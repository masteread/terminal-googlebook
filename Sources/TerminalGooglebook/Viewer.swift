import Darwin
import Foundation
import TerminalGooglebookCore
import TerminalUI

@MainActor
final class TerminalViewer {
    static var supportsCurrentTerminal: Bool {
        let env = ProcessInfo.processInfo.environment
        return isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 && env["TMUX"] == nil &&
            (env["TERM_PROGRAM"] == "iTerm.app" || env["TERM_PROGRAM"] == "ghostty" || env["KITTY_WINDOW_ID"] != nil || env["TERM"]?.contains("kitty") == true)
    }
    private enum Link: Equatable { case connecting, live }
    private struct Layout: Equatable {
        let desktop: DesktopPlacement
        let border: Bool
        let columns: Int, rows: Int
    }
    private struct Activity { let at: Date; let text: String; let ok: Bool; let milliseconds: Double? }
    private struct Shortcut { let key: Character; let label: String; let action: String; let arguments: [String: String]; let glyph: String }
    /// Lo que la terminal no puede mandar por sí misma: los botones de sistema de Android y atajos que ella se queda.
    private static let shortcuts: [Shortcut] = [
        Shortcut(key: "l", label: "Launcher", action: "key", arguments: ["key": "meta"], glyph: "Super"),
        Shortcut(key: "s", label: "Switch window", action: "key", arguments: ["key": "alt+tab"], glyph: "Alt+Tab"),
        Shortcut(key: "h", label: "Home", action: "home", arguments: [:], glyph: ""),
        Shortcut(key: "b", label: "Back", action: "back", arguments: [:], glyph: ""),
        Shortcut(key: "r", label: "Recents", action: "recents", arguments: [:], glyph: ""),
        Shortcut(key: "c", label: "Copy", action: "key", arguments: ["key": "ctrl+c"], glyph: "Ctrl+C"),
        Shortcut(key: "v", label: "Paste", action: "key", arguments: ["key": "ctrl+v"], glyph: "Ctrl+V")
    ]

    let mailbox: Mailbox
    let directory: URL
    let machine: Machine
    let graphics: String
    private let writer = TerminalWriter()
    private let renderer: DesktopRenderer
    private var metrics = TerminalMetricFilter()
    private var layout: Layout?
    private var hit: ImageLayout?
    /// The guest display in points: input coordinates, and the aspect ratio to lay out.
    private var points: (width: Int, height: Int)
    private var quit = false, link = Link.connecting, palette = false
    private var queue: [Request] = [], labels: [UUID: String] = [:], inFlight = false
    private var anchor: (x: Int, y: Int, at: Date)?, lastClick: (x: Int, y: Int, at: Date, count: Int)?
    private var wheel = (dx: 0, dy: 0, x: 0, y: 0, at: Date.distantPast)
    private var activity: [Activity] = []
    private var previousChrome = ""
    private var fps = 0.0, fpsSample = (frames: 0, at: Date())
    private var firstFrameShown = false

    init(directory: URL, machine: Machine) throws {
        mailbox = try Mailbox(directory.appendingPathComponent("exchange"))
        self.directory = directory; self.machine = machine
        points = (machine.width, machine.height)
        let env = ProcessInfo.processInfo.environment
        guard Self.supportsCurrentTerminal else { throw Failure("The viewer needs Ghostty, Kitty or iTerm2, outside tmux. Use the CLI or MCP tools from other terminals.") }
        graphics = env["TERM_PROGRAM"] == "iTerm.app" ? "iterm" : "kitty"
        // Kitty-protocol terminals start on PNG until they confirm shared memory support.
        renderer = DesktopRenderer(writer: writer, transport: graphics == "iterm" ? .iterm : .kittyDirect)
    }

    func run() async throws {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw Failure("Cannot read terminal settings") }
        var raw = original; cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { throw Failure("Cannot enter terminal input mode") }
        let signals = [SIGINT, SIGTERM, SIGHUP]
        let oldHandlers = signals.map { Darwin.signal($0, SIG_IGN) }
        let sources = signals.map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit = true }
            source.resume(); return source
        }
        writer.write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[2J\u{1b}[?1002h\u{1b}[?1006h")
        queryMetrics()
        var probe = graphics == "kitty" ? DesktopRenderer.sharedMemoryProbe() : nil
        if let probe { writer.write(probe.query) }
        var transportDecided = probe == nil
        defer {
            renderer.configure(placement: nil)
            probe?.cleanup()
            writer.write(renderer.clear() + "\u{1b}[0m\u{1b}[2J\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?25h\u{1b}[?1049l")
            writer.flush()
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            for (index, source) in sources.enumerated() { source.cancel(); Darwin.signal(signals[index], oldHandlers[index]) }
        }
        var streaming = false
        var parser = TerminalInput(), lastInput = Date(), previousSize = "", lastChrome = Date.distantPast
        let started = Date()
        while !quit {
            var size = winsize(); _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
            let key = "\(size.ws_col):\(size.ws_row):\(size.ws_xpixel):\(size.ws_ypixel)"
            if key != previousSize { previousSize = key; queryMetrics(); relayout(size) }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 0) > 0 {
                if descriptor.revents & Int16(POLLHUP | POLLERR) != 0 { break }
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 { break }
                if count > 0 {
                    lastInput = Date()
                    let before = (metrics.cellWidth, metrics.cellHeight, metrics.cellScale, metrics.background)
                    let filtered = metrics.feed(Array(bytes.prefix(count)))
                    if before != (metrics.cellWidth, metrics.cellHeight, metrics.cellScale, metrics.background) { relayout(size) }
                    handle(parser.feed(filtered))
                }
            } else if Date().timeIntervalSince(lastInput) > 0.1 {
                handle(parser.feed(metrics.feed([], flush: true), flushEscape: true))
            }
            // The probe reply arrives with the cell metrics, typically within a few milliseconds.
            if !transportDecided, metrics.graphicsReplies[31] != nil || Date().timeIntervalSince(started) > 0.4 {
                transportDecided = true
                if metrics.graphicsReplies[31] == "OK" { renderer.configure(placement: layout?.desktop, transport: .kittySharedMemory) }
                probe?.cleanup(); probe = nil
            }
            if transportDecided, !streaming, metrics.cellHeight != nil || Date().timeIntervalSince(started) > 0.4 { streaming = true; streamFrames() }
            if wheel.dx != 0 || wheel.dy != 0, Date().timeIntervalSince(wheel.at) >= 0.03 { flushWheel() }
            sendNextInput()
            if Date().timeIntervalSince(lastChrome) >= 0.08 { lastChrome = Date(); drawChrome() }
            // Sin input en curso duerme más: en reposo el viewer no debe gastar CPU.
            let active = inFlight || !queue.isEmpty || wheel.dx != 0 || wheel.dy != 0 || anchor != nil || Date().timeIntervalSince(lastInput) < 1
            try await Task.sleep(nanoseconds: active ? 4_000_000 : 30_000_000)
        }
    }

    // MARK: Frames

    /// Lee frames del cliente SPICE, que solo escribe cuando la pantalla cambió: sin cambios, este
    /// hilo queda bloqueado y no gasta nada. Si el socket se cierra y la VM ya no corre, sale.
    private func streamFrames() {
        let path = directory.appendingPathComponent("frame.sock").path, directory = directory, renderer = renderer
        Thread.detachNewThread { [weak self] in
            while true {
                if let fd = try? connectUnix(path) {
                    var header = [UInt32](repeating: 0, count: 4)
                    while header.withUnsafeMutableBytes({ fill(fd, $0.baseAddress!, 16) }) {
                        let width = Int(header[0]), height = Int(header[1]), stride = Int(header[2]), length = Int(header[3])
                        guard (1...8192).contains(width), (1...8192).contains(height), stride >= width * 4, (1...(256 << 20)).contains(length) else { break }
                        var data = Data(count: length)
                        guard data.withUnsafeMutableBytes({ fill(fd, $0.baseAddress!, length) }) else { break }
                        renderer.submit(.pixels(data, width: width, height: height, bytesPerRow: stride))
                        Task { @MainActor in self?.received(width: width, height: height) }
                    }
                    close(fd)
                }
                if !CLI.isRunning(directory) { Task { @MainActor in self?.quit = true }; return }
                usleep(200_000)
            }
        }
    }
    private func received(width: Int, height: Int) {
        link = .live
        if (width, height) != points { points = (width, height); forceRelayout() }
    }

    // MARK: Layout

    private func queryMetrics() { writer.write("\u{1b}[16t\u{1b}[14t\u{1b}]1337;ReportCellSize\u{7}\u{1b}]11;?\u{7}") }
    private func forceRelayout() {
        layout = nil
        var size = winsize(); _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size); relayout(size)
    }
    private func relayout(_ size: winsize) {
        let cols = max(1, Int(size.ws_col)), rows = max(4, Int(size.ws_row))
        let cw = metrics.cellWidth ?? (size.ws_xpixel > 0 ? Double(size.ws_xpixel) / Double(cols) : 8)
        let ch = metrics.cellHeight ?? (size.ws_ypixel > 0 ? Double(size.ws_ypixel) / Double(rows) : 16)
        // Header and footer take a row each; the rounded frame takes one more cell on every side.
        let border = rows >= 12 && cols >= 24, pad = border ? 1 : 0
        let fit = ImageLayout(width: points.width, height: points.height, column: 1 + pad, row: 2 + pad,
                              columns: cols - 2 * pad, rows: rows - 2 - 2 * pad, cellWidth: cw, cellHeight: ch)
        let scale = metrics.cellScale
        let desktop = DesktopPlacement(column: fit.column, row: fit.row, columns: fit.columns, rows: fit.rows,
                                       canvasWidth: max(1, Int((Double(fit.columns) * cw * scale).rounded())),
                                       canvasHeight: max(1, Int((Double(fit.rows) * ch * scale).rounded())),
                                       imageWidth: max(1, Int((fit.pixelWidth * scale).rounded())),
                                       imageHeight: max(1, Int((fit.pixelHeight * scale).rounded())),
                                       background: graphics == "iterm" ? metrics.background ?? 0x1a1b26 : nil)
        hit = fit
        let next = Layout(desktop: desktop, border: border, columns: cols, rows: rows)
        guard next != layout else { return }
        layout = next
        writer.write("\u{1b}[0m\u{1b}[2J")
        previousChrome = ""
        renderer.configure(placement: desktop)
        drawChrome()
        renderer.redraw()
    }

    // MARK: Chrome

    private func drawChrome() {
        guard let layout else { return }
        let now = Date(), stats = renderer.currentStats
        if now.timeIntervalSince(fpsSample.at) >= 1 {
            fps = Double(stats.frames - fpsSample.frames) / now.timeIntervalSince(fpsSample.at)
            fpsSample = (stats.frames, now)
        }
        let spin = Theme.spinner[Int(now.timeIntervalSinceReferenceDate * 12) % Theme.spinner.count]
        let d = layout.desktop, cols = layout.columns
        var output = ""

        // Header: brand, machine, connection state.
        let state: [Span] = switch link {
        case .connecting: [Span("\(spin) connecting", Theme.yellow)]
        case .live where fps >= 0.5: [Span("● ", Theme.green), Span("live", Theme.bold + Theme.green), Span("  \(Int(fps.rounded())) fps", Theme.muted)]
        case .live: [Span("● ", Theme.green), Span("live", Theme.bold + Theme.green), Span("  idle", Theme.faint)]
        }
        let latency = activity.last?.milliseconds.map { [Span("  \(Int($0.rounded())) ms", Theme.faint)] } ?? []
        let right = state + latency + [Span(" ")]
        var left = [Span(" ◆ terminal-googlebook ", Theme.badge), Span("  "), Span(machine.name, Theme.bold + Theme.text)]
        let detail = [Span("  Googlebook OS", Theme.muted), Span(" · \(points.width)×\(points.height)", Theme.faint),
                      Span(stats.sourceWidth > 0 ? " · \(stats.sourceWidth)×\(stats.sourceHeight) px" : "", Theme.faint)]
        for count in stride(from: detail.count, through: 0, by: -1) where left.width + Array(detail.prefix(count)).width + right.width + 2 <= cols {
            left += detail.prefix(count); break
        }
        output += Box.line(column: 1, row: 1, width: cols, left + [Span(String(repeating: " ", count: max(1, cols - left.width - right.width)))] + right)

        // Display frame. It lights up while a drag is in progress or the palette is open.
        if layout.border {
            output += Box.frame(column: d.column - 1, row: d.row - 1, width: d.columns + 2, height: d.rows + 2,
                                color: anchor != nil || palette ? Theme.accent : Theme.border)
        }
        if stats.frames > 0 && !firstFrameShown {
            // Wipe the connecting message so it does not sit on top of the desktop.
            firstFrameShown = true
            for offset in 0..<8 { output += Box.line(column: d.column, row: d.row + d.rows / 2 - 2 + offset, width: d.columns, []) }
            renderer.redraw()
        }
        if stats.frames == 0 {
            let lines: [[Span]] = [[Span("◆", Theme.accent)], [], [Span(spin + " ", Theme.yellow), Span("Starting \(machine.name)", Theme.text)], [Span("Ctrl+] exits; the VM keeps running", Theme.faint)]]
            // Always paint the same block of rows, so a shorter message clears a longer one.
            for (offset, line) in (lines + Array(repeating: [], count: max(0, 8 - lines.count))).prefix(8).enumerated() {
                let pad = max(0, (d.columns - line.width) / 2)
                output += Box.line(column: d.column, row: d.row + d.rows / 2 - 2 + offset, width: d.columns, [Span(String(repeating: " ", count: pad))] + line)
            }
        }
        if palette { output += drawPalette(d) }

        // Footer: key hints on the left, the latest action on the right.
        func hint(_ key: String, _ action: String) -> [Span] { [Span(" \(key) ", Theme.key), Span(" \(action)", Theme.muted), Span("  ")] }
        let quitHint = hint("⌃]", "quit")
        var footer: [Span] = [Span(" ")]
        if let last = activity.last, now.timeIntervalSince(last.at) < (last.ok ? 2.5 : 6) {
            let toast = [Span(last.ok ? "✓ " : "✕ ", last.ok ? Theme.green : Theme.red), Span(last.text, last.ok ? Theme.text : Theme.red)] +
                (last.milliseconds.map { [Span(" · \(Int($0.rounded())) ms", Theme.faint)] } ?? [])
            let fitted = toast.truncated(max(4, cols - quitHint.width - 3))
            footer += fitted + [Span(String(repeating: " ", count: max(1, cols - 1 - fitted.width - quitHint.width)))]
        } else {
            let hints = stats.frames == 0 ? [] : [("⌃G", "system"), ("click", "click"), ("drag", "drag"), ("wheel", "scroll"), ("type", "keyboard")]
            for (key, action) in hints {
                let item = hint(key, action)
                if footer.width + item.width + quitHint.width > cols { break }
                footer += item
            }
            footer += [Span(String(repeating: " ", count: max(0, cols - footer.width - quitHint.width)))]
        }
        footer += quitHint
        output += Box.line(column: 1, row: layout.rows, width: cols, footer)

        guard output != previousChrome else { return }
        previousChrome = output
        writer.write(output)
    }

    /// A centered card of Googlebook OS actions. Every cell has a background, so it covers the desktop image.
    private func drawPalette(_ d: DesktopPlacement) -> String {
        let surface = Theme.bg(0x1f2335), half = (Self.shortcuts.count + 1) / 2
        let cell = 24, width = min(d.columns, cell * 2 + 6), height = min(d.rows, half + 5)
        let column = d.column + (d.columns - width) / 2, row = d.row + (d.rows - height) / 2
        guard width >= 30, height >= 8 else { return "" }
        func styled(_ spans: [Span]) -> [Span] { spans.map { Span($0.text, surface + $0.style) } }
        func line(_ offset: Int, _ spans: [Span]) -> String {
            let fitted = styled(spans).truncated(width - 4)
            return "\u{1b}[\(row + offset);\(column + 2)H" + fitted.rendered + [Span(String(repeating: " ", count: max(0, width - 4 - fitted.width)), surface)].rendered
        }
        var output = ""
        for offset in 1..<(height - 1) {
            output += "\u{1b}[\(row + offset);\(column + 1)H" + [Span(" ", surface)].rendered + "\u{1b}[\(row + offset);\(column + width - 2)H" + [Span(" ", surface)].rendered
        }
        output += Box.frame(column: column, row: row, width: width, height: height,
                            title: [Span("Googlebook OS", Theme.bold + Theme.accent)], color: surface + Theme.accent)
        output += line(1, [])
        func item(_ s: Shortcut) -> [Span] {
            let label = [Span(" \(s.key) ", Theme.key), Span(" " + s.label, Theme.text)]
            let glyph = Span(s.glyph, Theme.faint)
            return label + [Span(String(repeating: " ", count: max(1, cell - label.width - glyph.text.count))), glyph]
        }
        for index in 0..<min(half, height - 4) {
            var spans = item(Self.shortcuts[index])
            if index + half < Self.shortcuts.count { spans += [Span("  ")] + item(Self.shortcuts[index + half]) }
            output += line(2 + index, spans)
        }
        let hint = "press a key · esc closes"
        output += line(height - 2, [Span(String(repeating: " ", count: max(0, (width - 4 - hint.count) / 2)) + hint, Theme.faint)])
        return output
    }
    private func setPalette(_ open: Bool) {
        guard palette != open, let layout else { return }
        palette = open
        if graphics == "iterm" { renderer.hold(open) }
        if !open {
            // Clear the card so the desktop shows through again.
            let d = layout.desktop
            for row in d.row..<(d.row + d.rows) { writer.write("\u{1b}[0m\u{1b}[\(row);\(d.column)H" + String(repeating: " ", count: d.columns)) }
            if graphics == "iterm" { renderer.redraw() }
        }
        previousChrome = ""; drawChrome()
    }

    private func record(_ text: String, ok: Bool, milliseconds: Double? = nil) {
        activity.append(Activity(at: Date(), text: text, ok: ok, milliseconds: milliseconds))
        if activity.count > 50 { activity.removeFirst(activity.count - 50) }
    }

    // MARK: Input

    /// Input runs one request at a time, in order, without ever blocking drawing or typing.
    private func enqueue(_ action: String, _ arguments: [String: String], label: String) {
        if action == "type", let last = queue.last, last.action == "type", let previous = last.arguments["text"],
           previous.utf8.count + (arguments["text"]?.utf8.count ?? 0) < 32768 {
            let text = previous + (arguments["text"] ?? "")
            let merged = Request(action: "type", arguments: ["text": text], timeout: 5)
            labels[last.id] = nil; labels[merged.id] = Self.typeLabel(text)
            queue[queue.count - 1] = merged; return
        }
        guard queue.count < 64 else { record("Input is busy; wait a moment", ok: false); return }
        let request = Request(action: action, arguments: arguments, timeout: 5)
        labels[request.id] = label
        queue.append(request)
    }
    private func sendNextInput() {
        guard !inFlight, !queue.isEmpty else { return }
        let request = queue.removeFirst(), label = labels.removeValue(forKey: request.id) ?? request.action
        inFlight = true
        Task { @MainActor in
            let started = Date()
            do {
                _ = try await mailbox.call(request)
                record(label, ok: true, milliseconds: Date().timeIntervalSince(started) * 1000)
            } catch {
                queue.removeAll(); labels.removeAll()
                record("\(label): \(error.localizedDescription)", ok: false)
            }
            inFlight = false
        }
    }
    private static func typeLabel(_ text: String) -> String {
        let visible = text.replacingOccurrences(of: "\n", with: "⏎")
        return "type “\(visible.count > 18 ? visible.prefix(17) + "…" : visible)”"
    }
    /// Terminal cell to guest point. Drags keep tracking outside the display.
    private func point(_ column: Int, _ row: Int, clamp: Bool = false) -> (Int, Int)? {
        hit?.point(column: column, row: row, clamp: clamp)
    }
    private func handle(_ events: [TerminalEvent]) {
        var text = ""
        func flush() { if !text.isEmpty { enqueue("type", ["text": text], label: Self.typeLabel(text)); text = "" } }
        for event in events {
            if case .quit = event { quit = true; return }
            if palette {
                switch event {
                case .text(let value):
                    if let shortcut = Self.shortcuts.first(where: { String($0.key) == value.lowercased() }) {
                        enqueue(shortcut.action, shortcut.arguments, label: shortcut.label)
                    }
                    setPalette(false)
                case .key, .mouse: setPalette(false)
                case .quit: break
                }
                continue
            }
            if case .text(let value) = event { text += value; continue }
            flush()
            switch event {
            case .key("ctrl+g"): setPalette(true)
            case .key(let key): enqueue("key", ["key": key], label: "key \(key)")
            case .mouse(let button, let column, let row, let released):
                if button & 64 != 0 {
                    guard let p = point(column, row) else { continue }
                    if wheel.dx == 0 && wheel.dy == 0 { wheel.at = Date() }
                    // 64/65 scroll vertically, 66/67 horizontally. Positive values scroll content up or left.
                    if button & 2 == 0 { wheel.dy = max(-1000, min(1000, wheel.dy + (button & 1 == 0 ? 60 : -60))) }
                    else { wheel.dx = max(-1000, min(1000, wheel.dx + (button & 1 == 0 ? 60 : -60))) }
                    wheel.x = p.0; wheel.y = p.1
                } else if button & 3 == 2 && button & 32 == 0 {
                    guard !released, let p = point(column, row) else { continue }
                    enqueue("click", ["x": String(p.0), "y": String(p.1), "button": "right"], label: "right click \(p.0),\(p.1)")
                } else if button & 32 != 0 {
                    continue // Motion while held: the drag is sent once, on release.
                } else if released {
                    guard let start = anchor, let p = point(column, row, clamp: true) else { anchor = nil; continue }
                    anchor = nil
                    if hypot(Double(p.0 - start.x), Double(p.1 - start.y)) >= 8 {
                        enqueue("drag", ["x": String(start.x), "y": String(start.y), "toX": String(p.0), "toY": String(p.1)], label: "drag \(start.x),\(start.y) → \(p.0),\(p.1)")
                    } else {
                        // A quick second click at the same spot continues a double (or triple) click.
                        var count = 1
                        if let last = lastClick, Date().timeIntervalSince(last.at) < 0.4, abs(last.x - start.x) <= 6, abs(last.y - start.y) <= 6 { count = min(3, last.count + 1) }
                        lastClick = (start.x, start.y, Date(), count)
                        var arguments = ["x": String(start.x), "y": String(start.y)]
                        if count > 1 { arguments["count"] = String(count) }
                        enqueue("click", arguments, label: (count == 2 ? "double click " : count == 3 ? "triple click " : "click ") + "\(start.x),\(start.y)")
                    }
                } else if button & 3 == 0, let p = point(column, row) {
                    anchor = (p.0, p.1, Date())
                }
            default: break
            }
        }
        flush()
    }
    private func flushWheel() {
        // Consecutive scrolls merge in the queue rather than piling up.
        if let last = queue.last, last.action == "scroll" {
            wheel.dy = max(-1000, min(1000, wheel.dy + (Int(last.arguments["dy"] ?? "") ?? 0)))
            wheel.dx = max(-1000, min(1000, wheel.dx + (Int(last.arguments["dx"] ?? "") ?? 0)))
            labels[last.id] = nil; queue.removeLast()
        }
        var arguments = ["x": String(wheel.x), "y": String(wheel.y), "dy": String(wheel.dy)]
        if wheel.dx != 0 { arguments["dx"] = String(wheel.dx) }
        let arrow = wheel.dy > 0 ? "↑" : wheel.dy < 0 ? "↓" : wheel.dx > 0 ? "←" : "→"
        enqueue("scroll", arguments, label: "scroll \(arrow)")
        wheel.dx = 0; wheel.dy = 0
    }
}

private func fill(_ fd: Int32, _ target: UnsafeMutableRawPointer, _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let got = read(fd, target + offset, count - offset)
        if got < 0 && errno == EINTR { continue }
        guard got > 0 else { return false }
        offset += got
    }
    return true
}

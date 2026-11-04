import Darwin
import Foundation
import TerminalGooglebookCore

/// El estado de la instalación, en disco para que otra terminal, un agente o `status` lo puedan leer.
struct SetupState: Codable {
    struct Phase: Codable { let label: String; let seconds: Int }
    var state = "running"  // running, done, failed
    var step = 0, steps = Setup.stepCount
    var label = "Starting"
    var percent: Int?
    var doneBytes: Int64?, totalBytes: Int64?, bytesPerSecond: Int64?, secondsLeft: Int?
    var elapsedSeconds = 0
    var error: String?
    var log = ""
    var phases: [Phase] = []
}

/// Descarga la imagen de Google y arma el disco en esta máquina; nada de eso se redistribuye.
@MainActor
final class Setup {
    nonisolated static let stepCount = 5
    private struct Stage { let marker: String; let step: Int; let label: String; var file: String? = nil; var size: Int64? = nil }
    /// Las líneas que imprimen vm/fetch.sh y vm/build-image.sh. Los tamaños están fijados por sus SHA-256.
    private static let stages = [
        Stage(marker: "== UTM", step: 1, label: "Downloading UTM", file: "downloads/UTM-5.0.6.dmg.part", size: 303_864_562),
        Stage(marker: "verifying UTM", step: 1, label: "Preparing UTM"),
        Stage(marker: "== Cuttlefish", step: 2, label: "Downloading Cuttlefish", file: "downloads/aosp_cf_arm64_only_phone-img-16373615.zip.part", size: 1_101_175_103),
        Stage(marker: "verifying aosp", step: 2, label: "Unpacking Cuttlefish"),
        Stage(marker: "== Googlebook recovery", step: 3, label: "Downloading Googlebook OS", file: "downloads/mica-recovery.zip.part", size: 7_601_764_157),
        Stage(marker: "verifying mica", step: 4, label: "Unpacking Googlebook OS", file: "googlebook/mica-recovery.raw.part", size: 19_230_966_272),
        Stage(marker: "== Fetch complete", step: 5, label: "Assembling the disk")
    ]

    let store: Store, assets: Assets, launcher: String
    private var lockDescriptor: Int32 = -1
    private var stateURL: URL { store.root.appendingPathComponent("setup.json") }
    private var logURL: URL { store.root.appendingPathComponent("setup.log") }
    private var lockURL: URL { store.root.appendingPathComponent("setup.lock") }
    private let isTerminal = isatty(STDERR_FILENO) == 1
    private var lastPlainLine = Date.distantPast, lastPlainLabel = ""

    init(store: Store, assets: Assets, launcher: String) { self.store = store; self.assets = assets; self.launcher = launcher }

    /// Instala, o sigue una instalación ya en curso en otra terminal. Lanza un error si no termina bien.
    func run(showNext: Bool) async throws {
        if assets.isInstalled {
            if showNext { printNext(header: "Already set up.") }
            return
        }
        guard let sources = assets.vmSources else { throw Failure("This build has no VM installer. Reinstall terminal-googlebook.") }
        try FileManager.default.createDirectory(at: assets.work, withIntermediateDirectories: true)
        guard takeLock() else { return try await follow(showNext: showNext) }
        defer { close(lockDescriptor) }
        stderr("Setting up the virtual Googlebook: about 9 GB to download, 60 GB of free disk, usually 30 to 60 minutes.\nIf it stops, run the same command again: it continues where it left off. Log: \(logURL.path)")

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = sources.appendingPathComponent("install.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["GOOGLEBOOK_WORK"] = assets.work.path
        if let bundle = assets.bundle {
            environment["GBOS_BUNDLE"] = bundle.path
            let tools = ["python/bin", "tools/bin", "tools/sbin"].map { bundle.appendingPathComponent($0).path }
            environment["PATH"] = (tools + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        }
        process.environment = environment
        process.standardOutput = log; process.standardError = log; process.standardInput = FileHandle.nullDevice
        try process.run()

        var state = SetupState(); state.log = logURL.path
        let started = Date()
        var phaseStart = started, samples: [(at: Date, bytes: Int64)] = [], lastChange = Date()
        while process.isRunning {
            let now = Date(), stage = currentStage()
            state.elapsedSeconds = Int(now.timeIntervalSince(started))
            if stage.label != state.label {
                if state.step > 0 { state.phases.append(.init(label: state.label, seconds: Int(now.timeIntervalSince(phaseStart)))) }
                phaseStart = now; samples = []; lastChange = now
            }
            state.step = stage.step; state.label = stage.label
            state.percent = nil; state.doneBytes = nil; state.totalBytes = nil; state.bytesPerSecond = nil; state.secondsLeft = nil
            if let file = stage.file, let total = stage.size,
               let size = (try? FileManager.default.attributesOfItem(atPath: assets.work.appendingPathComponent(file).path))?[.size] as? Int64 {
                if size != samples.last?.bytes { lastChange = now }
                samples.append((now, size)); samples.removeAll { now.timeIntervalSince($0.at) > 15 }
                state.doneBytes = size; state.totalBytes = total; state.percent = Int(min(100, size * 100 / max(1, total)))
                if let first = samples.first, now.timeIntervalSince(first.at) >= 3, size > first.bytes {
                    let speed = Double(size - first.bytes) / now.timeIntervalSince(first.at)
                    state.bytesPerSecond = Int64(speed); state.secondsLeft = Int(Double(total - size) / speed)
                }
                if now.timeIntervalSince(lastChange) > 20 { state.label = stage.label + " (waiting for the network, it retries on its own)" }
            }
            save(state); draw(state)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        endLine()
        state.elapsedSeconds = Int(Date().timeIntervalSince(started))
        state.phases.append(.init(label: currentStage().label, seconds: Int(Date().timeIntervalSince(phaseStart))))
        state.percent = nil; state.doneBytes = nil; state.totalBytes = nil; state.bytesPerSecond = nil; state.secondsLeft = nil
        guard process.terminationStatus == 0, assets.isInstalled else {
            state.state = "failed"
            state.error = lastLines(8)
            save(state)
            throw Failure("Setup stopped during \"\(state.label)\" after \(Self.duration(state.elapsedSeconds)).\n\(state.error ?? "")\nRun the same command again to continue. Full log: \(logURL.path)")
        }
        state.state = "done"; state.step = Self.stepCount; state.label = "Done"
        save(state)
        report(state, showNext: showNext)
    }

    /// Otra instalación tiene el candado: muestra su progreso hasta que termine.
    private func follow(showNext: Bool) async throws {
        stderr("Setup is already running in another process; following it. Ctrl+C here does not stop it.")
        while !takeLock() {
            if let state = loadState() { draw(state) }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        close(lockDescriptor)
        endLine()
        if assets.isInstalled, let state = loadState() { report(state, showNext: showNext); return }
        throw Failure("Setup stopped: \(loadState()?.error ?? "no details"). Run the same command again to continue. Full log: \(logURL.path)")
    }

    /// Una línea para quien pregunta sin estar mirando: un agente o `status`.
    func summary() -> (state: String, text: String) {
        if assets.isInstalled { return ("ready", "Setup is complete.") }
        let command = "\(launcher) setup"
        if !isLocked { 
            if let state = loadState(), state.state == "failed" || state.state == "running" {
                return ("stopped", "Setup stopped during \"\(state.label)\". Ask the user to run `\(command)` in a terminal; it continues where it left off. Log: \(logURL.path)")
            }
            return ("not-set-up", "The virtual Googlebook is not set up. Ask the user to run `\(command)` in a terminal. It downloads about 9 GB and usually takes 30 to 60 minutes, with a progress bar. If you can run shell commands and the user agrees, run it yourself in the background and check it with `\(launcher) status`.")
        }
        guard let state = loadState() else { return ("setting-up", "Setup is starting.") }
        return ("setting-up", "Setup is running: \(Self.line(state, bar: false)). Tell the user, and check again in a few minutes.")
    }

    private var isLocked: Bool {
        guard takeLock() else { return true }
        close(lockDescriptor); return false
    }
    private func takeLock() -> Bool {
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { if descriptor >= 0 { close(descriptor) }; return false }
        lockDescriptor = descriptor; return true
    }
    private func loadState() -> SetupState? { (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(SetupState.self, from: $0) } }
    private func save(_ state: SetupState) { try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic) }

    private func currentStage() -> Stage {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        var current = Stage(marker: "", step: 0, label: "Starting")
        for line in text.split(separator: "\n") {
            if let stage = Self.stages.first(where: { line.hasPrefix($0.marker) }) { current = stage }
            else if current.step == 0, line.hasPrefix("== ") { current = Stage(marker: "", step: 5, label: String(line.dropFirst(3))) }
        }
        return current
    }
    private func lastLines(_ count: Int) -> String {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).suffix(count).joined(separator: "\n")
    }

    private func draw(_ state: SetupState) {
        guard isTerminal else {
            // Sin terminal, para agentes y logs: una línea por paso y otra cada 30 s.
            guard state.label != lastPlainLabel || Date().timeIntervalSince(lastPlainLine) >= 30 else { return }
            lastPlainLabel = state.label; lastPlainLine = Date()
            stderr(Self.line(state, bar: false)); return
        }
        var size = winsize(); _ = ioctl(STDERR_FILENO, TIOCGWINSZ, &size)
        let columns = size.ws_col > 0 ? Int(size.ws_col) : 100
        _ = writeAll(STDERR_FILENO, Data(("\r\u{1b}[K" + String(Self.line(state, bar: true).prefix(columns - 1))).utf8))
    }
    private func endLine() { if isTerminal { _ = writeAll(STDERR_FILENO, Data("\r\u{1b}[K".utf8)) } }

    private func report(_ state: SetupState, showNext: Bool) {
        var lines = ["✓ Setup finished in \(Self.duration(state.elapsedSeconds))."]
        lines += state.phases.filter { $0.seconds > 0 }.map { "    \($0.label): \(Self.duration($0.seconds))" }
        stderr(lines.joined(separator: "\n"))
        if showNext { printNext(header: nil) }
    }
    private func printNext(header: String?) {
        stderr((header.map { $0 + "\n" } ?? "") + """

        Next:
          Use it yourself:    \(launcher) up
          Give it to Claude:  \(launcher) connect
                              Then tell Claude Code "open your computer", or type /googlebook
        """)
    }

    static func line(_ s: SetupState, bar: Bool) -> String {
        var parts = ["[\(max(s.step, 1))/\(s.steps)] \(s.label)"]
        if let percent = s.percent {
            if bar {
                let filled = percent * 24 / 100
                parts.append(String(repeating: "█", count: filled) + String(repeating: "░", count: 24 - filled) + " \(percent)%")
            } else { parts.append("\(percent)%") }
        }
        if let done = s.doneBytes, let total = s.totalBytes { parts.append(String(format: "%.1f/%.1f GB", Double(done) / 1e9, Double(total) / 1e9)) }
        if let speed = s.bytesPerSecond { parts.append(String(format: "%.1f MB/s", Double(speed) / 1e6)) }
        if let left = s.secondsLeft { parts.append("~\(duration(left)) left") }
        parts.append("\(duration(s.elapsedSeconds)) so far")
        return parts.joined(separator: "  ")
    }
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%dm%02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh%02dm", seconds / 3600, seconds / 60 % 60)
    }
}

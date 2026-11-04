import Foundation
import Darwin
import TerminalGooglebookCore

/// La última acción de un agente, para que quien mira el viewer la vea. Sin el texto que escribe:
/// este archivo no debe guardar contraseñas.
struct AgentActivity: Codable {
    let text: String
    let x: Int?, y: Int?
    let click: Bool
}

/// Dónde están los binarios de la VM. En desarrollo, el `vm/` del repositorio.
struct Assets {
    let work: URL
    let vmSources: URL?
    let python: URL
    /// Los binarios precompilados del release; nil al compilar desde el repositorio.
    let bundle: URL?

    init(store: Store, executable: URL) {
        let environment = ProcessInfo.processInfo.environment
        var sources: URL?
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("vm")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("run/run_vm.py").path) { sources = candidate; break }
            directory.deleteLastPathComponent()
        }
        vmSources = sources
        if let override = environment["TERMINAL_GOOGLEBOOK_WORK"] { work = URL(fileURLWithPath: override) }
        else if let sources, FileManager.default.fileExists(atPath: sources.appendingPathComponent("work/host/qemu-interop").path) { work = sources.appendingPathComponent("work") }
        else { work = store.root.appendingPathComponent("work") }
        bundle = sources.map { $0.deletingLastPathComponent().appendingPathComponent("bundle") }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let bundled = (bundle ?? store.root).appendingPathComponent("python/bin/python3")
        python = URL(fileURLWithPath: environment["TERMINAL_GOOGLEBOOK_PYTHON"] ?? (FileManager.default.fileExists(atPath: bundled.path) ? bundled.path : "/usr/bin/python3"))
    }
    var baseImage: URL { work.appendingPathComponent("image") }
    var headless: URL { work.appendingPathComponent("host/headless") }
    var isInstalled: Bool {
        ["googlebook.raw", "initrd.img", "kernel.Image"].allSatisfy { FileManager.default.fileExists(atPath: baseImage.appendingPathComponent($0).path) }
            && FileManager.default.isExecutableFile(atPath: headless.path)
    }
}

func connectUnix(_ path: String) throws -> Int32 {
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure("Socket path too long: \(path)") }
    withUnsafeMutablePointer(to: &address.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strcpy($0, path) } }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure("Cannot create socket") }
    let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard result == 0 else { close(fd); throw Failure("Cannot connect to \(path): \(String(cString: strerror(errno)))") }
    return fd
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}

/// Lee una línea de `fd` esperando como mucho `timeout` segundos.
func readLine(_ fd: Int32, buffer: inout Data, timeout: TimeInterval) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            return line
        }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
        guard remaining > 0, poll(&descriptor, 1, remaining) > 0 else { throw Failure("Timed out reading from the VM") }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &chunk, chunk.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw Failure("The VM closed the connection") }
        buffer.append(contentsOf: chunk.prefix(count))
    }
}

/// Teclado y control de QEMU por su socket QMP.
final class QMP {
    private let fd: Int32
    private var buffer = Data()
    init(path: String) throws {
        fd = try connectUnix(path)
        _ = try readLine(fd, buffer: &buffer, timeout: 5)
        _ = try command("qmp_capabilities")
    }
    deinit { close(fd) }
    @discardableResult
    func command(_ name: String, _ arguments: [String: Any]? = nil) throws -> [String: Any] {
        var message: [String: Any] = ["execute": name]
        if let arguments { message["arguments"] = arguments }
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        guard writeAll(fd, data) else { throw Failure("QEMU is not accepting commands") }
        while true {
            let line = try readLine(fd, buffer: &buffer, timeout: 10)
            guard let reply = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if reply["event"] != nil { continue }
            if let error = reply["error"] as? [String: Any] { throw Failure("\(name): \(error["desc"] as? String ?? "QEMU error")") }
            return reply
        }
    }
    func press(_ codes: [String]) throws {
        func event(_ code: String, _ down: Bool) -> [String: Any] {
            ["type": "key", "data": ["down": down, "key": ["type": "qcode", "data": code]]]
        }
        try command("input-send-event", ["events": codes.map { event($0, true) }])
        // Android abre su selector de ventanas solo si Alt sigue pulsada un momento tras el Tab.
        usleep(codes.contains("alt") && codes.contains("tab") ? 400_000 : 30_000)
        try command("input-send-event", ["events": codes.reversed().map { event($0, false) }])
        usleep(30_000)
    }
}

/// Lado host del helper de puntero: el guest se conecta a este puerto por la NAT y debe recibir
/// el token del boot actual. Solo escucha en loopback. Lo que el guest envía se descarta, así que
/// su clipboard nunca llega al host.
final class PointerHelper {
    static let port: UInt16 = 27183
    private let lock = NSLock()
    private var connection: Int32 = -1
    private let listener: Int32
    private let token: () -> String?

    init(token: @escaping () -> String?) throws {
        self.token = token
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = Self.port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 1) == 0 else {
            close(listener)
            throw Failure("Port \(Self.port) is in use. Another Googlebook VM or the Googlebook VM app is probably running; only one VM can run at a time.")
        }
        Thread.detachNewThread { [self] in acceptLoop() }
    }
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connection >= 0 }

    private func acceptLoop() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            var one: Int32 = 1; setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            guard let token = token(), writeAll(fd, Data("A \(token)\nG 0 0\n".utf8)) else { close(fd); continue }
            lock.lock(); if connection >= 0 { close(connection) }; connection = fd; lock.unlock()
            Thread.detachNewThread { [self] in
                var chunk = [UInt8](repeating: 0, count: 4096)
                while read(fd, &chunk, chunk.count) > 0 {}
                lock.lock(); if connection == fd { close(fd); connection = -1 }; lock.unlock()
            }
        }
    }
    func send(_ line: String) throws {
        lock.lock(); let fd = connection; lock.unlock()
        guard fd >= 0, writeAll(fd, Data((line + "\n").utf8)) else { throw Failure("The pointer helper is not connected yet. Android may still be starting; try again in a few seconds.") }
    }
    /// Espera al helper, que reintenta cada pocos segundos mientras Android arranca.
    func waitUntilConnected(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !isConnected, Date() < deadline { usleep(100_000) }
    }
}

/// El proceso que vive tanto como la VM: lanza QEMU y el cliente de frames, y atiende las acciones
/// que llegan de la CLI y del servidor MCP. Nunca usa las APIs de pantalla o input del host.
final class HostRuntime {
    let machine: Machine
    let directory: URL
    let assets: Assets
    private let lock: FileLock
    private let mailbox: Mailbox
    private let helper: PointerHelper
    private let vm = Process()
    private let frames = Process()
    private let framesInput = Pipe(), framesOutput = Pipe()
    private var framesBuffer = Data()
    private var qmp: QMP?
    private var bootCompleted = false
    private var stopping = false

    init(machine: Machine, directory: URL, assets: Assets) throws {
        self.machine = machine; self.directory = directory; self.assets = assets
        lock = try FileLock(directory.appendingPathComponent("runtime.lock"))
        let tokenURL = directory.appendingPathComponent("token")
        for stale in ["token", "qmp.sock", "spice.sock", "frame.sock", "activity", "serial.sock", "serial.log", "result.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(stale))
        }
        helper = try PointerHelper(token: { (try? String(contentsOf: tokenURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) })
        mailbox = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
    }

    /// Si algo falla después de lanzar QEMU, la VM se apaga: nunca queda una VM sin dueño.
    func run() async throws {
        do { try await serve() }
        catch {
            if vm.isRunning {
                vm.terminationHandler = nil
                kill(vm.processIdentifier, SIGTERM)
                vm.waitUntilExit()
            }
            throw error
        }
    }

    private func serve() async throws {
        vm.executableURL = assets.python
        var arguments = [Self.runnerPath(assets), assets.work.path, machine.name, "--run-dir", directory.path, "--image", directory.path, "--seconds", "0",
                         "--display", "\(machine.width)x\(machine.height)", "--memory", String(machine.memoryGiB * 1024), "--cpus", String(machine.cpu),
                         "--no-audio", "--no-bluetooth", "--no-mouse"]
        if !machine.network { arguments.append("--offline") }
        vm.arguments = arguments
        vm.terminationHandler = { _ in exit(0) }
        try vm.run()

        let spice = directory.appendingPathComponent("spice.sock").path
        let started = Date()
        while !FileManager.default.fileExists(atPath: spice) {
            guard vm.isRunning, Date().timeIntervalSince(started) < 30 else { throw Failure("QEMU did not start. Details: \(directory.path)/host.log") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        frames.executableURL = assets.headless
        frames.arguments = [spice, directory.appendingPathComponent("frame.sock").path]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_FRAMEWORK_PATH"] = assets.work.appendingPathComponent("UTM-beta/UTM.app/Contents/Frameworks").path
        environment["VM_MOUSE_SEAMLESS"] = "0"
        frames.environment = environment
        frames.standardInput = framesInput; frames.standardOutput = framesOutput
        frames.standardError = FileHandle(forWritingAtPath: directory.appendingPathComponent("runtime.log").path) ?? FileHandle.standardError
        try frames.run()
        // QEMU crea sus sockets uno a uno: spice.sock puede aparecer antes que qmp.sock.
        while qmp == nil {
            do { qmp = try QMP(path: directory.appendingPathComponent("qmp.sock").path) }
            catch {
                guard vm.isRunning, Date().timeIntervalSince(started) < 30 else { throw error }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        termination.setEventHandler { [self] in stop(force: false) }
        termination.resume()
        withExtendedLifetime(termination) {}
        Self.keepAlive = termination

        // El kernel avisa cuando llega una petición: sin peticiones, este proceso no gasta CPU ni añade latencia.
        let exchange = open(directory.appendingPathComponent("exchange").path, O_EVTONLY | O_CLOEXEC)
        let arrival = DispatchSemaphore(value: 0)
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: exchange, eventMask: .write, queue: .global())
        watcher.setEventHandler { arrival.signal() }
        watcher.resume()
        Self.keepAliveWatcher = watcher
        while true {
            watchBoot()
            for request in try mailbox.requests() {
                do { try mailbox.respond(Reply(id: request.id, values: try await handle(request))) }
                catch { try? mailbox.respond(Reply(id: request.id, error: error.localizedDescription)) }
            }
            Self.waitBriefly(arrival)
        }
    }
    private static func waitBriefly(_ arrival: DispatchSemaphore) { _ = arrival.wait(timeout: .now() + 0.5) }
    private static var keepAlive: Any?
    private static var keepAliveWatcher: Any?
    static func runnerPath(_ assets: Assets) -> String {
        (assets.vmSources?.appendingPathComponent("run/run_vm.py").path) ?? assets.work.appendingPathComponent("run/run_vm.py").path
    }

    private var lastBootCheck = Date.distantPast
    private func watchBoot() {
        guard !bootCompleted, Date().timeIntervalSince(lastBootCheck) > 0.5 else { return }
        lastBootCheck = Date()
        guard let log = try? Data(contentsOf: directory.appendingPathComponent("serial.log")), log.range(of: Data("VM_BOOT_COMPLETED".utf8)) != nil else { return }
        bootCompleted = true
        // La densidad acorde a la resolución, igual que launch.py, para que la interfaz quepa.
        let density = Int((240.0 * Double(machine.width) / 1920.0).rounded())
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [self] in try? control("VM_DENSITY \(density)") }
    }

    /// Canal fijo de verbos al guest. El FIFO de su puerto serie es de 16 bytes: se escribe por partes.
    private func control(_ verb: String) throws {
        let fd = try connectUnix(directory.appendingPathComponent("serial.sock").path)
        defer { close(fd) }
        let data = Data((verb + "\n").utf8)
        for start in stride(from: 0, to: data.count, by: 8) {
            guard writeAll(fd, data.subdata(in: start..<min(start + 8, data.count))) else { throw Failure("The guest control channel is closed") }
            usleep(30_000)
        }
    }

    private func serialLogSize() -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("serial.log").path)[.size] as? UInt64) ?? 0
    }

    /// Espera una línea nueva del puerto serie que cumpla `pattern`, leyendo solo lo posterior a `offset`.
    private func waitForSerial(_ pattern: String, after offset: UInt64, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("serial.log")) {
                defer { try? handle.close() }
                try? handle.seek(toOffset: offset)
                if let data = try? handle.readToEnd() {
                    let text = String(decoding: data, as: UTF8.self)
                    if let range = text.range(of: pattern, options: .regularExpression) { return String(text[range]) }
                }
            }
            usleep(50_000)
        }
        return nil
    }

    private func currentUser() -> Int? {
        let offset = serialLogSize()
        guard (try? control("VM_STATUS")) != nil, let line = waitForSerial("VM_CONTROL boot=[01]? ?user=[0-9]+", after: offset, timeout: 6) else { return nil }
        return Int(line.split(separator: "=").last ?? "")
    }

    private func status(quick: Bool) -> [String: String] {
        var values = ["name": machine.name, "state": stopping ? "stopping" : "running", "bootCompleted": String(bootCompleted),
                      "helperConnected": String(helper.isConnected), "width": String(machine.width), "height": String(machine.height)]
        if !quick, bootCompleted {
            // Con el usuario 0 activo Android está en el selector de usuario.
            let user = currentUser()
            values["userPicker"] = user.map { String($0 == 0) } ?? "unknown"
        }
        return values
    }

    /// Una captura en `path`. El cliente de frames responde con la resolución.
    private func capture(_ path: URL) throws -> (width: Int, height: Int) {
        guard writeAll(framesInput.fileHandleForWriting.fileDescriptor, Data("shot \(path.path)\n".utf8)) else { throw Failure("The frame client stopped") }
        while true {
            let line = try readLine(framesOutput.fileHandleForReading.fileDescriptor, buffer: &framesBuffer, timeout: 10)
            guard line.hasPrefix("FRAME ") else { continue }
            let parts = line.split(separator: " ")
            guard parts.count == 4, parts[1] == "ok", let width = Int(parts[2]), let height = Int(parts[3]) else {
                throw Failure("No frame is available yet. Android may still be starting; try again in a few seconds.")
            }
            return (width, height)
        }
    }

    private func requireQMP() throws -> QMP {
        guard let qmp else { throw Failure("QEMU is not ready") }
        return qmp
    }

    private func type(_ text: String) throws {
        for run in GuestInput.runs(text) {
            switch run {
            case .keys(let chords): for codes in chords { try requireQMP().press(codes) }
            case .paste(let segment):
                helper.waitUntilConnected(timeout: 10)
                try helper.send("C " + Data(segment.utf8).base64EncodedString())
                usleep(100_000)
                try helper.send("K 279")  // KEYCODE_PASTE
                usleep(100_000)
            }
        }
    }

    /// Lleva el puntero a un punto de la pantalla.
    private func move(x: Int, y: Int) throws {
        guard (0..<machine.width).contains(x), (0..<machine.height).contains(y) else {
            throw Failure("(\(x), \(y)) is outside the \(machine.width)×\(machine.height) screen")
        }
        helper.waitUntilConnected(timeout: 10)
        try helper.send("M \(x) \(y)")
    }

    private func click(x: Int, y: Int, button: String?, count: Int) throws {
        let mask = button == "right" ? 2 : 1
        try move(x: x, y: y)
        usleep(30_000)
        for _ in 0..<count {
            try helper.send("D \(mask)"); usleep(40_000)
            try helper.send("U \(mask)"); usleep(40_000)
        }
    }

    /// Pasos intermedios a unos 60 Hz: Android descarta un arrastre sin movimiento entre bajar y subir.
    private func drag(x: Int, y: Int, toX: Int, toY: Int) throws {
        try move(x: toX, y: toY)
        try move(x: x, y: y)
        usleep(30_000)
        try helper.send("D 1")
        usleep(40_000)
        let steps = 12
        for step in 1...steps {
            try helper.send("M \(x + (toX - x) * step / steps) \(y + (toY - y) * step / steps)")
            usleep(16_000)
        }
        usleep(40_000)
        try helper.send("U 1")
    }

    /// `dy` positivo desplaza hacia arriba y negativo hacia abajo, como la rueda; `dx` positivo va
    /// hacia la izquierda. Una muesca de rueda son 60 unidades.
    private func scroll(x: Int, y: Int, dx: Int, dy: Int) throws {
        try move(x: x, y: y)
        usleep(20_000)
        try helper.send(String(format: "S %.3f %.3f", -Double(dx) / 60, Double(dy) / 60))
    }

    /// Un intent VIEW por el canal de verbos. La alternativa de click en el dock y escribir en el
    /// omnibox se probó y falla: el dock minimiza Chrome si ya está al frente y el texto se corrompe.
    private func openURL(_ url: String) throws {
        let validated = try GuestInput.validatedURL(url)
        let offset = serialLogSize()
        try control("VM_OPEN_URL " + Data(validated.utf8).base64EncodedString())
        guard let result = waitForSerial("VM_CONTROL open_url [^\\n]*", after: offset, timeout: 20) else { throw Failure("Android did not answer. It may still be starting.") }
        if result.contains("open_url picker") { throw Failure("Android is at the user picker. Take a screenshot and click User, then try again.") }
        if result.contains("Error") { throw Failure("Chrome could not open the URL: \(result)") }
    }

    private func handle(_ request: Request) async throws -> [String: String] {
        let a = request.arguments
        func int(_ key: String) throws -> Int {
            guard let value = a[key].flatMap({ Int($0) }) else { throw Failure("Missing integer '\(key)'") }
            return value
        }
        func text(_ key: String) throws -> String {
            guard let value = a[key], !value.isEmpty else { throw Failure("Missing '\(key)'") }
            return value
        }
        switch request.action {
        case "status": return status(quick: a["quick"] == "true")
        case "screenshot", "snapshot":
            let name = "image-\(request.id.uuidString).png"
            let size = try capture(directory.appendingPathComponent("exchange").appendingPathComponent(name))
            return ["image": name, "width": String(size.width), "height": String(size.height)]
        case "click":
            let count = try a["count"] == nil ? (a["double"] == "true" ? 2 : 1) : int("count")
            guard (1...3).contains(count) else { throw Failure("count must be 1, 2 or 3") }
            try click(x: try int("x"), y: try int("y"), button: a["button"], count: count)
        case "move": try move(x: try int("x"), y: try int("y"))
        case "drag": try drag(x: try int("x"), y: try int("y"), toX: try int("toX"), toY: try int("toY"))
        case "scroll":
            let dx = a["dx"].flatMap { Int($0) } ?? 0, dy = a["dy"].flatMap { Int($0) } ?? 0
            guard (-1000...1000).contains(dx), (-1000...1000).contains(dy), dx != 0 || dy != 0 else { throw Failure("scroll needs dx or dy between -1000 and 1000") }
            try scroll(x: try int("x"), y: try int("y"), dx: dx, dy: dy)
        case "home", "back", "recents":
            helper.waitUntilConnected(timeout: 10)
            try helper.send("K \(["home": 3, "back": 4, "recents": 187][request.action]!)")
        case "type": try type(try text("text"))
        case "key": try requireQMP().press(try GuestInput.chord(try text("key")))
        case "open_url": try openURL(try text("url"))
        case "stop":
            stop(force: a["force"] == "true")
            return ["name": machine.name, "state": "stopping"]
        default: throw Failure("Unknown action: \(request.action)")
        }
        if a["source"] != "viewer" { publish(request) }
        return ["ok": "true"]
    }

    private func publish(_ request: Request) {
        let a = request.arguments
        func point(_ x: String, _ y: String) -> (Int, Int)? { a[x].flatMap { Int($0) }.flatMap { px in a[y].flatMap { Int($0) }.map { (px, $0) } } }
        let at: (Int, Int)?, text: String
        switch request.action {
        case "click": at = point("x", "y"); text = "\(a["button"] == "right" ? "right-click" : a["count"].flatMap { Int($0) }.map { $0 > 1 } == true ? "double-click" : "click") \(at?.0 ?? 0),\(at?.1 ?? 0)"
        case "move": at = point("x", "y"); text = "move \(at?.0 ?? 0),\(at?.1 ?? 0)"
        case "drag": at = point("toX", "toY"); text = "drag to \(at?.0 ?? 0),\(at?.1 ?? 0)"
        case "scroll": at = point("x", "y"); text = "scroll at \(at?.0 ?? 0),\(at?.1 ?? 0)"
        case "type": at = nil; text = "type \(a["text"]?.count ?? 0) characters"
        case "key": at = nil; text = "key \(a["key"] ?? "")"
        case "open_url": at = nil; text = "open \(a["url"] ?? "")"
        default: at = nil; text = request.action
        }
        let entry = AgentActivity(text: text, x: at?.0, y: at?.1, click: request.action == "click")
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: directory.appendingPathComponent("activity"), options: .atomic)
    }

    private func stop(force: Bool) {
        stopping = true
        if force { try? qmp?.command("quit") }
        else if vm.isRunning { kill(vm.processIdentifier, SIGTERM) }  // run_vm.py apaga Android antes de terminar
    }
}

import Foundation
import TerminalGooglebookCore
import Darwin

@MainActor
final class CLI {
    let store = Store()
    var executableURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath()
    }
    var assets: Assets { Assets(store: store, executable: executableURL) }

    func run(_ input: [String]) async throws {
        let command = input.first ?? "help"
        let tail = Array(input.dropFirst())
        switch command {
        case "help", "--help", "-h": print(Self.help)
        case "--version", "version": print("terminal-googlebook \(appVersion)")
        case "up": try await up(tail)
        case "start":
            let args = try Arguments(tail, flags: ["detach"], options: ["timeout"])
            let name = try args.machineName()
            _ = try store.load(name)
            try await start(name, wait: !args.flags.contains("detach"), timeout: args.integer("timeout", default: 300, range: 1...3600))
        case "ls", "list":
            _ = try Arguments(tail)
            let directory = store.root.appendingPathComponent("machines")
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let machines = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { try? store.load($0.lastPathComponent) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(machines), as: UTF8.self))
        case "status":
            let name = try Arguments(tail).machineName()
            _ = try store.load(name)
            guard Self.isRunning(try store.directory(name)) else { try printJSON(["name": name, "state": "stopped"]); return }
            try printJSON(try await call(name, Request(action: "status", timeout: 15)).values)
        case "stop":
            let args = try Arguments(tail, flags: ["force"])
            let name = try args.machineName()
            _ = try store.load(name)
            let directory = try store.directory(name)
            guard Self.isRunning(directory) else { try printJSON(["name": name, "state": "stopped"]); return }
            _ = try await call(name, Request(action: "stop", arguments: ["force": String(args.flags.contains("force"))], timeout: 10))
            let deadline = Date().addingTimeInterval(60)
            while Self.isRunning(directory) {
                guard Date() < deadline else { throw Failure("VM '\(name)' did not stop in time. Use: terminal-googlebook stop \(name) --force") }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try printJSON(["name": name, "state": "stopped"])
        case "__run":
            let name = try Arguments(tail).machineName()
            let runtime = try HostRuntime(machine: try store.load(name), directory: try store.directory(name), assets: assets)
            try await runtime.run()
        case "action": try await action(tail)
        case "mcp":
            let args = try Arguments(tail, flags: ["config"])
            let name = try args.machineName()
            if args.flags.contains("config") {
                // Point clients at the launcher, not the versioned bundle, so upgrades keep working.
                let server: [String: Any] = ["command": launcherPath, "args": name == "default" ? ["mcp"] : ["mcp", name]]
                let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["terminal-googlebook": server]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                print(String(decoding: data, as: UTF8.self)); return
            }
            try await AgentServer(store: store, name: name).run()
        case "skills":
            let args = try Arguments(tail, options: ["dir"])
            guard let skill = bundledSkill else { throw Failure("This build has no bundled skill. Reinstall terminal-googlebook.") }
            switch args.positionals {
            case ["get"], []: print(try String(contentsOf: skill, encoding: .utf8), terminator: "")
            case ["path"]: print(skill.path)
            case ["install"]:
                let root = args.options["dir"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
                let destination = root.appendingPathComponent("terminal-googlebook/SKILL.md")
                if let existing = try? String(contentsOf: destination, encoding: .utf8), !existing.contains("\nname: terminal-googlebook\n") {
                    throw Failure("Refusing to replace a different skill at \(destination.path)")
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: skill).write(to: destination, options: .atomic)
                try printJSON(["installed": destination.path])
            default: throw Failure("Usage: terminal-googlebook skills [get|path|install [--dir ~/.claude/skills]]")
            }
        default: throw Failure("Unknown command: \(command). Run terminal-googlebook help.")
        }
    }

    /// Crea la VM si falta (descarga e instala lo necesario) y la deja arrancada.
    func up(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["no-view", "detach", "offline"], options: ["width", "height", "memory", "cpus", "timeout"])
        let name = try args.machineName()
        try store.checkSocketLength(name)
        let directory = try store.directory(name)
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("machine.json").path) {
            let machine = Machine(name: name, cpu: try args.integer("cpus", default: 4, range: 1...32), memoryGiB: try args.integer("memory", default: 4, range: 2...64),
                                  width: try args.integer("width", default: 1280, range: 640...3840), height: try args.integer("height", default: 800, range: 480...2400),
                                  network: !args.flags.contains("offline"))
            if !assets.isInstalled { try install() }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // En APFS es un clon: cada VM ocupa solo lo que cambia respecto a la imagen base.
            let disk = directory.appendingPathComponent("googlebook.raw")
            try FileManager.default.copyItem(at: assets.baseImage.appendingPathComponent("googlebook.raw"), to: disk)
            for file in ["initrd.img", "kernel.Image"] {
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(file), withDestinationURL: assets.baseImage.appendingPathComponent(file))
            }
            try store.save(machine)
        } else if !args.options.isEmpty && args.options.keys.contains(where: { $0 != "timeout" }) || args.flags.contains("offline") {
            throw Failure("VM '\(name)' already exists; its resolution, memory, CPUs and network are fixed when it is created.")
        }
        try await start(name, wait: !args.flags.contains("detach"), timeout: args.integer("timeout", default: 300, range: 1...3600))
    }

    /// Descarga la imagen de Google y arma el disco en esta máquina; nada de eso se redistribuye.
    private func install() throws {
        guard let sources = assets.vmSources else { throw Failure("This build has no VM installer. Reinstall terminal-googlebook.") }
        stderr("Downloading the Googlebook image from Google and assembling the disk. The first time takes about 9 GB and needs 60 GB free…")
        let process = Process()
        process.executableURL = sources.appendingPathComponent("install.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["GOOGLEBOOK_WORK"] = assets.work.path
        process.environment = environment
        process.standardOutput = FileHandle.standardError
        try FileManager.default.createDirectory(at: assets.work, withIntermediateDirectories: true)
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0, assets.isInstalled else { throw Failure("The VM installation failed; see the output above.") }
    }

    func start(_ name: String, wait: Bool, timeout: Int) async throws {
        let directory = try store.directory(name)
        if !Self.isRunning(directory) {
            guard assets.isInstalled else { throw Failure("The VM files are missing from \(assets.work.path). Run: terminal-googlebook up \(name)") }
            let log = directory.appendingPathComponent("runtime.log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["__run", name]
            var environment = ProcessInfo.processInfo.environment
            environment["TERMINAL_GOOGLEBOOK_HOME"] = store.root.path
            process.environment = environment
            process.standardOutput = handle; process.standardError = handle; process.standardInput = FileHandle.nullDevice
            try process.run()
            // El proceso de la VM toma el candado casi de inmediato; si termina antes, falló.
            let deadline = Date().addingTimeInterval(5)
            while !Self.isRunning(directory), Date() < deadline, process.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
            guard Self.isRunning(directory) else { throw Failure("The VM did not start: \(lastLine(log) ?? "no details"). Details: \(log.path)") }
        }
        guard wait else { try printJSON(["name": name, "state": "starting"]); return }
        let deadline = Date().addingTimeInterval(Double(timeout))
        while Date() < deadline {
            guard Self.isRunning(directory) else { throw Failure("The VM stopped while starting. Details: \(directory.path)/runtime.log") }
            if let reply = try? await call(name, Request(action: "status", arguments: ["quick": "true"], timeout: 2)),
               reply.values["bootCompleted"] == "true", reply.values["helperConnected"] == "true" {
                try printJSON(try await call(name, Request(action: "status", timeout: 15)).values)
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw Failure("Android did not finish starting within \(timeout) seconds. Details: \(directory.path)/serial.log")
    }

    private func lastLine(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").last.map(String.init)
    }

    func call(_ name: String, _ request: Request) async throws -> Reply {
        try await Mailbox(store.directory(name).appendingPathComponent("exchange")).call(request)
    }

    func action(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["double"], options: ["x", "y", "text", "key", "url", "button", "count", "output", "timeout"])
        let actions: Set<String> = ["status", "screenshot", "snapshot", "click", "type", "key", "open_url"]
        var positions = args.positionals
        let name: String
        if let first = positions.first, actions.contains(first) { name = "default" }
        else { guard !positions.isEmpty else { throw Failure("Usage: terminal-googlebook action [NAME] screenshot|click|type|key|open_url|status") }; name = positions.removeFirst() }
        try validateName(name)
        _ = try store.load(name)
        guard !positions.isEmpty, actions.contains(positions[0]) else { throw Failure("Unknown or missing guest action") }
        guard Self.isRunning(try store.directory(name)) else { throw Failure("VM '\(name)' is stopped. Start it with: terminal-googlebook start \(name)") }
        let verb = positions.removeFirst()
        var parameters = args.options
        parameters.removeValue(forKey: "output"); parameters.removeValue(forKey: "timeout")
        if verb == "type", !positions.isEmpty { parameters["text"] = positions.joined(separator: " "); positions.removeAll() }
        if verb == "key", positions.count == 1 { parameters["key"] = positions.removeFirst() }
        if verb == "open_url", positions.count == 1 { parameters["url"] = positions.removeFirst() }
        if verb == "click", positions.count == 2 { parameters["x"] = positions.removeFirst(); parameters["y"] = positions.removeFirst() }
        guard positions.isEmpty else { throw Failure("Unexpected action arguments") }
        if args.flags.contains("double") { parameters["double"] = "true" }
        let fallback = verb == "open_url" ? 40 : verb == "type" ? 60 : 15
        let timeout = try args.integer("timeout", default: fallback, range: 1...120)
        let mailbox = try Mailbox(store.directory(name).appendingPathComponent("exchange"))
        let request = Request(action: verb, arguments: parameters, timeout: Double(timeout))
        let imageName = "image-\(request.id.uuidString).png"
        defer { mailbox.remove(imageName) }
        let reply = try await mailbox.call(request)
        var values = reply.values
        if verb == "screenshot" || verb == "snapshot" {
            guard values["image"] == imageName, let png = try mailbox.read(imageName, limit: 32 * 1024 * 1024) else { throw Failure("Invalid image response") }
            let output = URL(fileURLWithPath: ((args.options["output"] ?? "terminal-googlebook-\(name).png") as NSString).expandingTildeInPath)
            try png.write(to: output, options: .atomic)
            values["image"] = output.path
        }
        try printJSON(values)
    }

    /// The agent skill shipped inside the app bundle, so its instructions match this version.
    /// Development builds outside a bundle fall back to the repository copy.
    var bundledSkill: URL? {
        let bundled = executableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/skills/terminal-googlebook/SKILL.md")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        var directory = executableURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("skills/terminal-googlebook/SKILL.md")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }
    /// How the user invoked us, before symlinks: the installer's stable launcher.
    var launcherPath: String {
        let invoked = CommandLine.arguments[0]
        if invoked.contains("/") { return URL(fileURLWithPath: invoked).standardizedFileURL.path }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(invoked)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return executableURL.path
    }
    nonisolated static func isRunning(_ directory: URL) -> Bool {
        let fd = open(directory.appendingPathComponent("runtime.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }
    static let help = """
    terminal-googlebook — a virtual Googlebook for computer-use agents

    up [NAME]                   Download if needed, create and boot a VM (default name: default)
      [--width 1280 --height 800 --memory 4 --cpus 4 --offline]   Fixed when the VM is created
      [--no-view | --detach]    Wait for Android without viewing, or return right away
    start [NAME] [--detach]     Boot an existing VM with no window on the host
    stop [NAME] [--force]       Shut Android down cleanly (or power off immediately)
    status [NAME]               VM, pointer helper and user picker, as JSON
    ls                          List VMs as JSON

    action [NAME] status
    action [NAME] screenshot [--output PATH]
    action [NAME] click X Y [--button right] [--count 2]
    action [NAME] type 'text'
    action [NAME] key ctrl+t
    action [NAME] open_url https://example.com

    mcp [NAME]                  MCP server (stdio) with computer-use tools for agents
      [--config]                Print an mcpServers entry for other MCP clients
    skills get|path|install     The agent skill for this version
      [--dir ~/.claude/skills]

    Every command prints JSON and exits nonzero on failure.
    TERMINAL_GOOGLEBOOK_HOME overrides the data directory.
    """
}

/// The app bundle around the running executable. Bundle.main cannot find it when the CLI is
/// started through the installer's symlink, so versions would fall back to a guess.
let appBundle: Bundle = {
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath()
    return Bundle(url: executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) ?? Bundle.main
}()
var appVersion: String { appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

func printJSON(_ value: [String: String]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

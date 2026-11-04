import CoreGraphics
import Foundation
import ImageIO
import TerminalGooglebookCore
import UniformTypeIdentifiers

/// A Model Context Protocol server over stdio, so agents get computer-use tools for the guest
/// desktop without shelling out: `claude mcp add terminal-googlebook -- /path/to/terminal-googlebook mcp`.
/// It only talks to the VM's host process through its mailbox; it never touches the host desktop.
@MainActor
final class AgentServer {
    let store: Store
    let name: String
    let executable: URL, launcher: String
    init(store: Store, name: String, executable: URL, launcher: String) { self.store = store; self.name = name; self.executable = executable; self.launcher = launcher }

    static let instructions = """
    Controls your own computer: a separate virtual Googlebook, not the user's desktop. Call `start` first: it \
    opens a live view for the user, and says what to tell them. If userPicker is true, take a screenshot and click User (there is no password). For any web task \
    start with `open_url`. Every x/y is a pixel in the latest screenshot (top-left origin). Take \
    another screenshot after actions to check the result. Never add a Google account to this VM.
    """

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static let point: [String: Any] = ["type": "integer", "minimum": 0]
    private static let after: [String: Any] = ["type": "boolean", "description": "Also return a screenshot taken shortly after the action."]
    static let tools: [[String: Any]] = [
        ["name": "start", "description": "Turn on your computer, the virtual Googlebook, and wait until it is ready, about a minute. Opens a terminal window on the user's Mac so they can watch you live, unless one is already open. Does nothing else if it is already on. If setup is missing or running, it says so and what to do.",
         "inputSchema": schema([:])],
        ["name": "screenshot", "description": "Capture the virtual Googlebook's screen. Returns the image and a local PNG path. Coordinates for other tools are pixels in this image.",
         "inputSchema": schema([:]), "annotations": ["readOnlyHint": true]],
        ["name": "click", "description": "Click at a point. clicks: 2 double-clicks.",
         "inputSchema": schema(["x": point, "y": point, "button": ["type": "string", "enum": ["left", "right"]],
                                "clicks": ["type": "integer", "minimum": 1, "maximum": 3], "screenshot": after], required: ["x", "y"])],
        ["name": "move", "description": "Move the pointer to a point, to hover.",
         "inputSchema": schema(["x": point, "y": point, "screenshot": after], required: ["x", "y"])],
        ["name": "drag", "description": "Press at (x, y), drag to (toX, toY) and release.",
         "inputSchema": schema(["x": point, "y": point, "toX": point, "toY": point, "screenshot": after], required: ["x", "y", "toX", "toY"])],
        ["name": "scroll", "description": "Scroll at a point. Negative dy scrolls down, positive dy up; negative dx scrolls right. One wheel notch is 60; try -300 to move a page.",
         "inputSchema": schema(["x": point, "y": point, "dx": ["type": "integer", "minimum": -1000, "maximum": 1000], "dy": ["type": "integer", "minimum": -1000, "maximum": 1000], "screenshot": after], required: ["x", "y"])],
        ["name": "home", "description": "Android Home button.", "inputSchema": schema(["screenshot": after])],
        ["name": "back", "description": "Android Back button.", "inputSchema": schema(["screenshot": after])],
        ["name": "recents", "description": "Android Recents button.", "inputSchema": schema(["screenshot": after])],
        ["name": "type", "description": "Type literal UTF-8 text into the focused field. Use `key` for enter, tab and shortcuts.",
         "inputSchema": schema(["text": ["type": "string"], "screenshot": after], required: ["text"])],
        ["name": "key", "description": "Press a key or chord: enter, esc, tab, backspace, up, down, left, right, ctrl+t, ctrl+l, ctrl+shift+tab, alt+tab. Modifiers: ctrl, alt, shift, meta.",
         "inputSchema": schema(["key": ["type": "string"], "screenshot": after], required: ["key"])],
        ["name": "open_url", "description": "Open an http or https URL in a new Chrome tab. The first step for any web task.",
         "inputSchema": schema(["url": ["type": "string"], "screenshot": after], required: ["url"])],
        ["name": "status", "description": "Report whether the VM is running, Android finished booting, the pointer helper is connected, and whether Android is at the user picker.",
         "inputSchema": schema([:]), "annotations": ["readOnlyHint": true]]
    ]

    func run() async throws {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
            }
            // Notifications have no id and get no reply.
            guard let id = message["id"] else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            switch message["method"] as? String {
            case "initialize":
                send(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "terminal-googlebook", "version": appVersion],
                    "instructions": Self.instructions]])
            case "ping": send(["jsonrpc": "2.0", "id": id, "result": [:]])
            case "tools/list": send(["jsonrpc": "2.0", "id": id, "result": ["tools": Self.tools]])
            case "tools/call":
                let tool = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                do { send(["jsonrpc": "2.0", "id": id, "result": ["content": try await call(tool, arguments)]]) }
                catch { send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": explain(error)]], "isError": true]]) }
            default: send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
        }
    }

    private func call(_ tool: String, _ a: [String: Any]) async throws -> [[String: Any]] {
        func int(_ key: String) throws -> String {
            guard let value = a[key] as? Int ?? (a[key] as? Double).map({ Int($0) }) else { throw Failure("Missing integer '\(key)'") }
            return String(value)
        }
        func string(_ key: String) throws -> String {
            guard let value = a[key] as? String, !value.isEmpty else { throw Failure("Missing '\(key)'") }
            return value
        }
        var requests: [Request] = []
        switch tool {
        case "start": return try await startMachine()
        case "screenshot": return try await screenshot()
        case "status":
            let assets = Assets(store: store, executable: executable)
            if !assets.isInstalled { return [["type": "text", "text": Setup(store: store, assets: assets, launcher: launcher).summary().text]] }
            let reply = try await guest(Request(action: "status", timeout: 15))
            let summary = reply.values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            return [["type": "text", "text": "VM '\(name)' is running.\n" + summary]]
        case "click":
            var arguments = ["x": try int("x"), "y": try int("y"), "count": String(max(1, min(3, a["clicks"] as? Int ?? 1)))]
            if a["button"] as? String == "right" { arguments["button"] = "right" }
            requests = [Request(action: "click", arguments: arguments, timeout: 15)]
        case "move": requests = [Request(action: "move", arguments: ["x": try int("x"), "y": try int("y")], timeout: 15)]
        case "drag": requests = [Request(action: "drag", arguments: ["x": try int("x"), "y": try int("y"), "toX": try int("toX"), "toY": try int("toY")], timeout: 15)]
        case "scroll":
            var arguments = ["x": try int("x"), "y": try int("y")]
            if a["dx"] != nil { arguments["dx"] = try int("dx") }
            if a["dy"] != nil { arguments["dy"] = try int("dy") }
            requests = [Request(action: "scroll", arguments: arguments, timeout: 15)]
        case "home", "back", "recents": requests = [Request(action: tool, timeout: 15)]
        case "type": requests = [Request(action: "type", arguments: ["text": try string("text")], timeout: 60)]
        case "key": requests = [Request(action: "key", arguments: ["key": try string("key")], timeout: 10)]
        case "open_url": requests = [Request(action: "open_url", arguments: ["url": try string("url")], timeout: 40)]
        default: throw Failure("Unknown tool: \(tool)")
        }
        for request in requests { _ = try await guest(request) }
        // Una acción enviada no es una acción con efecto: el guest no confirma lo que hace la interfaz.
        var content: [[String: Any]] = [["type": "text", "text": tool == "open_url"
            ? "Sent to Chrome. Take a screenshot to confirm the page loaded. The first time, Chrome shows setup dialogs: choose Stay signed out and No thanks."
            : "Sent: \(tool). Take a screenshot to confirm the result."]]
        if a["screenshot"] as? Bool == true {
            // Give animations and redraws a moment before looking.
            try await Task.sleep(nanoseconds: 400_000_000)
            content += try await screenshot()
        }
        return content
    }

    private func startMachine() async throws -> [[String: Any]] {
        // La primera vez son 9 GB de descarga: esa decisión es del usuario, no del agente.
        let assets = Assets(store: store, executable: executable)
        guard assets.isInstalled else { return [["type": "text", "text": Setup(store: store, assets: assets, launcher: launcher).summary().text]] }
        // Antes de arrancar: el usuario ve la ventana de inmediato y el viewer espera a la VM.
        let watch = name == "default" ? "\(launcher) view" : "\(launcher) view \(name)"
        let window: String
        switch (try? ViewerWindow.open(name: name, directory: try store.directory(name), launcher: launcher)) ?? .unavailable {
        case .opened(let terminal): window = "A live view opened in \(terminal) on the user's Mac. Tell them they can watch you there, and that Ctrl+] closes it without stopping you."
        case .alreadyOpen: window = "The user's live view is already open."
        case .unavailable: window = "No live view could open here. Tell the user: to watch live, run this in Ghostty, Kitty or iTerm2: \(watch)"
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["up", name, "--no-view"]
        let output = Pipe()
        process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        try process.run()
        let text = await Task.detached { String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }.value
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(text) }
        return [["type": "text", "text": "\(text)\n\(window)"]]
    }

    /// A point-sized screenshot, so image pixels are the coordinates the other tools take.
    /// JPEG keeps the message small; the model sees the same detail at this size.
    private func screenshot() async throws -> [[String: Any]] {
        try requireRunning()
        let mailbox = try exchange()
        let request = Request(action: "screenshot", timeout: 15)
        let imageName = "image-\(request.id.uuidString).png"
        defer { mailbox.remove(imageName) }
        let reply = try await guest(request, mailbox: mailbox)
        guard reply.values["image"] == imageName, let png = try mailbox.read(imageName, limit: 64 * 1024 * 1024),
              let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("The VM returned an invalid screenshot")
        }
        let saved = try store.directory(name).appendingPathComponent("last-screenshot.png")
        try png.write(to: saved, options: .atomic)
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure("Cannot encode screenshot") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot encode screenshot") }
        return [["type": "image", "data": (jpeg as Data).base64EncodedString(), "mimeType": "image/jpeg"],
                ["type": "text", "text": "Screen: \(image.width)×\(image.height). Use these pixel coordinates. PNG: \(saved.path)"]]
    }

    private func exchange() throws -> Mailbox { try Mailbox(store.directory(name).appendingPathComponent("exchange")) }
    private func guest(_ request: Request, mailbox: Mailbox? = nil) async throws -> Reply {
        try requireRunning()
        return try await (mailbox ?? exchange()).call(request)
    }
    /// Checked per call, so the server starts (and lists its tools) before any VM exists.
    private func requireRunning() throws {
        guard (try? store.load(name)) != nil else {
            throw Failure("No virtual Googlebook named '\(name)' exists yet. Call the `start` tool.")
        }
        let directory = try store.directory(name)
        guard CLI.isRunning(directory) else { throw Failure("VM '\(name)' is stopped. Call the `start` tool.") }
    }
    private func explain(_ error: Error) -> String { error.localizedDescription }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(10)
        _ = writeAll(STDOUT_FILENO, data)  // Ver stderr(_:): FileHandle.write abortaría si el cliente ya se fue.
    }
}

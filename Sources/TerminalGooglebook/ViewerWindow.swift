import AppKit
import Foundation

/// Abre el viewer en una ventana nueva de una terminal que pueda mostrarlo.
/// iTerm2 no ejecuta scripts que le llegan por `open`: sin aviso no pasa nada, así que va por AppleScript,
/// y macOS pide el permiso de Automatización la primera vez. Ghostty y Kitty reciben el comando por `open`.
enum ViewerWindow {
    enum Outcome { case opened(String), alreadyOpen, unavailable }

    private static let terminals = [
        (name: "iTerm2", id: "com.googlecode.iterm2", program: "iTerm.app"),
        (name: "Ghostty", id: "com.mitchellh.ghostty", program: "ghostty"),
        (name: "Kitty", id: "net.kovidgoyal.kitty", program: "kitty"),
    ]

    /// Mientras un viewer corre, sostiene este candado: así `start` no abre una ventana por cada llamada.
    static func holdLock(_ directory: URL) {
        _ = Darwin.open(directory.appendingPathComponent("viewer.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
    }

    private static func isOpen(_ directory: URL) -> Bool {
        let fd = Darwin.open(directory.appendingPathComponent("viewer.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    static func open(name: String, directory: URL, launcher: String) throws -> Outcome {
        let env = ProcessInfo.processInfo.environment
        if env["SSH_CONNECTION"] != nil { return .unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if isOpen(directory) { return .alreadyOpen }

        // Primero la terminal donde corre el agente; si no, la primera instalada.
        let installed = terminals.compactMap { terminal in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.id).map { (terminal, $0) }
        }
        guard let (terminal, app) = installed.first(where: { $0.0.program == env["TERM_PROGRAM"] }) ?? installed.first else { return .unavailable }

        var lines = ["#!/bin/bash"]
        if let home = env["TERMINAL_GOOGLEBOOK_HOME"] { lines.append("export TERMINAL_GOOGLEBOOK_HOME=\(quoted(home))") }
        lines.append("exec \(quoted(launcher)) view\(name == "default" ? "" : " " + quoted(name))")
        let script = directory.appendingPathComponent("view.command")
        try (lines.joined(separator: "\n") + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: terminal.name == "iTerm2" ? "/usr/bin/osascript" : "/usr/bin/open")
        switch terminal.name {
        case "iTerm2":
            let command = quoted(script.path).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            process.arguments = ["-e", "tell application \"iTerm\" to create window with default profile command \"\(command)\""]
        case "Ghostty": process.arguments = ["-na", app.path, "--args", "-e", script.path]
        default: process.arguments = ["-na", app.path, "--args", script.path]
        }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? .opened(terminal.name) : .unavailable
    }

    private static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

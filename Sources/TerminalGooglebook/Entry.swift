import Foundation
import TerminalGooglebookCore
import Darwin

@main
struct Entry {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "__run" { _ = setsid() }
        signal(SIGPIPE, SIG_IGN)
        let cli = CLI()
        Task { @MainActor in
            do { try await cli.run(Array(CommandLine.arguments.dropFirst())); exit(0) }
            catch { stderr("terminal-googlebook: \(error.localizedDescription)"); exit(1) }
        }
        CFRunLoopRun()
    }
}

/// No FileHandle.write: lanza una excepción de Objective-C, y aborta, si la terminal o el cliente ya se fueron.
func stderr(_ message: String) { _ = writeAll(STDERR_FILENO, Data((message + "\n").utf8)) }

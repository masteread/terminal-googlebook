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

func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

import XCTest
import Foundation
import Darwin
@testable import TerminalGooglebookCore

final class CoreTests: XCTestCase {
    func testChordsMapToQcodes() throws {
        XCTAssertEqual(try GuestInput.chord("ctrl+t"), ["ctrl", "t"])
        XCTAssertEqual(try GuestInput.chord("enter"), ["ret"])
        XCTAssertEqual(try GuestInput.chord("ESC"), ["esc"])
        XCTAssertEqual(try GuestInput.chord("ctrl+shift+tab"), ["ctrl", "shift", "tab"])
        XCTAssertEqual(try GuestInput.chord("f5"), ["f5"])
        XCTAssertThrowsError(try GuestInput.chord("hyper+t"))
        XCTAssertThrowsError(try GuestInput.chord(""))
    }
    func testTypingSeparatesKeysFromPastedUnicode() {
        XCTAssertEqual(GuestInput.runs("aB1 ?"), [.keys([["a"], ["shift", "b"], ["1"], ["spc"], ["shift", "slash"]])])
        XCTAssertEqual(GuestInput.runs("mañana"), [.keys([["m"], ["a"]]), .paste("ñ"), .keys([["a"], ["n"], ["a"]])])
        XCTAssertEqual(GuestInput.runs("日本"), [.paste("日本")])
        XCTAssertEqual(GuestInput.runs("a\n"), [.keys([["a"], ["ret"]])])
    }
    func testEveryPrintableASCIICharacterHasKeys() {
        for value in 32...126 { XCTAssertNotNil(GuestInput.keys(for: Character(UnicodeScalar(UInt8(value)))), "\(value)") }
    }
    func testOnlyWebURLsCanBeOpened() throws {
        XCTAssertEqual(try GuestInput.validatedURL("https://example.com/a?b=1"), "https://example.com/a?b=1")
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "example.com", "https://a b.com", "https://a.com\nx", "chrome://settings", "https://ñ.com"] {
            XCTAssertThrowsError(try GuestInput.validatedURL(bad), bad)
        }
    }
    func testSetupLockPreventsConcurrentInstallAndReleases() throws {
        let path = try temporary().appendingPathComponent("setup.lock")
        var first: FileLock? = try FileLock(path)
        try withExtendedLifetime(first) { XCTAssertThrowsError(try FileLock(path)) }
        first = nil
        XCTAssertNoThrow(try FileLock(path))
    }
    func testSetupLockRejectsSymlink() throws {
        let root = try temporary()
        let target = root.appendingPathComponent("target")
        try Data().write(to: target)
        let link = root.appendingPathComponent("setup.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try FileLock(link))
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-googlebook-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testMachineNamesCannotEscapeStore() throws {
        for name in ["../host", "/tmp", "", ".", "a/b", "a b", String(repeating: "x", count: 49)] {
            XCTAssertThrowsError(try validateName(name))
        }
        for name in ["default", "agent-1", "gb_test", "M2"] { XCTAssertNoThrow(try validateName(name)) }
    }
    func testParserRejectsUnknownDuplicateAndMissingOptions() throws {
        XCTAssertThrowsError(try Arguments(["--force"], flags: ["offline"]))
        XCTAssertThrowsError(try Arguments(["--disk"], options: ["disk"]))
        XCTAssertThrowsError(try Arguments(["--disk", "4", "--disk", "8"], options: ["disk"]))
        XCTAssertThrowsError(try Arguments(["--disk", "0"], options: ["disk"]).integer("disk", default: 64, range: 32...1024))
        XCTAssertEqual(try Arguments(["--", "--literal"]).positionals, ["--literal"])
    }
    func testMailboxRejectsTraversalSymlinksHardlinksAndOversizedFiles() throws {
        let root = try temporary()
        let mailbox = try Mailbox(root)
        let secret = root.appendingPathComponent("secret")
        try Data("host file".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: secret.path)
        XCTAssertThrowsError(try mailbox.read("link"))
        XCTAssertThrowsError(try mailbox.read("../secret"))
        XCTAssertThrowsError(try mailbox.write(Data(), named: "../escape"))
        XCTAssertThrowsError(try mailbox.read("secret", limit: 1))
        XCTAssertEqual(link(secret.path, root.appendingPathComponent("hardlink").path), 0)
        XCTAssertThrowsError(try mailbox.read("hardlink"))
    }
    func testPublishingReplacesSymlinkInsteadOfWritingItsTarget() throws {
        let root = try temporary()
        let mailbox = try Mailbox(root)
        let target = root.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("reply.json").path, withDestinationPath: target.path)
        try mailbox.write(Data("reply".utf8), named: "reply.json")
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
        XCTAssertEqual(try mailbox.read("reply.json"), Data("reply".utf8))
    }
    func testMailboxRejectsDirectorySymlinkAndNonregularFile() throws {
        let parent = try temporary()
        let actual = parent.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        XCTAssertThrowsError(try Mailbox(alias))
        let mailbox = try Mailbox(actual)
        XCTAssertEqual(mkfifo(actual.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try mailbox.read("pipe"))
    }
    func testExpiredAndMismatchedRequestsAreDiscarded() throws {
        let root = try temporary()
        let mailbox = try Mailbox(root)
        let expired = Request(action: "click", timeout: -1)
        try mailbox.write(JSONEncoder().encode(expired), named: "request-\(expired.id.uuidString).json")
        let valid = Request(action: "status")
        try mailbox.write(JSONEncoder().encode(valid), named: "request-\(UUID().uuidString).json")
        XCTAssertTrue(try mailbox.requests().isEmpty)
    }
    func testRequestReplyRoundTripAndCleanup() async throws {
        let root = try temporary()
        let client = try Mailbox(root)
        let server = try Mailbox(root)
        let request = Request(action: "type", arguments: ["text": "hello 🌍"], timeout: 2)
        let task = Task { try await client.call(request) }
        var received: Request?
        for _ in 0..<50 {
            received = try server.requests().first
            if received != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(received?.arguments["text"], "hello 🌍")
        try server.respond(Reply(id: request.id, values: ["done": "true"]))
        let reply = try await task.value
        XCTAssertEqual(reply.values["done"], "true")
        XCTAssertNil(try client.read("request-\(request.id.uuidString).json"))
        XCTAssertNil(try client.read("reply-\(request.id.uuidString).json"))
    }
    func testMailboxTimeoutCleansPendingAction() async throws {
        let mailbox = try Mailbox(temporary())
        let request = Request(action: "click", timeout: 0.05)
        do { _ = try await mailbox.call(request); XCTFail("Expected timeout") } catch {}
        XCTAssertNil(try mailbox.read("request-\(request.id.uuidString).json"))
    }
    func testInputHandlesFragmentedUnicodeArrowsMouseAndExit() {
        var parser = TerminalInput()
        let emoji = Array("🌍".utf8)
        XCTAssertEqual(parser.feed(Array(emoji.prefix(2))), [])
        XCTAssertEqual(parser.feed(Array(emoji.dropFirst(2))), [.text("🌍")])
        XCTAssertEqual(parser.feed([27, 91]), [])
        XCTAssertEqual(parser.feed([65]), [.key("up")])
        XCTAssertEqual(parser.feed(Array("\u{1b}[<0;12;8M".utf8)), [.mouse(button: 0, column: 12, row: 8, released: false)])
        XCTAssertEqual(parser.feed(Array("\u{1b}[<0;12;8m".utf8)), [.mouse(button: 0, column: 12, row: 8, released: true)])
        XCTAssertEqual(parser.feed([3, 29]), [.key("ctrl+c"), .quit])
    }
    func testEscapeAndUnknownSequencesDoNotBecomeGuestText() {
        var parser = TerminalInput()
        XCTAssertEqual(parser.feed([27]), [])
        XCTAssertEqual(parser.feed([], flushEscape: true), [.key("escape")])
        XCTAssertEqual(parser.feed(Array("\u{1b}[99~".utf8)), [])
        XCTAssertEqual(parser.feed(Array("\u{1b}[<0;0;0M".utf8)), [])
        XCTAssertEqual(parser.feed([255, 65]), [.text("A")])
    }
}

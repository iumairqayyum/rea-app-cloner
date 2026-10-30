import XCTest
@testable import NeatCloneCore

final class NativeBridgeTests: XCTestCase {
    func testRejectsUnsafeRequests() throws {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https://user:pass@example.org/a", "https://example.org/a.ts", "https://example.org/a\n"] {
            XCTAssertThrowsError(try BridgeRequest(url: url).validatedURL())
        }
        XCTAssertThrowsError(try BridgeRequest(version: 2, url: "https://example.org/a").validatedURL())
        XCTAssertThrowsError(try BridgeRequest(url: "https://example.org/a", filename: "../escape").validatedURL())
        XCTAssertEqual(try BridgeRequest(url: "https://example.org/a.mp4?signature=secret").validatedURL().host, "example.org")
    }

    func testFramesAndTruncation() throws {
        let pipe = Pipe()
        try NativeFrame.write(Data("{\"ok\":true}".utf8), to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try NativeFrame.read(from: pipe.fileHandleForReading), Data("{\"ok\":true}".utf8))
        XCTAssertNil(try NativeFrame.read(from: pipe.fileHandleForReading))
        let truncated = Pipe()
        truncated.fileHandleForWriting.write(Data([9, 0, 0, 0, 123]))
        try truncated.fileHandleForWriting.close()
        XCTAssertThrowsError(try NativeFrame.read(from: truncated.fileHandleForReading))
        let oversized = Pipe()
        oversized.fileHandleForWriting.write(Data([1, 0, 1, 0]))
        try oversized.fileHandleForWriting.close()
        XCTAssertThrowsError(try NativeFrame.read(from: oversized.fileHandleForReading))
    }

    func testPrivateInboxRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let entry = InboxEntry(request: BridgeRequest(url: "https://example.org/file.mp4"))
        try entry.write(to: folder)
        let path = folder.appendingPathComponent(entry.id.uuidString + ".json")
        XCTAssertEqual(try JSONDecoder().decode(InboxEntry.self, from: Data(contentsOf: path)).id, entry.id)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

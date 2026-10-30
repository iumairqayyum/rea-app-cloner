import XCTest
@testable import NeatCloneCore

final class DownloadTests: XCTestCase {
    func testURLValidationRejectsCredentialsAndSegments() {
        for raw in ["file:///etc/passwd", "ftp://example.org/file", "https://user:secret@example.org/x", "https://example.org/segment.ts"] {
            XCTAssertThrowsError(try DownloadSafety.validate(URL(string: raw)!))
        }
        XCTAssertNoThrow(try DownloadSafety.validate(URL(string: "https://example.org/video.mp4?token=private")!))
    }
    func testSafeFilenameAndCollisionHandling() {
        let url = URL(string: "https://example.org/master.m3u8")!
        XCTAssertEqual(DownloadSafety.filename("../../unsafe\\name:one", url: url, kind: .direct), "_.._unsafe_name_one")
        XCTAssertEqual(DownloadSafety.filename(nil, url: url, kind: .hls), "master.mp4")
        let dir = URL(fileURLWithPath: "/tmp/not-present-\(UUID().uuidString)")
        let occupied = Set([dir.appendingPathComponent("video.mp4").path])
        XCTAssertEqual(DownloadSafety.uniqueDestination(directory: dir, filename: "video.mp4", occupied: occupied).lastPathComponent, "video (2).mp4")
    }
    func testContentRangeParsing() {
        let value = DirectDownloader.parseRange("bytes 10-19/20")
        XCTAssertEqual(value?.start, 10); XCTAssertEqual(value?.end, 19); XCTAssertEqual(value?.total, 20)
        XCTAssertNil(DirectDownloader.parseRange("bytes 10-19/*"))
        XCTAssertNil(DirectDownloader.parseRange("bytes 10-19/20 trailing"))
        XCTAssertNil(DirectDownloader.parseRange("bytes */20"))
    }
    @MainActor func testInterruptedQueueRecoveryAndInboxIdempotence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let job = DownloadJob(id: id, url: URL(string: "https://example.org/video.mp4")!, kind: .direct,
                              fileName: "video.mp4", destination: root.appendingPathComponent("video.mp4"), status: .downloading)
        let state = root.appendingPathComponent("queue.json")
        try JSONEncoder().encode([job]).write(to: state)
        let queue = try DownloadQueue(stateURL: state)
        XCTAssertEqual(queue.jobs.count, 1); XCTAssertEqual(queue.jobs[0].status, .paused)
        let repeated = try queue.enqueue(url: job.url, directory: root, id: id)
        XCTAssertEqual(repeated, id); XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].status, .paused)
        let permissions = try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    @MainActor func testCorruptQueueIsNotSilentlyOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("queue.json")
        let original = Data("corrupt but preserve".utf8)
        try original.write(to: state)
        XCTAssertThrowsError(try DownloadQueue(stateURL: state))
        XCTAssertEqual(try Data(contentsOf: state), original)
    }
}

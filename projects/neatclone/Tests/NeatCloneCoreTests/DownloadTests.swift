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
    func testNewestFirstAndStableColumnSorting() {
        let url = URL(string: "https://example.org/file")!
        let jobs = [
            DownloadJob(id: UUID(), url: url, kind: .direct, fileName: "zeta.bin", destination: URL(fileURLWithPath: "/tmp/z"), status: .queued, bytes: 5),
            DownloadJob(id: UUID(), url: url, kind: .direct, fileName: "Alpha.bin", destination: URL(fileURLWithPath: "/tmp/a"), status: .queued, bytes: 5),
            DownloadJob(id: UUID(), url: url, kind: .direct, fileName: "middle.bin", destination: URL(fileURLWithPath: "/tmp/m"), status: .queued, bytes: 1)
        ]
        XCTAssertEqual(DownloadOrdering.sorted(jobs).map(\.id), jobs.reversed().map(\.id))
        XCTAssertEqual(DownloadOrdering.sorted(jobs, key: "file", ascending: true).map(\.fileName), ["Alpha.bin", "middle.bin", "zeta.bin"])
        XCTAssertEqual(DownloadOrdering.sorted(jobs, key: "bytes", ascending: true).map(\.fileName), ["middle.bin", "Alpha.bin", "zeta.bin"])
        XCTAssertEqual(Array(DownloadOrdering.sorted(jobs, key: "bytes", ascending: false).map(\.id).prefix(2)), [jobs[1].id, jobs[0].id])
    }
    @MainActor func testRemoveFromListPreservesFileAndConfirmedDeleteRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("queue.json")
        let output = root.appendingPathComponent("keep.bin")
        try Data("keep".utf8).write(to: output)
        let keepID = UUID()
        let kept = DownloadJob(id: keepID, url: URL(string: "https://example.org/keep")!, kind: .direct,
            fileName: "keep.bin", destination: output, status: .paused)
        let deleteURL = root.appendingPathComponent("delete.bin")
        try Data("delete".utf8).write(to: deleteURL)
        let deleteID = UUID()
        let complete = DownloadJob(id: deleteID, url: URL(string: "https://example.org/delete")!, kind: .direct,
            fileName: "delete.bin", destination: deleteURL, status: .completed)
        try JSONEncoder().encode([kept, complete]).write(to: state)
        let queue = try DownloadQueue(stateURL: state)
        try queue.removeFromList(keepID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(queue.jobs.contains(where: { $0.id == keepID }))
        try queue.removeFromList(deleteID, deleteFile: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleteURL.path))
        XCTAssertFalse(queue.jobs.contains(where: { $0.id == deleteID }))
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

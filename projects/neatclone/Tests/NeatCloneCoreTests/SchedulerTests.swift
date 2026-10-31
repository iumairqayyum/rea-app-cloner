import XCTest
@testable import NeatCloneCore

final class SchedulerTests: XCTestCase {
    private func date(_ text:String) -> Date { ISO8601DateFormatter().date(from:text)! }
    func testFixedTimezoneAndOvernightWeekdayWindow() {
        let schedule = QueueSchedule(timeZoneID:"Asia/Karachi",startMinute:22*60,endMinute:2*60,weekdays:[2])
        XCTAssertNotNil(schedule.window(containing:date("2026-11-02T18:00:00Z"))) // Monday 23:00
        XCTAssertNotNil(schedule.window(containing:date("2026-11-02T20:00:00Z"))) // Tuesday01:00 belongs to Monday
        XCTAssertNil(schedule.window(containing:date("2026-11-02T21:00:00Z")))
        XCTAssertEqual(schedule.nextBoundary(after:date("2026-11-02T18:00:00Z")),date("2026-11-02T21:00:00Z"))
    }
    func testSpringGapShiftsToNextValidTimeAndFallRepeatIsSingleWindow() {
        let spring = QueueSchedule(timeZoneID:"America/New_York",startMinute:150,endMinute:240)
        XCTAssertEqual(spring.nextBoundary(after:date("2026-03-08T06:59:00Z")),date("2026-03-08T07:00:00Z"))
        XCTAssertNotNil(spring.window(containing:date("2026-03-08T07:10:00Z")))
        let autumn = QueueSchedule(timeZoneID:"America/New_York",startMinute:90,endMinute:150)
        let first = autumn.window(containing:date("2026-11-01T05:40:00Z"))
        let repeated = autumn.window(containing:date("2026-11-01T06:40:00Z"))
        XCTAssertEqual(first?.start,date("2026-11-01T05:30:00Z"))
        XCTAssertEqual(first,repeated)
    }
    func testMissedOnceWindowIsSkippedRatherThanReplayed() {
        let once = QueueSchedule(start:date("2026-10-31T12:00:00Z"),end:date("2026-10-31T13:00:00Z"))
        XCTAssertNotNil(once.window(containing:date("2026-10-31T12:30:00Z")))
        XCTAssertNil(once.window(containing:date("2026-10-31T14:00:00Z")))
        XCTAssertNil(once.nextBoundary(after:date("2026-10-31T14:00:00Z")))
    }
    func testInvalidAndDisabledSchedulesNeverRun() {
        let bad = QueueSchedule(timeZoneID:"Not/AZone",startMinute:0,endMinute:99)
        XCTAssertFalse(bad.isValid); XCTAssertNil(bad.nextBoundary(after:Date()))
        XCTAssertFalse(QueueSchedule(timeZoneID:"UTC",startMinute:60,endMinute:60).isValid)
        let disabled = DownloadQueueDefinition(name:"Night",enabled:false)
        XCTAssertFalse(disabled.allows(Date()))
    }
    func testExactHTTPSCredentialOriginScoping() throws {
        let scope = try CredentialScope(url:URL(string:"https://EXAMPLE.com:8443/path")!)
        XCTAssertTrue(scope.matches(URL(string:"https://example.com:8443/other")!))
        XCTAssertFalse(scope.matches(URL(string:"https://example.com/other")!))
        XCTAssertFalse(scope.matches(URL(string:"http://example.com:8443/")!))
        XCTAssertFalse(scope.matches(URL(string:"https://sub.example.com:8443/")!))
        XCTAssertThrowsError(try CredentialScope(url:URL(string:"https://user:password@example.com")!))
    }
    @MainActor func testOldJobMigrationAndPersistedNamedQueue() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let state = folder.appendingPathComponent("queue.json")
        let id = UUID()
        let old: [[String:Any]] = [["id":id.uuidString,"url":"https://example.com/a.mp4","kind":"direct","fileName":"a.mp4","destination":folder.appendingPathComponent("a.mp4").absoluteString,"status":"paused","bytes":12,"speed":0]]
        try JSONSerialization.data(withJSONObject:old).write(to:state)
        let queue = try DownloadQueue(stateURL:state)
        XCTAssertEqual(queue.jobs.first?.activeConnections,0)
        XCTAssertNil(queue.jobs.first?.queueID)
        let definition = DownloadQueueDefinition(name:"Night",enabled:false,schedule:QueueSchedule(timeZoneID:"UTC",startMinute:60,endMinute:120))
        try queue.updateQueue(definition); queue.assign(id,to:definition.id)
        let restored = try DownloadQueue(stateURL:state)
        XCTAssertEqual(restored.queues,[definition]); XCTAssertEqual(restored.jobs.first?.queueID,definition.id)
        XCTAssertEqual(restored.jobs.first?.status,.paused)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:state.deletingPathExtension().appendingPathExtension("schedules.json").path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    @MainActor func testQueueDefersNetworkUntilWindowAndStopsAtEnd() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let queue = try DownloadQueue(stateURL:folder.appendingPathComponent("queue.json"))
        let start = Date().addingTimeInterval(0.15), end = start.addingTimeInterval(0.35)
        let definition = DownloadQueueDefinition(name:"One controlled window",schedule:QueueSchedule(start:start,end:end))
        try queue.updateQueue(definition)
        // Port 1 deliberately has no fixture service. The scheduler must not
        // start this permitted request before its explicit start window.
        let id = try queue.enqueue(url:URL(string:"http://127.0.0.1:1/unreachable")!,directory:folder,queueID:definition.id)
        XCTAssertEqual(queue.jobs.first?.status,.queued)
        let deadline = Date().addingTimeInterval(4)
        while queue.jobs.first?.status == .queued && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertEqual(queue.jobs.first?.status,.downloading)
        while Date() < end.addingTimeInterval(0.1) { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertEqual(queue.jobs.first?.status,.queued)
        queue.cancel(id)
        XCTAssertEqual(queue.jobs.first?.status,.cancelled)
    }
}

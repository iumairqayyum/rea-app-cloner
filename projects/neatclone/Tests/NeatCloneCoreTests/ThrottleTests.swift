import XCTest
@testable import NeatCloneCore

final class ThrottleTests: XCTestCase {
    func testSharedMonotonicBudgetDoesNotMultiplyWithConsumers() async throws {
        let limiter = ByteRateLimiter(rate: 65_536)
        let began = ProcessInfo.processInfo.systemUptime
        async let first: Void = limiter.acquire(32_768)
        async let second: Void = limiter.acquire(32_768)
        _ = try await (first, second)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        print("Shared token bucket granted 65536 bytes in \(elapsed) seconds at 65536 B/s")
        XCTAssertGreaterThanOrEqual(elapsed, 0.9); XCTAssertLessThan(elapsed, 2.5)
    }
    func testCancellationAndChangingRateWakeWaiters() async throws {
        let limiter = ByteRateLimiter(rate: 1)
        let blocked = Task { try await limiter.acquire(1_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let began = ProcessInfo.processInfo.systemUptime
        blocked.cancel()
        do { try await blocked.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.25)
        let changed = Task { try await limiter.acquire(1_000_000) }
        await limiter.setRate(nil)
        try await changed.value
    }
}

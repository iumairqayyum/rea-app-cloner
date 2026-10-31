import Foundation

/// FIFO monotonic token bucket. At most 100 ms of tokens may accumulate. One
/// instance shared by all queues enforces the global limit without multiplying
/// the budget by connection count. Sleep is cancellable and no thread blocks.
public actor ByteRateLimiter {
    private var rate: Int64?
    private var tokens: Double = 0
    private var last = ProcessInfo.processInfo.systemUptime
    private var waiters: [UUID] = []
    public init(rate: Int64? = nil) { self.rate = rate.flatMap { $0 > 0 ? $0 : nil } }
    public func setRate(_ value: Int64?) {
        rate = value.flatMap { $0 > 0 ? $0 : nil }
        tokens = 0; last = ProcessInfo.processInfo.systemUptime
    }
    public func acquire(_ count: Int) async throws {
        try Task.checkCancellation()
        guard count > 0, rate != nil else { return }
        let id = UUID(); waiters.append(id)
        defer { waiters.removeAll { $0 == id } }
        var remaining = Double(count)
        while remaining > 0 {
            try Task.checkCancellation()
            guard let rate else { return }
            if waiters.first == id {
                let now = ProcessInfo.processInfo.systemUptime
                tokens = min(max(1, Double(rate) / 10), tokens + max(0, now - last) * Double(rate))
                last = now
                let taken = min(remaining, tokens)
                remaining -= taken; tokens -= taken
                if remaining == 0 { return }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// URLSession invokes data delegates off the main thread. This gate applies the
/// same actor budget before accepting each streamed buffer. Cancellation wakes
/// the permit task; no synchronous wait occurs on the application's main actor.
final class TransferRateGate: @unchecked Sendable {
    let local: ByteRateLimiter?
    let global: ByteRateLimiter?
    init(local: ByteRateLimiter?, global: ByteRateLimiter?) { self.local = local; self.global = global }
    func wait(_ count: Int, cancelled: @escaping @Sendable () -> Bool) throws {
        guard local != nil || global != nil else { return }
        let done = DispatchSemaphore(value: 0)
        let box = PermitResult()
        let permit = Task {
            do { try await local?.acquire(count); try await global?.acquire(count) }
            catch { box.failure = error }
            done.signal()
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            if cancelled() { permit.cancel() }
        }
        if cancelled() { throw CancellationError() }
        if let error = box.failure { throw error }
    }
    private final class PermitResult: @unchecked Sendable { var failure: Error? }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct RangeIdentity: Codable, Equatable {
    var url: URL
    var total: Int64
    var validator: String
}
private struct RangeCheckpoint: Codable {
    var identity: RangeIdentity
    var quantum: Int64
    var completed: Set<Int64>
    var checksums: [String: UInt64]
}

private func rangeChecksum(_ data: Data) -> UInt64 {
    data.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
}

/// A response-bound, bounded-memory read. The server must prove the exact range
/// before any bytes are admitted. Redirects never carry credentials to another
/// origin. No arbitrary URLSession error text is exposed to the UI or logs.
private final class RangeRead: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let expected: (Int64, Int64, RangeIdentity?)
    private let authorization: TransferAuthorization?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    init(start: Int64, end: Int64, identity: RangeIdentity?, authorization: TransferAuthorization?) {
        expected = (start, end, identity); limit = Int(end - start + 1); self.authorization = authorization
    }
    func run(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try DownloadSafety.validate(url)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { c in
                lock.lock(); defer { lock.unlock() }
                if cancelled { c.resume(throwing: CancellationError()); return }
                continuation = c
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
                session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("bytes=\(expected.0)-\(expected.1)", forHTTPHeaderField: "Range")
                request.setValue(expected.2?.validator, forHTTPHeaderField: "If-Range")
                request.setValue(authorization?.header(for: url), forHTTPHeaderField: "Authorization")
                task = session!.dataTask(with: request); task!.resume()
            }
        }, onCancel: {
            self.lock.lock(); self.cancelled = true; self.task?.cancel(); self.lock.unlock()
        })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? DownloadSafety.validate(url)) != nil,
              !(response.url?.scheme == "https" && url.scheme != "https") else { failure = DownloadError.invalidURL; completionHandler(nil); return }
        var next = request
        next.setValue(authorization?.header(for: url), forHTTPHeaderField: "Authorization")
        completionHandler(next)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { failure = DownloadError.transport; completionHandler(.cancel); return }
        self.response = http
        guard http.statusCode == 206,
              let text = http.value(forHTTPHeaderField: "Content-Range"), let parsed = DirectDownloader.parseRange(text),
              parsed.start == expected.0, parsed.end == expected.1, parsed.total > parsed.end,
              http.expectedContentLength == Int64(limit),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            failure = http.statusCode == 206 || http.statusCode == 200 ? DownloadError.invalidRange : DownloadError.http(http.statusCode)
            completionHandler(.cancel); return
        }
        if let identity = expected.2 {
            guard parsed.total == identity.total, Self.validator(http) == identity.validator else {
                failure = DownloadError.invalidRange; completionHandler(.cancel); return
            }
        }
        completionHandler(.allow)
    }
    static func validator(_ response: HTTPURLResponse) -> String? {
        if let etag = response.value(forHTTPHeaderField: "ETag"), etag.hasPrefix("\""), etag.hasSuffix("\"") { return etag }
        if let modified = response.value(forHTTPHeaderField: "Last-Modified") {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if formatter.date(from: modified) != nil { return modified }
        }
        return nil
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= limit else { failure = DownloadError.invalidRange; dataTask.cancel(); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate(); self.session = nil }
        lock.lock(); let wasCancelled = cancelled; let c = continuation; continuation = nil; lock.unlock()
        if wasCancelled { c?.resume(throwing: CancellationError()) }
        else if let failure { c?.resume(throwing: failure) }
        else if error != nil { c?.resume(throwing: DownloadError.transport) }
        else if body.count != limit { c?.resume(throwing: DownloadError.incomplete) }
        else if let response { c?.resume(returning: (body, response)) }
        else { c?.resume(throwing: DownloadError.transport) }
    }
}

/// Work is assigned in small durable quanta rather than fixed file partitions.
/// Fast workers consume more pending ranges. Slow/retried ranges shrink, server
/// failures reduce the connection ceiling, and successful work grows it slowly.
/// Each response is <=512 KiB; no whole-file in-memory stitching occurs.
public struct AdaptiveDownloader {
    public let options: TransferOptions
    public let globalLimiter: ByteRateLimiter?
    public let authorization: TransferAuthorization?
    public init(options: TransferOptions = TransferOptions(), globalLimiter: ByteRateLimiter? = nil, authorization: TransferAuthorization? = nil) {
        self.options = options; self.globalLimiter = globalLimiter; self.authorization = authorization
    }
    public func download(url: URL, destination: URL, workingDirectory: URL,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in },
                         onConnections: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        try DownloadSafety.validate(url)
        let identity: RangeIdentity
        do { identity = try await Self.probe(url, authorization: authorization) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // A failed probe is not license to append partial range bytes. The
            // sequential downloader revalidates/restarts its own independent file.
            onConnections(1); defer { onConnections(0) }
            try await DirectDownloader(limiter: ByteRateLimiter(rate: options.bytesPerSecond), globalLimiter: globalLimiter, authorization: authorization)
                .download(url: url, destination: destination, workingDirectory: workingDirectory, progress: progress)
            return
        }
        let coordinator = try RangeCoordinator(identity: identity, directory: workingDirectory, destination: destination,
            options: options, globalLimiter: globalLimiter, authorization: authorization, progress: progress, onConnections: onConnections)
        try await coordinator.run()
    }
    private static func probe(_ url: URL, authorization: TransferAuthorization?) async throws -> RangeIdentity {
        let (_, response) = try await RangeRead(start: 0, end: 0, identity: nil, authorization: authorization).run(url)
        guard let validator = RangeRead.validator(response),
              let text = response.value(forHTTPHeaderField: "Content-Range"),
              let range = DirectDownloader.parseRange(text), range.total > 0 else { throw DownloadError.invalidRange }
        return RangeIdentity(url: url, total: range.total, validator: validator)
    }
    /// Refresh requires an existing resume manifest, identical validators and
    /// length, and a byte-for-byte match of an already downloaded sample. Merely
    /// having the same filename or size is never sufficient.
    public static func validateRefresh(original: URL, replacement: URL, workingDirectory: URL,
                                       authorization: TransferAuthorization? = nil) async throws {
        try DownloadSafety.validate(replacement)
        let candidate = try await probe(replacement, authorization: authorization)
        let adaptive = workingDirectory.appendingPathComponent("ranges.json")
        if FileManager.default.fileExists(atPath: adaptive.path) {
            var checkpoint = try JSONDecoder().decode(RangeCheckpoint.self, from: Data(contentsOf: adaptive))
            guard checkpoint.identity.url == original, checkpoint.identity.validator == candidate.validator,
                  checkpoint.identity.total == candidate.total, let first = checkpoint.completed.min(), let last = checkpoint.completed.max() else { throw DownloadError.invalidRange }
            let file = try FileHandle(forReadingFrom: workingDirectory.appendingPathComponent("ranges.part")); defer { try? file.close() }
            for index in Set([first, last]) {
                let start = index * checkpoint.quantum
                let end = min(start + min(checkpoint.quantum, 16_384) - 1, candidate.total - 1)
                let (sample, _) = try await RangeRead(start: start, end: end, identity: candidate, authorization: authorization).run(replacement)
                try file.seek(toOffset: UInt64(start))
                guard try file.read(upToCount: sample.count) == sample else { throw DownloadError.invalidRange }
            }
            checkpoint.identity.url = replacement
            try JSONEncoder().encode(checkpoint).write(to: adaptive, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: adaptive.path)
        } else {
            let metadata = workingDirectory.appendingPathComponent("resume.json")
            let data = try Data(contentsOf: metadata)
            guard var record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["url"] as? String == original.absoluteString,
                  record["validator"] as? String == candidate.validator,
                  let total = record["total"] as? NSNumber, total.int64Value == candidate.total else { throw DownloadError.invalidRange }
            let file = try FileHandle(forReadingFrom: workingDirectory.appendingPathComponent("download.part")); defer { try? file.close() }
            let size = try file.seekToEnd()
            guard size > 0, size <= UInt64(candidate.total) else { throw DownloadError.invalidRange }
            let count = min(16_384, Int(size))
            for start in Set([Int64(0), Int64(size) - Int64(count)]) {
                let (sample, _) = try await RangeRead(start: start, end: start + Int64(count) - 1, identity: candidate, authorization: authorization).run(replacement)
                try file.seek(toOffset: UInt64(start))
                guard try file.read(upToCount: count) == sample else { throw DownloadError.invalidRange }
            }
            record["url"] = replacement.absoluteString
            try JSONSerialization.data(withJSONObject: record).write(to: metadata, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        }
    }
}

private actor RangeCoordinator {
    let identity: RangeIdentity
    let directory: URL
    let destination: URL
    let options: TransferOptions
    let limiter: ByteRateLimiter
    let globalLimiter: ByteRateLimiter?
    let authorization: TransferAuthorization?
    let progress: @Sendable (Int64, Int64?) -> Void
    let onConnections: @Sendable (Int) -> Void
    var checkpoint: RangeCheckpoint
    let file: FileHandle
    var inFlight: Set<Int64> = []
    var active = 0
    var ceiling: Int
    var successful = 0
    var desiredQuanta = 8
    var attempts: [Int64: Int] = [:]
    var nextQuantum: Int64 = 0
    var networkActive = 0
    static let quantum: Int64 = 65_536

    init(identity: RangeIdentity, directory: URL, destination: URL, options: TransferOptions,
         globalLimiter: ByteRateLimiter?, authorization: TransferAuthorization?,
         progress: @escaping @Sendable (Int64, Int64?) -> Void, onConnections: @escaping @Sendable (Int) -> Void) throws {
        self.identity = identity; self.directory = directory; self.destination = destination; self.options = options
        self.globalLimiter = globalLimiter; self.authorization = authorization
        self.progress = progress; self.onConnections = onConnections
        limiter = ByteRateLimiter(rate: options.bytesPerSecond)
        ceiling = min(options.maxConnections, max(1, Int((identity.total + Self.quantum - 1) / Self.quantum)))
        guard identity.total <= 512 * 1024 * 1024 * 1024 else { throw DownloadError.invalidRange }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let part = directory.appendingPathComponent("ranges.part"), manifest = directory.appendingPathComponent("ranges.json")
        if let data = try? Data(contentsOf: manifest), let saved = try? JSONDecoder().decode(RangeCheckpoint.self, from: data),
           saved.identity == identity, saved.quantum == Self.quantum,
           let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size]) as? NSNumber,
           size.int64Value == identity.total,
           saved.completed.allSatisfy({ $0 >= 0 && $0 < (identity.total + Self.quantum - 1) / Self.quantum }) {
            checkpoint = saved
            // A checksum is a local corruption detector, not a publisher trust
            // signature. Changed cached quanta are fetched again, never trusted.
            let stored = try FileHandle(forReadingFrom: part); defer { try? stored.close() }
            for index in saved.completed {
                let start = index * Self.quantum, count = Int(min(Self.quantum, identity.total - start))
                try stored.seek(toOffset: UInt64(start))
                let bytes = try stored.read(upToCount: count) ?? Data()
                if bytes.count != count || saved.checksums[String(index)] != rangeChecksum(bytes) {
                    checkpoint.completed.remove(index); checkpoint.checksums.removeValue(forKey: String(index))
                }
            }
        } else {
            checkpoint = RangeCheckpoint(identity: identity, quantum: Self.quantum, completed: [], checksums: [:])
            if !FileManager.default.fileExists(atPath: part.path) { _ = FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let fresh = try FileHandle(forWritingTo: part); try fresh.truncate(atOffset: UInt64(identity.total)); try fresh.close()
        }
        file = try FileHandle(forUpdating: part)
    }
    private var quantumCount: Int64 { (identity.total + Self.quantum - 1) / Self.quantum }
    private var received: Int64 { checkpoint.completed.reduce(0) { $0 + min(Self.quantum, identity.total - $1 * Self.quantum) } }
    private func claim() -> (Int64, Int64)? {
        guard active < ceiling else { return nil }
        while nextQuantum < quantumCount && (checkpoint.completed.contains(nextQuantum) || inFlight.contains(nextQuantum)) { nextQuantum += 1 }
        guard nextQuantum < quantumCount else { return nil }
        let first = nextQuantum
        var last = first
        let count = options.bytesPerSecond == nil ? desiredQuanta : 1
        while last + 1 < quantumCount && last - first + 1 < count,
              !checkpoint.completed.contains(last + 1), !inFlight.contains(last + 1) { last += 1 }
        for index in first...last { inFlight.insert(index) }
        nextQuantum = last + 1
        active += 1
        return (first, last)
    }
    func run() async throws {
        defer { try? file.close(); onConnections(0) }
        progress(received, identity.total)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<ceiling {
                group.addTask { try await self.worker() }
            }
            try await group.waitForAll()
        }
        try Task.checkCancellation()
        guard checkpoint.completed.count == Int(quantumCount) else { throw DownloadError.incomplete }
        try file.synchronize()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DownloadError.destinationExists }
        try FileManager.default.moveItem(at: directory.appendingPathComponent("ranges.part"), to: destination)
        try? FileManager.default.removeItem(at: directory)
    }
    private func worker() async throws {
        while true {
            try Task.checkCancellation()
            guard let (first, last) = claim() else {
                if inFlight.isEmpty { return }
                try await Task.sleep(nanoseconds: 20_000_000); continue
            }
            let start = first * Self.quantum, end = min((last + 1) * Self.quantum, identity.total) - 1
            var startedNetwork = false
            var released = false
            do {
                let began = ProcessInfo.processInfo.systemUptime
                try await limiter.acquire(Int(end - start + 1)); try await globalLimiter?.acquire(Int(end - start + 1))
                networkActive += 1; startedNetwork = true; onConnections(networkActive)
                let (data, _) = try await RangeRead(start: start, end: end, identity: identity, authorization: authorization).run(identity.url)
                networkActive -= 1; startedNetwork = false; onConnections(networkActive)
                try Task.checkCancellation()
                try file.seek(toOffset: UInt64(start)); try file.write(contentsOf: data); try file.synchronize()
                for index in first...last {
                    let relativeStart = Int((index - first) * Self.quantum)
                    let relativeEnd = min(relativeStart + Int(Self.quantum), data.count)
                    checkpoint.checksums[String(index)] = rangeChecksum(data.subdata(in: relativeStart..<relativeEnd))
                    checkpoint.completed.insert(index); inFlight.remove(index)
                }
                active -= 1; released = true
                try saveCheckpoint(); progress(received, identity.total)
                // Slow requests are resegmented into the minimum quantum on the
                // next assignment; fast workers grow to a bounded 512 KiB read.
                desiredQuanta = ProcessInfo.processInfo.systemUptime - began > 1 ? 1 : min(8, desiredQuanta + 1)
                successful += 1
                if successful % 8 == 0 { ceiling = min(options.maxConnections, ceiling + 1) }
            } catch {
                for index in first...last { inFlight.remove(index) }
                nextQuantum = min(nextQuantum, first)
                if startedNetwork { networkActive -= 1; onConnections(networkActive) }
                if !released { active -= 1 }
                desiredQuanta = max(1, desiredQuanta / 2)
                ceiling = max(1, ceiling / 2)
                let retryable: Bool
                switch error as? DownloadError {
                case .transport?, .incomplete?: retryable = true
                case .http(let status)?: retryable = status == 408 || status == 429 || status >= 500
                default: retryable = false
                }
                attempts[first, default: 0] += 1
                if retryable && attempts[first, default: 0] < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempts[first, default: 0]) * 500_000_000)
                    continue
                }
                throw error
            }
        }
    }
    private func saveCheckpoint() throws {
        let path = directory.appendingPathComponent("ranges.json")
        try JSONEncoder().encode(checkpoint).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}

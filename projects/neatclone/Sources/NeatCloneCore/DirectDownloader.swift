import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct ResumeRecord: Codable {
    var url: URL
    var validator: String?
    var total: Int64?
}

/// One streaming HTTP transfer. Partial bytes are retained in the caller's work
/// directory. Only a validated range response may append to an existing file.
public final class DirectDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var failure: Error?
    private var cancelled = false
    private var offset: Int64 = 0
    private var received: Int64 = 0
    private var expected: Int64?
    private var record: ResumeRecord?
    private var work: URL!
    private var destination: URL!
    private var source: URL!
    private var progress: (@Sendable (Int64, Int64?) -> Void)?
    private let rateGate: TransferRateGate
    private let authorization: TransferAuthorization?

    public override convenience init() { self.init(limiter: nil, globalLimiter: nil, authorization: nil) }
    public init(limiter: ByteRateLimiter? = nil, globalLimiter: ByteRateLimiter? = nil, authorization: TransferAuthorization? = nil) {
        self.rateGate = TransferRateGate(local: limiter, global: globalLimiter)
        self.authorization = authorization
        super.init()
    }
    public func download(url: URL, destination: URL, workingDirectory: URL,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws {
        try DownloadSafety.validate(url)
        self.source = url; self.destination = destination; self.work = workingDirectory; self.progress = progress
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)
        let part = work.appendingPathComponent("download.part")
        let meta = work.appendingPathComponent("resume.json")
        if let bytes = try? Data(contentsOf: meta),
           let stored = try? JSONDecoder().decode(ResumeRecord.self, from: bytes), stored.url == url,
           stored.validator != nil {
            record = stored
            offset = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(authorization?.header(for: url), forHTTPHeaderField: "Authorization")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(record?.validator, forHTTPHeaderField: "If-Range")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 24 * 3600
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                continuation = c
                let next = session!.dataTask(with: request)
                task = next
                let shouldCancel = cancelled
                lock.unlock()
                if shouldCancel { next.cancel() }
                next.resume()
            }
        }, onCancel: { self.cancel() })
    }
    public func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? DownloadSafety.validate(url)) != nil,
              !(response.url?.scheme?.lowercased() == "https" && url.scheme?.lowercased() != "https") else {
            failure = DownloadError.invalidURL; completionHandler(nil); return
        }
        var next = request
        next.setValue(authorization?.header(for: url), forHTTPHeaderField: "Authorization")
        completionHandler(next)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw DownloadError.transport }
            if http.statusCode == 416 {
                // A fully fetched but uncommitted or stale partial is restarted;
                // never treat 416 by itself as proof that a file is complete.
                try? FileManager.default.removeItem(at: work.appendingPathComponent("resume.json"))
            }
            guard http.statusCode == 200 || http.statusCode == 206 else { throw DownloadError.http(http.statusCode) }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard encoding == nil || encoding == "identity" else { throw DownloadError.invalidRange }
            let etag = http.value(forHTTPHeaderField: "ETag")
            let validator = etag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
                ?? http.value(forHTTPHeaderField: "Last-Modified")
            if http.statusCode == 206 {
                guard offset > 0,
                      let text = http.value(forHTTPHeaderField: "Content-Range"),
                      let parsed = Self.parseRange(text), parsed.start == offset,
                      parsed.end >= parsed.start, parsed.total > parsed.end,
                      record?.total == nil || record?.total == parsed.total,
                      validator == record?.validator,
                      response.expectedContentLength < 0 || response.expectedContentLength == parsed.end - parsed.start + 1 else {
                    throw DownloadError.invalidRange
                }
                expected = parsed.total
            } else {
                // A server ignoring Range or rejecting If-Range sent a fresh body.
                // Truncate before writing; never append a 200 response.
                offset = 0
                expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            }
            let part = work.appendingPathComponent("download.part")
            if !FileManager.default.fileExists(atPath: part.path) {
                guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw DownloadError.localIO }
            }
            handle = try FileHandle(forWritingTo: part)
            if offset == 0 { try handle?.truncate(atOffset: 0) }
            else { try handle?.seek(toOffset: UInt64(offset)) }
            received = offset
            let next = ResumeRecord(url: source, validator: validator, total: expected)
            try JSONEncoder().encode(next).write(to: work.appendingPathComponent("resume.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: work.appendingPathComponent("resume.json").path)
            progress?(received, expected)
            completionHandler(.allow)
        } catch {
            failure = error
            if error as? DownloadError == .invalidRange {
                // The next explicit retry starts clean rather than looping over bad metadata.
                try? FileManager.default.removeItem(at: work.appendingPathComponent("resume.json"))
            }
            completionHandler(.cancel)
        }
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try rateGate.wait(data.count, cancelled: { self.lock.lock(); defer { self.lock.unlock() }; return self.cancelled })
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            if let expected, received > expected { throw DownloadError.invalidRange }
            progress?(received, expected)
        } catch { failure = DownloadError.localIO; dataTask.cancel() }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.synchronize(); try handle?.close() } catch { failure = DownloadError.localIO }
        lock.lock(); let wasCancelled = cancelled; let c = continuation; continuation = nil; lock.unlock()
        defer { session.finishTasksAndInvalidate(); self.session = nil; self.task = nil }
        if wasCancelled { c?.resume(throwing: CancellationError()); return }
        if let failure { c?.resume(throwing: failure); return }
        if error != nil { c?.resume(throwing: DownloadError.transport); return }
        if let expected, received != expected { c?.resume(throwing: DownloadError.incomplete); return }
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw DownloadError.destinationExists }
            try FileManager.default.moveItem(at: work.appendingPathComponent("download.part"), to: destination)
            try? FileManager.default.removeItem(at: work)
            c?.resume()
        } catch { c?.resume(throwing: (error as? DownloadError) ?? .localIO) }
    }
    public static func parseRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let pattern = #"^bytes ([0-9]+)-([0-9]+)/([0-9]+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let m = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let parts = (1...3).compactMap { Range(m.range(at: $0), in: value).flatMap { Int64(value[$0]) } }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}

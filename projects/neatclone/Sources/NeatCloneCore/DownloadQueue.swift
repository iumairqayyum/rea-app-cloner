import Foundation

/// Main-actor state and a single active transfer. Every transition is persisted;
/// reopening the queue leaves interrupted work paused rather than auto-fetching.
@MainActor public final class DownloadQueue {
    public private(set) var jobs: [DownloadJob]
    public var onChange: (() -> Void)?
    public private(set) var persistenceError: String?
    private let stateURL: URL
    private let ffmpegURL: URL?
    private var active: Task<Void, Never>?
    private var activeID: UUID?
    private var lastSave = Date.distantPast
    private var lastProgressTime = Date()
    private var lastProgressBytes: Int64 = 0

    public init(stateURL: URL, ffmpegURL: URL? = nil) throws {
        self.stateURL = stateURL
        self.ffmpegURL = ffmpegURL
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: stateURL))
            for i in jobs.indices where [.queued, .downloading].contains(jobs[i].status) {
                jobs[i].status = .paused
                jobs[i].speed = 0
            }
        } else { jobs = [] }
        try persist()
    }

    @discardableResult public func enqueue(url: URL, kind: DownloadKind = .direct,
        filename: String? = nil, directory: URL, id: UUID = UUID()) throws -> UUID {
        if jobs.contains(where: { $0.id == id }) { return id }
        try DownloadSafety.validate(url)
        guard directory.isFileURL else { throw DownloadError.unsafeDestination }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = DownloadSafety.filename(filename, url: url, kind: kind)
        let final = DownloadSafety.uniqueDestination(directory: directory, filename: name,
                                                     occupied: Set(jobs.map { $0.destination.path }))
        let job = DownloadJob(id: id, url: url, kind: kind, fileName: final.lastPathComponent,
                              destination: final, status: .queued)
        jobs.append(job)
        do { try persist() } catch { jobs.removeLast(); throw error }
        onChange?()
        startNext()
        return id
    }
    public func pause(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), [.downloading, .queued].contains(jobs[i].status) else { return }
        jobs[i].status = .paused; jobs[i].speed = 0
        if activeID == id { active?.cancel() }
        changed()
    }
    public func resume(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), [.paused, .failed].contains(jobs[i].status) else { return }
        jobs[i].status = .queued; jobs[i].error = nil
        changed(); startNext()
    }
    public func retry(_ id: UUID) { resume(id) }
    public func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status != .completed else { return }
        jobs[i].status = .cancelled; jobs[i].speed = 0
        if activeID == id { active?.cancel() }
        else { try? FileManager.default.removeItem(at: workDirectory(for: jobs[i])) }
        changed()
    }
    private func workDirectory(for job: DownloadJob) -> URL {
        job.destination.deletingLastPathComponent().appendingPathComponent(".neatclone-\(job.id.uuidString)", isDirectory: true)
    }
    private func startNext() {
        guard active == nil, persistenceError == nil,
              let i = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        let job = jobs[i]
        jobs[i].status = .downloading; jobs[i].error = nil
        activeID = job.id; lastProgressTime = Date(); lastProgressBytes = job.bytes
        changed()
        guard persistenceError == nil else { activeID = nil; return }
        active = Task { [weak self] in
            guard let self else { return }
            var finalError: Error?
            for attempt in 0..<3 {
                do {
                    try Task.checkCancellation()
                    let progress: @Sendable (Int64, Int64?) -> Void = { [weak self] bytes, total in
                        Task { @MainActor in self?.update(job.id, bytes: bytes, total: total) }
                    }
                    if job.kind == .direct {
                        try await DirectDownloader().download(url: job.url, destination: job.destination,
                            workingDirectory: self.workDirectory(for: job), progress: progress)
                    } else {
                        let downloader: HLSDownloader
                        if let ffmpegURL = self.ffmpegURL { downloader = HLSDownloader(ffmpeg: ffmpegURL) }
                        else { downloader = HLSDownloader() }
                        try await downloader.download(url: job.url, destination: job.destination,
                            workingDirectory: self.workDirectory(for: job), progress: progress)
                    }
                    finalError = nil; break
                } catch {
                    finalError = error
                    if error is CancellationError || Task.isCancelled { break }
                    // Retry only transient transfers/5xx and inconsistent range metadata.
                    let retryable: Bool
                    if let e = error as? DownloadError {
                        switch e {
                        case .transport, .incomplete, .invalidRange: retryable = true
                        case .http(let code): retryable = [408, 416, 429].contains(code) || code >= 500
                        default: retryable = false
                        }
                    } else if let e = error as? HLSError, case .network(let code) = e {
                        retryable = [408, 429].contains(code) || code >= 500
                    } else if let e = error as? URLError {
                        retryable = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                     .notConnectedToInternet, .dnsLookupFailed].contains(e.code)
                    } else { retryable = false }
                    guard retryable, attempt < 2 else { break }
                    do { try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000) }
                    catch { finalError = CancellationError(); break }
                }
            }
            if let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
                if self.jobs[index].status == .downloading {
                    if let finalError {
                        self.jobs[index].status = finalError is CancellationError ? .paused : .failed
                        // Do not persist raw errors: Foundation errors can include signed URLs.
                        self.jobs[index].error = (finalError as? DownloadError)?.errorDescription
                            ?? (job.kind == .hls ? "HLS transfer failed. Check the authorized playlist and FFmpeg installation; encrypted or unsupported playlists are refused." : DownloadError.transport.errorDescription)
                    } else {
                        self.jobs[index].status = .completed
                        if job.kind == .direct,
                           let size = try? FileManager.default.attributesOfItem(atPath: job.destination.path)[.size] as? NSNumber {
                            self.jobs[index].bytes = size.int64Value
                            self.jobs[index].total = size.int64Value
                        } else if let total = self.jobs[index].total { self.jobs[index].bytes = total }
                    }
                }
                self.jobs[index].speed = 0
                if self.jobs[index].status == .cancelled { try? FileManager.default.removeItem(at: self.workDirectory(for: job)) }
            }
            self.active = nil; self.activeID = nil
            self.changed(); self.startNext()
        }
    }
    private func update(_ id: UUID, bytes: Int64, total: Int64?) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status == .downloading else { return }
        let now = Date(); let elapsed = now.timeIntervalSince(lastProgressTime)
        if elapsed >= 0.2 {
            jobs[i].speed = max(0, Double(bytes - lastProgressBytes) / elapsed)
            lastProgressTime = now; lastProgressBytes = bytes
        }
        jobs[i].bytes = bytes; jobs[i].total = total
        if now.timeIntervalSince(lastSave) > 1 { changed() }
        else { onChange?() }
    }
    private func changed() {
        do { try persist() } catch { persistenceError = DownloadError.localIO.errorDescription }
        onChange?()
    }
    private func persist() throws {
        let data = try JSONEncoder().encode(jobs)
        try data.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        lastSave = Date()
    }
}

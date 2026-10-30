import Foundation

/// Main-actor state and a single active transfer. Every transition is persisted;
/// reopening the queue leaves interrupted work paused rather than auto-fetching.
@MainActor public final class DownloadQueue {
    public private(set) var jobs: [DownloadJob]
    public var onChange: (() -> Void)?
    public private(set) var persistenceError: String?
    private let stateURL: URL
    private let ffmpegURL: URL?
    public private(set) var queues: [DownloadQueueDefinition] = []
    public private(set) var transferOptions = TransferOptions()
    public var authorizationProvider: ((URL) -> TransferAuthorization?)?
    private let globalLimiter = ByteRateLimiter()
    private var scheduleTask: Task<Void, Never>?
    private var lastServedQueue: UUID?
    private var queueStateURL: URL { stateURL.deletingPathExtension().appendingPathExtension("schedules.json") }
    private var active: Task<Void, Never>?
    private var activeID: UUID?
    private var lastSave = Date.distantPast
    private var lastProgressTime = Date()
    private var lastProgressBytes: Int64 = 0

    public init(stateURL: URL, ffmpegURL: URL? = nil) throws {
        self.stateURL = stateURL
        self.ffmpegURL = ffmpegURL
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scheduleURL = stateURL.deletingPathExtension().appendingPathExtension("schedules.json")
        if FileManager.default.fileExists(atPath: scheduleURL.path) {
            queues = try JSONDecoder().decode([DownloadQueueDefinition].self, from: Data(contentsOf: scheduleURL))
        }
        if FileManager.default.fileExists(atPath: stateURL.path) {
            jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: stateURL))
            for i in jobs.indices where [.queued, .downloading].contains(jobs[i].status) {
                jobs[i].status = jobs[i].queueID.flatMap { id in queues.first { $0.id == id } }?.schedule == nil ? .paused : .queued
                jobs[i].speed = 0; jobs[i].activeConnections = 0
            }
        } else { jobs = [] }
        try persist()
        reevaluateSchedule()
    }

    public func configure(options: TransferOptions, globalBytesPerSecond: Int64?) {
        transferOptions = options
        Task { await globalLimiter.setRate(globalBytesPerSecond) }
        onChange?()
    }
    public func updateQueue(_ definition: DownloadQueueDefinition) throws {
        guard !definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              definition.schedule == nil || definition.schedule!.isValid else { throw DownloadError.unsafeDestination }
        let previous = queues
        if let index = queues.firstIndex(where: { $0.id == definition.id }) { queues[index] = definition }
        else { queues.append(definition) }
        do { try persistQueues() } catch { queues = previous; throw error }
        reevaluateSchedule(); onChange?()
    }
    public func removeQueue(_ id: UUID) throws {
        let previous = queues
        queues.removeAll { $0.id == id }
        do { try persistQueues() } catch { queues = previous; throw error }
        for index in jobs.indices where jobs[index].queueID == id { jobs[index].queueID = nil }
        changed(); reevaluateSchedule()
    }
    public func assign(_ id: UUID, to queueID: UUID?) {
        guard queueID == nil || queues.contains(where: { $0.id == queueID }),
              let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status != .completed else { return }
        jobs[index].queueID = queueID
        changed(); reevaluateSchedule()
    }
    public func refreshAddress(_ id: UUID, to replacement: URL) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              [.paused, .failed].contains(jobs[index].status), jobs[index].kind == .direct else { throw DownloadError.invalidURL }
        // Pause's cancellation is asynchronous. Wait for its cleanup before
        // validating/replacing a manifest; never race active random-access writes.
        if activeID == id {
            guard let transfer = active else { throw DownloadError.invalidURL }
            await transfer.value
        }
        guard let index = jobs.firstIndex(where: { $0.id == id }), activeID != id,
              [.paused,.failed].contains(jobs[index].status) else { throw DownloadError.invalidURL }
        let old = jobs[index].url
        try await AdaptiveDownloader.validateRefresh(original: old, replacement: replacement,
            workingDirectory: workDirectory(for: jobs[index]), authorization: authorizationProvider?(replacement))
        // A user may remove/change the job while the validation request is in flight.
        guard let current = jobs.firstIndex(where: { $0.id == id }), activeID != id, jobs[current].url == old else { throw DownloadError.invalidURL }
        jobs[current].url = replacement; jobs[current].error = nil
        changed()
    }
    public func pauseAll() { for job in jobs where [.downloading, .queued].contains(job.status) { pause(job.id) } }
    public func resumeAll() { for job in jobs where [.paused, .failed].contains(job.status) { resume(job.id) } }
    public func reevaluateSchedule(now: Date = Date()) {
        scheduleTask?.cancel(); scheduleTask = nil
        if let id = activeID, let index = jobs.firstIndex(where: { $0.id == id }), !eligible(jobs[index], at: now) {
            jobs[index].status = .queued; jobs[index].speed = 0; active?.cancel(); changed()
        }
        if let next = queues.compactMap({ $0.enabled ? $0.schedule?.nextBoundary(after: now) : nil }).min() {
            let delay = max(0.05, min(next.timeIntervalSince(now), 7 * 86400))
            scheduleTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); try Task.checkCancellation(); self?.reevaluateSchedule() }
                catch { }
            }
        }
        startNext()
    }
    private func eligible(_ job: DownloadJob, at date: Date) -> Bool {
        guard let id = job.queueID else { return true }
        return queues.first(where: { $0.id == id })?.allows(date) ?? false
    }
    private func persistQueues() throws {
        try JSONEncoder().encode(queues).write(to: queueStateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:queueStateURL.path)
    }


    @discardableResult public func enqueue(url: URL, kind: DownloadKind = .direct,
        filename: String? = nil, directory: URL, id: UUID = UUID(), queueID: UUID? = nil) throws -> UUID {
        if jobs.contains(where: { $0.id == id }) { return id }
        try DownloadSafety.validate(url)
        guard queueID == nil || queues.contains(where: { $0.id == queueID }) else { throw DownloadError.unsafeDestination }
        guard directory.isFileURL else { throw DownloadError.unsafeDestination }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = DownloadSafety.filename(filename, url: url, kind: kind)
        let final = DownloadSafety.uniqueDestination(directory: directory, filename: name,
                                                     occupied: Set(jobs.map { $0.destination.path }))
        let job = DownloadJob(id: id, url: url, kind: kind, fileName: final.lastPathComponent,
                              destination: final, status: .queued, queueID: queueID)
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
        guard active == nil, persistenceError == nil else { return }
        let candidates = jobs.indices.filter { jobs[$0].status == .queued && eligible(jobs[$0], at: Date()) }
        guard let i = candidates.first(where: { jobs[$0].queueID != lastServedQueue }) ?? candidates.first else { return }
        let job = jobs[i]
        lastServedQueue = job.queueID
        let options = transferOptions
        let authorization = authorizationProvider?(job.url)
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
                        try await AdaptiveDownloader(options: options, globalLimiter: self.globalLimiter, authorization: authorization)
                            .download(url: job.url, destination: job.destination,
                                workingDirectory: self.workDirectory(for: job), progress: progress,
                                onConnections: { [weak self] count in Task { @MainActor in self?.updateConnections(job.id, count: count) } })
                    } else {
                        let downloader = HLSDownloader(ffmpeg: self.ffmpegURL,
                            limiter: ByteRateLimiter(rate: options.bytesPerSecond),
                            globalLimiter: self.globalLimiter, authorization: authorization)
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
                self.jobs[index].speed = 0; self.jobs[index].activeConnections = 0
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
    private func updateConnections(_ id: UUID, count: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .downloading else { return }
        jobs[index].activeConnections = max(0, count); onChange?()
    }
    private func changed() {
        do { try persist(); persistenceError = nil } catch { persistenceError = DownloadError.localIO.errorDescription }
        onChange?()
    }
    private func persist() throws {
        let data = try JSONEncoder().encode(jobs)
        try data.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        lastSave = Date()
    }
}

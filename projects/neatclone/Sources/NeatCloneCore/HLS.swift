import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum HLSError: Error, LocalizedError {
    case invalidPlaylist, unsupported(String), network(Int), limit, missingFFmpeg, remux
    public var errorDescription: String? {
        switch self {
        case .invalidPlaylist: return "Invalid HLS playlist."
        case .unsupported(let reason): return "Unsupported HLS: \(reason)"
        case .network(let status): return "HLS server returned HTTP \(status). Authorization may be required."
        case .limit: return "HLS safety limit exceeded."
        case .missingFFmpeg: return "Install FFmpeg and set NEATCLONE_FFMPEG to its absolute executable path."
        case .remux: return "FFmpeg could not copy these media streams into MP4. Partial segments are retained."
        }
    }
}

public struct HLSVariant: Equatable {
    public let url: URL
    public let bandwidth: Int
    public let audioGroup: String?
}
public struct HLSSegment: Equatable {
    public let url: URL
    public let duration: Double
}
public struct HLSPlaylist {
    public let variants: [HLSVariant]
    public let audio: [String: URL]
    public let inBandAudio: Set<String>
    public let segments: [HLSSegment]
    public let initialization: URL?

    static func webURL(_ value: String, base: URL) throws -> URL {
        guard !value.contains("{$"), let url = URL(string: value, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { throw HLSError.invalidPlaylist }
        return url
    }

    static func attributes(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        var quoted = false, pieces: [String] = [], part = ""
        for character in text {
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted { pieces.append(part); part = "" } else { part.append(character) }
        }
        pieces.append(part)
        for piece in pieces {
            let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        }
        return values
    }

    public static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        guard text.utf8.count <= 1_048_576 else { throw HLSError.limit }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { throw HLSError.invalidPlaylist }
        var variants: [HLSVariant] = [], segments: [HLSSegment] = [], audio: [String: URL] = [:]
        var inBandAudio: Set<String> = []
        var pendingVariant: [String: String]?, duration: Double?, initialization: URL?, ended = false
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let attributes = attributes(String(line.split(separator: ":", maxSplits: 1)[1]))
                guard attributes["METHOD"] == "NONE" else { throw HLSError.unsupported("encrypted or DRM-protected playlists are refused") }
            } else if ["#EXT-X-BYTERANGE", "#EXT-X-DISCONTINUITY", "#EXT-X-GAP", "#EXT-X-CONTENT-STEERING", "#EXT-X-DEFINE", "#EXT-X-PART", "#EXT-X-SKIP"].contains(where: { line.hasPrefix($0) }) {
                throw HLSError.unsupported("byte ranges, discontinuities, variable/steered URLs and partial/live playlists are not supported in this slice")
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                guard pendingVariant == nil, duration == nil else { throw HLSError.invalidPlaylist }
                pendingVariant = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if attributes["TYPE"] == "AUDIO", let group = attributes["GROUP-ID"] {
                    if let uri = attributes["URI"] {
                        if audio[group] == nil || attributes["DEFAULT"] == "YES" { audio[group] = try webURL(uri, base: baseURL) }
                    } else { inBandAudio.insert(group) }
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard attributes["BYTERANGE"] == nil, let uri = attributes["URI"], initialization == nil, segments.isEmpty else {
                    throw HLSError.unsupported("changing or byte-range initialization maps")
                }
                initialization = try webURL(uri, base: baseURL)
            } else if line.hasPrefix("#EXTINF:") {
                guard duration == nil, let token = line.dropFirst(8).split(separator: ",", maxSplits: 1).first,
                      let value = Double(token), value.isFinite, value > 0, value <= 86400 else { throw HLSError.invalidPlaylist }
                duration = value
            } else if line == "#EXT-X-ENDLIST" {
                ended = true
            } else if !line.hasPrefix("#") {
                let url = try webURL(line, base: baseURL)
                if let attributes = pendingVariant {
                    guard let bandwidth = Int(attributes["BANDWIDTH"] ?? ""), bandwidth > 0 else { throw HLSError.invalidPlaylist }
                    variants.append(HLSVariant(url: url, bandwidth: bandwidth, audioGroup: attributes["AUDIO"]))
                    pendingVariant = nil
                } else if let value = duration {
                    guard !ended else { throw HLSError.invalidPlaylist }
                    segments.append(HLSSegment(url: url, duration: value)); duration = nil
                } else { throw HLSError.invalidPlaylist }
            }
            guard variants.count <= 64, audio.count <= 32, segments.count <= 10_000 else { throw HLSError.limit }
        }
        guard pendingVariant == nil, duration == nil, !(variants.isEmpty && segments.isEmpty), variants.isEmpty || segments.isEmpty else { throw HLSError.invalidPlaylist }
        if variants.isEmpty && !ended { throw HLSError.unsupported("live playlists are not supported; an ENDLIST VOD is required") }
        for variant in variants {
            if let group = variant.audioGroup, audio[group] == nil && !inBandAudio.contains(group) {
                throw HLSError.unsupported("the declared audio rendition group is missing")
            }
        }
        return HLSPlaylist(variants: variants, audio: audio, inBandAudio: inBandAudio, segments: segments, initialization: initialization)
    }
}

// A bounded data delegate prevents a server from allocating an unbounded segment
// or manifest body. Redirects remain HTTP(S); no target code is ever executed.
private final class HLSFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let limit: Int
    var data = Data()
    var response: HTTPURLResponse?
    var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    var session: URLSession?
    var task: URLSessionDataTask?
    private let lock = NSLock()
    private var cancelled = false
    init(limit: Int) { self.limit = limit }
    func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url); request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                task = session.dataTask(with: request); task?.resume()
            }
        }, onCancel: { self.lock.lock(); self.cancelled = true; self.task?.cancel(); self.lock.unlock() })
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        self.response = http
        guard http.statusCode == 200, response.expectedContentLength <= limit else { completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { completionHandler(nil); return }
        guard !(response.url?.scheme == "https" && url.scheme == "http") else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self.data.count + data.count > limit { task?.cancel() } else { self.data.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate(); self.session = nil }
        guard let continuation = continuation else { return }; self.continuation = nil
        if let response = response, response.statusCode != 200 { continuation.resume(throwing: HLSError.network(response.statusCode)) }
        else if let error = error { continuation.resume(throwing: error) }
        else if let response = response { continuation.resume(returning: (data, response)) }
        else { continuation.resume(throwing: HLSError.invalidPlaylist) }
    }
}

private final class HLSProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func stop() {
        lock.lock(); cancelled = true
        if let process = process, process.isRunning {
            process.terminate()
            // A child may inherit a blocked SIGTERM from a concurrency worker.
            // Bound cancellation even then; this PID is only our owned FFmpeg.
            DispatchQueue.global().asyncAfter(deadline:.now() + 1) {
                self.lock.lock(); defer { self.lock.unlock() }
                if self.process === process && process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
        lock.unlock()
    }
    func run(executable: URL, arguments: [String]) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global().async {
                    self.lock.lock()
                    if self.cancelled { self.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    let process = Process(); process.executableURL = executable; process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    self.process = process
                    do { try process.run(); self.lock.unlock(); process.waitUntilExit(); self.lock.lock(); let cancelled = self.cancelled; self.process = nil; self.lock.unlock()
                        if cancelled { continuation.resume(throwing: CancellationError()) }
                        else if process.terminationStatus == 0 { continuation.resume() }
                        else { continuation.resume(throwing: HLSError.remux) }
                    } catch { self.process = nil; self.lock.unlock(); continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.stop() })
    }
}

public struct HLSDownloader {
    public let ffmpeg: URL
    public init(ffmpeg: URL? = nil) {
        let configured = ProcessInfo.processInfo.environment["NEATCLONE_FFMPEG"]
        self.ffmpeg = ffmpeg ?? URL(fileURLWithPath: configured ?? (["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/ffmpeg"))
    }
    public func download(url: URL, destination: URL, workingDirectory: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        guard ffmpeg.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw HLSError.missingFFmpeg }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:workingDirectory.path)
        let root = try await load(url)
        var tracks: [HLSPlaylist] = []
        if let variant = root.variants.max(by: { $0.bandwidth < $1.bandwidth }) {
            let video = try await load(variant.url)
            guard video.variants.isEmpty else { throw HLSError.unsupported("nested master playlists") }
            tracks.append(video)
            if let group = variant.audioGroup, let audio = root.audio[group] {
                let track = try await load(audio)
                guard track.variants.isEmpty else { throw HLSError.unsupported("nested audio master playlists") }
                tracks.append(track)
            }
        } else { tracks = [root] }
        let total = Int64(tracks.reduce(0) { $0 + $1.segments.count + ($1.initialization == nil ? 0 : 1) })
        var completed: Int64 = 0
        var storedBytes: Int64 = 0
        // Never reuse unverifiable stale remote bodies on resume. Completed files
        // from interrupted attempts are replaced by this bounded deterministic pass.
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(track.segments.map(\.duration).max() ?? 1)))\n#EXT-X-MEDIA-SEQUENCE:0\n"
            if let initialization = track.initialization {
                let name = "track\(index)-init.mp4"
                storedBytes += try await save(initialization, to: workingDirectory.appendingPathComponent(name)); completed += 1; progress(completed, total)
                guard storedBytes <= 8 * 1024 * 1024 * 1024 else { throw HLSError.limit }
                playlist += "#EXT-X-MAP:URI=\"\(name)\"\n"
            }
            for (segmentIndex, segment) in track.segments.enumerated() {
                try Task.checkCancellation()
                let name = "track\(index)-segment\(segmentIndex).\(track.initialization == nil ? "ts" : "m4s")"
                storedBytes += try await save(segment.url, to: workingDirectory.appendingPathComponent(name))
                guard storedBytes <= 8 * 1024 * 1024 * 1024 else { throw HLSError.limit }
                playlist += "#EXTINF:\(segment.duration),\n\(name)\n"
                completed += 1; progress(completed, total)
            }
            playlist += "#EXT-X-ENDLIST\n"
            try Data(playlist.utf8).write(to: workingDirectory.appendingPathComponent("track\(index).m3u8"), options: .atomic)
        }
        let output = workingDirectory.appendingPathComponent("remux.mp4")
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        var arguments = ["-nostdin", "-v", "error", "-n"]
        for index in tracks.indices { arguments += ["-protocol_whitelist", "file", "-allowed_extensions", "ALL", "-i", workingDirectory.appendingPathComponent("track\(index).m3u8").path] }
        arguments += tracks.count == 2 ? ["-map", "0:v:0", "-map", "1:a:0"] : ["-map", "0:v:0?", "-map", "0:a:0?"]
        arguments += ["-c", "copy", "-movflags", "+faststart", output.path]
        try Task.checkCancellation()
        try await HLSProcess().run(executable: ffmpeg, arguments: arguments)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: output, to: destination)
        try? FileManager.default.removeItem(at: workingDirectory)
    }
    private func load(_ url: URL) async throws -> HLSPlaylist {
        _ = try HLSPlaylist.webURL(url.absoluteString, base: url)
        let (data, response) = try await HLSFetch(limit: 1_048_576).fetch(url)
        guard let text = String(data: data, encoding: .utf8) else { throw HLSError.invalidPlaylist }
        return try HLSPlaylist.parse(text, baseURL: response.url ?? url)
    }
    private func save(_ url: URL, to path: URL) async throws -> Int64 {
        let (data, _) = try await HLSFetch(limit: 64 * 1024 * 1024).fetch(url)
        guard !data.isEmpty else { throw HLSError.invalidPlaylist }
        try data.write(to: path, options: .atomic)
        return Int64(data.count)
    }
}

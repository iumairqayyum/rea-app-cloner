import Foundation

public enum DownloadKind: String, Codable, Sendable { case direct, hls }
public enum DownloadStatus: String, Codable, Sendable {
    case queued, downloading, paused, completed, failed, cancelled
}
public struct DownloadJob: Codable, Identifiable, Sendable {
    public var id: UUID
    public var url: URL
    public var kind: DownloadKind
    public var fileName: String
    public var destination: URL
    public var status: DownloadStatus
    /// Bytes for direct transfers, completed segments for HLS.
    public var bytes: Int64 = 0
    public var total: Int64? = nil
    public var error: String? = nil
    public var speed: Double = 0
    public var activeConnections: Int = 0
    public var queueID: UUID? = nil
    public var eta: TimeInterval? {
        guard kind == .direct, speed > 0, let total, total >= bytes else { return nil }
        return Double(total - bytes) / speed
    }
    public init(id: UUID, url: URL, kind: DownloadKind, fileName: String, destination: URL,
                status: DownloadStatus, bytes: Int64 = 0, total: Int64? = nil,
                error: String? = nil, speed: Double = 0, activeConnections: Int = 0, queueID: UUID? = nil) {
        self.id = id; self.url = url; self.kind = kind; self.fileName = fileName
        self.destination = destination; self.status = status; self.bytes = bytes
        self.total = total; self.error = error; self.speed = speed
        self.activeConnections = activeConnections; self.queueID = queueID
    }
    private enum CodingKeys: String, CodingKey {
        case id, url, kind, fileName, destination, status, bytes, total, error, speed, activeConnections, queueID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); url = try c.decode(URL.self, forKey: .url)
        kind = try c.decode(DownloadKind.self, forKey: .kind); fileName = try c.decode(String.self, forKey: .fileName)
        destination = try c.decode(URL.self, forKey: .destination); status = try c.decode(DownloadStatus.self, forKey: .status)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        total = try c.decodeIfPresent(Int64.self, forKey: .total); error = try c.decodeIfPresent(String.self, forKey: .error)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 0
        activeConnections = try c.decodeIfPresent(Int.self, forKey: .activeConnections) ?? 0
        queueID = try c.decodeIfPresent(UUID.self, forKey: .queueID)
    }
    public var progress: Double? { total.flatMap { $0 > 0 ? min(1, Double(bytes) / Double($0)) : nil } }
}
public enum DownloadError: Error, Equatable, LocalizedError {
    case invalidURL, unsafeDestination, http(Int), invalidRange, incomplete, localIO, transport, destinationExists
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use an HTTP or HTTPS URL without embedded credentials. TS segments are not full videos."
        case .unsafeDestination: return "Choose a writable destination directory."
        case .http(let code):
            if code == 403 { return "Server refused this request (HTTP 403). Check its published access or size limits; NeatClone will not bypass the denial." }
            return "Server returned HTTP \(code). Renew the authorized URL if it expired."
        case .invalidRange: return "The server returned an inconsistent byte range; retry from the beginning."
        case .incomplete: return "The response ended before all expected bytes arrived."
        case .localIO: return "Cannot write the download or queue state. Check disk space and permissions."
        case .transport: return "Network transfer failed. Check connectivity, then retry."
        case .destinationExists: return "The destination already exists. Choose a different filename."
        }
    }
}
public enum DownloadSafety {
    public static func validate(_ url: URL, allowSegment: Bool = false) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              !url.absoluteString.contains("\r"), !url.absoluteString.contains("\n"),
              allowSegment || !["ts", "m2ts"].contains(url.pathExtension.lowercased()) else {
            throw DownloadError.invalidURL
        }
    }
    public static func filename(_ proposed: String?, url: URL, kind: DownloadKind) -> String {
        let raw = proposed?.isEmpty == false ? proposed! : url.lastPathComponent
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var value = raw.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        while value.utf8.count > 180 { value.removeLast() }
        if value.isEmpty { value = "download" }
        if kind == .hls { value = (value as NSString).deletingPathExtension + ".mp4" }
        return value
    }
    public static func uniqueDestination(directory: URL, filename: String, occupied: Set<String>) -> URL {
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var result = directory.appendingPathComponent(filename)
        var index = 2
        while FileManager.default.fileExists(atPath: result.path) || occupied.contains(result.path) {
            result = directory.appendingPathComponent(stem + " (\(index))" + (ext.isEmpty ? "" : "." + ext))
            index += 1
        }
        return result
    }
}

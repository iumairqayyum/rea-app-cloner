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
    public var progress: Double? { total.flatMap { $0 > 0 ? min(1, Double(bytes) / Double($0)) : nil } }
}
public enum DownloadError: Error, Equatable, LocalizedError {
    case invalidURL, unsafeDestination, http(Int), invalidRange, incomplete, localIO, transport, destinationExists
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use an HTTP or HTTPS URL without embedded credentials. TS segments are not full videos."
        case .unsafeDestination: return "Choose a writable destination directory."
        case .http(let code): return "Server returned HTTP \(code). Renew the authorized URL if it expired."
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

import Foundation

public enum BridgeFailure: Error { case malformed, unsupported, invalidURL, invalidName, oversized, truncated }

public struct BridgeRequest: Codable {
    public var version: Int
    public var action: String
    public var url: String
    public var kind: String
    public var filename: String?
    public var pageURL: String?

    public init(version: Int = 1, action: String = "enqueue", url: String, kind: String = "direct", filename: String? = nil, pageURL: String? = nil) {
        self.version = version; self.action = action; self.url = url
        self.kind = kind; self.filename = filename; self.pageURL = pageURL
    }

    public func validatedURL() throws -> URL {
        guard version == 1, action == "enqueue", ["direct", "hls"].contains(kind) else { throw BridgeFailure.unsupported }
        let result = try Self.webURL(url)
        if let pageURL { _ = try Self.webURL(pageURL) }
        guard result.pathExtension.lowercased() != "ts" else { throw BridgeFailure.unsupported }
        if let filename {
            guard !filename.isEmpty, filename.utf8.count <= 180,
                  filename != ".", filename != "..",
                  !filename.contains("/"), !filename.contains("\\"), !filename.contains(":"),
                  !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw BridgeFailure.invalidName }
        }
        return result
    }

    static func webURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 8192,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { throw BridgeFailure.invalidURL }
        return url
    }
}

public struct InboxEntry: Codable {
    public let id: UUID
    public let request: BridgeRequest
    public init(id: UUID = UUID(), request: BridgeRequest) { self.id = id; self.request = request }

    public func write(to directory: URL) throws {
        _ = try request.validatedURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(id.uuidString + ".json")
        try JSONEncoder().encode(self).write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}

public enum NativeFrame {
    public static let limit = 65_536
    public static func read(from handle: FileHandle) throws -> Data? {
        func exact(_ count: Int, allowEOF: Bool = false) throws -> Data? {
            var bytes = Data()
            while bytes.count < count {
                guard let next = try handle.read(upToCount: count - bytes.count), !next.isEmpty else {
                    if allowEOF && bytes.isEmpty { return nil }
                    throw BridgeFailure.truncated
                }
                bytes.append(next)
            }
            return bytes
        }
        guard let header = try exact(4, allowEOF: true) else { return nil }
        let count = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        guard count > 0, count <= limit else { throw BridgeFailure.oversized }
        return try exact(Int(count))
    }

    public static func write(_ data: Data, to handle: FileHandle) throws {
        guard !data.isEmpty, data.count <= limit else { throw BridgeFailure.oversized }
        let count = UInt32(data.count)
        let header = Data((0..<4).map { UInt8((count >> ($0 * 8)) & 255) })
        try handle.write(contentsOf: header + data)
    }
}

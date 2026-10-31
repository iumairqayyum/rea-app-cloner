import Foundation

public struct TransferOptions: Codable, Sendable, Equatable {
    public var maxConnections: Int
    public var bytesPerSecond: Int64?
    public init(maxConnections: Int = 8, bytesPerSecond: Int64? = nil) {
        self.maxConnections = min(32, max(1, maxConnections))
        self.bytesPerSecond = bytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Ephemeral authorization supplied by a user-consented, domain-scoped store.
/// Never encoded into resume manifests or passed to another origin on redirect.
public struct TransferAuthorization: Sendable {
    public let host: String
    public let value: String
    public let port: Int
    public init(host: String, value: String, port: Int? = nil) { self.host = host.lowercased(); self.value = value; self.port = port ?? 443 }
    func header(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == host,
              (url.port ?? 443) == port,
              !value.contains("\r"), !value.contains("\n") else { return nil }
        return value
    }
}

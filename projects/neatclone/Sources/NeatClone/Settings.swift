import Foundation

/// Non-secret preferences only. Credentials belong to the platform Keychain adapter.
struct AppSettings: Equatable {
    static let connectionChoices = Array(1...32)
    var maxConnections: Int = 8
    var perDownloadBytesPerSecond: Int64? = nil
    var globalBytesPerSecond: Int64? = nil
    var notifyResults = false
    var destination: String? = nil

    init() {}
    init(defaults: UserDefaults) {
        let configured = defaults.integer(forKey: "neatclone.maxConnections")
        maxConnections = Self.connectionChoices.contains(configured) ? configured : 8
        perDownloadBytesPerSecond = Self.positiveRate(defaults.string(forKey: "neatclone.perDownloadRate"))
        globalBytesPerSecond = Self.positiveRate(defaults.string(forKey: "neatclone.globalRate"))
        notifyResults = defaults.bool(forKey: "neatclone.notifyResults")
        destination = defaults.string(forKey: "destination")
    }
    func save(to defaults: UserDefaults) {
        defaults.set(Self.connectionChoices.contains(maxConnections) ? maxConnections : 8, forKey: "neatclone.maxConnections")
        defaults.set(perDownloadBytesPerSecond.map(String.init), forKey: "neatclone.perDownloadRate")
        defaults.set(globalBytesPerSecond.map(String.init), forKey: "neatclone.globalRate")
        defaults.set(notifyResults, forKey: "neatclone.notifyResults")
        defaults.set(destination, forKey: "destination")
    }
    static func positiveRate(_ text: String?) -> Int64? {
        guard let text, let value = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }
    static func rateFromKiB(_ text: String) throws -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "0" { return nil }
        guard let value = Int64(trimmed), value > 0, value <= Int64.max / 1024 else { throw SettingsError.invalidRate }
        return value * 1024
    }
    enum SettingsError: Error { case invalidRate }
}

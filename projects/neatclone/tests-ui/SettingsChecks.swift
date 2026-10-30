import Foundation

@main enum SettingsChecks {
    static func main() throws {
        let name = "org.neatclone.settings-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        precondition(AppSettings(defaults: defaults).maxConnections == 8)
        var settings = AppSettings()
        settings.maxConnections = 24
        settings.perDownloadBytesPerSecond = try AppSettings.rateFromKiB("512")
        settings.globalBytesPerSecond = try AppSettings.rateFromKiB("2048")
        settings.notifyResults = true
        settings.destination = "/tmp/NeatClone"
        settings.save(to: defaults)
        precondition(AppSettings(defaults: defaults) == settings)
        defaults.set(99, forKey: "neatclone.maxConnections")
        precondition(AppSettings(defaults: defaults).maxConnections == 8)
        let unlimited = try AppSettings.rateFromKiB("0")
        let empty = try AppSettings.rateFromKiB("")
        precondition(unlimited == nil && empty == nil)
        for invalid in ["-1", "1.25", "oops", String(Int64.max)] {
            do { _ = try AppSettings.rateFromKiB(invalid); fatalError("Accepted invalid rate") }
            catch AppSettings.SettingsError.invalidRate {}
        }
        print("PASS: settings defaults, round trip, supported connection ceiling, unlimited and invalid rate handling")
    }
}

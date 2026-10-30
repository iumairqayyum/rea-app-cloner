import Foundation

/// Calendar windows have a fixed user-selected timezone, not the process zone.
/// Missing DST times move to the next valid local time; repeated times use the
/// first occurrence. Missed windows are skipped rather than replayed in a burst.
public struct QueueSchedule: Codable, Equatable, Sendable {
    public var timeZoneID: String
    public var startMinute: Int
    public var endMinute: Int
    /// Calendar weekday numbers: Sunday=1 through Saturday=7.
    public var weekdays: [Int]
    public var oneShotStart: Date?
    public var oneShotEnd: Date?

    public init(timeZoneID: String, startMinute: Int, endMinute: Int, weekdays: [Int] = Array(1...7)) {
        self.timeZoneID = timeZoneID; self.startMinute = startMinute; self.endMinute = endMinute
        self.weekdays = weekdays; oneShotStart = nil; oneShotEnd = nil
    }
    public init(start: Date, end: Date) {
        timeZoneID = "UTC"; startMinute = 0; endMinute = 0; weekdays = []
        oneShotStart = start; oneShotEnd = end
    }
    public var isValid: Bool {
        if let start = oneShotStart, let end = oneShotEnd { return end > start && end.timeIntervalSince(start) <= 7 * 86400 }
        return oneShotStart == nil && oneShotEnd == nil && TimeZone(identifier: timeZoneID) != nil
            && (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute)
            && startMinute != endMinute && !weekdays.isEmpty && weekdays.allSatisfy { (1...7).contains($0) }
    }
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)!; return c
    }
    private func localTime(_ minute: Int, day: Date, calendar c: Calendar) -> Date? {
        let midnight = c.startOfDay(for: day)
        let matching = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
        guard let date = c.nextDate(after: midnight.addingTimeInterval(-1), matching: matching,
                                  matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
              c.isDate(date, inSameDayAs: day) else { return nil }
        return date
    }
    private func interval(startingOn day: Date) -> DateInterval? {
        let c = calendar
        guard weekdays.contains(c.component(.weekday, from: day)),
              let start = localTime(startMinute, day: day, calendar: c),
              let endDay = c.date(byAdding: .day, value: endMinute < startMinute ? 1 : 0, to: day),
              let end = localTime(endMinute, day: endDay, calendar: c), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
    public func window(containing now: Date) -> DateInterval? {
        guard isValid else { return nil }
        if let start = oneShotStart, let end = oneShotEnd { return start <= now && now < end ? DateInterval(start: start, end: end) : nil }
        let c = calendar
        for offset in [-1, 0] {
            if let day = c.date(byAdding: .day, value: offset, to: now), let interval = interval(startingOn: day), interval.start <= now && now < interval.end { return interval }
        }
        return nil
    }
    public func nextBoundary(after now: Date) -> Date? {
        guard isValid else { return nil }
        if let active = window(containing: now) { return active.end }
        if let start = oneShotStart { return start > now ? start : nil }
        let c = calendar
        return (0...8).compactMap { offset -> Date? in
            guard let day = c.date(byAdding: .day, value: offset, to: now), let interval = interval(startingOn: day), interval.start > now else { return nil }
            return interval.start
        }.min()
    }
}

public struct DownloadQueueDefinition: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var schedule: QueueSchedule?
    public init(id: UUID = UUID(), name: String, enabled: Bool = true, schedule: QueueSchedule? = nil) {
        self.id = id; self.name = String(name.prefix(80)); self.enabled = enabled; self.schedule = schedule
    }
    public func allows(_ date: Date) -> Bool { enabled && (schedule == nil || schedule?.window(containing: date) != nil) }
}

/// Exact HTTPS origin matching is shared with Keychain lookup. No password or
/// authorization material is stored in this value, UserDefaults, or queue JSON.
public struct CredentialScope: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public init(url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { throw DownloadError.invalidURL }
        self.host = host; self.port = url.port ?? 443
    }
    public var key: String { "https://\(host):\(port)" }
    public func matches(_ url: URL) -> Bool { (try? CredentialScope(url: url)) == self }
}

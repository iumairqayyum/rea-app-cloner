import Foundation

/// Stable table ordering. Persisted queue order is enqueue order, so reversing it
/// gives a useful newest-first history until the user chooses a column.
public enum DownloadOrdering {
    public static func sorted(_ jobs: [DownloadJob], key: String? = nil, ascending: Bool = true,
                              queueNames: [UUID: String] = [:]) -> [DownloadJob] {
        guard let key else { return Array(jobs.reversed()) }
        let insertion = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($0.element.id, $0.offset) })
        return jobs.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch key {
            case "progress": comparison = compare(lhs.progress ?? -1, rhs.progress ?? -1)
            case "bytes": comparison = compare(Double(lhs.bytes), Double(rhs.bytes))
            case "speed": comparison = compare(lhs.speed, rhs.speed)
            case "eta": comparison = compare(lhs.eta ?? .infinity, rhs.eta ?? .infinity)
            case "connections": comparison = compare(Double(lhs.activeConnections), Double(rhs.activeConnections))
            case "state": comparison = lhs.status.rawValue.localizedStandardCompare(rhs.status.rawValue)
            case "queue": comparison = queueName(lhs, names: queueNames).localizedStandardCompare(queueName(rhs, names: queueNames))
            default: comparison = lhs.fileName.localizedStandardCompare(rhs.fileName)
            }
            if comparison == .orderedSame { return insertion[lhs.id, default: 0] > insertion[rhs.id, default: 0] }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private static func compare(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }

    private static func queueName(_ job: DownloadJob, names: [UUID: String]) -> String {
        job.queueID.flatMap { names[$0] } ?? "Unassigned"
    }
}

import Foundation

@MainActor public extension DownloadQueue {
    /// Both AppKit and the portable integration harness use the same importer.
    /// Enqueue persists the receipt UUID before its inbox file is removed. A
    /// crash between those operations cannot enqueue the same receipt twice.
    func importInbox(from inbox: URL, directory: URL) throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: inbox.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        var ids: [UUID] = []
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(100) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= NativeFrame.limit else { throw BridgeFailure.malformed }
            let entry = try JSONDecoder().decode(InboxEntry.self, from: Data(contentsOf: file))
            guard file.deletingPathExtension().lastPathComponent == entry.id.uuidString else { throw BridgeFailure.malformed }
            let url = try entry.request.validatedURL()
            let id = try enqueue(url: url, kind: entry.request.kind == "hls" ? .hls : .direct, filename: entry.request.filename, directory: directory, id: entry.id)
            try FileManager.default.removeItem(at: file)
            ids.append(id)
        }
        return ids
    }
}

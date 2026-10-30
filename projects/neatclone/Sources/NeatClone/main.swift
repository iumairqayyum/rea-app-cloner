#if os(macOS)
import AppKit
import NeatCloneCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var queue: DownloadQueue!
    private let table = NSTableView()
    private let urlField = NSTextField()
    private let filenameField = NSTextField()
    private let message = NSTextField(labelWithString: "Ready. Add a URL or send one from Chrome.")
    private let folderLabel = NSTextField(labelWithString: "")
    private let hls = NSButton(checkboxWithTitle: "Unencrypted HLS → MP4", target: nil, action: nil)
    private var timer: Timer?
    private var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("NeatClone", isDirectory: true)
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeatClone", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let path = UserDefaults.standard.string(forKey: "destination") { destination = URL(fileURLWithPath: path, isDirectory: true) }
            let candidates = ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]
            let ffmpeg = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            queue = try DownloadQueue(stateURL: support.appendingPathComponent("queue.json"), ffmpegURL: ffmpeg)
            createWindow()
            queue.onChange = { [weak self] in
                self?.table.reloadData()
                if self?.queue.persistenceError != nil { self?.message.stringValue = "History could not be saved. Check disk access before adding more downloads." }
            }
            importInbox()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.importInbox() }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "NeatClone could not open its download history."
            alert.informativeText = "Check access to your Application Support folder. Existing history was not overwritten."
            alert.runModal(); NSApp.terminate(nil)
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "NeatClone — Downloads"; window.minSize = NSSize(width: 800, height: 460)
        urlField.placeholderString = "https://example.com/video.mp4"
        filenameField.placeholderString = "Optional file name"
        urlField.target = self; urlField.action = #selector(addDownload)
        let add = button("Add to queue", #selector(addDownload)); add.keyEquivalent = "\r"
        let inputs = NSStackView(views: [urlField, filenameField, hls, add]); inputs.spacing = 8
        urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        filenameField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        folderLabel.stringValue = destination.path; folderLabel.lineBreakMode = .byTruncatingMiddle
        let folderRow = NSStackView(views: [NSTextField(labelWithString: "Save to:"), folderLabel, button("Choose…", #selector(chooseFolder))]); folderRow.spacing = 8
        let actions = NSStackView(views: [button("Pause", #selector(pause)), button("Resume", #selector(resume)), button("Retry", #selector(retry)), button("Cancel", #selector(cancel)), button("Show file", #selector(showFile))]); actions.spacing = 8
        for (id, title, width) in [("file", "File", 300.0), ("state", "Status", 130.0), ("progress", "Progress", 100.0), ("bytes", "Received", 130.0), ("speed", "Speed", 110.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 30
        table.allowsMultipleSelection = false
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let root = NSStackView(views: [inputs, folderRow, actions, scroll, message]); root.orientation = .vertical
        root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(); window.contentView = view; view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 18), root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18), root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            inputs.widthAnchor.constraint(equalTo: root.widthAnchor), folderRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250)
        ])
        let menu = NSMenu(); let app = NSMenuItem(); menu.addItem(app)
        let submenu = NSMenu(); submenu.addItem(withTitle: "Quit NeatClone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); app.submenu = submenu
        NSApp.mainMenu = menu
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let selected = panel.url {
            destination = selected; folderLabel.stringValue = selected.path
            UserDefaults.standard.set(selected.path, forKey: "destination")
        }
    }

    @objc private func addDownload() {
        let request = BridgeRequest(url: urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), kind: hls.state == .on ? "hls" : "direct", filename: filenameField.stringValue.isEmpty ? nil : filenameField.stringValue)
        do {
            let url = try request.validatedURL()
            _ = try queue.enqueue(url: url, kind: hls.state == .on ? .hls : .direct, filename: request.filename, directory: destination)
            urlField.stringValue = ""; filenameField.stringValue = ""; message.stringValue = "Added to queue."
        } catch { message.stringValue = "Could not add this request. Use an HTTP(S) URL and a safe file name." }
    }

    private func importInbox() {
        let inbox = support.appendingPathComponent("Inbox", isDirectory: true)
        do {
            let imported = try queue.importInbox(from: inbox, directory: destination)
            if !imported.isEmpty { message.stringValue = "Chrome request added to queue." }
        } catch { message.stringValue = "A browser request could not be imported; it remains in the private inbox." }
    }

    private func selected() -> UUID? { table.selectedRow >= 0 && table.selectedRow < queue.jobs.count ? queue.jobs[table.selectedRow].id : nil }
    @objc private func pause() { if let id = selected() { queue.pause(id) } }
    @objc private func resume() { if let id = selected() { queue.resume(id) } }
    @objc private func retry() { if let id = selected() { queue.retry(id) } }
    @objc private func cancel() { if let id = selected() { queue.cancel(id) } }
    @objc private func showFile() {
        if let id = selected(), let job = queue.jobs.first(where: { $0.id == id }), job.status == .completed { NSWorkspace.shared.activateFileViewerSelecting([job.destination]) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { queue?.jobs.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let job = queue.jobs[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "file": text = job.fileName
        case "state": text = job.error ?? job.status.rawValue.capitalized
        case "progress": text = job.progress.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
        case "bytes": text = job.kind == .hls ? "\(job.bytes) segments" : ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file)
        case "speed": text = job.status == .downloading ? (job.kind == .hls ? String(format: "%.1f segments/s", job.speed) : ByteCountFormatter.string(fromByteCount: Int64(max(0, job.speed)), countStyle: .file) + "/s") : "—"
        default: text = ""
        }
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = text; return label
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window?.makeKeyAndOrderFront(nil); return true }
}

@main struct NeatCloneMain {
    @MainActor static func main() {
        let app = NSApplication.shared; let delegate = AppDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#else
import Foundation
@main struct NeatCloneMain {
    static func main() {
        FileHandle.standardError.write(Data("NeatClone's AppKit interface requires macOS 12 or later. Use NeatCloneCLI for portable core tests.\n".utf8))
        exit(78)
    }
}
#endif

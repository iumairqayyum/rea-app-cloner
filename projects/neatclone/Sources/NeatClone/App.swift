#if os(macOS)
import AppKit
import NeatCloneCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    private var window: NSWindow!
    private var queue: DownloadQueue!
    private var platform: MacIntegration!
    private let table = DownloadTableView()
    private let urlField = NSTextField()
    private let filenameField = NSTextField()
    private let search = NSSearchField()
    private let filter = NSPopUpButton()
    private let message = NSTextField(labelWithString: "Ready. Add an authorized URL or send one from Chrome.")
    private let folderLabel = NSTextField(labelWithString: "")
    private let hls = NSButton(checkboxWithTitle: "Unencrypted HLS → MP4", target: nil, action: nil)
    private var inboxTimer: Timer?
    private var settings = AppSettings(defaults: .standard)
    private var settingsWindow: NSWindow?
    private let connectionSetting = NSPopUpButton()
    private let perDownloadSetting = NSTextField()
    private let globalSetting = NSTextField()
    private let notificationSetting = NSButton(checkboxWithTitle: "Notify when downloads complete or fail", target: nil, action: nil)
    private let settingsMessage = NSTextField(labelWithString: "Rates are KiB/s. Blank or 0 means unlimited.")
    private var displayed: [DownloadJob] = []
    private var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("NeatClone", isDirectory: true)
    private static var smokeOutput: URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-smoke-output"), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    private let support: URL = {
        if AppDelegate.smokeOutput != nil { return FileManager.default.temporaryDirectory.appendingPathComponent("NeatClone-UI-" + UUID().uuidString, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeatClone", isDirectory: true)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if Self.smokeOutput != nil { settings = AppSettings(); destination = support.appendingPathComponent("Downloads") }
            if let path = settings.destination { destination = URL(fileURLWithPath: path, isDirectory: true) }
            let ffmpeg = ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            queue = try DownloadQueue(stateURL: support.appendingPathComponent("queue.json"), ffmpegURL: ffmpeg)
            platform = MacIntegration(queue: queue)
            createWindow()
            applySettings()
            platform.install()
            queue.onChange = { [weak self] in
                guard let self else { return }
                self.reloadGrid(); self.platform.onQueueChange()
                if self.queue.persistenceError != nil { self.message.stringValue = "History could not be saved. Check disk access before adding downloads." }
            }
            reloadGrid(); importInbox()
            if let output = Self.smokeOutput {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.runUISmoke(output) }
            }
            inboxTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.importInbox() }
            }
        } catch {
            if Self.smokeOutput != nil { FileHandle.standardError.write(Data("Could not initialize isolated UI probe\n".utf8)); exit(1) }
            let alert = NSAlert(); alert.messageText = "NeatClone could not open its download history."
            alert.informativeText = "Check access to your Application Support folder. Existing history was not overwritten."
            alert.runModal(); NSApp.terminate(nil)
        }
    }

    private func runUISmoke(_ output: URL) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        do {
            try UIVerification.verifyMenus(NSApp.mainMenu!)
            try UIVerification.verifyTextField(urlField, in: window)
            try UIVerification.verifyTextField(filenameField, in: window)
            urlField.stringValue = ""; filenameField.stringValue = ""
            showSettings(nil)
            try UIVerification.verifyTextField(perDownloadSetting, in: settingsWindow!)
            try UIVerification.verifyTextField(globalSetting, in: settingsWindow!)
            settingsWindow?.orderOut(nil)
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
            let input = NSTextField(frame: NSRect(x: 20, y: 60, width: 440, height: 26)); sheet.contentView?.addSubview(input)
            window.beginSheet(sheet); sheet.makeKey()
            try UIVerification.verifyTextField(input, in: sheet)
            window.endSheet(sheet); sheet.orderOut(nil)
            window.makeKeyAndOrderFront(nil)
            try UIVerification.png(window: window, to: output)
            NSPasteboard.general.clearContents(); if let clipboard { NSPasteboard.general.setString(clipboard, forType: .string) }
            try? FileManager.default.removeItem(at: support)
            print("PASS: AppKit URL, filename, settings and sheet responder editing; menu shortcuts; live window PNG")
            exit(0)
        } catch {
            NSPasteboard.general.clearContents(); if let clipboard { NSPasteboard.general.setString(clipboard, forType: .string) }
            let reason = (error as? UIVerification.Failure)?.message ?? "UI verification failed"
            FileHandle.standardError.write(Data((reason + "\n").utf8)); exit(1)
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action); result.bezelStyle = .rounded
        result.setAccessibilityLabel(title); return result
    }
    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "NeatClone — Download Manager"; window.minSize = NSSize(width: 960, height: 540)
        window.setFrameAutosaveName("NeatClone.MainWindow")
        let toolbar = NSToolbar(identifier: "NeatClone.Toolbar"); toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window.toolbar = toolbar; window.toolbarStyle = .expanded
        urlField.placeholderString = "https://example.com/video.mp4"; urlField.setAccessibilityLabel("Download URL")
        filenameField.placeholderString = "Optional file name"; filenameField.setAccessibilityLabel("File name")
        urlField.target = self; urlField.action = #selector(addDownload(_:))
        let inputs = NSStackView(views: [urlField, filenameField, hls, button("Add to queue", #selector(addDownload(_:)))]); inputs.spacing = 8
        urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        filenameField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        folderLabel.stringValue = destination.path; folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setAccessibilityLabel("Download destination")
        let folder = NSStackView(views: [NSTextField(labelWithString: "Save to:"), folderLabel, button("Choose…", #selector(chooseFolder(_:)))]); folder.spacing = 8
        filter.addItems(withTitles: ["All downloads", "Downloading", "Queued", "Paused", "Completed", "Failed", "Cancelled"])
        filter.target = self; filter.action = #selector(filterChanged(_:)); filter.setAccessibilityLabel("Filter by status")
        search.placeholderString = "Find file name"; search.target = self; search.action = #selector(filterChanged(_:)); search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search downloads")
        let filters = NSStackView(views: [filter, search]); filters.spacing = 8
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        let columns: [(String, String, CGFloat)] = [("file", "File name", 280), ("state", "Status", 130), ("progress", "Progress", 100), ("bytes", "Received / total", 160), ("speed", "Throughput", 120), ("eta", "ETA", 90), ("connections", "Connections", 100), ("queue", "Queue", 130)]
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title; column.width = width; column.minWidth = 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 32; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true; table.autosaveName = "NeatClone.Grid"; table.autosaveTableColumns = true
        table.setAccessibilityLabel("Download queue")
        table.copyText = { [weak self] in self?.selectedJobs().map { "\($0.fileName)\t\($0.status.rawValue)" }.joined(separator: "\n") ?? "" }
        table.menu = contextMenu()
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        message.lineBreakMode = .byWordWrapping; message.maximumNumberOfLines = 2
        let root = NSStackView(views: [inputs, folder, filters, scroll, message]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(); window.contentView = view; view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            inputs.widthAnchor.constraint(equalTo: root.widthAnchor), folder.widthAnchor.constraint(equalTo: root.widthAnchor), filters.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260), message.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        NSApp.mainMenu = UIMenus.make(target: self)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("add"), NSToolbarItem.Identifier("resume"), NSToolbarItem.Identifier("pause"),
         .flexibleSpace, NSToolbarItem.Identifier("queue"), NSToolbarItem.Identifier("settings")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) + [.space] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let choices: [String: (String, String, Selector)] = ["add": ("Add URL", "plus", #selector(focusURL(_:))), "resume": ("Start / Resume", "play.fill", #selector(resume(_:))), "pause": ("Pause", "pause.fill", #selector(pause(_:))), "queue": ("Queue", "list.bullet", #selector(showScheduler(_:))), "settings": ("Settings", "gearshape", #selector(showSettings(_:)))]
        guard let choice = choices[identifier.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier); item.label = choice.0; item.paletteLabel = choice.0
        item.image = NSImage(systemSymbolName: choice.1, accessibilityDescription: choice.0); item.target = self; item.action = choice.2; item.isEnabled = true
        return item
    }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "Downloads"); menu.autoenablesItems = false
        for (title, action) in [("Start / Resume", #selector(resume(_:))), ("Pause", #selector(pause(_:))), ("Retry", #selector(retry(_:))), ("Refresh Download Address…", #selector(refreshAddress(_:))), ("Show Full Error…", #selector(showError(_:))), ("Show File", #selector(showFile(_:))), ("Cancel", #selector(cancel(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        let assignment = NSMenuItem(title: "Move to Queue", action: nil, keyEquivalent: "")
        let submenu = NSMenu(); submenu.autoenablesItems = false
        let unassigned = NSMenuItem(title: "Unassigned", action: #selector(assignQueue(_:)), keyEquivalent: ""); unassigned.target = self; submenu.addItem(unassigned)
        for definition in queue.queues {
            let item = NSMenuItem(title: definition.name, action: #selector(assignQueue(_:)), keyEquivalent: ""); item.target = self; item.representedObject = definition.id.uuidString; submenu.addItem(item)
        }
        assignment.submenu = submenu; menu.addItem(assignment); return menu
    }
    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let selected = panel.url {
            destination = selected; folderLabel.stringValue = selected.path; settings.destination = selected.path; settings.save(to: .standard)
        }
    }
    @objc private func focusURL(_ sender: Any?) { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(urlField); urlField.selectText(nil) }
    @objc private func addDownload(_ sender: Any?) {
        let request = BridgeRequest(url: urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), kind: hls.state == .on ? "hls" : "direct", filename: filenameField.stringValue.isEmpty ? nil : filenameField.stringValue)
        do {
            let url = try request.validatedURL(); _ = try queue.enqueue(url: url, kind: hls.state == .on ? .hls : .direct, filename: request.filename, directory: destination)
            urlField.stringValue = ""; filenameField.stringValue = ""; message.stringValue = "Added to queue."
        } catch { message.stringValue = "Could not add this request. Use HTTP(S) without embedded credentials and a safe file name." }
    }
    private func importInbox() {
        do { if !(try queue.importInbox(from: support.appendingPathComponent("Inbox", isDirectory: true), directory: destination)).isEmpty { message.stringValue = "Chrome request added to queue." } }
        catch { message.stringValue = "A browser request could not be imported; it remains in the private inbox." }
    }
    private func selectedJobs() -> [DownloadJob] { table.selectedRowIndexes.compactMap { displayed.indices.contains($0) ? displayed[$0] : nil } }
    @objc private func pause(_ sender: Any?) { selectedJobs().forEach { queue.pause($0.id) } }
    @objc private func resume(_ sender: Any?) { selectedJobs().forEach { queue.resume($0.id) } }
    @objc private func retry(_ sender: Any?) { selectedJobs().forEach { queue.retry($0.id) } }
    @objc private func cancel(_ sender: Any?) { selectedJobs().forEach { queue.cancel($0.id) } }
    @objc private func assignQueue(_ sender: NSMenuItem) {
        let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
        selectedJobs().forEach { queue.assign($0.id, to: id) }
    }
    @objc private func showScheduler(_ sender: Any?) { platform.showScheduler() }
    @objc private func showCredentials(_ sender: Any?) { platform.showCredentials() }
    @objc private func showFile(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(selectedJobs().filter { $0.status == .completed }.map(\.destination))
    }
    @objc private func showError(_ sender: Any?) {
        guard let job = selectedJobs().first else { message.stringValue = "Select a download first."; return }
        let alert = NSAlert(); alert.messageText = job.fileName
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 200)); text.isEditable = false; text.isSelectable = true
        text.font = .systemFont(ofSize: 13); text.string = job.error ?? "No recorded error. Status: \(job.status.rawValue)."
        let scroll = NSScrollView(frame: text.frame); scroll.documentView = text; scroll.hasVerticalScroller = true; alert.accessoryView = scroll
        alert.beginSheetModal(for: window)
    }
    @objc private func refreshAddress(_ sender: Any?) {
        guard let job = selectedJobs().first else { message.stringValue = "Select a download first."; return }
        let alert = NSAlert(); alert.messageText = "Refresh Download Address"; alert.informativeText = "Paste a new authorized URL for the same file. Resume is refused unless the stored identity and length can be verified."
        alert.addButton(withTitle: "Validate New Address"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 580, height: 26)); field.placeholderString = "https://…"; field.setAccessibilityLabel("Replacement URL"); alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                do {
                    let url = try BridgeRequest(url: text).validatedURL(); try await self.queue.refreshAddress(job.id, to: url)
                    self.message.stringValue = "Address validated. Resume the download when ready."
                } catch { self.message.stringValue = "Address refresh refused. The replacement must identify the same file; keep the original or start a new download." }
            }
        }
        alert.window.makeFirstResponder(field)
    }
    @objc private func filterChanged(_ sender: Any?) { reloadGrid() }
    private func reloadGrid() {
        let selected = Set(selectedJobs().map(\.id)); let query = search.stringValue.lowercased()
        let state = filter.indexOfSelectedItem == 0 ? nil : filter.titleOfSelectedItem?.lowercased()
        displayed = queue.jobs.filter { (state == nil || $0.status.rawValue == state) && (query.isEmpty || $0.fileName.lowercased().contains(query)) }
        if let sort = table.sortDescriptors.first, let key = sort.key {
            displayed.sort { a, b in
                let comparison: ComparisonResult
                switch key {
                case "progress": comparison = compare(a.progress ?? -1, b.progress ?? -1)
                case "bytes": comparison = compare(Double(a.bytes), Double(b.bytes))
                case "speed": comparison = compare(a.speed, b.speed)
                case "eta": comparison = compare(a.eta ?? .infinity, b.eta ?? .infinity)
                case "connections": comparison = compare(Double(a.activeConnections), Double(b.activeConnections))
                case "state": comparison = a.status.rawValue.localizedStandardCompare(b.status.rawValue)
                case "queue": comparison = queueName(a).localizedStandardCompare(queueName(b))
                default: comparison = a.fileName.localizedStandardCompare(b.fileName)
                }
                return sort.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }
        table.reloadData(); table.selectRowIndexes(IndexSet(displayed.indices.filter { selected.contains(displayed[$0].id) }), byExtendingSelection: false)
        table.menu = contextMenu()
    }
    private func compare(_ a: Double, _ b: Double) -> ComparisonResult { a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame }
    private func queueName(_ job: DownloadJob) -> String { queue.queues.first { $0.id == job.queueID }?.name ?? "Unassigned" }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reloadGrid() }
    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let job = displayed[row]; let text: String
        switch tableColumn?.identifier.rawValue {
        case "file": text = job.fileName
        case "state": text = job.status.rawValue.capitalized + (job.error == nil ? "" : " — error")
        case "progress": text = job.progress.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
        case "bytes": text = job.kind == .hls ? "\(job.bytes) segments" : ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file) + (job.total.map { " / " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
        case "speed": text = job.status == .downloading ? (job.kind == .hls ? String(format: "%.1f segments/s", job.speed) : ByteCountFormatter.string(fromByteCount: Int64(max(0, job.speed)), countStyle: .file) + "/s") : "—"
        case "eta": text = job.eta.map { seconds in seconds.isFinite ? String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60) : "—" } ?? "—"
        case "connections": text = job.kind == .hls ? "—" : "\(job.activeConnections) active"
        case "queue": text = queueName(job)
        default: text = ""
        }
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = job.error ?? text; label.setAccessibilityLabel(text); return label
    }
    @objc private func showSettings(_ sender: Any?) {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "NeatClone Settings"; panel.isReleasedWhenClosed = false
        for value in AppSettings.connectionChoices { connectionSetting.addItem(withTitle: String(value)); connectionSetting.lastItem?.tag = value }
        connectionSetting.selectItem(withTag: settings.maxConnections)
        perDownloadSetting.stringValue = settings.perDownloadBytesPerSecond.map { String($0 / 1024) } ?? ""
        globalSetting.stringValue = settings.globalBytesPerSecond.map { String($0 / 1024) } ?? ""
        perDownloadSetting.placeholderString = "Unlimited"; globalSetting.placeholderString = "Unlimited"
        perDownloadSetting.setAccessibilityLabel("Per-download limit KiB per second"); globalSetting.setAccessibilityLabel("Global limit KiB per second")
        notificationSetting.state = settings.notifyResults ? .on : .off
        func row(_ title: String, _ control: NSView) -> NSStackView { let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 240).isActive = true; let row = NSStackView(views: [label, control]); row.spacing = 12; return row }
        let explanatory = NSTextField(wrappingLabelWithString: "Requested connections are a ceiling, not a speed promise. Actual connections depend on validated range support and available work. Changes apply to new or resumed transfers.")
        let buttons = NSStackView(views: [button("Credentials…", #selector(showCredentials(_:))), button("Apply", #selector(saveSettings(_:)))]); buttons.spacing = 12
        let stack = NSStackView(views: [row("Connections per download", connectionSetting), row("Per-download limit (KiB/s)", perDownloadSetting), row("Global limit (KiB/s)", globalSetting), notificationSetting, explanatory, settingsMessage, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 22), explanatory.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        settingsWindow = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    @objc private func saveSettings(_ sender: Any?) {
        do {
            var next = settings; next.maxConnections = connectionSetting.selectedItem?.tag ?? 8
            next.perDownloadBytesPerSecond = try AppSettings.rateFromKiB(perDownloadSetting.stringValue); next.globalBytesPerSecond = try AppSettings.rateFromKiB(globalSetting.stringValue)
            next.notifyResults = notificationSetting.state == .on; next.save(to: .standard); settings = next
            applySettings(); settingsMessage.stringValue = "Settings saved. Limits apply to new/resumed transfers."
        } catch { settingsMessage.stringValue = "Enter a whole, positive KiB/s value; blank or 0 means unlimited." }
    }
    private func applySettings() {
        queue.configure(options: TransferOptions(maxConnections: settings.maxConnections, bytesPerSecond: settings.perDownloadBytesPerSecond), globalBytesPerSecond: settings.globalBytesPerSecond)
        platform.setNotificationsEnabled(settings.notifyResults)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window?.makeKeyAndOrderFront(nil); return true }
}
@main struct NeatCloneMain {
    @MainActor static func main() { let app = NSApplication.shared; let delegate = AppDelegate(); app.setActivationPolicy(.regular); app.delegate = delegate; withExtendedLifetime(delegate) { app.run() } }
}
#else
import Foundation
@main struct NeatCloneMain {
    static func main() { FileHandle.standardError.write(Data("NeatClone's AppKit interface requires macOS 12 or later. Use NeatCloneCLI for portable core tests.\n".utf8)); exit(78) }
}
#endif

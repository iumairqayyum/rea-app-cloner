#if os(macOS)
import AppKit
import NeatCloneCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    private var window: NSWindow!
    private var queue: DownloadQueue!
    private var platform: MacIntegration!
    private let table = DownloadTableView()
    private let downloadsScroll = NSScrollView()
    private var addDownloadButton: NSButton!
    private let urlField = NSTextField()
    private let filenameField = NSTextField()
    private let search = NSSearchField()
    private let message = NSTextField(labelWithString: "Ready. Add an authorized URL or send one from Chrome.")
    private let folderLabel = NSTextField(labelWithString: "")
    private let sidebar = NSVisualEffectView()
    private let inputCard = NSVisualEffectView()
    private var sidebarButtons: [NSButton] = []
    private var selectedFilterTag = 0
    private let heading = NSTextField(labelWithString: "Downloads")
    private let subheading = NSTextField(labelWithString: "Newest first")
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
            if Self.smokeOutput != nil { try installUISmokeFixtures() }
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
            try UIVerification.verifyUsableMainWindow(window, controls: [
                ("Download URL", urlField), ("Add Download button", addDownloadButton),
                ("Filename input", filenameField), ("HLS option", hls),
                ("Downloads list", downloadsScroll), ("Download table", table)
            ])
            try UIVerification.png(window: window, to: output)
            try UIVerification.require(urlField.target === self && urlField.action == #selector(addDownload(_:)), "URL field is not connected to Add URL")
            try UIVerification.require(addDownloadButton.target === self && addDownloadButton.action == #selector(addDownload(_:)), "Add URL button is not connected to the queue action")
            try UIVerification.verifyMenus(NSApp.mainMenu!)
            try UIVerification.require(sidebarButtons.count == 7, "The download sidebar is incomplete")
            try UIVerification.require(table.allowsMultipleSelection && table.numberOfRows == 3, "The download table is missing multi-selection or sample history")
            try UIVerification.verifyDownloadMenu(table.menu)
            try UIVerification.require(displayed.first?.fileName == "Archive part 01.bin", "Default history order is not newest first")
            sidebarButtons[4].performClick(nil)
            try UIVerification.require(displayed.count == 1 && displayed.first?.status == .completed, "Sidebar status filter did not update history")
            sidebarButtons[0].performClick(nil)
            table.sortDescriptors = [NSSortDescriptor(key: "file", ascending: true)]; reloadGrid()
            try UIVerification.require(displayed.first?.fileName == "Archive part 01.bin" && displayed.last?.fileName == "Sample video.mp4", "Filename column sorting did not apply")
            table.sortDescriptors = []; reloadGrid()
            try UIVerification.verifyTextField(urlField, in: window)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("https://example.test/pasted.mp4", forType: .string)
            try UIVerification.require(window.makeFirstResponder(urlField), "Cannot focus URL field for Paste")
            try UIVerification.require(NSApp.sendAction(Selector(("paste:")), to: nil, from: nil), "Cmd+V did not reach the URL field")
            try UIVerification.require(urlField.stringValue == "https://example.test/pasted.mp4", "URL field Paste changed the clipboard text")
            // Exercise the same visible button action with an isolated local URL,
            // then cancel immediately so the smoke never contacts an external host.
            let smokeURL = "http://127.0.0.1:1/ui-smoke.mp4"
            urlField.stringValue = smokeURL
            let previousIDs = Set(queue.jobs.map(\.id))
            addDownloadButton.performClick(nil)
            guard let smokeJob = queue.jobs.first(where: { !previousIDs.contains($0.id) && $0.url.absoluteString == smokeURL }) else {
                throw UIVerification.Failure(message: "Add URL did not add the entered address to the queue")
            }
            queue.cancel(smokeJob.id)
            try UIVerification.require(queue.jobs.contains(where: { $0.id == smokeJob.id && $0.status == .cancelled }), "The smoke download was not cleanly cancelled")
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
            NSPasteboard.general.clearContents(); if let clipboard { NSPasteboard.general.setString(clipboard, forType: .string) }
            try? FileManager.default.removeItem(at: support)
            print("PASS: AppKit URL, filename, settings and sheet responder editing; menu shortcuts")
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
    private func installUISmokeFixtures() throws {
        let now = URL(string: "https://example.test/video.mp4")!
        let files = [
            DownloadJob(id: UUID(), url: now, kind: .direct, fileName: "Sample video.mp4", destination: destination.appendingPathComponent("Sample video.mp4"), status: .paused, bytes: 46_000_000, total: 100_000_000, activeConnections: 0),
            DownloadJob(id: UUID(), url: URL(string: "https://example.test/installer.dmg")!, kind: .direct, fileName: "Developer tools.dmg", destination: destination.appendingPathComponent("Developer tools.dmg"), status: .completed, bytes: 24_000_000, total: 24_000_000),
            DownloadJob(id: UUID(), url: URL(string: "https://example.test/large.bin")!, kind: .direct, fileName: "Archive part 01.bin", destination: destination.appendingPathComponent("Archive part 01.bin"), status: .failed, bytes: 0, total: 100_000_000, error: DownloadError.http(403).errorDescription)
        ]
        try JSONEncoder().encode(files).write(to: support.appendingPathComponent("queue.json"), options: .atomic)
    }
    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "NeatClone — Download Manager"
        let toolbar = NSToolbar(identifier: "NeatClone.Toolbar"); toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window.toolbar = toolbar; window.toolbarStyle = .expanded
        sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.state = .followsWindowActiveState
        let sidebarTitle = NSTextField(labelWithString: "LIBRARY")
        sidebarTitle.font = .systemFont(ofSize: 11, weight: .bold); sidebarTitle.textColor = .tertiaryLabelColor
        let labels = ["All Downloads", "Downloading", "Queued", "Paused", "Completed", "Failed", "Cancelled"]
        let symbols = ["tray.full", "arrow.down.circle.fill", "clock", "pause.circle", "checkmark.circle.fill", "exclamationmark.circle.fill", "xmark.circle"]
        sidebarButtons = labels.enumerated().map { index, title in
            let image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: title) ?? NSImage()
            let item = NSButton(title: title, image: image, target: self, action: #selector(selectSidebarFilter(_:)))
            item.setButtonType(.toggle); item.bezelStyle = .rounded; item.imagePosition = .imageLeading; item.alignment = .left; item.tag = index
            item.setAccessibilityLabel("Show \(title)"); return item
        }
        let sideStack = NSStackView(views: [sidebarTitle] + sidebarButtons)
        sideStack.orientation = .vertical; sideStack.alignment = .leading; sideStack.spacing = 8; sideStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sideStack)
        NSLayoutConstraint.activate([sideStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14), sideStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14), sideStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 22)])

        urlField.placeholderString = "https://example.com/video.mp4"; urlField.setAccessibilityLabel("Download URL")
        filenameField.placeholderString = "Optional file name"; filenameField.setAccessibilityLabel("File name")
        urlField.target = self; urlField.action = #selector(addDownload(_:))
        urlField.font = .systemFont(ofSize: 14); filenameField.font = .systemFont(ofSize: 13)
        addDownloadButton = button("Add Download", #selector(addDownload(_:))); addDownloadButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add download"); addDownloadButton.imagePosition = .imageLeading
        let addressRow = NSStackView(views: [urlField, addDownloadButton]); addressRow.spacing = 10; addressRow.distribution = .fill
        urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let detailsRow = NSStackView(views: [filenameField, hls]); detailsRow.spacing = 12; detailsRow.distribution = .fill
        filenameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        folderLabel.stringValue = destination.path; folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setAccessibilityLabel("Download destination"); folderLabel.font = .systemFont(ofSize: 12); folderLabel.textColor = .secondaryLabelColor
        let folder = NSStackView(views: [NSTextField(labelWithString: "Save to"), folderLabel, button("Choose…", #selector(chooseFolder(_:)))]); folder.spacing = 10
        let inputs = NSStackView(views: [addressRow, detailsRow, folder]); inputs.orientation = .vertical; inputs.alignment = .leading; inputs.spacing = 10
        inputs.translatesAutoresizingMaskIntoConstraints = false
        inputCard.material = .contentBackground; inputCard.blendingMode = .withinWindow; inputCard.state = .followsWindowActiveState
        inputCard.wantsLayer = true; inputCard.layer?.cornerRadius = 10; inputCard.layer?.masksToBounds = true; inputCard.addSubview(inputs)
        NSLayoutConstraint.activate([inputs.leadingAnchor.constraint(equalTo: inputCard.leadingAnchor, constant: 14), inputs.trailingAnchor.constraint(equalTo: inputCard.trailingAnchor, constant: -14), inputs.topAnchor.constraint(equalTo: inputCard.topAnchor, constant: 12), inputs.bottomAnchor.constraint(equalTo: inputCard.bottomAnchor, constant: -12), addressRow.widthAnchor.constraint(equalTo: inputs.widthAnchor), detailsRow.widthAnchor.constraint(equalTo: inputs.widthAnchor), folder.widthAnchor.constraint(equalTo: inputs.widthAnchor)])

        search.placeholderString = "Find file name"; search.target = self; search.action = #selector(filterChanged(_:)); search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search downloads")
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        heading.font = .systemFont(ofSize: 23, weight: .semibold); subheading.font = .systemFont(ofSize: 12); subheading.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [heading, subheading]); titleStack.orientation = .vertical; titleStack.alignment = .leading; titleStack.spacing = 3
        let header = NSStackView(views: [titleStack, search]); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 18
        let columns: [(String, String, CGFloat)] = [("file", "File name", 270), ("state", "Status", 125), ("progress", "Progress", 155), ("bytes", "Received / total", 150), ("speed", "Throughput", 112), ("eta", "ETA", 82), ("connections", "Connections", 100), ("queue", "Queue", 125)]
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title; column.width = width; column.minWidth = 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 42; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true; table.autosaveName = "NeatClone.Grid"; table.autosaveTableColumns = true
        table.setAccessibilityLabel("Download queue")
        table.copyText = { [weak self] in self?.selectedJobs().map { "\($0.fileName)\t\($0.status.rawValue)" }.joined(separator: "\n") ?? "" }
        table.removeSelection = { [weak self] in self?.removeFromList(nil) }
        table.menu = contextMenu()
        table.backgroundColor = .clear; table.gridColor = .separatorColor; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        downloadsScroll.documentView = table; downloadsScroll.hasVerticalScroller = true; downloadsScroll.hasHorizontalScroller = true; downloadsScroll.drawsBackground = false; downloadsScroll.borderType = .noBorder
        message.lineBreakMode = .byWordWrapping; message.maximumNumberOfLines = 2; message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        let main = NSStackView(views: [header, inputCard, downloadsScroll, message]); main.orientation = .vertical; main.alignment = .leading; main.spacing = 16; main.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = view; view.addSubview(sidebar); view.addSubview(main)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor), sidebar.topAnchor.constraint(equalTo: view.topAnchor), sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 184),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 22), main.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22), main.topAnchor.constraint(equalTo: view.topAnchor, constant: 20), main.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: main.widthAnchor), inputCard.widthAnchor.constraint(equalTo: main.widthAnchor), downloadsScroll.widthAnchor.constraint(equalTo: main.widthAnchor), downloadsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250), message.widthAnchor.constraint(equalTo: main.widthAnchor)
        ])
        // Apply autosaved geometry only after toolbar and content constraints are
        // installed. A stale Monterey frame can otherwise restore a toolbar-only
        // strip despite minSize being set before the frame restoration.
        _ = window.setFrameAutosaveName("NeatClone.MainWindow")
        UIVerification.enforceUsableMainWindowSize(window)
        updateSidebarSelection()
        NSApp.mainMenu = UIMenus.make(target: self)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("add"), NSToolbarItem.Identifier("resume"), NSToolbarItem.Identifier("pause"), NSToolbarItem.Identifier("remove"),
         .flexibleSpace, NSToolbarItem.Identifier("queue"), NSToolbarItem.Identifier("settings")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) + [.space] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let choices: [String: (String, String, Selector)] = ["add": ("Add URL", "plus", #selector(focusURL(_:))), "resume": ("Start / Resume", "play.fill", #selector(resume(_:))), "pause": ("Pause", "pause.fill", #selector(pause(_:))), "remove": ("Remove from List", "trash", #selector(removeFromList(_:))), "queue": ("Queue", "list.bullet", #selector(showScheduler(_:))), "settings": ("Settings", "gearshape", #selector(showSettings(_:)))]
        guard let choice = choices[identifier.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier); item.label = choice.0; item.paletteLabel = choice.0
        item.image = NSImage(systemSymbolName: choice.1, accessibilityDescription: choice.0); item.target = self; item.action = choice.2; item.isEnabled = true
        return item
    }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "Downloads"); menu.autoenablesItems = false
        for (title, action) in [("Start / Resume", #selector(resume(_:))), ("Pause", #selector(pause(_:))), ("Retry", #selector(retry(_:))), ("Refresh Download Address…", #selector(refreshAddress(_:))), ("Show Full Error…", #selector(showError(_:))), ("Show File", #selector(showFile(_:))), ("Cancel", #selector(cancel(_:))), ("Remove from List", #selector(removeFromList(_:))), ("Delete File & Remove…", #selector(confirmDeleteFiles(_:)))] {
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
    @objc private func selectSidebarFilter(_ sender: NSButton) {
        selectedFilterTag = sender.tag; updateSidebarSelection(); reloadGrid()
    }
    private func updateSidebarSelection() {
        let labels = ["All Downloads", "Downloading", "Queued", "Paused", "Completed", "Failed", "Cancelled"]
        let rawStatuses = [nil, "downloading", "queued", "paused", "completed", "failed", "cancelled"] as [String?]
        for button in sidebarButtons where labels.indices.contains(button.tag) {
            let count = rawStatuses[button.tag].map { value in queue.jobs.filter { $0.status.rawValue == value }.count } ?? queue.jobs.count
            button.title = "\(labels[button.tag])  \(count)"
            button.state = button.tag == selectedFilterTag ? .on : .off
            button.contentTintColor = button.tag == selectedFilterTag ? .controlAccentColor : .secondaryLabelColor
        }
    }
    @objc private func removeFromList(_ sender: Any?) {
        let ids = selectedJobs().map(\.id)
        guard !ids.isEmpty else { message.stringValue = "Select stopped downloads to remove them from history."; return }
        do { try queue.removeFromList(ids); message.stringValue = "Removed selected downloads from history. Saved files were kept." }
        catch { message.stringValue = "Active downloads must be paused or cancelled before they can be removed." }
    }
    @objc private func confirmDeleteFiles(_ sender: Any?) {
        let jobs = selectedJobs().filter { $0.status == .completed }
        guard !jobs.isEmpty else { message.stringValue = "Select one or more completed downloads first."; return }
        let alert = NSAlert(); alert.alertStyle = .critical
        alert.messageText = jobs.count == 1 ? "Delete this downloaded file?" : "Delete \(jobs.count) downloaded files?"
        alert.informativeText = jobs.count == 1 ? jobs[0].destination.path : "The selected completed files will be deleted from disk and removed from history."
        alert.addButton(withTitle: "Delete File & Remove"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            for job in jobs {
                do { try self.queue.removeFromList(job.id, deleteFile: true) }
                catch { self.message.stringValue = "A file could not be deleted. Check its location and permissions."; break }
            }
        }
    }
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
        let rawStatuses = [nil, "downloading", "queued", "paused", "completed", "failed", "cancelled"] as [String?]
        let state = rawStatuses.indices.contains(selectedFilterTag) ? rawStatuses[selectedFilterTag] : nil
        let filtered = queue.jobs.filter { (state == nil || $0.status.rawValue == state) && (query.isEmpty || $0.fileName.lowercased().contains(query)) }
        let sort = table.sortDescriptors.first
        let names = Dictionary(uniqueKeysWithValues: queue.queues.map { ($0.id, $0.name) })
        displayed = DownloadOrdering.sorted(filtered, key: sort?.key, ascending: sort?.ascending ?? true, queueNames: names)
        subheading.stringValue = sort?.key.map { "\(displayed.count) items · Sorted by \($0)" } ?? "\(displayed.count) items · Newest first"
        table.reloadData(); table.selectRowIndexes(IndexSet(displayed.indices.filter { selected.contains(displayed[$0].id) }), byExtendingSelection: false)
        table.menu = contextMenu(); updateSidebarSelection()
    }
    private func queueName(_ job: DownloadJob) -> String { queue.queues.first { $0.id == job.queueID }?.name ?? "Unassigned" }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reloadGrid() }
    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let job = displayed[row]; let text: String
        switch tableColumn?.identifier.rawValue {
        case "file": text = job.fileName
        case "state":
            let badge = NSTextField(labelWithString: job.status.rawValue.capitalized + (job.error == nil ? "" : " · Error"))
            badge.font = .systemFont(ofSize: 11, weight: .semibold); badge.alignment = .center; badge.drawsBackground = true
            badge.backgroundColor = statusColor(job.status).withAlphaComponent(0.13); badge.textColor = statusColor(job.status)
            badge.wantsLayer = true; badge.layer?.cornerRadius = 8; badge.toolTip = job.error ?? badge.stringValue
            badge.setAccessibilityLabel(badge.stringValue); return badge
        case "progress":
            let bar = NSProgressIndicator(); bar.style = .bar; bar.minValue = 0; bar.maxValue = 1; bar.controlSize = .small
            let percent = NSTextField(labelWithString: job.progress.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
            percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); percent.textColor = .secondaryLabelColor; percent.alignment = .right
            if let value = job.progress { bar.doubleValue = value } else { bar.isIndeterminate = true; bar.startAnimation(nil) }
            let cell = NSStackView(views: [bar, percent]); cell.orientation = .horizontal; cell.alignment = .centerY; cell.spacing = 8
            bar.widthAnchor.constraint(equalToConstant: 84).isActive = true; percent.widthAnchor.constraint(equalToConstant: 42).isActive = true
            return cell
        case "bytes": text = job.kind == .hls ? "\(job.bytes) segments" : ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file) + (job.total.map { " / " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
        case "speed": text = job.status == .downloading ? (job.kind == .hls ? String(format: "%.1f segments/s", job.speed) : ByteCountFormatter.string(fromByteCount: Int64(max(0, job.speed)), countStyle: .file) + "/s") : "—"
        case "eta": text = job.eta.map { seconds in seconds.isFinite ? String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60) : "—" } ?? "—"
        case "connections": text = job.kind == .hls ? "—" : "\(job.activeConnections) active"
        case "queue": text = queueName(job)
        default: text = ""
        }
        if tableColumn?.identifier.rawValue == "file" {
            let symbol = ["mp4", "m4v", "mov", "mkv", "webm", "avi"].contains(job.fileName.split(separator: ".").last?.lowercased() ?? "") ? "film" : "doc"
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: symbol) ?? NSImage())
            icon.contentTintColor = job.status == .completed ? .systemGreen : .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let name = NSTextField(labelWithString: text); name.font = .systemFont(ofSize: 12, weight: .medium); name.lineBreakMode = .byTruncatingMiddle; name.toolTip = text
            let cell = NSStackView(views: [icon, name]); cell.orientation = .horizontal; cell.alignment = .centerY; cell.spacing = 9; return cell
        }
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle; label.toolTip = job.error ?? text; label.setAccessibilityLabel(text); return label
    }
    private func statusColor(_ status: DownloadStatus) -> NSColor {
        switch status {
        case .downloading: return .controlAccentColor
        case .completed: return .systemGreen
        case .failed: return .systemRed
        case .paused: return .systemOrange
        case .queued: return .secondaryLabelColor
        case .cancelled: return .tertiaryLabelColor
        }
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

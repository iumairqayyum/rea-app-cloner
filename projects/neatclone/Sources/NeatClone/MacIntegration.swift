#if os(macOS)
import AppKit
import Security
import UserNotifications
import NeatCloneCore

struct StoredCredential: Codable, Equatable {
    var username: String
    var password: String
}
enum CredentialFailure: Error { case invalidInput, keychain(OSStatus) }

/// Keychain payload is never copied into queue state, UserDefaults, or logs.
final class KeychainCredentialStore {
    private let service: String
    init(service: String = "org.neatclone.credentials") { self.service = service }
    private func query(_ scope: CredentialScope) -> [String: Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
         kSecAttrAccount as String:scope.key]
    }
    func save(_ credential: StoredCredential, for scope: CredentialScope) throws {
        guard !credential.username.isEmpty, !credential.username.contains(":"),
              credential.username.utf8.count <= 256, credential.password.utf8.count <= 4096 else { throw CredentialFailure.invalidInput }
        let data = try JSONEncoder().encode(credential)
        let existing = query(scope)
        let status = SecItemUpdate(existing as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = existing; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialFailure.keychain(added) }
        } else if status != errSecSuccess { throw CredentialFailure.keychain(status) }
    }
    func load(for scope: CredentialScope) throws -> StoredCredential? {
        var item = query(scope); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialFailure.keychain(status) }
        return try JSONDecoder().decode(StoredCredential.self, from: data)
    }
    func delete(for scope: CredentialScope) throws {
        let status = SecItemDelete(query(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialFailure.keychain(status) }
    }
}

@MainActor final class DockProgressView: NSView {
    var fraction: Double? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        guard let fraction else { return }
        let track = NSRect(x: 7, y: 7, width: bounds.width - 14, height: 12)
        NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect:track, xRadius:6, yRadius:6).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect:NSRect(x:track.minX, y:track.minY, width:track.width * min(1,max(0,fraction)), height:track.height), xRadius:6, yRadius:6).fill()
    }
}

/// Platform integration is fed queue callbacks; it does not poll the network or
/// run browser-supplied commands. Notifications require explicit app consent.
@MainActor final class MacIntegration: NSObject {
    private let queue: DownloadQueue
    private let credentials = KeychainCredentialStore()
    private var item: NSStatusItem?
    private let dock = DockProgressView(frame:NSRect(x:0,y:0,width:128,height:128))
    private var statuses: [UUID: DownloadStatus] = [:]
    private var notificationsEnabled = false
    private var wakeObserver: NSObjectProtocol?
    private var timeObserver: NSObjectProtocol?
    private var zoneObserver: NSObjectProtocol?
    private var schedulerWindow: NSWindow?
    private let nameField = NSTextField()
    private let zoneField = NSTextField()
    private let startField = NSTextField()
    private let endField = NSTextField()
    private let weekdayField = NSTextField()
    private let queuePicker = NSPopUpButton()
    private let enabledCheck = NSButton(checkboxWithTitle:"Queue enabled", target:nil, action:nil)
    private let scheduleCheck = NSButton(checkboxWithTitle:"Run only in this recurring local-time window", target:nil, action:nil)
    private let schedulerMessage = NSTextField(labelWithString:"")

    init(queue: DownloadQueue) { self.queue = queue; super.init() }
    func install() {
        guard item == nil else { return }
        statuses = Dictionary(uniqueKeysWithValues:queue.jobs.map { ($0.id,$0.status) })
        queue.authorizationProvider = { [weak self] url in
            guard let self, let scope = try? CredentialScope(url:url), let credential = try? self.credentials.load(for:scope) else { return nil }
            let token = Data((credential.username + ":" + credential.password).utf8).base64EncodedString()
            return TransferAuthorization(host:scope.host, value:"Basic " + token, port:scope.port)
        }
        let status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        status.button?.title = "↓ NeatClone"
        let menu = NSMenu()
        for (title, action) in [("Show Downloads",#selector(showDownloads)),("Resume All",#selector(resumeAll)),("Pause All",#selector(pauseAll)),("Queues and Schedules…",#selector(openScheduler)),("Credentials…",#selector(openCredentials))] {
            let entry = NSMenuItem(title:title, action:action, keyEquivalent:""); entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title:"Quit NeatClone", action:#selector(NSApplication.terminate(_:)), keyEquivalent:"q"); menu.addItem(quit)
        status.menu = menu; item = status
        NSApp.dockTile.contentView = dock
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification, object:nil, queue:.main) { [weak self] _ in Task { @MainActor in self?.queue.reevaluateSchedule() } }
        timeObserver = NotificationCenter.default.addObserver(forName:NSNotification.Name.NSSystemClockDidChange, object:nil, queue:.main) { [weak self] _ in Task { @MainActor in self?.queue.reevaluateSchedule() } }
        zoneObserver = NotificationCenter.default.addObserver(forName:NSNotification.Name.NSSystemTimeZoneDidChange, object:nil, queue:.main) { [weak self] _ in Task { @MainActor in self?.queue.reevaluateSchedule() } }
        onQueueChange()
    }
    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { _, _ in }
    }
    func onQueueChange() {
        let active = queue.jobs.filter { $0.status == .downloading }
        let pending = queue.jobs.filter { [.queued,.downloading,.paused].contains($0.status) }
        item?.button?.title = active.isEmpty ? "↓ NeatClone" : "↓ \(active.count) active"
        dock.fraction = active.compactMap(\.progress).first
        NSApp.dockTile.badgeLabel = pending.isEmpty ? nil : String(pending.count)
        NSApp.dockTile.display()
        for job in queue.jobs {
            if let previous = statuses[job.id], previous != job.status, [.completed,.failed].contains(job.status), notificationsEnabled {
                let content = UNMutableNotificationContent()
                content.title = job.status == .completed ? "Download completed" : "Download failed"
                content.body = job.status == .completed ? "A NeatClone download is ready." : "Open NeatClone to review the error and retry."
                // No filename, URL, query token, or raw transport error in alerts.
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:job.id.uuidString + "-" + job.status.rawValue, content:content, trigger:nil))
            }
            statuses[job.id] = job.status
        }
    }
    @objc private func showDownloads() { NSApp.activate(ignoringOtherApps:true); NSApp.windows.first(where: { $0.title.contains("NeatClone") })?.makeKeyAndOrderFront(nil) }
    @objc private func resumeAll() { queue.resumeAll() }
    @objc private func pauseAll() { queue.pauseAll() }
    @objc private func openScheduler() { showScheduler() }
    @objc private func openCredentials() { showCredentials() }

    func showCredentials() {
        let alert = NSAlert(); alert.messageText = "HTTPS credentials"
        alert.informativeText = "Save only credentials you authorize NeatClone to use. They stay in macOS Keychain and are sent only to the exact HTTPS hostname and port. Browser cookies are not imported."
        alert.addButton(withTitle:"Save in Keychain"); alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Delete for origin")
        let origin = NSTextField(); origin.placeholderString = "https://downloads.example.com"
        let username = NSTextField(); username.placeholderString = "Username"
        let password = NSSecureTextField(); password.placeholderString = "Password"
        let consent = NSButton(checkboxWithTitle:"Allow this app to send these credentials to this HTTPS origin", target:nil, action:nil)
        let stack = NSStackView(views:[origin,username,password,consent]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x:0,y:0,width:460,height:130)
        for field in [origin,username,password] { field.widthAnchor.constraint(equalToConstant:460).isActive = true }
        alert.accessoryView = stack
        let response = alert.runModal()
        guard response != .alertSecondButtonReturn, let url = URL(string:origin.stringValue), let scope = try? CredentialScope(url:url) else { return }
        do {
            if response == .alertThirdButtonReturn { try credentials.delete(for:scope) }
            else {
                guard consent.state == .on else { let notice = NSAlert(); notice.messageText = "Credential consent was not granted."; notice.runModal(); return }
                try credentials.save(StoredCredential(username:username.stringValue,password:password.stringValue),for:scope)
            }
        } catch { let notice = NSAlert(); notice.messageText = "Keychain operation could not be completed."; notice.informativeText = "Check the origin and username, or allow the Keychain request if macOS asks."; notice.runModal() }
        password.stringValue = ""
    }

    func showScheduler() {
        if let schedulerWindow { refreshPicker(); schedulerWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:610,height:420), styleMask:[.titled,.closable], backing:.buffered, defer:false)
        window.title = "NeatClone — Queues and Schedules"; window.isReleasedWhenClosed = false
        queuePicker.target = self; queuePicker.action = #selector(selectQueue)
        nameField.placeholderString = "Queue name"
        zoneField.stringValue = TimeZone.current.identifier
        startField.stringValue = "09:00"; endField.stringValue = "17:00"; weekdayField.stringValue = "2,3,4,5,6"
        let intro = NSTextField(wrappingLabelWithString:"Each queue runs serially; eligible queues alternate fairly. Windows use the named timezone, including DST. Missed windows are skipped; sleep/wake reevaluates the current window. No scripts or destructive post-actions run.")
        let views: [NSView] = [intro,queuePicker,nameField,enabledCheck,scheduleCheck,
            row("Timezone",zoneField),row("Start HH:MM",startField),row("End HH:MM",endField),row("Weekdays (Sun=1)",weekdayField)]
        let save = NSButton(title:"Save Queue",target:self,action:#selector(saveQueue)); save.bezelStyle = .rounded
        let move = NSButton(title:"Move queued downloads here",target:self,action:#selector(moveJobs)); move.bezelStyle = .rounded
        let remove = NSButton(title:"Remove Queue",target:self,action:#selector(removeQueue)); remove.bezelStyle = .rounded
        let actions = NSStackView(views:[save,move,remove]); actions.spacing = 8
        let stack = NSStackView(views:views + [actions,schedulerMessage]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(); window.contentView = container; container.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:18),stack.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-18),stack.topAnchor.constraint(equalTo:container.topAnchor,constant:18)])
        schedulerWindow = window; refreshPicker(); selectQueue(); window.center(); window.makeKeyAndOrderFront(nil)
    }
    private func row(_ label: String,_ field: NSTextField) -> NSView {
        field.widthAnchor.constraint(equalToConstant:350).isActive = true
        let title = NSTextField(labelWithString:label); title.widthAnchor.constraint(equalToConstant:170).isActive = true
        let row = NSStackView(views:[title,field]); row.spacing = 10; return row
    }
    private func refreshPicker(select id:UUID? = nil) {
        queuePicker.removeAllItems(); queuePicker.addItem(withTitle:"New queue…")
        for definition in queue.queues { queuePicker.addItem(withTitle:definition.name); queuePicker.lastItem?.representedObject = definition.id.uuidString }
        if let id, let selected = queuePicker.itemArray.first(where: { ($0.representedObject as? String) == id.uuidString }) { queuePicker.select(selected) }
    }
    private var selectedQueueID: UUID? { (queuePicker.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:)) }
    @objc private func selectQueue() {
        guard let id = selectedQueueID, let definition = queue.queues.first(where: { $0.id == id }) else {
            nameField.stringValue = ""; enabledCheck.state = .on; scheduleCheck.state = .off; return
        }
        nameField.stringValue = definition.name; enabledCheck.state = definition.enabled ? .on : .off
        scheduleCheck.state = definition.schedule == nil ? .off : .on
        if let schedule = definition.schedule {
            zoneField.stringValue = schedule.timeZoneID
            startField.stringValue = String(format:"%02d:%02d",schedule.startMinute/60,schedule.startMinute%60)
            endField.stringValue = String(format:"%02d:%02d",schedule.endMinute/60,schedule.endMinute%60)
            weekdayField.stringValue = schedule.weekdays.map(String.init).joined(separator:",")
        }
    }
    private func minute(_ text:String) -> Int? {
        let pieces = text.split(separator:":"); guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }; return hour*60+minute
    }
    @objc private func saveQueue() {
        var schedule:QueueSchedule?
        if scheduleCheck.state == .on {
            guard let start = minute(startField.stringValue), let end = minute(endField.stringValue) else { schedulerMessage.stringValue = "Enter valid HH:MM start and end times."; return }
            let days = weekdayField.stringValue.split(separator:",").compactMap { Int($0.trimmingCharacters(in:.whitespaces)) }
            let value = QueueSchedule(timeZoneID:zoneField.stringValue,startMinute:start,endMinute:end,weekdays:days)
            guard value.isValid else { schedulerMessage.stringValue = "Choose a valid timezone, distinct times, and weekdays 1–7."; return }; schedule = value
        }
        let definition = DownloadQueueDefinition(id:selectedQueueID ?? UUID(),name:nameField.stringValue,enabled:enabledCheck.state == .on,schedule:schedule)
        do { try queue.updateQueue(definition); refreshPicker(select:definition.id); schedulerMessage.stringValue = "Saved. Window changes apply to running jobs." }
        catch { schedulerMessage.stringValue = "Could not save the queue. Check its name and storage permissions." }
    }
    @objc private func moveJobs() {
        guard let id = selectedQueueID else { return }
        for job in queue.jobs where [.queued,.paused,.failed].contains(job.status) { queue.assign(job.id,to:id) }
        schedulerMessage.stringValue = "Waiting downloads assigned. Resume paused downloads when ready."
    }
    @objc private func removeQueue() {
        guard let id = selectedQueueID else { return }
        do { try queue.removeQueue(id); refreshPicker(); selectQueue(); schedulerMessage.stringValue = "Queue removed; its downloads now use the default queue." }
        catch { schedulerMessage.stringValue = "Queue could not be removed." }
    }
}
#endif

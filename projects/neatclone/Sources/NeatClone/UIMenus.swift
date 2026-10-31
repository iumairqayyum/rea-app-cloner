#if os(macOS)
import AppKit

/// Uses the normal responder chain, so a field editor in a sheet or settings
/// window receives edit actions rather than the download controller swallowing them.
@MainActor enum UIMenus {
    static func make(target: AnyObject?) -> NSMenu {
        let root = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; root.addItem(item)
            return menu
        }
        func item(_ menu: NSMenu, _ title: String, _ selector: String, _ key: String,
                  _ mask: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let value = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key)
            value.keyEquivalentModifierMask = mask; value.target = target; menu.addItem(value)
        }
        let app = submenu("NeatClone")
        item(app, "Settings…", "showSettings:", ",", target: target)
        app.addItem(.separator())
        item(app, "Hide NeatClone", "hide:", "h")
        item(app, "Hide Others", "hideOtherApplications:", "h", [.command, .option])
        item(app, "Show All", "unhideAllApplications:", "")
        app.addItem(.separator())
        item(app, "Quit NeatClone", "terminate:", "q")
        let file = submenu("File")
        item(file, "Add URL…", "focusURL:", "n", target: target)
        item(file, "Choose Download Folder…", "chooseFolder:", "d", [.command, .shift], target: target)
        let edit = submenu("Edit")
        item(edit, "Undo", "undo:", "z")
        item(edit, "Redo", "redo:", "z", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", "cut:", "x")
        item(edit, "Copy", "copy:", "c")
        item(edit, "Paste", "paste:", "v")
        item(edit, "Select All", "selectAll:", "a")
        let downloads = submenu("Downloads")
        item(downloads, "Start / Resume", "resume:", "r", target: target)
        item(downloads, "Pause", "pause:", "p", target: target)
        item(downloads, "Retry", "retry:", "r", [.command, .shift], target: target)
        item(downloads, "Refresh Download Address…", "refreshAddress:", "u", [.command, .shift], target: target)
        item(downloads, "Show Full Error…", "showError:", "", target: target)
        let window = submenu("Window")
        item(window, "Minimize", "performMiniaturize:", "m")
        item(window, "Bring All to Front", "arrangeInFront:", "")
        NSApp.windowsMenu = window
        return root
    }
}

/// Native selection semantics plus user-requested clipboard actions for the grid.
@MainActor final class DownloadTableView: NSTableView {
    var copyText: (() -> String)?
    var removeSelection: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
    @objc func copy(_ sender: Any?) {
        guard let value = copyText?(), !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            removeSelection?()
            return
        }
        super.keyDown(with: event)
    }
}
#endif

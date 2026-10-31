#if os(macOS)
import AppKit

@MainActor enum UIVerification {
    struct Failure: Error { let message: String }
    private static var preparedApplication = false

    /// XCTest's command-line runner does not call NSApplication.run(). Bootstrap
    /// the normal AppKit lifecycle and wait for WindowServer activation before
    /// testing nil-target responder dispatch. Real app probes already have a run loop.
    static func prepareWindow(_ window: NSWindow) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if !preparedApplication {
            preparedApplication = true
            if !app.isRunning { app.finishLaunching() }
        }
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeKey()
        let deadline = Date().addingTimeInterval(3)
        repeat {
            app.updateWindows()
            while let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                app.sendEvent(event)
                if Date() >= deadline { break }
            }
            if app.keyWindow === window && window.isKeyWindow { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.makeKey()
        } while Date() < deadline
        try require(app.keyWindow === window && window.isKeyWindow, "AppKit window never became key after application activation")
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    static func verifyMenus(_ menu: NSMenu) throws {
        guard let edit = menu.items.first(where: { $0.title == "Edit" })?.submenu else { throw Failure(message: "Missing Edit menu") }
        let expected: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("Undo", "undo:", "z", .command), ("Redo", "redo:", "z", [.command, .shift]),
            ("Cut", "cut:", "x", .command), ("Copy", "copy:", "c", .command),
            ("Paste", "paste:", "v", .command), ("Select All", "selectAll:", "a", .command)
        ]
        for (title, selector, key, modifiers) in expected {
            guard let item = edit.items.first(where: { $0.title == title }) else { throw Failure(message: "Missing \(title)") }
            try require(item.action == Selector(selector), "Wrong \(title) action")
            try require(item.target == nil, "\(title) must use responder chain")
            try require(item.keyEquivalent == key && item.keyEquivalentModifierMask == modifiers, "Wrong \(title) shortcut")
        }
    }
    static func verifyDownloadMenu(_ menu: NSMenu?) throws {
        guard let menu else { throw Failure(message: "Missing download context menu") }
        let required: [(String, Selector)] = [
            ("Remove from List", Selector(("removeFromList:"))),
            ("Delete File & Remove…", Selector(("confirmDeleteFiles:"))),
            ("Show Full Error…", Selector(("showError:")))
        ]
        for (title, action) in required {
            guard let item = menu.items.first(where: { $0.title == title }) else { throw Failure(message: "Missing download action: \(title)") }
            try require(item.action == action, "Wrong action for \(title)")
        }
    }
    static func verifyTextField(_ field: NSTextField, in window: NSWindow) throws {
        try prepareWindow(window)
        field.stringValue = "original"
        try require(window.makeFirstResponder(field), "Cannot focus input")
        field.selectText(nil)
        guard let editor = field.currentEditor() as? NSTextView else { throw Failure(message: "No field editor") }
        editor.allowsUndo = true
        try require(window.firstResponder === editor, "Field editor is not the window first responder")
        try require(NSApp.sendAction(Selector(("selectAll:")), to: nil, from: nil), "Select All not routed")
        try require(editor.selectedRange().length == "original".utf16.count, "Select All selected wrong range")
        try require(NSApp.sendAction(Selector(("copy:")), to: nil, from: nil), "Copy not routed")
        try require(NSPasteboard.general.string(forType: .string) == "original", "Copy returned wrong text")
        try require(NSApp.sendAction(Selector(("cut:")), to: nil, from: nil), "Cut not routed")
        try require(editor.string.isEmpty, "Cut did not edit field")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("replacement", forType: .string)
        try require(NSApp.sendAction(Selector(("paste:")), to: nil, from: nil), "Paste not routed")
        try require(editor.string == "replacement", "Paste did not edit field")
        // Field editors group undo at event boundaries. Close the open event group
        // before routing the standard Undo/Redo actions, exactly as the next event does.
        if let undo = editor.undoManager {
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
            if undo.canUndo {
                try require(NSApp.sendAction(Selector(("undo:")), to: nil, from: nil), "Undo not routed")
                try require(editor.string != "replacement", "Undo did not edit field")
                if undo.canRedo {
                    try require(NSApp.sendAction(Selector(("redo:")), to: nil, from: nil), "Redo not routed")
                    try require(editor.string == "replacement", "Redo did not restore field")
                } else { throw Failure(message: "Redo unavailable after Undo") }
            } else { throw Failure(message: "Undo unavailable after Paste") }
        } else { throw Failure(message: "Input has no undo manager") }
        _ = window.makeFirstResponder(nil)
    }
    static func png(window: NSWindow, to output: URL) throws {
        guard let view = window.contentView else { throw Failure(message: "Missing content view") }
        // Automated responder checks temporarily resize/focus sheets. Restore
        // the main window's minimum drawable area before capturing its content.
        window.makeKeyAndOrderFront(nil)
        let origin = window.frame.origin
        window.setFrame(NSRect(origin: origin, size: NSSize(width: 1260, height: 760)), display: true)
        window.setContentSize(NSSize(width: 1260, height: 760))
        if view.bounds.height <= 0 { view.setFrameSize(NSSize(width: 1260, height: 700)) }
        view.layoutSubtreeIfNeeded()
        NSApp.updateWindows(); view.displayIfNeeded()
        let width = Int(ceil(view.bounds.width)), height = Int(ceil(view.bounds.height))
        guard width > 0, height > 0 else { throw Failure(message: "Window has no drawable content size: \(view.bounds)") }
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) ?? NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap else { throw Failure(message: "Cannot allocate \(width)×\(height) screenshot bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else { throw Failure(message: "No PNG representation") }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
    }
}
#endif

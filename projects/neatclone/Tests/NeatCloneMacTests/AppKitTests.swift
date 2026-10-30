#if os(macOS)
import AppKit
import XCTest
@testable import NeatClone

@MainActor final class AppKitTests: XCTestCase {
    func testStandardMenusUseResponderChainAndExpectedShortcuts() async throws {
        _ = NSApplication.shared
        try UIVerification.verifyMenus(UIMenus.make(target: nil))
    }
    func testTextFieldEditingInWindowAndSheet() async throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = app.mainMenu; app.mainMenu = UIMenus.make(target: nil)
        defer { app.mainMenu = menu }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 20, y: 60, width: 350, height: 24)); window.contentView?.addSubview(field)
        try UIVerification.verifyTextField(field, in: window)
        let sheet = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let sheetField = NSTextField(frame: field.frame); sheet.contentView?.addSubview(sheetField)
        window.beginSheet(sheet, completionHandler: nil); sheet.makeKey()
        try UIVerification.verifyTextField(sheetField, in: sheet)
        window.endSheet(sheet); sheet.orderOut(nil); window.orderOut(nil)
    }
    func testGridSelectAllAndCopyActions() async throws {
        final class Rows: NSObject, NSTableViewDataSource { func numberOfRows(in tableView: NSTableView) -> Int { 2 } }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let table = DownloadTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 150)); let rows = Rows()
        table.dataSource = rows; table.allowsMultipleSelection = true; table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.copyText = { "one.mp4\ntwo.mp4" }; window.contentView?.addSubview(table); table.reloadData(); try UIVerification.prepareWindow(window); XCTAssertTrue(window.makeFirstResponder(table)); XCTAssertTrue(window.firstResponder === table)
        XCTAssertTrue(NSApp.sendAction(Selector(("selectAll:")), to: nil, from: nil)); XCTAssertEqual(table.numberOfSelectedRows, 2)
        XCTAssertTrue(NSApp.sendAction(Selector(("copy:")), to: nil, from: nil)); XCTAssertEqual(NSPasteboard.general.string(forType: .string), "one.mp4\ntwo.mp4")
        window.orderOut(nil)
    }
    func testPreferencesRoundTripWithoutStoringCredentials() async throws {
        let name = "org.neatclone.ui-test-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = AppSettings(defaults: defaults); XCTAssertEqual(settings.maxConnections, 8)
        settings.maxConnections = 16; settings.globalBytesPerSecond = try AppSettings.rateFromKiB("2048"); settings.save(to: defaults)
        XCTAssertEqual(AppSettings(defaults: defaults), settings)
        XCTAssertNil(defaults.object(forKey: "password"))
    }
}
#endif

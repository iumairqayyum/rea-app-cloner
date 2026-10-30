import Foundation
import NeatCloneCore

// Chrome supplies the caller origin; the installer pins an exact allowed origin
// in both Chrome's host manifest and this launcher's environment.
let environment = ProcessInfo.processInfo.environment
guard let expected = environment["NEATCLONE_ALLOWED_ORIGIN"],
      expected.hasPrefix("chrome-extension://"),
      CommandLine.arguments.count >= 2, CommandLine.arguments[1] == expected else {
    exit(1)
}
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let inbox = environment["NEATCLONE_INBOX_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? support.appendingPathComponent("NeatClone/Inbox", isDirectory: true)
while true {
    do {
        guard let data = try NativeFrame.read(from: .standardInput) else { break }
        let request = try JSONDecoder().decode(BridgeRequest.self, from: data)
        _ = try request.validatedURL()
        let entry = InboxEntry(request: request)
        try entry.write(to: inbox)
        #if os(macOS)
        let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = [app.path]
        launch.standardOutput = FileHandle.nullDevice; launch.standardError = FileHandle.nullDevice
        try launch.run(); launch.waitUntilExit()
        guard launch.terminationStatus == 0 else { throw BridgeFailure.unsupported }
        #endif
        let reply = try JSONSerialization.data(withJSONObject: ["ok": true, "id": entry.id.uuidString])
        try NativeFrame.write(reply, to: .standardOutput)
    } catch {
        // Never echo URL, signed query, browser context, or filesystem details.
        let reply = Data("{\"ok\":false,\"error\":\"Request rejected or application unavailable\"}".utf8)
        try? NativeFrame.write(reply, to: .standardOutput)
        break
    }
}

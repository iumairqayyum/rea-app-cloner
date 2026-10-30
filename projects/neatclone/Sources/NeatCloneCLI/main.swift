import Foundation
import NeatCloneCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main struct NeatCloneCLI {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3, ["download", "import-inbox"].contains(args[0]) else {
            fputs("Usage: NeatCloneCLI download URL DESTINATION_DIRECTORY [--hls]\n       NeatCloneCLI import-inbox INBOX_DIRECTORY DESTINATION_DIRECTORY\n", stderr); exit(2)
        }
        do {
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            let state = directory.appendingPathComponent(".neatclone-cli-queue.json")
            let queue = try DownloadQueue(stateURL: state)
            let ids: [UUID]
            if args[0] == "import-inbox" {
                ids = try queue.importInbox(from: URL(fileURLWithPath: args[1], isDirectory: true), directory: directory)
            } else {
                guard let url = URL(string: args[1]) else { throw DownloadError.invalidURL }
                ids = [try queue.enqueue(url: url, kind: args.contains("--hls") ? .hls : .direct, directory: directory)]
            }
            while true {
                let selected = queue.jobs.filter { ids.contains($0.id) }
                guard selected.count == ids.count else { exit(1) }
                if selected.allSatisfy({ $0.status == .completed }) {
                    for job in selected { print("Saved \(job.fileName)") }; return
                }
                if let failed = selected.first(where: { [.failed, .cancelled].contains($0.status) }) {
                    fputs((failed.error ?? "Download stopped") + "\n", stderr); exit(1)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        } catch {
            fputs(((error as? DownloadError)?.errorDescription ?? "Download could not start") + "\n", stderr)
            exit(1)
        }
    }
}

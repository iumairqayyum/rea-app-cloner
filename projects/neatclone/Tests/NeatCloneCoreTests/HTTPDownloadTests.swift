import XCTest
@testable import NeatCloneCore

/// Real loopback HTTP responses, including interrupted transfers and adversarial
/// resume metadata. The fixture code belongs to this test, not the inspected app.
final class HTTPDownloadTests: XCTestCase {
    private let body = Data((0..<262144).map { UInt8($0 % 251) })
    private final class Server {
        let root: URL
        let process: Process
        let url: URL
        init(mode: String) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let ready = root.appendingPathComponent("port")
            process = Process()
            guard let python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw DownloadError.transport }
            process.executableURL = URL(fileURLWithPath: python)
            let script = #"""
import http.server,sys,time,pathlib,signal
signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGTERM})
signal.signal(signal.SIGTERM,signal.SIG_DFL)
mode=sys.argv[2]
data=bytes(i%251 for i in range(262144))
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_GET(self):
  start=0; status=200; etag='"v1"'
  r=self.headers.get('Range')
  if r:
   pathlib.Path(sys.argv[1]+'.range').write_text(r)
  if r and mode not in ('ignore','changed'):
   start=int(r.split('=')[1].split('-')[0]);status=206
  if mode=='changed':etag='"v2"'
  self.send_response(status)
  self.send_header('ETag',etag)
  self.send_header('Content-Type','video/mp4')
  self.send_header('Content-Length',str(len(data)-start))
  if status==206:
   advertised=start+1 if mode=='bad' else start
   self.send_header('Content-Range',f'bytes {advertised}-{len(data)-1}/{len(data)}')
  self.end_headers()
  try:
   for i in range(start,len(data),4096):
    self.wfile.write(data[i:i+4096]);self.wfile.flush()
    if mode=='slow':time.sleep(.02)
  except (BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
"""#
            process.arguments = ["-u", "-c", script, ready.path, mode]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            var port: Int?
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline && process.isRunning {
                port = (try? String(contentsOf: ready)).flatMap(Int.init)
                if port != nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let port else { process.terminate(); throw DownloadError.transport }
            url = URL(string: "http://127.0.0.1:\(port)/video.mp4")!
        }
        deinit {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
    }
    private func seed(server: Server) throws -> (URL, URL) {
        let work = server.root.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try body.prefix(32000).write(to: work.appendingPathComponent("download.part"))
        let record: [String: Any] = ["url": server.url.absoluteString, "validator": "\"v1\"", "total": body.count]
        try JSONSerialization.data(withJSONObject: record).write(to: work.appendingPathComponent("resume.json"))
        return (work, server.root.appendingPathComponent("result.mp4"))
    }
    func testRangeResumeAndNonRangeAndChangedResourceRestart() async throws {
        for mode in ["range", "ignore", "changed"] {
            let server = try await Server(mode: mode)
            let (work, final) = try seed(server: server)
            try await DirectDownloader().download(url: server.url, destination: final, workingDirectory: work)
            XCTAssertEqual(try Data(contentsOf: final), body, mode)
            XCTAssertEqual(try String(contentsOf: server.root.appendingPathComponent("port.range")), "bytes=32000-")
        }
    }
    func testWrongRangeCannotCorruptSavedFileAndNextRetryIsFresh() async throws {
        let server = try await Server(mode: "bad")
        let (work, final) = try seed(server: server)
        do {
            try await DirectDownloader().download(url: server.url, destination: final, workingDirectory: work)
            XCTFail("Incorrect range must not succeed")
        } catch { XCTAssertEqual(error as? DownloadError, .invalidRange) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("resume.json").path))
        try await DirectDownloader().download(url: server.url, destination: final, workingDirectory: work)
        XCTAssertEqual(try Data(contentsOf: final), body)
    }
    @MainActor func testPauseResumeQueueWritesExactBody() async throws {
        let server = try await Server(mode: "slow")
        let queue = try DownloadQueue(stateURL: server.root.appendingPathComponent("queue.json"))
        let id = try queue.enqueue(url: server.url, directory: server.root)
        for _ in 0..<100 {
            if queue.jobs[0].bytes > 8192 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(queue.jobs[0].bytes, 8192)
        queue.pause(id)
        XCTAssertEqual(queue.jobs[0].status, .paused)
        try await Task.sleep(nanoseconds: 100_000_000)
        queue.resume(id)
        for _ in 0..<250 {
            if [.completed, .failed].contains(queue.jobs[0].status) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(queue.jobs[0].status, .completed, queue.jobs[0].error ?? "")
        XCTAssertEqual(try Data(contentsOf: queue.jobs[0].destination), body)
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("port.range").path))
    }
}

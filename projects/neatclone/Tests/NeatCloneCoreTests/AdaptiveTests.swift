import XCTest
@testable import NeatCloneCore

final class AdaptiveTests: XCTestCase {
    final class Server {
        let root: URL
        let reaper: ChildProcessReaper
        let base: URL
        let size: Int
        init(size: Int = 2_097_152) async throws {
            self.size = size
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard let python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw DownloadError.transport }
            let process = Process(); process.executableURL = URL(fileURLWithPath: python)
            let script = #"""
import http.server,sys,time,pathlib,signal,os
signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGTERM})
signal.signal(signal.SIGTERM,signal.SIG_DFL)
root=pathlib.Path(sys.argv[1]);size=int(sys.argv[2])
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  r=self.headers.get('Range');start=0;end=size-1;status=200
  if r and not self.path.startswith('/ignore'):
   a,b=r.split('=')[1].split('-');start=int(a);end=int(b) if b else size-1;status=206
  with (root/'requests').open('a') as f:f.write(f'{self.path} {start}-{end} {status}\n')
  if self.path.startswith('/forbidden'):
   self.send_response(403);self.send_header('Content-Length','1');self.end_headers();self.wfile.write(b'x');return
  if self.path.startswith('/badfull') and not r:status=206
  if self.path.startswith('/retry') and end>0:
   try:
    fd=os.open(root/'retried',os.O_CREAT|os.O_EXCL|os.O_WRONLY);os.close(fd)
    self.send_response(503);self.send_header('Content-Length','0');self.end_headers();return
   except FileExistsError:pass
  self.send_response(status);self.send_header('ETag','"stable"');self.send_header('Content-Length',str(end-start+1));self.send_header('Content-Type','application/octet-stream')
  if status==206:
   advertised=start+1 if self.path.split('?',1)[0] in ('/bad','/badfull') or (self.path.startswith('/badlater') and end>0) else start
   self.send_header('Content-Range',f'bytes {advertised}-{end}/{size}')
  self.end_headers()
  try:
   for index in range(start,end+1,16384):
    stop=min(index+16384,end+1)
    chunk=bytes(((i%251)^255 if self.path.startswith('/evil') else i%251) for i in range(index,stop))
    self.wfile.write(chunk);self.wfile.flush();time.sleep(.002)
  except (BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_port));server.serve_forever()
"""#
            process.arguments = ["-u", "-c", script, root.path, String(size)]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            reaper = try ChildProcessReaper(process)
            var port: Int?
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                port = (try? String(contentsOf: root.appendingPathComponent("port"))).flatMap(Int.init)
                if port != nil { break }; try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let port else { reaper.terminate(); throw DownloadError.transport }
            base = URL(string: "http://127.0.0.1:\(port)")!
        }
        deinit {
            reaper.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        var body: Data { Data((0..<size).map { UInt8($0 % 251) }) }
        func url(_ path: String = "file.bin") -> URL { base.appendingPathComponent(path) }
    }
    final class Connections: @unchecked Sendable {
        private let lock = NSLock()
        private var maximum = 0
        func observe(_ count: Int) { lock.lock(); maximum = Swift.max(maximum, count); lock.unlock() }
        var max: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    }
    func testConcurrentRangesWriteExactFileAndRespectCeiling() async throws {
        let server = try await Server()
        let destination = server.root.appendingPathComponent("result")
        let connections = Connections()
        try await AdaptiveDownloader(options: TransferOptions(maxConnections: 4)).download(url: server.url(), destination: destination,
            workingDirectory: server.root.appendingPathComponent("work"), onConnections: { connections.observe($0) })
        XCTAssertEqual(try Data(contentsOf: destination), server.body)
        XCTAssertGreaterThan(connections.max, 1); XCTAssertLessThanOrEqual(connections.max, 4)
    }
    func testNoRangeFallsBackAndInvalidRangeNeverCommits() async throws {
        let server = try await Server(size: 262_144)
        let final = server.root.appendingPathComponent("fallback")
        try await AdaptiveDownloader().download(url: server.url("ignore"), destination: final, workingDirectory: server.root.appendingPathComponent("work"))
        XCTAssertEqual(try Data(contentsOf: final), server.body)
        let fallbackConnections = Connections()
        let recovered = server.root.appendingPathComponent("bad-range-recovered")
        try await AdaptiveDownloader(options: TransferOptions(maxConnections: 8)).download(url: server.url("badlater"), destination: recovered,
            workingDirectory: server.root.appendingPathComponent("bad-range-work"), onConnections: { fallbackConnections.observe($0) })
        XCTAssertEqual(try Data(contentsOf: recovered), server.body)
        XCTAssertEqual(fallbackConnections.max, 1, "A malformed range response must fall back to one validated streaming request")
        let fallbackRequests = try String(contentsOf: server.root.appendingPathComponent("requests"))
            .components(separatedBy: .newlines).filter { $0.contains("/badlater") }
        XCTAssertGreaterThanOrEqual(fallbackRequests.count, 3, "Probe and rejected ranges must be followed by a fresh stream")
        XCTAssertTrue(fallbackRequests.contains(where: { $0.hasSuffix("206") }))
        XCTAssertTrue(fallbackRequests.last?.hasSuffix("200") == true)
        let bad = server.root.appendingPathComponent("bad-result")
        do {
            try await AdaptiveDownloader().download(url: server.url("badfull"), destination: bad, workingDirectory: server.root.appendingPathComponent("bad-work"))
            XCTFail("Range mismatch must not commit")
        } catch { XCTAssertEqual(error as? DownloadError, .invalidRange) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
    }
    func testHTTP403IsSurfacedAndNeverCreatesOutput() async throws {
        let server = try await Server(size: 100_000_000)
        let destination = server.root.appendingPathComponent("forbidden.bin")
        do {
            try await AdaptiveDownloader().download(url: server.url("forbidden"), destination: destination,
                workingDirectory: server.root.appendingPathComponent("forbidden-work"))
            XCTFail("HTTP 403 must remain a server refusal")
        } catch { XCTAssertEqual(error as? DownloadError, .http(403)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let requests = try String(contentsOf: server.root.appendingPathComponent("requests"))
        XCTAssertEqual(requests.components(separatedBy: .newlines).filter { !$0.isEmpty }.count, 1, "A permanent 403 must not trigger a sequential retry")
    }
    func testCheckpointResumeAndRefreshRejectsSameValidatorDifferentContent() async throws {
        let server = try await Server()
        let work = server.root.appendingPathComponent("partial"), final = server.root.appendingPathComponent("resumed")
        let original = server.url()
        let task = Task { try await AdaptiveDownloader(options: TransferOptions(maxConnections: 3, bytesPerSecond: 1_048_576)).download(url: original, destination: final, workingDirectory: work) }
        let manifest = work.appendingPathComponent("ranges.json")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: manifest.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        do { try await task.value; XCTFail("Transfer should be paused") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        let before = try Data(contentsOf: manifest)
        do {
            try await AdaptiveDownloader.validateRefresh(original: original, replacement: server.url("evil"), workingDirectory: work)
            XCTFail("Reused ETag and length cannot authorize unrelated bytes")
        } catch { XCTAssertEqual(error as? DownloadError, .invalidRange) }
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        try await AdaptiveDownloader.validateRefresh(original: original, replacement: server.url("renewed"), workingDirectory: work)
        try await AdaptiveDownloader(options: TransferOptions(maxConnections: 4)).download(url: server.url("renewed"), destination: final, workingDirectory: work)
        XCTAssertEqual(try Data(contentsOf: final), server.body)
    }
    func testRefreshWithoutTrustedPartialIsRefused() async throws {
        let server = try await Server(size: 1024)
        do {
            try await AdaptiveDownloader.validateRefresh(original: server.url(), replacement: server.url("renewed"), workingDirectory: server.root)
            XCTFail("Missing checkpoint must not be refreshed")
        } catch {}
    }
    func testResumeDetectsCorruptedCachedQuantum() async throws {
        let server = try await Server()
        let work = server.root.appendingPathComponent("corrupt-work"), destination = server.root.appendingPathComponent("corrected")
        let task = Task { try await AdaptiveDownloader(options: TransferOptions(maxConnections: 2, bytesPerSecond: 1_048_576)).download(url: server.url(), destination: destination, workingDirectory: work) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: work.appendingPathComponent("ranges.json").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel(); _ = try? await task.value
        let part = try FileHandle(forUpdating: work.appendingPathComponent("ranges.part"))
        try part.seek(toOffset: 0); try part.write(contentsOf: Data(repeating: 255, count: 4096)); try part.close()
        try await AdaptiveDownloader().download(url: server.url(), destination: destination, workingDirectory: work)
        XCTAssertEqual(try Data(contentsOf: destination), server.body)
    }
    func testMeasuredAdaptiveAndFallbackThroughput() async throws {
        for path in ["file.bin", "ignore"] {
            let server = try await Server(size: 262_144)
            let began = ProcessInfo.processInfo.systemUptime
            let final = server.root.appendingPathComponent("throttled")
            try await AdaptiveDownloader(options: TransferOptions(maxConnections: 4, bytesPerSecond: 131_072)).download(url: server.url(path), destination: final, workingDirectory: server.root.appendingPathComponent("work"))
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            print("Measured \(path) 262144 bytes in \(elapsed) seconds at configured 131072 B/s")
            XCTAssertGreaterThanOrEqual(elapsed, 1.8); XCTAssertLessThan(elapsed, 4.5)
            XCTAssertEqual(try Data(contentsOf: final), server.body)
        }
    }
    func testAuthorizationRequiresExactHTTPSOrigin() {
        let auth = TransferAuthorization(host: "example.org", value: "Basic test", port: 8443)
        XCTAssertNotNil(auth.header(for: URL(string: "https://example.org:8443/a")!))
        XCTAssertNil(auth.header(for: URL(string: "https://example.org/a")!))
        XCTAssertNil(auth.header(for: URL(string: "http://example.org:8443/a")!))
        XCTAssertNil(auth.header(for: URL(string: "https://other.org:8443/a")!))
    }
    func testServerBackoffRetriesRepartitionedWorkWithoutCorruption() async throws {
        let server = try await Server()
        let final = server.root.appendingPathComponent("retried-result")
        try await AdaptiveDownloader(options: TransferOptions(maxConnections: 4)).download(url: server.url("retry"), destination: final, workingDirectory: server.root.appendingPathComponent("work"))
        XCTAssertEqual(try Data(contentsOf: final), server.body)
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("retried").path))
        let requests = try String(contentsOf: server.root.appendingPathComponent("requests"))
        XCTAssertGreaterThan(requests.components(separatedBy: .newlines).filter { !$0.isEmpty }.count, 5)
    }
    func testActualConcurrentDownloadsShareGlobalRateCeiling() async throws {
        let server = try await Server(size: 131_072)
        let limiter = ByteRateLimiter(rate: 131_072)
        let began = ProcessInfo.processInfo.systemUptime
        async let first: Void = AdaptiveDownloader(globalLimiter: limiter).download(url: server.url(), destination: server.root.appendingPathComponent("one"), workingDirectory: server.root.appendingPathComponent("one-work"))
        async let second: Void = AdaptiveDownloader(globalLimiter: limiter).download(url: server.url(), destination: server.root.appendingPathComponent("two"), workingDirectory: server.root.appendingPathComponent("two-work"))
        _ = try await (first, second)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        print("Two concurrent downloads totaling 262144 bytes completed in \(elapsed) seconds under shared 131072 B/s limit")
        XCTAssertGreaterThanOrEqual(elapsed, 1.8); XCTAssertLessThan(elapsed, 4.5)
        XCTAssertEqual(try Data(contentsOf: server.root.appendingPathComponent("one")), server.body)
        XCTAssertEqual(try Data(contentsOf: server.root.appendingPathComponent("two")), server.body)
    }
    func test100MBStreamResumesWithBoundedRangesAndExactSize() async throws {
        let size = 100_000_000
        let server = try await Server(size: size)
        let destination = server.root.appendingPathComponent("large.bin")
        let work = server.root.appendingPathComponent("large-work")
        let firstPass = Task {
            try await AdaptiveDownloader(options: TransferOptions(maxConnections: 8, bytesPerSecond: 1_048_576)).download(
                url: server.url(), destination: destination, workingDirectory: work)
        }
        let manifest = work.appendingPathComponent("ranges.json")
        var hasCheckpoint = false
        for _ in 0..<600 {
            if let data = try? Data(contentsOf: manifest),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let completed = object["completed"] as? [Int], !completed.isEmpty { hasCheckpoint = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(hasCheckpoint, "Large transfer should persist a validated range before interruption")
        firstPass.cancel()
        do { try await firstPass.value; XCTFail("First pass should be cancelled") } catch { }

        let connections = Connections()
        try await AdaptiveDownloader(options: TransferOptions(maxConnections: 8)).download(url: server.url(), destination: destination,
            workingDirectory: work, onConnections: { connections.observe($0) })
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, Int64(size))
        XCTAssertGreaterThan(connections.max, 1)
        XCTAssertLessThanOrEqual(connections.max, 8)
        let handle = try FileHandle(forReadingFrom: destination); defer { try? handle.close() }
        var offsets = Array(stride(from: 0, to: size, by: 8 * 1024 * 1024))
        offsets.append(size - 65_536)
        for offset in Set(offsets) {
            let count = min(65_536, size - offset)
            try handle.seek(toOffset: UInt64(offset))
            let actual = try XCTUnwrap(handle.read(upToCount: count))
            let expected = Data((offset..<(offset + count)).map { UInt8($0 % 251) })
            XCTAssertEqual(actual, expected, "Resumed content mismatch at byte \(offset)")
        }
    }
}

import XCTest
@testable import NeatCloneCore

final class HLSTests: XCTestCase {
    let base = URL(string: "https://media.example/path/main.m3u8?token=secret")!
    func testVODAndRelativePaths() throws {
        let value = try HLSPlaylist.parse("#EXTM3U\n#EXTINF:2.5,\n../video.ts\n#EXT-X-ENDLIST", baseURL: base)
        XCTAssertEqual(value.segments.count, 1)
        XCTAssertEqual(value.segments[0].duration, 2.5)
        XCTAssertEqual(value.segments[0].url.absoluteString, "https://media.example/video.ts")
    }
    func testMasterAudioGroupAndQuotedAttributes() throws {
        let value = try HLSPlaylist.parse("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="English, stereo",DEFAULT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="sound"
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000,AUDIO="sound"
        high.m3u8
        """, baseURL: base)
        XCTAssertEqual(value.variants.count, 2)
        XCTAssertEqual(value.variants.max(by: {$0.bandwidth < $1.bandwidth})?.url.lastPathComponent, "high.m3u8")
        XCTAssertEqual(value.audio["sound"]?.lastPathComponent, "audio.m3u8")
    }
    func testRejectEncryptionLiveByteRangesAndFileURLs() {
        for playlist in [
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8",
            "#EXTM3U\n#EXTINF:1,\na.ts",
            "#EXTM3U\n#EXT-X-BYTERANGE:100@0\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXT-X-DISCONTINUITY\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXTINF:1,\nfile:///etc/passwd\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXTINF:1,\nhttps://user:password@host/file.ts\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXTINF:\na.ts\n#EXT-X-ENDLIST"
        ] { XCTAssertThrowsError(try HLSPlaylist.parse(playlist, baseURL: base)) }
    }
    func testFragmentedMP4Initialization() throws {
        let value = try HLSPlaylist.parse("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:1,\na.m4s\n#EXT-X-ENDLIST", baseURL: base)
        XCTAssertEqual(value.initialization?.lastPathComponent, "init.mp4")
        XCTAssertThrowsError(try HLSPlaylist.parse("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"100@0\"\n#EXTINF:1,\na.m4s\n#EXT-X-ENDLIST", baseURL: base))
    }
    func testMissingAudioGroupAndVariablePlaylistsAreRefused() throws {
        XCTAssertThrowsError(try HLSPlaylist.parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO=\"missing\"\na.m3u8",baseURL:base))
        let inBand = try HLSPlaylist.parse("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"sound\",NAME=\"in-band\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO=\"sound\"\na.m3u8",baseURL:base)
        XCTAssertTrue(inBand.inBandAudio.contains("sound"))
        XCTAssertThrowsError(try HLSPlaylist.parse("#EXTM3U\n#EXT-X-DEFINE:NAME=\"token\",VALUE=\"abc\"\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST",baseURL:base))
        XCTAssertThrowsError(try HLSPlaylist.parse("#EXTM3U\n#EXTINF:1,\n{$host}/a.ts\n#EXT-X-ENDLIST",baseURL:base))
    }
    func testLimitsAndMalformedDurations() {
        for duration in ["nan", "inf", "-1", "0", "90000"] {
            XCTAssertThrowsError(try HLSPlaylist.parse("#EXTM3U\n#EXTINF:\(duration),\na.ts\n#EXT-X-ENDLIST", baseURL: base))
        }
        XCTAssertThrowsError(try HLSPlaylist.parse("#EXTM3U\n" + String(repeating:"x",count:1_048_576), baseURL:base))
    }

    @discardableResult
    func run(_ command: String, _ arguments: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: command); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Fixture command failed: \(command)")
        return bytes
    }
    func testUnencryptedHLSRemuxPreservesVideoAndAudio() async throws {
        try await verifyRemux(fragmented: false)
    }
    func testMasterFragmentedMP4WithSeparateAudio() async throws {
        try await verifyRemux(fragmented: true)
    }
    func verifyRemux(fragmented: Bool) async throws {
        let ffmpeg = ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath:$0) }
        let python = ["/usr/bin/python3", "/usr/local/bin/python3"].first { FileManager.default.isExecutableFile(atPath:$0) }
        guard let ffmpeg = ffmpeg, let python = python else { throw XCTSkip("Integration requires FFmpeg and Python 3") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fixture = directory.appendingPathComponent("main.m3u8")
        var arguments = ["-nostdin","-v","error","-f","lavfi","-i","testsrc=size=64x64:rate=10","-f","lavfi","-i","sine=frequency=440:sample_rate=48000","-t","2","-c:v","libx264","-pix_fmt","yuv420p","-g","10","-c:a","aac","-f","hls","-hls_time","1","-hls_playlist_type","vod"]
        if fragmented { arguments += ["-hls_segment_type","fmp4"] }
        try run(ffmpeg, arguments + [fixture.path])
        if fragmented {
            try run(ffmpeg,["-nostdin","-v","error","-f","lavfi","-i","sine=frequency=440:sample_rate=48000","-t","2","-c:a","aac","-f","hls","-hls_time","1","-hls_playlist_type","vod","-hls_segment_type","fmp4","-hls_fmp4_init_filename","audio-init.mp4",directory.appendingPathComponent("audio.m3u8").path])
            try Data("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"sound\",DEFAULT=YES,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=100000,AUDIO=\"sound\"\nmain.m3u8\n".utf8).write(to:directory.appendingPathComponent("master.m3u8"))
        }
        let server = Process(); server.executableURL = URL(fileURLWithPath:python)
        let ready = directory.appendingPathComponent("server-port")
        server.arguments = ["-u","-c","import http.server,os,pathlib,sys,signal;signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGTERM});os.chdir(sys.argv[1]);s=http.server.ThreadingHTTPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler);pathlib.Path('server-port').write_text(str(s.server_port));s.serve_forever()", directory.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath:ready.path) || !server.isRunning { break }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        let port = (try? String(contentsOf:ready,encoding:.utf8)) ?? ""
        guard let number = Int(port), number > 0 else { throw NSError(domain:"HLSFixture",code:1,userInfo:[NSLocalizedDescriptionKey:"Local HTTP fixture could not start; check loopback execution permissions"]) }
        let destination = directory.appendingPathComponent("output.mp4")
        let filename = fragmented ? "master.m3u8" : "main.m3u8"
        try await HLSDownloader(ffmpeg:URL(fileURLWithPath:ffmpeg)).download(url:URL(string:"http://127.0.0.1:\(port)/\(filename)")!,destination:destination,workingDirectory:directory.appendingPathComponent("work"),progress:{_,_ in})
        XCTAssertTrue(FileManager.default.fileExists(atPath:destination.path))
        let probe = URL(fileURLWithPath:ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        let result = try run(probe,["-v","error","-show_streams","-of","json",destination.path])
        let object = try JSONSerialization.jsonObject(with:result) as! [String:Any]
        let streams = object["streams"] as! [[String:Any]]
        XCTAssertEqual(Set(streams.compactMap{$0["codec_type"] as? String}),Set(["video","audio"]))
        let durations = streams.compactMap{Double($0["duration"] as? String ?? "")}
        XCTAssertEqual(durations.count,2)
        XCTAssertLessThan(abs(durations[0]-durations[1]),0.15)
        XCTAssertTrue(durations.allSatisfy{abs($0-2)<0.2})
    }
}

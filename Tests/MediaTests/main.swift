// Checks the TS remuxer and the DASH downloader against files made by ffmpeg.
// Run on macOS: swiftc NiceYT/Browser/TSRemuxer.swift NiceYT/Browser/DASHDownloader.swift Tests/MediaTests/main.swift
import AVFoundation
import Foundation

var failures = 0

func check(_ name: String, _ url: URL, expectVideo: Bool = true, expectAudio: Bool = true, seconds: Double) async {
    let asset = AVURLAsset(url: url)
    let duration = (try? await asset.load(.duration).seconds) ?? 0
    let video = ((try? await asset.loadTracks(withMediaType: .video)) ?? []).count
    let audio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).count
    let ok = abs(duration - seconds) < 1.0 && (video > 0) == expectVideo && (audio > 0) == expectAudio
    print("\(ok ? "PASS" : "FAIL") \(name): \(String(format: "%.2f", duration)) s, video \(video), audio \(audio)")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath)

for name in ["h264.ts", "hevc.ts", "audio.ts"] {
    let input = dir.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: input.path) else { continue }
    let output = dir.appendingPathComponent(name + ".mp4")
    do {
        try await TSRemuxer.remux(input, to: output)
        await check("TS \(name)", output, expectVideo: name != "audio.ts", seconds: 6)
    } catch {
        print("FAIL TS \(name): \(error.localizedDescription)")
        failures += 1
    }
}

for name in ["timeline", "number", "single"] {
    guard let url = URL(string: "http://127.0.0.1:8765/\(name)/manifest.mpd") else { continue }
    do {
        let file = try await DASHDownloader.download(url) { _ in }
        await check("DASH \(name)", file, seconds: 6)
    } catch {
        print("FAIL DASH \(name): \(error.localizedDescription)")
        failures += 1
    }
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

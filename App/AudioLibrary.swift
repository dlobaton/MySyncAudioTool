import AVFoundation
import CryptoKit
import Foundation

struct AudioLibrary {
    let songs: [URL]
    let fingerprint: (UInt64, UInt64)

    static func load() throws -> AudioLibrary {
        let directory = Bundle.main.bundleURL.appendingPathComponent("songs", isDirectory: true)
        let songs: [URL]
        if FileManager.default.fileExists(atPath: directory.path) {
            songs = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)
                .filter {
                    guard ["mp3", "wav"].contains($0.pathExtension.lowercased()) else { return false }
                    return try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                }
                .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        } else {
            songs = []
        }
        var playlist = SHA256()
        playlist.update(data: Data("MySyncAudioTool/2".utf8))
        for url in songs {
            var file = SHA256()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                file.update(data: chunk)
            }
            playlist.update(data: Data(url.lastPathComponent.utf8))
            playlist.update(data: Data([0]))
            playlist.update(data: Data(file.finalize()))
        }
        let bytes = Array(playlist.finalize())
        func word(_ start: Int) -> UInt64 {
            bytes[start..<start + 8].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        return AudioLibrary(songs: songs, fingerprint: (word(0), word(8)))
    }

    static func clickTest(silent: Bool = false) -> Data {
        let rate = 48_000
        let frames = silent ? rate / 10 : rate * 3
        let burst = rate / 50
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func int(_ value: UInt32, bytes: Int) {
            for i in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
        }
        text("RIFF"); int(UInt32(36 + frames * 2), bytes: 4); text("WAVEfmt ")
        int(16, bytes: 4); int(1, bytes: 2); int(1, bytes: 2)
        int(UInt32(rate), bytes: 4); int(UInt32(rate * 2), bytes: 4)
        int(2, bytes: 2); int(16, bytes: 2)
        text("data"); int(UInt32(frames * 2), bytes: 4)
        if silent {
            data.append(Data(count: frames * 2))
            return data
        }
        for frame in 0..<frames {
            let phase = frame % rate - rate / 4
            let sample: Int16
            if (0..<burst).contains(phase) {
                let envelope = sin(.pi * Double(phase) / Double(burst))
                let wave = sin(2 * .pi * 1_800 * Double(phase) / Double(rate))
                sample = Int16(10_000 * wave * envelope * envelope)
            } else {
                sample = 0
            }
            int(UInt32(UInt16(bitPattern: sample)), bytes: 2)
        }
        return data
    }
}

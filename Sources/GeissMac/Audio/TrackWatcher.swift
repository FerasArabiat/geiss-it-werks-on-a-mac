import Foundation

/// Reports the currently playing track as "Artist - Title" (the shape of the
/// original Winamp plug-in's song title), for the song-title popup.
///
/// Reads macOS's Now Playing info through the NowPlayingHelper library run
/// inside /usr/bin/perl (see Sources/NowPlayingHelper) — covers the Spotify
/// and Music apps and browser players alike. If the helper is missing or
/// can't start, there's simply no song title.
final class TrackWatcher {
    /// Called on the main thread with each newly playing track.
    var onTrack: ((String) -> Void)?

    private var helper: Process?
    private var lastTrack: String?

    private static let helperScript = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $sym = DynaLoader::dl_find_symbol($lib, "geissmac_now_playing_loop") or die DynaLoader::dl_error();
        DynaLoader::dl_install_xsub("main::now_playing_loop", $sym);
        now_playing_loop();
        """

    /// The app ships the helper in Contents/Resources; under `swift run` it
    /// sits next to the executable once `swift build` has built all products.
    private static func helperURL() -> URL? {
        let name = "libNowPlayingHelper.dylib"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func start() {
        guard let dylib = Self.helperURL() else {
            print("GeissMac: Now Playing helper not found; no song titles.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.helperScript, dylib.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let info = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                DispatchQueue.main.async { self?.handleNowPlaying(info) }
            }
        }
        do {
            try process.run()
        } catch {
            print("GeissMac: couldn't start the Now Playing helper — \(error)")
            return
        }
        helper = process
    }

    func stop() {
        helper?.terminate()
        helper = nil
    }

    private func handleNowPlaying(_ info: [String: Any]) {
        guard info["playing"] as? Bool == true, let title = info["title"] as? String, !title.isEmpty else { return }
        let artist = info["artist"] as? String
        let track = artist.map { $0.isEmpty ? title : "\($0) - \(title)" } ?? title
        guard track != lastTrack else { return }
        lastTrack = track
        onTrack?(track)
    }
}

import Foundation

/// The original's per-mode star ratings (`modeprefs`, 0-5), which weight
/// the automatic mode picker. Defaults are the original's
/// (Sysstuff.h:375-380 — modes 5-9 favored, 12 and 15 rarely picked);
/// '<' / '>' adjust the current mode and are persisted as JSON in
/// Application Support (the original used the registry). The port's mode
/// 26 starts at a neutral 3.
final class ModeRatings {
    private static let defaults = [0, 3, 3, 3, 3, 5, 5, 5, 5, 5,  // 01-09 (index 0 unused)
                                   3, 3, 1, 3, 3, 2, 3, 4, 3, 3,  // 10-19
                                   3, 3, 3, 3, 3, 3,              // 20-25
                                   3]                             // 26 (port)
    private var stars = ModeRatings.defaults
    private let url: URL?

    init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GeissMac/mode-ratings.json")
        guard let url, let data = try? Data(contentsOf: url) else { return }
        do {
            for (key, value) in try JSONDecoder().decode([String: Int].self, from: data) {
                if let mode = Int(key), Modes.all.contains(mode) {
                    stars[mode] = min(5, max(0, value))
                }
            }
        } catch {
            print("GeissMac: couldn't read mode ratings at \(url.path) — \(error)")
        }
    }

    func stars(for mode: Int) -> Int? {
        Modes.all.contains(mode) ? stars[mode] : nil
    }

    /// Clamped to 0-5 and saved; returns the new rating.
    func adjust(mode: Int, by delta: Int) -> Int? {
        guard Modes.all.contains(mode) else { return nil }
        stars[mode] = min(5, max(0, stars[mode] + delta))
        save()
        return stars[mode]
    }

    /// `FX_Pick_Random_Mode` (main.cpp:4277): weighted by stars; if every
    /// mode is rated 0, uniform with an extra 1-in-25 pull each toward 7 and 5.
    func pickMode() -> Int {
        let total = stars[1...].reduce(0, +)
        guard total > 0 else {
            var mode = Int.random(in: Modes.all)
            if Int.random(in: 0..<25) == 0 { mode = 7 }
            if Int.random(in: 0..<25) == 0 { mode = 5 }
            return mode
        }
        var remaining = Int.random(in: 0..<total)
        for mode in Modes.all {
            remaining -= stars[mode]
            if remaining < 0 { return mode }
        }
        return Modes.count
    }

    private func save() {
        guard let url else { return }
        let entries = Dictionary(uniqueKeysWithValues: Modes.all.map { (String(format: "%02d", $0), stars[$0]) })
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            print("GeissMac: couldn't save mode ratings to \(url.path) — \(error)")
        }
    }
}

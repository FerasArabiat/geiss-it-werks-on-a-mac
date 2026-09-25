import Foundation

/// A saved look — the original's numbered presets (Effects.h SavePreset /
/// LoadPreset, `[PRESET n]` sections of GEISS.INI): mode, its rolled motion
/// parameters (the original's t1/t2/s1/s2/f1-f4 and damping), waveform,
/// center, effect flags, slide shift and wave gain, plus the 8-bit palette
/// (nil in presets saved before the 8-bit look existed).
struct Preset: Codable {
    var mode: Int
    var motion: ModeMotion
    var waveformType: Int
    var centerOffset: SIMD2<Float>
    var chaserCount: Int
    var barEnabled: Bool
    var dotsEnabled: Bool
    var solarEnabled: Bool
    var gridEnabled: Bool
    var nuclideEnabled: Bool
    var shadeEnabled: Bool
    var slideShiftEnabled: Bool
    var waveScaleStep: Int
    var palette: EightBitPalette?
}

/// Presets 00-99, persisted as JSON in Application Support (in place of
/// the original's GEISS.INI).
final class PresetStore {
    private var presets: [String: Preset] = [:]
    private let url: URL?

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GeissMac", isDirectory: true)
        url = directory?.appendingPathComponent("presets.json")
        if let url, let data = try? Data(contentsOf: url) {
            do {
                presets = try JSONDecoder().decode([String: Preset].self, from: data)
            } catch {
                print("GeissMac: couldn't read presets at \(url.path) — \(error)")
            }
        }
    }

    func preset(_ number: Int) -> Preset? {
        presets[Self.key(number)]
    }

    /// Returns false if the file couldn't be written (the preset still
    /// works for this session).
    @discardableResult
    func save(_ preset: Preset, as number: Int) -> Bool {
        presets[Self.key(number)] = preset
        guard let url else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: url, options: .atomic)
            return true
        } catch {
            print("GeissMac: couldn't save presets to \(url.path) — \(error)")
            return false
        }
    }

    private static func key(_ number: Int) -> String {
        number < 10 ? "0\(number)" : "\(number)"
    }
}

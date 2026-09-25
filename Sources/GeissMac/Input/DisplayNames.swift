/// Display names for the modes, taken from the original's own source
/// comments in GenerateChunkOfNewMap (see ORIGINAL_FEATURE_REFERENCE.md §3),
/// tidied for on-screen use, with a short description where the comment
/// gives one. Modes 1, 2, 10, 11 and 15 have no name in the source; theirs
/// are the port's, describing what the formula does. Mode 26 is the port's own.
enum ModeNames {
    static func label(for mode: Int) -> String {
        guard let entry = entries[mode] else { return "mode \(mode)" }
        return entry.description.map { "\(entry.name) — \($0)" } ?? entry.name
    }

    static func name(for mode: Int) -> String {
        entries[mode]?.name ?? "mode \(mode)"
    }

    private static let entries: [Int: (name: String, description: String?)] = [
        1: ("zoom & spin", nil),                    // source: "***" only
        2: ("fast zoom & spin", nil),               // source: "****" only
        3: ("terra-landing", nil),
        4: ("sphere", nil),
        5: ("SUPER-perspective", nil),
        6: ("VORTEX THINGY", nil),
        7: ("fuzzy", nil),
        8: ("ripples", nil),
        9: ("crazy-ass feedback", nil),
        10: ("stretch", nil),                       // no name in source
        11: ("double twist", nil),                  // no name in source
        12: ("sideways splitter", nil),
        13: ("continuous black hole", "sucks in @ center, pushes out @ edges"),
        14: ("split-world warp", nil),
        15: ("petals", nil),                        // no name in source
        16: ("crystal ball", nil),
        17: ("horizontal tunnel", nil),
        18: ("vertical tunnel", nil),
        19: ("vortex", nil),
        20: ("terra II", nil),                     // source: "terra''" (double-prime)
        21: ("diced cube", "gritty, dirty electronics"),
        22: ("phonic rings", nil),
        23: ("badass phonic rings", "quicker response & fadeout"),
        24: ("fast swirl", nil),
        25: ("1/r zoom", "fully speed-scalable, no curl"),
        26: ("smooth vortex", "mode 6 with half the pull, longer trails"), // port's own mode
    ]
}

/// Display names for the waveform styles. The original never names them in
/// code; only style 6 has one, from its changelog ("added a new waveform
/// (oscilloscope X-Y mode)", main.cpp:96). The rest are the port's plain
/// descriptions of what each draws.
enum WaveformNames {
    static func name(for style: Int) -> String {
        switch style {
        case 0: return "off"
        case 1: return "oscilloscope"
        case 2: return "dual oscilloscope"
        case 3: return "vertical oscilloscope"
        case 4: return "dual diagonal"
        case 5: return "circle"
        case 6: return "X-Y oscilloscope"
        default: return "style \(style)"
        }
    }
}

import AppKit
import Metal

/// What the on-screen text should show this frame (see InputController.hudText).
/// Help rows are "label\tstate"; the states line up in their own column, and
/// a row whose state is "off" is dimmed. `helpLeft` sits under the message at
/// the top-left, `helpRight` against the top-right edge.
struct HUDText: Equatable {
    var message: String?
    var showFPS: Bool
    var helpLeft: [String]?
    var helpRight: [String]?
    /// Song title and/or clock, each at its own spot.
    var popups: [TextPopup] = []
}

/// The original plug-in's song-title popup (video.h
/// Plop_Songtitle_Using_Backbuffer_As_Scratch): text in a bold 24px font at a
/// random, center-biased spot, white `RGB(225,225,225)` over a dark
/// `RGB(20,20,20)` shadow; when its time is up it is stamped into the feedback
/// buffer in a random light color, so the effect carries it away. Used for
/// the song title and, the same way, for the port's clock.
struct TextPopup: Equatable {
    var id: Int
    var text: String
    var stampColor: SIMD4<Float>
    /// Where in the free space (0-1 each axis) the title sits.
    var position: SIMD2<Float>
    var shownAt: TimeInterval
    /// `g_song_tooltip_frames`: 60 at 30fps here — the original's slider
    /// ran 2-100 with 20 as the default, too short to read a full title.
    static let duration: TimeInterval = 2
}

/// The original's on-screen text (video.h's Put_*_To_Backbuffer): GDI
/// `TextOut` in the system font on an opaque black box per line, drawn
/// onto the back buffer after the effect — an overlay, never fed back into
/// the trails. One message line at the top-left; the help block indented
/// 20px below it, lines `y_inc` = 18px apart. Sizes are original (640-wide)
/// pixels × nativePixelScale, like every other constant in the port.
///
/// Deliberate deviations at the user's request: white, regular-weight text
/// with no background box (a soft shadow keeps it legible over bright
/// trails) instead of the original's yellow on black, everything scaled by
/// `sizeScale`, and the help laid out in columns showing each toggle's
/// current state, with the effects on the right side of the screen.
///
/// Rendered with AppKit into a texture covering just the text, re-rendered
/// only when the text or scale changes. One instance per panel (the
/// renderer keeps a left and a right one).
final class HUDOverlay {
    private let device: MTLDevice
    private var cacheKey = ""
    private(set) var texture: MTLTexture?
    /// Relative to the original's proportions — the user asked for smaller
    /// text twice (0.8, then 40% smaller again).
    private let sizeScale: CGFloat = 0.48

    init(device: MTLDevice) {
        self.device = device
    }

    private struct Row {
        var box: CGRect
        var segments: [(text: NSAttributedString, x: CGFloat)]
    }

    /// Returns the panel's texture, or nil when there's no text. `indent` is
    /// the help columns' left offset in original pixels (the original's 20).
    func texture(message: String?, helpColumns: [[String]], indent: CGFloat, nativePixelScale: Float) -> MTLTexture? {
        let scale = CGFloat(nativePixelScale) * sizeScale
        let key = "\(scale)|\(indent)|\(message ?? "")|" + helpColumns.map { $0.joined(separator: "\n") }.joined(separator: "||")
        if key == cacheKey { return texture }
        cacheKey = key

        let font = NSFont.systemFont(ofSize: 13 * scale)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.9)
        shadow.shadowBlurRadius = 3 * scale
        shadow.shadowOffset = .zero
        func text(_ string: String, dim: Bool = false) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [
                .font: font,
                .foregroundColor: dim ? NSColor(white: 0.55, alpha: 1) : NSColor.white,
                .shadow: shadow,
            ])
        }
        let boxHeight = 18 * scale
        let pad = 4 * scale
        var rows: [Row] = []

        if let message {
            let t = text(message)
            rows.append(Row(box: CGRect(x: 0, y: 0, width: t.size().width + 2 * pad, height: boxHeight), segments: [(t, pad)]))
        }

        var columnX = indent * scale
        for column in helpColumns {
            let parts = column.map { line -> (label: String, state: String?) in
                let split = line.split(separator: "\t", maxSplits: 1).map(String.init)
                return (split.first ?? "", split.count > 1 ? split[1] : nil)
            }
            let labels = parts.map { text($0.label, dim: $0.state == "off") }
            let states = parts.map { $0.state.map { text($0, dim: $0 == "off") } }
            let labelWidth = labels.map { $0.size().width }.max() ?? 0
            let stateWidth = states.compactMap { $0?.size().width }.max() ?? 0
            let gap = stateWidth > 0 ? 16 * scale : 0
            let columnWidth = labelWidth + gap + stateWidth + 2 * pad

            for i in parts.indices {
                let y = (20 + 18 * CGFloat(i)) * scale
                var segments = [(labels[i], columnX + pad)]
                if let state = states[i] {
                    segments.append((state, columnX + pad + labelWidth + gap))
                }
                rows.append(Row(box: CGRect(x: columnX, y: y, width: columnWidth, height: boxHeight), segments: segments))
            }
            columnX += columnWidth + 12 * scale
        }

        guard !rows.isEmpty else {
            texture = nil
            return nil
        }
        // Without the original's black boxes the text would touch the screen
        // edge, so everything sits inside a small margin (which also leaves
        // room for the shadow).
        let margin = 6 * scale
        let bounds = rows.reduce(CGRect.zero) { $0.union($1.box) }
        let width = Int(ceil(bounds.maxX + 2 * margin)), height = Int(ceil(bounds.maxY + 2 * margin))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Flip so y grows downward, matching the layout above.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: margin, y: margin)
        for row in rows {
            for segment in row.segments {
                let textHeight = segment.text.size().height
                segment.text.draw(at: CGPoint(x: segment.x, y: row.box.minY + (boxHeight - textHeight) / 2))
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        if texture?.width != width || texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            texture = device.makeTexture(descriptor: descriptor)
        }
        if let data = context.data {
            texture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        }
        return texture
    }
}

/// Popup text rendered once as white-on-transparent text, cached per text
/// and scale. The renderer tints it for the shadow and the overlay, and uses
/// its shape to stamp the text into the feedback buffer.
final class PopupTextTextures {
    private let device: MTLDevice
    private var cache: [String: MTLTexture] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(for text: String, nativePixelScale: Float) -> MTLTexture? {
        let key = "\(nativePixelScale)|\(text)"
        if let cached = cache[key] { return cached }
        if cache.count > 8 { cache.removeAll() } // only a couple are ever live

        // CreateFont(24, 10, ..., 700): a 24px bold cell — about a 20px font.
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 20 * CGFloat(nativePixelScale)),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        let width = Int(ceil(size.width)), height = Int(ceil(size.height))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        string.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        cache[key] = texture
        return texture
    }
}

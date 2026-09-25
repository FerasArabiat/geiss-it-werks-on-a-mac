#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Waveform — 6 draw styles matching the original's (main.cpp's RenderWave,
// styles 1-6; a would-be 7th is unreachable dead code in the original and
// wasn't ported). Dual-channel styles (2, 4) are drawn as two separate calls
// from Swift (once per channel, offset apart) using styles 1/3 underneath,
// rather than needing their own cases here.
//
// Geometry is computed in pixel space (top-left origin, same as the warp
// pass's centerPx), not NDC: NDC stretches with the aspect ratio, which had
// turned the radial ring and the vectorscope into ellipses. Every style is
// centered on the mouse-driven gXC/gYC, as in the original.
//
// Drawn as a triangle strip (2 vertices per sample) extruded to a real
// thickness of 1 *original* pixel (see halfThicknessPx), because Metal's
// hardware lines are always 1 *physical* pixel wide — about 1/5 the
// original's line weight on a Retina display.
// ============================================================================

struct WaveformUniforms {
    float4 color;
    float2 centerPx;               // gXC/gYC
    float2 resolution;
    float amplitudePx;             // sample value (-1...1) → pixels
    float perpendicularOffsetPx;   // shifts Y for style 1, X for style 3 (dual-channel styles)
    float halfThicknessPx;
    float baseRadiusPx;            // style 5 ring radius
    uint sampleCount;
    uint style;                    // 1 horizontal, 3 vertical, 5 radial, 6 vectorscope
    float rotation;                // slow spin, style 6 only
    float _padding;
};

struct VertexOut {
    float4 position [[position]];
};

static float2 wave_point(uint i,
                         constant float *samplesL,
                         constant float *samplesR,
                         constant WaveformUniforms &u) {
    float denom = float(max(u.sampleCount, 2u) - 1u);
    float t = float(i) / denom;
    float sL = samplesL[i];

    if (u.style == 3) {
        // Vertical oscilloscope — amplitude drives X, sample index drives Y.
        return float2(u.centerPx.x + sL * u.amplitudePx + u.perpendicularOffsetPx, t * u.resolution.y);
    } else if (u.style == 4) {
        // One of style 4's two 45° diagonals: x = row + sample, running
        // down-right from the top edge (main.cpp:9270-9271). Not centered
        // on gXC — the original's isn't either.
        float row = t * u.resolution.y;
        return float2(row + sL * u.amplitudePx + u.perpendicularOffsetPx, row);
    } else if (u.style == 5) {
        // Radial ring around gXC/gYC: `rad = base_rad + sample*fDiv`
        // (main.cpp:9316).
        float angle = t * 6.28318530718;
        float radius = max(0.0, u.baseRadiusPx + sL * u.amplitudePx);
        return u.centerPx + float2(cos(angle), sin(angle)) * radius;
    } else if (u.style == 6) {
        // Vectorscope/Lissajous — L vs R, same pixel scale on both axes, slowly rotated.
        float2 p = float2(sL, samplesR[i]) * u.amplitudePx;
        float c = cos(u.rotation);
        float s = sin(u.rotation);
        return u.centerPx + float2(p.x * c - p.y * s, p.x * s + p.y * c);
    }
    // Style 1 (and the default/fallback) — horizontal oscilloscope.
    return float2(t * u.resolution.x, u.centerPx.y + sL * u.amplitudePx + u.perpendicularOffsetPx);
}

vertex VertexOut waveform_vertex(uint vertexID [[vertex_id]],
                                  constant float *samplesL [[buffer(0)]],
                                  constant WaveformUniforms &uniforms [[buffer(1)]],
                                  constant float *samplesR [[buffer(2)]]) {
    uint i = vertexID / 2;
    float side = (vertexID & 1) ? 1.0 : -1.0;
    uint last = max(uniforms.sampleCount, 2u) - 1u;

    float2 p = wave_point(i, samplesL, samplesR, uniforms);
    float2 tangent = wave_point(min(i + 1, last), samplesL, samplesR, uniforms)
                   - wave_point(i == 0 ? 0 : i - 1, samplesL, samplesR, uniforms);
    float len = length(tangent);
    float2 normal = len > 1e-4 ? float2(-tangent.y, tangent.x) / len : float2(0.0, 1.0);
    float2 px = p + normal * side * uniforms.halfThicknessPx;

    VertexOut out;
    out.position = float4(px.x / uniforms.resolution.x * 2.0 - 1.0,
                          1.0 - px.y / uniforms.resolution.y * 2.0,
                          0.0, 1.0);
    return out;
}

fragment float4 waveform_fragment(VertexOut in [[stage_in]],
                                   constant WaveformUniforms &uniforms [[buffer(1)]]) {
    return uniforms.color;
}

// ============================================================================
// Overlay effects — point sprites for every effect in OverlayEffects.swift
// (SOLAR, SHADE, CHASERS, BAR, DOTS, NUCLIDE, GRID). The original draws each
// as small pixel stamps written straight into its 8-bit buffer; the Swift
// side picks a blend pipeline per effect to match that pixel math (add,
// screen, replace, max), and `shape` picks the stamp footprint here. Safe
// to accumulate because the render target clamps to [0,1] — no
// unbounded-accumulation risk like an earlier float-texture version had.
// ============================================================================

struct ParticleVertexOut {
    float4 position [[position]];
    float4 color;
    float shape [[flat]];
    float pointSize [[point_size]];
};

vertex ParticleVertexOut particle_vertex(uint vertexID [[vertex_id]],
                                          constant float4 *positionsAndSize [[buffer(0)]], // xy = pixel position, z = point size (px), w = shape
                                          constant float4 *colors [[buffer(1)]],
                                          constant float2 &resolution [[buffer(2)]]) {
    float4 p = positionsAndSize[vertexID];
    float2 ndc;
    ndc.x = (p.x / resolution.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (p.y / resolution.y) * 2.0; // pixel Y is top-down; NDC Y is bottom-up

    ParticleVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = colors[vertexID];
    out.shape = p.w;
    out.pointSize = p.z;
    return out;
}

fragment float4 particle_fragment(ParticleVertexOut in [[stage_in]],
                                   float2 pointCoord [[point_coord]]) {
    // Square (shape 2): the original's single-pixel stamps, drawn as-is —
    // also required for replace/max pipelines, where a zero-falloff corner
    // would still overwrite.
    if (in.shape > 1.5) {
        return float4(in.color.rgb, 1.0);
    }
    float dist = length(pointCoord - float2(0.5, 0.5)) * 2.0; // 0 at center, 1 at edge
    // Cone (shape 1): NUCLIDE's `(r - dist)*25`, linear to zero at the rim.
    // Glow (shape 0): flat-topped with a soft rim — closer to the original's
    // nearly uniform 3x3/"+" stamps than a center-peaked glow, but round.
    float falloff = in.shape > 0.5 ? max(0.0, 1.0 - dist) : 1.0 - smoothstep(0.6, 1.0, dist);
    // Falloff is baked into the color, not alpha: additive blend factors
    // ignore alpha entirely (that bug once rendered every particle as a
    // hard square).
    return float4(in.color.rgb * falloff, 1.0);
}

// ============================================================================
// Feedback zoomer — the actual "Geiss look".
//
// Ported concept (not code) from the original's GenerateChunkOfNewMap() in
// main.cpp: every output pixel looks up a source location computed by
// rotating+scaling around a center point (gXC/gYC in the original), with the
// scale itself varying per-mode as a function of distance from that center
// (sphere/vortex/black-hole/tunnel formulas). The original precomputed this
// as a per-pixel byte-packed offset+bilinear-weight table (DATA_FX) once per
// "mode", then replayed it every frame via hand-written MMX/Cyrix asm in
// proc_map.cpp, because 1998 CPUs couldn't afford to redo the math live.
//
// On a GPU there's no reason to precompute or store that table at all: we
// evaluate the same per-mode transform analytically in the fragment shader
// every frame, and Metal's texture sampler does the bilinear interpolation
// for free. Applying the same fixed transform to the previous frame's output,
// over and over, is what produces the spinning/zooming trail look — the
// motion comes from repeated composition, not from changing the transform
// per frame.
//
// All 25 of the original's modes above 0 are now ported: 1-25 (see
// MetalRenderer.swift's modeParameters and scale_for_mode below). Modes 6,
// 10, 11, and 12 are structurally different from the rest (direct
// source-position formulas rather than a single rotate+scale from one
// center) — see vortex_source, mode10_source, mode11_source, mode12_source
// below and their branches in warp_fragment. Mode 7's per-pixel "fuzz" is a
// substitute, not an exact port — the original drives it from a precomputed
// pseudo-random array whose generation isn't reproducible without its RNG
// state; see scale_for_mode's case 7 for what was used instead.
// ============================================================================

struct WarpUniforms {
    float2 centerPx;         // gXC/gYC — the zoom/rotation center, in pixels
    float2 resolution;       // drawable size in pixels (== FXW/FXH)
    float rotationCos;
    float rotationSin;
    float damping;           // 1.0 = full transform; <1.0 softens toward identity
    float weightsum;         // the original's weightsum_res_adjusted (253, mode 12: 247); 0 = plain resample, no decay this frame
    float protectiveFactor;  // dampens scale-formula intensity at resolutions >640px wide
    float f1;
    float f2;
    float f3;
    uint mode;
    float centerDwindle;     // the mode's center_dwindle (1 = off)
    float nativePixelScale;  // physical pixels per original (640-wide) pixel
    float2 slideOffsetPx;    // slide shift drift (`slider1`), 0 when off
};

// One of mode 6's 5 point-source attractors (main.cpp's cx/cy/ci/cj/ctype
// arrays). `type` 0 = fixed-direction push, 1 = counterclockwise swirl,
// 2 = clockwise swirl.
struct VortexPoint {
    float2 position;   // pixel space
    float2 direction;  // only used by type 0
    int type;
    int _padding;
};

vertex VertexOut fullscreen_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

// Mode 6 ("VORTEX THINGY") — unlike every other mode ported so far, this
// isn't a rotate+scale from one center. It's a velocity field summed from 5
// independent point sources (the original generates 10 per mode-switch but
// only ever reads the first 5 in its per-pixel loop — a quirk of the
// original preserved here rather than "fixed", since faithfully reproducing
// the original's actual behavior is the goal). Ported directly from
// main.cpp's custom_motion_vectors[6] branch.
//
// Unlike every scale-based mode, this one's math has NO resolution
// normalization in the original at all — distances are raw pixels, with no
// `rmult`/`inv_FXW` anywhere in that branch. Confirmed by direct user
// testing: on a modern display this reproduces faithfully but reads as "too
// small, like it was designed for lower-resolution screens" — because it
// was. `rmult` here is an intentional *deviation* from a literal port, added
// specifically to counteract that: it rescales both the per-point influence
// radius and the final displacement magnitude so the effect occupies the
// same proportion of the screen (and moves at the same relative speed)
// regardless of resolution, the same way every other mode already does via
// its own scale-formula's `rmult`/`protectiveFactor`.
static float2 vortex_source(float2 fragPx, float2 resolution, constant VortexPoint *points, float gain) {
    float rmult = 640.0 / resolution.x;
    float2 t = float2(0.0, 0.0);
    float f = 0.0;

    for (int n = 0; n < 5; n++) {
        float2 d2 = (points[n].position - fragPx) * rmult;  // "newx = cx[n]-x; newy = cy[n]-y", rescaled
        float xxyy = dot(d2, d2);
        float d = 1.0 / (xxyy + 0.1);
        f += d;

        if (points[n].type == 0) {
            t += points[n].direction * d;
        } else {
            float z = 1.0 / (sqrt(xxyy) + 0.01);
            float d2w = d * 2.0;
            if (points[n].type == 1) {
                t += float2(-d2.y, d2.x) * d2w * z;
            } else {
                t += float2(d2.y, -d2.x) * d2w * z;
            }
        }
    }

    // `gain`: 1 for mode 6 (the original's `1.9/f`), 0.5 for the port's mode
    // 26 "smooth vortex" — the tuning the user chose while mode 6 had fixed
    // vortex points: the same pull spread over smaller per-frame steps reads
    // as a smooth pull rather than distinct wound spiral arms.
    float2 pushPx = (f > 0.000001) ? t * (1.9 / f) * gain : float2(0.0, 0.0);
    // Undo the distance rescaling on the way out, so the displacement is
    // proportionally as strong here as the original was at 640-wide.
    return fragPx + (pushPx + float2(-0.1, 0.6)) / rmult;
}

// Mode-specific scale factor, evaluated at a pixel offset (newx2, newy2) from
// the zoom center. `rmult` matches the original's `640.0/FXW` — several of
// Geiss's scale formulas were tuned at 640-wide resolution, so this rescales
// distances measured at the real (much larger, on modern displays) resolution
// back into the same range those formulas expect.
static float scale_for_mode(uint mode, float2 offsetPx, float2 resolution, float f1, float f2, float f3, float protectiveFactor) {
    float rmult = 640.0 / resolution.x;
    float r = length(offsetPx) * rmult;

    switch (mode) {
        case 5: {
            // "SUPER-perspective" — Geiss's own 5-star flagship mode. f3 = 1
            // selects the linear falloff the original used when NUCLIDE was
            // on (main.cpp:4713-4716); sqrt otherwise.
            float rr = r * (1.0 / 200.0);
            rr = f3 > 0.5 ? rr * 1.7 : sqrt(rr);
            float scale1 = f2 - f1 * rr;
            return (scale1 - 1.0) * protectiveFactor + 1.0;
        }
        case 13: {
            // Black hole: sucks in at center, pushes out at edges.
            float scale1 = 1.04 - r * sqrt(r) * 0.00025 * 0.14;
            return (scale1 - 1.0) * f1 + 1.0;
        }
        case 1:
            // Simplest mode ("***" in the original's rating) — fixed
            // zoom+rotate, no radial variation at all (f1 carries the fixed
            // scale here, chosen since this mode has no per-pixel formula).
            return f1;
        case 2:
            // "****" — also a fixed zoom+rotate, slightly faster/looser
            // than mode 1.
            return f1;
        case 3: {
            // "Terra-landing" — vertical gradient zoom.
            float n_y = offsetPx.y * (480.0 / resolution.y);
            return 0.95 - n_y * 0.0005;
        }
        case 4:
            // Sphere.
            return 0.9 + r * 0.0025 * 0.14;
        case 7: {
            // "Fuzzy" — radial zoom plus per-pixel grain. The original's
            // grain comes from a *fixed* 2345-entry table
            // (`rand()%100*0.0005`, main.cpp:3980) cycled in scan order —
            // not reproducible exactly without that RNG state. Substituted
            // with a deterministic hash of screen position: same idea (a
            // fixed, always-non-negative, per-pixel grain in the same
            // [0, 0.0495] range), different exact values.
            float scale1 = f1 - r * f2;
            scale1 = (scale1 - 1.0) * protectiveFactor + 1.0;
            float grain = fract(sin(dot(offsetPx, float2(12.9898, 78.233))) * 43758.5453) * 0.0495;
            return scale1 + grain;
        }
        case 8:
            // Ripples — f1 modulates ripple frequency.
            return 0.85 + 0.1 * sin(sqrt(r) * f1);
        case 9: {
            // "Crazy-ass feedback" (petals emerge from rotation+scale
            // interaction, not explicit angle math — the original's own
            // petal-angle modulation is present but commented out in its
            // shipped source).
            float scale1 = f1 - r * f2;
            return (scale1 - 1.0) * protectiveFactor + 1.0;
        }
        case 14:
            // Organic up-down warp — uses raw pixel offset, not normalized.
            return 0.9 + 0.2 * cos(offsetPx.y * 12.0 / resolution.y);
        case 16: {
            // Crystal ball.
            float scale1 = 1.05 - r * r * 0.00025 * 0.09;
            return max(scale1, -1.5);
        }
        case 15: {
            // Real angle-based petal modulation (unlike mode 9's — this one
            // actually uses atan2 in the original's shipped source). f1 =
            // petal count, f2 = scale lower bound, f3 = scale range.
            float angle = atan2(offsetPx.y, offsetPx.x);
            return f2 + f3 * sin(angle * f1);
        }
        case 19: {
            // Vortex — uses normalized (~-1..1) coordinates directly.
            float2 n = offsetPx * (2.0 / resolution.x);
            return 1.04 - 0.25 * length(n);
        }
        case 25: {
            // 1/r zoom — smooth, fully speed-scalable, no curl.
            float2 n = offsetPx * (2.0 / resolution.x);
            return 3.0 / (3.0 + length(n));
        }
        case 17: {
            // Horizontal tunnel.
            float2 n = offsetPx * (2.0 / resolution.x);
            return 0.97 - n.y * n.y * 0.40;
        }
        case 18: {
            // Vertical tunnel.
            float2 n = offsetPx * (2.0 / resolution.x);
            return 0.97 - n.x * n.x * 0.40;
        }
        case 20: {
            // "terra''" — asymmetric vertical push.
            float2 n = offsetPx * (2.0 / resolution.x);
            return 1.15 - sqrt(max(0.0, n.y + 1.4)) * 0.20;
        }
        case 21: {
            // Diced cube — gritty, quantized zoom.
            float2 n = offsetPx * (2.0 / resolution.x);
            return 0.95 - floor(abs(n.x) * 10.0) * 0.03 - floor(abs(n.y) * 10.0) * 0.03;
        }
        case 22: {
            // Phonic rings — concentric quantized bands.
            float2 n = offsetPx * (2.0 / resolution.x);
            return 0.95 - floor(length(n) * 10.0) * 0.04;
        }
        case 23: {
            // Badass phonic rings — quicker response & fadeout than 22.
            float2 n = offsetPx * (2.0 / resolution.x);
            float band = fmod(floor(length(n) * 20.0), 4.0);
            return 0.95 - band * 0.12;
        }
        case 24:
            // Fast swirl — the spin (turn1, in modeParameters) does the work here.
            return 0.96;
        default:
            return 1.0;
    }
}

// Mode 10 — another custom-motion-vector mode: horizontal stretch that
// strengthens toward the bottom of the screen, plus a flat 4% vertical
// zoom-out (applied to the absolute row, not an offset from center — the
// original's own formula, not a mistake). Already resolution-independent as
// written (the position-dependent factor is expressed as `y/FXH`, a
// proportion, and the offset it multiplies scales naturally with position),
// so no rmult correction needed here — unlike modes 6 and 12.
static float2 mode10_source(float2 fragPx, float2 offsetPx, float2 centerPx, float2 resolution) {
    float horizontalScale = 1.03 + 0.03 * (fragPx.y / resolution.y);
    float newX = offsetPx.x * horizontalScale + centerPx.x;
    float newY = fragPx.y * 1.04;
    return float2(newX, newY);
}

// Mode 12 ("sideways splitter") — pushes content toward the sides via an
// inverse-square-ish (sqrt) curve; vertical position passes through
// unchanged. The original feeds a *raw, unscaled* pixel offset into sqrt()
// here — the same class of resolution-dependence bug found in mode 6 (see
// vortex_source's doc comment), since sqrt of
// a raw pixel distance does not grow proportionally with resolution. Fixed
// the same way: rescale by `rmult` going in, undo it coming out.
static float2 mode12_source(float2 offsetPx, float2 centerPx, float2 resolution) {
    float rmult = 640.0 / resolution.x;
    float scaledX = offsetPx.x * rmult;
    float resultScaled;
    if (scaledX < -0.5) {
        resultScaled = -sqrt(-scaledX) + 0.9;
    } else if (scaledX > 0.5) {
        resultScaled = sqrt(scaledX) - 0.9;
    } else {
        resultScaled = 0.0;
    }
    float newX = centerPx.x + resultScaled / rmult;
    float newY = centerPx.y + offsetPx.y; // newy2 + gYC == identity
    return float2(newX, newY);
}

// Mode 11 — checkerboard-dithered double transform: alternates between two
// different rotate+scale pairs on a per-pixel checkerboard, rather than
// applying one uniform transform everywhere. The original's
// rotation_dither[] table flags modes 1, 9, and 11. Mode 1's two transforms
// are identical (a no-op); mode 9's differ only in scale and are handled in
// warp_fragment; mode 11's differ in both, handled here.
static float2 mode11_source(float2 fragPx, float2 offsetPx, float2 centerPx,
                             float rotationCos1, float rotationSin1,
                             float scale1, float scale2, float turn2) {
    int ix = int(fragPx.x);
    int iy = int(fragPx.y);
    bool useFirst = (ix % 2) == (iy % 2);

    float cosT = useFirst ? rotationCos1 : cos(turn2);
    float sinT = useFirst ? rotationSin1 : sin(turn2);
    float scale = useFirst ? scale1 : scale2;

    float2 rotated;
    rotated.x = offsetPx.x * cosT - offsetPx.y * sinT;
    rotated.y = offsetPx.x * sinT + offsetPx.y * cosT;
    return rotated * scale + centerPx;
}

// The original's per-pixel blend (proc_map.cpp's MMX loop over DATA_FX,
// weights built at main.cpp:5193-5207), done exactly: four neighbors with
// bilinear weights each truncated to a whole byte out of `weightsum`
// (253/256 at 640x480, so ~1.2% dimmer per frame plus the truncation), then
// the sum shifted down by 8 — rounding *down*, so a dim pixel always loses at
// least one level per frame. That slow, flooring fade is what lets SOLAR
// sparks and every trail linger and grow under the zoom; a multiply stored
// back into 8 bits rounds to nearest instead and leaves dim pixels stuck.
static float4 original_blend(texture2d<float, access::sample> tex, float2 sourcePx, float weightsum) {
    int width = int(tex.get_width());
    int height = int(tex.get_height());
    float2 p = sourcePx - 0.5; // texel centers sit at +0.5
    float2 base = floor(p);
    float2 f = p - base;
    int x0 = int(base.x);
    int y0 = int(base.y);
    // Wrap x, clamp y — the same as the sampler and the original.
    uint xa = uint(((x0 % width) + width) % width);
    uint xb = (xa + 1) % uint(width);
    uint ya = uint(clamp(y0, 0, height - 1));
    uint yb = uint(clamp(y0 + 1, 0, height - 1));

    float w00 = floor((1.0 - f.x) * (1.0 - f.y) * weightsum);
    float w10 = floor(f.x * (1.0 - f.y) * weightsum);
    float w01 = floor((1.0 - f.x) * f.y * weightsum);
    float w11 = floor(f.x * f.y * weightsum);

    float4 sum = w00 * round(tex.read(uint2(xa, ya)) * 255.0)
               + w10 * round(tex.read(uint2(xb, ya)) * 255.0)
               + w01 * round(tex.read(uint2(xa, yb)) * 255.0)
               + w11 * round(tex.read(uint2(xb, yb)) * 255.0);
    return floor(sum / 256.0) / 255.0;
}

fragment float4 warp_fragment(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> previous [[texture(0)]],
                               sampler previousSampler [[sampler(0)]],
                               constant WarpUniforms &uniforms [[buffer(0)]],
                               constant VortexPoint *vortexPoints [[buffer(1)]]) {
    float2 fragPx = in.position.xy;
    float2 offsetPx = fragPx - uniforms.centerPx;

    float2 sourcePx;
    if (uniforms.mode == 6 || uniforms.mode == 26) {
        sourcePx = vortex_source(fragPx, uniforms.resolution, vortexPoints, uniforms.f1);
    } else if (uniforms.mode == 10) {
        sourcePx = mode10_source(fragPx, offsetPx, uniforms.centerPx, uniforms.resolution);
    } else if (uniforms.mode == 12) {
        sourcePx = mode12_source(offsetPx, uniforms.centerPx, uniforms.resolution);
    } else if (uniforms.mode == 11) {
        sourcePx = mode11_source(fragPx, offsetPx, uniforms.centerPx, uniforms.rotationCos, uniforms.rotationSin, uniforms.f1, uniforms.f2, uniforms.f3);
    } else {
        float scale = scale_for_mode(uniforms.mode, offsetPx, uniforms.resolution, uniforms.f1, uniforms.f2, uniforms.f3, uniforms.protectiveFactor);
        // Mode 9's rotation_dither: on the checkerboard's other half the
        // original keeps its init-time constant zoom (scale2, in f3) instead
        // of the radial formula — same rotation (main.cpp:5061-5077).
        if (uniforms.mode == 9 && (int(fragPx.x) % 2) != (int(fragPx.y) % 2)) {
            scale = (uniforms.f3 - 1.0) * uniforms.protectiveFactor + 1.0;
        }

        float2 rotated;
        rotated.x = offsetPx.x * uniforms.rotationCos - offsetPx.y * uniforms.rotationSin;
        rotated.y = offsetPx.x * uniforms.rotationSin + offsetPx.y * uniforms.rotationCos;

        sourcePx = rotated * scale + uniforms.centerPx;
    }

    // Damp toward the identity sample (this pixel) — softens the transform,
    // mirroring the original's `new_damping` blend (applied uniformly to
    // every mode's newx/newy in the original's shared tail code, mode 6
    // included).
    sourcePx = fragPx * (1.0 - uniforms.damping) + sourcePx * uniforms.damping;
    sourcePx += uniforms.slideOffsetPx;

    float4 result = uniforms.weightsum > 0.0
        ? original_blend(previous, sourcePx, uniforms.weightsum)
        : previous.sample(previousSampler, sourcePx / uniforms.resolution);

    // Diminish_Center (Effects.h:257): extra dimming on a 5-pixel "+" at
    // gXC/gYC — a 3-pixel-wide vertical line in mode 12 — so a bright spot
    // can't build up at the transform's fixed point.
    if (uniforms.centerDwindle < 0.999) {
        float2 d = abs(fragPx - uniforms.centerPx) / uniforms.nativePixelScale;
        bool inside = uniforms.mode == 12
            ? d.x < 1.5
            : ((d.x < 0.5 && d.y < 1.5) || (d.x < 1.5 && d.y < 0.5));
        if (inside) {
            result *= uniforms.centerDwindle;
        }
    }
    return result;
}

// ============================================================================
// Present — draws the feedback texture to the actual drawable.
// ============================================================================

fragment float4 present_fragment(VertexOut in [[stage_in]],
                                  texture2d<float, access::sample> feedback [[texture(0)]],
                                  texture2d<float, access::read> palette [[texture(1)]],
                                  sampler feedbackSampler [[sampler(0)]],
                                  constant uint &eightBit [[buffer(0)]]) {
    float2 uv = in.position.xy / float2(feedback.get_width(), feedback.get_height());
    float4 color = feedback.sample(feedbackSampler, uv);

    // The 8-bit look: the original's 8-bit buffer held one brightness per
    // pixel, shown through a 256-color palette (EightBitPalette). Everything
    // draws in gray then, so any channel is that brightness; the brightest
    // one also covers the few effects that keep their own colors.
    if (eightBit != 0) {
        uint index = min(uint(round(max(max(color.r, color.g), color.b) * 255.0)), 255u);
        return float4(palette.read(uint2(index, 0)).rgb, 1.0);
    }

    // "Gamma correction" in the original is much simpler than a real gamma
    // curve or a palette LUT — it's literally REMAP[z] = min(255, z*2)
    // (main.cpp:3943), i.e. double the brightness and clamp, applied once at
    // display time on top of the already hard-clamped accumulation buffer.
    // (The CrankPal palette curves are the 8-bit mode's separate path —
    // FX_Random_Palette bails out `if (iDispBits != 8) return;` — handled
    // above as the optional 8-bit look.)
    color.rgb = min(color.rgb * 2.0, 1.0);
    return float4(color.rgb, 1.0);
}

// ============================================================================
// HUD text — HUDOverlay's texture drawn 1:1 at the top-left of the drawable,
// after the present pass (premultiplied-alpha blend), like the original's
// GDI text on its back buffer.
// ============================================================================

struct HUDVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex HUDVertexOut hud_vertex(uint vertexID [[vertex_id]],
                               constant float4 &rect [[buffer(0)]],        // x, y, width, height in pixels, top-left origin
                               constant float2 &resolution [[buffer(1)]]) {
    float2 corner = float2(vertexID & 1, vertexID >> 1);
    float2 px = rect.xy + corner * rect.zw;
    HUDVertexOut out;
    out.position = float4(px.x / resolution.x * 2.0 - 1.0, 1.0 - px.y / resolution.y * 2.0, 0.0, 1.0);
    out.uv = corner;
    return out;
}

fragment float4 hud_fragment(HUDVertexOut in [[stage_in]],
                             texture2d<float, access::sample> text [[texture(0)]],
                             sampler textSampler [[sampler(0)]],
                             constant float4 &tint [[buffer(0)]]) {
    return text.sample(textSampler, in.uv) * tint;
}

// The song title's last frame: written straight into the feedback texture in
// its stamp color wherever the text is (`if (dest2[x] > 1) VS1 = color`,
// video.h:279-284), after which the effect warps it away.
fragment float4 title_stamp_fragment(HUDVertexOut in [[stage_in]],
                                     texture2d<float, access::sample> text [[texture(0)]],
                                     sampler textSampler [[sampler(0)]],
                                     constant float4 &color [[buffer(0)]]) {
    if (text.sample(textSampler, in.uv).a < 0.3) {
        discard_fragment();
    }
    return color;
}

// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GeissMac",
    platforms: [
        .macOS(.v14) // Sonoma+: required for ScreenCaptureKit audio-tap API. Apple Silicon only — no x86_64 target.
    ],
    products: [
        .executable(name: "GeissMac", targets: ["GeissMac"]),
        // Loaded into /usr/bin/perl at runtime (not linked into the app) to
        // read macOS's Now Playing info — see Sources/NowPlayingHelper.
        .library(name: "NowPlayingHelper", type: .dynamic, targets: ["NowPlayingHelper"]),
    ],
    targets: [
        .target(
            name: "NowPlayingHelper",
            path: "Sources/NowPlayingHelper",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "GeissMac",
            path: "Sources/GeissMac",
            resources: [
                .copy("../../Resources/Palettes"),
                // Kept as a plain-text resource and compiled at runtime via
                // MTLDevice.makeLibrary(source:) — see MetalRenderer.buildPipeline().
                // Plain `swift build` (unlike an Xcode build) does not run the
                // Metal compiler over .process resources, so there's no
                // default.metallib to load with makeDefaultLibrary(bundle:).
                .copy("Renderer/Shaders.metal")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]) // using @main, not a top-level main.swift script
            ]
        )
    ]
)

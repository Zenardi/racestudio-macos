// swift-tools-version: 5.9
import PackageDescription
import Foundation

// swift-testing ships inside the active developer directory. When only Apple's
// Command Line Tools are installed (no Xcode.app), SwiftPM does not
// automatically add its framework/library search paths, so wire them in
// explicitly — but only when that CLT layout is actually present. In a full
// Xcode environment these paths are absent here and native resolution is used,
// keeping the manifest portable across both setups and CI.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltUsrLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let needsTestingPaths = FileManager.default.fileExists(
    atPath: cltFrameworks + "/Testing.framework"
)

var testSwiftSettings: [SwiftSetting] = []
var testLinkerSettings: [LinkerSetting] = []
if needsTestingPaths {
    testSwiftSettings.append(.unsafeFlags(["-F", cltFrameworks]))
    testLinkerSettings.append(.unsafeFlags([
        "-F", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltUsrLib
    ]))
}

// The RaceStudioFFI.xcframework is a build artifact produced by
// scripts/build_xcframework.sh (git-ignored — the static library is ~34 MB).
// Wire the UniFFI targets in only when it is present, so a fresh checkout still
// builds (with the FFI surface gated behind `#if canImport(RaceStudioFFIBindings)`)
// and the coverage gate — which builds the xcframework first — always exercises it.
let ffiXcframework = "RaceStudioFFI.xcframework"
let ffiEnabled = FileManager.default.fileExists(atPath: ffiXcframework)

var coreDependencies: [Target.Dependency] = []
var ffiTargets: [Target] = []
var testExcludes: [String] = []
if ffiEnabled {
    coreDependencies.append("RaceStudioFFIBindings")
    ffiTargets = [
        .binaryTarget(name: "RaceStudioFFI", path: ffiXcframework),
        // The uniffi-generated high-level Swift bindings. Kept out of the
        // RaceStudioCore coverage scope (Sources/RaceStudioCore) on purpose —
        // generated glue is not hand-written logic.
        .target(
            name: "RaceStudioFFIBindings",
            dependencies: ["RaceStudioFFI"],
            path: "Generated",
            exclude: [
                "racestudio_ffiFFI.h",
                "racestudio_ffiFFI.modulemap",
                "module.modulemap"
            ]
        )
    ]
} else {
    testExcludes.append("FFIRoundTripTests.swift")
}

let package = Package(
    name: "RaceStudio",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RaceStudioCore", targets: ["RaceStudioCore"]),
        .executable(name: "RaceStudio", targets: ["RaceStudio"])
    ],
    targets: [
        // The 95%-coverage logic library. All testable behaviour lives here.
        .target(
            name: "RaceStudioCore",
            dependencies: coreDependencies
        ),
        // Thin @main SwiftUI shell. Holds no logic and is excluded from the
        // coverage metric by target (wired in issue 0.3).
        .executableTarget(
            name: "RaceStudio",
            dependencies: ["RaceStudioCore"]
        ),
        .testTarget(
            name: "RaceStudioCoreTests",
            dependencies: ["RaceStudioCore"],
            exclude: testExcludes,
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ] + ffiTargets
)

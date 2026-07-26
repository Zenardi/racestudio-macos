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

// The @main shell ships an Info.plist (imported .xrk/.xrz UTI declarations) and
// a sandbox entitlements file. SwiftPM forbids a resource literally named
// Info.plist, so both are excluded from resource processing; the plist is
// instead embedded into the executable's Mach-O `__TEXT,__info_plist` section so
// a plain `swift run RaceStudio` still carries its document-type declarations.
// An absolute path keeps the linker flag correct regardless of the invoking
// working directory (`#filePath` resolves to this manifest's directory = app/).
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlistPath = packageDir + "/Sources/RaceStudio/Info.plist"

var coreDependencies: [Target.Dependency] = []
// The @main shell depends on RaceStudioCore always, and on the generated FFI
// bindings when present so its device panel (issue 6.7) can name the FFI record
// types (`Device`/`SessionInfo`) behind `#if canImport(RaceStudioFFIBindings)`.
var shellDependencies: [Target.Dependency] = ["RaceStudioCore"]
var ffiTargets: [Target] = []
var testExcludes: [String] = []
if ffiEnabled {
    coreDependencies.append("RaceStudioFFIBindings")
    shellDependencies.append("RaceStudioFFIBindings")
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
    // The FFI test files import the generated bindings; exclude them when the
    // xcframework is absent so a fresh checkout still builds.
    testExcludes.append("FFIRoundTripTests.swift")
    testExcludes.append("DecodeFFITests.swift")
    testExcludes.append("AnalysisFFITests.swift")
    testExcludes.append("ProjectFFIValidatorTests.swift")
    testExcludes.append("BonjourBrowserTests.swift")
    testExcludes.append("SessionEnumerationTests.swift")
    testExcludes.append("SessionDownloadTests.swift")
    testExcludes.append("SessionDeleteTests.swift")
    testExcludes.append("DevicePanelModelTests.swift")
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
            dependencies: coreDependencies,
            resources: [
                // The String Catalog (issue 7.3) is copied verbatim into
                // Bundle.module so LocalizationCatalog parses the raw .xcstrings
                // JSON at runtime — no dependency on Xcode's xcstringstool, so the
                // localization gate runs on a Command-Line-Tools-only CI runner.
                .copy("Localization/Localizable.xcstrings")
            ]
        ),
        // Thin @main SwiftUI shell. Holds no logic and is excluded from the
        // coverage metric by target (wired in issue 0.3).
        .executableTarget(
            name: "RaceStudio",
            dependencies: shellDependencies,
            exclude: [
                "Info.plist",
                "RaceStudio.entitlements"
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath
                ])
            ]
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

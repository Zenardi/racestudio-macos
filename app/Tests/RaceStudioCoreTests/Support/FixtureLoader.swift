import Foundation

/// Resolves the repo-root `fixtures/` directory and loads golden JSON — the
/// Swift twin of the Rust `support::fixtures` helpers (issue 0.5). `.xrk`
/// samples are fetched by `scripts/fetch_fixtures.sh`; the small goldens under
/// `fixtures/golden/` are committed and act as the decode oracle for M1+.
enum FixtureLoader {

    /// The repo-root `fixtures/` directory, resolved relative to this source
    /// file so it does not depend on the working directory.
    static func fixturesDir() -> URL {
        // .../app/Tests/RaceStudioCoreTests/Support/FixtureLoader.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // RaceStudioCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("fixtures")
    }

    /// Absolute URL of a fixture file, e.g. `url(for: "aim_official_test.xrk")`.
    static func url(for name: String) -> URL {
        fixturesDir().appendingPathComponent(name)
    }

    /// Load and decode a golden JSON, e.g.
    /// `golden("aim_official_test", aspect: "channels")` reads
    /// `fixtures/golden/aim_official_test.channels.json`.
    ///
    /// Throws a clear, actionable error (naming the file and how to regenerate
    /// it) when the golden is missing — never a silent empty result.
    static func golden<T: Decodable>(_ name: String, aspect: String) throws -> T {
        let fileName = "\(name).\(aspect).json"
        let fileURL = fixturesDir()
            .appendingPathComponent("golden")
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FixtureError.missing(fileName: fileName, path: fileURL.path)
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missing(fileName: String, path: String)
        var description: String {
            switch self {
            case let .missing(fileName, path):
                return "golden fixture not found: \(fileName) (looked in \(path)). "
                    + "Run `make fixtures` to generate it."
            }
        }
    }
}

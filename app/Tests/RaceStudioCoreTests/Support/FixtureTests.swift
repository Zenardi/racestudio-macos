import Testing
import Foundation

/// Golden schema (subset) matching scripts/gen_goldens.py channels output.
private struct ChannelsGolden: Decodable {
    let file: String
    let channelCount: Int
    let channels: [Channel]
    struct Channel: Decodable {
        let name: String
        let samples: Int
    }
}

/// Tests for the Swift golden-fixture loader (issue 0.5), mirroring the Rust
/// `support::fixtures` helpers so `RaceStudioCoreTests` can consume the same
/// committed goldens.
@Suite struct FixtureTests {

    /// `url(for:)` resolves the repo `fixtures/` dir (path only — `.xrk` samples
    /// are git-ignored, so existence is not required).
    @Test func testFixtureLoaderResolvesXrkURL() {
        let url = FixtureLoader.url(for: "aim_official_test.xrk")
        #expect(url.lastPathComponent == "aim_official_test.xrk")
        #expect(url.path.hasSuffix("fixtures/aim_official_test.xrk"))
    }

    /// `golden(_:aspect:)` decodes a committed golden JSON into a typed value.
    @Test func testFixtureLoaderDecodesGoldenJSON() throws {
        let golden: ChannelsGolden =
            try FixtureLoader.golden("aim_official_test", aspect: "channels")
        #expect(golden.channelCount > 0)
        #expect(golden.channels.count == golden.channelCount)
        #expect(golden.channels.contains { $0.name == "AccelerometerX" })
    }
}

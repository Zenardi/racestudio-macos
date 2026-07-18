#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Coverage for the production adapter (`FFISessionLoader`) and the FFI-backed
/// `SessionStore()` convenience.
///
/// The pure FFI→domain mapping and error path are tested without any `.xrk`
/// sample; two golden-validation tests additionally decode the real
/// `aim_official_test.xrk` through the Rust core and assert the channel/lap
/// counts match the committed libxrk goldens, skipping cleanly when the
/// git-ignored sample is absent (`make fixtures`). Gated on
/// `RaceStudioFFIBindings` so a fresh checkout without the xcframework builds.
@Suite struct FFISessionLoaderTests {

    private static let fixtureName = "aim_official_test"

    /// The real sample URL, or `nil` (with a skip note) when it is absent.
    private func fixtureURLOrSkip() -> URL? {
        let url = FixtureLoader.url(for: "\(Self.fixtureName).xrk")
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 2), magic == Data("<h".utf8) else {
            print("skipping: \(Self.fixtureName).xrk is not present — run `make fixtures`")
            return nil
        }
        try? handle.close()
        return url
    }

    // MARK: - Fixture-independent

    @Test func test_makes_domain_session_from_ffi_readouts() {
        let metadata = RaceStudioFFIBindings.SessionMetadata(
            vehicle: "V", track: "T", driver: "D", session: "S", series: "R",
            logDate: "01/02/2003", logTime: "04:05:06", datetimeUtc: 42)
        let channels = [ChannelInfo(name: "RPM", unit: "rpm", sampleRateHz: 100, decimals: 0, sampleCount: 7)]
        let laps = [LapInfo(index: 0, startTimeS: 0, durationS: 1.5, endTimeS: 1.5)]

        let session = FFISessionLoader.makeSession(metadata: metadata, channels: channels, laps: laps)

        // Metadata asserted field-by-field: the Core and FFI `SessionMetadata`
        // types collide by name in this file, so we avoid naming the Core one.
        #expect(session.metadata.vehicle == "V")
        #expect(session.metadata.track == "T")
        #expect(session.metadata.driver == "D")
        #expect(session.metadata.session == "S")
        #expect(session.metadata.series == "R")
        #expect(session.metadata.logDate == "01/02/2003")
        #expect(session.metadata.logTime == "04:05:06")
        #expect(session.metadata.datetimeUtc == 42)
        #expect(session.channels == [Channel(name: "RPM", unit: "rpm", sampleRateHz: 100, decimals: 0, sampleCount: 7)])
        #expect(session.laps == [Lap(index: 0, startTimeS: 0, durationS: 1.5, endTimeS: 1.5)])
        _ = FFISessionLoader()
    }

    @MainActor @Test func test_default_store_uses_ffi_loader_and_is_idle() {
        #expect(SessionStore().state == .idle)
    }

    @Test func test_load_throws_on_unreadable_path() async {
        await #expect(throws: (any Error).self) {
            _ = try await FFISessionLoader().load(URL(fileURLWithPath: "/nonexistent/none.xrk")) { _ in }
        }
    }

    @Test func test_ffi_decode_errors_translate_to_core_decode_error() {
        #expect(DecodeError(FfiDecodeError.Io(message: "disk")) == .io(message: "disk"))
        #expect(DecodeError(FfiDecodeError.BadMagic) == .badMagic)
        #expect(DecodeError(FfiDecodeError.TruncatedHeader) == .truncatedHeader)
        #expect(DecodeError(FfiDecodeError.TruncatedChannel) == .truncatedChannel)
        #expect(DecodeError(FfiDecodeError.BadSampleCount) == .badSampleCount)
        #expect(DecodeError(FfiDecodeError.TruncatedGps) == .truncatedGps)
        #expect(DecodeError(FfiDecodeError.TruncatedLaps) == .truncatedLaps)
        #expect(DecodeError(FfiDecodeError.ChannelOutOfRange(index: 3, channelCount: 2))
            == .channelOutOfRange(index: 3, channelCount: 2))
        #expect(DecodeError(FfiDecodeError.Other(message: "y")) == .other(message: "y"))
    }

    // MARK: - Golden validation (skips when the sample is absent)

    @Test func test_ffi_loader_decodes_real_xrk_matching_golden() async throws {
        guard let url = fixtureURLOrSkip() else { return }

        let session = try await FFISessionLoader().load(url) { _ in }.session

        #expect(session.channels.count == (try GoldenSession.channelCount(Self.fixtureName)))
        #expect(session.laps.count == (try GoldenSession.lapCount(Self.fixtureName)))
        #expect(!session.metadata.driver.isEmpty)
    }

    @MainActor @Test func test_store_default_init_loads_real_session() async throws {
        guard let url = fixtureURLOrSkip() else { return }

        let store = SessionStore()
        await store.load(url: url)

        let viewModel = try #require(store.viewModel)
        #expect(viewModel.channels.count == (try GoldenSession.channelCount(Self.fixtureName)))
    }
}
#endif

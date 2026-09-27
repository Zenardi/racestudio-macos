import Foundation
import Testing
@testable import RaceStudioCore

/// Behaviour for a track's identity: which layout it is, which way round it is
/// driven, and the name the user wants to see for it.
///
/// A venue is often run in more than one configuration, and lap times are only
/// comparable within one layout and one direction — so both belong to the track,
/// not to a session. And because a logger stamps the venue from whatever track was
/// last configured on it, the name it records is unreliable: one of two stints at
/// the same circuit arrived labelled `Velopark1000`. Naming the *track* once
/// therefore has to fix every session recorded there, not just the one in front of
/// the user.
@Suite struct TrackIdentityTests {

    private func track(
        id: String = "sanmarino-kart-l2", name: String = "Kartódromo San Marino",
        layout: String = "Layout 2", direction: TrackDirection? = .counterClockwise
    ) -> DetectedTrackInfo {
        let gate = DetectedTrackGate(
            start: GPSCoord(latitude: -22.7768, longitude: -47.1201),
            end: GPSCoord(latitude: -22.7768, longitude: -47.1202))
        return DetectedTrackInfo(
            id: id, name: name, layout: layout, direction: direction,
            toleranceM: 40, startFinish: gate, sectorGates: [gate])
    }

    // MARK: - Layout and direction

    @Test func test_a_layout_is_appended_to_the_display_name() {
        #expect(track().displayName == "Kartódromo San Marino — Layout 2")
    }

    @Test func test_a_single_configuration_venue_shows_only_its_name() {
        #expect(track(name: "Adria International Raceway", layout: "").displayName
                == "Adria International Raceway")
    }

    @Test func test_direction_reads_as_words_not_an_enum_case() {
        #expect(TrackDirection.counterClockwise.title == "Counter-clockwise")
        #expect(TrackDirection.clockwise.title == "Clockwise")
    }

    /// The database does not record every venue's direction, and inventing one
    /// would be worse than admitting it is unknown.
    @Test func test_an_unrecorded_direction_stays_absent() {
        #expect(track(direction: nil).direction == nil)
    }

    // MARK: - Surfacing through the split model

    @Test func test_the_split_model_reports_the_layout_and_direction() {
        let model = TrackDetectionModel(detected: track())

        #expect(model.trackName == "Kartódromo San Marino — Layout 2")
        #expect(model.trackDirection == .counterClockwise)
    }

    @Test func test_the_beacon_fallback_reports_no_direction() {
        let model = TrackDetectionModel(detected: nil)

        #expect(model.trackName == nil)
        #expect(model.trackDirection == nil)
    }
}

/// Naming a track, and having that name reach every session recorded there.
@MainActor @Suite struct TrackNicknameTests {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).xrk") }
    private let sanMarino = "sanmarino-kart-l2"

    /// The detection a real San Marino session carries.
    private var detected: DetectedTrackInfo {
        let gate = DetectedTrackGate(
            start: GPSCoord(latitude: -22.7768, longitude: -47.1201),
            end: GPSCoord(latitude: -22.7768, longitude: -47.1202))
        return DetectedTrackInfo(
            id: sanMarino, name: "Kartódromo San Marino", layout: "Layout 2",
            direction: .counterClockwise, toleranceM: 40,
            startFinish: gate, sectorGates: [gate])
    }

    @Test func test_a_session_shows_its_decoded_venue_when_no_track_is_named() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"),
                  track: detected)

        #expect(model.sessions[0].displayTitle == "Velopark1000")
    }

    /// The point of the feature: the logger mis-stamped one of two stints at the same
    /// circuit, and naming the track fixes both at once.
    @Test func test_naming_a_track_retitles_every_session_recorded_there() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "S.Marino AR", datetimeUtc: 1_000),
                  sourceURL: url("a"), track: detected)
        model.add(SessionFixture.make(track: "Velopark1000", datetimeUtc: 2_000),
                  sourceURL: url("b"), track: detected)

        model.renameTrack(id: sanMarino, to: "San Marino")

        #expect(model.sessions.map(\.displayTitle) == ["San Marino", "San Marino"])
    }

    @Test func test_naming_a_track_leaves_sessions_at_other_tracks_alone() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "Adria", datetimeUtc: 1_000),
                  sourceURL: url("a"), track: DetectedTrackInfo(id: "adria", name: "Adria International Raceway",
                                           toleranceM: 40,
                                           startFinish: detected.startFinish, sectorGates: []))
        model.add(SessionFixture.make(track: "Velopark1000", datetimeUtc: 2_000),
                  sourceURL: url("b"), track: detected)

        model.renameTrack(id: sanMarino, to: "San Marino")

        #expect(model.sessions.map(\.displayTitle) == ["San Marino", "Adria"])
    }

    /// A session imported *after* the track was named must pick the name up, or the
    /// user has to rename on every import.
    @Test func test_a_session_imported_later_picks_up_the_track_name() {
        let model = LibraryBrowserModel()
        model.renameTrack(id: sanMarino, to: "San Marino")

        model.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"),
                  track: detected)

        #expect(model.sessions[0].displayTitle == "San Marino")
    }

    /// A name the user set on one session is more specific than the track's name, so
    /// it wins — a single stint can still be labelled "wet session".
    @Test func test_a_session_name_takes_precedence_over_the_track_name() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(track: "Velopark1000"),
                                sourceURL: url("a"), track: detected)
        model.renameTrack(id: sanMarino, to: "San Marino")

        model.rename(id: summary.id, to: "Wet session")

        #expect(model.sessions[0].displayTitle == "Wet session")
    }

    @Test func test_clearing_a_track_name_restores_the_decoded_venues() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"),
                  track: detected)
        model.renameTrack(id: sanMarino, to: "San Marino")

        model.renameTrack(id: sanMarino, to: "  ")

        #expect(model.sessions[0].displayTitle == "Velopark1000")
    }

    /// A session with no detected track cannot inherit any track name.
    @Test func test_a_session_with_no_detected_track_is_unaffected() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "Fuji GP Sh"), sourceURL: url("a"))

        model.renameTrack(id: sanMarino, to: "San Marino")

        #expect(model.sessions[0].displayTitle == "Fuji GP Sh")
    }

    @Test func test_track_names_persist_through_the_library_index() throws {
        let index = SessionIndex()
        index.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"),
                  track: detected)
        index.renameTrack(id: sanMarino, to: "San Marino")

        let restored = try JSONDecoder().decode(
            SessionIndex.self, from: try JSONEncoder().encode(index))

        #expect(restored.summaries[0].displayTitle == "San Marino")
        #expect(restored.trackName(id: sanMarino) == "San Marino")
    }

    @Test func test_search_matches_a_track_name() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"),
                  track: detected)
        model.renameTrack(id: sanMarino, to: "San Marino")

        model.search("marino")

        #expect(model.sessions.count == 1)
    }
}

/// What the library shows about the circuit a session was recorded at. Detection
/// already drove split geometry but was never surfaced, so the app knew which
/// circuit it was looking at and never said so.
@MainActor @Suite struct SessionTrackSummaryTests {

    private let gate = DetectedTrackGate(
        start: GPSCoord(latitude: -22.7768, longitude: -47.1201),
        end: GPSCoord(latitude: -22.7768, longitude: -47.1202))

    private func detected(layout: String, direction: TrackDirection?) -> DetectedTrackInfo {
        DetectedTrackInfo(id: "t", name: "Kartódromo San Marino", layout: layout,
                          direction: direction, toleranceM: 40,
                          startFinish: gate, sectorGates: [gate])
    }

    @Test func test_a_detected_session_reports_its_layout_and_direction() {
        let model = LibraryBrowserModel()

        let summary = model.add(SessionFixture.make(), sourceURL: URL(fileURLWithPath: "/tmp/a.xrk"),
                                track: detected(layout: "Layout 2", direction: .counterClockwise))

        #expect(summary.trackSummary == "Kartódromo San Marino — Layout 2 · Counter-clockwise")
    }

    /// A venue whose direction the database does not record must not invent one.
    @Test func test_an_unrecorded_direction_is_omitted_rather_than_guessed() {
        let model = LibraryBrowserModel()

        let summary = model.add(SessionFixture.make(), sourceURL: URL(fileURLWithPath: "/tmp/a.xrk"),
                                track: detected(layout: "", direction: nil))

        #expect(summary.trackSummary == "Kartódromo San Marino")
    }

    /// No match means the splits come from beacons; the library says nothing about
    /// a circuit rather than showing the logger's unreliable venue as if verified.
    @Test func test_an_unmatched_session_reports_no_track() {
        let model = LibraryBrowserModel()

        let summary = model.add(SessionFixture.make(), sourceURL: URL(fileURLWithPath: "/tmp/a.xrk"))

        #expect(summary.trackSummary == nil)
    }

    /// Re-importing must not lose the detection, which is derived at import time.
    @Test func test_reimporting_preserves_the_detected_track() {
        let model = LibraryBrowserModel()
        let session = SessionFixture.make()
        model.add(session, sourceURL: URL(fileURLWithPath: "/tmp/a.xrk"),
                  track: detected(layout: "Layout 2", direction: .counterClockwise))

        model.add(session, sourceURL: URL(fileURLWithPath: "/tmp/b.xrk"))

        #expect(model.sessions[0].trackSummary == "Kartódromo San Marino — Layout 2 · Counter-clockwise")
    }
}

/// The split model's track id, and the default "no detection" a data source that
/// does not implement matching falls back to.
@Suite struct TrackDetectionSourceTests {

    private let gate = DetectedTrackGate(
        start: GPSCoord(latitude: -22.7768, longitude: -47.1201),
        end: GPSCoord(latitude: -22.7768, longitude: -47.1202))

    /// The id is the key a user-chosen track name is stored against, so the split
    /// model has to expose it alongside the geometry.
    @Test func test_the_split_model_reports_the_detected_track_id() {
        let detected = DetectedTrackInfo(
            id: "sanmarino-kart-l2", name: "Kartódromo San Marino", layout: "Layout 2",
            direction: .counterClockwise, toleranceM: 40, startFinish: gate, sectorGates: [gate])

        #expect(TrackDetectionModel(detected: detected).trackID == "sanmarino-kart-l2")
    }

    @Test func test_the_beacon_fallback_reports_no_track_id() {
        #expect(TrackDetectionModel(detected: nil).trackID == nil)
    }

    /// A data source that does not implement matching (every non-FFI test loader)
    /// takes the protocol default, so the caller falls back to beacon segmentation
    /// rather than failing.
    @Test func test_a_source_without_matching_detects_no_track() {
        let source = FakeSessionDataSource(banks: [], gps: [])

        #expect(source.detectTrack() == nil)
    }
}

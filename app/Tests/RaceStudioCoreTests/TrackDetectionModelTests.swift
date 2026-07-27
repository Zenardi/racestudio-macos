import Foundation
import Testing

@testable import RaceStudioCore

/// Tests for track detection (issue 9.2): the ``TrackDetectionModel`` split-source
/// resolver, the ``DetectedTrackInfo`` geometry it carries, and its surfacing
/// through ``AnalysisSession`` — including the clean beacon fallback when a session
/// matched no bundled track.
@Suite struct TrackDetectionModelTests {

    // MARK: - Builders (no logic — fixed data)

    private func gate(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> DetectedTrackGate {
        DetectedTrackGate(
            start: GPSCoord(latitude: aLat, longitude: aLon),
            end: GPSCoord(latitude: bLat, longitude: bLon))
    }

    private func adria() -> DetectedTrackInfo {
        DetectedTrackInfo(
            id: "adria", name: "Adria International Raceway", toleranceM: 40,
            startFinish: gate(45.0, 12.0, 45.0, 12.001),
            sectorGates: [gate(45.001, 12.0, 45.001, 12.001), gate(45.002, 12.0, 45.002, 12.001)])
    }

    private func session() -> Session {
        Session(
            metadata: SessionMetadata(
                vehicle: "", track: "", driver: "", session: "",
                series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [], laps: [])
    }

    // MARK: - Geometry value types

    @Test func gate_midpoint_is_the_average_of_its_endpoints() {
        let mid = gate(45.0, 12.0, 45.0, 12.002).midpoint
        #expect(abs(mid.latitude - 45.0) < 1e-9)
        #expect(abs(mid.longitude - 12.001) < 1e-9)
    }

    @Test func segment_count_is_one_more_than_the_sector_gates() {
        #expect(adria().segmentCount == 3, "two sector gates → three segments")
    }

    // MARK: - Auto-detected source

    @Test func auto_detected_surfaces_track_name_line_and_markers() throws {
        let model = TrackDetectionModel(detected: adria())

        #expect(model.isAutoDetected)
        #expect(model.trackName == "Adria International Raceway")
        #expect(model.segmentCount == 3)
        // The start/finish line is the definition's two endpoints, in order (these
        // are stored verbatim, so exact equality holds).
        #expect(model.startFinishLine == [
            GPSCoord(latitude: 45.0, longitude: 12.0),
            GPSCoord(latitude: 45.0, longitude: 12.001)
        ])
        // Sector markers are the gate midpoints, in track order.
        let markers = model.sectorMarkers
        try #require(markers.count == 2)
        for (marker, expectedLat) in zip(markers, [45.001, 45.002]) {
            #expect(abs(marker.latitude - expectedLat) < 1e-9)
            #expect(abs(marker.longitude - 12.0005) < 1e-9)
        }
    }

    // MARK: - Beacon fallback

    @Test func no_detection_falls_back_to_beacons() {
        let model = TrackDetectionModel(detected: nil)

        #expect(model.source == .beacons)
        #expect(!model.isAutoDetected)
        #expect(model.trackName == nil)
        #expect(model.startFinishLine == nil, "start/finish then comes from beacons")
        #expect(model.sectorMarkers.isEmpty)
        #expect(model.segmentCount == nil)
    }

    // MARK: - Surfacing through AnalysisSession

    @MainActor @Test func analysis_session_surfaces_a_detected_track() {
        let source = FakeSessionDataSource(banks: [], detectedTrack: adria())
        let sut = AnalysisSession(session: session(), dataSource: source)

        #expect(sut.detectTrack() == adria())
        #expect(sut.trackDetection().isAutoDetected)
        #expect(sut.trackDetection().trackName == "Adria International Raceway")
    }

    @MainActor @Test func analysis_session_without_a_match_resolves_to_beacons() {
        // A data source that detects nothing (the default) surfaces the beacon
        // fallback through the pump — no track, no trap.
        let source = FakeSessionDataSource(banks: [])
        let sut = AnalysisSession(session: session(), dataSource: source)

        #expect(sut.detectTrack() == nil)
        #expect(sut.trackDetection().source == .beacons)
    }
}

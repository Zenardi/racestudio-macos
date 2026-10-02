#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Shared fixtures for the device panel suites (issues 6.7, #179): the golden
/// device (`discovery.json`), the de-identified captured catalog
/// (`catalog.json`), and a model already showing that catalog's session table.
@MainActor
enum DevicePanelFixtures {
    static func goldenDevice() throws -> Device {
        struct Golden: Decodable { let devices: [Row] }
        struct Row: Decodable { let name: String; let address: String; let port: UInt16; let model: String }
        let url = FixtureLoader.fixturesDir().appendingPathComponent("device/golden/discovery.json")
        let row = try #require(try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url)).devices.first)
        return Device(name: row.name, address: row.address, port: row.port, model: row.model)
    }

    /// The sessions of the de-identified captured catalog (`catalog.json`).
    static func goldenSessions() throws -> [DeviceSession] {
        struct Golden: Decodable { let sessions: [Row] }
        struct Row: Decodable {
            let fileName: String, sizeBytes: UInt32, date: Stamp, lapCount: UInt16
            let bestLapNumber: UInt16?, bestLapMs: UInt32?
            let driver: String, trackName: String, vehicle: String, championship: String
            let durationMs: UInt32?, trackLatitude: Double?, trackLongitude: Double?
        }
        struct Stamp: Decodable {
            let year: UInt16, month: UInt8, day: UInt8, hour: UInt8, minute: UInt8, second: UInt8
        }
        let url = FixtureLoader.fixturesDir().appendingPathComponent("device/golden/catalog.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Golden.self, from: Data(contentsOf: url)).sessions.map { row in
            let d = row.date
            return DeviceSession(
                fileName: row.fileName, sizeBytes: row.sizeBytes,
                date: RaceStudioFFIBindings.SessionDate(
                    year: d.year, month: d.month, day: d.day, hour: d.hour, minute: d.minute, second: d.second),
                lapCount: row.lapCount, bestLapNumber: row.bestLapNumber, bestLapMs: row.bestLapMs,
                driver: row.driver, trackName: row.trackName, vehicle: row.vehicle,
                championship: row.championship, durationMs: row.durationMs,
                trackLatitude: row.trackLatitude, trackLongitude: row.trackLongitude)
        }
    }

    static func catalog(_ sessions: [DeviceSession]) -> DeviceCatalog {
        DeviceCatalog(sessions: sessions, skippedRows: 0)
    }

    struct Harness {
        let model: DevicePanelModel
        let service: FakeDeviceService
        let importer: FakeSessionImporter
        let device: Device
        let sessions: [DeviceSession]
    }

    /// A model showing the golden device's golden session table.
    static func atSessions(
        failures: [String: Error] = [:], failingImports: Set<String> = [],
        progress: [Double] = [1.0], holdsDownloads: Bool = false
    ) async throws -> Harness {
        let device = try goldenDevice()
        let sessions = try goldenSessions()
        let service = FakeDeviceService(
            devices: .success([device]), catalog: .success(catalog(sessions)),
            failures: failures, progress: progress, holdsDownloads: holdsDownloads)
        let importer = FakeSessionImporter(failing: failingImports)
        let model = DevicePanelModel(service: service, importer: importer)
        await model.loadDevices()
        await model.select(device)
        return Harness(model: model, service: service, importer: importer, device: device, sessions: sessions)
    }

    /// Wait until `model` is downloading (for tests that cancel mid-queue).
    static func untilDownloading(_ model: DevicePanelModel) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if case .downloading = model.state { return }
            await Task.yield()
        }
        Issue.record("the model never started downloading")
    }
}
#endif

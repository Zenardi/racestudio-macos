#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// A source of discovered MyChron devices (issue 6.3).
///
/// The live `NWBrowser` adapter (``BonjourBrowser``) conforms to this; tests
/// inject a replay fake so the discovery *selection* logic runs against recorded
/// fixtures with no live device attached.
public protocol DeviceBrowsing: Sendable {
    /// Browse for devices, returning every announcement found (possibly empty).
    func browse() async throws -> [Device]
}

/// The AP-mode fallback device — the well-known gateway the MyChron serves on
/// when the Mac has joined its own access point (issue 6.3).
///
/// Delegates to the Rust core so the gateway address/port stay single-sourced
/// with `docs/device/PROTOCOL.md`.
public func apModeFallback() -> Device {
    apModeFallbackDevice()
}

/// Parse recorded/observed AP-mode discovery-response bytes into typed devices
/// via the Rust core (issue 6.3).
///
/// - Throws: ``DiscoveryError`` when a record is malformed or truncated.
public func parseDiscovery(_ bytes: Data) throws -> [Device] {
    try parseDeviceDiscovery(bytes: bytes)
}

/// Discover devices: run the primary (mDNS/Bonjour or replayed) browse, falling
/// back to the AP-mode gateway device when it finds none (issue 6.3).
///
/// This is the selection logic the 6.7 device UI drives; it is deterministic and
/// fixture-testable because `browser` is injected.
///
/// - Throws: rethrows any error from `browser`.
public func discoverDevices(using browser: some DeviceBrowsing) async throws -> [Device] {
    let found = try await browser.browse()
    return found.isEmpty ? [apModeFallback()] : found
}
#endif

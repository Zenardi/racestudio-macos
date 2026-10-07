import Foundation

/// Where an overlay export is (issue 9.13).
public enum ExportPhase: String, Sendable {
    /// Encoding frames.
    case encoding
    /// Every frame is encoded; the file is being finished — the writer's
    /// fast-start pass moves its index to the front.
    case finishing
    /// The file is in place at its destination.
    case complete
}

/// How far an overlay export has got (issue 9.13) — emitted several times a
/// second while it runs, and once more, complete, when it finishes.
public struct ExportProgress: Equatable, Sendable {
    /// Frames encoded so far.
    public let framesDone: Int
    /// Frames the export writes in all.
    public let totalFrames: Int
    /// Seconds since the export started.
    public let elapsed: TimeInterval
    /// Where the export is.
    public let phase: ExportPhase

    public init(framesDone: Int, totalFrames: Int, elapsed: TimeInterval, phase: ExportPhase = .encoding) {
        self.framesDone = framesDone
        self.totalFrames = totalFrames
        self.elapsed = elapsed
        self.phase = phase
    }

    /// The share of the work done, `0…1`. Finishing the file counts as one
    /// step after the last frame, so `1` means the export is complete — never
    /// merely every frame encoded.
    public var fraction: Double {
        guard phase != .complete else { return 1 }
        guard totalFrames > 0 else { return 0 }
        return min(max(Double(framesDone) / Double(totalFrames + 1), 0), 1)
    }

    /// A straight-line estimate of the seconds left at the pace so far, or
    /// `nil` before the first frame. The export sheet smooths it.
    public var estimatedRemaining: TimeInterval? {
        guard framesDone > 0, fraction > 0 else { return nil }
        return max(elapsed / fraction - elapsed, 0)
    }
}

/// Where an export checks the free space of its destination (issue 9.13): the
/// volume in production, a fake in tests.
public protocol DiskSpaceChecking: Sendable {
    /// The bytes free on the volume holding `url`, or `nil` when unknown.
    func availableCapacity(for url: URL) throws -> Int64?
}

/// The production ``DiskSpaceChecking``: the volume's capacity for important
/// use — what macOS can free up for a file the user asked to save.
public struct VolumeDiskSpace: DiskSpaceChecking {
    public init() {}

    public func availableCapacity(for url: URL) throws -> Int64? {
        try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

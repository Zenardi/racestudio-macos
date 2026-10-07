import Foundation

/// A failure as the export sheet tells it (issue 9.14): what went wrong, and
/// what to do about it.
public struct ExportUserMessage: Equatable, Sendable {
    /// What went wrong — "Not enough disk space — 3.1 GB needed".
    public let title: String
    /// What to do — "Free up space on that disk, or save the video to another one."
    public let fix: String

    public init(title: String, fix: String) {
        self.title = title
        self.fix = fix
    }
}

/// The brain of the export's progress sheet (issue 9.14).
///
/// ``start(_:to:cancel:)`` follows an ``OverlayVideoExporter`` progress
/// stream to its end, through these states:
///
/// - ``State/running`` while frames are encoded, with the latest
///   ``progress`` and a smoothed estimate of the time left (``remaining``);
/// - ``State/cancelling`` once ``cancel()`` has asked the exporter to stop,
///   until it reports that it has — its files removed — and the sheet is
///   ``State/idle`` again;
/// - ``State/finished(_:)`` with the file in place, or ``State/failed(_:)``
///   with the typed error, which ``userMessage(for:locale:)`` explains.
///
/// The time left is hidden until 3% of the work and two seconds have passed,
/// then smoothed: each new straight-line reading moves the estimate only
/// ``etaSmoothing`` of the way, the previous estimate counting down the time
/// since, so it settles instead of jumping with every pace change. While the
/// file is finished there is no frame pace to go by, and none is shown.
///
/// One export at a time: a start while one runs is ignored. The app keeps one
/// model, so quitting or closing the window can ask to cancel first
/// (``cancelAndWait()``).
@MainActor
public final class ExportProgressModel: ObservableObject {

    /// Where an export stands.
    public enum State: Equatable, Sendable {
        /// No export.
        case idle
        /// Encoding.
        case running
        /// Asked to stop; cleaning up.
        case cancelling
        /// Done: the file is at this URL.
        case finished(URL)
        /// Failed, for this reason; nothing is left behind.
        case failed(OverlayExportError)
    }

    /// The share of the work before the time left is shown.
    public static let etaWarmUpFraction = 0.03
    /// The seconds before the time left is shown.
    public static let etaWarmUpSeconds: TimeInterval = 2
    /// How far each new reading moves the time left.
    public static let etaSmoothing = 0.3

    /// Where the export stands.
    @Published public private(set) var state: State = .idle
    /// The latest progress, or `nil` before any.
    @Published public private(set) var progress: ExportProgress?
    /// The smoothed seconds left, or `nil` while hidden.
    @Published public private(set) var remaining: TimeInterval?
    /// Where the running or last export writes.
    public private(set) var destination: URL?

    private var task: Task<Void, Never>?
    private var cancelExport: (@Sendable () async -> Void)?

    public init() {}

    /// Whether an export is running or cleaning up after a cancel.
    public var isActive: Bool { state == .running || state == .cancelling }

    /// The share of the work done, `0…1`, for the progress bar.
    public var fraction: Double { progress?.fraction ?? 0 }

    // MARK: - Running

    /// Follow `stream` — an export writing to `destination` — to its end.
    /// `cancel` asks the exporter to stop (``OverlayVideoExporter/cancel()``).
    /// Ignored while another export is running.
    public func start(_ stream: AsyncThrowingStream<ExportProgress, Error>, to destination: URL,
                      cancel: @escaping @Sendable () async -> Void) {
        guard !isActive else { return }
        self.destination = destination
        cancelExport = cancel
        progress = nil
        remaining = nil
        lastElapsed = nil
        state = .running
        task = Task { [weak self] in
            do {
                for try await event in stream { self?.receive(event) }
                self?.end(.finished(destination))
            } catch {
                self?.fail(error)
            }
        }
    }

    /// Ask the running export to stop. The sheet shows "Cancelling…" until
    /// the exporter reports it has; then it is idle.
    public func cancel() {
        guard state == .running, let cancelExport else { return }
        state = .cancelling
        Task { await cancelExport() }
    }

    /// Cancel the running export, if any, and return once it has stopped and
    /// cleaned up — what quitting and closing the window wait for.
    public func cancelAndWait() async {
        cancel()
        await wait()
    }

    /// Return once the export being followed has ended.
    public func wait() async {
        await task?.value
    }

    /// Put a finished or failed export away; a running one stays.
    public func dismiss() {
        guard !isActive else { return }
        end(.idle)
    }

    /// Take in one progress event: the latest progress, and the time left.
    func receive(_ event: ExportProgress) {
        progress = event
        remaining = smoothedRemaining(after: event)
    }

    // MARK: - What the sheet says

    /// The progress line: `41% · frame 1,234 of 2,940 · 0:31 elapsed · about
    /// 0:43 left` — empty before any progress.
    public func statusLine(locale: Locale = .current) -> String {
        guard let progress else { return "" }
        let percent = "\(Int(progress.fraction * 100))%"
        let frames = L10n.format(.exportProgressFrames, locale: locale,
                                 L10n.formattedNumber(Double(progress.framesDone), fractionDigits: 0, locale: locale),
                                 L10n.formattedNumber(Double(progress.totalFrames), fractionDigits: 0, locale: locale))
        let elapsed = L10n.format(.exportProgressElapsed, locale: locale, ExportFormat.clock(progress.elapsed))
        let left: String
        if progress.phase == .finishing {
            left = L10n.string(.exportProgressFinishing, locale: locale)
        } else if let remaining {
            left = L10n.format(.exportProgressRemaining, locale: locale,
                               ExportFormat.clock(remaining, rule: .toNearestOrAwayFromZero))
        } else {
            left = L10n.string(.exportProgressEstimating, locale: locale)
        }
        return [percent, frames, elapsed, left].joined(separator: " · ")
    }

    /// The failure's message, or `nil` unless the export failed.
    public func failureMessage(locale: Locale = .current) -> ExportUserMessage? {
        guard case .failed(let error) = state else { return nil }
        return Self.userMessage(for: error, locale: locale)
    }

    /// `error` in plain language, with a fix.
    public static func userMessage(for error: OverlayExportError, locale: Locale = .current) -> ExportUserMessage {
        let text = { (key: L10n.Key) in L10n.string(key, locale: locale) }
        switch error {
        case .sourceUnreadable:
            return ExportUserMessage(title: text(.exportErrorSourceUnreadable), fix: text(.exportFixSourceUnreadable))
        case .noVideoTrack:
            return ExportUserMessage(title: text(.exportErrorNoVideoTrack), fix: text(.exportFixNoVideoTrack))
        case .rangeOutsideFootage:
            return ExportUserMessage(title: text(.exportErrorRangeOutsideFootage),
                                     fix: text(.exportFixRangeOutsideFootage))
        case .destinationIsSource:
            return ExportUserMessage(title: text(.exportErrorDestinationIsSource),
                                     fix: text(.exportFixDestinationIsSource))
        case .unsupportedOutput(let reason):
            return message(for: reason, locale: locale)
        case let .insufficientDiskSpace(required, available):
            let needed = ExportFormat.bytes(required, locale: locale)
            let title = available.map {
                L10n.format(.exportErrorDiskSpace, locale: locale, needed, ExportFormat.bytes($0, locale: locale))
            } ?? L10n.format(.exportErrorDiskFull, locale: locale, needed)
            return ExportUserMessage(title: title, fix: text(.exportFixDiskSpace))
        case .writerFailed(let reason):
            return ExportUserMessage(title: L10n.format(.exportErrorWriterFailed, locale: locale, reason),
                                     fix: text(.exportFixWriterFailed))
        case .cancelled:
            return ExportUserMessage(title: text(.exportErrorCancelled), fix: text(.exportFixCancelled))
        }
    }

    // MARK: - Internals

    private static func message(for reason: UnsupportedOutputReason, locale: Locale) -> ExportUserMessage {
        switch reason {
        case .codecUnavailable:
            return ExportUserMessage(title: L10n.string(.exportErrorCodecUnavailable, locale: locale),
                                     fix: L10n.string(.exportFixCodecUnavailable, locale: locale))
        case let .dimensionsTooLarge(width, height, codec):
            return ExportUserMessage(title: L10n.format(.exportErrorTooLarge, locale: locale, "\(width) × \(height)",
                                                        codec == .hevc ? "HEVC" : "H.264"),
                                     fix: L10n.string(.exportFixTooLarge, locale: locale))
        case let .dimensionsTooSmall(width, height):
            return ExportUserMessage(title: L10n.format(.exportErrorTooSmall, locale: locale, "\(width) × \(height)"),
                                     fix: L10n.string(.exportFixTooSmall, locale: locale))
        }
    }

    /// The time left after `event`: hidden while warming up and while
    /// finishing; the first reading as it is; later ones smoothed.
    private func smoothedRemaining(after event: ExportProgress) -> TimeInterval? {
        guard event.phase == .encoding, event.fraction >= Self.etaWarmUpFraction,
              event.elapsed >= Self.etaWarmUpSeconds, let reading = event.estimatedRemaining else { return nil }
        guard let previous = remaining, let since = lastElapsed.map({ event.elapsed - $0 }) else {
            lastElapsed = event.elapsed
            return reading
        }
        lastElapsed = event.elapsed
        return Self.etaSmoothing * reading + (1 - Self.etaSmoothing) * max(previous - since, 0)
    }

    private var lastElapsed: TimeInterval?

    private func end(_ state: State) {
        self.state = state
        cancelExport = nil
        if state == .idle {
            progress = nil
            remaining = nil
            lastElapsed = nil
        }
    }

    private func fail(_ error: Error) {
        let typed = OverlayExportError(mapping: error, requiredBytes: 0)
        end(typed == .cancelled ? .idle : .failed(typed))
    }
}

import Foundation

/// What the export sheet exports (issue 9.14) — the choices of its range menu.
/// Each resolves to an ``ExportRange`` once the session's laps and the
/// section under review are known.
public enum ExportRangeChoice: String, CaseIterable, Sendable {
    /// Every frame of the video.
    case wholeFootage
    /// The session's span.
    case session
    /// The session's fastest lap.
    case bestLap
    /// The laps picked in the sheet, as one clip.
    case selectedLaps
    /// The lap or sector under review in Video + Data.
    case selection
}

/// Which overlay the export burns in (issue 9.14): the workspace's own, as
/// arranged in the overlay editor, or a built-in preset.
public enum ExportOverlayChoice: Hashable, Sendable {
    /// The workspace's overlay.
    case workspace
    /// A built-in preset.
    case preset(OverlayPreset)

    /// The choice's stable stored spelling: `workspace`, or the preset's name.
    public var storageValue: String {
        switch self {
        case .workspace: return Self.workspaceValue
        case .preset(let preset): return preset.rawValue
        }
    }

    /// The choice spelled `storageValue`, or `nil` for one this build doesn't
    /// know.
    public init?(storageValue: String) {
        if storageValue == Self.workspaceValue {
            self = .workspace
        } else if let preset = OverlayPreset(rawValue: storageValue) {
            self = .preset(preset)
        } else {
            return nil
        }
    }

    /// The choice as the sheet's overlay menu names it.
    public func title(locale: Locale = .current) -> String {
        switch self {
        case .workspace: return L10n.string(.exportOverlayWorkspace, locale: locale)
        case .preset(let preset): return preset.title(locale: locale)
        }
    }

    private static let workspaceValue = "workspace"
}

extension ExportCodec {
    /// The codec as the sheet's codec menu names it, with what it is for.
    public func title(locale: Locale = .current) -> String {
        switch self {
        case .h264: return L10n.string(.exportCodecH264, locale: locale)
        case .hevc: return L10n.string(.exportCodecHevc, locale: locale)
        }
    }
}

/// The export sheet's last-used choices (issue 9.14). A `nil` range or overlay
/// leaves it to the sheet's default rule; the output settings default to
/// ``ExportSettings``' own: 1080p H.264 with the sound kept.
public struct ExportPreferences: Equatable, Sendable {
    public var range: ExportRangeChoice?
    public var overlay: ExportOverlayChoice?
    public var settings: ExportSettings
    /// The widgets switched on or off for export, per overlay choice, by
    /// widget id (issue 9.19) — only where the switch differs from the
    /// overlay's own state.
    public var widgetSwitches: [ExportOverlayChoice: [OverlayWidget.ID: Bool]]

    public init(range: ExportRangeChoice? = nil, overlay: ExportOverlayChoice? = nil,
                settings: ExportSettings = ExportSettings(),
                widgetSwitches: [ExportOverlayChoice: [OverlayWidget.ID: Bool]] = [:]) {
        self.range = range
        self.overlay = overlay
        self.settings = settings
        self.widgetSwitches = widgetSwitches
    }
}

/// Keeps the export sheet's last-used choices per user (issue 9.14) — in
/// `UserDefaults` in the app, behind the ``KeyValueStoring`` seam.
///
/// Stored as a JSON object of strings, plus the widget switches as an object
/// of on/off values per overlay choice. Reading is lenient, field by field: a
/// value this build doesn't know (a newer build's codec, a hand edit), or one
/// of the wrong type, reads as that field's default — and a switch for an
/// unknown overlay, or one that isn't on/off, is dropped; bytes that aren't
/// such an object read as all defaults. Nothing here throws.
public struct ExportSettingsStore {

    /// Where the choices are kept unless told otherwise.
    public static let defaultKey = "com.racestudio.videoExport.lastUsed.v1"

    private let store: KeyValueStoring
    private let key: String

    public init(store: KeyValueStoring, key: String = ExportSettingsStore.defaultKey) {
        self.store = store
        self.key = key
    }

    /// The choices last saved, each unknown one at its default.
    public func load() -> ExportPreferences {
        guard let data = store.data(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ExportPreferences()
        }
        let text = { (field: Field) in object[field.rawValue] as? String }
        let defaults = ExportSettings()
        return ExportPreferences(
            range: text(.range).flatMap(ExportRangeChoice.init(rawValue:)),
            overlay: text(.overlay).flatMap(ExportOverlayChoice.init(storageValue:)),
            settings: ExportSettings(
                resolution: text(.resolution).flatMap(ExportResolution.init(rawValue:)) ?? defaults.resolution,
                codec: text(.codec).flatMap(ExportCodec.init(rawValue:)) ?? defaults.codec,
                audio: text(.audio).flatMap(ExportAudio.init(rawValue:)) ?? defaults.audio,
                outsideSession: text(.outsideSession).flatMap(OutsideSessionOverlay.init(rawValue:))
                    ?? defaults.outsideSession),
            widgetSwitches: Self.switches(object[Field.widgets.rawValue]))
    }

    /// Remember `preferences` for the next export.
    public func save(_ preferences: ExportPreferences) {
        var object: [String: Any] = [
            Field.resolution.rawValue: preferences.settings.resolution.rawValue,
            Field.codec.rawValue: preferences.settings.codec.rawValue,
            Field.audio.rawValue: preferences.settings.audio.rawValue,
            Field.outsideSession.rawValue: preferences.settings.outsideSession.rawValue
        ]
        object[Field.range.rawValue] = preferences.range?.rawValue
        object[Field.overlay.rawValue] = preferences.overlay?.storageValue
        if !preferences.widgetSwitches.isEmpty {
            object[Field.widgets.rawValue] = Dictionary(uniqueKeysWithValues: preferences.widgetSwitches.map {
                ($0.key.storageValue, $0.value)
            })
        }
        store.set(try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), forKey: key)
    }

    private enum Field: String {
        case range, overlay, resolution, codec, audio, outsideSession, widgets
    }

    /// The widget switches stored as `value`: each known overlay choice's
    /// on/off values, the rest dropped.
    private static func switches(_ value: Any?) -> [ExportOverlayChoice: [OverlayWidget.ID: Bool]] {
        guard let stored = value as? [String: Any] else { return [:] }
        var switches: [ExportOverlayChoice: [OverlayWidget.ID: Bool]] = [:]
        for (spelling, widgets) in stored {
            guard let choice = ExportOverlayChoice(storageValue: spelling),
                  let widgets = widgets as? [String: Any] else { continue }
            // JSON reads `true` and `1` alike as a number: only a boolean is on/off.
            let onOff = widgets.compactMapValues { $0 as? NSNumber }
                .filter { CFGetTypeID($0.value) == CFBooleanGetTypeID() }
            if !onOff.isEmpty { switches[choice] = onOff.mapValues(\.boolValue) }
        }
        return switches
    }
}

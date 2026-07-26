import Foundation

/// The parsed contents of an Apple String Catalog (`.xcstrings`) — the single
/// source of truth for the app's user-facing strings (issue 7.3).
///
/// The catalog is shipped **verbatim** into `Bundle.module` (a `.copy` resource
/// rule, not `.process`) and parsed here at runtime rather than compiled by
/// Xcode's `xcstringstool`. That makes the whole localization surface testable in
/// CI on a Command-Line-Tools-only runner — the completeness gate in
/// `LocalizationTests` reads the exact same JSON the app does, so a missing or
/// stale translation fails a test rather than shipping silently.
public struct LocalizationCatalog: Sendable, Equatable {

    /// One translation: its text and its catalog state (e.g. `"translated"`).
    public struct Unit: Sendable, Equatable {
        public let value: String
        public let state: String
        public init(value: String, state: String) {
            self.value = value
            self.state = state
        }
    }

    /// The catalog's source language (`"en"`), used as the last-resort fallback.
    public let sourceLanguage: String

    /// `key → language → unit`. Every key carries one entry per translated
    /// language; a key with no translations maps to an empty dictionary.
    public let entries: [String: [String: Unit]]

    public init(sourceLanguage: String, entries: [String: [String: Unit]]) {
        self.sourceLanguage = sourceLanguage
        self.entries = entries
    }

    /// All string keys, sorted for deterministic iteration.
    public var keys: [String] { entries.keys.sorted() }

    /// Every language that appears anywhere in the catalog (e.g. `["en", "pt-BR"]`).
    public var availableLanguages: Set<String> {
        Set(entries.values.flatMap(\.keys))
    }

    /// The per-language units for `key`, or `nil` when the key is absent.
    public func languages(for key: String) -> [String: Unit]? { entries[key] }

    /// The unit for `key` in `language`, or `nil` when either is absent.
    public func unit(forKey key: String, language: String) -> Unit? {
        entries[key]?[language]
    }

    /// The string for `key` in `language`, falling back to `fallback` when the key
    /// has no translation in `language`; `nil` when neither language has it.
    public func value(forKey key: String, language: String, fallback: String) -> String? {
        unit(forKey: key, language: language)?.value ?? unit(forKey: key, language: fallback)?.value
    }

    /// An empty catalog — the graceful fallback when the bundled resource cannot
    /// be loaded (a packaging regression, caught by tests, never a crash).
    public static let empty = LocalizationCatalog(sourceLanguage: "en", entries: [:])

    // MARK: - Loading

    public enum LoadError: Error, Equatable {
        /// The `.xcstrings` resource was not found in the bundle.
        case resourceMissing
        /// The resource was found but could not be decoded as a String Catalog.
        case malformed(String)
    }

    /// Loads and parses `Localizable.xcstrings` from `bundle`.
    public static func load(
        from bundle: Bundle,
        resource: String = "Localizable",
        extension ext: String = "xcstrings"
    ) throws -> LocalizationCatalog {
        guard let url = bundle.url(forResource: resource, withExtension: ext) else {
            throw LoadError.resourceMissing
        }
        return try parse(try Data(contentsOf: url))
    }

    /// Like ``load(from:resource:extension:)`` but degrades to ``empty`` on failure
    /// instead of throwing, so the app never crashes on a packaging fault.
    public static func loaded(from bundle: Bundle) -> LocalizationCatalog {
        (try? load(from: bundle)) ?? empty
    }

    /// Parses raw `.xcstrings` JSON into a catalog. Throws ``LoadError/malformed(_:)``
    /// when the bytes are not a valid String Catalog.
    public static func parse(_ data: Data) throws -> LocalizationCatalog {
        let raw: RawCatalog
        do {
            raw = try JSONDecoder().decode(RawCatalog.self, from: data)
        } catch {
            throw LoadError.malformed(String(describing: error))
        }
        var entries: [String: [String: Unit]] = [:]
        for (key, entry) in raw.strings {
            var units: [String: Unit] = [:]
            for (language, localization) in entry.localizations ?? [:] {
                guard let stringUnit = localization.stringUnit else { continue }
                // A source-language unit sometimes omits `state`; treat it as
                // translated so the completeness gate does not false-flag it.
                units[language] = Unit(value: stringUnit.value, state: stringUnit.state ?? "translated")
            }
            entries[key] = units
        }
        return LocalizationCatalog(sourceLanguage: raw.sourceLanguage, entries: entries)
    }

    /// The catalog bundled with `RaceStudioCore`. Loaded once; degrades to
    /// ``empty`` on a packaging fault (which the tests would catch first).
    public static let shared = loaded(from: .module)

    // MARK: - Codable mirror of the .xcstrings schema

    private struct RawCatalog: Decodable {
        let sourceLanguage: String
        let strings: [String: RawEntry]
    }
    private struct RawEntry: Decodable {
        let localizations: [String: RawLocalization]?
    }
    private struct RawLocalization: Decodable {
        let stringUnit: RawStringUnit?
    }
    private struct RawStringUnit: Decodable {
        let state: String?
        let value: String
    }
}

/// Typed access to the localized strings in ``LocalizationCatalog`` (issue 7.3).
///
/// Every user-facing string resolves through a ``Key`` here so keys are
/// compile-checked and enumerable — `LocalizationTests` asserts the ``Key`` set
/// and the catalog stay in lock-step, and a missing key resolves to a *flagged*
/// sentinel (never a silent empty string) that a developer notices immediately.
public enum L10n {

    /// Prefix on the sentinel returned for an unknown key. A resolved string that
    /// begins with this was NOT found in the catalog.
    public static let missingKeyPrefix = "⚠️MISSING:"

    /// Every user-facing string key. Raw values match the catalog keys exactly.
    public enum Key: String, CaseIterable, Sendable {
        case accessibilityChannelLabel = "accessibility.channel.label"
        case accessibilityChannelNoData = "accessibility.channel.noData"
        case accessibilityChannelSummary = "accessibility.channel.summary"
        case accessibilityChannelSummaryNoUnit = "accessibility.channel.summary.noUnit"
        case appName = "app.name"
        case chartAnalysisWindow = "chart.analysisWindow"
        case chartDeltaStrip = "chart.deltaStrip"
        case chartHistogram = "chart.histogram"
        case chartMathEditor = "chart.mathEditor"
        case chartPlot = "chart.plot"
        case chartScatter = "chart.scatter"
        case chartSpectrum = "chart.spectrum"
        case chartTrackMap = "chart.trackMap"
        case chartWorkspace = "chart.workspace"
        case controlAddChannel = "control.addChannel"
        case controlAddMathChannel = "control.addMathChannel"
        case controlAddPlot = "control.addPlot"
        case controlConnectDevice = "control.connectDevice"
        case controlDelete = "control.delete"
        case controlDownload = "control.download"
        case controlExportCSV = "control.exportCSV"
        case controlImport = "control.import"
        case controlOpen = "control.open"
        case controlRemoveChannel = "control.removeChannel"
        case controlRemovePlot = "control.removePlot"
        case controlResetZoom = "control.resetZoom"
        case controlSelectLap = "control.selectLap"
        case controlToggleLapOverlay = "control.toggleLapOverlay"
        case controlZoomIn = "control.zoomIn"
        case controlZoomOut = "control.zoomOut"
        case featureChannelsReport = "feature.channelsReport"
        case featureGauges = "feature.gauges"
        case featureMultiSessionCompare = "feature.multiSessionCompare"
        case featureReportExport = "feature.reportExport"
        case featureTrackDetection = "feature.trackDetection"
        case featureVideoSync = "feature.videoSync"
        case menuFile = "menu.file"
        case menuFileExport = "menu.file.export"
        case menuFileImport = "menu.file.import"
        case menuHelp = "menu.help"
        case menuView = "menu.view"
        case unitBar = "unit.bar"
        case unitCelsius = "unit.celsius"
        case unitDegrees = "unit.degrees"
        case unitG = "unit.g"
        case unitHertz = "unit.hertz"
        case unitKmh = "unit.kmh"
        case unitMeter = "unit.meter"
        case unitMillimeter = "unit.millimeter"
        case unitMph = "unit.mph"
        case unitPercent = "unit.percent"
        case unitRpm = "unit.rpm"
        case unitSecond = "unit.second"
        case unitVolt = "unit.volt"
    }

    /// The localized string for `key` in `locale` (default: the current locale).
    public static func string(_ key: Key, locale: Locale = .current) -> String {
        string(forKey: key.rawValue, locale: locale)
    }

    /// The localized string for a raw `rawKey` in `locale`. Resolves the closest
    /// available language (region-specific, then language, then the source
    /// language); an unknown key yields a flagged sentinel that names it.
    public static func string(forKey rawKey: String, locale: Locale = .current) -> String {
        let catalog = LocalizationCatalog.shared
        let language = languageCode(for: locale)
        return catalog.value(forKey: rawKey, language: language, fallback: catalog.sourceLanguage)
            ?? missingKeyPrefix + rawKey
    }

    /// The localized template for `key`, filled with `args`. Placeholders use
    /// positional specifiers (`%1$@`, `%2$@`, …) so a translation can reorder them.
    public static func format(_ key: Key, locale: Locale = .current, _ args: CVarArg...) -> String {
        String(format: string(key, locale: locale), locale: locale, arguments: args)
    }

    /// `value` formatted for `locale` with a fixed number of fraction digits — the
    /// locale drives the decimal and grouping separators (pt-BR: `1.234,5`; en:
    /// `1,234.5`). A non-finite value renders the em-dash placeholder, so a sensor
    /// gap never speaks a garbage number.
    public static func formattedNumber(
        _ value: Double,
        fractionDigits: Int,
        locale: Locale = .current
    ) -> String {
        guard value.isFinite else { return ChannelFormatting.emDash }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = max(0, fractionDigits)
        formatter.maximumFractionDigits = max(0, fractionDigits)
        return formatter.string(from: NSNumber(value: value)) ?? ChannelFormatting.emDash
    }

    /// Whether `value` is the flagged sentinel of an unresolved key.
    public static func isFlagged(_ value: String) -> Bool {
        value.hasPrefix(missingKeyPrefix)
    }

    /// The catalog language `locale` resolves to, among the catalog's available
    /// languages: an exact `lang-REGION` tag (`pt-BR`), then the bare language
    /// (`en`), then any tag sharing the language (`pt_PT` → `pt-BR`), then the
    /// source language.
    public static func languageCode(for locale: Locale) -> String {
        resolve(
            locale: locale,
            available: LocalizationCatalog.shared.availableLanguages,
            source: LocalizationCatalog.shared.sourceLanguage)
    }

    static func resolve(locale: Locale, available: Set<String>, source: String) -> String {
        let language = locale.language.languageCode?.identifier ?? source
        if let region = locale.language.region?.identifier {
            let tag = "\(language)-\(region)"
            if available.contains(tag) { return tag }
        }
        if available.contains(language) { return language }
        if let shared = available.sorted().first(where: { $0.hasPrefix(language + "-") }) {
            return shared
        }
        return source
    }
}

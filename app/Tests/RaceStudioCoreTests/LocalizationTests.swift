import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for the localization surface (issue 7.3): the `Localizable.xcstrings`
/// String Catalog, its `LocalizationCatalog` parser, and the typed `L10n` helper.
///
/// The catalog is shipped verbatim into `Bundle.module` and parsed at runtime, so
/// these assertions run deterministically in CI **without** Xcode's
/// `xcstringstool` — the catalog completeness gate is real, not build-time magic.
@Suite struct LocalizationTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")

    /// The bundled catalog, loaded the same way the app loads it. A load/packaging
    /// regression surfaces here (never a vacuous pass) because every test that
    /// walks keys also asserts the catalog is non-empty.
    private func catalog() throws -> LocalizationCatalog {
        try LocalizationCatalog.load(from: .module)
    }

    // MARK: - Catalog completeness

    @Test func test_all_en_keys_have_ptbr_translation() throws {
        let catalog = try catalog()
        #expect(!catalog.keys.isEmpty, "the bundled catalog must not be empty")

        for key in catalog.keys {
            let units = catalog.languages(for: key)
            #expect(units?[catalog.sourceLanguage] != nil, "key '\(key)' is missing its source (en) string")
            #expect(units?["pt-BR"] != nil, "key '\(key)' is missing a pt-BR translation")
        }
    }

    @Test func test_no_untranslated_or_stale_strings() throws {
        let catalog = try catalog()
        #expect(!catalog.keys.isEmpty)

        // Every unit is fully translated — none left in a `new`/`needs_review`/`stale` state.
        for (key, langs) in catalog.entries {
            for (lang, unit) in langs {
                #expect(unit.state == "translated",
                        "key '\(key)' [\(lang)] is not translated (state: \(unit.state))")
                #expect(!unit.value.isEmpty, "key '\(key)' [\(lang)] has an empty value")
            }
        }

        // No stale keys: the en and pt-BR key sets are identical (a pt-BR entry with
        // no matching en key would be an orphaned/stale translation, and vice-versa).
        let enKeys = Set(catalog.keys.filter { catalog.unit(forKey: $0, language: "en") != nil })
        let ptKeys = Set(catalog.keys.filter { catalog.unit(forKey: $0, language: "pt-BR") != nil })
        #expect(enKeys == ptKeys, "en and pt-BR key sets diverge: \(enKeys.symmetricDifference(ptKeys))")
    }

    /// Every typed `L10n.Key` resolves to a real (un-flagged) catalog entry in both
    /// shipped languages — no typed key points at a missing string.
    @Test func test_every_typed_key_resolves_in_both_languages() throws {
        let catalog = try catalog()
        #expect(!L10n.Key.allCases.isEmpty)
        #expect(catalog.keys.count == L10n.Key.allCases.count,
                "the catalog and the typed key list must be in lock-step")

        for key in L10n.Key.allCases {
            let enValue = L10n.string(key, locale: en)
            let ptValue = L10n.string(key, locale: ptBR)
            #expect(!L10n.isFlagged(enValue), "key '\(key.rawValue)' is unresolved in en")
            #expect(!L10n.isFlagged(ptValue), "key '\(key.rawValue)' is unresolved in pt-BR")
            #expect(!enValue.isEmpty)
            #expect(!ptValue.isEmpty)
        }
    }

    /// A pt-BR locale actually returns the Portuguese string, not the English one,
    /// for a key whose translations differ.
    @Test func test_ptbr_locale_returns_portuguese_string() {
        let enImport = L10n.string(.controlImport, locale: en)
        let ptImport = L10n.string(.controlImport, locale: ptBR)
        #expect(enImport != ptImport, "the import control label must differ between en and pt-BR")
    }

    // MARK: - Number formatting

    @Test func test_ptbr_locale_formats_numbers_localized() {
        // pt-BR uses a comma decimal separator (and a dot for thousands); en is the
        // mirror image. Number/date formatting must follow the locale.
        let enNumber = L10n.formattedNumber(1234.5, fractionDigits: 1, locale: en)
        let ptNumber = L10n.formattedNumber(1234.5, fractionDigits: 1, locale: ptBR)

        #expect(enNumber == "1,234.5", "en groups with ',' and points the decimal")
        #expect(ptNumber == "1.234,5", "pt-BR groups with '.' and commas the decimal")
        #expect(ptNumber.contains(","), "pt-BR decimal separator is a comma")
        #expect(ptNumber != enNumber)
    }

    @Test func test_number_formatting_respects_fraction_digits() {
        #expect(L10n.formattedNumber(3.14159, fractionDigits: 0, locale: en) == "3")
        #expect(L10n.formattedNumber(3.14159, fractionDigits: 2, locale: en) == "3.14")
        #expect(L10n.formattedNumber(3.1, fractionDigits: 2, locale: en) == "3.10", "pads to fixed digits")
    }

    @Test func test_number_formatting_is_nonfinite_safe() {
        // A sensor gap must never render a garbage numeric label.
        #expect(L10n.formattedNumber(.nan, fractionDigits: 1, locale: en) == ChannelFormatting.emDash)
        #expect(L10n.formattedNumber(.infinity, fractionDigits: 1, locale: en) == ChannelFormatting.emDash)
    }

    // MARK: - Lookup / flagging

    @Test func test_l10n_lookup_missing_key_is_flagged() throws {
        let catalog = try catalog()
        let missing = "this.key.does.not.exist"

        // The catalog reports the key as absent...
        #expect(catalog.unit(forKey: missing, language: "en") == nil)
        // ...and a lookup returns a *flagged* sentinel a developer will notice, never
        // an empty string masquerading as a real translation.
        let looked = L10n.string(forKey: missing, locale: en)
        #expect(L10n.isFlagged(looked), "a missing key must resolve to a flagged sentinel")
        #expect(looked.contains(missing), "the sentinel names the offending key")
        // A real key is, of course, not flagged.
        #expect(!L10n.isFlagged(L10n.string(forKey: L10n.Key.appName.rawValue, locale: en)))
    }

    @Test func test_language_resolution_falls_back_to_source() {
        // An unsupported locale (e.g. French) falls back to the source language
        // rather than flagging every string.
        let fr = Locale(identifier: "fr_FR")
        let value = L10n.string(.appName, locale: fr)
        #expect(!L10n.isFlagged(value))
        #expect(value == L10n.string(.appName, locale: en), "unsupported locales fall back to en")
    }

    @Test func test_language_resolution_matches_language_without_exact_region() {
        // A same-language, different-region locale not in the catalog (pt-PT, i.e.
        // Portugal) resolves to the shared language's available tag (pt-BR) rather
        // than falling through to English.
        let ptPT = Locale(identifier: "pt_PT")
        #expect(L10n.string(.controlImport, locale: ptPT) == L10n.string(.controlImport, locale: ptBR),
                "a bare/other-region Portuguese locale resolves to pt-BR")
    }

    // MARK: - Catalog loading & parsing

    @Test func test_load_from_bundle_without_catalog_throws() {
        // A bundle that does not carry the catalog surfaces a typed error rather
        // than an empty result masquerading as a valid catalog.
        #expect(throws: LocalizationCatalog.LoadError.resourceMissing) {
            _ = try LocalizationCatalog.load(from: Bundle(for: TestBundleMarker.self))
        }
    }

    @Test func test_loaded_degrades_to_empty_when_resource_absent() {
        let catalog = LocalizationCatalog.loaded(from: Bundle(for: TestBundleMarker.self))
        #expect(catalog.entries.isEmpty)
        #expect(catalog.keys.isEmpty)
        #expect(catalog.sourceLanguage == "en")
    }

    @Test func test_parse_rejects_malformed_json() {
        #expect(throws: LocalizationCatalog.LoadError.self) {
            _ = try LocalizationCatalog.parse(Data("this is not a string catalog".utf8))
        }
    }

    @Test func test_bundled_catalog_matches_shared() throws {
        // The bundled `shared` catalog is the same one `load(from: .module)` returns
        // (both non-empty), proving the resource shipped into Bundle.module.
        let loaded = try catalog()
        #expect(!LocalizationCatalog.shared.keys.isEmpty)
        #expect(LocalizationCatalog.shared.keys == loaded.keys)
        #expect(LocalizationCatalog.shared.availableLanguages == ["en", "pt-BR"])
    }

    @Test func test_missing_key_lookups_return_nil() throws {
        let catalog = try catalog()
        #expect(catalog.languages(for: "no.such.key") == nil)
        #expect(catalog.unit(forKey: "app.name", language: "de") == nil, "no German translation exists")
    }

    @Test func test_value_falls_back_to_source_language() {
        // A key present only in the source language still resolves for another
        // language via the fallback (an incomplete-catalog safety net).
        let catalog = LocalizationCatalog(sourceLanguage: "en", entries: [
            "greeting": ["en": .init(value: "Hi", state: "translated")]
        ])
        #expect(catalog.value(forKey: "greeting", language: "pt-BR", fallback: "en") == "Hi",
                "falls back to the source language")
        #expect(catalog.value(forKey: "greeting", language: "en", fallback: "en") == "Hi")
        #expect(catalog.value(forKey: "absent", language: "pt-BR", fallback: "en") == nil)
    }

    @Test func test_parse_handles_missing_localizations_and_state() throws {
        // A key with no localizations and a unit with no explicit state are both
        // valid .xcstrings shapes; the latter is treated as translated.
        let json = """
        {
          "sourceLanguage" : "en",
          "strings" : {
            "empty.key" : { },
            "stateless.key" : {
              "localizations" : { "en" : { "stringUnit" : { "value" : "Ready" } } }
            }
          },
          "version" : "1.0"
        }
        """
        let catalog = try LocalizationCatalog.parse(Data(json.utf8))
        #expect(catalog.languages(for: "empty.key") == [:], "a key with no localizations maps to empty")
        #expect(catalog.unit(forKey: "stateless.key", language: "en")?.state == "translated",
                "a unit with no explicit state defaults to translated")
        #expect(catalog.unit(forKey: "stateless.key", language: "en")?.value == "Ready")
    }

    @Test func test_format_placeholders_match_across_languages() throws {
        // Every translation of a key must reference the SAME set of positional
        // placeholders (`%1$@`, `%2$@`, …) as the source. A pt-BR value with a stray
        // extra `%n$@` would crash `String(format:)` for pt-BR users only — and CI
        // would otherwise stay green. This gate makes that class of regression fail.
        let catalog = try catalog()
        for key in catalog.keys {
            guard let langs = catalog.languages(for: key) else { continue }
            let reference = Self.positionalIndices(in: langs[catalog.sourceLanguage]?.value ?? "")
            for (lang, unit) in langs {
                #expect(Self.positionalIndices(in: unit.value) == reference,
                        "key '\(key)' [\(lang)] placeholders diverge from \(catalog.sourceLanguage)")
            }
        }
    }

    /// The set of positional argument indices (`%1$@` → 1) referenced by a format
    /// template. `%%` and a lone `%` are correctly ignored.
    private static func positionalIndices(in template: String) -> Set<Int> {
        var indices: Set<Int> = []
        let characters = Array(template)
        var index = 0
        while index < characters.count {
            if characters[index] == "%" {
                var cursor = index + 1
                var digits = ""
                while cursor < characters.count, characters[cursor].isNumber {
                    digits.append(characters[cursor])
                    cursor += 1
                }
                if cursor < characters.count, characters[cursor] == "$", let number = Int(digits) {
                    indices.insert(number)
                }
            }
            index += 1
        }
        return indices
    }

    @Test func test_resolve_selects_the_closest_available_language() {
        let available: Set<String> = ["en", "pt-BR"]
        #expect(L10n.resolve(locale: ptBR, available: available, source: "en") == "pt-BR", "exact region tag")
        #expect(L10n.resolve(locale: en, available: available, source: "en") == "en", "bare language tag")
        #expect(L10n.resolve(locale: Locale(identifier: "pt_PT"), available: available, source: "en") == "pt-BR",
                "same language, other region")
        #expect(L10n.resolve(locale: Locale(identifier: "fr_FR"), available: available, source: "en") == "en",
                "unsupported language falls back to source")
        #expect(L10n.resolve(locale: Locale(identifier: ""), available: available, source: "en") == "en",
                "a locale with no language code falls back to source")
    }
}

/// A test-module marker whose `Bundle(for:)` is the test bundle — which does NOT
/// carry `RaceStudioCore`'s `Localizable.xcstrings` resource — so it exercises the
/// catalog's resource-missing / degrade-to-empty paths.
private final class TestBundleMarker {}

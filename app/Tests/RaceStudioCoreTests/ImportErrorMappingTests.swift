import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ImportError(decodeError:)` (issue 2.5) — mapping every decode
/// failure to a distinct, non-empty, user-facing message with a recovery
/// suggestion where one applies.
@Suite struct ImportErrorMappingTests {

    /// Every distinguished `DecodeError`, one of each shape.
    private let allCases: [DecodeError] = [
        .io(message: "disk gone"),
        .badMagic,
        .truncatedHeader,
        .truncatedChannel,
        .badSampleCount,
        .truncatedGps,
        .truncatedLaps,
        .channelOutOfRange(index: 99, channelCount: 21),
        .other(message: "novel failure"),
        .other(message: "")
    ]

    @Test func test_each_decode_error_maps_to_distinct_message() {
        // The named/distinguished cases (excluding the two `.other` variants,
        // which are deliberately the same generic bucket) must be distinct.
        let distinguished = allCases.dropLast(2).map { ImportError(decodeError: $0).message }
        #expect(Set(distinguished).count == distinguished.count)
    }

    @Test func test_error_message_is_nonempty_for_all_cases() {
        for decodeError in allCases {
            let error = ImportError(decodeError: decodeError)
            #expect(!error.title.isEmpty, "title empty for \(decodeError)")
            #expect(!error.message.isEmpty, "message empty for \(decodeError)")
        }
    }

    @Test func test_unknown_error_maps_to_generic_message() {
        let error = ImportError(decodeError: .other(message: "boom"))

        #expect(error.title == "Import Failed")
        #expect(!error.message.isEmpty)
    }

    @Test func test_recovery_suggestion_present_where_applicable() {
        // Applicable: a read error tells the user to check the file.
        #expect(ImportError(decodeError: .io(message: "x")).recoverySuggestion != nil)
        #expect(ImportError(decodeError: .badMagic).recoverySuggestion != nil)
        // Not applicable: an internal index error has no user recovery.
        #expect(ImportError(decodeError: .channelOutOfRange(index: 1, channelCount: 2)).recoverySuggestion == nil)
    }
}

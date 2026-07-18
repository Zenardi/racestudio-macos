import Foundation
@testable import RaceStudioCore

/// A deterministic ``ExpressionValidating`` for the project/workspace tests
/// (issue 5.4) — stands in for the FFI parser so `RaceStudioCore` load/validate
/// logic is exercised without the xcframework.
///
/// It rejects any expression in `invalid` and records every expression it was
/// asked to validate (so a test can prove re-validation actually ran on load).
final class FakeExpressionValidator: ExpressionValidating, @unchecked Sendable {

    struct Invalid: Error {}

    private let invalid: Set<String>
    private(set) var validated: [String] = []

    init(invalid: Set<String> = []) {
        self.invalid = invalid
    }

    func validate(_ expression: String) throws {
        validated.append(expression)
        if invalid.contains(expression) { throw Invalid() }
    }
}

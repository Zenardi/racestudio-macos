import Foundation

/// How the export sheets write sizes and times (issue 9.14).
enum ExportFormat {

    /// A file size in decimal units, as the Finder shows them, in `locale`'s
    /// numbers: `3.1 GB` (`3,1 GB` in Portuguese), `74 MB`, `0.4 MB`.
    static func bytes(_ bytes: Int64, locale: Locale) -> String {
        let value = Double(max(bytes, 0))
        if value >= 1e9 { return L10n.formattedNumber(value / 1e9, fractionDigits: 1, locale: locale) + " GB" }
        let megabytes = value / 1e6
        return L10n.formattedNumber(megabytes, fractionDigits: megabytes >= 10 ? 0 : 1, locale: locale) + " MB"
    }

    /// A duration as a clock — `0:31`, `1:02:03` — its seconds rounded by
    /// `rule` (down for time elapsed; to the nearest for a time to come). A
    /// negative or non-finite duration reads `0:00`.
    static func clock(_ seconds: Double, rule: FloatingPointRoundingRule = .down) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(min(seconds, 359_999).rounded(rule)) : 0
        let hours = total / 3_600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }
}

//
//  LenientDateTranscoder.swift
//  SpatiumAPI
//

import Foundation
import OpenAPIRuntime

/// Decodes the timestamps this server actually sends.
///
/// SpatiumDDI is FastAPI, so timestamps come from Python's `datetime.isoformat()`
/// — microsecond precision, e.g. `2026-05-14T21:59:10.586198Z`. The runtime's
/// default transcoder uses `ISO8601DateFormatter` without fractional seconds and
/// rejects every one of them, so a client built straight from the document fails
/// to decode almost every response it receives.
///
/// `ISO8601DateFormatter` is also unreliable with more than three fractional
/// digits, so the fraction is normalised to milliseconds before parsing rather
/// than hoping the platform copes.
///
/// Delete this once the server serialises at millisecond precision —
/// see spatiumnorth/spatiumddi#907.
public struct LenientDateTranscoder: DateTranscoder {
    public init() {}

    public func decode(_ string: String) throws -> Date {
        let normalised = Self.normaliseFraction(in: string)

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: normalised) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: normalised) { return date }

        // A date-only value is legitimate for some fields.
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        if let date = dateOnly.date(from: normalised) { return date }

        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Not an ISO 8601 timestamp: \(string)")
        )
    }

    public func encode(_ date: Date) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Truncates or pads the fractional seconds to exactly three digits.
    ///
    /// Scanned by hand rather than with `Regex`, which is not `Sendable` and so
    /// cannot be hoisted into a stored property on a `Sendable` transcoder.
    static func normaliseFraction(in string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }

        var end = string.index(after: dot)
        while end < string.endIndex, string[end].isNumber {
            end = string.index(after: end)
        }

        let digits = string[string.index(after: dot)..<end]
        guard !digits.isEmpty, digits.count != 3 else { return string }

        let milliseconds =
            digits.count > 3
            ? String(digits.prefix(3))
            : String(digits).padding(toLength: 3, withPad: "0", startingAt: 0)
        return string.replacingCharacters(in: dot..<end, with: ".\(milliseconds)")
    }
}

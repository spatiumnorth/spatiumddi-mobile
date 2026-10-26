//
//  ServerVersion.swift
//  SpatiumDDI
//

import Foundation

/// A SpatiumDDI control-plane version.
///
/// The platform released CalVer — `2026.10.02-1` — until 1.0.0, and SemVer —
/// `1.0.0-beta.1`, `1.0.0` — from then on. Every SemVer release is newer than
/// every CalVer one. It also reports strings that are not releases at all: a
/// container built from `main` reports `dev` or `dev-<sha>-<rand>`, a
/// development control plane reports `latest`, a nightly reports
/// `0.0.0-nightly-YYYYMMDD+<sha>`, and packaging metadata can leave a `0.x`
/// placeholder. Those are not "very old" and must not compare as such, so they
/// are development builds rather than a parse failure sorted to the bottom.
///
/// The ordering is a port of the platform's own, `backend/app/core/versions.py`
/// (`parse_release`). Keep the two in step: an app that orders versions
/// differently from the server it is gating will refuse, or wave through, the
/// wrong ones.
nonisolated struct ServerVersion: Sendable, Equatable {
    /// Exactly what the server reported, less surrounding whitespace. Shown as
    /// is, so the operator sees the string they would find in the platform's
    /// own About page.
    let displayName: String
    /// The release this names, or nil for a development build.
    let release: Release?

    init(_ raw: String) {
        displayName = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        release = Release(parsing: displayName)
    }

    var isDevelopment: Bool { release == nil }

    /// Whether this version is at least `minimum`.
    ///
    /// A development build passes. It is deliberately not treated as "too old":
    /// a build from `main` is by definition newer than any release, and refusing
    /// it would lock the app out of exactly the servers it is developed against.
    /// The overview says plainly that the version could not be checked, which is
    /// the honest report — this is a permissive answer, not a verified one.
    func satisfiesMinimum(_ minimum: ServerVersion) -> Bool {
        guard let mine = release, let theirs = minimum.release else { return true }
        return mine >= theirs
    }
}

extension ServerVersion {
    /// A released build, in release order.
    nonisolated enum Release: Sendable, Equatable, Comparable {
        /// `YYYY.MM.DD-N`, before 1.0.0. A tag with no `-N` is run 0.
        case calendar(year: Int, month: Int, day: Int, run: Int)
        /// `MAJOR.MINOR.PATCH[-PRE][+BUILD]`, from 1.0.0. Build metadata is
        /// dropped: SemVer gives it no precedence, so `1.0.0+abc` is `1.0.0`.
        case semantic(major: Int, minor: Int, patch: Int, preRelease: [PreReleaseIdentifier])

        /// One dot-separated part of a SemVer pre-release, `beta` or `1` in
        /// `beta.1`.
        enum PreReleaseIdentifier: Sendable, Equatable, Comparable {
            // Declared in precedence order — numeric identifiers sort before
            // alphanumeric ones (SemVer §11.4.3) — which is the order the
            // synthesised `<` uses.
            case numeric(Int)
            case alphanumeric(String)
        }

        init?(parsing value: String) {
            // CalVer first, as the platform does — and a CalVer-shaped string
            // that is not a real date is nothing, not the SemVer `2026.2.30-1`
            // it would otherwise also parse as.
            if let (year, month, day, run) = Self.calendarParts(value) {
                guard Self.isValidDate(year: year, month: month, day: day) else { return nil }
                self = .calendar(year: year, month: month, day: day, run: run)
            } else if let semantic = Self.semantic(value) {
                self = semantic
            } else {
                return nil
            }
        }

        static func < (lhs: Release, rhs: Release) -> Bool {
            switch (lhs, rhs) {
            case (.calendar(let a, let b, let c, let d), .calendar(let e, let f, let g, let h)):
                return (a, b, c, d) < (e, f, g, h)
            case (.calendar, .semantic):
                return true
            case (.semantic, .calendar):
                return false
            case (.semantic(let a, let b, let c, let lhsPre), .semantic(let d, let e, let f, let rhsPre)):
                if (a, b, c) != (d, e, f) { return (a, b, c) < (d, e, f) }
                return precedes(lhsPre, rhsPre)
            }
        }

        /// SemVer §11 for two pre-release lists of the same version.
        ///
        /// An empty list is the release itself, which sorts after every
        /// pre-release of it. Otherwise identifiers compare left to right, and
        /// a list that runs out first is the earlier one.
        private static func precedes(_ lhs: [PreReleaseIdentifier], _ rhs: [PreReleaseIdentifier]) -> Bool {
            switch (lhs.isEmpty, rhs.isEmpty) {
            case (true, _): return false
            case (false, true): return true
            case (false, false): return lhs.lexicographicallyPrecedes(rhs)
            }
        }

        // MARK: Parsing

        private static func isASCIIDigits(_ text: Substring) -> Bool {
            !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
        }

        /// `[0-9A-Za-z-]+`, the SemVer identifier alphabet.
        private static func isIdentifier(_ text: Substring) -> Bool {
            !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }

        /// `^(\d{4})\.(\d{2})\.(\d{2})(?:-(\d+))?$` — the shape only; whether
        /// it is a real date is the caller's next question.
        private static func calendarParts(_ value: String) -> (Int, Int, Int, Int)? {
            let (date, run) = splitOnce(Substring(value), at: "-")
            let parts = date.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3,
                parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                parts.allSatisfy(isASCIIDigits),
                let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
            else { return nil }
            guard let run else { return (year, month, day, 0) }
            guard isASCIIDigits(run), let number = Int(run) else { return nil }
            return (year, month, day, number)
        }

        /// `MAJOR.MINOR.PATCH[-PRE][+BUILD]` with MAJOR at least 1. The 0.x
        /// range is where nightlies and packaging placeholders live, so it never
        /// names a release.
        private static func semantic(_ value: String) -> Release? {
            let (withoutBuild, build) = splitOnce(Substring(value), at: "+")
            if let build {
                guard !build.isEmpty,
                    build.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
                else { return nil }
            }
            let (core, pre) = splitOnce(withoutBuild, at: "-")
            let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
            guard numbers.count == 3, numbers.allSatisfy(isASCIIDigits),
                let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]),
                major >= 1
            else { return nil }

            var identifiers: [PreReleaseIdentifier] = []
            if let pre {
                let parts = pre.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.allSatisfy(isIdentifier) else { return nil }
                for part in parts {
                    if isASCIIDigits(part) {
                        guard let number = Int(part) else { return nil }
                        identifiers.append(.numeric(number))
                    } else {
                        identifiers.append(.alphanumeric(String(part)))
                    }
                }
            }
            return .semantic(major: major, minor: minor, patch: patch, preRelease: identifiers)
        }

        /// Splits at the first `separator`. The second half is nil when there is
        /// no separator, and empty when it is the last character.
        private static func splitOnce(_ text: Substring, at separator: Character) -> (Substring, Substring?) {
            guard let index = text.firstIndex(of: separator) else { return (text, nil) }
            return (text[..<index], text[text.index(after: index)...])
        }

        /// What Python's `date()` accepts: the proleptic Gregorian calendar,
        /// years from 1. `2026.02.30-1` is not a release; it is a typo.
        private static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
            guard year >= 1, (1...12).contains(month), day >= 1 else { return false }
            let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            let lengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            return day <= lengths[month - 1]
        }
    }
}

nonisolated enum SupportedServer {
    /// The oldest control plane this build is known to work against.
    ///
    /// This is the release the API client was generated from, and that is not a
    /// coincidence: it is the only version whose contract this app has actually
    /// been compiled against. Claiming compatibility with anything older would
    /// be a guess about backwards compatibility nothing here verifies.
    static let minimum = ServerVersion("2026.10.02-1")
}

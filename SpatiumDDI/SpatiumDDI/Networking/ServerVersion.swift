//
//  ServerVersion.swift
//  SpatiumDDI
//

import Foundation

/// A SpatiumDDI control-plane version.
///
/// The platform releases CalVer — `2026.08.22-1`. It also reports strings that
/// are not versions at all: a container built from `main` reports `dev`, and a
/// development control plane reports `latest`. Those are not "very old" and must
/// not compare as such, so they are a separate case rather than a parse failure
/// sorted to the bottom.
nonisolated enum ServerVersion: Sendable, Equatable {
    /// A released CalVer build: year, month, day, and the run within that day.
    case release(year: Int, month: Int, day: Int, run: Int)
    /// Anything that isn't CalVer — `dev`, `latest`, a branch name.
    case development(String)

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // `YYYY.MM.DD-N`. Anything else — including a CalVer-shaped string with
        // a non-numeric part — is a development build.
        let parts = trimmed.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let run = Int(parts[1]) else {
            self = .development(trimmed)
            return
        }
        let date = parts[0].split(separator: ".")
        guard date.count == 3,
            let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2])
        else {
            self = .development(trimmed)
            return
        }
        self = .release(year: year, month: month, day: day, run: run)
    }

    var isDevelopment: Bool {
        if case .development = self { return true }
        return false
    }

    /// Ordering over releases only. A development build has no place in the
    /// order — see `satisfiesMinimum`.
    private var sortKey: (Int, Int, Int, Int)? {
        if case .release(let year, let month, let day, let run) = self {
            return (year, month, day, run)
        }
        return nil
    }

    /// Whether this version is at least `minimum`.
    ///
    /// A development build passes. It is deliberately not treated as "too old":
    /// a build from `main` is by definition newer than any release, and refusing
    /// it would lock the app out of exactly the servers it is developed against.
    /// The overview says plainly that the version could not be checked, which is
    /// the honest report — this is a permissive answer, not a verified one.
    func satisfiesMinimum(_ minimum: ServerVersion) -> Bool {
        guard let mine = sortKey, let theirs = minimum.sortKey else { return true }
        return mine >= theirs
    }

    var displayName: String {
        switch self {
        case .release(let year, let month, let day, let run):
            String(format: "%04d.%02d.%02d-%d", year, month, day, run)
        case .development(let raw):
            raw
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
    static let minimum = ServerVersion("2026.09.04-1")
}

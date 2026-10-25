//
//  ServerVersionTests.swift
//  SpatiumDDITests
//

import Testing

@testable import SpatiumDDI

@Suite("Server version")
struct ServerVersionTests {
    @Test("A CalVer release parses into its parts")
    func parsesRelease() {
        let version = ServerVersion("2026.08.22-1")
        #expect(version.release == .calendar(year: 2026, month: 8, day: 22, run: 1))
        #expect(version.isDevelopment == false)
        #expect(version.displayName == "2026.08.22-1")
    }

    @Test("A CalVer tag with no run is run 0, as the platform reads it")
    func calendarWithoutRun() {
        #expect(ServerVersion("2026.08.22").release == .calendar(year: 2026, month: 8, day: 22, run: 0))
        #expect(ServerVersion("2026.08.22-1").satisfiesMinimum(ServerVersion("2026.08.22")))
        #expect(!ServerVersion("2026.08.22").satisfiesMinimum(ServerVersion("2026.08.22-1")))
    }

    @Test("A SemVer release parses into its parts")
    func parsesSemantic() {
        #expect(
            ServerVersion("1.0.0").release == .semantic(major: 1, minor: 0, patch: 0, preRelease: []))
        #expect(
            ServerVersion("1.0.0-beta.1").release
                == .semantic(major: 1, minor: 0, patch: 0, preRelease: [.alphanumeric("beta"), .numeric(1)]))
        #expect(
            ServerVersion("2.13.4-rc.2+build.7").release
                == .semantic(major: 2, minor: 13, patch: 4, preRelease: [.alphanumeric("rc"), .numeric(2)]))
    }

    // What the operator sees has to be what the platform's About page says —
    // never a reformatting the app made up.
    @Test(
        "The name shown is what the server sent",
        arguments: [
            "2026.08.22-1", "2026.08.22", "1.0.0-beta.1", "1.0.0+abc123", "0.0.0-nightly-20261001+abc", "dev",
        ]
    )
    func displayNameIsVerbatim(_ raw: String) {
        #expect(ServerVersion(raw).displayName == raw)
        #expect(ServerVersion("  \(raw)\n").displayName == raw)
    }

    // The lab reports "dev"; a development control plane reports "latest".
    // Neither is a version, and neither may be treated as an ancient release.
    @Test(
        "Strings that aren't releases are development builds",
        arguments: [
            "dev", "latest", "main", "dev-3f2a9c1-8812", "2026.08-1", "v2026.08.22-1", "v1.0.0", "",
            "   ",
        ]
    )
    func parsesDevelopment(_ raw: String) {
        let version = ServerVersion(raw)
        #expect(version.isDevelopment, "\(raw) should not parse as a release")
    }

    // A nightly is `0.0.0-nightly-YYYYMMDD+<sha>` (or the bare image tag), and
    // the 0.x range is packaging placeholders. SemVer releases start at 1.0.0.
    @Test(
        "Nightlies and 0.x placeholders are not releases",
        arguments: [
            "0.0.0-nightly-20261001+3f2a9c1", "0.0.0-nightly-20261001", "nightly-20261001", "0.1.0",
            "0.9.9-rc.1",
        ]
    )
    func nightliesAreDevelopment(_ raw: String) {
        #expect(ServerVersion(raw).isDevelopment, "\(raw) should not parse as a release")
    }

    @Test(
        "Malformed versions are not releases",
        arguments: [
            // CalVer-shaped but not a date. Not a SemVer with a 2026 major either.
            "2026.02.30-1", "2026.13.01-1", "0000.01.01-1", "2026.08.22-",
            // Broken SemVer: missing parts, empty identifiers, empty build,
            // characters outside the identifier alphabet.
            "1.0", "1.0.0.0", "1.0.0-", "1.0.0-beta..1", "1.0.0-beta.", "1.0.0+", "1.0.0+a+b",
            "1.0.0-beta_1", "1.0.0 beta", "1..0", "-1.0.0", "1.0.0-βeta",
        ]
    )
    func garbageIsDevelopment(_ raw: String) {
        #expect(ServerVersion(raw).isDevelopment, "\(raw) should not parse as a release")
    }

    @Test("A leap day is a real CalVer date, only in a leap year")
    func leapDays() {
        #expect(!ServerVersion("2028.02.29-1").isDevelopment)
        #expect(ServerVersion("2026.02.29-1").isDevelopment)
        #expect(ServerVersion("2100.02.29-1").isDevelopment)
        #expect(!ServerVersion("2000.02.29-1").isDevelopment)
    }

    @Test("Releases order by date, then by the run within the day")
    func ordersReleases() {
        let minimum = ServerVersion("2026.08.22-1")
        #expect(ServerVersion("2026.08.22-1").satisfiesMinimum(minimum))
        #expect(ServerVersion("2026.08.22-2").satisfiesMinimum(minimum))
        #expect(ServerVersion("2026.09.01-1").satisfiesMinimum(minimum))
        #expect(ServerVersion("2027.01.01-1").satisfiesMinimum(minimum))
        #expect(ServerVersion("2026.08.22-10").satisfiesMinimum(ServerVersion("2026.08.22-9")))

        #expect(!ServerVersion("2026.08.21-9").satisfiesMinimum(minimum))
        #expect(!ServerVersion("2026.07.31-1").satisfiesMinimum(minimum))
        #expect(!ServerVersion("2025.12.31-1").satisfiesMinimum(minimum))
    }

    // The reason this type had to learn SemVer: before, every 1.x server parsed
    // as a development build and was waved through unchecked.
    @Test("Every SemVer release is newer than every CalVer release")
    func semanticAfterCalendar() {
        let lastCalendar = ServerVersion("2099.12.31-99")
        #expect(ServerVersion("1.0.0").satisfiesMinimum(lastCalendar))
        #expect(ServerVersion("1.0.0-alpha").satisfiesMinimum(lastCalendar))
        #expect(!ServerVersion("2099.12.31-99").satisfiesMinimum(ServerVersion("1.0.0-alpha")))
        #expect(!ServerVersion("2026.10.02-1").satisfiesMinimum(ServerVersion("1.0.0")))
        #expect(!ServerVersion("1.0.0").isDevelopment)
    }

    @Test("SemVer orders numerically, not as text")
    func semanticNumericOrder() {
        #expect(ServerVersion("1.0.10").satisfiesMinimum(ServerVersion("1.0.9")))
        #expect(!ServerVersion("1.0.9").satisfiesMinimum(ServerVersion("1.0.10")))
        #expect(ServerVersion("1.10.0").satisfiesMinimum(ServerVersion("1.9.99")))
        #expect(ServerVersion("2.0.0").satisfiesMinimum(ServerVersion("1.99.99")))
        #expect(!ServerVersion("1.2.3").satisfiesMinimum(ServerVersion("1.2.4")))
    }

    // SemVer §11's own example chain, each strictly before the next.
    @Test("Pre-releases follow SemVer precedence, and sort before their release")
    func preReleasePrecedence() throws {
        let chain = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
            "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        ]
        let releases = try chain.map { try #require(ServerVersion($0).release) }
        for (earlier, later) in zip(releases, releases.dropFirst()) {
            #expect(earlier < later, "\(earlier) should sort before \(later)")
            #expect(!(later < earlier))
        }
        #expect(!ServerVersion("1.0.0-rc.2").satisfiesMinimum(ServerVersion("1.0.0")))
        #expect(ServerVersion("1.0.0").satisfiesMinimum(ServerVersion("1.0.0-rc.2")))
        #expect(ServerVersion("1.0.0-rc.2").satisfiesMinimum(ServerVersion("1.0.0-rc.1")))
        // A pre-release of the next version is still after this release.
        #expect(ServerVersion("1.0.1-beta.1").satisfiesMinimum(ServerVersion("1.0.0")))
    }

    @Test("Numeric pre-release identifiers sort before alphanumeric ones")
    func numericBeforeAlphanumeric() {
        #expect(!ServerVersion("1.0.0-1").satisfiesMinimum(ServerVersion("1.0.0-a")))
        #expect(ServerVersion("1.0.0-a").satisfiesMinimum(ServerVersion("1.0.0-1")))
        // Alphanumeric identifiers compare as ASCII text, so upper case first.
        #expect(!ServerVersion("1.0.0-RC").satisfiesMinimum(ServerVersion("1.0.0-beta")))
    }

    @Test("Build metadata has no precedence")
    func buildMetadataIgnored() {
        #expect(ServerVersion("1.0.0+abc").release == ServerVersion("1.0.0+def").release)
        #expect(ServerVersion("1.0.0+abc").satisfiesMinimum(ServerVersion("1.0.0")))
        #expect(ServerVersion("1.0.0").satisfiesMinimum(ServerVersion("1.0.0+abc")))
        #expect(!ServerVersion("1.0.0-rc.1+abc").satisfiesMinimum(ServerVersion("1.0.0")))
    }

    // A build from `main` is by definition newer than any release. Refusing it
    // would lock the app out of exactly the servers it is developed against —
    // so it passes, and the overview says the check did not actually run.
    @Test("A development build is not treated as too old")
    func developmentPasses() {
        #expect(ServerVersion("dev").satisfiesMinimum(ServerVersion("2026.08.22-1")))
        #expect(ServerVersion("latest").satisfiesMinimum(ServerVersion("2099.01.01-1")))
        #expect(ServerVersion("0.0.0-nightly-20200101+abc").satisfiesMinimum(ServerVersion("1.0.0")))
    }

    @Test("The declared minimum is the release the client was generated from")
    func minimumIsPinnedRelease() {
        #expect(SupportedServer.minimum.displayName == "2026.10.02-1")
        #expect(!SupportedServer.minimum.isDevelopment)
    }
}

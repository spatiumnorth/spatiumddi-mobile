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
        #expect(version == .release(year: 2026, month: 8, day: 22, run: 1))
        #expect(version.isDevelopment == false)
        #expect(version.displayName == "2026.08.22-1")
    }

    // The lab reports "dev"; a development control plane reports "latest".
    // Neither is a version, and neither may be treated as an ancient release.
    @Test(
        "Strings that aren't CalVer are development builds",
        arguments: ["dev", "latest", "main", "2026.08.22", "2026.08-1", "v2026.08.22-1", ""]
    )
    func parsesDevelopment(_ raw: String) {
        let version = ServerVersion(raw)
        #expect(version.isDevelopment, "\(raw) should not parse as a release")
    }

    @Test("Releases order by date, then by the run within the day")
    func ordersReleases() {
        let minimum = ServerVersion("2026.08.22-1")
        #expect(ServerVersion("2026.08.22-1").satisfiesMinimum(minimum))
        #expect(ServerVersion("2026.08.22-2").satisfiesMinimum(minimum))
        #expect(ServerVersion("2026.09.01-1").satisfiesMinimum(minimum))
        #expect(ServerVersion("2027.01.01-1").satisfiesMinimum(minimum))

        #expect(!ServerVersion("2026.08.21-9").satisfiesMinimum(minimum))
        #expect(!ServerVersion("2026.07.31-1").satisfiesMinimum(minimum))
        #expect(!ServerVersion("2025.12.31-1").satisfiesMinimum(minimum))
    }

    // A build from `main` is by definition newer than any release. Refusing it
    // would lock the app out of exactly the servers it is developed against —
    // so it passes, and the overview says the check did not actually run.
    @Test("A development build is not treated as too old")
    func developmentPasses() {
        #expect(ServerVersion("dev").satisfiesMinimum(ServerVersion("2026.08.22-1")))
        #expect(ServerVersion("latest").satisfiesMinimum(ServerVersion("2099.01.01-1")))
    }

    @Test("The declared minimum is the release the client was generated from")
    func minimumIsPinnedRelease() {
        #expect(SupportedServer.minimum.displayName == "2026.09.04-1")
        #expect(!SupportedServer.minimum.isDevelopment)
    }
}

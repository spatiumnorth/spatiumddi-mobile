//
//  OverviewSignalsTests.swift
//  SpatiumDDITests
//

import SwiftUI
import Testing

@testable import SpatiumDDI

/// The overview's rollup tiles: what each one counts, and how loud it is.
@Suite("Overview signals")
struct OverviewSignalsTests {
    @Test("Without-MFA is local users less the enrolled")
    func withoutMFA() {
        let signals = OverviewModel.SecuritySignals(
            failedLogins: 3, failedLoginWindowHours: 24, tokensExpiring: 1, mfaEnrolled: 7,
            mfaLocalUsers: 10, permissionChanges: 2, permissionChangeWindowDays: 7
        )
        #expect(signals.withoutMFA == 3)
    }

    /// No local users is "nobody lacks MFA", not a negative and not unknown.
    @Test("Without-MFA never goes negative")
    func withoutMFAClamped() {
        let none = OverviewModel.SecuritySignals(
            failedLogins: 0, failedLoginWindowHours: 24, tokensExpiring: 0, mfaEnrolled: 0,
            mfaLocalUsers: 0, permissionChanges: 0, permissionChangeWindowDays: 7
        )
        #expect(none.withoutMFA == 0)

        // The two counts come from separate queries; a tile must not show -1
        // if they ever disagree.
        let skewed = OverviewModel.SecuritySignals(
            failedLogins: 0, failedLoginWindowHours: 24, tokensExpiring: 0, mfaEnrolled: 5,
            mfaLocalUsers: 4, permissionChanges: 0, permissionChangeWindowDays: 7
        )
        #expect(skewed.withoutMFA == 0)
    }

    @Test("Circuit alerts count both kinds, as the web console does")
    func circuitAlerts() {
        let signals = OverviewModel.NetworkSignals(
            asnDrift: 0, roasExpiring: 0, roasExpired: 0, circuitTermsEnding: 2, circuitStatusChanged: 3
        )
        #expect(signals.circuitAlerts == 5)
    }

    @Test("Zero reads as an answer; anything raised is loud")
    func tint() {
        #expect(SignalTint.of(0) == .green)
        #expect(SignalTint.of(1) == .orange)
        #expect(SignalTint.of(4, raised: .red) == .red)
    }

    /// The tiles are gated on the same modules as the sidebar sections they
    /// open, so a tile can never lead to a section the sidebar is hiding.
    @Test("Tile gates match the sections they open")
    func gates() {
        #expect(AppSection.newDevices.featureModule == "security.new_device_watch")
        #expect(AppSection.asns.featureModule == "network.asn")
        #expect(AppSection.circuits.featureModule == "network.circuit")
    }
}

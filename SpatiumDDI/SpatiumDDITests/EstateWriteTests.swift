//
//  EstateWriteTests.swift
//  SpatiumDDITests
//

import Foundation
import SpatiumAPI
import Testing

@testable import SpatiumDDI

/// A MAC as it arrives from wherever it was copied.
@Suite("MAC address validation")
struct MACAddressTests {
    /// The separators a MAC turns up with. A switch's ARP table, a Windows
    /// `ipconfig`, a Cisco `show mac address-table` and a sticker all disagree,
    /// and refusing the shape somebody pasted sends them back to a laptop.
    @Test(
        "Every separator convention is accepted",
        arguments: [
            "aa:bb:cc:dd:ee:ff",
            "aa-bb-cc-dd-ee-ff",
            "aabb.ccdd.eeff",
            "aabbccddeeff",
            "AA:BB:CC:DD:EE:FF",
        ])
    func separators(text: String) {
        #expect(MACAddress.looksValid(text))
    }

    /// Twelve hex digits is the part a typo actually breaks, so it is the part
    /// that is checked. Eleven digits is the classic dropped character.
    @Test(
        "The wrong number of digits is refused",
        arguments: [
            "aa:bb:cc:dd:ee",
            "aa:bb:cc:dd:ee:f",
            "aa:bb:cc:dd:ee:fff",
            "",
        ])
    func wrongLength(text: String) {
        #expect(!MACAddress.looksValid(text))
    }

    /// A hostname typed into the MAC field is the likely mis-tap, and it has
    /// the right sort of shape — dots and alphanumerics — to slip through a
    /// looser check.
    @Test("Non-hex characters are refused")
    func nonHex() {
        #expect(!MACAddress.looksValid("host.example.com"))
        #expect(!MACAddress.looksValid("gg:bb:cc:dd:ee:ff"))
        #expect(!MACAddress.looksValid("10.1.0.50"))
    }
}

/// A TTL as typed into a zone.
@Suite("TTL parsing")
struct TTLValueTests {
    @Test("Ordinary values pass through", arguments: [0, 1, 300, 3600, 86400, 2_147_483_647])
    func accepted(value: Int) {
        #expect(TTLValue.parse(String(value)) == value)
    }

    /// The DNS ceiling is a signed 32-bit second count. A value above it is
    /// refused here rather than by a 422 the operator has to decode.
    @Test("Above the DNS ceiling is refused")
    func ceiling() {
        #expect(TTLValue.parse("2147483648") == nil)
        #expect(TTLValue.parse("99999999999") == nil)
    }

    /// A negative TTL is meaningless, and the minus sign is one keystroke from
    /// nothing on a number pad.
    @Test("Negative and non-numeric are refused")
    func rejected() {
        #expect(TTLValue.parse("-1") == nil)
        #expect(TTLValue.parse("") == nil)
        #expect(TTLValue.parse("1h") == nil)
        #expect(TTLValue.parse("3600.0") == nil)
    }

    @Test("Surrounding whitespace is not an error")
    func trims() {
        #expect(TTLValue.parse("  3600 \n") == 3600)
    }
}

/// One line of a change summary.
@Suite("Change summary lines")
struct FieldChangeTests {
    @Test("Both sides are named")
    func bothSides() {
        #expect(FieldChange.line("Name", from: "old", to: "new") == "Name: old → new")
    }

    /// A blank either side of an arrow reads as a rendering bug rather than as
    /// the fact it is. Setting a field and clearing one are both real edits and
    /// both have to be legible.
    @Test("An absent value is named rather than left blank")
    func emptySides() {
        #expect(FieldChange.line("Gateway", from: "", to: "10.1.0.1") == "Gateway: empty → 10.1.0.1")
        #expect(FieldChange.line("Gateway", from: "10.1.0.1", to: "") == "Gateway: 10.1.0.1 → empty")
    }

    /// The update schemas can't carry an explicit null, so emptying a field
    /// that had a value would be omitted and change nothing. Each sheet refuses
    /// it on this answer.
    @Test("Emptying a set field is a clear; anything else is not")
    func clears() {
        #expect(FieldChange.clears(from: "aa:bb:cc:dd:ee:ff", to: ""))
        #expect(FieldChange.clears(from: "3600", to: "  "))
        #expect(!FieldChange.clears(from: "", to: ""))
        #expect(!FieldChange.clears(from: "", to: "10.1.0.1"))
        #expect(!FieldChange.clears(from: "10.1.0.1", to: "10.1.0.254"))
    }
}

/// Telling this device's own credential apart from every other row.
@Suite("This device's token")
struct TokenPrefixTests {
    /// The server publishes `sddi_` plus five characters as a token's `prefix`,
    /// and that string is what the Access list shows for every row — so
    /// deriving it here reveals nothing the list does not.
    @Test("An API token yields the prefix the server publishes")
    func apiToken() {
        #expect(ControlPlaneSession.publishedPrefix(of: "sddi_WNFTZrestofthesecret") == "sddi_WNFTZ")
    }

    /// A `/auth/login` JWT has no prefix scheme. Returning empty means it
    /// matches no row, rather than matching the wrong one — which is the whole
    /// safety property, since the wrong match would label somebody else's
    /// token "this device" and aim the warning at the wrong operator.
    @Test("A JWT yields nothing, so it matches nothing")
    func jwt() {
        #expect(ControlPlaneSession.publishedPrefix(of: "eyJhbGciOiJIUzI1NiJ9.abc.def").isEmpty)
        #expect(ControlPlaneSession.publishedPrefix(of: "").isEmpty)
    }

    /// A truncated token is not a short prefix — it is a value that could
    /// match a row it is not.
    @Test("A token too short to carry a full prefix yields nothing")
    func truncated() {
        #expect(ControlPlaneSession.publishedPrefix(of: "sddi_").isEmpty)
        #expect(ControlPlaneSession.publishedPrefix(of: "sddi_ABC").isEmpty)
    }
}

/// The maintenance window as the app models it.
@Suite("Maintenance state")
struct MaintenanceStateTests {
    /// The server omits these fields on a control plane that has never had a
    /// change window, and an app that read that as "unknown" would have no
    /// state to render. Absent means off.
    @Test("Absent fields read as no window running")
    func absentIsOff() {
        let state = MaintenanceState(enabled: nil, message: nil, startedAt: nil)
        #expect(!state.isOn)
        #expect(state.message.isEmpty)
        #expect(state.startedAt == nil)
    }

    @Test("A running window carries its message and start time")
    func running() {
        let started = Date(timeIntervalSince1970: 1_780_000_000)
        let state = MaintenanceState(
            enabled: true, message: "Back at 14:00", startedAt: started
        )
        #expect(state.isOn)
        #expect(state.message == "Back at 14:00")
        #expect(state.startedAt == started)
    }

    /// The platform keeps the last message after a window is lifted, which is
    /// deliberate — the next window is usually about the same thing — so a
    /// message with the flag off must not read as a window still running.
    @Test("A kept message with the flag off is still off")
    func keptMessage() {
        let state = MaintenanceState(
            enabled: false, message: "Back at 14:00", startedAt: nil
        )
        #expect(!state.isOn)
        #expect(state.message == "Back at 14:00")
    }
}

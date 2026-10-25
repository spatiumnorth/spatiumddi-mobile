//
//  ClientLookupTests.swift
//  SpatiumDDITests
//

import SwiftUI
import Testing

@testable import SpatiumDDI

@Suite("Client lookup")
struct ClientLookupTests {
    /// The lookup sends the term as exactly one of `mac`, `ip` or `hostname`,
    /// so misreading a MAC as a hostname silently matches nothing — the search
    /// comes back empty and the technician concludes the machine never asked.
    @Test(
        "A MAC is recognised however it was punctuated",
        arguments: [
            "aa:bb:cc:dd:ee:ff",
            "AA-BB-CC-DD-EE-FF",
            "aabb.ccdd.eeff",
            "aabbccddeeff",
            "AABBCCDDEEFF",
        ]
    )
    func recognisesMAC(_ text: String) {
        #expect(ClientIdentifier.isMACLike(text), "\(text) should read as a MAC")
    }

    @Test(
        "Things that aren't MACs aren't treated as one",
        arguments: [
            "10.40.12.68",
            "laptop-1234",
            "aabbccddee",  // eleven digits
            "aabbccddeeffa",  // thirteen
            "zzbbccddeeff",  // not hex
            "",
        ]
    )
    func rejectsNonMAC(_ text: String) {
        #expect(!ClientIdentifier.isMACLike(text), "\(text) should not read as a MAC")
    }

    /// The bug this prevents is a 500, not a wrong result. `/logs/dhcp-activity`
    /// lower-cases the value and compares it straight against a Postgres
    /// MACADDR column, so anything Postgres cannot cast is a server error — and
    /// a technician typing an address off a label is exactly who hits it.
    @Test(
        "Any punctuation a technician might type canonicalises to one form",
        arguments: [
            "aa:bb:cc:dd:ee:ff",
            "AA-BB-CC-DD-EE-FF",
            "aabb.ccdd.eeff",
            "aabbccddeeff",
            "AABBCCDDEEFF",
            "  AA:bb:CC:dd:EE:ff  ",
        ]
    )
    func canonicalises(_ text: String) {
        #expect(ClientIdentifier.canonicalMAC(text) == "aa:bb:cc:dd:ee:ff")
    }

    @Test(
        "Anything that isn't twelve hex digits is refused locally",
        arguments: ["10.40.12.68", "laptop-1234", "aabbccddee", "aabbccddeeffa", "zzbbccddeeff", ""]
    )
    func refusesNonMAC(_ text: String) {
        #expect(ClientIdentifier.canonicalMAC(text) == nil)
    }

    @Test("An IPv4 address is recognised so it goes in the right filter")
    func recognisesIPv4() {
        #expect(ClientIdentifier.isIPv4Like("10.40.12.68"))
        #expect(ClientIdentifier.isIPv4Like("192.168.1.1"))
        #expect(!ClientIdentifier.isIPv4Like("10.40.12"))
        #expect(!ClientIdentifier.isIPv4Like("10.40.12."))
        #expect(!ClientIdentifier.isIPv4Like("host.example.com"))
        #expect(!ClientIdentifier.isIPv4Like("aa:bb:cc:dd:ee:ff"))
    }

    // A DHCPv6 lease has no MAC (optional since 2026.10.02-1) and is keyed by
    // DUID. Showing a blank, or a DUID unlabelled where a MAC is expected,
    // would misreport who holds the address.
    @Test("A lease is named by its MAC, else its DUID, labelled as one")
    func leaseClientFallsBackToDUID() {
        let duid = "00:01:00:01:2c:5e:aa:bb:aa:bb:cc:dd:ee:ff"
        #expect(LeaseClient(mac: "aa:bb:cc:dd:ee:ff", duid: duid) == .mac("aa:bb:cc:dd:ee:ff"))
        #expect(LeaseClient(mac: nil, duid: duid) == .duid(duid))
        #expect(LeaseClient(mac: "", duid: duid) == .duid(duid))
        #expect(LeaseClient(mac: nil, duid: nil) == .unknown)
        #expect(LeaseClient(mac: "", duid: "") == .unknown)

        #expect(LeaseClient(mac: nil, duid: duid).plainText == "DUID \(duid)")
        #expect(LeaseClient(mac: nil, duid: nil).plainText == nil)
    }

    @Test("Filtering a lease list matches a DUID as well as a MAC")
    func leaseClientFilterMatchesDUID() {
        #expect(LeaseClient(mac: nil, duid: "00:01:00:01:2C:5E").matches("2c:5e"))
        #expect(LeaseClient(mac: "aa:bb:cc:dd:ee:ff", duid: nil).matches("DD:EE"))
        #expect(!LeaseClient(mac: nil, duid: "00:01:00:01").matches("ff"))
        // The label is the app's, not the server's: typing "DUID" is not a match.
        #expect(!LeaseClient(mac: nil, duid: "00:01:00:01").matches("duid"))
        #expect(!LeaseClient(mac: nil, duid: nil).matches("aa"))
    }

    @Test("A NAK is coloured as the thing worth finding")
    func naksStandOut() {
        #expect(DHCPMessage.tint(for: "DHCP4_NAK") == .red)
        #expect(DHCPMessage.tint(for: "DHCP4_LEASE_DECLINE") == .red)
        #expect(
            DHCPMessage.tint(for: "DHCP4_LEASE_ALLOC") == .secondary
                || DHCPMessage.tint(for: "DHCP4_LEASE_ALLOC") == .blue)
        #expect(DHCPMessage.tint(for: "COMMAND_RECEIVED") == .secondary)
    }
}

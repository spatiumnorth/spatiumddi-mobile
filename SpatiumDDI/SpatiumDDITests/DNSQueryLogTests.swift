//
//  DNSQueryLogTests.swift
//  SpatiumDDITests
//

import SwiftUI
import Testing

@testable import SpatiumDDI

@Suite("DNS query log")
struct DNSQueryLogTests {
    /// Offering a server the endpoint refuses is offering a guaranteed 400.
    @Test("Only agent-shipped drivers have a query log", arguments: ["bind9", "BIND9", "powerdns"])
    func agentDrivers(_ driver: String) {
        #expect(DNSQueryLog.shipsQueryLog(driver: driver))
    }

    @Test("Windows and anything unknown do not", arguments: ["windows", "windows_dns", "", "unbound"])
    func nonAgentDrivers(_ driver: String) {
        #expect(!DNSQueryLog.shipsQueryLog(driver: driver))
    }

    @Test("The picker keeps the group a server was found in, and drops what has no log")
    func sources() {
        let found = DNSQueryLog.sources(
            [("1", "ns1", "bind9"), ("2", "dc1", "windows"), ("3", "ns2", "powerdns")],
            in: "corp"
        )
        #expect(found.map(\.id) == ["1", "3"])
        #expect(found.allSatisfy { $0.groupName == "corp" })
    }

    /// The mistake this exists to prevent: an unrecorded outcome shown as a
    /// blank where NOERROR would sit, and read as success.
    @Test("A missing rcode is unrecorded, never success")
    func unrecorded() {
        #expect(DNSQueryLog.Outcome(rcode: nil, answerCount: 3) == .unrecorded)
        #expect(DNSQueryLog.Outcome(rcode: "", answerCount: nil) == .unrecorded)
    }

    /// NODATA and NXDOMAIN are different faults that look identical without
    /// the label — but only a known zero is NODATA.
    @Test("NOERROR with no answers is NODATA; with an unknown count it is not")
    func noData() {
        #expect(DNSQueryLog.Outcome(rcode: "NOERROR", answerCount: 0) == .noData)
        #expect(DNSQueryLog.Outcome(rcode: "noerror", answerCount: 0) == .noData)
        #expect(DNSQueryLog.Outcome(rcode: "NOERROR", answerCount: 2) == .recorded("NOERROR"))
        #expect(DNSQueryLog.Outcome(rcode: "NOERROR", answerCount: nil) == .recorded("NOERROR"))
        #expect(DNSQueryLog.Outcome(rcode: "NXDOMAIN", answerCount: 0) == .recorded("NXDOMAIN"))
    }

    @Test("Failures are the loud colour")
    func tints() {
        #expect(DNSQueryLog.tint(for: "NOERROR") == .green)
        #expect(DNSQueryLog.tint(for: "nxdomain") == .orange)
        #expect(DNSQueryLog.tint(for: "SERVFAIL") == .red)
        #expect(DNSQueryLog.tint(for: "REFUSED") == .red)
    }
}

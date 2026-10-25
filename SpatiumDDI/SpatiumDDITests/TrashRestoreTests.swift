//
//  TrashRestoreTests.swift
//  SpatiumDDITests
//

import Foundation
import SpatiumAPI
import Testing

@testable import SpatiumDDI

/// What the restore confirmation says, and how a refusal is read.
@Suite("Trash restore")
struct TrashRestoreTests {
    @Test("A known type is named in the app's words; an unknown one verbatim")
    func subject() {
        #expect(TrashRestore.subject(type: "dns_zone", name: "corp.example.") == "DNS zone · corp.example.")
        #expect(TrashRestore.subject(type: "vlan", name: "VLAN 20") == "vlan · VLAN 20")
    }

    /// The batch is the unit of restore. A single row says nothing about
    /// company; a cascade says how many rows come back with it.
    @Test("The batch size is stated only when it is more than the row itself")
    func batch() {
        let single = TrashRestore.consequence(type: "subnet", batchSize: 1)
        #expect(!single.contains("in all"))
        #expect(single.contains("nothing is restored"))

        let cascade = TrashRestore.consequence(type: "dns_zone", batchSize: 12)
        #expect(cascade.contains("12 rows in all"))
        #expect(cascade.contains("records deleted with it"))
    }

    /// The 409's `detail` is an object, which the generic error envelopes
    /// don't read — so without this the operator would get no clue *what*
    /// clashed.
    @Test("A clash refusal is read with each conflict")
    func parsesRefusal() throws {
        let body = Data(
            """
            {"detail": {"message": "Restore would clash with active rows", "conflicts": [
              {"type": "subnet", "id": "1", "display": "10.1.0.0/24",
               "reason": "An active subnet with CIDR 10.1.0.0/24 already exists in this space"},
              {"type": "dns_record", "id": "2", "display": "", "reason": "An identical record already exists in zone"}
            ]}}
            """.utf8)
        let refusal = try #require(TrashRestoreRefusal.parse(body))
        #expect(refusal.message == "Restore would clash with active rows")
        #expect(
            refusal.lines == [
                "10.1.0.0/24 — An active subnet with CIDR 10.1.0.0/24 already exists in this space",
                "An identical record already exists in zone",
            ])
    }

    /// A string `detail` is the ordinary shape and belongs to `APIStatusError`;
    /// claiming it here would drop the server's sentence.
    @Test("Anything else is left to the generic error path")
    func otherShapes() {
        #expect(TrashRestoreRefusal.parse(Data(#"{"detail": "Soft-deleted row not found"}"#.utf8)) == nil)
        #expect(
            TrashRestoreRefusal.parse(Data(#"{"detail": {"message": "x", "conflicts": []}}"#.utf8)) == nil)
        #expect(TrashRestoreRefusal.parse(Data("not json".utf8)) == nil)
    }
}

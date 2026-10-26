//
//  PoolOccupancyTests.swift
//  SpatiumDDITests
//

import Foundation
import SpatiumAPI
import Testing

@testable import SpatiumDDI

@Suite("DHCP pool occupancy")
struct PoolOccupancyTests {
    private func row(_ poolID: String, assigned: Int) -> Components.Schemas.PoolOccupancyResponse {
        .init(
            assigned: assigned,
            computedAt: Date(),
            endIp: "10.0.0.200",
            free: 101 - assigned,
            percent: Double(assigned) / 101 * 100,
            poolId: poolID,
            poolName: "",
            poolType: "dynamic",
            scopeId: "scope",
            startIp: "10.0.0.100",
            total: 101
        )
    }

    @Test("Each row lands on the pool it measures")
    func keyed() {
        let byPool = PoolOccupancy.byPool([row("a", assigned: 10), row("b", assigned: 90)])
        #expect(byPool["a"]?.assigned == 10)
        #expect(byPool["b"]?.assigned == 90)
        // A pool the server didn't measure — a non-dynamic one — gets no bar,
        // rather than a 0% that is not a fact about it.
        #expect(byPool["c"] == nil)
    }

    @Test("A repeated pool does not crash; the last row wins")
    func duplicate() {
        let byPool = PoolOccupancy.byPool([row("a", assigned: 10), row("a", assigned: 20)])
        #expect(byPool.count == 1)
        #expect(byPool["a"]?.assigned == 20)
    }
}

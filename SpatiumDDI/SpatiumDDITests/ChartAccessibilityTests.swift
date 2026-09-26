//
//  ChartAccessibilityTests.swift
//  SpatiumDDITests
//

import Accessibility
import Foundation
import Testing

@testable import SpatiumDDI

/// What VoiceOver's Audio Graph is handed in place of the marks.
@MainActor
struct ChartAccessibilityTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Every series and every point reaches the descriptor")
    func seriesCarried() {
        let descriptor = TimeSeriesChartDescriptor(
            title: "Queries and SERVFAIL",
            summary: "211 queries, 3 failed.",
            valueTitle: "Count",
            series: [
                .init(name: "Queries", points: [(start, 100), (start.addingTimeInterval(60), 111)]),
                .init(name: "SERVFAIL", points: [(start, 0), (start.addingTimeInterval(60), 3)]),
            ]
        ).makeChartDescriptor()

        #expect(descriptor.series.map(\.name) == ["Queries", "SERVFAIL"])
        #expect(descriptor.series.map(\.dataPoints.count) == [2, 2])
        #expect(descriptor.summary == "211 queries, 3 failed.")
        let y = descriptor.yAxis as? AXNumericDataAxisDescriptor
        #expect(y?.range == 0...111)
    }

    /// A 4.3%→4.4% move heard across the whole pitch range is the audio
    /// version of an auto-scaled axis: noise that sounds like a trend.
    @Test("A percentage keeps its fixed 0–100 range")
    func fixedRange() {
        let descriptor = TimeSeriesChartDescriptor(
            title: "Utilisation", summary: "", valueTitle: "Percent used",
            series: [.init(name: "Used", points: [(start, 4.3), (start.addingTimeInterval(3600), 4.4)])],
            valueRange: 0...100
        ).makeChartDescriptor()

        let y = descriptor.yAxis as? AXNumericDataAxisDescriptor
        #expect(y?.range == 0...100)
    }

    @Test("A single sample and an all-zero series still give a usable range")
    func degenerateRanges() {
        let descriptor = TimeSeriesChartDescriptor(
            title: "t", summary: "", valueTitle: "Count",
            series: [.init(name: "s", points: [(start, 0)])]
        ).makeChartDescriptor()

        let x = descriptor.xAxis as? AXNumericDataAxisDescriptor
        let y = descriptor.yAxis as? AXNumericDataAxisDescriptor
        #expect((x?.range.upperBound ?? 0) > (x?.range.lowerBound ?? 0))
        #expect(y?.range == 0...1)
    }

    @Test("Window names are spelled out for speech", arguments: MetricsWindow.allCases)
    func spokenNames(window: MetricsWindow) {
        let spoken = String(localized: window.spokenName)
        #expect(spoken != window.rawValue)
        #expect(spoken.contains(" "))
    }
}

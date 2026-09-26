//
//  ChartAccessibility.swift
//  SpatiumDDI
//

import Accessibility
import SwiftUI

/// A time series as VoiceOver's Audio Graph reads it.
///
/// A summary label says what a chart concluded; an audio graph lets the
/// operator hear the shape — the NAK line lifting off zero at 02:10 — which is
/// the thing the chart was drawn to show. Without a descriptor a chart is a
/// labelled blank region, and the marks inside it are read one at a time as
/// "Time, 14:32, Queries, 211", up to 360 of them.
struct TimeSeriesChartDescriptor: AXChartDescriptorRepresentable {
    struct Series {
        let name: String
        let points: [(t: Date, value: Double)]
    }

    let title: String
    let summary: String
    let valueTitle: String
    let series: [Series]
    /// Fixed for a percentage, so a 4.3%→4.4% move is heard as flat rather
    /// than as a climb across the whole audio range.
    var valueRange: ClosedRange<Double>?

    func makeChartDescriptor() -> AXChartDescriptor {
        let times = series.flatMap { $0.points.map(\.t.timeIntervalSince1970) }
        let first = times.min() ?? 0
        let last = max(times.max() ?? 0, first + 1)
        let peak = series.flatMap { $0.points.map(\.value) }.max() ?? 0

        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Time"),
            range: first...last,
            gridlinePositions: []
        ) { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) }

        let yAxis = AXNumericDataAxisDescriptor(
            title: valueTitle,
            range: valueRange ?? 0...max(peak, 1),
            gridlinePositions: []
        ) { $0.formatted(.number.precision(.fractionLength(0...1))) }

        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series.map { series in
                AXDataSeriesDescriptor(
                    name: series.name,
                    isContinuous: true,
                    dataPoints: series.points.map {
                        AXDataPoint(x: $0.t.timeIntervalSince1970, y: $0.value)
                    }
                )
            }
        )
    }
}

extension View {
    /// One VoiceOver element for the whole chart: the summary as its label,
    /// and the series behind it for Audio Graph.
    func chartAccessibility(_ descriptor: TimeSeriesChartDescriptor) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: descriptor.title))
            .accessibilityValue(Text(verbatim: descriptor.summary))
            .accessibilityChartDescriptor(descriptor)
    }
}

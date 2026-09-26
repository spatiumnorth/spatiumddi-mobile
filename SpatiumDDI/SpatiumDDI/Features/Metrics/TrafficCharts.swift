//
//  TrafficCharts.swift
//  SpatiumDDI
//

import Charts
import SpatiumAPI
import SwiftUI

/// Traffic over time, drawn small enough to answer one question.
///
/// The web console's charts are dashboards. These are not, and the difference
/// is deliberate: a phone chart gets a glance, so each one here answers exactly
/// one question — "is the resolver being hammered right now", "is this subnet
/// filling up" — and everything that would dilute that is left off.

// MARK: - Windows

/// The spans the platform will aggregate over.
///
/// Exactly four, because the server accepts exactly four: anything else comes
/// back as `window must be one of ['1h', '24h', '6h', '7d']`. Modelling it as
/// an enum means that sentence can never reach an operator.
nonisolated enum MetricsWindow: String, CaseIterable, Identifiable, Sendable {
    case hour = "1h"
    case sixHours = "6h"
    case day = "24h"
    case week = "7d"

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .hour: "1h"
        case .sixHours: "6h"
        case .day: "24h"
        case .week: "7d"
        }
    }

    /// For a sentence VoiceOver reads aloud, where "7d" comes out as "seven d".
    var spokenName: LocalizedStringResource {
        switch self {
        case .hour: "1 hour"
        case .sixHours: "6 hours"
        case .day: "24 hours"
        case .week: "7 days"
        }
    }
}

// MARK: - Condensing

/// One sample of one series.
nonisolated struct Sample: Equatable, Sendable {
    var t: Date
    var value: Int
}

/// Samples after they have been folded to a drawable number.
nonisolated struct CondensedSeries: Equatable, Sendable {
    var samples: [Sample]
    /// How many seconds each returned sample now covers.
    var bucketSeconds: Int
}

nonisolated enum TimeSeries {
    /// The most marks worth drawing on a phone.
    ///
    /// A 24-hour window comes back as roughly 1,400 one-minute buckets and a
    /// 7-day window as 2,000. A phone chart is around 350 points wide, so
    /// drawing them one to one asks for four marks per pixel and hands back a
    /// solid block of colour. That is not a chart, and it is not fast either.
    static let maxPoints = 180

    /// Folds samples into at most `limit` buckets by **summing**.
    ///
    /// Summing rather than averaging or taking a maximum, and the choice shows
    /// on screen. An average flattens the spike that is the entire reason
    /// somebody opened the screen; a maximum inflates a quiet baseline into a
    /// busy-looking one. A sum simply continues the aggregation the server
    /// already did — it folded raw queries into per-minute buckets — so the
    /// only thing that changes is the bucket width, and the caller says what
    /// that width is next to the chart rather than leaving the axis to lie.
    static func condense(
        _ samples: [Sample], bucketSeconds: Int, into limit: Int = maxPoints
    ) -> CondensedSeries {
        guard limit > 0 else { return CondensedSeries(samples: [], bucketSeconds: bucketSeconds) }
        guard samples.count > limit else {
            return CondensedSeries(samples: samples, bucketSeconds: bucketSeconds)
        }

        // Ceiling division: a factor that rounds down would leave more buckets
        // than the limit allows.
        let factor = (samples.count + limit - 1) / limit
        var folded: [Sample] = []
        folded.reserveCapacity((samples.count + factor - 1) / factor)

        var index = 0
        while index < samples.count {
            let end = min(index + factor, samples.count)
            let slice = samples[index..<end]
            // Stamped with the start of the bucket, matching how the server
            // stamps its own — a bucket labelled with its end reads as an hour
            // of traffic that has not happened yet.
            folded.append(Sample(t: slice[index].t, value: slice.reduce(0) { $0 + $1.value }))
            index = end
        }

        return CondensedSeries(samples: folded, bucketSeconds: bucketSeconds * factor)
    }
}

// MARK: - Charts

/// Two series over time: a filled one and a line over it.
///
/// The shape the DHCP activity strip already uses, generalised. The filled
/// series is the ordinary traffic and the line is whatever means something has
/// gone wrong, so a glance at the line answers the question without reading
/// the axis.
struct TrafficChart: View {
    let volume: CondensedSeries
    let volumeLabel: String
    let volumeTint: Color
    let problem: CondensedSeries
    let problemLabel: String
    let problemTint: Color
    /// Read aloud in place of the marks, which VoiceOver cannot describe.
    let accessibilitySummary: String

    /// Scales with Dynamic Type: at the largest sizes the legend and axis
    /// labels grow into a fixed frame and squeeze the plot to a sliver.
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 130

    private var descriptor: TimeSeriesChartDescriptor {
        TimeSeriesChartDescriptor(
            title: String(localized: "\(volumeLabel) and \(problemLabel)"),
            summary: accessibilitySummary,
            valueTitle: String(
                localized: "Count per \(Duration.seconds(volume.bucketSeconds).formattedCompact)"),
            series: [
                .init(name: volumeLabel, points: volume.samples.map { ($0.t, Double($0.value)) }),
                .init(name: problemLabel, points: problem.samples.map { ($0.t, Double($0.value)) }),
            ]
        )
    }

    private var isSilent: Bool {
        volume.samples.allSatisfy { $0.value == 0 } && problem.samples.allSatisfy { $0.value == 0 }
    }

    var body: some View {
        if volume.samples.isEmpty {
            Text("The server returned no samples for this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isSilent {
            // A flat line at zero and "nothing happened" look identical on a
            // chart, and only one of them is the truth being reported.
            Text("No traffic in this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Chart {
                    ForEach(volume.samples, id: \.t) { sample in
                        AreaMark(
                            x: .value("Time", sample.t),
                            y: .value(volumeLabel, sample.value)
                        )
                        .foregroundStyle(by: .value("Series", volumeLabel))
                    }
                    ForEach(problem.samples, id: \.t) { sample in
                        LineMark(
                            x: .value("Time", sample.t),
                            y: .value(problemLabel, sample.value)
                        )
                        .foregroundStyle(by: .value("Series", problemLabel))
                    }
                }
                .chartForegroundStyleScale([
                    volumeLabel: volumeTint,
                    problemLabel: problemTint,
                ])
                .chartLegend(.visible)
                .frame(height: height)
                .chartAccessibility(descriptor)

                // The axis is a count per bucket, and the bucket is not always
                // the one the server sent — saying which keeps the numbers
                // honest after condensing.
                Text("totals per \(Duration.seconds(volume.bucketSeconds).formattedCompact)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// How a subnet's occupancy has moved.
///
/// "Is this subnet filling up, or was it always like this" is a triage
/// question, and a single percentage cannot answer it.
struct UtilisationTrendChart: View {
    let points: [Components.Schemas.UtilizationHistoryPoint]

    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 110

    private var descriptor: TimeSeriesChartDescriptor {
        TimeSeriesChartDescriptor(
            title: String(localized: "Utilisation trend"),
            summary: trendSummary,
            valueTitle: String(localized: "Percent used"),
            series: [
                .init(
                    name: String(localized: "Used"),
                    points: points.map { ($0.sampledAt, $0.utilizationPercent) })
            ],
            valueRange: 0...100
        )
    }

    /// Whether the figure has moved at all across the samples.
    private var isFlat: Bool {
        guard let first = points.first?.utilizationPercent else { return true }
        return points.allSatisfy { abs($0.utilizationPercent - first) < 0.05 }
    }

    var body: some View {
        if points.count < 2 {
            Text("Not enough history yet to draw a trend.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Chart(points, id: \.sampledAt) { point in
                    AreaMark(
                        x: .value("Sampled", point.sampledAt),
                        y: .value("Used", point.utilizationPercent)
                    )
                    .foregroundStyle(.blue.opacity(0.25))
                    LineMark(
                        x: .value("Sampled", point.sampledAt),
                        y: .value("Used", point.utilizationPercent)
                    )
                    .foregroundStyle(.blue)
                }
                // Pinned to 0–100 so a subnet that moved from 4.3% to 4.4%
                // does not draw as a cliff. An auto-scaled axis makes noise
                // look like a trend, which is exactly the misread this chart
                // exists to prevent.
                .chartYScale(domain: 0...100)
                .frame(height: height)
                .chartAccessibility(descriptor)

                if isFlat {
                    Text("Flat across the whole period.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var trendSummary: String {
        guard let first = points.first, let last = points.last else { return "" }
        let from = first.utilizationPercent.formatted(.number.precision(.fractionLength(1)))
        let to = last.utilizationPercent.formatted(.number.precision(.fractionLength(1)))
        return String(
            localized: "Utilisation moved from \(from)% to \(to)% over \(points.count) samples."
        )
    }
}

// MARK: - Mapping the server's shapes

extension Components.Schemas.DNSTimeseries {
    /// Total queries per bucket.
    var queries: CondensedSeries {
        TimeSeries.condense(
            points.map { Sample(t: $0.t, value: $0.queriesTotal) }, bucketSeconds: bucketSeconds)
    }

    /// SERVFAIL per bucket — the series that means something is broken rather
    /// than merely busy. NXDOMAIN is deliberately not plotted with it: a
    /// missing name is a normal answer, and a chart that treats the two the
    /// same makes an ordinary resolver look sick.
    var failures: CondensedSeries {
        TimeSeries.condense(
            points.map { Sample(t: $0.t, value: $0.servfail) }, bucketSeconds: bucketSeconds)
    }

    var totalQueries: Int { points.reduce(0) { $0 + $1.queriesTotal } }
    var totalNXDomain: Int { points.reduce(0) { $0 + $1.nxdomain } }
    var totalServfail: Int { points.reduce(0) { $0 + $1.servfail } }
}

extension Components.Schemas.DHCPTimeseries {
    var acks: CondensedSeries {
        TimeSeries.condense(points.map { Sample(t: $0.t, value: $0.ack) }, bucketSeconds: bucketSeconds)
    }

    var naks: CondensedSeries {
        TimeSeries.condense(points.map { Sample(t: $0.t, value: $0.nak) }, bucketSeconds: bucketSeconds)
    }

    var totalDiscover: Int { points.reduce(0) { $0 + $1.discover } }
    var totalAck: Int { points.reduce(0) { $0 + $1.ack } }
    var totalNak: Int { points.reduce(0) { $0 + $1.nak } }
}

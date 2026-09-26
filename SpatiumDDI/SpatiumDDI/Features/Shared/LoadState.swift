//
//  LoadState.swift
//  SpatiumDDI
//

import SwiftUI

/// Where a fetch has got to.
///
/// Failure is a first-class state rather than an empty list. Non-negotiable #4:
/// a 403 must be shown honestly, never swallowed into a blank screen — and a
/// blank list is exactly what "swallowed" looks like to an operator.
enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    /// Why it failed.
    ///
    /// A `FailureMessage` rather than a `String`, because the two kinds of
    /// failure text need opposite handling: this app's own wording must reach
    /// the string catalogue, and the control plane's must never be parsed or
    /// looked up.
    case failed(FailureMessage)

    /// Not started, or started and cancelled before it finished.
    var isIdle: Bool {
        if case .idle = self { true } else { false }
    }
}

/// Renders the four states of a fetch consistently.
struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    let emptyMessage: LocalizedStringResource
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle:
            // Not started — or started and cancelled before it finished, which
            // is the same thing from here. Either way the view is on screen
            // with nothing to show, so start a fetch.
            //
            // Without this, a cancelled task is an indefinite spinner that
            // nothing ever re-triggers: `.idle` looks exactly like `.loading`,
            // and the owning view's `.task` has already run for this instance
            // so it will not run again. A screen that spins forever is worse
            // than one that reports a failure.
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowSeparator(.hidden)
                .task { retry() }

        case .loading:
            ProgressView().frame(maxWidth: .infinity, alignment: .center).listRowSeparator(.hidden)

        case .loaded(let value):
            if let collection = value as? any Collection, collection.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "tray", description: Text(emptyMessage))
                    .listRowSeparator(.hidden)
            } else {
                content(value)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Try Again", action: retry)
            }
            .listRowSeparator(.hidden)
        }
    }
}

/// One KPI: a number and what it counts.
///
/// An unknown value renders as a dash and keeps its tile, rather than the tile
/// disappearing. A missing tile reads as "this platform has no such thing";
/// a dash reads as "this number could not be established", which is what
/// actually happened.
struct CountTile: View {
    let value: Int?
    let label: LocalizedStringResource
    let tint: Color

    private var text: String { value?.formatted() ?? "—" }

    var body: some View {
        VStack(spacing: 2) {
            Text(text)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            value.map { "\($0) \(String(localized: label))" } ?? "\(String(localized: label)) unavailable")
    }
}

/// A utilisation bar sized to the value it reports.
struct UtilisationBar: View {
    let percent: Double

    private var tint: Color {
        switch percent {
        case ..<70: .green
        case ..<90: .orange
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .tint(tint)
            Text("\(percent, format: .number.precision(.fractionLength(1)))% used")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Shown when a filter excluded everything — which is not the same answer as
/// there being nothing to show.
///
/// `LoadStateView` already renders the empty collection, so by the time this
/// appears the data exists and the filter is what hid it. Collapsing the two is
/// a real misreport on this app's subject matter: a zone with no records and a
/// type filter that excluded all of them look identical otherwise, and only one
/// of them means "this zone is empty".
struct NoMatchesView: View {
    /// What the operator typed. Empty means only a non-text filter is narrowing.
    let query: String
    let filterDescription: LocalizedStringResource

    var body: some View {
        if query.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(filterDescription)
            )
        } else {
            ContentUnavailableView.search(text: query)
        }
    }
}

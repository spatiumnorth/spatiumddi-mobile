//
//  Severity.swift
//  SpatiumDDI
//

import SwiftUI

/// Alert severity, as the control plane names it.
///
/// The server sends a bare string. Mapping it here rather than at each call site
/// keeps one answer to "what colour is a warning", and — more importantly —
/// keeps an unrecognised severity visible instead of defaulting it to something
/// calm. A severity this app has never heard of is not automatically minor.
nonisolated enum Severity: String, CaseIterable, Comparable, Sendable {
    case critical
    case warning
    case info

    init(apiValue: String) {
        self = Severity(rawValue: apiValue.lowercased()) ?? .warning
    }

    /// This app's word for the severity, not the server's raw value.
    var label: LocalizedStringResource {
        switch self {
        case .critical: "Critical"
        case .warning: "Warning"
        case .info: "Info"
        }
    }

    var tint: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    var symbol: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    /// Most severe sorts first.
    private var order: Int {
        switch self {
        case .critical: 0
        case .warning: 1
        case .info: 2
        }
    }

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.order < rhs.order }
}

/// A small filled capsule carrying a severity or status word.
///
/// The text is rendered verbatim. Most badges carry a value the control plane
/// chose — a zone type, a lease state, a driver name — and those are data, not
/// this app's wording: translating them would misreport what the server said,
/// and looking them up in the catalogue could substitute unrelated chrome.
/// Badges showing this app's own words use `Badge(localised:)`.
struct Badge: View {
    let text: String
    var tint: Color = .secondary

    /// This app's own wording, translated before display.
    init(localised: LocalizedStringResource, tint: Color = .secondary) {
        self.text = String(localized: localised)
        self.tint = tint
    }

    /// A value the server chose, shown exactly as it arrived.
    init(text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        // `uppercased()` without a locale uses the generic mapping, which is
        // wrong for Turkish dotted/dotless i among others.
        Text(verbatim: text.uppercased(with: .current))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// A coloured dot for a health/status word, with the word beside it.
struct StatusLabel: View {
    let status: String

    /// Mapped from the vocabularies the control plane actually uses across DNS
    /// servers, DHCP servers and platform components. Anything unrecognised is
    /// deliberately grey rather than green — an unknown state is not a good one.
    private var tint: Color {
        switch status.lowercased() {
        case "ok", "active", "healthy", "running", "up", "ready", "approved":
            .green
        case "degraded", "warning", "pending", "syncing", "paused", "maintenance":
            .orange
        case "error", "failed", "unreachable", "down", "critical", "rejected":
            .red
        default:
            .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            // The server's status vocabulary, shown as sent.
            Text(verbatim: status.capitalized(with: .current)).font(.caption)
        }
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}

/// The agent's report that the daemon it fronts is not serving.
///
/// Shown only when the platform says so (`daemon_not_serving == true`). The
/// reason is the agent's own words, shown as sent.
struct DaemonNotServingLabel: View {
    let reason: String?
    let since: Date?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("The daemon on this server is not serving.")
                if let reason, !reason.isEmpty {
                    Text(verbatim: reason).font(.caption)
                }
                if let since {
                    Text("since \(since.formatted(.relative(presentation: .named)))").font(.caption2)
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill")
        }
        .foregroundStyle(.red)
    }
}

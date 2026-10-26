//
//  TrashRestore.swift
//  SpatiumDDI
//

import Foundation
import SpatiumAPI

/// What restoring a Trash entry does, worded before it happens.
///
/// The platform restores by **deletion batch**, not by row: tapping a zone
/// brings back the zone and every record that was deleted with it, tapping a
/// scope brings back its pools and reservations too. It is also all or
/// nothing — if any row in the batch clashes with something live now (a name or
/// CIDR taken since the delete), the server refuses the whole batch with a 409
/// and restores none of it. Both facts change what the operator is agreeing to,
/// so both go in the confirmation.
///
/// The partial restore the platform offers (`skip_conflicts`) is deliberately
/// not used. The server only allows it on a flat batch of DNS records, and
/// choosing which of those to leave behind is a desk decision; the refusal
/// names each clash so the operator can resolve it there.
nonisolated enum TrashRestore {
    /// The app's own name for a trash type, or `nil` for a type this build
    /// doesn't know — which the caller shows verbatim rather than guessing at.
    static func typeLabel(_ type: String) -> String? {
        switch type {
        case "ip_space": String(localized: "IP space")
        case "ip_block": String(localized: "IP block")
        case "subnet": String(localized: "Subnet")
        case "dns_zone": String(localized: "DNS zone")
        case "dns_record": String(localized: "DNS record")
        case "dhcp_scope": String(localized: "DHCP scope")
        default: nil
        }
    }

    /// The entry as the confirmation names it: its kind, then its name.
    static func subject(type: String, name: String) -> String {
        "\(typeLabel(type) ?? type) · \(name)"
    }

    /// What the restore will do, in the order the operator needs it.
    static func consequence(type: String, batchSize: Int) -> String {
        var lines: [String] = []
        switch type {
        case "dhcp_scope":
            lines.append(
                String(
                    localized:
                        "The scope is pushed back to its DHCP servers, with its pools and reservations.")
            )
        case "dns_zone":
            lines.append(String(localized: "The zone and the records deleted with it are served again."))
        case "dns_record":
            lines.append(String(localized: "The record is published to the zone's servers again."))
        default:
            break
        }
        if batchSize > 1 {
            // Inflected, not hand-pluralised. Resolved through AttributedString
            // because a plain String would carry the markup through verbatim.
            let rows = String(AttributedString(localized: "^[\(batchSize) row](inflect: true)").characters)
            lines.append(
                String(
                    localized: "Everything deleted in the same action comes back with it — \(rows) in all.")
            )
        }
        lines.append(
            String(
                localized:
                    "If any of it clashes with something live now, such as a name or CIDR taken since, nothing is restored."
            )
        )
        return lines.joined(separator: "\n\n")
    }
}

/// The 409 a restore answers with when the batch would clash with live rows.
///
/// Its `detail` is an object — `{"message": ..., "conflicts": [...]}` — which
/// neither of `APIStatusError`'s envelopes reads, so without this the operator
/// would get the generic "that conflicts with something" and no idea *what*.
/// The conflicts are the generated `RestoreConflict`; only the envelope around
/// them is spelled out here, as `APIStatusError` does for its own envelopes.
nonisolated struct TrashRestoreRefusal: Equatable {
    /// The server's summary, verbatim.
    let message: String?
    let conflicts: [Components.Schemas.RestoreConflict]

    static func parse(_ data: Data) -> TrashRestoreRefusal? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            !envelope.detail.conflicts.isEmpty
        else { return nil }
        let message = envelope.detail.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TrashRestoreRefusal(
            message: message?.isEmpty == false ? message : nil,
            conflicts: envelope.detail.conflicts
        )
    }

    /// One clash per line, as the server described it: what, then why.
    var lines: [String] {
        conflicts.map { conflict in
            conflict.display.isEmpty ? conflict.reason : "\(conflict.display) — \(conflict.reason)"
        }
    }

    private struct Envelope: Decodable {
        struct Detail: Decodable {
            let message: String?
            let conflicts: [Components.Schemas.RestoreConflict]
        }
        let detail: Detail
    }
}

//
//  CollisionWarning.swift
//  SpatiumDDI
//

import Foundation
import SwiftUI

/// One reason the control plane wants a second look before it writes.
///
/// These arrive inside a 409 as an untyped list of heterogeneous objects — the
/// document types the body as `{}`, so nothing here is generated and nothing
/// here can rely on a fixed shape. Every field is therefore captured as text
/// and rendered as text, and a `kind` this app has never seen still says
/// something true rather than being dropped.
///
/// Dropping an unrecognised warning would be the dangerous failure: the
/// operator would be shown "confirm to continue" with nothing to confirm, and
/// `force=true` overrides *all* of them at once.
nonisolated struct CollisionWarning: Equatable, Sendable, Decodable {
    /// The server's own name for this warning. Note the two spellings: the IPAM
    /// collision checks emit `kind`, the public-facing guard emits `type`.
    let kind: String
    /// Every scalar field the object carried, stringified.
    let fields: [String: String]

    init(kind: String, fields: [String: String]) {
        self.kind = kind
        self.fields = fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode([String: JSONScalar].self)
        var fields: [String: String] = [:]
        for (key, value) in object {
            if let text = value.text { fields[key] = text }
        }
        self.kind = fields["kind"] ?? fields["type"] ?? "unknown"
        self.fields = fields
    }

    /// A field, or nothing — never the string "null" or an empty value.
    private func value(_ key: String) -> String? {
        guard let value = fields[key], !value.isEmpty else { return nil }
        return value
    }

    /// The warning as a sentence, with the server's values shown as sent.
    ///
    /// Composed from this app's wording *around* the server's data rather than
    /// from the server's prose, so it is translatable — except when the server
    /// supplied a `message`, which is prose this app did not write and must not
    /// paraphrase.
    var summary: FailureMessage {
        if let message = value("message") { return .server(message) }

        switch kind {
        case "fqdn_collision":
            guard let fqdn = value("fqdn") else { break }
            guard let existing = value("existing_ip") else {
                return .app("\(fqdn) is already in use in this zone.")
            }
            return .app("\(fqdn) already points at \(existing).")

        case "mac_collision":
            guard let mac = value("mac_address") else { break }
            let host = value("existing_hostname")
            guard let existing = value("existing_ip") else {
                return .app("\(mac) is already recorded on another address.")
            }
            return .app("\(mac) is already recorded on \(existing)\(host.map { " (\($0))" } ?? "").")

        case "ptr_collision":
            guard let name = value("ptr_name"), let existing = value("existing_value") else { break }
            return .app("The reverse record \(name) already points at \(existing).")

        case "dynamic_pool":
            guard let start = value("pool_start"), let end = value("pool_end") else {
                return .app(
                    "This address is inside a DHCP pool. The DHCP server owns that range and will keep leasing the address unless you also pin a matching static reservation."
                )
            }
            return .app(
                "This address is inside the DHCP pool \(start)–\(end). The DHCP server owns that range and will keep leasing the address unless you also pin a matching static reservation."
            )

        default:
            break
        }

        // An unrecognised kind, or a recognised one missing the fields it
        // normally carries. Naming it beats silence: `force` waives every
        // warning at once, so one the operator never saw is one they waived
        // without knowing.
        return .app("The server raised a \(kind) warning.")
    }

    /// Supporting detail, where the summary left something out.
    var context: String? {
        switch kind {
        case "fqdn_collision", "mac_collision":
            guard let subnet = value("existing_subnet") else { return nil }
            return subnet
        case "public_facing_private_ip":
            guard let zone = value("zone") else { return nil }
            return value("group").map { "\(zone) · \($0)" } ?? zone
        default:
            return nil
        }
    }

    var symbol: String {
        switch kind {
        case "dynamic_pool": "cable.connector"
        case "fqdn_collision", "ptr_collision": "globe"
        case "mac_collision": "network"
        case "public_facing_private_ip": "eye.trianglebadge.exclamationmark"
        default: "exclamationmark.triangle"
        }
    }
}

/// One JSON scalar, stringified — enough to read a warning object of unknown shape.
private nonisolated enum JSONScalar: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    /// A nested object or array. Deliberately not rendered: a warning field
    /// this app doesn't understand is better omitted than printed as debug
    /// output in front of an operator.
    case other

    var text: String? {
        switch self {
        case .string(let value): value
        case .number(let value):
            // `Int(exactly:)`, not `Int(_:)`: a whole number past Int's range
            // would trap, and this value comes straight off the wire.
            Int(exactly: value).map(String.init) ?? String(value)
        case .bool(let value): value ? "true" : "false"
        case .null, .other: nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .other
        }
    }
}

/// The warnings a 409 carried, laid out for the operator to actually read.
struct CollisionWarningList: View {
    let warnings: [CollisionWarning]

    var body: some View {
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(warning.summary)
                    if let context = warning.context {
                        Text(verbatim: context)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            } icon: {
                Image(systemName: warning.symbol)
            }
            .foregroundStyle(.orange)
        }
    }
}

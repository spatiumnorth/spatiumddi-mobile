//
//  MetadataEditing.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Fixing the label while you are looking at it.
///
/// Both sheets here edit **metadata only** — what a subnet or a zone says about
/// itself, not what it *is*. The line is drawn where the blast radius changes:
///
/// - a subnet's name, description and gateway are corrections; its CIDR is a
///   resize, which the platform itself gates behind a typed CIDR and which
///   stays desktop work;
/// - a zone's TTL, admin email and primary NS are corrections; its type, its
///   DNSSEC policy and its existence are not.
///
/// Neither `SubnetUpdate` nor `ZoneUpdate` carries a `force` field, so unlike
/// the address paths there is no soft-conflict flow to offer here: what the
/// server refuses, it refuses, and the sheet says so.

// MARK: - Subnet

/// Correcting what a subnet says about itself.
struct EditSubnetView: View {
    let session: ControlPlaneSession
    let subnet: Components.Schemas.SubnetResponse
    let onSaved: (Components.Schemas.SubnetResponse) -> Void
    let onDismiss: () -> Void

    @State private var name = ""
    @State private var notes = ""
    @State private var gateway = ""
    @State private var isConfirming = false
    @State private var isSending = false
    @State private var failure: FailureMessage?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedGateway: String { gateway.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var original: (name: String, notes: String, gateway: String) {
        (subnet.name, subnet.description, subnet.gateway ?? "")
    }

    private var hasChanges: Bool {
        trimmedName != original.name || trimmedNotes != original.notes
            || trimmedGateway != original.gateway
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Network") {
                        Text(verbatim: subnet.network).font(.body.monospaced())
                    }
                } footer: {
                    // Named as a deliberate boundary rather than left as a
                    // missing field somebody assumes is an oversight.
                    Text(
                        "The CIDR isn't editable here. Resizing a subnet moves every address in it, so it stays on the web console behind its typed-CIDR confirmation."
                    )
                }

                Section {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Label")
                }

                Section {
                    TextField("Gateway (optional)", text: $gateway)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .font(.body.monospaced())
                } footer: {
                    if clearsGateway {
                        Label(
                            "The app can't remove a gateway yet — only change it. Put it back, or remove it in the web console.",
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    } else if !trimmedGateway.isEmpty, trimmedGateway != original.gateway {
                        // The gateway is handed to clients by DHCP, so this is
                        // not a label change at all — and nothing else on the
                        // screen would tell the operator that.
                        Label(
                            "The gateway is what DHCP hands to clients in this subnet. Changing it reaches every device that renews after the push.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    } else {
                        Text("Recorded on the subnet and offered to DHCP clients as their router.")
                    }
                }

                if let failure {
                    Section("Not saved") {
                        Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Subnet")
            .navigationBarTitleDisplayMode(.inline)
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onDismiss)
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Save") { isConfirming = true }
                            .disabled(!hasChanges || clearsGateway)
                    }
                }
            }
            .alert("Save changes to \(subnet.network)?", isPresented: $isConfirming) {
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await save() } }
            } message: {
                Text(verbatim: summary)
            }
            .task {
                name = original.name
                notes = original.notes
                gateway = original.gateway
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    private var clearsGateway: Bool { FieldChange.clears(from: original.gateway, to: trimmedGateway) }

    private var summary: String {
        var lines: [String] = []
        if trimmedName != original.name {
            lines.append(FieldChange.line("Name", from: original.name, to: trimmedName))
        }
        if trimmedNotes != original.notes {
            lines.append(FieldChange.line("Description", from: original.notes, to: trimmedNotes))
        }
        if trimmedGateway != original.gateway {
            lines.append(FieldChange.line("Gateway", from: original.gateway, to: trimmedGateway))
        }
        return lines.joined(separator: "\n")
    }

    private func save() async {
        isSending = true
        failure = nil
        defer { isSending = false }
        do {
            let response = try await session.client.updateSubnetApiV1IpamSubnetsSubnetIdPut(
                path: .init(subnetId: subnet.id),
                // Only the three fields this sheet owns. `SubnetUpdate` is
                // all-optional, so the other thirty-odd — DDNS policy, DNS
                // group links, discovery settings — keep whatever they had.
                body: .json(
                    .init(
                        description: trimmedNotes,
                        gateway: trimmedGateway.isEmpty ? nil : trimmedGateway,
                        name: trimmedName
                    ))
            )
            switch response {
            case .ok(let ok):
                onSaved(try ok.body.json)
                onDismiss()
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
        }
    }
}

// MARK: - Zone

/// Correcting a zone's SOA-facing metadata.
///
/// **No description field**: `ZoneUpdate` in the pinned document has none, so
/// there is nothing to edit rather than something this app chose to leave out.
struct EditZoneView: View {
    let session: ControlPlaneSession
    let groupID: String
    let zone: Components.Schemas.ZoneResponse
    let onSaved: (Components.Schemas.ZoneResponse) -> Void
    let onDismiss: () -> Void

    @State private var ttl = ""
    @State private var adminEmail = ""
    @State private var primaryNS = ""
    @State private var isConfirming = false
    @State private var isSending = false
    @State private var failure: FailureMessage?

    private var trimmedEmail: String { adminEmail.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNS: String { primaryNS.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedTTL: Int? { TTLValue.parse(ttl) }

    private var original: (ttl: String, email: String, ns: String) {
        (String(zone.ttl), zone.adminEmail, zone.primaryNs)
    }

    private var hasChanges: Bool {
        ttl.trimmingCharacters(in: .whitespacesAndNewlines) != original.ttl
            || trimmedEmail != original.email || trimmedNS != original.ns
    }

    private var blocker: LocalizedStringResource? {
        let typed = ttl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty && parsedTTL == nil {
            return "A TTL is a whole number of seconds, from 0 to 2147483647."
        }
        // A zone cannot exist without these. Emptied, they would be omitted
        // from the update and the zone left as it was — see FieldChange.clears.
        if FieldChange.clears(from: original.ttl, to: typed) {
            return "A zone needs a default TTL."
        }
        return nil
    }

    /// Beside the Authority fields rather than with the TTL's, so the reason
    /// sits next to the field at fault.
    private var authorityProblem: LocalizedStringResource? {
        if FieldChange.clears(from: original.email, to: trimmedEmail) {
            return "A zone needs an admin email — it's the RNAME in the SOA."
        }
        if FieldChange.clears(from: original.ns, to: trimmedNS) {
            return "A zone needs a primary name server — it's the MNAME in the SOA."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Zone") {
                        Text(verbatim: zone.name).font(.body.monospaced())
                    }
                } footer: {
                    Text(
                        "The zone's name, type and DNSSEC policy aren't editable here — those are creation-time and desk decisions."
                    )
                }

                Section {
                    TextField("3600", text: $ttl)
                        .keyboardType(.numberPad)
                        .font(.body.monospaced())
                } header: {
                    Text("Default TTL")
                } footer: {
                    if let blocker {
                        Label(blocker, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else if let parsedTTL, parsedTTL != zone.ttl {
                        // A TTL change does not take effect until the old one
                        // has aged out of every resolver that cached it, which
                        // is the single most misunderstood thing about DNS.
                        Text(
                            "Records that don't set their own TTL use this. Resolvers holding the old value keep it until it expires — up to \(Duration.seconds(zone.ttl).formattedCompact) from now."
                        )
                    } else {
                        Text("Used by every record in the zone that doesn't set its own.")
                    }
                }

                Section {
                    TextField("hostmaster@example.com", text: $adminEmail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    TextField("ns1.example.com.", text: $primaryNS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Authority")
                } footer: {
                    if let authorityProblem {
                        Label(authorityProblem, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else {
                        Text(
                            "Both land in the zone's SOA record and are republished to every server in the group."
                        )
                    }
                }

                if let failure {
                    Section("Not saved") {
                        Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Zone")
            .navigationBarTitleDisplayMode(.inline)
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onDismiss)
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Save") { isConfirming = true }
                            .disabled(!hasChanges || blocker != nil || authorityProblem != nil)
                    }
                }
            }
            .alert("Save changes to \(zone.name)?", isPresented: $isConfirming) {
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await save() } }
            } message: {
                Text(verbatim: summary)
            }
            .task {
                ttl = original.ttl
                adminEmail = original.email
                primaryNS = original.ns
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    private var summary: String {
        var lines: [String] = []
        let typedTTL = ttl.trimmingCharacters(in: .whitespacesAndNewlines)
        if typedTTL != original.ttl {
            lines.append(FieldChange.line("TTL", from: original.ttl, to: typedTTL))
        }
        if trimmedEmail != original.email {
            lines.append(FieldChange.line("Admin email", from: original.email, to: trimmedEmail))
        }
        if trimmedNS != original.ns {
            lines.append(FieldChange.line("Primary NS", from: original.ns, to: trimmedNS))
        }
        lines.append(String(localized: "The SOA serial increments and the zone is pushed to its servers."))
        return lines.joined(separator: "\n")
    }

    private func save() async {
        isSending = true
        failure = nil
        defer { isSending = false }
        do {
            let response = try await session.client.updateZoneApiV1DnsGroupsGroupIdZonesZoneIdPut(
                path: .init(groupId: groupID, zoneId: zone.id),
                body: .json(
                    .init(
                        adminEmail: trimmedEmail.isEmpty ? nil : trimmedEmail,
                        primaryNs: trimmedNS.isEmpty ? nil : trimmedNS,
                        ttl: parsedTTL
                    ))
            )
            switch response {
            case .ok(let ok):
                onSaved(try ok.body.json)
                onDismiss()
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
        }
    }
}

// MARK: - Shared

/// A TTL as typed.
///
/// Extracted so the bound is testable. `2147483647` is the DNS TTL ceiling —
/// a signed 32-bit second count — and a server that rejects a larger value
/// does so with a 422 the operator has to decode, which this avoids.
nonisolated enum TTLValue {
    static func parse(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            (0...2_147_483_647).contains(value)
        else { return nil }
        return value
    }
}

/// One line of a change summary, in the form both sheets use.
nonisolated enum FieldChange {
    /// `Label: before → after`, with an absent value named rather than blank.
    ///
    /// A blank on either side of an arrow reads as a rendering bug. Saying
    /// "empty" says what is actually happening.
    static func line(_ label: String, from old: String, to new: String) -> String {
        let before = old.isEmpty ? String(localized: "empty") : old
        let after = new.isEmpty ? String(localized: "empty") : new
        return "\(label): \(before) → \(after)"
    }

    /// Whether an edit empties a field that had a value.
    ///
    /// The server clears a column on an explicit `null`, but a generated client
    /// cannot send one: the published schema collapses nullable unions (the
    /// platform's #907, so the generator keeps the property at all), and an
    /// optional left `nil` is encoded by omitting the key — which the server
    /// reads as "leave it alone". Offered anyway, the confirmation would promise
    /// "→ empty" and the save would quietly change nothing. Each sheet refuses
    /// it instead, with the reason beside the field, until the platform
    /// publishes a clearing convention a generated client can express
    /// (spatiumnorth/spatiumddi#1211).
    static func clears(from old: String, to new: String) -> Bool {
        !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

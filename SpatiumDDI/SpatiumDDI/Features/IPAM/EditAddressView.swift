//
//  EditAddressView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Correcting what an allocated address says about itself.
///
/// **The address itself cannot be changed** — `IPAddressUpdate` has no
/// `address` field, so the server will not move a row to a different IP. That
/// is the right constraint and it is the server's, not this app's: moving an
/// address is a delete and an allocate, and both deserve to be seen as such.
///
/// Everything else here can collide with something already in the estate, so
/// this carries the same soft-409 flow as allocation: a duplicate hostname, a
/// MAC recorded elsewhere or a PTR clash comes back as warnings the operator
/// reads and then waives explicitly.
struct EditAddressView: View {
    let session: ControlPlaneSession
    let address: Components.Schemas.IPAddressResponse
    let subnet: Components.Schemas.SubnetResponse
    let onSaved: (Components.Schemas.IPAddressResponse) -> Void
    let onDismiss: () -> Void

    @State private var model: EditAddressModel
    @State private var isConfirming = false

    init(
        session: ControlPlaneSession,
        address: Components.Schemas.IPAddressResponse,
        subnet: Components.Schemas.SubnetResponse,
        onSaved: @escaping (Components.Schemas.IPAddressResponse) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.session = session
        self.address = address
        self.subnet = subnet
        self.onSaved = onSaved
        self.onDismiss = onDismiss
        _model = State(initialValue: EditAddressModel(session: session, address: address))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Address") {
                        Text(verbatim: address.address).font(.body.monospaced())
                    }
                    LabeledContent("Subnet", value: subnet.network)
                } footer: {
                    Text(
                        "The address itself can't be changed here — the server doesn't move a row to a different IP. Delete it and allocate the one you want."
                    )
                }

                Section {
                    TextField("Host name", text: $model.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("MAC address (optional)", text: $model.mac)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    TextField("Description (optional)", text: $model.notes, axis: .vertical)
                        .lineLimit(1...3)
                    Picker("Status", selection: $model.status) {
                        ForEach(EditAddressModel.offeredStatuses, id: \.self) { status in
                            Text(verbatim: status.capitalized(with: .current)).tag(status)
                        }
                    }
                } header: {
                    Text("Identity")
                } footer: {
                    if let problem = model.problem {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else if model.clearsHostname {
                        // Clearing a name is a DNS change, not a cosmetic one,
                        // and nothing else on this screen would say so.
                        Label(
                            "Clearing the host name deletes the DNS record this address publishes.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    } else {
                        Text("Renaming republishes the DNS record under the new name.")
                    }
                }

                switch model.submission {
                case .confirmable(let warnings):
                    Section {
                        CollisionWarningList(warnings: warnings)
                        Button("Save Anyway", role: .destructive) {
                            Task { await save(force: true) }
                        }
                        .disabled(model.isSending)
                    } header: {
                        Text("The server wants a second look")
                    } footer: {
                        Text(
                            "Nothing has been changed. Continuing waives every warning above at once."
                        )
                    }
                case .failed(let message):
                    Section("Not saved") {
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                case .idle, .sending, .saved:
                    EmptyView()
                }
            }
            .navigationTitle("Edit Address")
            .navigationBarTitleDisplayMode(.inline)
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // A write in flight lands whether or not the sheet is
                    // still here to report it.
                    Button("Cancel", role: .cancel, action: onDismiss)
                        .disabled(model.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSending {
                        ProgressView()
                    } else {
                        Button("Save") { isConfirming = true }
                            .disabled(!model.canSave)
                    }
                }
            }
            .alert("Save changes to \(address.address)?", isPresented: $isConfirming) {
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await save(force: false) } }
            } message: {
                Text(verbatim: model.changeSummary)
            }
        }
        .interactiveDismissDisabled(model.isSending)
    }

    private func save(force: Bool) async {
        guard let saved = await model.save(force: force) else { return }
        onSaved(saved)
        onDismiss()
    }
}

// MARK: - Model

@MainActor
@Observable
final class EditAddressModel {
    enum Submission: Equatable {
        case idle
        case sending
        case confirmable([CollisionWarning])
        case failed(FailureMessage)
        case saved
    }

    /// What an operator may set by hand. `static_dhcp` is absent for the same
    /// reason it is absent from allocation: a bare IPAM row does not stop a
    /// DHCP server leasing the address, and this app cannot create the matching
    /// reservation. `orphan` is what deleting produces, not something to pick.
    static let offeredStatuses = ["allocated", "reserved", "deprecated", "available"]

    var hostname: String { didSet { withdrawWaiver() } }
    var mac: String { didSet { withdrawWaiver() } }
    var notes: String { didSet { withdrawWaiver() } }
    var status: String { didSet { withdrawWaiver() } }

    private(set) var submission: Submission = .idle

    /// "Save Anyway" waives the warnings the server raised about the values it
    /// was shown. An edit after that is a different request, so the waiver goes
    /// and the next Save asks the server again — otherwise a forced write would
    /// carry values nobody confirmed, past warnings nobody saw.
    private func withdrawWaiver() {
        if case .confirmable = submission { submission = .idle }
    }

    private let session: ControlPlaneSession
    private let address: Components.Schemas.IPAddressResponse
    private let original: (hostname: String, mac: String, notes: String, status: String)

    init(session: ControlPlaneSession, address: Components.Schemas.IPAddressResponse) {
        self.session = session
        self.address = address
        let hostname = address.hostname ?? ""
        let mac = address.macAddress ?? ""
        let notes = address.description
        // A status the server set but this app does not offer — `static_dhcp`,
        // or an integration-owned one like `dhcp` — is kept as the selection
        // rather than silently rewritten to something else on the next save.
        let status = address.status
        self.hostname = hostname
        self.mac = mac
        self.notes = notes
        self.status = status
        self.original = (hostname, mac, notes, status)
    }

    var isSending: Bool { submission == .sending }

    var hasChanges: Bool {
        trimmed(hostname) != original.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmed(mac) != original.mac.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmed(notes) != original.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            || status != original.status
    }

    /// Why Save is unavailable, shown beside the fields.
    var problem: LocalizedStringResource? {
        if FieldChange.clears(from: original.mac, to: trimmed(mac)) {
            return
                "The app can't clear a MAC address yet — only change it. Put it back, or clear it in the web console."
        }
        return nil
    }

    var canSave: Bool { hasChanges && problem == nil && !isSending }

    /// Whether saving would remove a name the address currently publishes.
    var clearsHostname: Bool { !original.hostname.isEmpty && trimmed(hostname).isEmpty }

    /// What will actually change, field by field — not "are you sure".
    var changeSummary: String {
        var lines: [String] = []
        if trimmed(hostname) != original.hostname {
            lines.append(field("Name", from: original.hostname, to: trimmed(hostname)))
        }
        if trimmed(mac) != original.mac {
            lines.append(field("MAC", from: original.mac, to: trimmed(mac)))
        }
        if trimmed(notes) != original.notes {
            lines.append(field("Description", from: original.notes, to: trimmed(notes)))
        }
        if status != original.status {
            lines.append(field("Status", from: original.status, to: status))
        }
        return lines.joined(separator: "\n")
    }

    private func field(_ label: String, from old: String, to new: String) -> String {
        let before = old.isEmpty ? String(localized: "empty") : old
        let after = new.isEmpty ? String(localized: "empty") : new
        return "\(label): \(before) → \(after)"
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func save(force: Bool) async -> Components.Schemas.IPAddressResponse? {
        guard !isSending else { return nil }
        submission = .sending

        let body = Components.Schemas.IPAddressUpdate(
            description: trimmed(notes),
            force: force,
            hostname: trimmed(hostname),
            // Never "": Postgres rejects an empty MACADDR. An empty field is
            // omitted, which the server reads as "unchanged" — `problem` stops
            // that being offered as a way to clear one.
            macAddress: trimmed(mac).isEmpty ? nil : trimmed(mac),
            status: status
        )

        do {
            let response = try await session.client.updateAddressApiV1IpamAddressesAddressIdPut(
                path: .init(addressId: address.id),
                body: .json(body)
            )
            switch response {
            case .ok(let ok):
                let row = try ok.body.json
                submission = .saved
                return row
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            switch await WriteFailure.classify(error, forced: force) {
            case .confirmable(let warnings): submission = .confirmable(warnings)
            case .failed(let message): submission = .failed(message)
            }
            return nil
        }
    }
}

/// Removing an allocated address.
///
/// Both the soft and the permanent path **delete the DNS record** — the
/// router's own words are "the name is being released" — so the copy says that
/// outright rather than the comfortable half of it. What the soft path does
/// keep is the IPAM row, marked `orphan`, so the address can be re-allocated.
@MainActor
@Observable
final class DeleteAddressModel: Identifiable {
    /// Presenting this through `sheet(item:)` rather than a Bool keeps the
    /// model and the sheet created together, so a sheet can never be on screen
    /// pointed at a stale row.
    let id = UUID()
    private(set) var isDeleting = false
    private(set) var failure: FailureMessage?

    private let session: ControlPlaneSession
    let address: Components.Schemas.IPAddressResponse

    init(session: ControlPlaneSession, address: Components.Schemas.IPAddressResponse) {
        self.session = session
        self.address = address
    }

    /// Named for what the operator has to type, which is the address itself.
    var subject: String { address.address }

    var consequence: LocalizedStringResource {
        "The address becomes an orphan row in this subnet and can be allocated again. Its DNS record is deleted either way — the name is released."
    }

    /// Anything on this row that makes the delete mean more than usual.
    var caution: FailureMessage? {
        // Optional in the document even though the column has a default, so a
        // server that omits it is treated as "not a lease mirror" rather than
        // trapping on the unwrap.
        if address.autoFromLease == true {
            // The server refuses this outright; saying so first saves the trip.
            return .app(
                "This row mirrors a live DHCP lease, so the server will refuse. Release the lease at the DHCP server instead."
            )
        }
        if address.staticAssignmentId != nil {
            return .app(
                "The DHCP reservation on this address is removed with it, and pushed to the DHCP server."
            )
        }
        if let fqdn = address.fqdn, !fqdn.isEmpty {
            return .server(fqdn)
        }
        return nil
    }

    /// True once the server has accepted the delete.
    func delete() async -> Bool {
        isDeleting = true
        failure = nil
        do {
            let response = try await session.client.deleteAddressApiV1IpamAddressesAddressIdDelete(
                path: .init(addressId: address.id),
                // Never `true` from a phone. Permanent removal is the option
                // with no way back, and it is not one to offer one-handed.
                query: .init(permanent: false)
            )
            switch response {
            case .noContent:
                isDeleting = false
                return true
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
            isDeleting = false
            return false
        }
    }
}

//
//  AllocateAddressView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Taking an address in a subnet, and — in the same request — naming it.
///
/// This is the first thing this app writes. It exists because a technician
/// standing in front of a machine can already *see* what is free and then has
/// to find a laptop to claim it, during which somebody else takes it.
///
/// Two things shape the whole screen:
///
/// - **The candidate is not a reservation.** `next-ip-preview` takes no lock
///   and writes nothing; the platform's own docs say two callers opening this
///   at once see the same address and the first to submit wins. So the sheet
///   says so, and losing the race is a first-class outcome with a way forward,
///   not an error to hide.
/// - **A 409 is two different answers.** A hard conflict ("already allocated")
///   is the end of it; a soft one — a duplicate hostname, a MAC seen elsewhere,
///   an address inside a DHCP pool — comes back with `requires_confirmation`
///   and may be re-sent with `force`. That second send *is* non-negotiable #6's
///   confirmation: the operator reads what the server objected to and says yes
///   to that specific thing.
struct AllocateAddressView: View {
    let session: ControlPlaneSession
    let subnet: Components.Schemas.SubnetResponse
    /// Called once something was actually created, so the list behind can refresh.
    let onCreated: (Components.Schemas.IPAddressResponse) -> Void
    let onDismiss: () -> Void

    @State private var model: AllocateAddressModel
    @State private var isConfirming = false

    init(
        session: ControlPlaneSession,
        subnet: Components.Schemas.SubnetResponse,
        onCreated: @escaping (Components.Schemas.IPAddressResponse) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.session = session
        self.subnet = subnet
        self.onCreated = onCreated
        self.onDismiss = onDismiss
        _model = State(initialValue: AllocateAddressModel(session: session, subnet: subnet))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Subnet", value: subnet.network)
                    if !subnet.name.isEmpty { LabeledContent("Name", value: subnet.name) }
                    LabeledContent("Free") {
                        // Routed through `formattedAddressCount` on both sides:
                        // an IPv6 subnet's total comes back clamped to
                        // `Int64.max`, and subtracting from it produces a free
                        // count that is arithmetically fine and factually
                        // nonsense.
                        Text(
                            "\(freeAddressCount) of \(subnet.totalIps.formattedAddressCount)"
                        )
                    }
                }

                addressSection
                identitySection
                dnsSection
                outcomeSection
            }
            .navigationTitle("Allocate Address")
            .dismissableKeyboard()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onDismiss)
                        .disabled(model.isSending)
                }
                // The primary action lives in the bar, not at the foot of the
                // form: at the foot it is the one control the keyboard covers,
                // and on a long form it is also the one you have to go looking
                // for. Nothing is sent by this tap — it opens the confirmation.
                if !model.hasCreated {
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isSending {
                            ProgressView()
                        } else {
                            Button("Save") { isConfirming = true }
                                .disabled(!model.canSubmit)
                        }
                    }
                }
            }
            // Non-negotiable #6: the confirmation names the actual thing, not
            // "are you sure". An operator half-reading this on a train should
            // still see the address and the name it is about to be given.
            //
            // An alert rather than a confirmation dialog. A dialog raised from a
            // toolbar button anchors itself to that button as a popover with a
            // tail, which lands the summary in a narrow bubble over the form —
            // wrapping the one thing the operator is supposed to read. A
            // confirmation dialog earns its place when there are several
            // choices or a destructive one among them; this is a single action
            // plus the facts about it, which is what an alert is for.
            .alert(
                "Allocate \(model.effectiveAddress ?? "")?",
                isPresented: $isConfirming
            ) {
                // Explicit, and first: without a `.cancel` button SwiftUI
                // supplies a lone "OK", so the only way out would be to agree.
                Button("Cancel", role: .cancel) {}
                Button("Allocate") { Task { await submit(force: false) } }
            } message: {
                Text(model.confirmationSummary)
            }
            .task { await model.load() }
        }
        .interactiveDismissDisabled(model.isSending)
    }

    /// Free addresses, or "very large" where the total was clamped.
    private var freeAddressCount: String {
        subnet.totalIps.isClampedCount
            ? subnet.totalIps.formattedAddressCount
            : (subnet.totalIps - subnet.allocatedIps).formatted()
    }

    // MARK: - Sections

    @ViewBuilder
    private var addressSection: some View {
        Section {
            Picker("Address", selection: $model.source) {
                Text("Next available").tag(AllocateAddressModel.Source.next)
                Text("Specific").tag(AllocateAddressModel.Source.specific)
            }
            .pickerStyle(.segmented)

            switch model.source {
            case .next:
                switch model.preview {
                case .idle, .loading:
                    HStack {
                        Text("Finding a free address…").foregroundStyle(.secondary)
                        Spacer()
                        ProgressView()
                    }
                case .loaded(let candidate):
                    if let candidate {
                        LabeledContent("Candidate") {
                            Text(verbatim: candidate).font(.body.monospaced())
                        }
                        Button("Check for a newer candidate") { Task { await model.refreshPreview() } }
                            .font(.footnote)
                    } else {
                        // `address: null` means the subnet is exhausted, or the
                        // server declined to guess for this address family.
                        // Either way there is nothing to take here.
                        Label(
                            "The server didn't offer a free address in this subnet. Enter one specifically, or pick another subnet.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button("Try Again") { Task { await model.refreshPreview() } }
                        .font(.footnote)
                }

            case .specific:
                TextField("10.0.1.42", text: $model.typedAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .font(.body.monospaced())
            }
        } header: {
            Text("Address")
        } footer: {
            if model.source == .next {
                // Said plainly rather than discovered at 409 time.
                Text(
                    "This is a candidate, not a reservation — the server takes no lock when it suggests one. If someone else claims it first, you'll be told and can take the next one."
                )
            } else {
                Text("Must be inside \(subnet.network). The server checks, and says so if it isn't.")
            }
        }
    }

    @ViewBuilder
    private var identitySection: some View {
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
                Text("Allocated").tag("allocated")
                Text("Reserved").tag("reserved")
            }
        } header: {
            Text("Identity")
        } footer: {
            // Deliberately not offering `static_dhcp`: the platform's own
            // dynamic-pool warning says a bare IPAM row — even that one — does
            // not stop a DHCP server leasing the address, because the mirror
            // only flows reservation → IPAM. Offering a status that implies a
            // reservation this app cannot create would be a promise it can't keep.
            Text(
                "Leave the host name empty to take the address without publishing a DNS record. \"Reserved\" holds an address without saying a machine is on it yet."
            )
        }
    }

    @ViewBuilder
    private var dnsSection: some View {
        Section {
            Picker("Zone", selection: $model.zoneID) {
                Text("This subnet's own zone").tag(String?.none)
                ForEach(model.zones, id: \.id) { zone in
                    Text(verbatim: zone.name).tag(String?.some(zone.id))
                }
            }
            if let fqdn = model.fqdnPreview {
                LabeledContent("Will create") {
                    Text(verbatim: fqdn).font(.footnote.monospaced())
                }
            }
        } header: {
            Text("DNS")
        } footer: {
            if model.hostname.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No DNS record is created without a host name.")
            } else if model.zoneID == nil {
                // The server walks space → block → subnet to resolve this. The
                // app deliberately doesn't reimplement that walk — a
                // client-side copy of an inheritance rule is a copy that drifts
                // — so it says who decides rather than guessing the answer.
                Text(
                    "The server publishes into whichever zone this subnet is configured for, following the space → block → subnet inheritance. Pick one above to override it."
                )
            } else {
                Text("A forward record is created in this zone, and a reverse record if one is configured.")
            }
        }
    }

    @ViewBuilder
    private var outcomeSection: some View {
        switch model.submission {
        case .idle, .sending:
            EmptyView()

        case .confirmable(let warnings):
            Section {
                CollisionWarningList(warnings: warnings)
                Button("Allocate Anyway", role: .destructive) {
                    Task { await submit(force: true) }
                }
                .disabled(model.isSending)
            } header: {
                Text("The server wants a second look")
            } footer: {
                Text(
                    "Nothing has been written. Continuing waives every warning above at once — read them all before you do."
                )
            }

        case .failed(let message):
            Section("Not allocated") {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }

        case .created:
            // The sheet dismisses on success, so this state is only ever on
            // screen for the frame that starts the dismissal.
            EmptyView()
        }
    }

    private func submit(force: Bool) async {
        guard let created = await model.submit(force: force) else { return }
        // Straight back to the subnet, which refetches and shows the new row
        // with the fields only the server can fill in — the FQDN it published,
        // the vendor, the pool membership. Holding the sheet open on a success
        // banner would mean reading a worse copy of what is behind it.
        onCreated(created)
        onDismiss()
    }
}

// MARK: - Model

@MainActor
@Observable
final class AllocateAddressModel {
    enum Source: Hashable { case next, specific }

    enum Submission: Equatable {
        case idle
        case sending
        /// A soft 409. Re-sendable with `force`, once the operator has read it.
        case confirmable([CollisionWarning])
        case failed(FailureMessage)
        case created(Components.Schemas.IPAddressResponse)

        static func == (lhs: Submission, rhs: Submission) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.sending, .sending): true
            case (.confirmable(let l), .confirmable(let r)): l == r
            case (.failed(let l), .failed(let r)): l == r
            case (.created(let l), .created(let r)): l.id == r.id
            default: false
            }
        }
    }

    var source: Source = .next { didSet { withdrawWaiver() } }
    var typedAddress = "" { didSet { withdrawWaiver() } }
    var hostname = "" { didSet { withdrawWaiver() } }
    var mac = "" { didSet { withdrawWaiver() } }
    var notes = "" { didSet { withdrawWaiver() } }
    var status = "allocated" { didSet { withdrawWaiver() } }
    /// `nil` means "whatever this subnet is configured for" — the server resolves it.
    var zoneID: String? { didSet { withdrawWaiver() } }

    /// A fresh candidate is a different address, so it withdraws a waiver too.
    private(set) var preview: LoadState<String?> = .idle { didSet { withdrawWaiver() } }
    private(set) var zones: [Components.Schemas.ZoneResponse] = []
    private(set) var submission: Submission = .idle

    /// "Allocate Anyway" waives the warnings the server raised about the values
    /// it was shown. Any edit after that — or a newer candidate address — is a
    /// different request, so the waiver goes and the next tap asks the server
    /// again. Otherwise a forced write would carry values nobody confirmed.
    private func withdrawWaiver() {
        if case .confirmable = submission { submission = .idle }
    }

    private let session: ControlPlaneSession
    private let subnet: Components.Schemas.SubnetResponse

    init(session: ControlPlaneSession, subnet: Components.Schemas.SubnetResponse) {
        self.session = session
        self.subnet = subnet
        // Pre-select whatever the subnet already pins, so the picker shows the
        // answer rather than making the operator find it.
        self.zoneID = subnet.dnsZoneId
    }

    var isSending: Bool { submission == .sending }

    /// Whether this sheet has already written something.
    ///
    /// Once it has, the form closes rather than staying live: the fields still
    /// hold the values that were just used, and leaving Allocate enabled would
    /// make a second tap create a second address that nobody asked for.
    var hasCreated: Bool {
        if case .created = submission { return true }
        return false
    }

    /// The address that would actually be sent.
    var effectiveAddress: String? {
        switch source {
        case .next:
            guard case .loaded(let candidate) = preview else { return nil }
            return candidate
        case .specific:
            let trimmed = typedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    var canSubmit: Bool { effectiveAddress != nil && !isSending && !hasCreated }

    /// The FQDN this would publish, when the zone is known here.
    ///
    /// `nil` while the zone is left to the server: printing a guess would be
    /// worse than printing nothing, because the operator would check it.
    var fqdnPreview: String? {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let zoneID, let zone = zones.first(where: { $0.id == zoneID })
        else { return nil }
        return "\(host).\(zone.name.hasSuffix(".") ? String(zone.name.dropLast()) : zone.name)"
    }

    /// What the confirmation dialog states, as facts rather than a question.
    var confirmationSummary: String {
        var lines = [String(localized: "In \(subnet.network)")]
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fqdn = fqdnPreview {
            lines.append(String(localized: "DNS: \(fqdn)"))
        } else if !host.isEmpty {
            lines.append(String(localized: "Named \(host), in this subnet's configured zone"))
        } else {
            lines.append(String(localized: "No host name, so no DNS record"))
        }
        let trimmedMAC = mac.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMAC.isEmpty { lines.append(String(localized: "MAC \(trimmedMAC)")) }
        lines.append(String(localized: "Status: \(status)"))
        return lines.joined(separator: "\n")
    }

    // MARK: - Loading

    func load() async {
        guard case .idle = preview else { return }
        async let candidate: Void = refreshPreview()
        async let zoneList: Void = loadZones()
        _ = await (candidate, zoneList)
    }

    func refreshPreview() async {
        preview = .loading
        preview = await LoadState.fetching {
            let response = try await session.client
                .previewNextIpApiV1IpamSubnetsSubnetIdNextIpPreviewGet(
                    path: .init(subnetId: subnet.id),
                    query: .init(strategy: self.strategy, macAddress: self.eui64MAC)
                )
            switch response {
            case .ok(let ok):
                // `address` is nullable and null is meaningful: the subnet is
                // full, or the server won't guess for this family.
                return try ok.body.json.address
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    /// Only meaningful for IPv6, where the subnet carries its own policy.
    ///
    /// Left unset for IPv4 so the server applies its own default rather than
    /// this app pinning a strategy the subnet didn't ask for.
    private var strategy: String? {
        guard subnet.network.contains(":") else { return nil }
        return subnet.ipv6AllocationPolicy
    }

    /// Consulted by the server only for `strategy=eui64`.
    private var eui64MAC: String? {
        guard strategy == "eui64" else { return nil }
        let trimmed = mac.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The forward zones this subnet could publish into.
    ///
    /// Best-effort: a failure here costs the picker, not the allocation, since
    /// leaving the zone to the server is both the default and the correct
    /// answer in most estates.
    private func loadZones() async {
        var found: [Components.Schemas.ZoneResponse] = []
        for groupID in subnet.dnsGroupIds ?? [] {
            guard
                let response = try? await session.client
                    .listZonesApiV1DnsGroupsGroupIdZonesGet(path: .init(groupId: groupID)),
                case .ok(let ok) = response,
                let zones = try? ok.body.json
            else { continue }
            // Reverse zones are published to automatically alongside the
            // forward record; picking one as the *primary* zone would be wrong.
            found.append(contentsOf: zones.filter { $0.kind == "forward" })
        }
        zones = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // A pinned zone the picker can't show would silently reset the
        // selection to "automatic" and change what gets written.
        if let zoneID, !zones.contains(where: { $0.id == zoneID }) { self.zoneID = nil }
    }

    // MARK: - Writing

    /// Sends the create. Returns the created row, or `nil` if nothing was written.
    func submit(force: Bool) async -> Components.Schemas.IPAddressResponse? {
        guard !isSending else { return nil }
        guard let address = effectiveAddress else { return nil }
        submission = .sending

        let body = Components.Schemas.IPAddressCreate(
            address: address,
            description: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            dnsZoneId: zoneID,
            force: force,
            hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines),
            macAddress: trimmedMAC,
            status: status
        )

        do {
            let response = try await session.client
                .createAddressApiV1IpamSubnetsSubnetIdAddressesPost(
                    path: .init(subnetId: subnet.id),
                    body: .json(body)
                )
            switch response {
            case .created(let created):
                let row = try created.body.json
                submission = .created(row)
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

    private var trimmedMAC: String? {
        let trimmed = mac.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

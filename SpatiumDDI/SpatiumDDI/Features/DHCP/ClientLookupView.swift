//
//  ClientLookupView.swift
//  SpatiumDDI
//

import Darwin
import SpatiumAPI
import SwiftUI

/// "Why isn't this machine getting an address?"
///
/// The screen for a technician stood next to the machine in question. One field,
/// a MAC, an IP, a hostname or a DHCPv6 DUID, and the answer to the three questions that
/// follow: did it ever get a lease, what did it get, and has that lapsed.
///
/// Every other DHCP screen here starts from the server and works down. This one
/// starts from the client, because that is the thing the person in front of you
/// is holding.
struct ClientLookupView: View {
    let session: ControlPlaneSession

    /// A lease-history row with the name of the server it came from — the row
    /// itself only carries an id.
    struct Result: Identifiable {
        let row: Components.Schemas.LeaseHistoryRow
        let serverName: String?
        var id: String { row.id }
    }

    /// One lookup's answer: history, what is held right now, and how much of
    /// the history there was, so a capped page says it is one.
    struct Answer {
        let history: [Result]
        let historyTotal: Int
        let active: [Components.Schemas.LeaseResponse]
        /// The history couldn't be asked at all: it filters on MAC, IP or
        /// hostname, and a DUID is none of those. An empty history here means
        /// "not searchable", not "never seen".
        var historyUnsearchable = false
    }

    @State private var query = ""
    @State private var state: LoadState<Answer> = .idle
    @State private var searched = ""
    /// Where the SNMP poller has seen this MAC. Built lazily so the screen
    /// works unchanged on a control plane without the device module.
    @State private var sightings: NetworkSightingModel?

    var body: some View {
        List {
            Section {
                TextField("IP, hostname, MAC or DUID", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                Button {
                    Task { await search() }
                } label: {
                    HStack {
                        Label("Look Up", systemImage: "magnifyingglass")
                        Spacer()
                        if case .loading = state { ProgressView() }
                    }
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Client")
            } footer: {
                // Says what the match actually is, so nobody reads a blank
                // result as "this machine has never been on the network".
                Text(
                    "Searches lease history across every DHCP server you can read. A MAC or DUID can be entered with or without colons."
                )
            }

            if case .loaded(let answer) = state, !answer.active.isEmpty {
                Section("Holding an address now") {
                    ForEach(answer.active, id: \.id) { lease in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(lease.ipAddress).font(.body.monospaced())
                                Spacer()
                                Badge(text: lease.state, tint: .green)
                            }
                            LeaseClientText(mac: lease.macAddress, duid: lease.duid)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let hostname = lease.hostname, !hostname.isEmpty {
                                Text(hostname).font(.caption).foregroundStyle(.secondary)
                            }
                            if let expires = lease.expiresAt {
                                Text("expires \(expires.formatted(.relative(presentation: .named)))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            if let sightings {
                NetworkSightingSection(model: sightings)
            }

            if let canonical = ClientIdentifier.canonicalMAC(searched) {
                Section {
                    NavigationLink {
                        DHCPActivityView(session: session, initialMAC: canonical)
                    } label: {
                        Label("See this MAC in the server log", systemImage: "doc.text.magnifyingglass")
                    }
                } footer: {
                    // Deliberately not promised as "the DORA exchange". The
                    // agent pins Kea's logger to INFO, and DHCP4_PACKET_RECEIVED
                    // / _SEND are DEBUG — so what is actually recorded is the
                    // outcome (allocation, decline, NAK), not every packet.
                    Text(
                        "What the server recorded for this MAC — allocations, declines and NAKs. Kea servers only, and the log keeps 24 hours."
                    )
                }
            }

            if case .loaded(let answer) = state, answer.historyUnsearchable {
                Section {
                    Label(
                        answer.active.isEmpty
                            ? "No DHCP server holds a lease for this DUID right now. Lease history can't be searched by DUID, so a client that has since left won't show here — search its IPv6 address or hostname instead."
                            : "Lease history can't be searched by DUID. Search the address above to see who else has held it.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Lease history")
                }
            } else if !searched.isEmpty {
                Section {
                    LoadStateView(
                        state: historyState,
                        emptyMessage:
                            "No lease has ever been recorded for \"\(searched)\" on any DHCP server. Either it has never asked, or it is asking a server this platform doesn't manage.",
                        retry: { Task { await search() } }
                    ) { results in
                        ForEach(results) { result in
                            LeaseHistoryRow(result: result)
                        }
                    }
                } header: {
                    Text("Lease history")
                } footer: {
                    if case .loaded(let answer) = state, !answer.history.isEmpty {
                        if answer.historyTotal > answer.history.count {
                            Text(
                                "Most recent first. Showing \(answer.history.count) of \(answer.historyTotal) records — narrow the search to see older ones."
                            )
                        } else {
                            Text("Most recent first. ^[\(answer.history.count) record](inflect: true).")
                        }
                    }
                }
            }
        }
        .navigationTitle("Client Lookup")
        .dismissableKeyboard()
        .task(id: ObjectIdentifier(session)) {
            if sightings == nil { sightings = NetworkSightingModel(session: session) }
        }
    }

    /// The history rows as their own `LoadState`, so `LoadStateView` can tell
    /// "loaded and empty" from "loaded".
    private var historyState: LoadState<[Result]> {
        switch state {
        case .idle: .idle
        case .loading: .loading
        case .loaded(let answer): .loaded(answer.history)
        case .failed(let message): .failed(message)
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searched = trimmed
        state = .loading

        // Runs alongside the DHCP lookup rather than after it: the two answer
        // different halves of the same question — what the estate *thinks*
        // this client is, and where it physically is — and waiting for one to
        // show the other would make the slower one the whole wait.
        if let canonical = ClientIdentifier.canonicalMAC(trimmed) {
            let model = sightings ?? NetworkSightingModel(session: session)
            sightings = model
            Task { await model.search(mac: canonical) }
        } else {
            sightings?.clear()
        }

        let mac = ClientIdentifier.canonicalMAC(trimmed)
        let ip = ClientIdentifier.isIPv4Like(trimmed) || ClientIdentifier.isIPv6Like(trimmed) ? trimmed : nil
        let duid = (mac == nil && ip == nil) ? ClientIdentifier.canonicalDUID(trimmed) : nil

        state = await LoadState.fetching { [session] in
            // Fleet-wide, one call each (spatiumddi#917). This used to be one
            // call per DHCP server and a merge here, which swallowed each
            // server's failure: a server this account cannot read looked
            // exactly like one with no history. Now a refusal is the answer
            // the operator sees, not an absence.
            //
            // A DUID skips the history call: sent as a hostname it would match
            // nothing and read as "never seen", which is a worse answer than
            // saying the history can't be asked.
            async let history: Components.Schemas.LeaseHistoryPage? =
                duid == nil ? Self.history(session, mac: mac, ip: ip, term: trimmed) : nil
            async let active = Self.active(session, mac: mac, ip: ip, term: duid ?? trimmed)
            async let names = Self.serverNames(session)
            let (page, leases, serverNames) = try await (history, active, names)
            return Answer(
                // Most recent first. A row with no start date sorts last
                // rather than to the top — an unknown time is not a recent one.
                history: (page?.items ?? [])
                    .map { Result(row: $0, serverName: serverNames[$0.serverId]) }
                    .sorted { ($0.row.startedAt ?? .distantPast) > ($1.row.startedAt ?? .distantPast) },
                historyTotal: page?.total ?? 0,
                active: leases,
                historyUnsearchable: page == nil
            )
        }
    }

    /// The history endpoint filters on exactly one of these, so the guess
    /// matters: sending a hostname as `mac` matches nothing.
    private static func history(
        _ session: ControlPlaneSession, mac: String?, ip: String?, term: String
    ) async throws -> Components.Schemas.LeaseHistoryPage {
        let response = try await session.client.listAllLeaseHistoryApiV1DhcpLeaseHistoryGet(
            query: .init(
                mac: mac,
                ip: ip,
                hostname: (mac == nil && ip == nil) ? term : nil,
                perPage: 100
            )
        )
        switch response {
        case .ok(let ok): return try ok.body.json
        case .unprocessableContent: throw APIStatusError(status: 422)
        case .undocumented(let statusCode, let payload):
            throw await APIStatusError(status: statusCode, payload: payload)
        }
    }

    /// A history row says what happened; an active lease says what is true now.
    /// Exact MAC and IP matches where the input is one — `search` is a
    /// substring, and "10.0.0.1" would also match 10.0.0.10 through .19.
    ///
    /// A DUID goes in `search`, canonicalised to the colon form the platform
    /// stores: `search` matches `duid` as a substring, so `000100…` typed off
    /// a Windows `ipconfig /all` would otherwise match nothing.
    private static func active(
        _ session: ControlPlaneSession, mac: String?, ip: String?, term: String
    ) async throws -> [Components.Schemas.LeaseResponse] {
        let response = try await session.client.listAllLeasesApiV1DhcpLeasesGet(
            query: .init(
                search: (mac == nil && ip == nil) ? term : nil,
                mac: mac,
                ip: ip,
                page: 1,
                pageSize: 50
            )
        )
        switch response {
        case .ok(let ok): return try ok.body.json.items
        case .unprocessableContent: throw APIStatusError(status: 422)
        case .undocumented(let statusCode, let payload):
            throw await APIStatusError(status: statusCode, payload: payload)
        }
    }

    /// Server names for the rows, which carry only an id.
    ///
    /// Decoration, so it is the one failure tolerated here: a row without its
    /// server's name is still the answer, and an empty map costs the caption,
    /// not the lookup.
    private static func serverNames(_ session: ControlPlaneSession) async throws -> [String: String] {
        guard case .ok(let ok) = try? await session.client.listServersApiV1DhcpServersGet(),
            let servers = try? ok.body.json
        else { return [:] }
        return Dictionary(servers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

/// How to read what the operator typed into the lookup field.
///
/// A free function rather than a member of the view: this is string parsing,
/// not view logic, and as a member it inherited the view's `@MainActor`
/// isolation — which made it untestable from a synchronous test and trapped at
/// runtime when one tried.
nonisolated enum ClientIdentifier {
    /// Twelve hex digits, however the operator chose to punctuate them.
    ///
    /// A technician reads a MAC off a label or a screen and types it the way it
    /// was written — colons, hyphens, dots, or nothing at all.
    static func isMACLike(_ text: String) -> Bool {
        let digits = text.filter(\.isHexDigit)
        let separators = text.filter { $0 == ":" || $0 == "-" || $0 == "." }
        return digits.count == 12 && digits.count + separators.count == text.count
    }

    /// A MAC in the one form the log endpoint will accept.
    ///
    /// `/logs/dhcp-activity` compares `mac_address` against a Postgres
    /// `MACADDR` column after lower-casing it — no canonicalisation of its own.
    /// Anything Postgres cannot cast raises a **500, not a 422**, so a
    /// technician typing the address off a label exactly as printed would get
    /// a server error rather than an answer. Normalising here is what makes
    /// the field forgiving.
    static func canonicalMAC(_ text: String) -> String? {
        let digits = text.filter(\.isHexDigit).lowercased()
        guard digits.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2)
            .map { offset -> String in
                let start = digits.index(digits.startIndex, offsetBy: offset)
                let end = digits.index(start, offsetBy: 2)
                return String(digits[start..<end])
            }
            .joined(separator: ":")
    }

    /// A dotted-quad, loosely — enough to choose which filter to send.
    static func isIPv4Like(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// An IPv6 address, which both lease filters take as an exact `ip`.
    ///
    /// Groups of exactly two digits are left to `canonicalDUID`: that is how a
    /// DUID is written, and nobody writes `20:01:0d:b8:…` for an address.
    static func isIPv6Like(_ text: String) -> Bool {
        guard text.contains(":"), !hasOnlyOctetGroups(text) else { return false }
        var address = in6_addr()
        return inet_pton(AF_INET6, text, &address) == 1
    }

    /// A DHCPv6 DUID in the form the platform stores: lowercase hex octets
    /// joined by colons.
    ///
    /// Mirrors the platform's `canonical_duid` — hex digits with `:`, `-` or
    /// `.` separators, a whole number of octets — with two narrowings so a
    /// lookup isn't misread. Separated input must be in two-digit groups, and
    /// bare hex must be at least ten octets, the shortest DUID a real client
    /// sends (DUID-LL over Ethernet). Otherwise `cafe` or `deadbeef` would be
    /// taken for a DUID instead of a hostname. Six octets is a MAC, and the
    /// caller checks for one first.
    static func canonicalDUID(_ text: String) -> String? {
        let lowered = text.lowercased()
        guard !lowered.isEmpty, lowered.allSatisfy({ $0.isHexDigit || ":-.".contains($0) }) else { return nil }
        let digits = lowered.filter(\.isHexDigit)
        guard digits.count.isMultiple(of: 2) else { return nil }
        let octets = digits.count / 2
        let separated = digits.count != lowered.count
        guard separated ? (hasOnlyOctetGroups(lowered) && octets > 6) : octets >= 10, octets <= 130
        else { return nil }
        return stride(from: 0, to: digits.count, by: 2)
            .map { offset -> String in
                let start = digits.index(digits.startIndex, offsetBy: offset)
                return String(digits[start..<digits.index(start, offsetBy: 2)])
            }
            .joined(separator: ":")
    }

    private static func hasOnlyOctetGroups(_ text: String) -> Bool {
        text.split(omittingEmptySubsequences: false, whereSeparator: { ":-.".contains($0) })
            .allSatisfy { $0.count == 2 }
    }
}

/// What a lease's client can be named by.
///
/// A DHCPv4 lease is keyed by MAC. A DHCPv6 lease usually has no MAC at all —
/// 2026.10.02-1 stopped promising `mac_address` for exactly that reason — and
/// is keyed by DUID instead. A DUID standing in for a MAC is always labelled as
/// one, so nobody reads it as a long MAC or types it into a MAC field.
nonisolated enum LeaseClient: Equatable, Sendable {
    case mac(String)
    case duid(String)
    /// Neither was reported. Said as such rather than shown as a blank line.
    case unknown

    init(mac: String?, duid: String?) {
        if let mac, !mac.isEmpty {
            self = .mac(mac)
        } else if let duid, !duid.isEmpty {
            self = .duid(duid)
        } else {
            self = .unknown
        }
    }

    /// The identifier as plain text, for a caption assembled from other server
    /// values. "DUID" is the protocol's own term, like "MAC", not app wording.
    var plainText: String? {
        switch self {
        case .mac(let mac): mac
        case .duid(let duid): "DUID \(duid)"
        case .unknown: nil
        }
    }

    /// Whether a filter typed into a lease list matches this client.
    func matches(_ query: String) -> Bool {
        switch self {
        case .mac(let value), .duid(let value): value.localizedCaseInsensitiveContains(query)
        case .unknown: false
        }
    }
}

/// A lease's client identifier, as a caption line. Callers set the font.
struct LeaseClientText: View {
    let client: LeaseClient

    init(mac: String?, duid: String?) {
        client = LeaseClient(mac: mac, duid: duid)
    }

    var body: some View {
        switch client {
        case .mac(let mac): Text(verbatim: mac)
        case .duid(let duid): Text("DUID \(Text(verbatim: duid))")
        case .unknown: Text("No MAC or DUID reported")
        }
    }
}

private struct LeaseHistoryRow: View {
    let result: ClientLookupView.Result

    private var row: Components.Schemas.LeaseHistoryRow { result.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.ipAddress).font(.body.monospaced())
                Spacer()
                Badge(text: row.leaseState, tint: tint(for: row.leaseState))
            }
            LeaseClientText(mac: row.macAddress, duid: row.duid)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if let hostname = row.hostname, !hostname.isEmpty {
                Text(hostname).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let serverName = result.serverName {
                    Text(verbatim: serverName)
                }
                if let started = row.startedAt {
                    Text("from \(started.formatted(date: .abbreviated, time: .shortened))")
                }
                Text("to \(row.expiredAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func tint(for state: String) -> Color {
        switch state.lowercased() {
        case "active", "current": .green
        case "expired", "released": .secondary
        case "declined", "conflict": .red
        default: .secondary
        }
    }
}

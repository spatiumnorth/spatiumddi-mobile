//
//  DNSQueryLogView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// What a resolver was asked, and what it answered — the DNS twin of the DHCP
/// log.
///
/// The question it answers is the one a technician brings to a phone: "is this
/// machine even asking, and what is it being told?" — filterable by client
/// address, by a fragment of the name, by record type and by outcome.
///
/// **Agent-shipped servers only.** BIND9 and PowerDNS tail their query log to
/// the control plane; a Windows server does not, and the endpoint answers 400
/// for one. And it is only as complete as the group's logging settings: with
/// query logging off there are no rows at all, and with response logging off
/// every outcome is "not recorded" — which the rows say rather than leaving a
/// blank that reads as success.
///
/// The endpoint is a POST because the filter travels as a body. It reads a log
/// and returns rows; it changes nothing.
struct DNSQueryLogView: View {
    let session: ControlPlaneSession
    /// Pre-selected when arriving from a server's own screen.
    var initialServerID: String?

    @State private var servers: LoadState<[DNSQueryLog.Source]> = .idle
    /// How many groups could not be listed while building the picker.
    @State private var unlistedGroups = 0
    @State private var selectedServer: String?
    @State private var nameFilter = ""
    @State private var clientFilter = ""
    @State private var qtype = ""
    @State private var rcode = ""
    @State private var state: LoadState<[Components.Schemas.DNSQueryLogRow]> = .idle
    @State private var truncated = false

    private var isFiltered: Bool {
        !nameFilter.isEmpty || !clientFilter.isEmpty || !qtype.isEmpty || !rcode.isEmpty
    }

    var body: some View {
        List {
            Section {
                LoadStateView(
                    state: servers,
                    emptyMessage:
                        "No BIND9 or PowerDNS servers are registered. This log is agent-shipped; Windows DNS records its queries elsewhere.",
                    retry: { Task { await loadServers() } }
                ) { sources in
                    Picker("Server", selection: $selectedServer) {
                        ForEach(sources) { source in
                            // Both names are server text. The group is there
                            // because two groups can each have an `ns1`.
                            Text(verbatim: "\(source.serverName) · \(source.groupName)")
                                .tag(Optional(source.id))
                        }
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                if unlistedGroups > 0 {
                    Text(
                        "^[\(unlistedGroups) DNS group](inflect: true) couldn't be listed, so its servers aren't offered here. This account may not have access to it."
                    )
                }
            }

            Section {
                TextField("Name contains (optional)", text: $nameFilter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.search)
                    .onSubmit { Task { await fetch() } }
                TextField("Client IP (optional)", text: $clientFilter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.search)
                    .onSubmit { Task { await fetch() } }
                Picker("Type", selection: $qtype) {
                    Text("Any").tag("")
                    ForEach(DNSQueryLog.recordTypes, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                Picker("Outcome", selection: $rcode) {
                    Text("Any").tag("")
                    ForEach(DNSQueryLog.responseCodes, id: \.self) { Text(verbatim: $0).tag($0) }
                    // The platform's own token for "the outcome was never
                    // written down", which is a question in itself: is
                    // response logging actually on?
                    Text("Not recorded").tag(DNSQueryLog.unrecorded)
                }
                Button {
                    Task { await fetch() }
                } label: {
                    HStack {
                        Label("Fetch Log", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        if case .loading = state { ProgressView() }
                    }
                }
                .disabled(selectedServer == nil)
            } footer: {
                Text(
                    "The name matches anywhere in the query or the raw line. The client IP must be exact. Newest first."
                )
            }

            Section {
                LoadStateView(
                    state: state,
                    emptyMessage: isFiltered
                        ? "Nothing logged matches those filters."
                        : "This server has logged no queries. Query logging may be off for its group.",
                    retry: { Task { await fetch() } }
                ) { rows in
                    ForEach(rows, id: \.id) { QueryRow(row: $0) }
                }
            } header: {
                Text("Queries")
            } footer: {
                // The server caps what it returns. Saying so matters: an
                // operator who thinks they are looking at the whole log will
                // conclude a client never asked.
                if truncated {
                    Text("The server truncated this log — narrow the filter to see further back.")
                }
            }
        }
        .navigationTitle("DNS Log")
        .dismissableKeyboard()
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if selectedServer == nil { await loadServers() } else { await fetch() }
        }
        .task {
            if case .idle = servers { await loadServers() }
        }
    }

    private func loadServers() async {
        servers = .loading
        servers = await LoadState.fetching {
            let groups: [Components.Schemas.ServerGroupResponse]
            switch try await session.client.listGroupsApiV1DnsGroupsGet() {
            case .ok(let ok): groups = try ok.body.json
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }

            // Servers are per group, so the picker costs one call per group;
            // they run concurrently. A group that fails is counted rather than
            // dropped silently, so the footer can say the list is partial.
            let perGroup = await withTaskGroup(of: Result<[DNSQueryLog.Source], any Error>.self) { tasks in
                for group in groups {
                    tasks.addTask { [session] in
                        do {
                            return .success(try await Self.sources(in: group, session: session))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                var collected: [Result<[DNSQueryLog.Source], any Error>] = []
                for await sources in tasks { collected.append(sources) }
                return collected
            }

            // Every group refused is a failure, not an empty list — reporting
            // "no servers" to someone who may not read any group would be the
            // swallowed 403 non-negotiable #4 forbids. The first refusal is the
            // one shown, with the server's own reason.
            let listed = perGroup.compactMap { try? $0.get() }
            if listed.isEmpty, case .failure(let error) = perGroup.first {
                throw error
            }
            unlistedGroups = perGroup.count - listed.count
            let list = listed.flatMap { $0 }.sorted {
                $0.serverName.localizedStandardCompare($1.serverName) == .orderedAscending
            }
            if let initialServerID, list.contains(where: { $0.id == initialServerID }) {
                selectedServer = initialServerID
            } else if selectedServer == nil {
                selectedServer = list.first?.id
            }
            return list
        }
        // Arriving from a server means the operator already asked a question;
        // answer it rather than making them tap again.
        if initialServerID != nil, selectedServer == initialServerID { await fetch() }
    }

    private nonisolated static func sources(
        in group: Components.Schemas.ServerGroupResponse, session: ControlPlaneSession
    ) async throws -> [DNSQueryLog.Source] {
        let response = try await session.client
            .listServersApiV1DnsGroupsGroupIdServersGet(path: .init(groupId: group.id))
        switch response {
        case .ok(let ok):
            return DNSQueryLog.sources(
                try ok.body.json.map { ($0.id, $0.name, $0.driver) }, in: group.name
            )
        case .unprocessableContent:
            throw APIStatusError(status: 422)
        case .undocumented(let statusCode, let payload):
            throw await APIStatusError(status: statusCode, payload: payload)
        }
    }

    private func fetch() async {
        guard let serverId = selectedServer else { return }
        let name = nameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = clientFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .loading

        // The server compares this straight against a Postgres INET column, so
        // a value Postgres cannot cast comes back as a 500. Refuse locally with
        // something readable instead.
        if !client.isEmpty, IPFamily.of(client) == .neither {
            state = .failed(
                .app("\"\(client)\" isn't an IP address. The client filter matches one address exactly."))
            return
        }

        state = await LoadState.fetching {
            let response = try await session.client.queryDnsQueriesApiV1LogsDnsQueriesPost(
                body: .json(
                    .init(
                        clientIp: client.isEmpty ? nil : client,
                        maxEvents: 300,
                        q: name.isEmpty ? nil : name,
                        qtype: qtype.isEmpty ? nil : qtype,
                        rcode: rcode.isEmpty ? nil : rcode,
                        serverId: serverId
                    )
                )
            )
            switch response {
            case .ok(let ok):
                let body = try ok.body.json
                truncated = body.truncated
                return body.events.sorted { $0.ts > $1.ts }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct QueryRow: View {
    let row: Components.Schemas.DNSQueryLogRow

    private var outcome: DNSQueryLog.Outcome {
        DNSQueryLog.Outcome(rcode: row.rcode, answerCount: row.answerCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let qtype = row.qtype, !qtype.isEmpty {
                    Badge(text: qtype, tint: .indigo)
                }
                switch outcome {
                case .recorded(let code):
                    Badge(text: code, tint: DNSQueryLog.tint(for: code))
                case .noData:
                    // NOERROR with nothing in it: the name exists, the type
                    // does not. A different fault from NXDOMAIN, and
                    // indistinguishable from success without the label.
                    Badge(localised: "NODATA", tint: .orange)
                case .unrecorded:
                    // Never a blank where NOERROR would sit — an unrecorded
                    // outcome read as "fine" is the one mistake to prevent.
                    Badge(localised: "not recorded")
                }
                Spacer()
                Text(row.ts.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let qname = row.qname, !qname.isEmpty {
                Text(verbatim: qname).font(.callout.monospaced()).lineLimit(2)
            }
            HStack(spacing: 8) {
                if let client = row.clientIp, !client.isEmpty {
                    Text(verbatim: client).font(.caption.monospaced())
                }
                if let view = row.view, !view.isEmpty {
                    Text("view \(view)").font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            // The raw line is what an operator actually trusts — every other
            // field here is the platform's parse of it.
            Text(verbatim: row.raw)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }
}

/// The pure parts of the DNS query log: which servers have one, and how an
/// answer is labelled.
nonisolated enum DNSQueryLog {
    /// One server that ships a query log, with the group it was found in.
    struct Source: Identifiable, Equatable, Sendable {
        let id: String
        let serverName: String
        let groupName: String
    }

    /// The drivers whose agent tails a query log to the control plane. Any
    /// other driver is answered with a 400, so offering it would be offering a
    /// guaranteed error.
    static let agentDrivers: Set<String> = ["bind9", "powerdns"]

    static func shipsQueryLog(driver: String) -> Bool {
        agentDrivers.contains(driver.lowercased())
    }

    static func sources(
        _ servers: [(id: String, name: String, driver: String)], in groupName: String
    ) -> [Source] {
        servers.filter { shipsQueryLog(driver: $0.driver) }
            .map { Source(id: $0.id, serverName: $0.name, groupName: groupName) }
    }

    /// The types worth a one-tap filter. The server upper-cases what it is
    /// sent, so these are protocol tokens, not words to translate.
    static let recordTypes = ["A", "AAAA", "CNAME", "MX", "TXT", "PTR", "SRV", "NS", "SOA", "HTTPS"]

    static let responseCodes = ["NOERROR", "NXDOMAIN", "SERVFAIL", "REFUSED"]

    /// What the platform matches as "no outcome was logged".
    static let unrecorded = "UNKNOWN"

    enum Outcome: Equatable {
        case recorded(String)
        case noData
        case unrecorded

        init(rcode: String?, answerCount: Int?) {
            guard let rcode, !rcode.isEmpty else {
                self = .unrecorded
                return
            }
            // Only a known zero is NODATA. A missing count says nothing about
            // whether the answer was empty.
            if rcode.uppercased() == "NOERROR", answerCount == 0 {
                self = .noData
            } else {
                self = .recorded(rcode)
            }
        }
    }

    /// NOERROR is quiet, NXDOMAIN is often legitimate (search-domain walks),
    /// and everything else — SERVFAIL, REFUSED — is the line worth scrolling to.
    static func tint(for code: String) -> Color {
        switch code.uppercased() {
        case "NOERROR": .green
        case "NXDOMAIN": .orange
        default: .red
        }
    }
}

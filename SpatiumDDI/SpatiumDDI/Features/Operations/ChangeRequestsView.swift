//
//  ChangeRequestsView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Change requests awaiting a decision.
///
/// Read-only here. Deciding one is a Phase 2 write, and the reason this screen
/// exists first is that an approver away from a desk usually needs to know
/// *what* is queued and how risky it is long before they can act — "is this
/// worth stopping for" is the question, and it has an answer without a write.
struct ChangeRequestsView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.ChangeRequestResponse]> = .idle
    @State private var stateFilter: String? = "pending"

    /// The states the control plane uses, pending first because that is the
    /// only one anyone opens this screen for.
    private static let states = ["pending", "approved", "rejected", "expired"]

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChip(label: "All", selected: stateFilter == nil) { stateFilter = nil }
                        ForEach(Self.states, id: \.self) { value in
                            FilterChip(label: value.capitalized, selected: stateFilter == value) {
                                stateFilter = stateFilter == value ? nil : value
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
            }

            Section {
                LoadStateView(
                    state: state,
                    emptyMessage: stateFilter == "pending"
                        ? "Nothing is waiting for a decision."
                        : "No change requests recorded.",
                    retry: load
                ) { requests in
                    ForEach(requests, id: \.id) { request in
                        NavigationLink {
                            ChangeRequestDetailView(
                                session: session,
                                request: request,
                                onDecided: settle
                            )
                        } label: {
                            ChangeRequestRow(request: request)
                        }
                    }
                }
            }
        }
        .navigationTitle("Change Requests")
        .refreshable { await fetch() }
        .task(id: stateFilter) { await fetch() }
    }

    private func load() { Task { await fetch() } }

    /// Folds a decided request back into the list without a round trip. A row
    /// that no longer matches the state filter leaves rather than sitting
    /// under a heading it now contradicts.
    private func settle(_ decided: Components.Schemas.ChangeRequestResponse) {
        guard case .loaded(let rows) = state else { return }
        state = .loaded(
            RowUpdate.apply(decided, to: rows, id: \.id) { row in
                guard let stateFilter else { return true }
                return row.state.caseInsensitiveCompare(stateFilter) == .orderedSame
            }
        )
    }

    private func fetch() async {
        let filter = stateFilter
        state = .loading
        let result = await LoadState.fetching {
            let response = try await session.client.listRequestsApiV1ChangeRequestsGet(
                query: .init(state: filter, limit: 100)
            )
            switch response {
            case .ok(let ok):
                // Soonest to expire first: a pending request has a deadline,
                // and the one about to lapse is the one that needs attention.
                return try ok.body.json.sorted { $0.expiresAt < $1.expiresAt }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
        // A pull-to-refresh is not cancelled when the filter changes, so it can
        // finish after the fetch for the newer filter — and would put
        // "pending" rows under "All". Only the current filter's answer lands.
        guard filter == stateFilter else { return }
        state = result
    }
}

private struct ChangeRequestRow: View {
    let request: Components.Schemas.ChangeRequestResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(request.resourceDisplay.isEmpty ? request.resourceType : request.resourceDisplay)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Badge(text: request.state, tint: StateTint.forChangeRequest(request.state))
            }
            Text(request.previewText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(request.operation)
                Text("by \(request.requestedByDisplay)")
                if request.state.lowercased() == "pending" {
                    // The deadline is the actionable part of a pending request.
                    Text("expires \(request.expiresAt.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(Expiry(request.expiresAt).tint)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// One change request, in full — and the decision it is waiting for.
struct ChangeRequestDetailView: View {
    let session: ControlPlaneSession
    /// Called with the row the server returned, so the list behind this screen
    /// stops showing a decision that has already been made.
    let onDecided: (Components.Schemas.ChangeRequestResponse) -> Void

    @Environment(Permissions.self) private var permissions
    @State private var request: Components.Schemas.ChangeRequestResponse
    @State private var model: DecisionModel

    init(
        session: ControlPlaneSession,
        request: Components.Schemas.ChangeRequestResponse,
        onDecided: @escaping (Components.Schemas.ChangeRequestResponse) -> Void = { _ in }
    ) {
        self.session = session
        self.onDecided = onDecided
        _request = State(initialValue: request)
        _model = State(initialValue: DecisionModel(session: session, request: request))
    }

    private var isRequester: Bool { permissions.isMe(request.requestedByUserId) }

    private var decideBlock: ChangeRequestRules.Block? {
        ChangeRequestRules.blocksDeciding(
            state: request.state,
            isRequester: isRequester,
            mayDecide: permissions.can("approve", on: "change_request")
        )
    }

    private var cancelBlock: ChangeRequestRules.Block? {
        ChangeRequestRules.blocksCancelling(
            state: request.state,
            isRequester: isRequester,
            isSuperadmin: permissions.isSuperadmin
        )
    }

    var body: some View {
        List {
            Section {
                LabeledContent("State") {
                    Badge(text: request.state, tint: StateTint.forChangeRequest(request.state))
                }
                LabeledContent("Operation", value: request.operation)
                LabeledContent("Resource", value: request.resourceType)
                if !request.resourceDisplay.isEmpty {
                    LabeledContent("Target", value: request.resourceDisplay)
                }
            }

            Section("What it would do") {
                Text(request.previewText)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            // The reason the platform decided this needed approving at all. It
            // is the single most useful sentence on the screen for someone
            // deciding whether to stop what they are doing.
            if !request.riskReason.isEmpty {
                Section("Why this needs approval") {
                    Label(request.riskReason, systemImage: "exclamationmark.shield")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section("Requested") {
                LabeledContent("By", value: request.requestedByDisplay)
                LabeledContent("At", value: request.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Expires") {
                    Text(request.expiresAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(Expiry(request.expiresAt).tint)
                }
            }

            if request.decidedAt != nil || request.decidedByDisplay != nil {
                Section("Decision") {
                    if let by = request.decidedByDisplay { LabeledContent("By", value: by) }
                    if let at = request.decidedAt {
                        LabeledContent("At", value: at.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let note = request.decisionNote, !note.isEmpty {
                        LabeledContent("Note", value: note)
                    }
                }
            }

            if let error = request.error, !error.isEmpty {
                Section("Execution error") {
                    Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            if decideBlock == nil {
                Section {
                    // The note is the decision's own record — it lands in the
                    // audit row and on this screen's Decision section after.
                    TextField("Note (optional)", text: $model.note, axis: .vertical)
                        .lineLimit(1...3)
                    Button {
                        model.confirm(.approve)
                    } label: {
                        Label("Approve", systemImage: "checkmark.seal")
                    }
                    .disabled(model.isSending)
                    Button(role: .destructive) {
                        model.confirm(.reject)
                    } label: {
                        Label("Reject", systemImage: "xmark.seal")
                    }
                    .disabled(model.isSending)
                } header: {
                    Text("Decide")
                } footer: {
                    // Approving does not queue anything: it runs the change.
                    Text("Approving runs the change now, as you. Rejecting declines it and changes nothing.")
                }
            } else if let block = decideBlock, ChangeRequestRules.isPending(request.state) {
                // Say why, in the place the buttons would have been. A pending
                // request with no visible action and no explanation reads as a
                // screen that forgot to finish loading.
                Section("Decide") {
                    Label {
                        Text(explanation(for: block))
                    } icon: {
                        Image(systemName: block.symbol)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            if cancelBlock == nil {
                Section {
                    Button(role: .destructive) {
                        model.confirm(.cancel)
                    } label: {
                        Label("Withdraw This Request", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.isSending)
                } footer: {
                    Text("Withdrawing takes it off the approvers' queue. Nothing is changed.")
                }
            }

            if let failure = model.failure {
                Section("Not decided") {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Change Request")
        .navigationBarTitleDisplayMode(.inline)
        .dismissableKeyboard()
        .alert(
            Text(model.pending?.confirmationTitle ?? LocalizedStringResource("Confirm")),
            isPresented: Binding(
                get: { model.pending != nil },
                set: { if !$0 { model.pending = nil } }
            ),
            presenting: model.pending
        ) { decision in
            Button("Cancel", role: .cancel) { model.pending = nil }
            Button(role: decision == .approve ? nil : .destructive) {
                Task { await decide(decision) }
            } label: {
                Text(decision.confirmationVerb)
            }
        } message: { decision in
            // Names the actual change, not "are you sure" — for approve that
            // is the preview text, because approving is what executes it.
            Text(verbatim: decision.consequence(preview: request.previewText))
        }
        .overlay {
            if model.isSending {
                ProgressView().controlSize(.large)
            }
        }
    }

    private func decide(_ decision: DecisionModel.Decision) async {
        guard let decided = await model.send(decision) else { return }
        request = decided
        onDecided(decided)
    }

    /// The refusal, in the operator's terms rather than the grammar's.
    private func explanation(for block: ChangeRequestRules.Block) -> LocalizedStringResource {
        switch block {
        case .ownRequest:
            "This is your own request. The platform needs a second person to approve it — you can withdraw it instead."
        case .noGrant:
            "Deciding change requests needs the approve permission on this control plane."
        case .notYours:
            "Only the person who raised this request can withdraw it."
        case .settled(let state):
            "This request is \(state). There is nothing left to decide."
        }
    }
}

extension ChangeRequestRules.Block {
    /// A glyph for the refusal, so the row reads as an explanation rather than
    /// an error.
    var symbol: String {
        switch self {
        case .ownRequest: "person.crop.circle.badge.exclamationmark"
        case .noGrant: "lock"
        case .notYours: "person.2.slash"
        case .settled: "checkmark.circle"
        }
    }
}

/// Sending one decision, and what came back if it wasn't taken.
@MainActor
@Observable
final class DecisionModel {
    enum Decision: Identifiable, Equatable {
        case approve
        case reject
        case cancel

        var id: Self { self }

        var confirmationTitle: LocalizedStringResource {
            switch self {
            case .approve: "Approve and run this change?"
            case .reject: "Reject this request?"
            case .cancel: "Withdraw this request?"
            }
        }

        var confirmationVerb: LocalizedStringResource {
            switch self {
            case .approve: "Approve"
            case .reject: "Reject"
            case .cancel: "Withdraw"
            }
        }

        /// What happens, stated as fact.
        func consequence(preview: String) -> String {
            switch self {
            case .approve:
                // The server's own words for the change, verbatim.
                String(localized: "This runs now, under your account:") + "\n\n" + preview
            case .reject:
                String(localized: "The request is declined and nothing is changed. The requester is told.")
            case .cancel:
                String(localized: "The request comes off the approvers' queue. Nothing is changed.")
            }
        }
    }

    var note = ""
    var pending: Decision?
    private(set) var isSending = false
    private(set) var failure: FailureMessage?

    private let session: ControlPlaneSession
    private let request: Components.Schemas.ChangeRequestResponse

    init(session: ControlPlaneSession, request: Components.Schemas.ChangeRequestResponse) {
        self.session = session
        self.request = request
    }

    func confirm(_ decision: Decision) {
        failure = nil
        pending = decision
    }

    /// Sends the decision. Returns the row the server settled on, or nil.
    func send(_ decision: Decision) async -> Components.Schemas.ChangeRequestResponse? {
        pending = nil
        isSending = true
        failure = nil
        defer { isSending = false }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Components.Schemas.DecisionBody(decisionNote: trimmed.isEmpty ? nil : trimmed)

        do {
            // Three near-identical switches rather than one shared handler:
            // each route generates its own Output enum, and the cases only
            // look alike — they are unrelated types.
            switch decision {
            case .approve:
                switch try await session.client.approveRequestApiV1ChangeRequestsCrIdApprovePost(
                    path: .init(crId: request.id), body: .json(body)
                ) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            case .reject:
                switch try await session.client.rejectRequestApiV1ChangeRequestsCrIdRejectPost(
                    path: .init(crId: request.id), body: .json(body)
                ) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            case .cancel:
                switch try await session.client.cancelRequestApiV1ChangeRequestsCrIdCancelPost(
                    path: .init(crId: request.id), body: .json(body)
                ) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        } catch {
            // A decision has no soft-conflict path: a 409 here is a lost race
            // or a lapsed request, and both are final for this row. `forced`
            // says so, so nothing offers to re-send it.
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
            return nil
        }
    }
}

/// Who may decide a change request, and why not when they may not.
///
/// Every rule here is the server's, restated so the app can say *before* the
/// tap what the server would say after it. They are worth restating precisely
/// because the refusals are not obvious: an approver with every write grant in
/// the estate still cannot approve their **own** request, and finding that out
/// as a 409 — after reading the whole case and deciding — is a bad moment.
///
/// Pure and separate from the view for the same reason `DeleteConfirmation` is:
/// a rule only exercised by tapping through a screen is one nobody exercises.
nonisolated enum ChangeRequestRules {
    /// Why a decision is not on offer.
    enum Block: Equatable {
        /// Already decided, or lapsed. Carries the state, as the server spells it.
        case settled(String)
        /// The platform refuses a self-decision: approving your own request
        /// defeats the two-person rule, and rejecting it is just cancelling.
        case ownRequest
        /// No `{approve, change_request}` grant.
        case noGrant
        /// Cancelling is the requester's own move (or a superadmin's).
        case notYours
    }

    /// A request is only open to anything while it is pending.
    static func isPending(_ state: String) -> Bool {
        state.caseInsensitiveCompare("pending") == .orderedSame
    }

    /// Why Approve and Reject are not offered, or `nil` when they are.
    ///
    /// Ordered by what the operator can do something about: being the
    /// requester is permanent for this row, a missing grant needs someone
    /// else, and a settled row needs nothing at all.
    static func blocksDeciding(
        state: String, isRequester: Bool, mayDecide: Bool
    ) -> Block? {
        if !isPending(state) { return .settled(state) }
        if isRequester { return .ownRequest }
        if !mayDecide { return .noGrant }
        return nil
    }

    /// Why Cancel is not offered, or `nil` when it is.
    static func blocksCancelling(
        state: String, isRequester: Bool, isSuperadmin: Bool
    ) -> Block? {
        if !isPending(state) { return .settled(state) }
        if !isRequester && !isSuperadmin { return .notYours }
        return nil
    }
}

/// Shared colouring for the state words this platform uses.
nonisolated enum StateTint {
    static func forChangeRequest(_ state: String) -> Color {
        switch state.lowercased() {
        case "pending": .orange
        case "approved", "executed", "applied": .green
        case "rejected", "failed": .red
        case "expired": .secondary
        default: .secondary
        }
    }
}

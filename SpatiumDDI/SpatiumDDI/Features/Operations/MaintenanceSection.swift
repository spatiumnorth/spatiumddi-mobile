//
//  MaintenanceSection.swift
//  SpatiumDDI
//

import HTTPTypes
import OpenAPIRuntime
import SpatiumAPI
import SwiftUI

/// The change window, as a state the operator can open and close.
///
/// The app has always *honoured* maintenance mode — non-negotiable #5 — by
/// surfacing the banner and refusing to retry into a 503. What it could not do
/// was start or end the window, and the person most likely to need that is
/// standing in a machine room at the top of a change with their laptop still
/// in a bag.
///
/// Two things about the platform's behaviour are worth stating here because
/// both were verified against a live control plane rather than assumed:
///
/// - `PUT /api/v1/settings` is a **partial** update. Sending the two
///   maintenance fields leaves the other 127 settings exactly as they were, so
///   this screen cannot quietly reset a DNS default it never displayed.
/// - The settings path is **not** itself refused during a window, so lifting
///   maintenance mode from inside maintenance mode works. Without that the
///   feature would be a trap: an operator could close the estate from a phone
///   and then need a laptop to reopen it.
///
/// The state is **read from `/health/platform`**, not from `/settings`. The
/// health rollup carries the same three fields under a shape that has not
/// changed since maintenance mode shipped. `SettingsResponse` is the whole of
/// the platform's configuration, and it changes often: the 1.0.0 betas removed
/// two webhook fields this client's pin still lists as required. Against such a
/// server, every settings response failed to decode, even after the write had
/// landed.
nonisolated struct MaintenanceState: Equatable, Sendable {
    var isOn: Bool
    /// The operator's own words. Never localised, never parsed.
    var message: String
    /// When the window opened. Server-managed — set on enable, cleared on
    /// disable — so the app reports it and never sends it.
    var startedAt: Date?

    init(isOn: Bool = false, message: String = "", startedAt: Date? = nil) {
        self.isOn = isOn
        self.message = message
        self.startedAt = startedAt
    }

    /// The mapping from what the server sends, which is three independent
    /// optionals rather than one state.
    ///
    /// The whole of the logic is here, and two of its three rules are easy to
    /// get backwards:
    ///
    /// - **absent means off.** A control plane that has never had a change
    ///   window omits the flag, and reading that as "unknown" would leave the
    ///   section with no state to draw.
    /// - **a message with the flag off is still off.** The platform keeps the
    ///   last message after a window is lifted, deliberately — the next window
    ///   is usually about the same thing — so the message is not the signal.
    init(enabled: Bool?, message: String?, startedAt: Date?) {
        self.isOn = enabled ?? false
        self.message = message ?? ""
        self.startedAt = startedAt
    }

    init(_ health: PlatformHealth) {
        self.init(
            enabled: health.maintenanceMode,
            message: health.maintenanceMessage,
            startedAt: health.maintenanceStartedAt
        )
    }
}

/// Maintenance mode on the Server screen.
struct MaintenanceSection: View {
    let session: ControlPlaneSession
    /// The control plane's name, for copy that has to say *which* estate this
    /// closes. "Every user sees this" is only reassuring if it names whose.
    let serverName: String

    @Environment(Permissions.self) private var permissions

    @State private var state: LoadState<MaintenanceState> = .idle
    @State private var isEditing = false
    /// Set when the operator asks to lift the window; the alert reads from it.
    @State private var isConfirmingLift = false
    @State private var isWriting = false
    @State private var failure: FailureMessage?

    /// `settings` is the grammar's own name for the platform settings
    /// resource; `appliance` carries maintenance mode for an Appliance
    /// Operator, who is exactly the role that opens change windows. Listing
    /// both widens the gate rather than narrowing it, which is the correct
    /// direction to err when the server enforces independently anyway.
    private var mayChange: Bool { permissions.canWrite("settings", "appliance") }

    var body: some View {
        Section {
            LoadStateView(
                state: state,
                emptyMessage: "The server didn't report its maintenance state.",
                retry: { Task { await fetch() } }
            ) { maintenance in
                if maintenance.isOn {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The estate is in a change window.")
                                .font(.subheadline.weight(.semibold))
                            if let startedAt = maintenance.startedAt {
                                Text("since \(startedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                            }
                        }
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver.fill")
                    }
                    .foregroundStyle(.orange)

                    if !maintenance.message.isEmpty {
                        // The operator's text, shown as sent. Never Markdown,
                        // never looked up in this app's catalogue.
                        Text(verbatim: maintenance.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Writes are open. No change window is running.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }

                if mayChange {
                    if isWriting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Saving…").foregroundStyle(.secondary)
                        }
                    } else if maintenance.isOn {
                        Button("Lift Maintenance Mode") {
                            failure = nil
                            isConfirmingLift = true
                        }
                        Button("Change the Message") {
                            failure = nil
                            isEditing = true
                        }
                    } else {
                        Button("Start a Change Window") {
                            failure = nil
                            isEditing = true
                        }
                    }
                }

                if let failure {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Maintenance")
        } footer: {
            if case .loaded = state, !mayChange {
                Text("Changing the maintenance window needs write access to platform settings.")
            } else {
                Text(
                    "A change window shows every user a banner and makes the server refuse changes. It can be lifted from here too — the settings path stays open while the window is running."
                )
            }
        }
        .task { if case .idle = state { await fetch() } }
        .sheet(isPresented: $isEditing) {
            MaintenanceSheet(
                serverName: serverName,
                current: currentState,
                onSave: { message in
                    isEditing = false
                    Task { await write(isOn: true, message: message) }
                },
                onCancel: { isEditing = false }
            )
        }
        .alert("Lift maintenance mode?", isPresented: $isConfirmingLift) {
            Button("Cancel", role: .cancel) {}
            Button("Lift It") { Task { await write(isOn: false, message: nil) } }
        } message: {
            Text(
                "Writes reopen on \(serverName) immediately and the banner disappears for everyone using it."
            )
        }
    }

    private var currentState: MaintenanceState {
        if case .loaded(let maintenance) = state { return maintenance }
        return MaintenanceState()
    }

    /// Writes only the fields this screen owns, then asks the server what
    /// actually happened.
    ///
    /// `message` is `nil` when lifting: the platform keeps the last message on
    /// disable, and clearing it would throw away wording the operator will
    /// most likely want again at the next window.
    ///
    /// The settings echo is not trusted for the outcome. A 2xx whose body this
    /// client cannot decode means the window **did** change, and reporting
    /// that as a failure is the worst wrong answer this screen can give: the
    /// operator retries, or walks away believing writes are still open. So
    /// anything that reached the server with a 2xx is followed by a fresh
    /// read of the health rollup, and that read is what the screen shows.
    private func write(isOn: Bool, message: String?) async {
        isWriting = true
        failure = nil
        defer { isWriting = false }

        do {
            let response = try await session.client.updateSettingsApiV1SettingsPut(
                body: .json(.init(maintenanceMessage: message, maintenanceModeEnabled: isOn))
            )
            switch response {
            case .ok:
                break
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            // A landed write falls through to the re-read. Nothing here is
            // soft-conflictable, so a failure is never offered as re-sendable
            // with force.
            guard Self.landed(error) else {
                if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                    failure = message
                }
                return
            }
        }

        await fetch()
        if case .loaded(let maintenance) = state, maintenance.isOn != isOn {
            failure =
                isOn
                ? .app("The server accepted the change but still reports writes open.")
                : .app("The server accepted the change but still reports a change window.")
        }
    }

    /// Whether a thrown error is a 2xx the generated client failed to decode.
    ///
    /// The deserialiser runs inside the call, so a body that doesn't match the
    /// pinned schema throws a `ClientError` that still holds the response.
    nonisolated static func landed(_ error: any Error) -> Bool {
        guard let clientError = error as? ClientError,
            let response = clientError.response
        else { return false }
        return response.status.kind == .successful
    }

    private func fetch() async {
        if case .loaded = state {} else { state = .loading }
        state = await LoadState.fetching {
            switch try await session.client.platformHealthHealthPlatformGet() {
            case .ok(let ok):
                guard let health = PlatformHealth(container: try ok.body.json) else {
                    throw APIStatusError(status: 500)
                }
                return MaintenanceState(health)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Writing the banner every user of this control plane will see.
private struct MaintenanceSheet: View {
    let serverName: String
    let current: MaintenanceState
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var message = ""
    @State private var isConfirming = false
    @FocusState private var fieldFocused: Bool

    private var trimmed: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // `axis: .vertical` because this is a sentence to a
                    // colleague, not a field — it wraps rather than scrolling
                    // sideways out of sight.
                    TextField("Back at 14:00 — replacing the core switch", text: $message, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($fieldFocused)
                } header: {
                    Text("Message")
                } footer: {
                    if trimmed.isEmpty {
                        // Not a blocked Save — an empty message is allowed and
                        // the app has a fallback. Saying what it is beats
                        // letting the operator discover it on the banner.
                        Text(
                            "Without a message the banner just says the server is in a change window. Anyone who wanted to know why will ask you instead."
                        )
                    } else {
                        Text("Shown to everyone using \(serverName) until the window is lifted.")
                    }
                }

                if current.isOn {
                    Section {
                        Label(
                            "A change window is already running. Saving replaces its message and leaves it running.",
                            systemImage: "info.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(current.isOn ? Text("Change the Message") : Text("Start a Change Window"))
            .navigationBarTitleDisplayMode(.inline)
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { isConfirming = true }
                }
            }
            // Non-negotiable #6: Save opens the confirmation, and the
            // confirmation names the actual thing being written rather than
            // asking whether the operator is sure.
            .alert(
                current.isOn ? "Replace the message?" : "Start a change window?",
                isPresented: $isConfirming
            ) {
                Button("Cancel", role: .cancel) {}
                Button(current.isOn ? "Replace It" : "Start It") { onSave(trimmed) }
            } message: {
                Text(verbatim: confirmationText)
            }
            .task {
                // Prefilled with whatever is stored: the platform keeps the
                // last message after a window is lifted, and the next window
                // is usually about the same thing.
                message = current.message
                fieldFocused = true
            }
        }
    }

    /// What is about to happen, with the operator's own words quoted back.
    ///
    /// Assembled as a string rather than interpolated into `Text` so the
    /// server-supplied half goes through `Text(verbatim:)` and is never parsed
    /// as Markdown — the message is operator input, and a link in it would
    /// otherwise render as a tappable one inside this app's own alert.
    private var confirmationText: String {
        var lines: [String] = []
        if current.isOn {
            lines.append(
                String(
                    localized:
                        "The change window on \(serverName) keeps running. Only the banner text changes."
                )
            )
        } else {
            lines.append(
                String(
                    localized:
                        "Everyone using \(serverName) sees a banner, and the server refuses changes until the window is lifted."
                )
            )
        }
        if trimmed.isEmpty {
            lines.append(String(localized: "No message — the banner will not say why."))
        } else {
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n\n")
    }
}

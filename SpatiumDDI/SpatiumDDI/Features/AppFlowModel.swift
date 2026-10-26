//
//  AppFlowModel.swift
//  SpatiumDDI
//

import Foundation
import Observation

/// The app's top-level state: which server, and how far through the door we are.
@Observable
final class AppFlowModel {
    enum Stage: Equatable {
        /// The list of configured control planes.
        case servers
        /// The connect form — pointing the app at a server it doesn't know yet.
        case addServer
        case signIn(StoredServer)
        /// A token exists for this server and needs unsealing.
        ///
        /// Also where an **ungated** token waits on its way back in from the
        /// background — `UnlockView` shows progress rather than a prompt then,
        /// and reads it silently — and where it lands if that silent read is
        /// refused, so the reason has somewhere honest to be shown.
        case locked(StoredServer, message: String?)
        case signedIn(StoredServer)
    }

    private(set) var stage: Stage = .addServer

    /// Every configured control plane.
    private(set) var servers: [StoredServer] = []

    /// Held for the lifetime of the foreground session only. Never written
    /// anywhere but the Keychain, never logged — see `Redaction`.
    private(set) var token: String?

    private let tokens: TokenStore
    private let trust: TrustStore
    private let registry: ServerRegistry

    init(
        tokens: TokenStore = TokenStore(),
        trust: TrustStore = TrustStore(),
        registry: ServerRegistry = ServerRegistry()
    ) {
        self.tokens = tokens
        self.trust = trust
        self.registry = registry
        restore()
    }

    /// True while the stage is still whatever `restore()` concluded, and no
    /// deliberate navigation has happened since.
    private var isLaunchStage = true

    /// Why the app believes there is no stored token to unlock, when a server
    /// was configured and one was expected.
    ///
    /// Surfaced on the sign-in screen rather than kept for a debugger. Being
    /// asked to enrol again is alarming, and "the Keychain answered -25300" is
    /// both the honest reason and the thing that makes the next report useful
    /// — twice now this has been diagnosed by inference from a symptom, which
    /// is slower and less reliable than the device simply saying what happened.
    private(set) var tokenAbsence: String?

    /// Records the Keychain's own answer for a server that should have a token.
    private func noteAbsence(for server: StoredServer) {
        switch tokens.presence(for: server.address) {
        case .present, .absent:
            tokenAbsence = nil
        case .unknown(let status):
            tokenAbsence = "The Keychain could not be read (status \(status))."
        }
    }

    /// Re-reads the stored state if nothing has been chosen since launch.
    ///
    /// `restore()` runs in `init`, which is not always a moment the Keychain
    /// can answer questions: an item stored `WhenPasscodeSetThisDeviceOnly` is
    /// unreadable while the device is locked, and iOS launches apps for its own
    /// reasons — a prewarm, a relaunch after a force-quit — without the screen
    /// ever being unlocked. A launch that concluded "nothing to unlock" would
    /// otherwise keep that conclusion for the whole session and send the
    /// operator to enrol a token they already have.
    ///
    /// Guarded so it cannot undo a choice: an operator who deliberately went to
    /// the server list stays there.
    func reconsiderIfUntouched() {
        guard isLaunchStage else { return }
        // Only a stage that concluded *there is nothing to unlock* is worth
        // revisiting. Re-running `restore()` from anywhere else undoes work
        // the operator has already done — from `.signedIn` it throws them back
        // to the lock screen, they unlock, the next scene-phase change throws
        // them back again, and the app loops. Which is exactly what it did.
        switch stage {
        case .servers, .addServer:
            restore()
        case .signIn, .locked, .signedIn:
            return
        }
    }

    /// The chosen servers are configuration, not response data — non-negotiable
    /// #3 governs what the *control plane returns*, and these are the operator's
    /// own settings. They are not credentials, so they don't belong in the
    /// Keychain; the tokens and pins they are keyed to already do.
    private func restore() {
        servers = registry.servers()

        guard !servers.isEmpty else {
            stage = .addServer
            return
        }

        // Straight back to where they were, when there is something to unlock.
        // The list is the entry point instead of the *connect form* — not
        // instead of the fast path, which is the whole point of holding a
        // per-device token.
        if let current = servers.first(where: { $0.id == registry.currentID() }),
            tokens.hasToken(for: current.address)
        {
            open(current)
        } else {
            if let current = servers.first(where: { $0.id == registry.currentID() }) {
                noteAbsence(for: current)
            }
            stage = .servers
        }
    }

    // MARK: - Unlock, or straight in

    /// What reaching a server should do, given what is stored for it.
    nonisolated enum Entry: Equatable {
        /// Nothing stored: the sign-in form.
        case signIn
        /// A gated token: the unlock screen, which prompts.
        case unlock
        /// An ungated token: read it silently and go straight to signed in.
        case straightIn
    }

    /// The decision, with the Keychain taken out of it so it can be tested.
    ///
    /// `protection` is `nil` when the item's attributes could not be read —
    /// a launch while the device is locked, typically — even though
    /// `hasToken` says there is something there. That resolves to `.unlock`,
    /// not `.straightIn`: an unknown gate is treated as a gate, the same rule
    /// `KeychainProtection.stored(marker:)` applies to an unreadable marker.
    /// `UnlockView`'s own retry reads the marker again once it can.
    nonisolated static func entry(hasToken: Bool, protection: KeychainProtection?) -> Entry {
        guard hasToken else { return .signIn }
        return protection == .deviceUnlock ? .straightIn : .unlock
    }

    /// Takes a server that has a stored token as far in as it can go without
    /// asking anyone anything.
    ///
    /// For an ungated token that is all the way: no unlock screen, not even
    /// for a frame. A refused silent read lands on the lock screen with the
    /// reason, rather than on sign-in — the token is very likely still there
    /// (a locked device answers the same way), and sending the operator to
    /// enrol again over a momentary refusal is the mistake `hasToken` exists
    /// to avoid.
    private func open(_ server: StoredServer) {
        switch Self.entry(hasToken: true, protection: tokens.storedProtection(for: server.address)) {
        case .signIn, .unlock:
            stage = .locked(server, message: nil)
        case .straightIn:
            do {
                token = try tokens.ungatedToken(for: server.address)
                stage = .signedIn(server)
            } catch .deviceLocked {
                // Not worth a message: `UnlockView` retries the moment the
                // scene is active, which is the moment this stops being true.
                stage = .locked(server, message: nil)
            } catch {
                stage = .locked(server, message: error.localizedDescription)
            }
        }
    }

    /// Adds or updates a server, and makes it current.
    private func remember(_ server: StoredServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            // A re-connect keeps the name it already had unless a new one was
            // typed — retyping a host shouldn't silently erase "Prod EU".
            servers[index].label = server.trimmedLabel ?? servers[index].label
        } else {
            servers.append(server)
        }
        registry.save(servers)
        registry.setCurrentID(server.id)
    }

    // MARK: - Which gate is holding the token

    /// Bumped whenever a token's protection changes under a live view.
    ///
    /// The protection itself is read from the Keychain, which Observation
    /// cannot see — so after a re-seal the Server screen would go on showing
    /// the old gate until something else happened to redraw it. Reading this
    /// in `protection(for:)` makes every caller depend on it.
    private var protectionRevision = 0

    /// What is guarding the current server's stored token, if there is one.
    var currentProtection: KeychainProtection? {
        currentServer.flatMap { protection(for: $0) }
    }

    func protection(for server: StoredServer) -> KeychainProtection? {
        _ = protectionRevision
        return tokens.storedProtection(for: server.address)
    }

    func hasToken(for server: StoredServer) -> Bool { tokens.hasToken(for: server.address) }

    // MARK: - Enrolment

    /// A token an enrolment code supplied alongside the server address.
    ///
    /// Held only until sign-in reads it. It is not a stored credential — it has
    /// not been validated or accepted yet, and it never reaches the Keychain
    /// until the operator signs in with it.
    private(set) var pendingToken: String?

    /// A scanned enrolment code carried a token that has already been
    /// validated against the server and sealed in the Keychain.
    ///
    /// Straight to signed-in. The operator picked which code to scan and
    /// pressed the button; making them confirm an opaque `sddi_…` string
    /// afterwards is ceremony, not consent.
    func enrolled(with token: String, to server: StoredServer) {
        isLaunchStage = false
        remember(server)
        self.token = token
        pendingToken = nil
        stage = .signedIn(server)
    }

    func connected(to server: StoredServer, pendingToken: String? = nil) {
        isLaunchStage = false
        remember(server)
        // Reaching a server is always the start of a new session, so a token
        // still in memory belongs to whatever came before — possibly a
        // different control plane. Clearing here rather than relying on the
        // caller having done it: this is the only path that changes which
        // estate is loaded without going through the list.
        token = nil
        self.pendingToken = pendingToken
        let resolved = servers.first(where: { $0.id == server.id }) ?? server
        if tokens.hasToken(for: resolved.address) {
            open(resolved)
        } else {
            stage = .signIn(resolved)
        }
    }

    func signedIn(with token: String, to server: StoredServer) {
        isLaunchStage = false
        self.token = token
        pendingToken = nil
        stage = .signedIn(server)
    }

    /// Unseals the stored token — with a prompt if it is gated, silently if not.
    ///
    /// `TokenStore.token(for:reason:)` makes that choice from the item's own
    /// marker, so this one path serves both: the unlock button for a gated
    /// token, and the return from the background for an ungated one.
    func unlock() async {
        guard case .locked(let server, _) = stage else { return }
        // Unlocking is the operator acting, so whatever launch concluded is no
        // longer the current state — and must not be restored over the top of
        // the session they just authenticated into.
        isLaunchStage = false
        do {
            let stored = try await tokens.token(
                for: server.address,
                reason: "Unlock your SpatiumDDI token for \(server.displayName)"
            )
            token = stored
            stage = .signedIn(server)
        } catch TokenStore.StoreError.cancelled {
            stage = .locked(server, message: nil)
        } catch TokenStore.StoreError.notFound, TokenStore.StoreError.enrollmentChanged {
            // **Never delete here.** `errSecItemNotFound` does not only mean
            // "the item is gone": the Keychain says exactly the same thing when
            // an item is present but its access control cannot be satisfied by
            // the context presented — a biometric item asked for with a
            // passcode-authenticated context, say. Deleting on that signal
            // destroys a working credential over a failed *read*, and there is
            // no way back from it but pasting the token in again.
            //
            // Nothing needs deleting for recovery either way: `save` clears any
            // existing item before adding, because access control cannot be
            // changed by an update. So the only thing that delete ever achieved
            // here was the data loss.
            if tokens.hasToken(for: server.address) {
                // Still there, so this was the read failing rather than the
                // token being absent. Say so, and leave the way out to the
                // operator — Sign Out is on this screen.
                stage = .locked(
                    server,
                    message: String(
                        localized:
                            "The stored token could not be unsealed. It is still on this device — try again, or sign out to replace it."
                    )
                )
            } else {
                stage = .signIn(server)
            }
        } catch {
            stage = .locked(server, message: error.localizedDescription)
        }
    }

    /// Drops the in-memory token so returning to the app requires unlocking again.
    ///
    /// This app changes production DNS and DHCP from a phone that gets left on
    /// desks. Re-unlocking costs one glance.
    ///
    /// Unchanged for an ungated token, deliberately. What goes is the prompt
    /// on the way back, not the teardown on the way out: the token, the
    /// session and every fetched row still leave memory when the app does —
    /// non-negotiable #3 is about the data, and it does not depend on the gate.
    func lockForBackground() {
        guard case .signedIn(let server) = stage else { return }
        token = nil
        stage = .locked(server, message: nil)
    }

    /// The server rejected the stored credential.
    ///
    /// Discards it rather than keeping it: a token the server has revoked will
    /// fail identically on every future unlock, and leaving it in place means
    /// the operator authenticates their way into a dead session forever.
    func sessionRejected() {
        guard case .signedIn(let server) = stage else { return }
        token = nil
        try? tokens.delete(for: server.address)
        stage = .signIn(server)
    }

    func signOut() {
        isLaunchStage = false
        let server = currentServer
        token = nil
        pendingToken = nil
        if let server { try? tokens.delete(for: server.address) }
        // The server stays configured — its address, name and approved
        // certificate are not the credential, and making the operator re-enter
        // all three to sign back in would be a punishment, not a safeguard.
        stage = server.map { .signIn($0) } ?? .servers
    }

    // MARK: - Changing the gate later

    /// What came of asking to change a server's gate.
    enum GateChange: Equatable {
        /// Done; the token is now behind this.
        case changed(KeychainProtection)
        /// The operator dismissed the prompt. Nothing changed, and nothing
        /// needs saying.
        case cancelled
        /// Refused, and the token is exactly where it was.
        case unchanged(String)
        /// The Keychain refused both the new item and the rollback. The token
        /// survives only in memory, for this session — said, never hidden.
        case lost(String)
    }

    /// Turns "Require Face ID to open" on or off for a stored token.
    ///
    /// The two directions are not symmetric, and should not be:
    ///
    /// - **On** strengthens. The token is read back without a prompt — it is
    ///   ungated, that is the point — and re-sealed behind the best gate the
    ///   device offers. A device that has none is told so and left as it is.
    /// - **Off** weakens, so it must be earned: the token is read through its
    ///   *current* gate first, which prompts. Holding the phone unlocked must
    ///   not be enough to remove the thing that was protecting against
    ///   someone holding the phone unlocked. A cancelled or failed prompt
    ///   changes nothing.
    ///
    /// Either way the token re-sealed is the one read back from the Keychain,
    /// not the one in memory — they should match, but the stored one is the
    /// one being moved, and reading it is what proves the gate was passed.
    func setRequiringAuthentication(_ required: Bool, for server: StoredServer) async -> GateChange {
        guard let current = tokens.storedProtection(for: server.address) else {
            return .unchanged(String(localized: "No token is stored on this device for this server."))
        }
        guard current.isGated != required else { return .changed(current) }

        // Checked before reading anything, so a device that cannot gate is
        // told so without first being asked for nothing. `reseal` checks
        // again; this is for the message, that is for the guarantee.
        if required, case .failure(let refusal) = TokenStore.availableProtection() {
            return .unchanged(refusal.localizedDescription)
        }

        // Named from the item's own gate, as `UnlockView` does: a token sealed
        // behind the passcode stays passcode-gated after Face ID is enrolled.
        let gateName =
            current == .biometrics ? TokenStore.biometryDescription() : String(localized: "your passcode")

        let stored: String
        do {
            // Prompts only when `current` is gated — that is, only when
            // turning the gate off, which is exactly when it should.
            stored = try await tokens.token(
                for: server.address,
                reason: String(
                    localized: "Confirm it's you to stop requiring \(gateName) for \(server.displayName)"
                )
            )
        } catch TokenStore.StoreError.cancelled {
            return .cancelled
        } catch {
            return .unchanged(error.localizedDescription)
        }

        defer { protectionRevision += 1 }
        do {
            return .changed(
                try tokens.reseal(stored, for: server.address, requiringAuthentication: required)
            )
        } catch {
            return error.tokenRetained
                ? .unchanged(error.reason.localizedDescription)
                : .lost(error.reason.localizedDescription)
        }
    }

    /// Writes this session's token back after a re-seal lost it.
    ///
    /// Only meaningful for the server that is signed in — that is the only
    /// place an in-memory token exists — and only after `.lost`. It is the
    /// "retry" half of reporting honestly: the operator is told the Keychain
    /// copy is gone *and* given the way to put it back without signing in
    /// again.
    func saveSessionToken(for server: StoredServer, requiringAuthentication: Bool) -> GateChange {
        guard case .signedIn(let shown) = stage, shown.id == server.id, let token else {
            return .unchanged(String(localized: "There is no signed-in session to save a token from."))
        }
        defer { protectionRevision += 1 }
        do {
            return .changed(
                try tokens.save(token, for: server.address, requiringAuthentication: requiringAuthentication)
            )
        } catch {
            return .lost(error.localizedDescription)
        }
    }

    // MARK: - Several control planes

    /// Show the list. Every session-scoped state goes with the torn-down view.
    func showServers() {
        isLaunchStage = false
        token = nil
        pendingToken = nil
        stage = .servers
    }

    func showAddServer() {
        isLaunchStage = false
        token = nil
        pendingToken = nil
        stage = .addServer
    }

    /// Move to another control plane.
    ///
    /// Drops the in-memory token first, so nothing authenticated against the
    /// server being left can outlive the switch. `SignedInView` owns the
    /// `ControlPlaneSession` and every screen's fetched rows, and it is torn
    /// down by this stage change — which is what keeps non-negotiable #3's
    /// "nothing an inactive server returned may linger" true by construction
    /// rather than by remembering to clear things.
    func select(_ server: StoredServer) {
        isLaunchStage = false
        token = nil
        pendingToken = nil
        registry.setCurrentID(server.id)
        if tokens.hasToken(for: server.address) {
            open(server)
        } else {
            noteAbsence(for: server)
            stage = .signIn(server)
        }
    }

    /// Forget a server entirely: its token, its certificate pin, its name.
    ///
    /// Matches what Sign Out does to the token, and goes further — an operator
    /// removing a server means it, and leaving an approved certificate behind
    /// for a host they have finished with is a pin nobody is watching.
    func remove(_ server: StoredServer) {
        isLaunchStage = false
        try? tokens.delete(for: server.address)
        try? trust.removePin(for: server.address)
        servers.removeAll { $0.id == server.id }
        registry.save(servers)

        if registry.currentID() == server.id { registry.setCurrentID(nil) }
        if currentServer?.id == server.id {
            token = nil
            pendingToken = nil
        }
        if servers.isEmpty {
            stage = .addServer
        } else if isCurrent(server) {
            stage = .servers
        }
    }

    func rename(_ server: StoredServer, to label: String?) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        servers[index].label = (trimmed?.isEmpty ?? true) ? nil : trimmed
        registry.save(servers)

        // Keep whatever is on screen naming it correctly.
        let renamed = servers[index]
        switch stage {
        case .signIn(let shown) where shown.id == renamed.id:
            stage = .signIn(renamed)
        case .locked(let shown, let message) where shown.id == renamed.id:
            stage = .locked(renamed, message: message)
        case .signedIn(let shown) where shown.id == renamed.id:
            stage = .signedIn(renamed)
        default:
            break
        }
    }

    private func isCurrent(_ server: StoredServer) -> Bool { currentServer?.id == server.id }

    /// Which server the operator was last on, whatever stage they are at now.
    ///
    /// Distinct from `currentServer`, which is derived from the stage and is
    /// therefore `nil` while the list is on screen — exactly when the list needs
    /// to know which row to mark.
    var currentServerID: String? { registry.currentID() }

    var currentServer: StoredServer? {
        switch stage {
        case .servers, .addServer: nil
        case .signIn(let server), .locked(let server, _), .signedIn(let server): server
        }
    }

    var currentAddress: ServerAddress? { currentServer?.address }
}

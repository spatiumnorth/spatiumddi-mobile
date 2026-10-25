//
//  SignInModel.swift
//  SpatiumDDI
//

import Foundation
import Observation

/// Takes an API token, checks the server accepts it, and stores it behind biometry.
///
/// Minting a per-device token at "sign in on this device" needs `/auth/login`,
/// which needs the generated client. Until then the operator supplies a token
/// they created in the web UI. Everything after that point — validation,
/// storage, the biometric gate — is the real path, not a placeholder.
@Observable
final class SignInModel {
    enum State: Equatable {
        case idle
        case validating
        case storing
        case failed(FailureMessage)
    }

    var tokenInput: String = ""
    private(set) var state: State = .idle
    /// Presented after a scan, so the operator sees what the code contained.
    var scanNotice: String?
    var isScanning = false

    /// The control plane, with whatever the operator named it.
    let server: StoredServer
    /// The origin itself. Kept distinct from the name: an address mismatch in a
    /// scanned code is a fact about hosts, and reporting it in terms of a
    /// nickname would hide which two hosts actually disagreed.
    var address: ServerAddress { server.address }
    private let enrolment: TokenEnrolment
    private let trust: TrustStore
    private let onSignedIn: (String) -> Void

    init(
        server: StoredServer,
        prefilledToken: String? = nil,
        probe: ControlPlaneProbe = ControlPlaneProbe(),
        tokens: TokenStore = TokenStore(),
        trust: TrustStore = TrustStore(),
        onSignedIn: @escaping (String) -> Void
    ) {
        self.server = server
        // Filled, never submitted. A code scanned on the connect screen has
        // still not been seen by the operator, and #6's spirit is that nothing
        // consequential happens without them looking at it.
        if let prefilledToken {
            self.tokenInput = prefilledToken
            self.scanNotice = "Token filled in from the code you scanned. Review it, then sign in."
        }
        self.enrolment = TokenEnrolment(probe: probe, tokens: tokens)
        self.trust = trust
        self.onSignedIn = onSignedIn
    }

    /// Takes what a QR code claimed, and acts on none of it without saying so.
    ///
    /// A code is whatever was printed on the thing the camera pointed at. It can
    /// fill in a token; it cannot silently move the app to another server, and a
    /// certificate fingerprint that disagrees with the one already pinned is
    /// reported rather than quietly reconciled.
    func apply(_ payload: EnrolmentPayload) {
        isScanning = false

        if let scanned = payload.address, scanned != address {
            // One literal, not two joined with `+`. A concatenation is not a
            // literal so it cannot be a localised resource at all — and a
            // sentence split in half is unlocalisable regardless, because the
            // halves do not stay in that order in every language.
            state = .failed(
                .app(
                    "That code is for \(scanned.displayName), not \(address.displayName). Go back and change server if you meant to connect there."
                )
            )
            return
        }

        if let scanned = payload.certificateFingerprint,
            let pinned = trust.pinnedFingerprint(for: address),
            scanned != pinned
        {
            state = .failed(
                .app(
                    "That code carries a different certificate fingerprint than the one you approved for \(address.displayName). Do not continue until you know why."
                )
            )
            return
        }

        guard let token = payload.token else {
            state = .failed(.app("That code didn't contain a token."))
            return
        }

        tokenInput = token
        state = .idle
        scanNotice = "Token filled in from the scanned code. Review it, then sign in."
    }

    var isBusy: Bool { state == .validating || state == .storing }

    /// The server takes either an `sddi_` API token or a JWT. Anything else is
    /// almost certainly a paste mistake, and saying so beats a 401 round trip.
    var looksLikeAToken: Bool {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sddi_") || trimmed.split(separator: ".").count == 3
    }

    var biometryDescription: String { TokenStore.biometryDescription() }

    /// What will hold the token once it is sealed, or why nothing could.
    ///
    /// Read before signing in, not after: a passcode-only device is a trade-off
    /// the operator is accepting, and it has to be on screen while they still
    /// have the choice.
    var availableProtection: Result<KeychainProtection, TokenStore.StoreError> {
        enrolment.availableProtection
    }

    var isDeviceUnprotected: Bool { enrolment.unprotectedReason != nil }

    func signIn() async {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        state = .validating
        switch await enrolment.enrol(token, for: address, requiringAuthentication: true) {
        case .enrolled:
            tokenInput = ""
            state = .idle
            onSignedIn(token)
        case .failed(let message):
            state = .failed(message)
        }
    }

}

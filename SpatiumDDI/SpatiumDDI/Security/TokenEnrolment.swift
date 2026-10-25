//
//  TokenEnrolment.swift
//  SpatiumDDI
//

import Foundation

/// Validating a token against a control plane and sealing it in the Keychain.
///
/// Extracted because this now happens from two places: the sign-in screen,
/// where a token was typed or pasted, and the connect screen, where a scanned
/// enrolment code already carried one. Both paths must apply the same checks —
/// especially the gate, when the operator asked for one: that is the
/// difference between the protection they chose and the protection they got.
nonisolated struct TokenEnrolment {
    enum Outcome: Equatable {
        /// Accepted by the server and sealed in the Keychain, behind this.
        ///
        /// Carries the protection rather than a bare success so the caller can
        /// say which gate is actually holding the token — an operator on a
        /// passcode-only device should not be left to assume Face ID is
        /// involved when it is not.
        case enrolled(KeychainProtection)
        /// Refused, with something the operator can act on.
        case failed(FailureMessage)
    }

    var probe: ControlPlaneProbe = ControlPlaneProbe()
    var tokens: TokenStore = TokenStore()

    /// What gate this device could put in front of a token, or why none.
    ///
    /// Answerable without writing anything, which is what lets the sign-in
    /// screen warn about a passcode-only device — or one with no passcode at
    /// all — *before* the token is stored rather than reporting it afterwards.
    var availableProtection: Result<KeychainProtection, TokenStore.StoreError> {
        TokenStore.availableProtection()
    }

    /// Why this device cannot gate a token at all, if it cannot.
    ///
    /// Not a refusal on its own any more: an ungated token is allowed on such
    /// a device, with a warning. It is a refusal only when the operator has
    /// asked for a gate — see `enrol`.
    var unprotectedReason: String? {
        if case .failure(let error) = availableProtection {
            return error.localizedDescription
        }
        return nil
    }

    /// Validates `rawToken` and seals it.
    ///
    /// `requiringAuthentication` is the operator's "Require Face ID to open"
    /// choice. A parameter with no default, on purpose: every caller has to
    /// say which it means, so a new entry point cannot quietly pick one.
    func enrol(
        _ rawToken: String, for address: ServerAddress, requiringAuthentication: Bool
    ) async -> Outcome {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failed(.app("No token to sign in with.")) }

        // Refuse before validating anything when the gate that was asked for
        // cannot exist here. Checked here as well as in the store because the
        // message an operator needs is "set a passcode", not a Keychain error
        // code — and before the network round trip, because the answer will
        // not change by asking the server first.
        // Foundation already localised this LAError text, so it goes through
        // verbatim rather than being re-keyed against this app's catalogue.
        if requiringAuthentication, let reason = unprotectedReason { return .failed(.server(reason)) }

        switch await probe.validateToken(token, for: address) {
        case .authenticated, .forbidden:
            // `.forbidden` means the credential is good but this account cannot
            // read its own permissions — an authorisation problem to surface
            // later, not a reason to reject a working token here.
            do {
                return .enrolled(
                    try tokens.save(token, for: address, requiringAuthentication: requiringAuthentication)
                )
            } catch {
                return .failed(.server(error.localizedDescription))
            }

        case .rejected:
            return .failed(
                .app("The server rejected that token. Check it hasn't been revoked or expired.")
            )

        case .maintenance:
            return .failed(
                .app("\(address.displayName) is in a change window. Try again once it's finished.")
            )

        case .trustRequired:
            return .failed(
                .app("The server's certificate changed since you connected. Reconnect to review it.")
            )

        case .failed(let error):
            return .failed(.server(error.localizedDescription))
        }
    }
}

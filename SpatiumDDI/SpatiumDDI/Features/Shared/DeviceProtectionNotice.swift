//
//  DeviceProtectionNotice.swift
//  SpatiumDDI
//

import SwiftUI

/// Says what will hold the token, before it is held.
///
/// Shown wherever a token is about to be sealed, in every case including the
/// good one. Three outcomes are worth distinguishing, and each is stated rather
/// than left implicit:
///
/// - **Ungated** (the default): the token is in the Keychain, this device only,
///   and opening the app asks for nothing. Said plainly, in secondary text —
///   it is a choice, not a fault.
/// - **Ungated on a device with no passcode at all**: allowed, but amber. Here
///   "readable whenever the device is unlocked" means "readable by anyone who
///   picks it up", and the operator is entitled to hear that in those words.
/// - **Gated**: biometry is stated plainly; a passcode gets an amber notice,
///   because the operator is accepting a real trade-off over biometry:
///   - a passcode is typed in public, shoulder-surfable, and often shared;
///   - `.biometryCurrentSet` self-invalidates when a face or finger is
///     enrolled, so a coerced enrolment change drops the token.
///     `.devicePasscode` does not.
///
/// That argues for making every weaker option visible and clearly so — not for
/// leaving the app unusable on hardware that never had Face ID, or on a
/// simulator that has nothing at all.
struct DeviceProtectionNotice: View {
    /// The operator's "Require … to open" choice.
    let requiringAuthentication: Bool
    /// What gate the device could offer, or why none.
    let available: Result<KeychainProtection, TokenStore.StoreError>
    /// The biometric hardware's name, whether or not it is enrolled.
    var hardwareName: String? = TokenStore.biometryHardwareName()

    /// Which notice applies. Pulled out of `body` so the choice — the part
    /// that decides whether a warning is shown at all — can be tested without
    /// rendering anything.
    nonisolated enum Kind: Equatable {
        /// A gate was asked for and the device can provide this one.
        case gated(KeychainProtection)
        /// A gate was asked for and the device cannot provide any. Signing in
        /// is refused in this state; the detail is Foundation's own text.
        case gateUnavailable(String)
        /// No gate asked for, on a device that has a passcode.
        case ungated
        /// No gate asked for, on a device with no passcode — the one that
        /// needs saying loudly.
        case ungatedWithoutPasscode
    }

    nonisolated static func kind(
        requiringAuthentication: Bool,
        available: Result<KeychainProtection, TokenStore.StoreError>
    ) -> Kind {
        switch (requiringAuthentication, available) {
        case (true, .success(let protection)): .gated(protection)
        case (true, .failure(let error)): .gateUnavailable(error.localizedDescription)
        // `availableProtection` only fails when there is no passcode — a
        // passcode-only device still succeeds, as `.passcode` — so failure is
        // exactly "this device has no passcode".
        case (false, .success): .ungated
        case (false, .failure): .ungatedWithoutPasscode
        }
    }

    var body: some View {
        switch Self.kind(requiringAuthentication: requiringAuthentication, available: available) {
        case .gated(.biometrics):
            Label(
                "Your token will be protected by \(TokenStore.biometryDescription()).",
                systemImage: "faceid"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

        case .gated(.passcode):
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your token will be protected by your device passcode.")
                    Text(fallbackAdvice).foregroundStyle(.secondary)
                }
                .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
            }
            .foregroundStyle(.orange)

        case .gated(.deviceUnlock), .ungated:
            // `.gated(.deviceUnlock)` cannot come out of `availableProtection`,
            // which only ever offers a real gate; it shares the ungated copy
            // so a switch that grows a case still says something true.
            Label(
                "Opening the app won't ask for \(TokenStore.biometryDescription()). The token stays in this device's Keychain and can be read whenever the device is unlocked.",
                systemImage: "lock.open"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

        case .ungatedWithoutPasscode:
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("This device has no passcode.")
                    Text(
                        "Anyone who picks it up can open this app and use the token against your control plane. Set a passcode to stop that — and to be able to require it here."
                    )
                    .foregroundStyle(.secondary)
                }
                .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
            }
            .foregroundStyle(.orange)

        case .gateUnavailable(let detail):
            // `.server` rather than `.app`: this text is Foundation's own
            // localised `LAError` description, not this app's wording, so it
            // must not be re-keyed against the catalogue.
            Label(.server(detail), systemImage: "lock.slash.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    /// Names the thing to go and set up, but only when it exists to be set up.
    ///
    /// An iPad with no Face ID hardware told to "set up Face ID" sends its
    /// owner looking for a setting that is not there.
    private var fallbackAdvice: LocalizedStringResource {
        guard let hardwareName else {
            return
                "This device has no biometric hardware, so a passcode is the strongest protection available here."
        }
        return
            "\(hardwareName) isn't set up on this device. Setting it up is strongly recommended — it's harder to observe than a typed passcode, and it drops the stored token automatically if the enrolment ever changes."
    }
}

/// The "Require Face ID to open" switch and what it will mean, together.
///
/// One view for both places a token is sealed — the sign-in form and the
/// connect screen's scanned-code path — so the two cannot drift into offering
/// different choices or describing the same choice differently.
///
/// Off by default, because the caller's state starts off. The switch is
/// disabled on a device that has no passcode, where turning it on could only
/// lead to a refusal; the notice beneath it says why, which is the house rule
/// for anything disabled.
struct TokenGateControls: View {
    @Binding var requiringAuthentication: Bool
    let available: Result<KeychainProtection, TokenStore.StoreError>

    private var canGate: Bool {
        if case .success = available { return true }
        return false
    }

    var body: some View {
        Toggle(isOn: $requiringAuthentication) {
            Text("Require \(TokenStore.biometryDescription()) to open")
        }
        // Left enabled while on, so an operator whose passcode was removed
        // mid-form can still turn it off and carry on.
        .disabled(!canGate && !requiringAuthentication)

        DeviceProtectionNotice(requiringAuthentication: requiringAuthentication, available: available)
    }
}

extension KeychainProtection {
    /// What is guarding the token, for the Server screen and the server list.
    var summary: LocalizedStringResource {
        switch self {
        case .biometrics: "\(TokenStore.biometryDescription())"
        case .passcode: "Device passcode"
        case .deviceUnlock: "Device unlock only"
        }
    }

    /// The trade-off, where there is one worth restating.
    ///
    /// `nonisolated`, like `FailureMessage.englishText`: a pure value read the
    /// tests exercise from nonisolated contexts.
    nonisolated var caveat: LocalizedStringResource? {
        switch self {
        case .biometrics: nil
        case .passcode:
            "A passcode is weaker than biometrics here, and unlike a biometric enrolment it doesn't invalidate the stored token when it changes. Sign in again after setting up biometrics to upgrade this."
        case .deviceUnlock:
            "Opening this server asks for nothing beyond unlocking the device, so anyone holding it unlocked can use the token. The token itself never leaves this device's Keychain."
        }
    }

    var symbol: String {
        switch self {
        case .biometrics: "faceid"
        case .passcode: "lock.fill"
        case .deviceUnlock: "lock.open"
        }
    }
}

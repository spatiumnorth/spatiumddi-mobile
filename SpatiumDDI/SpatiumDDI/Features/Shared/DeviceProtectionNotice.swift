//
//  DeviceProtectionNotice.swift
//  SpatiumDDI
//

import SwiftUI

/// Says what will hold the token, before it is held.
///
/// Shown wherever a token is about to be sealed. Biometry is the expected case
/// and is stated plainly; a passcode-only device gets an amber notice rather
/// than silence, because the operator is accepting a real trade-off and is
/// entitled to know they are accepting it:
///
/// - a passcode is typed in public, shoulder-surfable, and often shared;
/// - `.biometryCurrentSet` self-invalidates when a face or finger is enrolled,
///   so a coerced enrolment change drops the token. `.devicePasscode` does not.
///
/// That argues for making the fallback visible and clearly second-best — not
/// for leaving the app unusable on hardware that never had Face ID.
struct DeviceProtectionNotice: View {
    let protection: Result<KeychainProtection, TokenStore.StoreError>
    /// The biometric hardware's name, whether or not it is enrolled.
    var hardwareName: String? = TokenStore.biometryHardwareName()

    var body: some View {
        switch protection {
        case .success(.biometrics):
            Label(
                "Your token will be protected by \(TokenStore.biometryDescription()).",
                systemImage: "faceid"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

        case .success(.passcode):
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

        case .success(.deviceUnlock):
            // `availableProtection` only ever offers a real gate; listed so
            // the switch stays exhaustive and still says something true.
            Label(
                "Opening the app won't ask for \(TokenStore.biometryDescription()).",
                systemImage: "lock.open"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

        case .failure(let error):
            // `.server` rather than `.app`: this text is Foundation's own
            // localised `LAError` description, not this app's wording, so it
            // must not be re-keyed against the catalogue.
            Label(.server(error.localizedDescription), systemImage: "lock.slash.fill")
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

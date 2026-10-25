//
//  UnlockView.swift
//  SpatiumDDI
//

import SwiftUI

/// Shown when a token is already stored for this server and needs unsealing.
struct UnlockView: View {
    let address: ServerAddress
    /// What is actually guarding the stored token.
    ///
    /// The item's own protection, not what the device could do today. A token
    /// sealed behind a passcode stays passcode-gated even after Face ID is
    /// enrolled, so promising Face ID here would be a lie the prompt then
    /// contradicts.
    let protection: KeychainProtection
    let message: String?
    let onUnlock: () -> Void
    let onSignOut: () -> Void

    private var gateName: String {
        switch protection {
        case .biometrics: TokenStore.biometryDescription()
        case .passcode: String(localized: "your passcode")
        // Never shown — the ungated layout does not name a gate — but a
        // name is still owed, and "nothing" is the true one.
        case .deviceUnlock: String(localized: "no prompt")
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(.brandMark)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(address.displayName)
                    .font(.headline)
                Text("Unlock with \(gateName) to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button(action: onUnlock) {
                Label("Unlock", systemImage: protection.symbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()

            Button("Sign Out", role: .destructive, action: onSignOut)
                .padding(.bottom, 24)
        }
        .padding()
    }
}

#Preview {
    UnlockView(
        address: ServerAddress(host: "ddi.internal.example", port: 8443),
        protection: .biometrics,
        message: nil,
        onUnlock: {}, onSignOut: {}
    )
}

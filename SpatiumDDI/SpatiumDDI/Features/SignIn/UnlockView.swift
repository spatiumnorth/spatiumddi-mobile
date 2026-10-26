//
//  UnlockView.swift
//  SpatiumDDI
//

import SwiftUI

/// Shown when a token is already stored for this server and needs unsealing.
///
/// For an **ungated** token this is not a lock screen at all — there is
/// nothing to unlock with — so it shows progress while the token is read
/// silently, and only becomes a screen with something to press if that read is
/// refused. It is still reached at all because the return from the background
/// drops the token (see `AppFlowModel.lockForBackground`), and this is where
/// the stage waits for the scene to be active enough to read it back.
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

    /// An ungated token on its way in, with nothing gone wrong yet.
    ///
    /// The one state where a button would be a lie: pressing it does what is
    /// already happening.
    private var isOpeningSilently: Bool { protection == .deviceUnlock && message == nil }

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
                if protection.isGated {
                    Text("Unlock with \(gateName) to continue.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if isOpeningSilently {
                    ProgressView("Opening…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if protection.isGated {
                Button(action: onUnlock) {
                    Label("Unlock", systemImage: protection.symbol)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
            } else if !isOpeningSilently {
                // The silent read was refused — a locked device, usually —
                // and the message above says why. Retrying is the same call.
                Button(action: onUnlock) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
            }

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

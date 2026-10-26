//
//  ServerSetupView.swift
//  SpatiumDDI
//

import SwiftUI

/// Where an operator points the app at their control plane.
struct ServerSetupView: View {
    /// How far the connect screen got.
    ///
    /// Modelled explicitly rather than as a nullable token, because "no token"
    /// and "a token that failed to enrol" lead to the same screen for opposite
    /// reasons, and the sign-in screen needs to tell them apart to know whether
    /// to pre-fill and what to say.
    enum Outcome {
        /// Reachable and trusted, but no usable token — sign in as normal.
        case needsSignIn(StoredServer, prefill: String?)
        /// A scanned token was validated and sealed; the operator is in.
        case enrolled(StoredServer, token: String)
    }

    var onConnected: (Outcome) -> Void = { _ in }
    /// Back to the server list. `nil` when there is no list to go back to —
    /// the first run, where cancelling would leave nowhere to be.
    var onCancel: (() -> Void)?

    @State private var model = ConnectionModel()
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                BrandHeader(caption: "Connect to your control plane.")

                Section {
                    TextField("ddi.internal.example", text: $model.addressInput)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit { Task { await model.connect() } }
                    TextField("Name (optional)", text: $model.labelInput)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server Address")
                } footer: {
                    // Kept to two lines. The connected Status section — and the
                    // Continue button on it — sits below this on a phone, and
                    // a footer that pushes them off the bottom of the screen
                    // makes the next step something you have to go looking for.
                    Text(
                        "A host name or IP address, plus a port if your control plane isn't on 443. Name it if you like — \"Lab\", \"Prod EU\"."
                    )
                }

                Section {
                    // Offered on the first screen because the enrolment code
                    // carries the server address as well as the token, and
                    // typing a hostname on a phone is the worst part of setting
                    // this up. It is a shortcut, never a requirement — the
                    // footer says so, because a button between the address
                    // field and Connect otherwise reads as a step rather than
                    // an alternative.
                    Button {
                        addressFocused = false
                        model.isScanning = true
                    } label: {
                        Label("Scan Enrolment Code", systemImage: "qrcode.viewfinder")
                    }
                    if let notice = model.scanNotice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Or scan a code")
                } footer: {
                    Text(
                        "A code from the web console's API Tokens page fills in the address and signs you in. Typing the address above and entering a token by hand works just as well."
                    )
                }

                Section {
                    Button {
                        addressFocused = false
                        Task { await model.connect() }
                    } label: {
                        HStack {
                            Text("Connect")
                            Spacer()
                            if model.isBusy { ProgressView() }
                        }
                    }
                    .disabled(model.addressInput.isEmpty || model.isBusy)
                }

                statusSection
            }
            .navigationTitle("")
            .dismissableKeyboard()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel, action: onCancel)
                    }
                }
            }
            .sheet(isPresented: $model.isScanning) {
                TokenScannerView(
                    onScanned: { model.apply($0) },
                    onCancel: { model.isScanning = false }
                )
            }
            .sheet(item: $model.pendingTrust) { pending in
                CertificateTrustSheet(
                    pending: pending,
                    onTrust: { Task { await model.approvePendingTrust() } },
                    onCancel: { model.declinePendingTrust() }
                )
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.state {
        case .idle, .connecting:
            EmptyView()

        case .connected(let address, let status):
            Section("Status") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reachable").font(.body)
                        Text("\(address.displayName) · HTTP \(status)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
                // Only when this button is about to seal a token. Without a
                // scanned token it merely moves to the sign-in screen, which
                // says the same thing at the moment it becomes true.
                if model.canFinishWithScannedToken {
                    TokenGateControls(
                        requiringAuthentication: $model.requiringAuthentication,
                        available: TokenStore.availableProtection()
                    )
                }
                Button(model.canFinishWithScannedToken ? "Sign In" : "Continue") {
                    Task {
                        let server = model.server(at: address)
                        guard model.canFinishWithScannedToken else {
                            onConnected(.needsSignIn(server, prefill: nil))
                            return
                        }
                        // The code carried a token, so finish here rather than
                        // handing the operator a form they have already filled.
                        let prefill = model.scannedToken
                        if let token = await model.finishWithScannedToken(for: address) {
                            onConnected(.enrolled(server, token: token))
                        } else {
                            // A bad code must not dead-end: fall through to
                            // sign-in with the token in place so it can be
                            // corrected, and the reason already on screen.
                            onConnected(.needsSignIn(server, prefill: prefill))
                        }
                    }
                }
                Button("Forget Trusted Certificate", role: .destructive) {
                    model.forgetTrust(for: address)
                }
            }

        case .maintenance(let address, let retryAfter):
            Section("Status") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Maintenance in progress")
                        Text(maintenanceDetail(address: address, retryAfter: retryAfter))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                }
            }

        case .failed(let message):
            Section("Status") {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
        }
    }

    /// Reported, never acted on — the app does not retry into a change window.
    private func maintenanceDetail(address: ServerAddress, retryAfter: TimeInterval?)
        -> LocalizedStringResource
    {
        guard let retryAfter else { return "\(address.displayName) is in a change window." }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        let phrase = formatter.string(from: retryAfter) ?? String(localized: "a while")
        return "\(address.displayName) · try again in \(phrase)."
    }
}

#Preview {
    ServerSetupView()
}

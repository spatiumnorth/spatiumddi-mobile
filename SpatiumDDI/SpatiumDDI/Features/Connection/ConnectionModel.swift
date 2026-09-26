//
//  ConnectionModel.swift
//  SpatiumDDI
//

import Foundation
import Observation

/// Drives "point this app at a control plane", including the trust conversation.
@Observable
final class ConnectionModel {
    enum State: Equatable {
        case idle
        case connecting
        case connected(ServerAddress, status: Int)
        case maintenance(ServerAddress, retryAfter: TimeInterval?)
        case failed(FailureMessage)
    }

    /// A certificate awaiting the operator's judgement.
    struct PendingTrust: Identifiable, Equatable {
        let id = UUID()
        let certificate: CertificateInfo
        let address: ServerAddress
        /// Whether the presented certificate matches the fingerprint carried by
        /// a scanned enrolment code. `nil` when no code supplied one.
        ///
        /// Evidence, not authority. A match means the certificate is the one the
        /// server itself printed into the code, which is far better than an
        /// operator eyeballing 64 hex characters — but the code is still
        /// attacker-supplied, so it informs the decision rather than making it.
        var matchesScannedCode: Bool?
    }

    var addressInput: String = ""
    /// An optional name for this control plane, typed while adding it.
    ///
    /// Offered at the point the operator is looking at the hostname, which is
    /// the only moment they know which one it is. Naming it later, from a list
    /// of near-identical hosts, is the problem the label exists to solve.
    var labelInput: String = ""
    private(set) var state: State = .idle
    var pendingTrust: PendingTrust?
    var isScanning = false
    /// What a scanned code said, shown so the operator sees what it configured.
    private(set) var scanNotice: String?
    /// Carried to sign-in so one scan configures the whole connection.
    /// The token a scanned code carried, until it has been used.
    private(set) var scannedToken: String?
    private var expectedFingerprint: Data?
    /// The server the scanned code named. The token and fingerprint are
    /// evidence about that server only, so they are dropped the moment the
    /// operator connects anywhere else — otherwise editing the address after a
    /// scan would send one server's token to another.
    private var scannedAddress: ServerAddress?

    /// Takes what a QR code claimed, and acts on none of it silently.
    ///
    /// A code is whatever was printed on the thing the camera pointed at — a
    /// sticker on a rack door is not an authorisation. So it fills the address
    /// field and carries a token forward, but it never connects on its own and
    /// never pins a certificate: the operator still confirms both.
    func apply(_ payload: EnrolmentPayload) {
        isScanning = false
        state = .idle

        guard let address = payload.address else {
            // A token-only code is the shape the web console emits when it does
            // not know its own external URL. It is useful at sign-in, but there
            // is nothing here for it to configure.
            scanNotice = nil
            state = .failed(
                .app(
                    "That code carries a token but no server address. Enter the address, then scan it again on the next screen."
                )
            )
            return
        }

        addressInput = address.displayName
        scannedAddress = address
        scannedToken = payload.token
        expectedFingerprint = payload.certificateFingerprint

        var carried = ["server"]
        if payload.token != nil { carried.append("token") }
        if payload.certificateFingerprint != nil { carried.append("certificate fingerprint") }
        let supplied = "Scanned code supplied the \(carried.joined(separator: ", "))."
        // Says what the button will actually do. With a token the next tap
        // signs in; without one it only reaches the server.
        scanNotice =
            payload.token == nil
            ? "\(supplied) Connect to continue."
            : "\(supplied) Signing in will finish setting this device up."
    }

    private let probe: ControlPlaneProbe
    private let trustStore: TrustStore
    private let enrolment: TokenEnrolment

    init(trustStore: TrustStore = TrustStore()) {
        self.trustStore = trustStore
        self.probe = ControlPlaneProbe(trustStore: trustStore)
        self.enrolment = TokenEnrolment(probe: ControlPlaneProbe(trustStore: trustStore))
    }

    /// Whether this connection can be completed without a separate sign-in.
    ///
    /// True once a scanned code has supplied a token and the server has been
    /// reached and trusted — at which point asking the operator to review an
    /// opaque `sddi_…` string and press Sign In is ceremony, not consent. They
    /// chose which code to scan and pressed Connect; that *is* the decision.
    /// The parts that are real judgements — approving an unknown certificate,
    /// unlocking the Keychain — still happen.
    var canFinishWithScannedToken: Bool {
        scannedToken != nil
    }

    /// Validates the scanned token and seals it, so the operator lands signed
    /// in rather than on a form they have already filled.
    ///
    /// Returns the token on success. On failure the caller falls through to the
    /// sign-in screen, where the message is shown and the token can be fixed by
    /// hand — a bad code must not become a dead end.
    func finishWithScannedToken(for address: ServerAddress) async -> String? {
        guard let token = scannedToken else { return nil }
        state = .connecting
        switch await enrolment.enrol(token, for: address) {
        case .enrolled:
            scannedToken = nil
            state = .connected(address, status: 200)
            return token
        case .failed(let message):
            state = .failed(message)
            return nil
        }
    }

    var isBusy: Bool { state == .connecting }

    /// The server as it should be recorded, with whatever name was typed.
    func server(at address: ServerAddress) -> StoredServer {
        StoredServer(address: address, label: labelInput)
    }

    func connect() async {
        let address: ServerAddress
        do {
            address = try ServerAddress.parse(addressInput)
        } catch {
            state = .failed(.server(error.localizedDescription))
            return
        }

        if let scannedAddress, scannedAddress != address {
            setScanAside()
        }

        state = .connecting
        await attempt(address)
    }

    /// The address was edited away from the one the code named: nothing the
    /// code carried applies to this server, and the notice says so rather than
    /// letting "Sign In" quietly become "Continue".
    private func setScanAside() {
        let hadToken = scannedToken != nil
        scannedAddress = nil
        scannedToken = nil
        expectedFingerprint = nil
        scanNotice =
            hadToken
            ? "The address no longer matches the scanned code, so its token was set aside."
            : nil
    }

    /// The operator vouched for the certificate. Pin it and retry — the same
    /// handshake now takes the pinned path instead of being refused.
    func approvePendingTrust() async {
        guard let pending = pendingTrust else { return }
        pendingTrust = nil

        do {
            try trustStore.pin(pending.certificate.fingerprint, for: pending.address)
        } catch {
            state = .failed(.app("Couldn't save the trust decision. \(error.localizedDescription)"))
            return
        }

        state = .connecting
        await attempt(pending.address)
    }

    func declinePendingTrust() {
        pendingTrust = nil
        state = .failed(.app("Connection refused — the server's certificate wasn't trusted."))
    }

    /// Drops a previously approved certificate, so the next connection re-asks.
    func forgetTrust(for address: ServerAddress) {
        try? trustStore.removePin(for: address)
        state = .idle
    }

    private func attempt(_ address: ServerAddress) async {
        switch await probe.probe(address) {
        case .reachable(let status):
            state = .connected(address, status: status)
        case .maintenance(let retryAfter):
            state = .maintenance(address, retryAfter: retryAfter)
        case .trustRequired(let certificate):
            state = .idle
            pendingTrust = PendingTrust(
                certificate: certificate,
                address: address,
                matchesScannedCode: expectedFingerprint.map { $0 == certificate.fingerprint }
            )
        case .failed(let error):
            state = .failed(.server(error.localizedDescription))
        }
    }
}

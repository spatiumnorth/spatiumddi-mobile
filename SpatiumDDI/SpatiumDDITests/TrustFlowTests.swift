//
//  TrustFlowTests.swift
//  SpatiumDDITests
//

import Foundation
import SpatiumAPI
import Testing

@testable import SpatiumDDI

/// Whether the stub control plane is up, and what certificate it is presenting.
///
/// Declared outside the suite: a `@Suite` trait cannot reference a static on the
/// type it annotates without the macro expansion becoming circular.
enum StubControlPlane {
    static var isRunning: Bool {
        ProcessInfo.processInfo.environment["SPATIUM_STUB_RUNNING"] == "1"
    }

    /// The fingerprint openssl reports for the stub's certificate, injected by
    /// the test script so it can never drift from the cert actually in use.
    static var expectedFingerprint: String? {
        ProcessInfo.processInfo.environment["SPATIUM_EXPECTED_FINGERPRINT"]
    }
}

/// Exercises the trust decision against a real TLS handshake with a self-signed
/// certificate — the case every self-hosted install actually hits.
///
/// Skipped wholesale when the stub from `scripts/dev-control-plane.sh` isn't
/// running, so an ordinary test run in Xcode stays green without extra setup.
@Suite(.enabled(if: StubControlPlane.isRunning))
struct TrustFlowTests {
    /// Isolated Keychain service per run, so tests never touch real trust decisions.
    private func isolatedStore() -> TrustStore {
        TrustStore(keychain: KeychainStore(service: "io.spatiumddi.tests.\(UUID().uuidString)"))
    }

    private var healthyAddress: ServerAddress {
        ServerAddress(host: "localhost", port: 8443)
    }

    private var maintenanceAddress: ServerAddress {
        ServerAddress(host: "localhost", port: 8444)
    }

    /// The fingerprint openssl reports for the stub's certificate, injected by
    /// the test script so it can never drift from the cert actually in use.
    private var expectedFingerprint: String? {
        ProcessInfo.processInfo.environment["SPATIUM_EXPECTED_FINGERPRINT"]
    }

    @Test("An unknown self-signed certificate is refused, not silently accepted")
    func untrustedCertificateIsRefused() async throws {
        let outcome = await ControlPlaneProbe(trustStore: isolatedStore()).probe(healthyAddress)

        guard case .trustRequired(let presented) = outcome else {
            Issue.record("Expected .trustRequired, got \(outcome)")
            return
        }
        #expect(presented.requestedHost == "localhost")
        #expect(presented.chainLength >= 1)
    }

    @Test("The fingerprint shown to the operator is the one openssl computes")
    func fingerprintMatchesOpenSSL() async throws {
        let expected = try #require(StubControlPlane.expectedFingerprint, "No expected fingerprint injected.")
        let outcome = await ControlPlaneProbe(trustStore: isolatedStore()).probe(healthyAddress)

        guard case .trustRequired(let presented) = outcome else {
            Issue.record("Expected .trustRequired, got \(outcome)")
            return
        }
        #expect(presented.fingerprintHex == expected.uppercased())
    }

    @Test("Approving the certificate lets the next connection through")
    func pinnedCertificateConnects() async throws {
        let store = isolatedStore()
        let probe = ControlPlaneProbe(trustStore: store)

        guard case .trustRequired(let presented) = await probe.probe(healthyAddress) else {
            Issue.record("Expected an initial trust prompt")
            return
        }

        // What ConnectionModel.approvePendingTrust() does when the operator taps Trust.
        try store.pin(presented.fingerprint, for: healthyAddress)

        let outcome = await probe.probe(healthyAddress)
        #expect(outcome == .reachable(status: 200))

        try store.removePin(for: healthyAddress)
    }

    @Test("A redirect to another origin is handed back, never followed")
    func redirectIsNotFollowed() async throws {
        let store = isolatedStore()
        guard
            case .trustRequired(let presented) = await ControlPlaneProbe(trustStore: store).probe(
                healthyAddress)
        else {
            Issue.record("Expected an initial trust prompt")
            return
        }
        try store.pin(presented.fingerprint, for: healthyAddress)
        defer { try? store.removePin(for: healthyAddress) }

        // The session the app builds, through the generated client and its
        // transport — the path a real call takes. The stub answers everything
        // under /redirect/ with a 307 to the next port, which presents the same
        // certificate: followed, the call would come back 404 from over there.
        let session = URLSession(
            configuration: .ephemeral,
            delegate: ServerTrustDelegate(address: healthyAddress, trustStore: store),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let client = SpatiumClientFactory.makeClient(
            serverURL: healthyAddress.origin.appending(path: "redirect"),
            session: session,
            token: "sddi_redirect_test"
        )

        let response = try await client.getVersionApiV1VersionGet()
        guard case .undocumented(let status, _) = response else {
            Issue.record("Expected the 307 itself, got \(response)")
            return
        }
        #expect(status == 307)
    }

    @Test("A pin for a different certificate does not open the door")
    func wrongPinStillRefuses() async throws {
        let store = isolatedStore()

        // A pin exists for this origin, but it isn't this server's certificate —
        // the case that separates real comparison from merely checking presence.
        try store.pin(Data(repeating: 0xAB, count: 32), for: healthyAddress)

        let outcome = await ControlPlaneProbe(trustStore: store).probe(healthyAddress)
        guard case .trustRequired = outcome else {
            Issue.record("A mismatched pin was accepted — got \(outcome)")
            return
        }

        try store.removePin(for: healthyAddress)
    }

    @Test("Forgetting a certificate makes the next connection ask again")
    func forgottenPinReprompts() async throws {
        let store = isolatedStore()
        let probe = ControlPlaneProbe(trustStore: store)

        guard case .trustRequired(let presented) = await probe.probe(healthyAddress) else {
            Issue.record("Expected an initial trust prompt")
            return
        }
        try store.pin(presented.fingerprint, for: healthyAddress)
        #expect(await probe.probe(healthyAddress) == .reachable(status: 200))

        try store.removePin(for: healthyAddress)
        guard case .trustRequired = await probe.probe(healthyAddress) else {
            Issue.record("Expected to be asked again after forgetting the pin")
            return
        }
    }

    @Test("A change window is reported as maintenance, with its Retry-After")
    func maintenanceIsSurfacedNotRetried() async throws {
        let store = isolatedStore()
        let probe = ControlPlaneProbe(trustStore: store)

        guard case .trustRequired(let presented) = await probe.probe(maintenanceAddress) else {
            Issue.record("Expected an initial trust prompt")
            return
        }
        try store.pin(presented.fingerprint, for: maintenanceAddress)

        let outcome = await probe.probe(maintenanceAddress)
        #expect(outcome == .maintenance(retryAfter: 1800))

        try store.removePin(for: maintenanceAddress)
    }

}

/// Independent of the stub: nothing is listening either way.
struct ConnectionFailureTests {
    private func isolatedStore() -> TrustStore {
        TrustStore(keychain: KeychainStore(service: "io.spatiumddi.tests.\(UUID().uuidString)"))
    }
    @Test("An unreachable port fails as a connection error, not a trust prompt")
    func closedPortIsAConnectionError() async throws {
        let address = ServerAddress(host: "127.0.0.1", port: 9)
        let outcome = await ControlPlaneProbe(trustStore: isolatedStore()).probe(address)

        guard case .failed = outcome else {
            Issue.record("Expected .failed, got \(outcome)")
            return
        }
    }
}

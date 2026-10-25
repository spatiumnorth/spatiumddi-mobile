//
//  AppFlowModelTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

@MainActor
struct AppFlowModelTests {
    /// A flow with its own Keychain service, defaults suite and trust store, so
    /// a test can never see — or delete — a real operator's token or pin.
    private func isolatedFlow() -> (AppFlowModel, StoredServer) {
        let suite = "io.spatiumddi.tests.\(UUID().uuidString)"
        let flow = AppFlowModel(
            tokens: TokenStore(service: suite),
            trust: TrustStore(keychain: KeychainStore(service: suite)),
            registry: ServerRegistry(defaults: UserDefaults(suiteName: suite)!)
        )
        return (flow, StoredServer(address: ServerAddress(host: "ddi.internal.example", port: 8443)))
    }

    private func server(_ host: String, label: String? = nil) -> StoredServer {
        StoredServer(address: ServerAddress(host: host, port: 8443), label: label)
    }

    /// The loop this caused on a real phone: sign in, reach the menu, and the
    /// next scene-phase change re-runs `restore()` over the top of the live
    /// session, dropping back to the lock screen — unlock, menu, lock, forever.
    ///
    /// `reconsiderIfUntouched` exists for a launch that could not read the
    /// Keychain, which is only ever a stage that concluded there was nothing
    /// to unlock. It must never touch a stage the operator has moved past.
    @Test("Becoming active never unwinds a session the operator is already in")
    func reconsideringNeverUnwindsProgress() {
        let (flow, server) = isolatedFlow()

        // Signed in: the state the loop threw away.
        flow.signedIn(with: "sddi_test", to: server)
        flow.reconsiderIfUntouched()
        #expect(flow.stage == .signedIn(server))
        #expect(flow.token == "sddi_test")

        // Part-way through sign-in is equally not to be restored over.
        flow.connected(to: server)
        let afterConnect = flow.stage
        flow.reconsiderIfUntouched()
        #expect(flow.stage == afterConnect)
    }

    /// The other half: a deliberate move to the server list stays put, so the
    /// re-check cannot drag an operator back into a server they just left.
    @Test("A chosen server list is not restored away from")
    func chosenListStays() {
        let (flow, _) = isolatedFlow()
        flow.showServers()
        flow.reconsiderIfUntouched()
        #expect(flow.stage == .servers)
    }

    @Test("A fresh install starts by asking for a server")
    func startsAtAddServer() {
        let (flow, _) = isolatedFlow()
        #expect(flow.stage == .addServer)
        #expect(flow.token == nil)
        #expect(flow.servers.isEmpty)
    }

    @Test("Connecting with no stored token goes to sign-in")
    func connectingAsksToSignIn() {
        let (flow, server) = isolatedFlow()
        flow.connected(to: server)
        #expect(flow.stage == .signIn(server))
    }

    @Test("A rejected credential ends the session rather than stranding the operator")
    func rejectionReturnsToSignIn() {
        let (flow, server) = isolatedFlow()
        flow.connected(to: server)
        flow.signedIn(with: "sddi_example", to: server)
        #expect(flow.stage == .signedIn(server))
        #expect(flow.token != nil)

        flow.sessionRejected()

        // Back to sign-in, and the dead credential is not held on to: it would
        // fail identically on every future unlock.
        #expect(flow.stage == .signIn(server))
        #expect(flow.token == nil)
    }

    @Test("A rejection outside a signed-in session changes nothing")
    func rejectionIgnoredWhenNotSignedIn() {
        let (flow, server) = isolatedFlow()
        flow.connected(to: server)
        flow.sessionRejected()
        #expect(flow.stage == .signIn(server))
    }

    @Test("Backgrounding locks a signed-in session and drops the in-memory token")
    func backgroundingLocks() {
        let (flow, server) = isolatedFlow()
        flow.connected(to: server)
        flow.signedIn(with: "sddi_example", to: server)

        flow.lockForBackground()

        #expect(flow.stage == .locked(server, message: nil))
        #expect(flow.token == nil, "A backgrounded app must not hold the credential")
    }

    @Test("Switching server clears the session")
    func switchingServerClears() {
        let (flow, server) = isolatedFlow()
        flow.connected(to: server)
        flow.signedIn(with: "sddi_example", to: server)
        flow.showServers()
        #expect(flow.stage == .servers)
        #expect(flow.token == nil)
    }

    /// Scanning a code that carries both server and token should land the
    /// operator inside, not on a pre-filled form. They chose which code to
    /// scan and pressed the button; a second confirmation of the same decision
    /// is ceremony.
    @Test("A scanned, already-enrolled token goes straight to signed in")
    func enrolledSkipsSignIn() {
        let (flow, server) = isolatedFlow()

        flow.enrolled(with: "sddi_abc", to: server)

        #expect(flow.stage == .signedIn(server))
        #expect(flow.token == "sddi_abc")
        #expect(flow.pendingToken == nil)
    }

    /// The fallback matters as much as the happy path: a code whose token the
    /// server rejects must land on sign-in with the token in place, so it can
    /// be corrected rather than re-scanned.
    @Test("A token that failed to enrol is carried to sign-in for correction")
    func failedEnrolmentPrefills() {
        let (flow, server) = isolatedFlow()

        flow.connected(to: server, pendingToken: "sddi_bad")

        #expect(flow.stage == .signIn(server))
        #expect(flow.pendingToken == "sddi_bad")
        #expect(flow.token == nil, "a rejected token is not a session")
    }

    @Test("Switching server drops a carried token")
    func switchingServerDropsPendingToken() {
        let (flow, server) = isolatedFlow()
        flow.connected(to: server, pendingToken: "sddi_abc")

        flow.showServers()

        #expect(flow.pendingToken == nil, "a token scanned for one server must not follow to another")
        #expect(flow.stage == .servers)
    }

    // MARK: - Several control planes (spatiumddi-mobile#6)

    @Test("Connecting to a second server keeps the first")
    func keepsBothServers() {
        let (flow, first) = isolatedFlow()
        let second = server("lab.internal.example", label: "Lab")

        flow.connected(to: first)
        flow.connected(to: second)

        #expect(flow.servers.count == 2)
        #expect(flow.servers.map(\.id).contains(first.id))
        #expect(flow.currentServerID == second.id)
    }

    @Test("Switching to another server drops the session for the one being left")
    func switchingTearsDownTheSession() {
        let (flow, first) = isolatedFlow()
        let second = server("lab.internal.example")

        flow.connected(to: first)
        flow.signedIn(with: "sddi_first", to: first)
        flow.connected(to: second)

        // Non-negotiable #3: nothing the previous control plane returned may
        // linger, and the token it was fetched with goes first.
        #expect(flow.token == nil)
        #expect(flow.stage == .signIn(second))
        #expect(flow.currentServer?.id == second.id)
    }

    @Test("Selecting a server makes it current")
    func selectingSetsCurrent() {
        let (flow, first) = isolatedFlow()
        let second = server("lab.internal.example")
        flow.connected(to: first)
        flow.connected(to: second)

        flow.select(first)

        #expect(flow.currentServerID == first.id)
        #expect(flow.stage == .signIn(first))
    }

    @Test("Removing a server forgets it entirely")
    func removingForgetsTheServer() {
        let (flow, first) = isolatedFlow()
        let second = server("lab.internal.example")
        flow.connected(to: first)
        flow.connected(to: second)

        flow.remove(second)

        #expect(flow.servers.map(\.id) == [first.id])
        #expect(flow.currentServerID == nil, "the removed server must not stay current")
    }

    @Test("Removing the last server returns to the connect form")
    func removingTheLastServerAsksForOne() {
        let (flow, only) = isolatedFlow()
        flow.connected(to: only)
        flow.showServers()

        flow.remove(only)

        #expect(flow.servers.isEmpty)
        #expect(flow.stage == .addServer)
    }

    @Test("A name given to a server survives reconnecting to it")
    func reconnectingKeepsTheName() {
        let (flow, plain) = isolatedFlow()
        flow.connected(to: StoredServer(address: plain.address, label: "Prod EU"))

        // Re-typing the host with no name must not silently erase "Prod EU" —
        // that is the label's whole job.
        flow.connected(to: StoredServer(address: plain.address, label: nil))

        #expect(flow.servers.first?.trimmedLabel == "Prod EU")
        #expect(flow.stage == .signIn(flow.servers[0]))
    }

    @Test("Renaming updates the server on screen, not just the list")
    func renamingUpdatesTheStage() {
        let (flow, target) = isolatedFlow()
        flow.connected(to: target)
        flow.signedIn(with: "sddi_example", to: target)

        flow.rename(target, to: "Prod EU")

        #expect(flow.servers.first?.trimmedLabel == "Prod EU")
        guard case .signedIn(let shown) = flow.stage else {
            Issue.record("expected to still be signed in, got \(flow.stage)")
            return
        }
        #expect(shown.trimmedLabel == "Prod EU", "the sidebar names the server from the stage")
    }

    @Test("An empty name falls back to the address rather than showing nothing")
    func blankNameFallsBack() {
        let (flow, target) = isolatedFlow()
        flow.connected(to: StoredServer(address: target.address, label: "Lab"))

        flow.rename(target, to: "   ")

        #expect(flow.servers.first?.trimmedLabel == nil)
        #expect(flow.servers.first?.displayName == target.address.displayName)
    }

    @Test("Signing out keeps the server configured")
    func signOutKeepsTheServer() {
        let (flow, target) = isolatedFlow()
        flow.connected(to: target)
        flow.signedIn(with: "sddi_example", to: target)

        flow.signOut()

        // Only the credential is a secret. Making the operator re-enter the
        // address, the name and the certificate approval to sign back in would
        // be a punishment, not a safeguard.
        #expect(flow.servers.count == 1)
        #expect(flow.stage == .signIn(target))
        #expect(flow.token == nil)
    }
}

/// The ungated default, through the flow: no unlock screen on the way in, the
/// same teardown on the way out, and a gate that can be asked for later.
@MainActor
struct UngatedFlowTests {
    @MainActor
    private struct Fixture {
        let tokens: TokenStore
        let registry: ServerRegistry
        let trust: TrustStore
        let server = StoredServer(address: ServerAddress(host: "ddi.internal.example", port: 8443))

        func flow() -> AppFlowModel { AppFlowModel(tokens: tokens, trust: trust, registry: registry) }
    }

    /// A configured server with an ungated token already stored — the state
    /// every default sign-in leaves behind.
    private func fixture() throws -> Fixture {
        let suite = "io.spatiumddi.tests.\(UUID().uuidString)"
        let fixture = Fixture(
            tokens: TokenStore(service: suite),
            registry: ServerRegistry(defaults: UserDefaults(suiteName: suite)!),
            trust: TrustStore(keychain: KeychainStore(service: suite))
        )
        fixture.registry.save([fixture.server])
        fixture.registry.setCurrentID(fixture.server.id)
        try fixture.tokens.save("sddi_ungated", for: fixture.server.address, requiringAuthentication: false)
        return fixture
    }

    @Test("Launching with an ungated token goes straight in")
    func launchGoesStraightIn() throws {
        let fixture = try fixture()
        defer { try? fixture.tokens.delete(for: fixture.server.address) }

        let flow = fixture.flow()

        #expect(flow.stage == .signedIn(fixture.server))
        #expect(flow.token == "sddi_ungated")
    }

    @Test("Selecting a server with an ungated token goes straight in")
    func selectGoesStraightIn() throws {
        let fixture = try fixture()
        defer { try? fixture.tokens.delete(for: fixture.server.address) }
        let flow = fixture.flow()
        flow.showServers()

        flow.select(fixture.server)

        #expect(flow.stage == .signedIn(fixture.server))
        #expect(flow.token == "sddi_ungated")
    }

    /// The gate going away is not the teardown going away. Non-negotiable #3
    /// still holds: backgrounding drops the token and the session, and coming
    /// back reads it again — silently.
    @Test("Backgrounding still drops the token; coming back needs no prompt")
    func backgroundStillTearsDown() async throws {
        let fixture = try fixture()
        defer { try? fixture.tokens.delete(for: fixture.server.address) }
        let flow = fixture.flow()

        flow.lockForBackground()
        #expect(flow.token == nil)
        #expect(flow.stage == .locked(fixture.server, message: nil))

        await flow.unlock()
        #expect(flow.stage == .signedIn(fixture.server))
        #expect(flow.token == "sddi_ungated")
    }

    @Test("Asking for the gate already in force changes nothing")
    func noOpChange() async throws {
        let fixture = try fixture()
        defer { try? fixture.tokens.delete(for: fixture.server.address) }
        let flow = fixture.flow()

        #expect(await flow.setRequiringAuthentication(false, for: fixture.server) == .changed(.deviceUnlock))
        #expect(fixture.tokens.storedProtection(for: fixture.server.address) == .deviceUnlock)
    }

    @Test("Turning the gate on where the device has none says so and keeps the token")
    func gateRefusedKeepsToken() async throws {
        guard case .failure = TokenStore.availableProtection() else { return }
        let fixture = try fixture()
        defer { try? fixture.tokens.delete(for: fixture.server.address) }
        let flow = fixture.flow()

        let outcome = await flow.setRequiringAuthentication(true, for: fixture.server)

        guard case .unchanged = outcome else {
            Issue.record("expected an honest refusal, got \(outcome)")
            return
        }
        #expect(fixture.tokens.storedProtection(for: fixture.server.address) == .deviceUnlock)
        #expect(try fixture.tokens.ungatedToken(for: fixture.server.address) == "sddi_ungated")
        #expect(flow.stage == .signedIn(fixture.server), "a refused change never signs anyone out")
    }

    @Test("A session token can be saved back after a lost re-seal")
    func saveSessionTokenRestores() throws {
        let fixture = try fixture()
        defer { try? fixture.tokens.delete(for: fixture.server.address) }
        let flow = fixture.flow()
        // Simulate the lost state: Keychain empty, session still holding it.
        try fixture.tokens.delete(for: fixture.server.address)
        #expect(flow.protection(for: fixture.server) == nil)

        #expect(
            flow.saveSessionToken(for: fixture.server, requiringAuthentication: false)
                == .changed(.deviceUnlock))
        #expect(try fixture.tokens.ungatedToken(for: fixture.server.address) == "sddi_ungated")
    }
}

/// Storage for the configured servers, including the upgrade from the
/// single-server layout every existing install is on.
@MainActor
struct ServerRegistryTests {
    private func isolated() -> (ServerRegistry, UserDefaults) {
        let suite = "io.spatiumddi.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ServerRegistry(defaults: defaults), defaults)
    }

    @Test("A fresh install has no servers")
    func emptyByDefault() {
        let (registry, _) = isolated()
        #expect(registry.servers().isEmpty)
        #expect(registry.currentID() == nil)
    }

    /// The upgrade path. A single-server install stored one `ServerAddress`
    /// under `lastServerAddress`; its Keychain token and certificate pin are
    /// already keyed by `pinKey`, so migrating the list costs the operator
    /// nothing — provided the list is actually migrated rather than ignored.
    @Test("A single-server install is migrated rather than forgotten")
    func migratesTheLegacyAddress() throws {
        let (registry, defaults) = isolated()
        let address = ServerAddress(host: "ddi.internal.example", port: 8443)
        defaults.set(try JSONEncoder().encode(address), forKey: "lastServerAddress")

        let servers = registry.servers()

        #expect(servers.count == 1)
        #expect(servers.first?.address == address)
        #expect(registry.currentID() == servers.first?.id, "the migrated server is the current one")
    }

    @Test("Migration happens once, and a later removal is not undone by it")
    func migrationDoesNotResurrectARemovedServer() throws {
        let (registry, defaults) = isolated()
        let address = ServerAddress(host: "ddi.internal.example", port: 8443)
        defaults.set(try JSONEncoder().encode(address), forKey: "lastServerAddress")

        _ = registry.servers()
        registry.save([])

        // The legacy key is still there. Reading an *empty saved list* must win
        // over it, or removing your only server would bring it back next launch.
        #expect(registry.servers().isEmpty)
    }

    @Test("Servers round-trip with their names")
    func roundTrips() {
        let (registry, _) = isolated()
        let servers = [
            StoredServer(address: ServerAddress(host: "a.example", port: nil), label: "Prod"),
            StoredServer(address: ServerAddress(host: "b.example", port: 8443)),
        ]

        registry.save(servers)

        #expect(registry.servers() == servers)
    }

    @Test("Two entries for one origin are the same server")
    func identityIsTheOrigin() {
        // They share a Keychain token and a certificate pin, both keyed by
        // `pinKey`, so treating them as two servers would mean two rows
        // fighting over one credential.
        let a = StoredServer(address: ServerAddress(host: "a.example", port: 443), label: "One")
        let b = StoredServer(address: ServerAddress(host: "a.example", port: nil), label: "Two")
        #expect(a.id == b.id)
    }
}

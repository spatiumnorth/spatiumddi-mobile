//
//  RedactionTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

struct RedactionTests {
    @Test("An API token never appears in its redacted form")
    func apiTokenIsNotEchoed() {
        let token = "sddi_9f2c41aa7b3e4d5081c6"
        let redacted = Redaction.redact(token)
        #expect(!redacted.contains("9f2c41aa7b3e4d5081c6"))
        #expect(redacted.hasPrefix("sddi_"))
        #expect(redacted == "sddi_<redacted:20>")
    }

    @Test("A non-prefixed secret leaks neither content nor prefix")
    func jwtIsFullyRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdef"
        let redacted = Redaction.redact(jwt)
        #expect(!redacted.contains("eyJ"))
        #expect(redacted == "<redacted:\(jwt.count)>")
    }

    @Test("An empty secret is reported as empty, not as a zero-length redaction")
    func emptySecret() {
        #expect(Redaction.redact("") == "<empty>")
    }

    @Test(
        "Authorization is redacted whatever its casing",
        arguments: [
            "Authorization", "authorization", "AUTHORIZATION",
        ])
    func authorizationHeaderRedacted(_ name: String) {
        #expect(Redaction.redactHeaderValue("Bearer sddi_secret", forName: name) == "<redacted>")
    }

    @Test("Ordinary headers survive intact")
    func benignHeaderKept() {
        #expect(Redaction.redactHeaderValue("application/json", forName: "Accept") == "application/json")
    }

    @Test(
        "Cookies are treated as credentials too", arguments: ["Cookie", "Set-Cookie", "Proxy-Authorization"])
    func cookieHeadersRedacted(_ name: String) {
        #expect(Redaction.redactHeaderValue("anything", forName: name) == "<redacted>")
    }

    @Test("A described request carries the URL but never the token")
    func describedRequestIsSafe() {
        var request = URLRequest(url: URL(string: "https://ddi.internal.example/api/v1/auth/me/permissions")!)
        request.httpMethod = "GET"
        request.setValue("Bearer sddi_9f2c41aa7b3e4d5081c6", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let description = Redaction.describe(request)
        #expect(!description.contains("sddi_9f2c41aa7b3e4d5081c6"))
        #expect(!description.contains("Bearer"))
        #expect(description.contains("Authorization: <redacted>"))
        #expect(description.contains("Accept: application/json"))
        #expect(description.contains("/api/v1/auth/me/permissions"))
    }
}

struct TokenStoreAvailabilityTests {
    /// Whatever the device offers, this must answer without trapping — the
    /// sign-in screen calls it on every render.
    @Test("Available protection reports a reason instead of crashing")
    func availabilityIsSafeToQuery() {
        switch TokenStore.availableProtection() {
        case .success:
            #expect(!TokenStore.biometryDescription().isEmpty)
        case .failure(let error):
            #expect(error.localizedDescription.isEmpty == false)
        }
    }

    /// The rule that survived widening the gate to include a passcode
    /// (spatiumddi-mobile#5), and survives the gate becoming optional: when the
    /// operator *asks* for a gate, a device that can provide neither refuses
    /// to store the token, rather than writing it with less protection than
    /// they chose.
    @Test("A gate asked for on an unprotected device is refused, not quietly dropped")
    func refusesToStoreUnprotected() throws {
        guard case .failure = TokenStore.availableProtection() else {
            // Something can protect a token here; the flow itself covers that path.
            return
        }
        let store = TokenStore(service: "io.spatiumddi.tests.\(UUID().uuidString)")
        let address = ServerAddress(host: "ddi.internal.example", port: 8443)

        #expect(throws: TokenStore.StoreError.self) {
            try store.save("sddi_should_not_persist", for: address, requiringAuthentication: true)
        }
        #expect(store.hasToken(for: address) == false)
    }
}

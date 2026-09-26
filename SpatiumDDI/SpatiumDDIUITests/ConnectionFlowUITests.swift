//
//  ConnectionFlowUITests.swift
//  SpatiumDDIUITests
//

import XCTest

/// Drives the whole trust conversation as an operator would meet it: type an
/// address, get challenged over an unverifiable certificate, approve it, connect.
///
/// Needs the stub from `scripts/dev-control-plane.sh`; skips without it.
final class ConnectionFlowUITests: XCTestCase {
    private var stubIsRunning: Bool {
        ProcessInfo.processInfo.environment["SPATIUM_STUB_RUNNING"] == "1"
    }

    private var expectedFingerprint: String? {
        ProcessInfo.processInfo.environment["SPATIUM_EXPECTED_FINGERPRINT"]?.uppercased()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(stubIsRunning, "Stub control plane not running.")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testOperatorApprovesCertificateThenConnects() throws {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Address field never appeared")
        field.tap()
        field.typeText("localhost:8443")
        attach(app, "01-server-address-entered")

        app.buttons["Connect"].tap()

        // The certificate is unverifiable, so the app must ask rather than proceed.
        let sheetTitle = app.staticTexts["Verify Certificate"]
        XCTAssertTrue(
            sheetTitle.waitForExistence(timeout: 15),
            "Expected to be challenged over the self-signed certificate")
        attach(app, "02-certificate-challenge")

        // The fingerprint on screen must be the real one, not a placeholder.
        if let expected = expectedFingerprint {
            let firstGroup = String(expected.prefix(11))  // "52:C1:AA:16"
            XCTAssertTrue(
                app.staticTexts[firstGroup].exists,
                "Fingerprint \(firstGroup) not shown on the trust sheet")
        }

        app.buttons["Trust"].tap()

        let reachable = app.staticTexts["Reachable"]
        XCTAssertTrue(
            reachable.waitForExistence(timeout: 15),
            "Connection did not succeed after the certificate was approved")
        attach(app, "03-connected")

        // Leave no pin behind, so a re-run starts from the same place.
        forgetTrustedCertificate(app)
    }

    @MainActor
    func testDecliningTheCertificateRefusesTheConnection() throws {
        let app = XCUIApplication()
        app.launch()

        connectExpectingChallenge(app, "localhost:8443")
        app.buttons["Don't Trust"].tap()

        let refused = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "certificate wasn't trusted")
        ).firstMatch
        XCTAssertTrue(
            refused.waitForExistence(timeout: 10),
            "Declining should refuse the connection, not quietly proceed")
        attach(app, "04-declined")
    }
}

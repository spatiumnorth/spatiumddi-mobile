//
//  UITestSupport.swift
//  SpatiumDDIUITests
//

import XCTest

/// Trust decisions live in the Keychain, which outlives an app install and is
/// shared by every test on the device. A test that pins a certificate and walks
/// away leaves the next run connecting silently to an already-trusted server —
/// which looks exactly like the challenge screen being broken.
///
/// These helpers make each test start from a known state instead of inheriting
/// whatever the last one left behind.
@MainActor
extension XCTestCase {

    /// Gets the app back to the connect screen, whatever it launched into.
    ///
    /// Test devices are clones of a simulator a human may have signed in on, and
    /// the Keychain survives an app reinstall. Without this the app launches
    /// locked or signed in, there is no address field, and every test fails at
    /// its first line for a reason that has nothing to do with what it covers.
    func startAtConnectScreen(_ app: XCUIApplication) {
        // The unlock screen offers Sign Out directly.
        if app.buttons["Sign Out"].waitForExistence(timeout: 3) {
            app.buttons["Sign Out"].tap()
        }

        // Signed in: the app lands on the sidebar menu, and Sign Out lives on
        // its Server section — which sits low enough in the list that the lazy
        // List may not have materialised the row until it is scrolled to.
        if app.navigationBars["Menu"].waitForExistence(timeout: 2) {
            let serverRow = app.cells.staticTexts["Server"]
            if !serverRow.exists { app.swipeUp() }
            if serverRow.waitForExistence(timeout: 3) {
                serverRow.tap()
                let signOut = app.buttons["Sign Out"]
                if !signOut.waitForExistence(timeout: 3) { app.swipeUp() }
                if signOut.waitForExistence(timeout: 3) { signOut.tap() }
            }
        }

        // Signing out lands on sign-in, which is two steps from the connect
        // form now that several servers can be configured: Switch Server opens
        // the list, and the form is behind Add Server on it.
        openConnectForm(app)
    }

    /// From wherever the app is in the server flow, get to the connect form.
    ///
    /// Both taps are conditional. On a device with no server configured the app
    /// launches straight into the form, and on one that has several the list is
    /// already on screen — asserting either step would fail on a clean
    /// simulator for a reason unrelated to what the test covers.
    func openConnectForm(_ app: XCUIApplication) {
        if app.buttons["Switch Server"].waitForExistence(timeout: 3) {
            app.buttons["Switch Server"].tap()
        }
        if app.buttons["Add Server"].waitForExistence(timeout: 3) {
            app.buttons["Add Server"].tap()
        }
    }

    /// Types an address into the connect screen and submits it.
    ///
    /// The address field is the first on the form; the optional name field sits
    /// below it and is deliberately left empty here, so a test asserts against
    /// the host rather than a label it invented.
    func enterAddress(_ app: XCUIApplication, _ address: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Address field never appeared")
        if (field.value as? String ?? "").isEmpty || field.value as? String == "ddi.internal.example" {
            field.tap()
            field.typeText(address)
        }
        app.buttons["Connect"].tap()
    }

    /// Connects and guarantees the certificate challenge is actually exercised.
    ///
    /// If a previous run already pinned this server, forgets it and reconnects
    /// so the test measures the challenge rather than skipping past it.
    func connectExpectingChallenge(_ app: XCUIApplication, _ address: String) {
        startAtConnectScreen(app)
        enterAddress(app, address)
        if app.staticTexts["Verify Certificate"].waitForExistence(timeout: 20) { return }

        // Already trusted, so the connection succeeded instead. The controls
        // for that state are in the Status section at the bottom of the form,
        // which on a phone-sized window is below the fold — and a SwiftUI Form
        // is a lazy collection view, so a row nobody has scrolled to is not in
        // the accessibility tree at all, not merely off screen.
        let forget = app.buttons["Forget Trusted Certificate"]
        if !forget.waitForExistence(timeout: 10) { app.swipeUp() }
        XCTAssertTrue(
            forget.waitForExistence(timeout: 10),
            "Neither challenged nor connected — the server is unreachable"
        )
        forget.tap()
        app.buttons["Connect"].tap()
        XCTAssertTrue(
            app.staticTexts["Verify Certificate"].waitForExistence(timeout: 20),
            "Certificate was forgotten but the next connection wasn't challenged"
        )
    }

    /// Drops any pin this test created, so the next run starts clean.
    func forgetTrustedCertificate(_ app: XCUIApplication) {
        let forget = app.buttons["Forget Trusted Certificate"]
        if forget.waitForExistence(timeout: 10) { forget.tap() }
    }
}

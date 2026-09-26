//
//  ScreenshotUITests.swift
//  SpatiumDDIUITests
//

import XCTest

/// Drives the whole app against a real control plane and captures each screen.
///
/// Two jobs. It is the only test that proves the sections render live data end
/// to end — a decode test says the JSON parses, not that the screen built from
/// it draws. And it is how store and README screenshots get made, so the images
/// people see come from the app actually running rather than a mockup.
///
/// Opt-in, because it needs a populated control plane and a token:
///
///   TEST_RUNNER_SPATIUM_LIVE_HOST=ddi.example.com \
///   TEST_RUNNER_SPATIUM_LIVE_TOKEN_FILE=/tmp/spatium-token \
///   TEST_RUNNER_SPATIUM_SHOT_DIR=/tmp/shots \
///     xcodebuild test -only-testing:SpatiumDDIUITests/ScreenshotUITests …
///
/// The simulator must have a biometric enrolment or a passcode, or the token
/// store refuses to save — which is non-negotiable #2 working as intended, not
/// a bug.
///
/// The walk mirrors how the app is actually navigated: sign in, land on the
/// sidebar menu, open each section from it, and drill where a second call
/// builds the screen — a subnet's addresses, a zone's records, a DHCP server's
/// chart. The write sheets are opened and captured but always **cancelled**;
/// this test must never mutate the estate it is pointed at.
final class ScreenshotUITests: XCTestCase {
    private var host = ""
    private var token = ""
    private var shotDirectory: URL?
    /// Which rows to drill into, by name — `SPATIUM_IPAM_SPACE`,
    /// `…_IPAM_BLOCK`, `…_IPAM_SUBNET`, `…_DNS_GROUP`, `…_DNS_ZONE`.
    ///
    /// Optional, but worth setting: without them the walk descends into the
    /// *first* row at each level, and on a demo estate the first row sorted to
    /// the top is as likely to be an empty multicast block as the populated
    /// office subnet the screenshots are for.
    private var hints: [String: String] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        host = environment["SPATIUM_LIVE_HOST"] ?? ""
        // Prefer a path over the value: xcodebuild dumps the launch
        // environment to its log, so a token passed directly is written to
        // disk in plaintext. See LiveServer.token.
        if let path = environment["SPATIUM_LIVE_TOKEN_FILE"], !path.isEmpty,
            let contents = try? String(contentsOfFile: path, encoding: .utf8)
        {
            token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            token = environment["SPATIUM_LIVE_TOKEN"] ?? ""
        }
        try XCTSkipIf(host.isEmpty || token.isEmpty, "No live control plane configured.")
        for key in ["IPAM_SPACE", "IPAM_BLOCK", "IPAM_SUBNET", "DNS_GROUP", "DNS_ZONE", "DHCP_SERVER"] {
            if let value = environment["SPATIUM_\(key)"], !value.isEmpty { hints[key] = value }
        }
        if let directory = environment["SPATIUM_SHOT_DIR"], !directory.isEmpty {
            shotDirectory = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory), withIntermediateDirectories: true
            )
        }
    }

    /// Attaches to the result bundle, and writes a PNG when a directory is set.
    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let shotDirectory else { return }
        try? screenshot.pngRepresentation.write(to: shotDirectory.appendingPathComponent("\(name).png"))
    }

    // MARK: - Sidebar navigation

    /// Puts the sidebar menu back on screen, however deep the walk went.
    ///
    /// On a phone the split view collapses into one stack, so this is "tap the
    /// back button until the bar reads Menu". Bounded, because a loop that taps
    /// whatever is at the top-left forever will eventually find a button that
    /// does something worse than navigate.
    @MainActor
    private func popToMenu(_ app: XCUIApplication) {
        for _ in 0..<8 {
            if app.navigationBars["Menu"].waitForExistence(timeout: 2) { return }
            let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
        }
        XCTAssertTrue(
            app.navigationBars["Menu"].waitForExistence(timeout: 5),
            "Never made it back to the menu"
        )
    }

    /// Opens one sidebar section from the menu.
    ///
    /// The menu is a plain List and a List is lazy: a row below the fold is
    /// not in the accessibility tree at all, so "missing" and "not scrolled
    /// to" are the same observation. Look where we are, then down, then up.
    @discardableResult
    @MainActor
    private func openSection(_ app: XCUIApplication, _ title: String) -> Bool {
        popToMenu(app)
        let row = app.cells.staticTexts[title]
        var swipes = 0
        while !(row.exists && row.isHittable), swipes < 3 {
            app.swipeUp()
            swipes += 1
        }
        while !(row.exists && row.isHittable), swipes < 6 {
            app.swipeDown()
            swipes += 1
        }
        guard row.exists, row.isHittable else { return false }
        row.tap()
        return true
    }

    /// Opens a section, lets it settle, and captures it.
    @MainActor
    private func captureSection(
        _ app: XCUIApplication, _ title: String, as name: String, settle: TimeInterval = 2.5
    ) {
        guard openSection(app, title) else {
            XCTFail("Menu row \(title) never appeared")
            return
        }
        Thread.sleep(forTimeInterval: settle)
        capture(app, name)
    }

    /// Opens the named row when a hint was provided, else the first row whose
    /// pushed screen is not an empty state.
    @MainActor
    private func descend(_ app: XCUIApplication, hint: String?) -> Bool {
        if let hint { return openRow(app, containing: hint) }
        return drillFirstPopulatedRow(app)
    }

    /// Taps the row whose text contains `text`, scrolling to materialise it —
    /// a lazy List keeps unscrolled rows out of the accessibility tree.
    @MainActor
    private func openRow(_ app: XCUIApplication, containing text: String) -> Bool {
        for _ in 0..<3 {
            let match = app.cells.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", text)
            ).firstMatch
            if match.exists, match.isHittable {
                match.tap()
                return true
            }
            app.swipeUp()
        }
        return false
    }

    /// Taps the first row and verifies the pushed screen has rows of its own;
    /// an empty container backs out and tries the next one. Demo estates keep
    /// empty spaces and groups near the top of the sort order — and an empty
    /// state is itself a cell, so "has any cell" is not the test; "has a cell
    /// and is not the Nothing here card" is.
    @MainActor
    private func drillFirstPopulatedRow(_ app: XCUIApplication) -> Bool {
        for index in 0..<3 {
            let row = app.cells.element(boundBy: index)
            guard row.waitForExistence(timeout: 10) else { return false }
            row.tap()
            let hasRows = app.cells.firstMatch.waitForExistence(timeout: 8)
            if hasRows, !app.staticTexts["Nothing here"].exists { return true }
            let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            guard back.exists else { return false }
            back.tap()
        }
        return false
    }

    /// Opens the first row on a subnet screen that is an address.
    ///
    /// The facts section above the address list also shows dotted quads — the
    /// network as a CIDR, sometimes a gateway — so a tap is verified by the
    /// Actions menu appearing rather than trusted. A fact row swallows the tap
    /// and the loop moves on.
    @MainActor
    private func openFirstAddressRow(_ app: XCUIApplication) -> Bool {
        for _ in 0..<2 {
            // Built fresh each pass: an NSPredicate is not Sendable, and one
            // bound outside the loop cannot be handed to `matching` twice
            // under Swift 6 region checking.
            let matches = app.cells.staticTexts.matching(
                NSPredicate(format: "label MATCHES %@", "(\\d{1,3}\\.){3}\\d{1,3}"))
            for index in 0..<min(matches.count, 6) {
                let candidate = matches.element(boundBy: index)
                guard candidate.exists, candidate.isHittable else { continue }
                candidate.tap()
                if app.buttons["Actions"].waitForExistence(timeout: 5) { return true }
            }
            // The Addresses section may be below the fold — and lazily absent.
            app.swipeUp()
        }
        return false
    }

    // MARK: - The walk

    @MainActor
    func testCaptureEverySurface() throws {
        let app = XCUIApplication()
        // The dark set is forced through the app's own capture hook — see
        // `SpatiumDDIApp.forcedScheme`. Flipping the simulator with
        // `simctl ui … appearance dark` (or the `-AppleInterfaceStyle`
        // argument domain) looks like it should work, and quietly doesn't
        // reach a test-managed launch — producing a "dark" run of perfectly
        // light captures.
        if (ProcessInfo.processInfo.environment["SPATIUM_APPEARANCE"] ?? "")
            .caseInsensitiveCompare("dark") == .orderedSame
        {
            app.launchEnvironment["SPATIUM_FORCE_APPEARANCE"] = "dark"
        }
        app.launch()

        startAtConnectScreen(app)
        capture(app, "01-connect")

        enterAddress(app, host)

        // A Tailscale or public host presents a chain the system already
        // trusts, so no challenge appears. A private CA does — approve it, the
        // way an operator would.
        if app.staticTexts["Verify Certificate"].waitForExistence(timeout: 25) {
            capture(app, "02-verify-certificate")
            app.buttons["Trust"].tap()
        }

        // The Status section carrying Continue is at the foot of a lazy Form:
        // on a phone it can be below the fold, which to the accessibility tree
        // is the same as not existing.
        let proceed = app.buttons["Continue"]
        if !proceed.waitForExistence(timeout: 25) { app.swipeUp() }
        XCTAssertTrue(proceed.waitForExistence(timeout: 10), "Server never became reachable")
        proceed.tap()

        XCTAssertTrue(
            app.navigationBars["Sign In"].waitForExistence(timeout: 15),
            "A trusted server should lead to sign-in"
        )
        capture(app, "03-sign-in")

        // The field is secure by default; the reveal toggle turns it into a
        // plain one, and typing into a SecureField is unreliable under XCUITest.
        let reveal = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Reveal'")).firstMatch
        if reveal.exists { reveal.tap() }
        let field =
            app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "No token field")
        field.tap()
        field.typeText(token)

        app.buttons["Sign In"].tap()

        // Signing in lands on the sidebar menu, deliberately — see
        // SignedInView. That, not a pushed screen, is the signed-in state.
        XCTAssertTrue(
            app.navigationBars["Menu"].waitForExistence(timeout: 40),
            "Signing in should land on the menu"
        )
        Thread.sleep(forTimeInterval: 1)
        capture(app, "04-menu")

        // The overview fires its rollup calls concurrently; give them time to
        // settle or the capture is a page of spinners.
        captureSection(app, "Overview", as: "05-overview", settle: 6)
        captureSection(app, "Alerts", as: "06-alerts")

        // IPAM, drilled to the bottom of the tree: space → block → subnet →
        // address, with the allocate sheet and the typed delete gate on the
        // way. Both sheets are cancelled — see the type comment.
        if openSection(app, "IPAM") {
            _ = app.navigationBars["IP Spaces"].waitForExistence(timeout: 10)
            Thread.sleep(forTimeInterval: 2)
            capture(app, "07-ipam-spaces")

            if descend(app, hint: hints["IPAM_SPACE"]), descend(app, hint: hints["IPAM_BLOCK"]) {
                Thread.sleep(forTimeInterval: 1.5)
                capture(app, "08-ipam-subnets")

                if descend(app, hint: hints["IPAM_SUBNET"]) {
                    Thread.sleep(forTimeInterval: 2)
                    capture(app, "09-ipam-subnet")

                    let allocate = app.buttons["Allocate Address"]
                    if allocate.waitForExistence(timeout: 5) {
                        allocate.tap()
                        if app.navigationBars["Allocate Address"].waitForExistence(timeout: 10) {
                            Thread.sleep(forTimeInterval: 2.5)
                            capture(app, "10-ipam-allocate")
                            app.buttons["Cancel"].tap()
                        }
                    }

                    if openFirstAddressRow(app) {
                        Thread.sleep(forTimeInterval: 2)
                        capture(app, "11-ipam-address")

                        app.buttons["Actions"].tap()
                        let delete = app.buttons["Delete"]
                        if delete.waitForExistence(timeout: 4) {
                            delete.tap()
                            if app.navigationBars["Delete this address?"].waitForExistence(timeout: 8) {
                                Thread.sleep(forTimeInterval: 1)
                                capture(app, "12-ipam-delete-gate")
                                app.buttons["Cancel"].tap()
                            }
                        }
                    }
                }
            }
        }

        // DNS, drilled to a zone's records and the new-record sheet.
        if openSection(app, "DNS") {
            Thread.sleep(forTimeInterval: 2)
            capture(app, "13-dns-groups")

            if descend(app, hint: hints["DNS_GROUP"]) {
                Thread.sleep(forTimeInterval: 1.5)
                capture(app, "14-dns-zones")

                if descend(app, hint: hints["DNS_ZONE"]) {
                    Thread.sleep(forTimeInterval: 2)
                    capture(app, "15-dns-records")

                    let newRecord = app.buttons["New Record"]
                    if newRecord.waitForExistence(timeout: 5) {
                        newRecord.tap()
                        if app.navigationBars["New Record"].waitForExistence(timeout: 10) {
                            Thread.sleep(forTimeInterval: 1)
                            capture(app, "16-dns-new-record")
                            app.buttons["Cancel"].tap()
                        }
                    }
                }
            }
        }

        // DHCP, drilled to one server's health and traffic chart. Hint this
        // one especially: a demo estate's first row is often the unreachable
        // Windows server, whose detail screen has no chart to show.
        if openSection(app, "DHCP") {
            Thread.sleep(forTimeInterval: 2.5)
            capture(app, "17-dhcp-servers")

            if descend(app, hint: hints["DHCP_SERVER"]) {
                Thread.sleep(forTimeInterval: 4)
                capture(app, "18-dhcp-server")
            }
        }

        captureSection(app, "DHCP Log", as: "19-dhcp-log", settle: 3.5)
        captureSection(app, "Client Lookup", as: "20-client-lookup", settle: 1.5)
        captureSection(app, "New Devices", as: "21-new-devices")
        captureSection(app, "Domains", as: "22-domains")
        captureSection(app, "Certificates", as: "23-certificates")

        // Search needs a query before it shows anything worth keeping.
        if openSection(app, "Search") {
            let searchField = app.searchFields.firstMatch
            if searchField.waitForExistence(timeout: 8) {
                searchField.tap()
                searchField.typeText("10")
                Thread.sleep(forTimeInterval: 3.5)
                capture(app, "24-search")
            }
        }

        captureSection(app, "Audit Log", as: "25-audit")
        captureSection(app, "Server", as: "26-server", settle: 2)
        captureSection(app, "About", as: "27-about", settle: 1)

        // Leave the device as it was found: signed out, so the sign-in flow
        // tests that share this simulator start from their own known state.
        if openSection(app, "Server") {
            let signOut = app.buttons["Sign Out"]
            if !signOut.waitForExistence(timeout: 5) { app.swipeUp() }
            if signOut.waitForExistence(timeout: 5) { signOut.tap() }
        }
    }
}

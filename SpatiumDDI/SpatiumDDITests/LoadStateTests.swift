//
//  LoadStateTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

@Suite("Load state")
@MainActor
struct LoadStateTests {
    private func describe<Value>(_ state: LoadState<Value>) -> String {
        switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded: "loaded"
        case .failed(let message): "failed(\(message.englishText))"
        }
    }

    @Test("A successful fetch loads")
    func loads() async {
        let state = await LoadState<Int>.fetching { 42 }
        guard case .loaded(let value) = state else {
            Issue.record("expected .loaded, got \(describe(state))")
            return
        }
        #expect(value == 42)
    }

    @Test("A thrown status becomes a message an operator can act on")
    func statusBecomesMessage() async {
        let state = await LoadState<Int>.fetching { throw APIStatusError(status: 403) }
        guard case .failed(let message) = state else {
            Issue.record("expected .failed, got \(describe(state))")
            return
        }
        #expect(message.englishText.contains("permission"))
    }

    /// Maintenance mode never blocks a read, so a read's 503 is something else
    /// — a proxy with its backend down. Calling it a change window sends the
    /// operator to wait out a window that isn't open.
    @Test("A 503 on a read is not reported as a change window")
    func read503IsNotMaintenance() async {
        let state = await LoadState<Int>.fetching { throw APIStatusError(status: 503) }
        guard case .failed(let message) = state else {
            Issue.record("expected .failed, got \(describe(state))")
            return
        }
        #expect(!message.englishText.contains("change window"))
        #expect(message.englishText.contains("503"))
    }

    /// The bug this guards against: cancellation arriving as `URLError.cancelled`
    /// rather than `CancellationError`.
    ///
    /// By the time a `.task` is cancelled the request is inside URLSession, so
    /// what comes back is a `URLError` — which a `catch is CancellationError`
    /// misses entirely, flashing the word "cancelled" as a failure over a screen
    /// the operator has already navigated away from.
    @Test("A cancelled fetch reports no state, even when URLSession calls it an error")
    func cancellationIsNotAFailure() async {
        let task = Task { @MainActor in
            await LoadState<Int>.fetching {
                // Spin until cancellation actually lands, so the test does not
                // race the closure, then fail the way URLSession really does.
                while !Task.isCancelled { await Task.yield() }
                throw URLError(.cancelled)
            }
        }
        task.cancel()
        let state = await task.value
        guard case .idle = state else {
            Issue.record("a cancelled fetch should leave no state, got \(describe(state))")
            return
        }
    }

    @Test("A genuine transport failure is still reported")
    func transportFailureIsReported() async {
        let state = await LoadState<Int>.fetching { throw URLError(.timedOut) }
        guard case .failed(let message) = state else {
            Issue.record("expected .failed, got \(describe(state))")
            return
        }
        #expect(message.englishText.contains("didn't respond"))
    }
}

@Suite("Feature-module errors")
struct FeatureModuleErrorTests {

    /// The platform answers 404 from every endpoint of a disabled module, with
    /// the module named in the body. Reporting the generic 404 message —
    /// "it may have been deleted" — tells an operator their data is gone, which
    /// is both wrong and the kind of wrong that starts an incident.
    @Test(
        "A disabled module is named, not reported as a deletion",
        arguments: [
            ("Feature 'network.vrf' is disabled.", "network.vrf"),
            ("Feature 'governance.approvals' is disabled.", "governance.approvals"),
            ("Feature 'security.tls_certs' is disabled.", "security.tls_certs"),
        ]
    )
    func namesTheModule(detail: String, module: String) {
        let error = APIStatusError(status: 404, detail: detail)
        #expect(error.disabledFeatureModule == module)

        let message = APIErrorMessage.describe(error).englishText
        #expect(message.contains(module))
        #expect(!message.contains("deleted"), "a disabled module is not a deletion")
    }

    @Test("A genuine 404 still reads as one")
    func genuineNotFound() {
        let error = APIStatusError(status: 404, detail: "Not Found")
        #expect(error.disabledFeatureModule == nil)
        #expect(APIErrorMessage.describe(error).englishText.contains("Not Found"))
    }

    @Test("A 404 with no body falls back to the generic wording")
    func bodilessNotFound() {
        let error = APIStatusError(status: 404)
        #expect(error.disabledFeatureModule == nil)
        #expect(APIErrorMessage.describe(error).englishText.contains("deleted"))
    }

    // The gate fails open: a non-admin cannot read /admin/feature-modules, and
    // hiding half the app because a permission check failed would be worse than
    // letting each screen report its own 404.
    @Test("An unknown module list hides nothing")
    @MainActor
    func unknownListHidesNothing() {
        let modules = FeatureModules()
        #expect(modules.isAvailable("network.vrf"))
        #expect(modules.isAvailable(nil))
    }
}

@Suite("Cancellation is never shown raw")
struct CancellationMessageTests {

    /// This exact string reached a screen: "The operation couldn't be completed.
    /// (Swift.CancellationError error 1.)" on the IPAM list, because that view
    /// still had its own `catch` instead of going through `LoadState.fetching`.
    /// Swift's own error text is never something to put in front of an operator.
    @Test("A CancellationError never renders as Swift's own description")
    func cancellationIsNotRaw() {
        let message = APIErrorMessage.describe(CancellationError()).englishText
        #expect(!message.contains("CancellationError"))
        #expect(!message.contains("couldn't be completed"))
        #expect(message == "The request was cancelled.")
    }

    @Test("A cancelled URL request is not raw either")
    func urlCancellationIsNotRaw() {
        let message = APIErrorMessage.describe(URLError(.cancelled)).englishText
        #expect(!message.contains("NSURLError"))
        #expect(message.contains("cancelled"))
    }

    @Suite("Server text is never interpreted")
    struct ServerTextTests {
        /// The finding this exists for: routing a server's `detail` through a
        /// localised value puts it on SwiftUI's Markdown-parsing path, so a
        /// compromised or MITM'd control plane could render a **tappable link**
        /// inside the app's own error banner — in an app holding a Keychain token.
        /// CLAUDE.md expects HTTP-only lab installs, so that reach is not theoretical.
        @Test(
            "A detail that looks like Markdown stays server text",
            arguments: [
                "[Contact support](https://phish.example/reset)",
                "[click me](javascript:alert(1))",
                "https://ddi.internal.example/x",
                "Zone `example.com` is locked",
                "Delete **all** records",
            ]
        )
        func detailIsNeverParsed(_ detail: String) {
            let message = APIErrorMessage.describe(APIStatusError(status: 403, detail: detail))
            guard case .server(let text) = message else {
                Issue.record("server detail must be .server, got \(message)")
                return
            }
            // Verbatim: character-for-character what the server sent, so nothing
            // downstream can parse it into a link or strip its punctuation.
            #expect(text == detail)
            #expect(message.englishText == detail)
        }

        /// The second half of the same finding: `LocalizedStringResource(stringLiteral:)`
        /// sets the resource's *key*, so a `detail` colliding with one of this app's
        /// own keys would render that key's translation instead of the server's
        /// reason — the opposite of showing a 403 honestly.
        @Test(
            "A detail colliding with an app key still shows the server's words",
            arguments: ["Access", "Status", "Try Again", "Nothing here", "Trust"]
        )
        func detailDoesNotCollideWithCatalogue(_ detail: String) {
            let message = APIErrorMessage.describe(APIStatusError(status: 404, detail: detail))
            guard case .server(let text) = message else {
                Issue.record("server detail must be .server, got \(message)")
                return
            }
            #expect(text == detail)
        }

        /// This app's own wording goes the other way — it must be translatable.
        @Test("The app's own messages are localisable")
        func appMessagesAreLocalised() {
            guard case .app = APIErrorMessage.describe(status: 403) else {
                Issue.record("a 403 message is this app's wording and must be .app")
                return
            }
            guard
                case .app = APIErrorMessage.describe(
                    APIStatusError(status: 404, detail: "Feature 'network.vrf' is disabled."))
            else {
                Issue.record("the disabled-module message is this app's wording")
                return
            }
        }
    }
}

//
//  APIErrorMessage.swift
//  SpatiumDDI
//

import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Turns a client error into something an operator can act on.
///
/// Non-negotiable #4: a 403 is shown honestly, never swallowed. Non-negotiable
/// #5: a 503 is a change window, not a network failure, and is never retried
/// into automatically.
nonisolated enum APIErrorMessage {
    /// The message for a status the call site caught, preferring what the
    /// server actually said over this app's generic wording.
    static func describe(_ error: APIStatusError) -> FailureMessage {
        // A disabled feature module is a 404 that means something specific and
        // benign. The generic 404 text — "it may have been deleted" — would
        // tell an operator their data is gone, which is both wrong and the kind
        // of wrong that starts an incident.
        if let module = error.disabledFeatureModule {
            return .app(
                "The \(module) feature module is switched off on this server, so there's nothing here to show."
            )
        }
        if let detail = error.detail, Self.detailBearingStatuses.contains(error.status) {
            // The server's own words, and untrusted input. `.server` renders
            // them verbatim: no Markdown parsing, so a `detail` carrying a
            // link cannot become a tappable one, and no catalogue lookup, so a
            // detail that collides with one of this app's own keys cannot
            // render as unrelated chrome.
            return .server(detail)
        }
        return describe(status: error.status)
    }

    /// Statuses whose `detail` says something the generic wording cannot.
    ///
    /// 409 and 422 matter most on a write: "Address 10.0.1.7 is already
    /// allocated in this subnet" and "mac_address is required when status is
    /// 'static_dhcp'" are the whole answer, and replacing either with "the
    /// server rejected that request" throws away the only actionable sentence.
    private static let detailBearingStatuses: Set<Int> = [400, 403, 404, 409, 422]

    /// The message for a failed **write**.
    ///
    /// Split from the read wording because the same statuses mean different
    /// things when something was being changed. "You don't have permission to
    /// read this" on a rejected allocation is simply the wrong sentence, and a
    /// 503 needs to say that nothing was changed — non-negotiable #5 forbids
    /// retrying into a change window, so the operator has to know where they
    /// stand rather than wonder whether it half-landed.
    static func describeWrite(_ error: APIStatusError) -> FailureMessage {
        if let module = error.disabledFeatureModule {
            return .app("The \(module) feature module is switched off on this server.")
        }
        if error.status == 503 {
            guard error.isMaintenance else {
                // Not the platform's refusal, so the request may have reached
                // it. Saying "nothing was changed" here could be false.
                return .app(
                    "The server was unavailable (HTTP 503), so it isn't known whether this change landed. Check before trying again."
                )
            }
            // The platform refuses before any handler runs, so nothing was
            // changed. The detail is the window's own message when the
            // operator who opened it wrote one.
            if let detail = error.detail {
                return .app("Nothing was changed — the server is in a change window: \(detail)")
            }
            return .app(
                "The server is in a change window and nothing was changed. Try again once it's finished.")
        }
        if let detail = error.detail, detailBearingStatuses.contains(error.status) {
            return .server(detail)
        }
        switch error.status {
        case 403:
            return .app(
                "You don't have permission to make this change. Ask an administrator to review your role."
            )
        case 404:
            return .app("The server doesn't have this any more — it may have been deleted.")
        case 409:
            return .app("That conflicts with something already on the server. Nothing was changed.")
        default:
            return describe(status: error.status)
        }
    }

    static func describe(_ error: any Error) -> FailureMessage {
        if let status = error as? APIStatusError { return describe(status) }

        // Cancellation is never news. It reached a screen once — as
        // "The operation couldn't be completed. (Swift.CancellationError error
        // 1.)" on the IPAM list — because a view still hand-rolled its own
        // catch. Callers should route through `LoadState.fetching`, which folds
        // cancellation into `.idle`, but this is the backstop: raw Swift error
        // text is never something to show an operator.
        if error is CancellationError { return .app("The request was cancelled.") }
        if let client = error as? ClientError {
            if let status = (client.response)?.status.code {
                return describe(status: status)
            }
            return describeTransport(client.underlyingError)
        }
        return describeTransport(error)
    }

    /// The message for a status the generated client reported directly.
    ///
    /// Not private: the generated `.ok` shorthand throws `RuntimeError`, not
    /// `ClientError`, for any status the document doesn't declare — and this
    /// document declares only 200 and 422. A 401, 403 or 503 therefore arrives
    /// as `Output.undocumented(statusCode:)`, and only the call site can see it.
    static func describe(status: Int) -> FailureMessage {
        switch status {
        case 401:
            .app("Your session is no longer valid. Sign in again.")
        case 403:
            .app("You don't have permission to read this. Ask an administrator to review your role.")
        case 404:
            .app("The server doesn't have this any more — it may have been deleted.")
        case 422:
            .app("The server rejected that request as invalid.")
        case 429:
            .app("The server is rate-limiting requests. Wait a moment and try again.")
        // Not "a change window": maintenance mode never blocks a read, so a
        // read that gets a 503 has met something else — a proxy with its
        // backend down, or a restore in progress.
        case 503:
            .app("The server isn't serving right now (HTTP 503). Try again in a moment.")
        case 500...599:
            .app("The server reported an error (HTTP \(status)).")
        default:
            .app("Unexpected response from the server (HTTP \(status)).")
        }
    }

    private static func describeTransport(_ error: any Error) -> FailureMessage {
        let nsError = error as NSError
        // Foundation has already localised this, so re-keying it would look it
        // up a second time in a catalogue that does not contain it.
        guard nsError.domain == NSURLErrorDomain else {
            return .server(error.localizedDescription)
        }
        switch nsError.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .app("Can't reach the server — check this device's network.")
        case NSURLErrorTimedOut:
            return .app("The server didn't respond in time.")
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return .app("This device has no network connection.")
        case NSURLErrorCancelled:
            // Normally intercepted by the task-cancellation check before it can
            // reach a screen; this is for the case where the session itself was
            // invalidated under an in-flight request.
            return .app("The request was cancelled.")
        default:
            return .server(error.localizedDescription)
        }
    }
}

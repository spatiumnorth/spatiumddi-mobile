//
//  ServerTrustDelegate.swift
//  SpatiumDDI
//

import Foundation
import Security
import os

/// Decides whether to complete a TLS handshake with a self-hosted control plane.
///
/// Three outcomes, in order:
///   1. The chain validates against the system anchors — proceed silently.
///   2. It doesn't, but the leaf matches a fingerprint this operator already
///      approved for this exact origin — proceed.
///   3. Anything else — refuse the handshake and record what was presented, so
///      the UI can show it and ask.
///
/// Case 3 refuses first and asks afterwards. URLSession wants an answer on a
/// background queue immediately and a human cannot be consulted in that window,
/// so the connection is dropped and retried once approval exists. There is no
/// point at which an unapproved certificate is accepted.
///
/// It also refuses every redirect. The API has no legitimate one, and a 3xx
/// followed to another origin would carry the request there — a write's body
/// with it on a 307 — to a host the operator never approved, and which step 2
/// would wave through if it presented the pinned certificate, since the pin is
/// checked against this delegate's origin rather than the one being visited.
final class ServerTrustDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let address: ServerAddress
    private let trustStore: TrustStore
    /// The certificate that caused the most recent refusal, for the UI to display.
    private let refused = OSAllocatedUnfairLock<CertificateInfo?>(initialState: nil)

    init(address: ServerAddress, trustStore: TrustStore) {
        self.address = address
        self.trustStore = trustStore
    }

    /// Set when a handshake was refused for want of operator approval.
    var refusedCertificate: CertificateInfo? { refused.withLock { $0 } }

    /// Hands the 3xx itself back to the caller, where it surfaces as the
    /// status it is rather than as whatever the other host said.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 1. Publicly valid chain, hostname included. Nothing to ask about.
        if SecTrustEvaluateWithError(trust, nil) {
            refused.withLock { $0 = nil }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard let presented = CertificateInfo(trust: trust, requestedHost: challenge.protectionSpace.host)
        else {
            refused.withLock { $0 = nil }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 2. Exactly the certificate the operator approved for this origin.
        //
        // This intentionally also covers a hostname mismatch. Appliance certs
        // routinely carry no SAN for the IP literal they're reached at, and
        // "these exact bytes, approved by name" is a stronger assertion than a
        // name match against an untrusted chain would have been.
        if let pinned = trustStore.pinnedFingerprint(for: address), pinned == presented.fingerprint {
            refused.withLock { $0 = nil }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // 3. Unknown. Refuse, and leave the evidence for the operator to judge.
        refused.withLock { $0 = presented }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

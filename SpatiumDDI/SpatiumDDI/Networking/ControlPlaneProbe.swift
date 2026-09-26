//
//  ControlPlaneProbe.swift
//  SpatiumDDI
//

import Foundation

/// What came back from trying to reach a control plane.
nonisolated enum ProbeOutcome: Sendable, Equatable {
    /// TLS completed and a SpatiumDDI health endpoint answered.
    case reachable(status: Int)
    /// A change window is in progress. Never retried automatically — the
    /// operator is told, and decides.
    case maintenance(retryAfter: TimeInterval?)
    /// The server's certificate isn't trusted and hasn't been approved here.
    case trustRequired(CertificateInfo)
    case failed(ConnectionError)
}

/// The result of presenting a token to the control plane.
nonisolated enum AuthOutcome: Sendable, Equatable {
    /// The server accepted the token.
    case authenticated
    /// The token is absent, expired, or revoked.
    case rejected
    /// The token is valid but this account may not read permissions. Still a
    /// successful authentication, and non-negotiable #4 says show it honestly
    /// rather than swallow it into a blank screen.
    case forbidden
    case maintenance(retryAfter: TimeInterval?)
    case trustRequired(CertificateInfo)
    case failed(ConnectionError)
}

nonisolated enum ConnectionError: Error, Sendable, Equatable, LocalizedError {
    case cannotFindHost(String)
    case cannotConnect(String)
    case timedOut
    case notAControlPlane(status: Int)
    /// A 503 that is not a change window — see `ControlPlaneProbe.isMaintenance`.
    case unavailable
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .cannotFindHost(let host):
            "Can't find \(host). Check the name, and that this device is on a network that can resolve it."
        case .cannotConnect(let host):
            "Nothing answered at \(host). Check the port, and that the control plane is running."
        case .timedOut:
            "The server didn't respond in time."
        case .notAControlPlane(let status):
            "That address answered with HTTP \(status), which isn't a SpatiumDDI health response. Check you have the right host and port."
        case .unavailable:
            "The server answered but isn't serving right now (HTTP 503). It may be restarting, or a proxy in front of it can't reach it."
        case .transport(let detail):
            detail
        }
    }
}

/// Establishes whether an address is a reachable SpatiumDDI control plane.
///
/// Reads status codes only and never decodes a response body — the app has no
/// hand-written models by policy (CLAUDE.md non-negotiable #1), and none of what
/// this needs to know lives in the payload anyway. When `openapi.json` ships, the
/// version handshake layers onto this transport rather than replacing it.
nonisolated struct ControlPlaneProbe: Sendable {
    let trustStore: TrustStore

    init(trustStore: TrustStore = TrustStore()) {
        self.trustStore = trustStore
    }

    /// Builds a session that applies this app's trust policy.
    ///
    /// Ephemeral: no on-disk cache, cookie jar or credential store. Non-negotiable
    /// #3 — a stale-but-plausible view of production networking is worse than none.
    private func makeSession(for address: ServerAddress) -> (URLSession, ServerTrustDelegate) {
        let delegate = ServerTrustDelegate(address: address, trustStore: trustStore)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return (URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil), delegate)
    }

    /// Presents a token and reports whether the server accepted it.
    ///
    /// Reads the status code and nothing else — the permissions payload needs
    /// the generated client, but "is this token good" does not.
    func validateToken(_ token: String, for address: ServerAddress) async -> AuthOutcome {
        let (session, delegate) = makeSession(for: address)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: address.apiBaseURL.appending(path: "auth/me/permissions"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.transport("The server sent a response the app couldn't read."))
            }
            switch http.statusCode {
            case 200...299: return .authenticated
            case 401: return .rejected
            case 403: return .forbidden
            case 503 where Self.isMaintenance(body):
                return .maintenance(retryAfter: Self.retryAfter(from: http))
            case 503: return .failed(.unavailable)
            default: return .failed(.notAControlPlane(status: http.statusCode))
            }
        } catch {
            if let presented = delegate.refusedCertificate { return .trustRequired(presented) }
            return .failed(Self.classify(error, address: address))
        }
    }

    func probe(_ address: ServerAddress) async -> ProbeOutcome {
        let (session, delegate) = makeSession(for: address)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: address.healthURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.transport("The server sent a response the app couldn't read."))
            }

            switch http.statusCode {
            case 200...299:
                return .reachable(status: http.statusCode)
            case 503 where Self.isMaintenance(body):
                return .maintenance(retryAfter: Self.retryAfter(from: http))
            case 503:
                return .failed(.unavailable)
            default:
                return .failed(.notAControlPlane(status: http.statusCode))
            }
        } catch {
            // A refused handshake surfaces here as a cancellation. The delegate
            // recorded what was presented, and that is the real story.
            if let presented = delegate.refusedCertificate {
                return .trustRequired(presented)
            }
            return .failed(Self.classify(error, address: address))
        }
    }

    /// Whether a 503 is the platform's change-window refusal.
    ///
    /// Not every 503 is. The platform's maintenance middleware marks its own —
    /// `{"detail": "...", "maintenance": true}` — while a proxy whose backend
    /// is down, or the platform mid-restore, sends a 503 without the marker.
    /// Calling those a change window tells the operator to wait out something
    /// that isn't happening, while the server they need is down.
    ///
    /// One flag read from an error body, like `APIStatusError`'s envelope — not
    /// a model of any documented response.
    static func isMaintenance(_ body: Data) -> Bool {
        struct Marker: Decodable { let maintenance: Bool? }
        return (try? JSONDecoder().decode(Marker.self, from: body))?.maintenance == true
    }

    /// `Retry-After` is either a delay in seconds or an HTTP-date.
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard
            let value = response.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespaces), !value.isEmpty
        else { return nil }

        if let seconds = TimeInterval(value) { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func classify(_ error: Error, address: ServerAddress) -> ConnectionError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .transport(error.localizedDescription) }

        switch nsError.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .cannotFindHost(address.displayName)
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return .cannotConnect(address.displayName)
        case NSURLErrorTimedOut:
            return .timedOut
        default:
            return .transport(error.localizedDescription)
        }
    }
}

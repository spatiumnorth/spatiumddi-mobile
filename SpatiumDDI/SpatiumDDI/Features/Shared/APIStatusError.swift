//
//  APIStatusError.swift
//  SpatiumDDI
//

import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A status the generated client reported as a case rather than a throw.
///
/// The document declares only 200 and 422, so every other status — 401, 403,
/// 404, 503 — arrives as `Output.undocumented(statusCode:)`. Only the call site
/// can see it, and the call site's job is to turn it into this so one error path
/// carries both it and a genuine transport failure.
///
/// Without this the natural shape is `.ok` shorthand, which collapses all of
/// them into an opaque `RuntimeError` and makes non-negotiable #4's honest 403
/// and #5's maintenance window unreachable.
nonisolated struct APIStatusError: Error {
    let status: Int
    /// What the server said in its `detail` field, where it said anything.
    ///
    /// This matters most for 404. The platform returns 404 both for "no such
    /// row" and for "that feature module is switched off", and the body is the
    /// only thing that tells them apart — `{"detail": "Feature 'network.vrf' is
    /// disabled."}`. Reporting the generic 404 message for the second case
    /// tells an operator their data was deleted, which is alarming and wrong.
    let detail: String?

    /// The soft-collision payload a 409 carries, when it carries one.
    ///
    /// The platform uses 409 for two different answers and the body is the only
    /// thing that separates them:
    ///
    /// - a **hard** conflict (`Address 10.0.1.7 is already allocated in this
    ///   subnet`) — a plain `detail` string, and the end of the matter;
    /// - a **soft**, overridable warning — `{"warnings": [...],
    ///   "requires_confirmation": true}`, which the caller may re-send with
    ///   `force=true` after the operator has read it.
    ///
    /// Collapsing the two would either turn a real "someone took it" into a
    /// button that reissues the same doomed request, or turn a duplicate
    /// hostname into a dead end when the operator meant a round-robin A record.
    let collision: Collision?

    /// Whether this is the platform's change-window refusal, which marks
    /// itself `"maintenance": true`. Any other 503 — a proxy with its backend
    /// down, a restore resetting connections — says nothing about whether a
    /// write landed. See `ControlPlaneProbe.isMaintenance`.
    let isMaintenance: Bool

    nonisolated struct Collision: Equatable, Sendable {
        let requiresConfirmation: Bool
        let warnings: [CollisionWarning]
    }

    init(
        status: Int, detail: String? = nil, collision: Collision? = nil, isMaintenance: Bool = false
    ) {
        self.status = status
        self.detail = detail
        self.collision = collision
        self.isMaintenance = isMaintenance
    }

    /// Reads the `detail` out of an undocumented response body.
    init(status: Int, payload: UndocumentedPayload) async {
        await self.init(status: status, body: payload.body)
    }

    /// Reads the `detail` out of an error body.
    ///
    /// Bounded: a body this large is not a FastAPI error envelope, and an error
    /// path is the wrong place to buffer an unbounded stream.
    init(status: Int, body: HTTPBody?) async {
        guard let body,
            let data = try? await Data(collecting: body, upTo: 8 * 1024)
        else {
            self.init(status: status)
            return
        }

        // A string detail and an object detail are both valid FastAPI error
        // envelopes, so both are tried rather than assuming the shape.
        if let envelope = try? JSONDecoder().decode(DetailEnvelope.self, from: data),
            !envelope.detail.isEmpty
        {
            self.init(
                status: status, detail: envelope.detail,
                isMaintenance: envelope.maintenance == true)
            return
        }
        if let envelope = try? JSONDecoder().decode(CollisionEnvelope.self, from: data) {
            self.init(
                status: status,
                collision: .init(
                    requiresConfirmation: envelope.detail.requiresConfirmation ?? false,
                    warnings: envelope.detail.warnings
                )
            )
            return
        }
        self.init(status: status)
    }

    private struct DetailEnvelope: Decodable {
        let detail: String
        let maintenance: Bool?
    }

    private struct CollisionEnvelope: Decodable {
        struct Detail: Decodable {
            let warnings: [CollisionWarning]
            let requiresConfirmation: Bool?

            enum CodingKeys: String, CodingKey {
                case warnings
                case requiresConfirmation = "requires_confirmation"
            }
        }
        let detail: Detail
    }

    /// Recovers a real status from a failure inside the generated client.
    ///
    /// The document declares 422 as `HTTPValidationError` — `{"detail": [...]}`
    /// — but the platform also raises `HTTPException(422, detail="mac_address
    /// is required when status is 'static_dhcp'")`, whose `detail` is a
    /// **string**. The generated deserialiser decodes eagerly, so that body
    /// fails to decode and the call throws a `ClientError` wrapping a
    /// `DecodingError` instead of returning `.unprocessableContent`.
    ///
    /// Left alone, the single most useful sentence on a write path — the one
    /// saying exactly what was wrong with the request — is replaced by an
    /// opaque decoding message. `ClientError` keeps the response and its body,
    /// and the URLSession transport buffers with `.multiple` iteration
    /// behaviour, so the body can be read again here.
    static func recovered(from error: any Error) async -> APIStatusError? {
        guard let clientError = error as? ClientError,
            let status = clientError.response?.status.code
        else { return nil }
        return await APIStatusError(status: status, body: clientError.responseBody)
    }

    /// The feature module this error names, if it named one.
    ///
    /// `Feature 'network.vrf' is disabled.` → `network.vrf`
    var disabledFeatureModule: String? {
        guard let detail, detail.hasPrefix("Feature "),
            let start = detail.firstIndex(of: "'"),
            let end = detail[detail.index(after: start)...].firstIndex(of: "'")
        else { return nil }
        return String(detail[detail.index(after: start)..<end])
    }
}

extension LoadState {
    /// Runs a fetch, folding a thrown status and a transport failure into `.failed`.
    ///
    /// The call site still switches over the generated `Output` — that switch is
    /// the only place a 403 or a 503 is distinguishable — but it throws instead
    /// of assigning, so the four states are produced in one place.
    static func fetching(_ operation: () async throws -> Value) async -> LoadState<Value> {
        do {
            return .loaded(try await operation())
        } catch let error as APIStatusError {
            return .failed(APIErrorMessage.describe(error))
        } catch {
            if let recovered = await APIStatusError.recovered(from: error) {
                return .failed(APIErrorMessage.describe(recovered))
            }
            // A cancelled fetch is a view going away or a refresh superseding
            // this one, and reporting it would flash an error over a screen the
            // operator has already left.
            //
            // Checked on the task rather than by matching `CancellationError`:
            // the request is in URLSession by the time cancellation lands, so
            // what actually comes back is `URLError.cancelled` wrapped in a
            // `ClientError` — which the type match misses entirely, leaving the
            // word "cancelled" rendered as a failure.
            if Task.isCancelled { return .idle }
            return .failed(APIErrorMessage.describe(error))
        }
    }
}

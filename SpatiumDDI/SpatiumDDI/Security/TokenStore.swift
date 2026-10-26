//
//  TokenStore.swift
//  SpatiumDDI
//

import Foundation
import LocalAuthentication
import Security

/// What stands between a stored token and anyone holding the device.
///
/// Non-negotiable #2 says tokens live in the Keychain, on this device only.
/// Whether opening the app *also* asks for the device owner is the operator's
/// choice, per server, and it is off by default: a forced Face ID prompt made
/// the app close to untestable — on the simulator above all — and the
/// Keychain's this-device-only class already keeps the token off backups,
/// other devices and a locked phone.
///
/// When the operator does ask for a gate, this prefers biometry, accepts a
/// passcode, and refuses when there is neither. The distinctions are kept
/// everywhere rather than collapsed into a Bool because the three are not
/// equivalent and the operator is entitled to know which one is holding their
/// token. See `caveat`.
nonisolated enum KeychainProtection: String, Equatable, Sendable, Codable, CaseIterable {
    /// `.biometryCurrentSet` — invalidated the moment enrolment changes.
    case biometrics
    /// `.devicePasscode` — weaker, and survives an enrolment change.
    case passcode
    /// No access control at all: `WhenUnlockedThisDeviceOnly` and nothing on
    /// top. Readable without a prompt by this app whenever the device is
    /// unlocked; never readable while it is locked, never in a backup, never
    /// on another device.
    ///
    /// The default. It is still a Keychain item — never `UserDefaults`, never
    /// a plist — so what it gives up is exactly one thing: someone holding the
    /// phone *unlocked* can open the app and use the token.
    case deviceUnlock

    /// Whether reading the token asks for the device owner first.
    ///
    /// The question every caller actually has. "Is it biometrics or a
    /// passcode" only matters once the answer to this is yes.
    var isGated: Bool { self != .deviceUnlock }

    /// Persisted alongside the item so the protection travels with it.
    ///
    /// A device that gains Face ID after a passcode-only sign-in still holds a
    /// passcode-gated item; only re-sealing upgrades it. Recomputing this
    /// from current device state would therefore report the wrong answer, and
    /// would pick the wrong `LAPolicy` when unsealing — or, for an ungated
    /// item, prompt for a gate that is not there.
    ///
    /// The two original markers keep their spelling, so items written before
    /// the gate became optional read back exactly as they were sealed.
    var marker: Data { Data(rawValue.utf8) }

    init?(marker: Data) {
        guard let raw = String(data: marker, encoding: .utf8) else { return nil }
        self.init(rawValue: raw)
    }

    /// What an item's marker attribute says is guarding it.
    ///
    /// An item written before this app understood passcode protection carries
    /// no marker; those are biometric by construction. An unreadable marker
    /// resolves the same way, and deliberately so: the failure that matters is
    /// mistaking a gated item for an ungated one, which would skip the prompt
    /// its access control still demands. Assuming the strongest gate costs, at
    /// worst, a prompt the item did not need.
    static func stored(marker: Data?) -> KeychainProtection {
        marker.flatMap(KeychainProtection.init(marker:)) ?? .biometrics
    }
}

/// The per-device API token, held in the Keychain on this device only.
///
/// Non-negotiable #2: never `UserDefaults`, never a plist, never a log line.
/// By default the item carries no access control and reads back without a
/// prompt while the device is unlocked. When the operator asks for a gate, it
/// is written with an access control that demands they be present, so the
/// token cannot be read back by anything — including this app — without them.
nonisolated struct TokenStore: Sendable {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "io.spatiumddi.SpatiumDDI") + ".token") {
        self.service = service
    }

    enum StoreError: Error, LocalizedError, Equatable {
        /// Neither biometry nor a passcode — nothing can protect a token here.
        case deviceUnprotected(String)
        case authenticationFailed
        case cancelled
        case notFound
        /// The stored item was invalidated — see `.biometryCurrentSet` below.
        case enrollmentChanged
        /// An ungated item asked for while the device is locked.
        ///
        /// `WhenUnlockedThisDeviceOnly` answers `errSecInteractionNotAllowed`
        /// then, and "Keychain error: user interaction is not allowed" tells
        /// the operator nothing they can act on.
        case deviceLocked
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .deviceUnprotected(let detail):
                return "This device can't store a token securely: \(detail)"
            case .authenticationFailed:
                return "Authentication failed."
            case .cancelled:
                return "Authentication was cancelled."
            case .notFound:
                return "No saved token for this server."
            case .enrollmentChanged:
                return
                    "The saved token was discarded because this device's biometric enrolment changed. Sign in again."
            case .deviceLocked:
                return "The saved token can't be read while this device is locked."
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    private func account(for address: ServerAddress) -> String { "api-token.\(address.pinKey)" }

    // MARK: - What this device can offer

    /// The strongest **gate** available right now, or why there is none.
    ///
    /// Only ever `.biometrics` or `.passcode`: this answers "what would guard
    /// the token if the operator asked for a gate", which is a question about
    /// the device. Whether they asked is a separate input — see
    /// `protection(requiringAuthentication:)`.
    ///
    /// Biometry is preferred. A **lockout** is deliberately still counted as
    /// biometry: `canEvaluatePolicy` refuses after too many failed attempts,
    /// but the enrolment is intact and the lockout clears on the next passcode
    /// unlock. Downgrading a token to passcode protection because of a
    /// temporary lockout would make a transient state permanent.
    static func availableProtection() -> Result<KeychainProtection, StoreError> {
        let context = LAContext()
        var biometryError: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometryError) {
            return .success(.biometrics)
        }
        if (biometryError as? LAError)?.code == .biometryLockout {
            return .success(.biometrics)
        }

        var passcodeError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError) {
            return .success(.passcode)
        }

        // Report the passcode failure, not the biometric one: "no passcode set"
        // is the actionable sentence, and "Face ID not enrolled" would send the
        // operator to fix the wrong thing.
        let detail = passcodeError?.localizedDescription ?? "no passcode is set"
        return .failure(.deviceUnprotected(detail))
    }

    /// The biometric method's own name, for copy. `nil` when there is none.
    ///
    /// Reported independently of `availableProtection()` because the two answer
    /// different questions: this one is about hardware and enrolment, that one
    /// is about what will actually protect the token.
    static func biometryName() -> String? {
        let context = LAContext()
        var error: NSError?
        let usable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        guard usable || (error as? LAError)?.code == .biometryLockout else { return nil }
        return name(of: context.biometryType)
    }

    /// What this hardware *could* do, enrolled or not.
    ///
    /// The difference matters for the passcode-fallback copy. "Face ID isn't
    /// set up on this device" is a sentence the operator can act on; the same
    /// sentence on an iPad with no Face ID hardware sends them looking for a
    /// setting that does not exist. `biometryType` is only meaningful after a
    /// `canEvaluatePolicy` call, whose result is deliberately ignored here —
    /// the question is about the hardware, not the enrolment.
    static func biometryHardwareName() -> String? {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return name(of: context.biometryType)
    }

    private static func name(of type: LABiometryType) -> String? {
        switch type {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    /// How to name the gate in operator-facing copy, whatever it turns out to be.
    static func biometryDescription() -> String {
        biometryName() ?? String(localized: "your passcode")
    }

    // MARK: - Reading what is stored

    /// True when a token exists, checked without prompting anyone.
    ///
    /// Asks only for attributes: an attribute-only query doesn't unseal the
    /// value, so it doesn't trip the access control.
    /// Whether the app should behave as though a token is stored.
    ///
    /// Errs towards **yes**, because the two wrong answers are not equally
    /// bad. Saying "yes" when there is nothing costs one unlock attempt that
    /// fails honestly and drops to sign-in. Saying "no" when the token is
    /// there tells the operator their credential is gone and makes them enrol
    /// a new one — over what may have been a momentary refusal.
    func hasToken(for address: ServerAddress) -> Bool {
        presence(for: address) != .absent
    }

    /// What is actually guarding the stored token, or `nil` if there isn't one.
    ///
    /// Read from the item's own marker — see `KeychainProtection.stored(marker:)`
    /// for why a missing or unreadable one means biometrics, never "ungated".
    func storedProtection(for address: ServerAddress) -> KeychainProtection? {
        guard let attributes = attributes(for: address) else { return nil }
        return .stored(marker: attributes[kSecAttrGeneric as String] as? Data)
    }

    /// Whether a token is stored — and the difference between "no" and
    /// "cannot tell right now", which are not the same answer.
    nonisolated enum Presence: Equatable {
        case present
        case absent
        /// The Keychain refused to say. The item may well be there.
        case unknown(OSStatus)
    }

    /// Looks for the item without prompting for anything.
    ///
    /// **Only `errSecItemNotFound` proves absence.** An item stored
    /// `WhenPasscodeSetThisDeviceOnly` behind an access control answers
    /// `errSecInteractionNotAllowed` when it cannot be reached at that
    /// moment — while the device is locked, or when the query is not allowed
    /// to interact — and reading that as "there is no token" is how a
    /// perfectly good credential comes to be reported missing.
    func presence(for address: ServerAddress) -> Presence {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecReturnAttributes as String: true,
            // **Fail, not Skip.** `kSecUseAuthenticationUISkip` does not mean
            // "answer without prompting" — it means an item that *would* need
            // authentication is silently omitted from the results, which comes
            // back as `errSecItemNotFound` and is indistinguishable from having
            // no token at all. A gated token is behind an access control, so
            // Skip reported every one of them missing on hardware where that
            // control is `.biometryCurrentSet`.
            //
            // `Fail` returns `errSecInteractionNotAllowed` for exactly that
            // case, which is the answer wanted: the item is there, it just
            // cannot be handed over without asking someone first.
            //
            // Still right for an ungated `.deviceUnlock` item, and harmless:
            // there is no access control to trip, so an unlocked device answers
            // `errSecSuccess`. A locked one answers `errSecInteractionNotAllowed`
            // — `.unknown`, which `hasToken` already reads as "probably yes".
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .absent
        default: return .unknown(status)
        }
    }

    private func attributes(for address: ServerAddress) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecReturnAttributes as String: true,
            // Same reasoning as `presence`: Skip hides the very items this is
            // asked about. Attributes still come back under Fail, because
            // reading them is not reading the secret.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    // MARK: - Writing

    /// Which protection a write would use, or why it cannot be had.
    ///
    /// Ungated needs nothing from the device — `WhenUnlockedThisDeviceOnly`
    /// exists with or without a passcode — so only a gated write can be
    /// refused.
    static func protection(requiringAuthentication: Bool) -> Result<KeychainProtection, StoreError> {
        requiringAuthentication ? availableProtection() : .success(.deviceUnlock)
    }

    /// Writes the token, replacing any existing one for this server.
    ///
    /// `requiringAuthentication` is the operator's choice from the sign-in
    /// screen. Off, the item has no access control. On, it gets the strongest
    /// gate the device offers, and the write is refused outright if there is
    /// none — the operator asked for a gate, and storing without one would
    /// quietly give them less than they chose.
    ///
    /// Returns the protection it was actually written with, so the caller can
    /// tell the operator when they got the weaker gate rather than leaving them
    /// to assume Face ID is involved.
    ///
    /// `.biometryCurrentSet` ties the item to the biometric enrolment as it
    /// stands now: adding a face or fingerprint destroys it, and the operator
    /// signs in again. That costs a re-auth, and buys that enrolling a new face
    /// on an unlocked phone cannot silently inherit access to production DNS.
    /// `.devicePasscode` carries no such guarantee — which is exactly why the
    /// difference is surfaced rather than smoothed over.
    @discardableResult
    func save(
        _ token: String, for address: ServerAddress, requiringAuthentication: Bool
    ) throws -> KeychainProtection {
        // Enforced here, not left to callers. SecAccessControlCreateWithFlags
        // will happily mint a `.biometryCurrentSet` policy on a device with no
        // enrolment (the simulator does exactly this), and SecItemAdd then
        // succeeds — storing a token nothing would ever be asked to unlock.
        // A gate the operator asked for is a property of the store, not of its
        // call sites.
        let protection = try Self.protection(requiringAuthentication: requiringAuthentication).get()
        let attributes = try sealedAttributes(token, for: address, behind: protection)

        // Delete first: SecItemUpdate cannot change an item's access control.
        // A fresh sign-in has nothing worth keeping — the token being replaced
        // is the one the operator is replacing — so unlike `reseal` there is
        // nothing to roll back to.
        try? delete(for: address)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        return protection
    }

    /// Why a re-seal failed, and — the part that matters — whether the token
    /// is still in the Keychain afterwards.
    nonisolated struct ResealFailure: Error, Equatable {
        let reason: StoreError
        /// True when the item is still stored behind its **previous**
        /// protection: nothing changed, or the change was rolled back.
        /// False only when both the new item and the rollback were refused,
        /// and the caller's in-memory copy is the last one.
        let tokenRetained: Bool
    }

    /// Moves an existing token behind a different gate.
    ///
    /// The awkward fact is that this cannot be done in place. SecItemUpdate
    /// cannot change an access control, so the item has to be deleted and added
    /// again — and staging the new item first under the same account is not
    /// possible either, because service + account is the item's identity.
    /// There is therefore a moment where the Keychain holds nothing.
    ///
    /// What makes that moment safe:
    ///
    /// 1. Everything that can fail *before* the delete is done before it: the
    ///    device's capability is checked and **both** attribute sets — the new
    ///    one and the one to roll back to — are built first. A gate the device
    ///    cannot offer is refused with the old item untouched.
    /// 2. The delete is checked, not `try?`. If it fails, the old item is still
    ///    there and nothing has changed.
    /// 3. If adding the new item fails, the old one is added straight back,
    ///    behind exactly the protection it had.
    /// 4. Only if that rollback is *also* refused is the token gone from the
    ///    Keychain — and then the failure says so (`tokenRetained == false`),
    ///    the caller still holds the token it passed in, and the session it
    ///    came from carries on. `AppFlowModel` keeps it and offers to save it
    ///    again; nothing here signs the operator out silently.
    ///
    /// `token` must be what is stored now, read back through
    /// `token(for:reason:)` — which, for a gated item, is also what proves the
    /// operator can pass the gate they are about to remove.
    @discardableResult
    func reseal(
        _ token: String, for address: ServerAddress, requiringAuthentication: Bool
    ) throws(ResealFailure) -> KeychainProtection {
        guard let previous = storedProtection(for: address) else {
            throw ResealFailure(reason: .notFound, tokenRetained: false)
        }

        let target: KeychainProtection
        switch Self.protection(requiringAuthentication: requiringAuthentication) {
        case .success(let protection): target = protection
        case .failure(let refusal): throw ResealFailure(reason: refusal, tokenRetained: true)
        }

        // Already there — a no-op is not a reason to open the gap at all.
        guard target != previous else { return previous }

        let sealed: [String: Any]
        let rollback: [String: Any]
        do {
            sealed = try sealedAttributes(token, for: address, behind: target)
            rollback = try sealedAttributes(token, for: address, behind: previous)
        } catch {
            throw ResealFailure(reason: error, tokenRetained: true)
        }

        do {
            try delete(for: address)
        } catch {
            throw ResealFailure(reason: error, tokenRetained: true)
        }

        let status = SecItemAdd(sealed as CFDictionary, nil)
        guard status == errSecSuccess else {
            let restored = SecItemAdd(rollback as CFDictionary, nil) == errSecSuccess
            throw ResealFailure(reason: .keychain(status), tokenRetained: restored)
        }
        return target
    }

    /// The full attribute set for writing `token` behind `protection`.
    ///
    /// Separate from the write so `reseal` can build every set it might need
    /// before it deletes anything: the only failure here is the device being
    /// unable to mint the access control, and that has to be found out while
    /// the old item still exists.
    private func sealedAttributes(
        _ token: String, for address: ServerAddress, behind protection: KeychainProtection
    ) throws(StoreError) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecValueData as String: Data(token.utf8),
            // Which gate this item was sealed behind. An attribute, not the
            // value, so it can be read back without a prompt — and so it is
            // deleted with the item rather than outliving it in a defaults
            // file that could then disagree with reality.
            kSecAttrGeneric as String: protection.marker,
        ]

        let flags: SecAccessControlCreateFlags
        switch protection {
        case .deviceUnlock:
            // No access control, and deliberately not `WhenPasscodeSet`: that
            // class cannot exist on a device with no passcode, and an ungated
            // token is allowed there — with a warning, see
            // `DeviceProtectionNotice`. `ThisDeviceOnly` is the line that does
            // not move: never in a backup, never migrated to another phone.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return attributes
        case .biometrics:
            flags = .biometryCurrentSet
        case .passcode:
            flags = .devicePasscode
        }

        var accessError: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil,
                // Both gated policies additionally require a passcode to exist
                // at all, so "no passcode" is refused by the Keychain even if
                // the capability check were ever wrong.
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                flags,
                &accessError
            )
        else {
            let detail =
                (accessError?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "a device passcode must be set"
            throw StoreError.deviceUnprotected(detail)
        }
        attributes[kSecAttrAccessControl as String] = access
        return attributes
    }

    // MARK: - Reading

    /// Reads the token, prompting for whatever is guarding it — which, for an
    /// ungated item, is nothing.
    ///
    /// For a gated item, authenticates explicitly first, then hands the satisfied context to the
    /// Keychain, so the operator sees one prompt carrying our reason string
    /// rather than a bare system dialog.
    ///
    /// The policy is chosen from the item's **own** protection, not from what
    /// the device can do today. A passcode-satisfied context does not unseal a
    /// `.biometryCurrentSet` item, so evaluating the wrong one would re-prompt
    /// or fail for no reason the operator could act on.
    func token(for address: ServerAddress, reason: String) async throws -> String {
        let protection = storedProtection(for: address) ?? .biometrics
        let context = LAContext()

        let policy: LAPolicy
        switch protection {
        case .deviceUnlock:
            // Nothing to evaluate: no access control, so no prompt. Going
            // through `evaluatePolicy` anyway would show the operator a Face ID
            // sheet for a gate they chose not to have.
            return try ungatedToken(for: address)
        case .biometrics:
            // Biometry or nothing: the item's ACL will not accept a passcode
            // either, so offering one as a fallback would be a dead end.
            context.localizedFallbackTitle = ""
            policy = .deviceOwnerAuthenticationWithBiometrics
        case .passcode:
            policy = .deviceOwnerAuthentication
        }

        do {
            try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                throw StoreError.cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                throw StoreError.deviceUnprotected(error.localizedDescription)
            default:
                throw StoreError.authenticationFailed
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw StoreError.keychain(errSecDecode)
            }
            return token
        case errSecItemNotFound:
            throw StoreError.notFound
        case errSecUserCanceled:
            // Distinct from a failure: `AppFlowModel` shows no error for a
            // cancellation, which is the right answer for a deliberate dismissal.
            throw StoreError.cancelled
        case errSecAuthFailed:
            throw StoreError.authenticationFailed
        // Raised when the item's `.biometryCurrentSet` policy no longer holds.
        case errSecInvalidData, errSecKeySizeNotAllowed:
            throw StoreError.enrollmentChanged
        default:
            throw StoreError.keychain(status)
        }
    }

    /// Reads an ungated token, without prompting and without the chance to.
    ///
    /// Synchronous, so `AppFlowModel` can go straight from launch to signed in
    /// without a frame of unlock screen in between.
    ///
    /// **Fail, not a bare query.** The marker said there is no access control,
    /// and a marker is written in the same `SecItemAdd` as the item it
    /// describes, so it should be right. If it ever were not, a bare query
    /// would raise the system's own authentication sheet with no reason string
    /// — exactly the unexplained prompt this path exists to avoid. `Fail` turns
    /// that into an error the unlock screen can show instead.
    func ungatedToken(for address: ServerAddress) throws(StoreError) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw StoreError.keychain(errSecDecode)
            }
            return token
        case errSecItemNotFound:
            throw StoreError.notFound
        case errSecInteractionNotAllowed:
            // A locked device, or — see above — an item that is gated after
            // all. Either way the token is there; it just is not readable this
            // instant, which is not the same as gone.
            throw StoreError.deviceLocked
        default:
            throw StoreError.keychain(status)
        }
    }

    func delete(for address: ServerAddress) throws(StoreError) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }
}

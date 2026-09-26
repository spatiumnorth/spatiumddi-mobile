//
//  WritePathTests.swift
//  SpatiumDDITests
//

import Foundation
import SpatiumAPI
import Testing

@testable import SpatiumDDI

/// The 409 the platform returns when it wants a second look before writing.
///
/// This is the load-bearing part of allocating an address (spatiumddi-mobile#7):
/// a hard conflict and a soft, force-overridable warning arrive with the same
/// status, and only the body separates them. Getting that wrong either loops a
/// doomed request or dead-ends a legitimate one.
@Suite("Collision warnings")
struct CollisionWarningTests {
    private func decode(_ json: String) throws -> [CollisionWarning] {
        struct Envelope: Decodable { let warnings: [CollisionWarning] }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).warnings
    }

    @Test("A duplicate FQDN names the address it already points at")
    func fqdnCollision() throws {
        let warnings = try decode(
            """
            {"warnings": [{
              "kind": "fqdn_collision",
              "fqdn": "web.corp.example",
              "existing_ip": "10.0.1.5",
              "existing_subnet": "10.0.1.0/24",
              "existing_ip_id": "0f8f…"
            }]}
            """
        )

        #expect(warnings.count == 1)
        #expect(warnings[0].kind == "fqdn_collision")
        #expect(warnings[0].summary.englishText == "web.corp.example already points at 10.0.1.5.")
        #expect(warnings[0].context == "10.0.1.0/24")
    }

    @Test("A dynamic-pool warning says why an IPAM row alone isn't enough")
    func dynamicPool() throws {
        let warnings = try decode(
            """
            {"warnings": [{
              "kind": "dynamic_pool",
              "address": "10.0.1.150",
              "pool_start": "10.0.1.100",
              "pool_end": "10.0.1.200"
            }]}
            """
        )

        let text = warnings[0].summary.englishText
        #expect(text.contains("10.0.1.100–10.0.1.200"))
        // The whole point of the warning: the DHCP server keeps leasing it.
        #expect(text.contains("static reservation"))
    }

    /// The public-facing guard spells its discriminator `type`, not `kind`, and
    /// supplies its own prose. Both have to survive or the warning renders as
    /// "unknown" with nothing in it.
    @Test("The public-facing guard is read despite spelling its key differently")
    func publicFacingUsesTypeNotKind() throws {
        let warnings = try decode(
            """
            {"warnings": [{
              "type": "public_facing_private_ip",
              "field": "extra_zone_ids",
              "message": "10.0.1.5 is a private address; publishing it would expose internal IPs.",
              "zone": "example.com",
              "group": "External"
            }]}
            """
        )

        #expect(warnings[0].kind == "public_facing_private_ip")
        // Server prose, rendered verbatim — never re-keyed or Markdown-parsed.
        #expect(
            warnings[0].summary
                == .server("10.0.1.5 is a private address; publishing it would expose internal IPs."))
        #expect(warnings[0].context == "example.com · External")
    }

    /// `force=true` waives every warning at once, so one that rendered as
    /// nothing would be one the operator waived without ever seeing it.
    @Test("An unrecognised warning still says something")
    func unknownKindIsNotSwallowed() throws {
        let warnings = try decode(#"{"warnings": [{"kind": "some_future_check", "detail": "x"}]}"#)

        #expect(warnings.count == 1)
        #expect(warnings[0].summary.englishText == "The server raised a some_future_check warning.")
    }

    @Test("Null and nested fields don't leak debug output into the sentence")
    func skipsNullsAndNesting() throws {
        let warnings = try decode(
            """
            {"warnings": [{
              "kind": "mac_collision",
              "mac_address": "aa:bb:cc:dd:ee:ff",
              "existing_ip": "10.0.2.7",
              "existing_hostname": null,
              "extra": {"nested": true}
            }]}
            """
        )

        #expect(warnings[0].fields["existing_hostname"] == nil)
        #expect(warnings[0].fields["extra"] == nil)
        #expect(
            warnings[0].summary.englishText
                == "aa:bb:cc:dd:ee:ff is already recorded on 10.0.2.7."
        )
    }
}

@Suite("Write errors")
struct WriteErrorTests {
    /// The two 409s. A hard conflict has a string `detail` and no way forward;
    /// a soft one carries `requires_confirmation` and may be re-sent forced.
    @Test("A hard conflict is not offered as confirmable")
    func hardConflictHasNoCollision() async {
        let error = APIStatusError(
            status: 409,
            detail: "Address 10.0.1.7 is already allocated in this subnet"
        )

        #expect(error.collision == nil)
        #expect(
            APIErrorMessage.describeWrite(error).englishText
                == "Address 10.0.1.7 is already allocated in this subnet"
        )
    }

    /// The wording of a read failure is simply wrong on a write. "You don't
    /// have permission to read this" on a rejected allocation misdescribes what
    /// the operator was trying to do.
    @Test("A 403 on a write says the operator couldn't change it, not read it")
    func forbiddenReadsDifferentlyOnAWrite() {
        let error = APIStatusError(status: 403)
        #expect(APIErrorMessage.describeWrite(error).englishText.contains("make this change"))
        #expect(APIErrorMessage.describe(error).englishText.contains("read this"))
    }

    /// Non-negotiable #5: a change window is never retried into, so the message
    /// has to leave the operator certain nothing half-landed.
    @Test("A maintenance window says nothing was changed")
    func maintenanceSaysNothingChanged() {
        let text = APIErrorMessage.describeWrite(APIStatusError(status: 503, isMaintenance: true))
            .englishText
        #expect(text.contains("nothing was changed"))
    }

    /// The window's own message is what the operator who opened it wanted
    /// everyone else to read — "Core switch upgrade until 02:00".
    @Test("A maintenance window carries the message it was opened with")
    func maintenanceCarriesItsMessage() {
        let error = APIStatusError(
            status: 503, detail: "Core switch upgrade until 02:00.", isMaintenance: true)
        let text = APIErrorMessage.describeWrite(error).englishText
        #expect(text.contains("Nothing was changed"))
        #expect(text.contains("Core switch upgrade until 02:00."))
    }

    /// A proxy's 503 for a backend that is down carries no marker, and the
    /// request may have reached the platform. "Nothing was changed" would be a
    /// claim the app cannot back.
    @Test("An unmarked 503 does not claim nothing was changed")
    func unmarked503IsNotMaintenance() {
        let text = APIErrorMessage.describeWrite(APIStatusError(status: 503)).englishText
        #expect(!text.localizedCaseInsensitiveContains("nothing was changed"))
        #expect(!text.contains("change window"))
        #expect(text.contains("isn't known"))
    }

    @Test("Only the platform's own marker makes a 503 a change window")
    func maintenanceMarker() {
        #expect(ControlPlaneProbe.isMaintenance(Data(#"{"detail":"x","maintenance":true}"#.utf8)))
        #expect(!ControlPlaneProbe.isMaintenance(Data(#"{"detail":"Database connection was closed"}"#.utf8)))
        #expect(!ControlPlaneProbe.isMaintenance(Data("<html>502 Bad Gateway</html>".utf8)))
        #expect(!ControlPlaneProbe.isMaintenance(Data()))
    }

    /// The single most useful sentence on a write is the server's own 422
    /// detail — "mac_address is required when status is 'static_dhcp'". It must
    /// not be replaced by this app's generic wording.
    @Test("A 422 detail survives instead of being generalised away")
    func validationDetailSurvives() {
        let error = APIStatusError(
            status: 422,
            detail: "mac_address is required when status is 'static_dhcp'"
        )
        #expect(
            APIErrorMessage.describeWrite(error)
                == .server("mac_address is required when status is 'static_dhcp'")
        )
    }
}

/// Client-side gating is a courtesy — non-negotiable #4 — so the failure
/// direction matters more than the accuracy: an unknown grant list shows the
/// button and lets the server answer.
@MainActor
@Suite("Permission gating")
struct PermissionsTests {
    private func grant(_ action: String, _ type: String, id: String? = nil)
        -> Components.Schemas.PermissionGrant
    {
        .init(action: action, resourceId: id, resourceType: type)
    }

    @Test("An unread grant list hides nothing")
    func failsOpen() {
        #expect(Permissions().canWrite("subnet"))
    }

    @Test("A superadmin can write anything")
    func superadmin() {
        #expect(Permissions(isSuperadmin: true, grants: []).canWrite("subnet"))
    }

    @Test("A read-only account is not offered a write")
    func readOnly() {
        let permissions = Permissions(isSuperadmin: false, grants: [grant("read", "subnet")])
        #expect(!permissions.canWrite("subnet"))
    }

    @Test("admin and the wildcard both imply write")
    func adminAndWildcard() {
        #expect(Permissions(isSuperadmin: false, grants: [grant("admin", "subnet")]).canWrite("subnet"))
        #expect(Permissions(isSuperadmin: false, grants: [grant("*", "subnet")]).canWrite("subnet"))
    }

    /// A grant scoped to one UUID says nothing about any other row — that is
    /// the whole point of `resource_id`.
    @Test("A grant scoped to one subnet doesn't cover another")
    func scopedGrant() {
        let permissions = Permissions(
            isSuperadmin: false,
            grants: [grant("write", "subnet", id: "subnet-a")]
        )
        #expect(permissions.canWrite("subnet", id: "subnet-a"))
        #expect(!permissions.canWrite("subnet", id: "subnet-b"))
    }

    /// The platform admits an address create on *either* a subnet grant or an
    /// address-set grant, so the app asks about both rather than picking one.
    @Test("Any one of the accepted resource types is enough")
    func anyOfSeveralTypes() {
        let permissions = Permissions(isSuperadmin: false, grants: [grant("write", "ip_address")])
        #expect(permissions.canWrite("subnet", "ip_address"))
    }
}

@Suite("Record value families")
struct IPFamilyTests {
    @Test(
        "Addresses are classified by family",
        arguments: [
            ("10.0.1.42", IPFamily.v4),
            ("255.255.255.255", .v4),
            ("2001:db8::42", .v6),
            ("::1", .v6),
            ("10.0.1.42, 10.0.1.43", .neither),
            ("host.example.com", .neither),
            ("", .neither),
        ]
    )
    func classifies(text: String, expected: IPFamily) {
        #expect(IPFamily.of(text) == expected)
    }
}

/// The passcode fallback (spatiumddi-mobile#5).
///
/// The device-dependent half — which protection is available — can't be
/// asserted in a test process, so what is pinned here is the part that must
/// hold on every device: the marker written beside the item, which decides
/// which `LAPolicy` is evaluated when the token is read back.
@Suite("Keychain protection")
struct KeychainProtectionTests {
    @Test("The stored marker round-trips", arguments: [KeychainProtection.biometrics, .passcode])
    func roundTrips(protection: KeychainProtection) {
        #expect(KeychainProtection(marker: protection.marker) == protection)
    }

    @Test("An unreadable marker is not silently treated as a known protection")
    func rejectsGarbage() {
        #expect(KeychainProtection(marker: Data([0xff, 0xfe])) == nil)
        #expect(KeychainProtection(marker: Data("something-else".utf8)) == nil)
    }

    /// An item written before the app understood passcode protection carries no
    /// marker at all, and those are biometric by construction. A store with no
    /// item must still answer "nothing", not "biometrics".
    @Test("No stored token means no protection to report")
    func noTokenNoProtection() {
        let store = TokenStore(service: "io.spatiumddi.tests.\(UUID().uuidString)")
        let address = ServerAddress(host: "ddi.internal.example", port: 8443)
        #expect(store.storedProtection(for: address) == nil)
        #expect(!store.hasToken(for: address))
    }

    @Test("Biometrics is the stronger answer, and is named as such")
    func passcodeIsMarkedAsSecondBest() {
        #expect(KeychainProtection.biometrics.caveat == nil)
        #expect(KeychainProtection.passcode.caveat != nil, "the weaker option has to say so")
    }
}

/// The typed gate in front of a delete (spatiumddi-mobile#8).
///
/// Deleting a DNS record pushes the retraction to every server in the group
/// immediately — the name stops resolving before the sheet has dismissed — so
/// this is the one confirmation in the app that asks for more than a tap.
@Suite("Delete confirmation")
struct DeleteConfirmationTests {
    @Test("The exact subject clears the gate")
    func exactMatch() {
        #expect(DeleteConfirmation.matches("10.50.0.1", subject: "10.50.0.1"))
    }

    /// Forgiving about the things a phone keyboard adds, strict about the rest.
    @Test(
        "Case and surrounding whitespace are forgiven",
        arguments: ["  10.50.0.1  ", "WEB01", "web01", "\nweb01\n"]
    )
    func forgiving(typed: String) {
        let subject = typed.lowercased().contains("web") ? "web01" : "10.50.0.1"
        #expect(DeleteConfirmation.matches(typed, subject: subject))
    }

    @Test(
        "A near miss does not",
        arguments: ["10.50.0.10", "10.50.0.", "", "10.50.01", "web 01"]
    )
    func nearMiss(typed: String) {
        #expect(!DeleteConfirmation.matches(typed, subject: "10.50.0.1"))
    }

    /// The dangerous edge: with an empty subject, typing nothing would satisfy
    /// a naive comparison — leaving the gate absent on exactly the rows whose
    /// identity is least obvious.
    @Test("An empty subject matches nothing at all")
    func emptySubjectIsNotAFreePass() {
        #expect(!DeleteConfirmation.matches("", subject: ""))
        #expect(!DeleteConfirmation.matches("   ", subject: "   "))
        #expect(!DeleteConfirmation.matches("anything", subject: ""))
    }
}

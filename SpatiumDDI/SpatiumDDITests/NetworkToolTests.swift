//
//  NetworkToolTests.swift
//  SpatiumDDITests
//

import Foundation
import SwiftUI
import Testing

@testable import SpatiumDDI

/// A MAC list as somebody actually pastes one.
@Suite("MAC list parsing")
struct MACListTests {
    /// The three shapes a copied MAC list arrives in — a lease table gives
    /// newlines, a spreadsheet gives commas, a terminal gives spaces.
    @Test(
        "Newlines, commas and spaces all separate",
        arguments: [
            "aa:bb:cc:dd:ee:ff\n11:22:33:44:55:66",
            "aa:bb:cc:dd:ee:ff,11:22:33:44:55:66",
            "aa:bb:cc:dd:ee:ff 11:22:33:44:55:66",
            "aa:bb:cc:dd:ee:ff, 11:22:33:44:55:66",
        ])
    func separators(text: String) {
        #expect(MACList.parse(text) == ["aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66"])
    }

    /// A paste out of a terminal brings trailing blank lines with it.
    @Test("Blank runs and stray whitespace produce no empty entries")
    func ignoresBlanks() {
        #expect(MACList.parse("\n\n aa:bb:cc:dd:ee:ff \n\n,,\n") == ["aa:bb:cc:dd:ee:ff"])
    }

    @Test("Nothing in, nothing out")
    func empty() {
        #expect(MACList.parse("").isEmpty)
        #expect(MACList.parse("   \n , \t ").isEmpty)
    }

    /// The list is passed through as typed. Normalising case or separators
    /// here would mean the answer names a MAC the operator never entered,
    /// which is worse than an unrecognised one.
    @Test("Entries are passed through as written")
    func preservesFormatting() {
        #expect(MACList.parse("AA-BB-CC-DD-EE-FF") == ["AA-BB-CC-DD-EE-FF"])
    }
}

/// What a fetched certificate amounts to.
@Suite("Certificate verdicts")
struct CertificateVerdictTests {
    @Test("A good certificate is the only one that reads as good news")
    func valid() {
        let verdict = CertificateVerdict.of(
            expired: false, hostnameMatches: true, selfSigned: false, ok: true
        )
        #expect(verdict == .valid)
        #expect(verdict.isGood)
    }

    /// The ordering is the whole point of the type. A certificate can be
    /// expired *and* self-signed *and* for the wrong name, and reporting the
    /// least alarming of those is how somebody talks themselves into ignoring
    /// it — so expiry wins, because it has already broken something.
    @Test("Expiry outranks every other complaint")
    func expiryWins() {
        #expect(
            CertificateVerdict.of(
                expired: true, hostnameMatches: false, selfSigned: true, ok: false
            ) == .expired
        )
    }

    @Test("A name mismatch outranks being self-signed")
    func hostnameBeatsSelfSigned() {
        #expect(
            CertificateVerdict.of(
                expired: false, hostnameMatches: false, selfSigned: true, ok: false
            ) == .wrongHostname
        )
    }

    @Test("Self-signed is reported when nothing worse applies")
    func selfSigned() {
        let verdict = CertificateVerdict.of(
            expired: false, hostnameMatches: true, selfSigned: true, ok: false
        )
        #expect(verdict == .selfSigned)
        #expect(!verdict.isGood)
    }

    /// A self-hosted estate is full of private CAs, and the server may simply
    /// not report these flags. Unknown must not read as "fine".
    @Test("Absent flags fall back to what the server concluded")
    func unknownFlags() {
        #expect(
            CertificateVerdict.of(
                expired: nil, hostnameMatches: nil, selfSigned: nil, ok: false
            ) == .unusable
        )
        #expect(
            CertificateVerdict.of(
                expired: nil, hostnameMatches: nil, selfSigned: nil, ok: true
            ) == .valid
        )
    }
}

/// What one resolver said during a propagation check.
///
/// These exist because the first version guessed the DNS RCODE vocabulary
/// (`NOERROR`) instead of reading what the server actually sends (`ok`), which
/// painted every *successful* resolver amber — the precise opposite of what
/// the screen is for. The words are the platform's, from `dns_tools.py`.
@Suite("Resolver status")
struct ResolverStatusTests {
    @Test("The server's own vocabulary maps to a verdict")
    func vocabulary() {
        #expect(ResolverStatus("ok") == .answered)
        #expect(ResolverStatus("nxdomain") == .missing)
        #expect(ResolverStatus("timeout") == .timedOut)
        #expect(ResolverStatus("error") == .failed)
    }

    @Test("Casing doesn't matter", arguments: ["ok", "OK", "Ok"])
    func casing(raw: String) {
        #expect(ResolverStatus(raw) == .answered)
    }

    /// A resolver that answered is the only green one. Getting this backwards
    /// is what the type is here to prevent.
    @Test("Only an answer is green")
    func onlyAnswerIsGreen() {
        #expect(ResolverStatus("ok").tint == .green)
        #expect(ResolverStatus("nxdomain").tint != .green)
        #expect(ResolverStatus("timeout").tint != .green)
        #expect(ResolverStatus("error").tint != .green)
    }

    /// Mid-propagation, a resolver that hasn't caught up is the *expected*
    /// state and the thing the operator is watching turn green — so it must
    /// not be dressed up as a failure.
    @Test("A missing record is amber, not red")
    func missingIsNotAFailure() {
        #expect(ResolverStatus("nxdomain").tint == .orange)
        #expect(ResolverStatus("error").tint == .red)
    }

    /// An unrecognised word is not evidence of anything.
    @Test("An unknown status is not coloured as a verdict")
    func unknown() {
        #expect(ResolverStatus("servfail") == .other("servfail"))
        #expect(ResolverStatus("servfail").tint == .secondary)
    }
}

/// A port, as typed.
@Suite("Port parsing")
struct PortNumberTests {
    @Test("Ordinary ports parse", arguments: [1, 53, 443, 8080, 65535])
    func valid(port: Int) {
        #expect(PortNumber.parse("\(port)") == port)
    }

    @Test("Surrounding whitespace is forgiven")
    func trims() {
        #expect(PortNumber.parse("  443\n") == 443)
    }

    /// Out of range and not-a-number both mean "don't send it", which is what
    /// keeps the Test button disabled with a reason next to the field.
    @Test("Anything outside 1–65535 is refused", arguments: ["0", "65536", "-1", "", "http", "44 3"])
    func invalid(text: String) {
        #expect(PortNumber.parse(text) == nil)
    }
}

/// Expiry from a day count, which is how the TLS tool reports it.
@Suite("Expiry from days")
struct ExpiryDaysTests {
    /// The same thresholds the Certificates section uses. Two screens
    /// disagreeing about what "soon" means is worse than either being wrong.
    @Test(
        "Day counts land in the same buckets as dates",
        arguments: [
            (-1, "expired"), (0, "critical"), (7, "critical"),
            (8, "soon"), (30, "soon"), (31, "fine"), (400, "fine"),
        ])
    func buckets(days: Int, expected: String) {
        let bucket =
            switch Expiry(daysRemaining: days) {
            case .expired: "expired"
            case .critical: "critical"
            case .soon: "soon"
            case .fine: "fine"
            case .unknown: "unknown"
            }
        #expect(bucket == expected)
    }

    /// `dateComponents` truncates toward zero, so hours past a deadline are
    /// "0 days" — which read "Expires today" on something already expired.
    @Test("A deadline hours in the past is expired, not today")
    func hoursPastIsExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = Expiry(now.addingTimeInterval(-5 * 3600), now: now)
        guard case .expired = expiry else {
            Issue.record("Expected .expired, got \(expiry)")
            return
        }
        guard case .critical(days: 0) = Expiry(now.addingTimeInterval(5 * 3600), now: now) else {
            Issue.record("Expected hours ahead to be .critical(0)")
            return
        }
    }
}

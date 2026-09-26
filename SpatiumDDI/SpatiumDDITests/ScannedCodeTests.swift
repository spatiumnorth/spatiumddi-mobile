//
//  ScannedCodeTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

/// A scanned code's token belongs to the server the code named, and to no other.
///
/// Nothing needs to be listening: the probe to a closed port fails, and what is
/// under test is what the model decided before it probed.
@MainActor
struct ScannedCodeTests {
    private func isolatedModel() -> ConnectionModel {
        ConnectionModel(
            trustStore: TrustStore(
                keychain: KeychainStore(service: "io.spatiumddi.tests.\(UUID().uuidString)")))
    }

    private func scan(_ model: ConnectionModel, host: String, port: Int) throws {
        try model.apply(
            EnrolmentPayload.parse("spatiumddi://enrol?host=\(host)&port=\(port)&token=sddi_scanned"))
    }

    @Test("Editing the address after a scan sets the scanned token aside")
    func editedAddressDropsToken() async throws {
        let model = isolatedModel()
        try scan(model, host: "127.0.0.1", port: 9)
        #expect(model.canFinishWithScannedToken)

        model.addressInput = "127.0.0.2:9"
        await model.connect()

        #expect(model.scannedToken == nil)
        #expect(!model.canFinishWithScannedToken)
        #expect(model.scanNotice != nil)
    }

    @Test("Connecting to the address the code named keeps its token")
    func sameAddressKeepsToken() async throws {
        let model = isolatedModel()
        try scan(model, host: "127.0.0.1", port: 9)

        await model.connect()

        #expect(model.scannedToken == "sddi_scanned")
        #expect(model.canFinishWithScannedToken)
    }
}

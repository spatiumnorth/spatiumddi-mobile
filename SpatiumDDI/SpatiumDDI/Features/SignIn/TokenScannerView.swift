//
//  TokenScannerView.swift
//  SpatiumDDI
//

import AVFoundation
import SwiftUI

/// Camera view that reads a SpatiumDDI enrolment QR code.
///
/// Reports the first well-formed payload and stops. It does not act on what it
/// read — the caller shows the operator what was scanned and waits for them to
/// agree, because a QR code is input from whoever printed it.
struct TokenScannerView: View {
    let onScanned: (EnrolmentPayload) -> Void
    let onCancel: () -> Void

    @State private var authorisation = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch authorisation {
                case .authorized:
                    scanner
                case .notDetermined:
                    prompt(
                        title: "Camera access needed",
                        message: "Allow camera access to scan an enrolment code.",
                        action: "Allow",
                        perform: request
                    )
                case .denied, .restricted:
                    prompt(
                        title: "Camera access is off",
                        message:
                            "Enable camera access for SpatiumDDI in Settings, or paste the token instead.",
                        action: "Open Settings",
                        perform: openSettings
                    )
                @unknown default:
                    prompt(
                        title: "Camera unavailable",
                        message: "Paste the token instead.",
                        action: "Close",
                        perform: onCancel
                    )
                }
            }
            .navigationTitle("Scan Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
            }
        }
    }

    private var scanner: some View {
        ZStack(alignment: .bottom) {
            CameraPreview { scanned in
                do {
                    onScanned(try EnrolmentPayload.parse(scanned))
                    return true
                } catch {
                    // Keep scanning. Pointing the camera at the wrong sticker is
                    // the ordinary way this goes wrong, and a scanner that dies
                    // on the first bad code looks like a broken camera.
                    scanError = error.localizedDescription
                    return false
                }
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 8) {
                if let scanError {
                    Label(scanError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text("Point the camera at the enrolment code shown in the SpatiumDDI web UI.")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
    }

    private func prompt(
        title: String, message: String, action: String, perform: @escaping () -> Void
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "qrcode.viewfinder")
        } description: {
            Text(message)
        } actions: {
            Button(action, action: perform)
        }
    }

    private func request() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            Task { @MainActor in
                authorisation = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Thin `AVCaptureSession` wrapper that emits decoded QR strings.
///
/// The handler returns whether the payload was accepted; a rejected one leaves
/// the session running so the operator can try another code.
private struct CameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Bool

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {
        controller.onCode = onCode
    }
}

/// `AVCaptureSession` is not `Sendable`, but Apple documents driving it from a
/// single serial queue as correct use. This carries it to that queue explicitly
/// rather than leaving the guarantee implicit.
///
/// `nonisolated` because the target defaults to main-actor isolation, which
/// would otherwise make the box itself main-actor bound — and reading
/// `box.session` on `sessionQueue` a main-actor access from the wrong thread.
private nonisolated struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    /// Returns true when the payload was accepted and scanning should stop.
    var onCode: ((String) -> Bool)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "io.spatiumddi.scanner.session")
    private var preview: AVCaptureVideoPreviewLayer?
    /// Latched while a code is being handled; a QR code re-reads many times a
    /// second, and only an accepted payload should end the scan.
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }  // No camera — the simulator, for one. The view stays black.

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        // startRunning() blocks; never call it on the main thread.
        let box = SessionBox(session: session)
        sessionQueue.async { box.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let box = SessionBox(session: session)
        sessionQueue.async {
            if box.session.isRunning { box.session.stopRunning() }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasReported,
            let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            object.type == .qr,
            let value = object.stringValue
        else { return }

        hasReported = true
        guard onCode?(value) == true else {
            // Not a payload we could use. Re-arm after a beat so the same code
            // in frame doesn't re-report dozens of times a second.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.hasReported = false
            }
            return
        }
        let box = SessionBox(session: session)
        sessionQueue.async { box.session.stopRunning() }
    }
}

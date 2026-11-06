import SwiftUI
import AVFoundation

// Camera QR scanning with AVFoundation (the pairing code of `python -m mglab pair`). The usage string
// `NSCameraUsageDescription` is already in project.yml / Info.plist. Owner: WP-13.
//
// `StrapQRScannerView` only reports the strings it reads; deciding what they mean is `PairingController`'s job.
// Where there is no camera (the simulator) or access is refused, the pairing sheet falls back to pasting the link.

/// Whether the camera can be used.
enum StrapCameraAccess: Equatable {
    case checking
    case ready
    /// Refused or restricted: only Settings can change that.
    case denied
    /// No camera on this device (simulator).
    case unavailable

    /// Asks for permission the first time; never prompts again after a refusal.
    static func resolve() async -> StrapCameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .ready : .denied
        default:
            return .denied
        }
    }
}

/// A live camera preview that reports QR codes. Starts and stops the capture session off the main thread.
struct StrapQRScannerView: UIViewRepresentable {
    let onCode: (String) -> Void
    /// The session could not be set up (no input, no QR support): the caller shows the paste fallback.
    let onFailure: (String) -> Void

    func makeCoordinator() -> StrapQRScannerCoordinator {
        StrapQRScannerCoordinator(onCode: onCode, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> StrapQRPreviewView {
        let view = StrapQRPreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: StrapQRPreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ uiView: StrapQRPreviewView, coordinator: StrapQRScannerCoordinator) {
        coordinator.stop()
    }
}

/// A view whose backing layer is the camera preview.
final class StrapQRPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass above guarantees the type.
        layer as! AVCaptureVideoPreviewLayer
    }
}

final class StrapQRScannerCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void
    private let onFailure: (String) -> Void
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "mgapp.pairing.qr.session")
    private var configured = false

    init(onCode: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        self.onCode = onCode
        self.onFailure = onFailure
        super.init()
    }

    func attach(to view: StrapQRPreviewView) {
        view.previewLayer.session = session
        sessionQueue.async { [weak self] in
            self?.configureAndStart()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // Runs on `sessionQueue`.
    private func configureAndStart() {
        if configured {
            if !session.isRunning { session.startRunning() }
            return
        }
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { return fail("No camera is available.") }

        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return fail("The camera cannot be used for scanning.")
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            return fail("The camera could not be opened.")
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return fail("The camera cannot read codes on this device.")
        }
        session.addOutput(output)
        // Types can only be set after the output is part of the session.
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.commitConfiguration()
            return fail("This device cannot read QR codes with the camera.")
        }
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        configured = true
        session.startRunning()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure(message)
        }
    }

    // MARK: AVCaptureMetadataOutputObjectsDelegate (main queue)

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, let text = code.stringValue {
                onCode(text)
                return
            }
        }
    }
}

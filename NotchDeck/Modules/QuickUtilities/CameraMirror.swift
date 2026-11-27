@preconcurrency import AVFoundation
import AppKit
import Observation
import SwiftUI

/// A camera NotchDeck can preview.
nonisolated struct CameraInfo: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
}

/// Webcam preview for a quick look before a call. The camera runs only while the Mirror tab is on
/// screen (the green light goes off when the notch closes).
@Observable
final class CameraMirrorStore {
    enum Access: Equatable { case notDetermined, granted, denied }

    private(set) var access: Access = CameraMirrorStore.currentAccess()
    private(set) var cameras: [CameraInfo] = []
    private(set) var selectedID: String?
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    @ObservationIgnored let session = CaptureSessionBox()
    @ObservationIgnored private var visibleViews = 0

    static let selectedCameraKey = "notchdeck.mirror.cameraID"

    init() {
        selectedID = UserDefaults.standard.string(forKey: Self.selectedCameraKey)
    }

    static func currentAccess() -> Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func viewAppeared() {
        visibleViews += 1
        Task { await startIfPossible() }
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        guard visibleViews == 0 else { return }
        session.stop()
        isRunning = false
    }

    /// The Mirror tab is no longer on screen (another tab was picked or the notch closed): turn the
    /// camera off right away instead of waiting for the view's fade-out, and drop any start in flight.
    func deactivate() {
        guard visibleViews > 0 || isRunning else { return }
        visibleViews = 0
        session.cancelPendingStart()
        session.stop()
        isRunning = false
    }

    func requestAccess() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        access = Self.currentAccess()
        await startIfPossible()
    }

    func select(_ camera: CameraInfo) {
        selectedID = camera.id
        UserDefaults.standard.set(camera.id, forKey: Self.selectedCameraKey)
        Task { await startIfPossible() }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startIfPossible() async {
        access = Self.currentAccess()
        guard access == .granted, visibleViews > 0 else { return }
        let devices = Self.discover()
        cameras = devices.map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
        guard !devices.isEmpty else {
            errorMessage = "No camera found."
            return
        }
        let device = devices.first { $0.uniqueID == selectedID } ?? AVCaptureDevice.default(for: .video) ?? devices[0]
        if selectedID == nil || !cameras.contains(where: { $0.id == selectedID }) { selectedID = device.uniqueID }
        let result = await session.start(deviceID: device.uniqueID)
        // The tab may have closed while the camera was starting.
        guard visibleViews > 0 else {
            session.stop()
            return
        }
        errorMessage = result
        isRunning = result == nil
    }

    private static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}

/// AVCaptureSession lives on its own serial queue (startRunning blocks for a moment).
nonisolated final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.notchdeck.camera-mirror")
    private var currentDeviceID: String?

    /// Starts (or switches to) a camera. Returns an error message, or nil on success.
    func start(deviceID: String) async -> String? {
        let requested = currentGeneration
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard requested == currentGeneration else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = configureAndRun(deviceID: deviceID)
                // Cancelled while the device was opening: turn it straight back off.
                if requested != currentGeneration, session.isRunning { session.stopRunning() }
                continuation.resume(returning: result)
            }
        }
    }

    private let lock = NSLock()
    private var generation = 0

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// A start already queued (or blocked opening the device) won't leave the camera running.
    func cancelPendingStart() {
        lock.lock(); generation += 1; lock.unlock()
    }

    private var currentGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    private func configureAndRun(deviceID: String) -> String? {
        if currentDeviceID != deviceID || session.inputs.isEmpty {
            guard let device = AVCaptureDevice(uniqueID: deviceID) else { return "That camera is no longer available." }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.sessionPreset = .high
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    return "\(device.localizedName) is in use by another app."
                }
                session.addInput(input)
            } catch {
                session.commitConfiguration()
                return error.localizedDescription
            }
            session.commitConfiguration()
            currentDeviceID = deviceID
        }
        if !session.isRunning { session.startRunning() }
        return session.isRunning ? nil : "The camera didn't start."
    }
}

/// Mirrored live preview.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        if nsView.previewLayer.session !== session { nsView.previewLayer.session = session }
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            // Mirror like a real mirror (and like FaceTime's self view).
            previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            CATransaction.commit()
        }
    }
}

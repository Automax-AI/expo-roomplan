import Foundation
import UIKit
import RoomPlan
import ExpoModulesCore
import AVFoundation
import ARKit

@available(iOS 17.0, *)
class RoomPlanCaptureUIView: ExpoView, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, ARSessionDelegate {
  private var roomCaptureView: RoomCaptureView!
  private let configuration = RoomCaptureSession.Configuration()
  // Events
  let onStatus = EventDispatcher()
  let onExported = EventDispatcher()
  let onPreview = EventDispatcher()
  let onPhoto = EventDispatcher()
  let onAudio = EventDispatcher()

  // Props
  var scanName: String? = nil
  var exportType: String? = nil
  var sendFileLoc: Bool = false
  var exportOnFinish: Bool = true

  private var capturedRooms: [CapturedRoom] = []
  private let structureBuilder = StructureBuilder(options: [.beautifyObjects])
  private var isRunning: Bool = false
  private var lastExportTrigger: Double? = nil
  private var lastFinishTrigger: Double? = nil
  private var lastAddAnotherTrigger: Double? = nil
  private var pendingFinish: Bool = false
  private var pendingExport: Bool = false
  private var previewEmitted: Bool = false

  // Photo capture state
  private var lastPhotoTrigger: Double? = nil
  private var photoTimer: Timer?
  private var autoPhotoIntervalSec: Double?
  private var photoUrls: [URL] = []

  // Audio recording state
  var audioEnabled: Bool = false
  private var isAudioRecording: Bool = false
  private var audioRecorder: AVAudioRecorder?
  private var audioFileURL: URL?
  var stopAudioOnFinish: Bool = true

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)

    roomCaptureView = RoomCaptureView(frame: .zero)
    roomCaptureView.translatesAutoresizingMaskIntoConstraints = false
    roomCaptureView.captureSession.delegate = self

    // Access the underlying ARSession for photo capture
    roomCaptureView.captureSession.arSession.delegate = self

    addSubview(roomCaptureView)

    NSLayoutConstraint.activate([
      roomCaptureView.topAnchor.constraint(equalTo: topAnchor),
      roomCaptureView.bottomAnchor.constraint(equalTo: bottomAnchor),
      roomCaptureView.leadingAnchor.constraint(equalTo: leadingAnchor),
      roomCaptureView.trailingAnchor.constraint(equalTo: trailingAnchor)
    ])
  }

  // Control running state from JS prop
  func setRunning(_ running: Bool) {
    guard running != isRunning else { return }
    isRunning = running
    if running {
      // Check device support before starting
      if !RoomCaptureSession.isSupported {
        sendError("RoomPlan is not supported on this device.")
        return
      }
      // Check/request camera permission
      let status = AVCaptureDevice.authorizationStatus(for: .video)
      switch status {
      case .authorized:
        previewEmitted = false
        roomCaptureView.captureSession.run(configuration: configuration)
        setupPhotoAndAudioCapture()
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { granted in
          DispatchQueue.main.async {
            if granted {
              self.previewEmitted = false
              self.roomCaptureView.captureSession.run(configuration: self.configuration)
              self.setupPhotoAndAudioCapture()
            } else {
              self.sendError("Camera permission was not granted.")
            }
          }
        }
      case .denied, .restricted:
        sendError("Camera permission is denied or restricted.")
      @unknown default:
        previewEmitted = false
        roomCaptureView.captureSession.run(configuration: configuration)
        setupPhotoAndAudioCapture()
      }
    } else {
      roomCaptureView.captureSession.stop(pauseARSession: false)
      cleanupPhotoAndAudioCapture()
    }
  }

  private func setupPhotoAndAudioCapture() {
    // If auto-photo requested, schedule timer
    if let sec = autoPhotoIntervalSec, sec > 0 {
      self.photoTimer?.invalidate()
      self.photoTimer = Timer.scheduledTimer(withTimeInterval: sec, repeats: true) { [weak self] _ in
        self?.captureStillFromARSession()
      }
    }

    // Start audio if requested
    if audioEnabled && !isAudioRecording {
      startAudioRecordingIfPermitted()
    }
  }

  private func cleanupPhotoAndAudioCapture() {
    photoTimer?.invalidate()
    photoTimer = nil
    if isAudioRecording {
      stopAudioRecording()
    }
  }

  func handleExportTrigger(_ trigger: Double?) {
    // Only handle when a non-nil trigger value actually changes
    guard let trigger else { return }
    if lastExportTrigger != trigger {
      lastExportTrigger = trigger
      // If nothing captured yet, queue export until capture ends
      guard !capturedRooms.isEmpty else {
        pendingExport = true
        return
      }
      exportResults()
    }
  }

  // Stop current capture, present the preview UI, and prepare to export.
  func handleFinishTrigger(_ trigger: Double?) {
    guard let trigger else { return }
    if lastFinishTrigger == trigger { return }
    lastFinishTrigger = trigger
  // Stop capturing to finalize current room; preview will be presented by RoomPlan
  pendingFinish = true
    roomCaptureView.captureSession.stop(pauseARSession: false)
  }

  // Restart session to accumulate another room like the controller-based flow
  func handleAddAnotherTrigger(_ trigger: Double?) {
    guard let trigger else { return }
    if lastAddAnotherTrigger == trigger { return }
    lastAddAnotherTrigger = trigger
    // Ensure current session is stopped, then start again to capture the next room
  pendingFinish = false
  pendingExport = false
  previewEmitted = false
  roomCaptureView.captureSession.stop(pauseARSession: false)
    DispatchQueue.main.async {
      self.roomCaptureView.captureSession.run(configuration: self.configuration)
    }
  }

  // MARK: - Photo Capture

  func handleCapturePhotoTrigger(_ trigger: Double?) {
    guard let trigger else { return }
    if lastPhotoTrigger != trigger {
      lastPhotoTrigger = trigger
      captureStillFromARSession()
    }
  }

  func setAutoPhotoInterval(_ val: Double?) {
    autoPhotoIntervalSec = val
    photoTimer?.invalidate()
    photoTimer = nil
    if isRunning, let sec = val, sec > 0 {
      photoTimer = Timer.scheduledTimer(withTimeInterval: sec, repeats: true) { [weak self] _ in
        self?.captureStillFromARSession()
      }
    }
  }

  private func captureStillFromARSession() {
    guard let frame = roomCaptureView.captureSession.arSession.currentFrame else {
      sendError("No AR frame available for photo.")
      return
    }
    let pixelBuffer = frame.capturedImage
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

    // Convert to CGImage (off main thread to keep UI smooth)
    let context = CIContext()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

      // Orientation: ARKit camera is typically .right for portrait device
      let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
      let data = image.jpegData(compressionQuality: 0.9)

      let folder = FileManager.default.temporaryDirectory.appending(path: "Export")
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let ts = Int(Date().timeIntervalSince1970 * 1000)
      let name = (self.scanName ?? "Room") + "_\(ts).jpg"
      let url = folder.appending(path: name)

      do {
        try data?.write(to: url)
        DispatchQueue.main.async {
          self.photoUrls.append(url)
          // Fire per-photo event to JS
          self.onPhoto(["photoUrl": url.absoluteString, "timestamp": ts])
        }
      } catch {
        DispatchQueue.main.async {
          self.sendError("Failed to save photo: \(error.localizedDescription)")
        }
      }
    }
  }

  // MARK: - Audio Recording

  func setAudioRunning(_ running: Bool) {
    if running {
      startAudioRecordingIfPermitted()
    } else {
      stopAudioRecording()
    }
  }

  private func startAudioRecordingIfPermitted() {
    let session = AVAudioSession.sharedInstance()
    session.requestRecordPermission { [weak self] granted in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard granted else {
          self.onAudio(["status": "error", "errorMessage": "Microphone permission not granted"])
          return
        }
        do {
          try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetooth])
          try session.setActive(true)

          let folder = FileManager.default.temporaryDirectory.appending(path: "Export")
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let name = (self.scanName ?? "Room") + ".m4a"
          let url = folder.appending(path: name)
          self.audioFileURL = url

          let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
          ]
          self.audioRecorder = try AVAudioRecorder(url: url, settings: settings)
          self.audioRecorder?.prepareToRecord()
          self.audioRecorder?.record()
          self.isAudioRecording = true
          self.onAudio(["status": "started", "audioUrl": url.absoluteString])
        } catch {
          self.onAudio(["status": "error", "errorMessage": error.localizedDescription])
        }
      }
    }
  }

  private func stopAudioRecording() {
    guard isAudioRecording else { return }
    audioRecorder?.stop()
    isAudioRecording = false
    onAudio(["status": "stopped", "audioUrl": audioFileURL?.absoluteString ?? ""])
  }

  // MARK: - RoomPlan delegates
  func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
    if let error {
      sendError(error.localizedDescription)
      return
    }
    let roomBuilder = RoomBuilder(options: [.beautifyObjects])
    Task {
      do {
        let capturedRoom = try await roomBuilder.capturedRoom(from: data)
        self.capturedRooms.append(capturedRoom)
        // If finishing, emit preview now that the processed room exists
        if self.pendingFinish && !self.previewEmitted {
          // Stop audio recording if configured to do so
          if self.stopAudioOnFinish && self.isAudioRecording {
            self.stopAudioRecording()
          }
          self.onPreview([:])
          self.previewEmitted = true
          // If requested, export right after preview
          if self.exportOnFinish {
            self.exportResults()
          }
          self.pendingFinish = false
        }
        // If an export was queued, export now
        if self.pendingExport {
          self.pendingExport = false
          self.exportResults()
        } else {
          self.sendStatus(.OK)
        }
      } catch {
        self.sendError("Failed to build captured room: \(error.localizedDescription)")
      }
    }
  }

  func captureSession(_ session: RoomCaptureSession, didFailWith error: any Error) {
    sendError(error.localizedDescription)
  }

  func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
    return true
  }
  
  func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    // RoomPlan presented its own preview UI; notify JS once
    if !previewEmitted {
      onPreview([:])
      previewEmitted = true
    }
  }

  // MARK: - Export
  private func exportResults() {
    let exportedScanName = scanName ?? "Room"

    let destinationFolderURL = FileManager.default.temporaryDirectory.appending(path: "Export")
    let destinationURL = destinationFolderURL.appending(path: "\(exportedScanName).usdz")
    let capturedRoomURL = destinationFolderURL.appending(path: "\(exportedScanName).json")

    Task {
      do {
        let structure = try await structureBuilder.capturedStructure(from: capturedRooms)

        try FileManager.default.createDirectory(at: destinationFolderURL, withIntermediateDirectories: true)

        var finalExportType = CapturedRoom.USDExportOptions.parametric
        if exportType == "MESH" { finalExportType = .mesh }
        if exportType == "MODEL" { finalExportType = .model }

        let jsonEncoder = JSONEncoder()
        let jsonData = try jsonEncoder.encode(structure)
        try jsonData.write(to: capturedRoomURL)
        try structure.export(to: destinationURL, exportOptions: finalExportType)

        // Build payload
        var payload: [String: Any] = [:]
        if self.sendFileLoc {
          payload["scanUrl"] = destinationURL.absoluteString
          payload["jsonUrl"] = capturedRoomURL.absoluteString
        }
        if let audio = self.audioFileURL {
          payload["audioUrl"] = audio.absoluteString
        }
        payload["photoUrls"] = self.photoUrls.map { $0.absoluteString }

        self.onExported(payload)
        // Also emit a final OK status after export
        self.sendStatus(.OK)
      } catch {
        self.sendError("Export failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Events
  private func sendStatus(_ status: ScanStatus) {
  self.onStatus(["status": status.rawValue])
  }

  private func sendError(_ message: String) {
    self.onStatus(["status": ScanStatus.Error.rawValue, "errorMessage": message])
  }
}

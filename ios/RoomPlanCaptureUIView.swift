import Foundation
import UIKit
import RoomPlan
import ExpoModulesCore
import AVFoundation
import ARKit
import OSLog

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
  let onAudioData = EventDispatcher()

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
  private var audioFileURL: URL?
  var stopAudioOnFinish: Bool = true

  // Audio Engine for streaming
  private var audioEngine: AVAudioEngine?
  private var audioInputNode: AVAudioInputNode?
  private var audioFile: AVAudioFile?  // For simultaneous file recording

  // ARWorldMap storage for scan resume functionality
  // Use static storage so the world map persists across view recreations
  private static var savedWorldMap: ARWorldMap?
  private static var savedWorldMapFileURL: URL? {
    FileManager.default.temporaryDirectory.appendingPathComponent("roomplan_worldmap.arworldmap")
  }
  private var isRelocalized: Bool = false
  private var isWaitingForRelocalization: Bool = false
  private var lastResumeTrigger: Double? = nil
  private var relocalizationTimeoutWorkItem: DispatchWorkItem?
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Automax", category: "RoomPlan")

  private func logMsg(_ message: String) {
    let tagged = "[RoomPlan] \(message)"
    print(tagged)
    logger.debug("\(message, privacy: .public)")
  }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    logMsg("RoomPlanCaptureUIView init started")

    logMsg("Creating RoomCaptureView...")
    // Check if we're on the main thread
    print("[RoomPlan] Is main thread: \(Thread.isMainThread)")
    roomCaptureView = RoomCaptureView(frame: .zero)
    logMsg("RoomCaptureView created successfully")

    roomCaptureView.translatesAutoresizingMaskIntoConstraints = false
    roomCaptureView.captureSession.delegate = self

    // Access the underlying ARSession for photo capture
    roomCaptureView.captureSession.arSession.delegate = self
    logMsg("Delegates set successfully")

    addSubview(roomCaptureView)
    logMsg("RoomCaptureView added as subview")

    NSLayoutConstraint.activate([
      roomCaptureView.topAnchor.constraint(equalTo: topAnchor),
      roomCaptureView.bottomAnchor.constraint(equalTo: bottomAnchor),
      roomCaptureView.leadingAnchor.constraint(equalTo: leadingAnchor),
      roomCaptureView.trailingAnchor.constraint(equalTo: trailingAnchor)
    ])
  }

  // Version-agnostic: ensure emissions occur on main; EventDispatcher forwards to JS thread
  @inline(__always)
  private func emitOnJS(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() }
    else { DispatchQueue.main.async(execute: block) }
  }

  // Control running state from JS prop
  func setRunning(_ running: Bool) {
    logMsg("setRunning called with: \(running), current isRunning: \(isRunning)")
    guard running != isRunning else {
      print("[RoomPlan] setRunning - no change needed")
      return
    }
    isRunning = running
    if running {
      print("[RoomPlan] Starting RoomPlan capture...")

      // Check device support before starting
      logMsg("Checking device support...")
      if !RoomCaptureSession.isSupported {
      logMsg("ERROR: RoomPlan is not supported on this device")
        emitOnJS { self.sendError("RoomPlan is not supported on this device.") }
        return
      }
      logMsg("Device support check passed")

      // Check/request camera permission
      let status = AVCaptureDevice.authorizationStatus(for: .video)
      logMsg("Camera permission status: \(status.rawValue)")

      switch status {
      case .authorized:
        logMsg("Camera authorized, starting capture session...")
        previewEmitted = false

        // Ensure we're on main thread and view is ready
        DispatchQueue.main.async { [weak self] in
          guard let self = self else { return }

          self.logMsg("View bounds: \(self.bounds)")
          self.logMsg("RoomCaptureView bounds: \(self.roomCaptureView.bounds)")
          self.logMsg("About to call roomCaptureView.captureSession.run...")

          self.roomCaptureView.captureSession.run(configuration: self.configuration)
          self.logMsg("captureSession.run called successfully")

          // Move setupPhotoAndAudioCapture inside async block
          self.setupPhotoAndAudioCapture()
          self.logMsg("setupPhotoAndAudioCapture completed")
        }

      case .notDetermined:
        logMsg("Camera permission not determined, requesting...")
        AVCaptureDevice.requestAccess(for: .video) { granted in
          self.logMsg("Camera permission response: \(granted)")
          DispatchQueue.main.async {
            if granted {
              self.previewEmitted = false
              self.logMsg("Starting capture session after permission granted...")
              self.roomCaptureView.captureSession.run(configuration: self.configuration)
              self.setupPhotoAndAudioCapture()
            } else {
              self.logMsg("Camera permission denied by user")
              self.emitOnJS { self.sendError("Camera permission was not granted.") }
            }
          }
        }
      case .denied, .restricted:
        logMsg("Camera permission is denied or restricted")
        emitOnJS { self.sendError("Camera permission is denied or restricted.") }
      @unknown default:
        logMsg("Unknown camera permission status, attempting to start...")
        previewEmitted = false
        roomCaptureView.captureSession.run(configuration: configuration)
        setupPhotoAndAudioCapture()
      }
    } else {
      logMsg("Stopping RoomPlan capture...")
      roomCaptureView.captureSession.stop(pauseARSession: false)
      cleanupPhotoAndAudioCapture()
      logMsg("RoomPlan capture stopped")
    }
  }

  private func setupPhotoAndAudioCapture() {
    print("[RoomPlan] setupPhotoAndAudioCapture called")

    // If auto-photo requested, schedule timer
    if let sec = autoPhotoIntervalSec, sec > 0 {
      logMsg("Setting up auto-photo with interval: \(sec)")
      self.photoTimer?.invalidate()
      self.photoTimer = Timer.scheduledTimer(withTimeInterval: sec, repeats: true) { [weak self] _ in
        self?.captureStillFromARSession()
      }
    }

    // TEMPORARILY DISABLED: Skip audio to isolate crash
    logMsg("Audio setup DISABLED for debugging")
    /*
    // Start audio if requested - delay to avoid ARSession conflict
    if audioEnabled && !isAudioRecording {
      print("[RoomPlan] Audio enabled, will start in 1 second...")
      // Delay audio start to let ARSession fully initialize
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        print("[RoomPlan] Starting audio recording after delay...")
        self?.startAudioRecordingIfPermitted()
      }
    } else {
      print("[RoomPlan] Audio not enabled or already recording")
    }
    */
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
  // Also saves the ARWorldMap for potential resume functionality.
  func handleFinishTrigger(_ trigger: Double?) {
    guard let trigger else { return }
    if lastFinishTrigger == trigger { return }
    lastFinishTrigger = trigger
    
        logMsg("Finishing scan, saving ARWorldMap for potential resume...")
    
    // Save the ARWorldMap before stopping for potential resume
    roomCaptureView.captureSession.arSession.getCurrentWorldMap { [weak self] worldMap, error in
      guard let self = self else { return }
      
      if let error = error {
        print("[RoomPlan] ERROR: Failed to get ARWorldMap: \(error.localizedDescription)")
      } else if let worldMap = worldMap {
        // Save to static variable (in-memory)
        RoomPlanCaptureUIView.savedWorldMap = worldMap
        print("[RoomPlan] ARWorldMap saved to memory successfully")
        
        // Also persist to disk for robustness
        if let fileURL = RoomPlanCaptureUIView.savedWorldMapFileURL {
          do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
            try data.write(to: fileURL)
            print("[RoomPlan] ARWorldMap saved to disk at: \(fileURL.path)")
            print("[RoomPlan] ARWorldMap anchors count: \(worldMap.anchors.count)")
          } catch {
            print("[RoomPlan] ERROR: Failed to save ARWorldMap to disk: \(error.localizedDescription)")
          }
        }
      } else {
        print("[RoomPlan] WARNING: getCurrentWorldMap returned nil worldMap without error")
      }
      
      // Stop capturing to finalize current room; preview will be presented by RoomPlan
      DispatchQueue.main.async {
        self.pendingFinish = true
        self.roomCaptureView.captureSession.stop(pauseARSession: true) // Keep AR session paused for resume
      }
    }
  }

  // MARK: - Resume Scan with ARWorldMap
  
  // Resume a paused scan by loading the saved ARWorldMap and relocalizing
  func handleResumeTrigger(_ trigger: Double?) {
    guard let trigger else { return }
    if lastResumeTrigger == trigger { return }
    lastResumeTrigger = trigger
    
    print("[RoomPlan] ========== RESUME SCAN TRIGGERED ==========")
      logMsg("Static savedWorldMap exists: \(RoomPlanCaptureUIView.savedWorldMap != nil)")
    
    // Reset state flags
    pendingFinish = false
    pendingExport = false
    previewEmitted = false
    isRelocalized = false
    relocalizationTimeoutWorkItem?.cancel()
    relocalizationTimeoutWorkItem = nil
    
    // Try to get world map from static storage first, then from disk
    var worldMap = RoomPlanCaptureUIView.savedWorldMap
    
    if worldMap == nil {
      logMsg("No world map in memory, trying to load from disk...")
      if let fileURL = RoomPlanCaptureUIView.savedWorldMapFileURL,
         FileManager.default.fileExists(atPath: fileURL.path) {
        do {
          let data = try Data(contentsOf: fileURL)
          worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
          if let wm = worldMap {
            RoomPlanCaptureUIView.savedWorldMap = wm
            logMsg("ARWorldMap loaded from disk successfully")
            logMsg("Loaded worldMap anchors count: \(wm.anchors.count)")
          }
        } catch {
          logMsg("ERROR: Failed to load ARWorldMap from disk: \(error.localizedDescription)")
        }
      } else {
        logMsg("No ARWorldMap file found on disk")
      }
    } else {
      logMsg("Using ARWorldMap from memory")
      logMsg("Memory worldMap anchors count: \(worldMap!.anchors.count)")
    }
    
    guard let finalWorldMap = worldMap else {
      logMsg("No saved ARWorldMap available, starting fresh scan")
      // No world map saved, start a fresh scan
      emitOnJS { self.onStatus(["status": "no_worldmap"]) }
      DispatchQueue.main.async {
        self.roomCaptureView.captureSession.run(configuration: self.configuration)
        self.setupPhotoAndAudioCapture()
      }
      return
    }
    
    logMsg("Loading saved ARWorldMap for relocalization...")
    logMsg("WorldMap has \(finalWorldMap.anchors.count) anchors")
    logMsg("WorldMap center: \(finalWorldMap.center)")
    logMsg("WorldMap extent: \(finalWorldMap.extent)")
    isWaitingForRelocalization = true
    
    // Emit status that we're relocalizing
    emitOnJS {
      self.onStatus([
        "status": "relocalizing",
        "anchors": finalWorldMap.anchors.count
      ])
    }
    
    // IMPORTANT: First stop any existing capture session to release the ARSession
    logMsg("Stopping existing capture session before relocalization...")
    roomCaptureView.captureSession.stop(pauseARSession: true)
    
    // Small delay to ensure session is fully stopped
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self = self else { return }
      
      self.logMsg("Configuring ARSession for relocalization...")
      
      // Configure AR session with saved world map for relocalization
      // Use ARWorldTrackingConfiguration which is compatible with the world map
      let arConfig = ARWorldTrackingConfiguration()
      arConfig.initialWorldMap = finalWorldMap
      arConfig.planeDetection = [.horizontal, .vertical]
      arConfig.environmentTexturing = .automatic
      
      // Run AR session with the saved world map - use resetTracking to clear any bad state
      // but keep anchors from the world map. Remove any existing anchors to avoid conflicts.
      self.logMsg("Starting ARSession with world map for relocalization...")
      // Ensure delegate is set before relocalization
      self.roomCaptureView.captureSession.arSession.delegate = self
      self.roomCaptureView.captureSession.arSession.run(
        arConfig,
        options: [.resetTracking, .removeExistingAnchors]
      )
      self.logMsg("ARSession started, waiting for tracking state to become normal...")
      
      // Set a timeout to avoid hanging on relocalization forever; fall back to fresh scan
      let timeout = DispatchWorkItem { [weak self] in
        guard let self = self else { return }
        if self.isWaitingForRelocalization && !self.isRelocalized {
          self.logMsg("Relocalization timed out, starting fresh scan")
          self.isWaitingForRelocalization = false
          self.isRelocalized = false
          RoomPlanCaptureUIView.savedWorldMap = nil
          self.emitOnJS { self.onStatus(["status": "relocalization_timeout"]) }
          DispatchQueue.main.async {
            self.roomCaptureView.captureSession.run(configuration: self.configuration)
            self.setupPhotoAndAudioCapture()
          }
        }
      }
      self.relocalizationTimeoutWorkItem = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: timeout)
    }
  }

  // Restart session to accumulate another room like the controller-based flow
  func handleAddAnotherTrigger(_ trigger: Double?) {
    guard let trigger else { return }
    if lastAddAnotherTrigger == trigger { return }
    lastAddAnotherTrigger = trigger

    // IMPORTANT: Do NOT clear capturedRooms - we want to keep accumulating rooms
    // This preserves all the scanning progress made so far
    logMsg("Continuing scan with \(capturedRooms.count) room(s) already captured")

    // Reset state flags but keep the captured data
    pendingFinish = false
    pendingExport = false
    previewEmitted = false

    // Stop current session and restart to continue scanning
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
      emitOnJS { self.sendError("No AR frame available for photo.") }
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
        }
        // Fire per-photo event on JS thread
        self.emitOnJS {
          self.onPhoto(["photoUrl": url.absoluteString, "timestamp": ts])
        }
      } catch {
        self.emitOnJS {
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
    AVAudioSession.sharedInstance().requestRecordPermission { granted in
      guard granted else {
        self.emitOnJS {
          self.onAudio(["status": "error", "errorMessage": "Microphone permission denied"])
        }
        return
      }

      DispatchQueue.main.async {
        do {
          // Configure audio session - use measurement mode for AR compatibility
          let audioSession = AVAudioSession.sharedInstance()
          // Use measurement mode which is more compatible with ARSession
          try audioSession.setCategory(.playAndRecord, mode: .measurement,
                                      options: [.mixWithOthers, .allowBluetooth])
          try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

          // Setup audio engine
          self.audioEngine = AVAudioEngine()
          guard let audioEngine = self.audioEngine else { return }

          self.audioInputNode = audioEngine.inputNode
          guard let inputNode = self.audioInputNode else { return }

          // Configure format: 16kHz, mono, 16-bit PCM (STT requirements)
          let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
          )!

          // Setup file for backup recording
          let folder = FileManager.default.temporaryDirectory.appending(path: "Export")
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let name = (self.scanName ?? "Room") + ".wav"  // Using WAV for PCM format
          let fileURL = folder.appending(path: name)
          self.audioFile = try AVAudioFile(forWriting: fileURL,
                                          settings: recordingFormat.settings)
          self.audioFileURL = fileURL

          // Install tap to capture PCM buffers
          inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { buffer, _ in
            // Stream to JavaScript
            self.streamAudioBuffer(buffer)

            // Also write to file
            try? self.audioFile?.write(from: buffer)
          }

          // Start engine
          try audioEngine.start()
          self.isAudioRecording = true

          self.emitOnJS {
            self.onAudio(["status": "started", "audioUrl": fileURL.absoluteString])
          }

        } catch {
          // Log the specific error for debugging
          print("[RoomPlan] Audio recording failed to start: \(error.localizedDescription)")

          // Don't crash - just report the error
          self.isAudioRecording = false
          self.audioEngine = nil
          self.audioInputNode = nil
          self.audioFile = nil

          self.emitOnJS {
            self.onAudio(["status": "error", "errorMessage": "Audio recording unavailable: \(error.localizedDescription)"])
          }
        }
      }
    }
  }

  private func stopAudioRecording() {
    guard isAudioRecording else { return }

    // Stop audio engine
    audioEngine?.stop()
    audioInputNode?.removeTap(onBus: 0)
    audioEngine = nil
    audioInputNode = nil
    audioFile = nil

    isAudioRecording = false
    emitOnJS {
      self.onAudio(["status": "stopped", "audioUrl": self.audioFileURL?.absoluteString ?? ""])
    }
  }

  // Stream audio buffer to JavaScript
  private func streamAudioBuffer(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.int16ChannelData else { return }

    let channelDataValue = channelData.pointee
    let channelDataArray = Array(UnsafeBufferPointer(start: channelDataValue,
                                                     count: Int(buffer.frameLength)))

    // Convert Int16 array to Data
    let data = channelDataArray.withUnsafeBytes { Data($0) }

    // Convert to base64 for JavaScript bridge
    let base64String = data.base64EncodedString()

    // Send via event dispatcher on JS thread
    emitOnJS {
      self.onAudioData([
        "pcmData": base64String,
        "sampleRate": 16000,
        "timestamp": Date().timeIntervalSince1970
      ])
    }
  }

  // MARK: - RoomPlan delegates
  func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
    if let error {
      emitOnJS { self.sendError(error.localizedDescription) }
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
          self.emitOnJS { self.onPreview([:]) }
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
          self.emitOnJS { self.sendStatus(.OK) }
        }
      } catch {
        self.emitOnJS { self.sendError("Failed to build captured room: \(error.localizedDescription)") }
      }
    }
  }

  func captureSession(_ session: RoomCaptureSession, didFailWith error: any Error) {
    emitOnJS { self.sendError(error.localizedDescription) }
  }

  func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
    return true
  }
  
  func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    // RoomPlan presented its own preview UI; notify JS once
    if !previewEmitted {
      emitOnJS { self.onPreview([:]) }
      previewEmitted = true
    }
  }

  // MARK: - ARSessionDelegate for Relocalization
  
  func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
    let trackingStateString: String
    switch camera.trackingState {
    case .normal:
      trackingStateString = "normal"
    case .limited(let reason):
      switch reason {
      case .initializing: trackingStateString = "limited(initializing)"
      case .relocalizing: trackingStateString = "limited(relocalizing)"
      case .excessiveMotion: trackingStateString = "limited(excessiveMotion)"
      case .insufficientFeatures: trackingStateString = "limited(insufficientFeatures)"
      @unknown default: trackingStateString = "limited(unknown)"
      }
    case .notAvailable:
      trackingStateString = "notAvailable"
    }
    
    print("[RoomPlan] AR tracking state changed: \(trackingStateString)")
    print("[RoomPlan] isWaitingForRelocalization: \(isWaitingForRelocalization), isRelocalized: \(isRelocalized)")
    
    switch camera.trackingState {
    case .normal:
      // If we were waiting for relocalization and tracking is now normal, start RoomCaptureSession
      if isWaitingForRelocalization && !isRelocalized {
        isRelocalized = true
        isWaitingForRelocalization = false
        relocalizationTimeoutWorkItem?.cancel()
        relocalizationTimeoutWorkItem = nil
      logMsg("Relocalization COMPLETE! Starting RoomCaptureSession...")
        
        // Emit relocated status
        emitOnJS { self.onStatus(["status": "relocated"]) }
        
        // Start the RoomCaptureSession now that we're relocalized
        // Add a small delay to ensure AR session is stable
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          self.roomCaptureView.captureSession.run(configuration: self.configuration)
          self.setupPhotoAndAudioCapture()
          print("[RoomPlan] RoomCaptureSession started after relocalization")
        }
      }
      
    case .limited(let reason):
      if reason == .relocalizing {
        logMsg("AR is actively relocalizing - point camera at previously scanned area")
        emitOnJS { self.onStatus(["status": "relocalizing"]) }
      } else if reason == .initializing {
        logMsg("AR is initializing...")
      } else if reason == .insufficientFeatures {
        logMsg("Insufficient visual features - need more textured surfaces")
      } else if reason == .excessiveMotion {
        logMsg("Excessive motion - move device more slowly")
      }
      
    case .notAvailable:
      logMsg("AR tracking not available")
      // If relocalization fails, we can fall back to starting fresh
      if isWaitingForRelocalization {
        logMsg("Relocalization failed (tracking not available), starting fresh scan")
        isWaitingForRelocalization = false
        isRelocalized = false
        relocalizationTimeoutWorkItem?.cancel()
        relocalizationTimeoutWorkItem = nil
        RoomPlanCaptureUIView.savedWorldMap = nil
        
        emitOnJS { self.onStatus(["status": "relocalization_failed"]) }
        
        // Start fresh
        DispatchQueue.main.async {
          self.roomCaptureView.captureSession.run(configuration: self.configuration)
          self.setupPhotoAndAudioCapture()
        }
      }
    }
  }
  
  func session(_ session: ARSession, didFailWithError error: Error) {
    logMsg("AR session failed with error: \(error.localizedDescription)")
    
    // Log more details about the error
    if let arError = error as? ARError {
      logMsg("ARError code: \(arError.code.rawValue)")
      switch arError.code {
      case .worldTrackingFailed:
        logMsg("World tracking failed - possible causes: fast motion, environment change, incompatible world map")
      case .sensorFailed:
        logMsg("Sensor failed")
      case .sensorUnavailable:
        logMsg("Sensor unavailable")
      case .unsupportedConfiguration:
        logMsg("Unsupported configuration")
      default:
        logMsg("Other ARError: \(arError.code)")
      }
    }
    
    // If we were waiting for relocalization and it failed, fall back to fresh scan
    if isWaitingForRelocalization {
      logMsg("Relocalization error, starting fresh scan instead")
      isWaitingForRelocalization = false
      isRelocalized = false
      relocalizationTimeoutWorkItem?.cancel()
      relocalizationTimeoutWorkItem = nil
      RoomPlanCaptureUIView.savedWorldMap = nil
      
      emitOnJS { self.onStatus(["status": "relocalization_failed", "errorMessage": error.localizedDescription]) }
      
      // Start fresh after a delay
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        self.roomCaptureView.captureSession.run(configuration: self.configuration)
        self.setupPhotoAndAudioCapture()
        print("[RoomPlan] Started fresh scan after relocalization failure")
      }
    }
  }

  // MARK: - Export
  private func exportResults() {
    let exportedScanName = scanName ?? "Room"

    let destinationFolderURL = FileManager.default.temporaryDirectory.appending(path: "Export")
    let destinationURL = destinationFolderURL.appending(path: "\(exportedScanName).usdz")
    let capturedRoomURL = destinationFolderURL.appending(path: "\(exportedScanName).json")

    print("[RoomPlan] Exporting \(capturedRooms.count) captured room(s)")

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

        self.emitOnJS { self.onExported(payload) }
        // Also emit a final OK status after export
        self.emitOnJS { self.sendStatus(.OK) }
      } catch {
        self.emitOnJS { self.sendError("Export failed: \(error.localizedDescription)") }
      }
    }
  }

  // MARK: - Events
  private func sendStatus(_ status: ScanStatus) {
    emitOnJS { self.onStatus(["status": status.rawValue]) }
  }

  private func sendError(_ message: String) {
    emitOnJS { self.onStatus(["status": ScanStatus.Error.rawValue, "errorMessage": message]) }
  }
}

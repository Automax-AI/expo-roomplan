You can absolutely capture photos and record audio **while** scanning with RoomPlan—*without* spinning up a second `AVCaptureSession` (which would fight ARKit for the camera). The trick is to (1) piggy-back on RoomPlan’s underlying **`ARSession`** for stills, and (2) run an **`AVAudioRecorder`** in parallel for audio.

Below is a focused deep-dive + concrete patch plan for your repo so you can drop this into your React Native app.

---

# What makes this possible (quick SDK notes)

* **RoomPlan exposes its ARKit session**. You can grab frames via
  `roomCaptureView.captureSession.arSession` and read `currentFrame.capturedImage` for stills. ([Apple Developer][1])
* **High-res-enough stills via ARKit**: Use `ARSession.currentFrame.capturedImage (CVPixelBuffer)` → `CIImage` → `CGImage` → `UIImage` → JPEG/HEIF file. No second camera session needed. ([Apple Developer][2])
* **Audio can be recorded concurrently** with ARKit using `AVAudioRecorder` (configure `AVAudioSession` to `.record` or `.playAndRecord`). ([Apple Developer][3])

> Don’t try to start a separate `AVCaptureSession` for photos—the camera is already owned by ARKit/RoomPlan and you’ll hit contention. Capturing from `ARSession` frames is the stable approach. (Apple’s docs explicitly allow you to access the `ARSession`; WWDC sessions also show grabbing frames from AR.) ([Apple Developer][1])

---

# The implementation plan (iOS)

You already have two native flows:

1. **`RoomPlanCaptureUIView`** (the Expo view you control via props)
2. **`RoomPlanCaptureViewController`** (standalone controller UI)

I’ll implement in **`RoomPlanCaptureUIView`** first (that’s the one wired to your TS `RoomPlanView` props), and note the minimal deltas if you also want it in the controller.

## 1) Add new events + props to your module

In `ExpoRoomPlanViewModule.swift` add two more events and a few props:

```swift
// + onPhoto, onAudio
View(RoomPlanCaptureUIView.self) {
  Events("onStatus", "onExported", "onPreview", "onPhoto", "onAudio")

  // …existing props…

  // NEW: enable/disable audio recording
  Prop("audioEnabled") { (view, value: Bool?) in view.audioEnabled = value ?? false }

  // NEW: start/stop audio at runtime
  Prop("audioRunning") { (view, value: Bool?) in view.setAudioRunning(value ?? false) }

  // NEW: bump number (Date.now()) to capture a photo on demand
  Prop("capturePhotoTrigger") { (view, value: Double?) in view.handleCapturePhotoTrigger(value) }

  // NEW: take a photo every N seconds while scanning (set to 0/undefined to disable)
  Prop("autoPhotoIntervalSec") { (view, value: Double?) in view.setAutoPhotoInterval(value) }

  // Optional: stop audio automatically when capture finishes
  Prop("stopAudioOnFinish") { (view, value: Bool?) in view.stopAudioOnFinish = value ?? true }
}
```

## 2) Extend the view to capture stills from ARKit and record audio

In `RoomPlanCaptureUIView`:

### a) Adopt `ARSessionDelegate` and add state

```swift
class RoomPlanCaptureUIView: ExpoView, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, ARSessionDelegate {
  // …existing…

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
```

Initialize the AR session delegate when you create the view:

```swift
required init(appContext: AppContext? = nil) {
  super.init(appContext: appContext)
  roomCaptureView = RoomCaptureView(frame: .zero)
  roomCaptureView.translatesAutoresizingMaskIntoConstraints = false
  roomCaptureView.captureSession.delegate = self

  // 👇 access the underlying ARSession
  roomCaptureView.captureSession.arSession.delegate = self

  addSubview(roomCaptureView)
  // …constraints…
}
```

### b) Start/stop scanning: wire audio + timers

In `setRunning(_:)`:

```swift
if running {
  // …your existing RoomPlan support + camera permission flow…

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
} else {
  roomCaptureView.captureSession.stop(pauseARSession: false)
  photoTimer?.invalidate()
  photoTimer = nil
  if isAudioRecording {
    stopAudioRecording()
  }
}
```

### c) Manual photo trigger

```swift
func handleCapturePhotoTrigger(_ trigger: Double?) {
  guard let trigger else { return }
  if lastPhotoTrigger != trigger {
    lastPhotoTrigger = trigger
    captureStillFromARSession()
  }
}
```

### d) Auto-photo setter

```swift
func setAutoPhotoInterval(_ val: Double?) {
  autoPhotoIntervalSec = val
  photoTimer?.invalidate()
  if isRunning, let sec = val, sec > 0 {
    photoTimer = Timer.scheduledTimer(withTimeInterval: sec, repeats: true) { [weak self] _ in
      self?.captureStillFromARSession()
    }
  }
}
```

### e) Capture a still from the AR session

```swift
private func captureStillFromARSession() {
  guard let frame = roomCaptureView.captureSession.arSession.currentFrame else {
    sendError("No AR frame available for photo.")
    return
  }
  let pixelBuffer = frame.capturedImage
  let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

  // Convert to CGImage (off main thread to keep UI smooth)
  let context = CIContext()
  DispatchQueue.global(qos: .userInitiated).async {
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
        // fire per-photo event to JS
        self.onPhoto(["photoUrl": url.absoluteString, "timestamp": ts])
      }
    } catch {
      DispatchQueue.main.async { self.sendError("Failed to save photo: \(error.localizedDescription)") }
    }
  }
}
```

> We’re reading **`ARSession.currentFrame`** from the same camera feed RoomPlan uses, so there’s no device-resource contention. ([Apple Developer][1])

### f) Audio recording helpers

```swift
func setAudioRunning(_ running: Bool) {
  if running { startAudioRecordingIfPermitted() } else { stopAudioRecording() }
}

private func startAudioRecordingIfPermitted() {
  let session = AVAudioSession.sharedInstance()
  session.requestRecordPermission { granted in
    DispatchQueue.main.async {
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
```

> `AVAudioRecorder` happily runs while ARKit uses the camera. Just remember the **Info.plist** key `NSMicrophoneUsageDescription`. ([Apple Developer][3])

### g) Clean up + include media in your export event

* Stop timers and (optionally) audio when a capture completes:

```swift
func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
  // …your existing room build…
  if self.pendingFinish && self.stopAudioOnFinish && self.isAudioRecording {
    self.stopAudioRecording()
  }
}
```

* Include `photoUrls` and `audioUrl` in `onExported`:

```swift
private func exportResults() {
  // …existing structure export…

  // Build payload
  var payload: [String: Any] = [:]
  if sendFileLoc {
    payload["scanUrl"] = destinationURL.absoluteString
    payload["jsonUrl"] = capturedRoomURL.absoluteString
  }
  if let audio = self.audioFileURL { payload["audioUrl"] = audio.absoluteString }
  payload["photoUrls"] = self.photoUrls.map { $0.absoluteString }

  self.onExported(payload)
  self.sendStatus(.OK)
}
```

> Leaves your existing behavior intact; the new fields are optional and backward-compatible.

## 3) Info.plist keys

* `NSMicrophoneUsageDescription` (“We record voice notes during scanning.”)
* (Optional) `NSPhotoLibraryAddUsageDescription` if you later choose to save to Photos instead of app tmp folder.

---

# React Native / TypeScript changes

### 1) Extend the view props & events

In `src/ExpoRoomplanView.types.ts`:

```ts
export interface RoomPlanViewProps extends ViewProps {
  // …existing…

  /** Enable audio recording during scan. */
  audioEnabled?: boolean;
  /** Start/stop audio recording. */
  audioRunning?: boolean;
  /** Bump to take a photo from the AR camera feed. */
  capturePhotoTrigger?: number;
  /** Take a photo every N seconds while scanning (disable with 0/undefined). */
  autoPhotoIntervalSec?: number;
  /** Stop audio automatically when finish trigger completes. Default true. */
  stopAudioOnFinish?: boolean;

  /** Per-photo callback. */
  onPhoto?: (e: { nativeEvent: { photoUrl: string; timestamp: number } }) => void;
  /** Audio state callback. */
  onAudio?: (e: { nativeEvent: { status: 'started' | 'stopped' | 'error'; audioUrl?: string; errorMessage?: string } }) => void;

  /** onExported now may include photo/audio */
  onExported?: (e: {
    nativeEvent: {
      scanUrl?: string;
      jsonUrl?: string;
      audioUrl?: string;
      photoUrls?: string[];
    };
  }) => void;
}
```

`RoomPlanView` component stays the same (RN just forwards props).

### 2) Add ergonomic controls to `useRoomPlanView`

In `src/useRoomPlanView.ts` add local state/trigger setters:

```ts
const [capturePhotoTrigger, setCapturePhotoTrigger] = useState<number>();
const [audioRunning, setAudioRunning] = useState<boolean>(false);
const [autoPhotoIntervalSec, setAutoPhotoIntervalSec] = useState<number | undefined>(undefined);

const capturePhoto = useCallback(() => setCapturePhotoTrigger(Date.now()), []);
const startAudio = useCallback(() => setAudioRunning(true), []);
const stopAudio = useCallback(() => setAudioRunning(false), []);
```

Thread them into `viewProps`:

```ts
const viewProps: RoomPlanViewProps = useMemo(() => ({
  // …existing…
  audioEnabled: true,                // or expose via hook options
  audioRunning,
  capturePhotoTrigger,
  autoPhotoIntervalSec,
  stopAudioOnFinish: true,
  // …events…
}), [/* deps incl. audioRunning, capturePhotoTrigger, autoPhotoIntervalSec */]);
```

Expose new controls in the return:

```ts
return {
  viewProps,
  controls: {
    start, cancel, finishScan, addRoom, exportScan, reset,
    capturePhoto, startAudio, stopAudio,
    setAutoPhotoInterval: (sec?: number) => setAutoPhotoIntervalSec(sec),
  },
  state: {
    // …existing…
  },
}
```

### 3) Example RN usage

```tsx
const { viewProps, controls, state } = useRoomPlanView({
  scanName: "Unit_203",
  sendFileLoc: true,
  exportOnFinish: true,
  onPhoto: (e) => console.log("photo:", e.nativeEvent.photoUrl),
  onAudio: (e) => console.log("audio:", e.nativeEvent),
  onExported: (e) => console.log("exported:", e.nativeEvent),
});

return (
  <>
    <RoomPlanView {...viewProps} style={{ flex: 1 }} />
    <Toolbar
      onStart={() => { controls.start(); controls.startAudio(); }}
      onSnap={() => controls.capturePhoto()}
      onFinish={() => controls.finishScan()}
      onCancel={() => { controls.cancel(); controls.stopAudio(); }}
    />
  </>
);
```

---

# If you also want this in `RoomPlanCaptureViewController`

* Add a floating **“Mic”** toggle and **“Shutter”** button (similar to `finishButton`/`cancelButton`).
* Copy the **audio helpers** and **`captureStillFromARSession()`** from the view into the controller, and use `roomCaptureView.captureSession.arSession`.
* Start audio in `startSession()` if enabled; stop it either in `stopSession()` or after export.

---

# Performance & gotchas

* **Don’t create another AVCapture pipeline**. Use the AR session frame. (Stable + zero camera contention.) ([Apple Developer][1])
* **Orientation**: ARKit frames are typically `.right` for portrait; if your UI is landscape you may need to adjust `UIImageOrientation`.
* **File lifetime**: You’re writing to `tmp/Export/`. Consider moving to Documents or uploading immediately after `onPhoto/onAudio/onExported`.
* **Permissions**: Camera (already handled) and Microphone (new).
* **Auto photos**: Keep interval ≥1s to avoid IO thrash during LiDAR scans.
* **iOS version**: Your code is gated with `@available(iOS 17.0, *)`. RoomPlan works on iOS 16+, but keeping 17+ is fine given your current annotations. WWDC23 brought multi-room & merge improvements you already leverage. ([Apple Developer][4])

---

# Implementation Status

✅ **IMPLEMENTATION COMPLETE**

All phases have been successfully implemented:

- [x] Phase 1: Added new events and props to ExpoRoomPlanViewModule.swift
- [x] Phase 2a: Added ARSessionDelegate and state properties to RoomPlanCaptureUIView
- [x] Phase 2b: Implemented photo capture from ARSession
- [x] Phase 2c: Implemented audio recording functionality
- [x] Phase 2d: Wired up start/stop scanning with audio and timers
- [x] Phase 2e: Included media in export event
- [x] Phase 3: Updated TypeScript types in ExpoRoomplanView.types.ts
- [x] Phase 4: Added controls to useRoomPlanView.ts hook
- [x] Documentation: Updated README with permissions and examples
- [x] Build: Successfully compiled module with no TypeScript errors

# Test checklist

1. Launch the RN screen with `RoomPlanView`.
2. Tap **Start** → verify scanning begins.
3. Audio auto-starts (if enabled): you should see `onAudio: started`.
4. Tap **Snap** a few times → verify `onPhoto` events + files exist.
5. Tap **Finish** → iOS preview shows (your current flow), then auto-export → `onExported` now includes `photoUrls[]` and `audioUrl`.
6. Validate files and upload where needed.

---

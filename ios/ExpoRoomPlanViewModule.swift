import ExpoModulesCore
import UIKit
import RoomPlan

public class ExpoRoomPlanViewModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoRoomPlanView")

    // Register a React Native view that embeds RoomCaptureView
    View(RoomPlanCaptureUIView.self) {
      Events("onStatus", "onExported", "onPreview", "onPhoto", "onAudio", "onAudioData")

      // Props to control flow
      Prop("scanName") { (view, value: String?) in
        view.scanName = value
      }
      Prop("exportType") { (view, value: String?) in
        view.exportType = value
      }
      Prop("sendFileLoc") { (view, value: Bool?) in
        view.sendFileLoc = value ?? false
      }
      Prop("exportOnFinish") { (view, value: Bool?) in
        view.exportOnFinish = value ?? true
      }
      Prop("running") { (view, value: Bool?) in
        view.setRunning(value ?? false)
      }
      // Bump this number to trigger an export on demand
      Prop("exportTrigger") { (view, value: Double?) in
        view.handleExportTrigger(value)
      }
      // Stop capture and show RoomPlan preview UI
      Prop("finishTrigger") { (view, value: Double?) in
        view.handleFinishTrigger(value)
      }
      // Continue scanning and add another room to the set
      Prop("addAnotherTrigger") { (view, value: Double?) in
        view.handleAddAnotherTrigger(value)
      }

      // Resume a paused scan with ARWorldMap relocalization
      Prop("resumeTrigger") { (view, value: Double?) in
        view.handleResumeTrigger(value)
      }

      // NEW: enable/disable audio recording
      Prop("audioEnabled") { (view, value: Bool?) in
        view.audioEnabled = value ?? false
      }

      // NEW: start/stop audio at runtime
      Prop("audioRunning") { (view, value: Bool?) in
        view.setAudioRunning(value ?? false)
      }

      // NEW: bump number (Date.now()) to capture a photo on demand
      Prop("capturePhotoTrigger") { (view, value: Double?) in
        view.handleCapturePhotoTrigger(value)
      }

      // NEW: take a photo every N seconds while scanning (set to 0/undefined to disable)
      Prop("autoPhotoIntervalSec") { (view, value: Double?) in
        view.setAutoPhotoInterval(value)
      }

      // Optional: stop audio automatically when capture finishes
      Prop("stopAudioOnFinish") { (view, value: Bool?) in
        view.stopAudioOnFinish = value ?? true
      }
    }
  }
}

import type { ViewProps, StyleProp, ViewStyle } from 'react-native';
import type { ScanStatus, ExportType } from './ExpoRoomplan.types';

/**
 * Props for {@link RoomPlanView}.
 */
export interface RoomPlanViewProps extends ViewProps {
  /** Base filename (no extension) for the exported files. */
  scanName?: string;
  /** Export mode for the USDZ model. */
  exportType?: ExportType;
  /**
   * When true, {@link onExported} will include the file URLs of the exported `.usdz` and `.json` files
   * instead of presenting the system share sheet.
   */
  sendFileLoc?: boolean;
  /** Start/stop the scanning session. */
  running?: boolean; // start/stop scanning
  /**
   * Bump this numeric value (e.g. with Date.now()) to trigger an export.
   * If no rooms have been captured yet, the export is queued until one is available.
   */
  exportTrigger?: number; // bump to trigger an export
  // Stop scanning and present the RoomPlan preview UI. Bump the number to trigger.
  /** Bump to stop capture and present the iOS preview UI. */
  finishTrigger?: number;
  // Continue scanning and accumulate additional rooms. Bump the number to trigger.
  /** Bump to finish the current room and immediately start a new capture. */
  addAnotherTrigger?: number;
  // If true (default), finish will also export the result once ready
  /** When true, finishing a capture automatically exports once preview is shown. */
  exportOnFinish?: boolean;

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

  /**
   * Bump to pause the scan and enter photo capture mode.
   * Preserves AR session state for relocalization when resuming.
   */
  pauseTrigger?: number;
  /**
   * Bump to resume the scan after taking photos.
   * Uses ARKit relocalization to continue from where the scan left off.
   */
  resumeTrigger?: number;

  /** Standard React Native style prop. */
  style?: StyleProp<ViewStyle>;
  /** Receives status updates such as OK, Error, and Canceled. */
  onStatus?: (e: { nativeEvent: { status: ScanStatus; errorMessage?: string } }) => void;
  /** Called when the native preview UI is presented after finishing a scan. */
  onPreview?: () => void;
  /** Per-photo callback. */
  onPhoto?: (e: { nativeEvent: { photoUrl: string; timestamp: number } }) => void;
  /** Audio state callback. */
  onAudio?: (e: {
    nativeEvent: {
      status: 'started' | 'stopped' | 'error';
      audioUrl?: string;
      errorMessage?: string;
    };
  }) => void;
  /** Audio data streaming callback for real-time PCM audio. */
  onAudioData?: (e: {
    nativeEvent: {
      pcmData: string; // Base64 encoded PCM audio
      sampleRate: number; // Sample rate (16000)
      timestamp: number; // Unix timestamp
    };
  }) => void;
  /** Emitted after export; includes file URLs when `sendFileLoc` is true, now also includes media. */
  onExported?: (e: {
    nativeEvent: {
      scanUrl?: string;
      jsonUrl?: string;
      audioUrl?: string;
      photoUrls?: string[];
    };
  }) => void;

  /**
   * Called when the scan is paused for photo capture mode.
   * At this point, the camera overlay can be shown.
   */
  onPaused?: () => void;
  /**
   * Called when the scan resumes after photo capture.
   * ARKit will attempt relocalization to continue from the previous position.
   */
  onResumed?: () => void;

  /**
   * Called with relocalization status updates during resume.
   * Provides feedback about ARKit's attempt to relocalize to the previous scan position.
   */
  onRelocalizationStatus?: (e: {
    nativeEvent: {
      status: 'starting' | 'relocalizing' | 'success' | 'unavailable';
      reason?: string;
      message: string;
    };
  }) => void;
}

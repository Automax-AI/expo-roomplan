import { useCallback, useMemo, useRef, useState } from 'react';
import type { RoomPlanViewProps } from './ExpoRoomplanView.types';
import type { ExportType, ScanStatus } from './ExpoRoomplan.types';

/**
 * Options for {@link useRoomPlanView}.
 */
export type UseRoomPlanViewOptions = {
  /** Base filename (no extension) for the exported files. */
  scanName?: string;
  /** Export mode for the USDZ model. */
  exportType?: ExportType;
  /** If true, finishing a capture also triggers export automatically. Defaults to `true`. */
  exportOnFinish?: boolean;
  /** When true, onExported receives file URLs instead of showing a share sheet. Defaults to `true`. */
  sendFileLoc?: boolean;
  /** Enable audio recording during scan. Defaults to `false`. */
  audioEnabled?: boolean;
  /** Stop audio automatically when finish trigger completes. Defaults to `true`. */
  stopAudioOnFinish?: boolean;
  /** Take a photo every N seconds while scanning (disable with 0/undefined). */
  autoPhotoIntervalSec?: number;
  /** Automatically stop scanning when status becomes OK, Error, or Canceled. Defaults to `false`. */
  autoCloseOnTerminalStatus?: boolean;
  /** Tap into status updates from the native view. */
  onStatus?: NonNullable<RoomPlanViewProps['onStatus']>;
  /** Called when the native preview UI is presented after finishing a scan. */
  onPreview?: RoomPlanViewProps['onPreview'];
  /** Per-photo callback. */
  onPhoto?: RoomPlanViewProps['onPhoto'];
  /** Audio state callback. */
  onAudio?: RoomPlanViewProps['onAudio'];
  /** Audio data streaming callback for real-time PCM audio. */
  onAudioData?: RoomPlanViewProps['onAudioData'];
  /** Called after export completes with file URLs when `sendFileLoc` is true. */
  onExported?: NonNullable<RoomPlanViewProps['onExported']>;
  /** Called when the scan is paused for photo capture mode. */
  onPaused?: RoomPlanViewProps['onPaused'];
  /** Called when the scan resumes after photo capture. */
  onResumed?: RoomPlanViewProps['onResumed'];
  /** Called with relocalization status updates during resume. */
  onRelocalizationStatus?: RoomPlanViewProps['onRelocalizationStatus'];
};

/**
 * Return type of {@link useRoomPlanView}.
 */
export type UseRoomPlanViewReturn = {
  viewProps: RoomPlanViewProps;
  controls: {
    /** Start a new scanning session. */
    start: () => void;
    /** Stop the current scanning session without exporting. */
    cancel: () => void;
    /** Stop capture and present the iOS preview UI (then export if `exportOnFinish` is true). */
    finishScan: () => void;
    /** Finish the current room and immediately start capturing another. */
    addRoom: () => void;
    /** Trigger export manually. Queued until a room is available if called too early. */
    exportScan: () => void;
    /** Take a photo from the AR camera feed. */
    capturePhoto: () => void;
    /** Start audio recording. */
    startAudio: () => void;
    /** Stop audio recording. */
    stopAudio: () => void;
    /** Set automatic photo interval (in seconds). Pass undefined to disable. */
    setAutoPhotoInterval: (sec?: number) => void;
    /** Reset all local hook state and triggers to an initial idle state. */
    reset: () => void;
    /**
     * Pause the scan and enter photo capture mode.
     * The AR session is preserved for relocalization when resuming.
     */
    pauseScan: () => void;
    /**
     * Resume the scan after taking photos.
     * Uses ARKit relocalization to continue from where the scan left off.
     */
    resumeScan: () => void;
  };
  state: {
    /** Whether the native view is currently scanning. */
    isRunning: boolean;
    /** Whether the scan is paused for photo capture mode. */
    isPaused: boolean;
    /** Whether ARKit is currently relocalizing. */
    isRelocalizing: boolean;
    /** Latest status reported by the native view. */
    status?: ScanStatus;
    /** True once the iOS preview UI has been presented for the current finish flow. */
    isPreviewVisible: boolean;
    /** Details of the last successful export, if any. */
    lastExport?: { scanUrl?: string; jsonUrl?: string };
    /** Last error message received from the native view, if any. */
    lastError?: string;
    /** Latest relocalization status message. */
    relocalizationMessage?: string;
  };
};

/**
 * React hook that controls the {@link RoomPlanView} and exposes a friendly API.
 *
 * It returns `viewProps` to spread onto the component, `controls` with imperative methods (start, cancel,
 * finishScan, addRoom, exportScan, reset), and `state` reflecting the current scanning lifecycle.
 *
 * @example
 * ```tsx
 * const { viewProps, controls } = useRoomPlanView({ scanName: 'Demo' });
 * return (
 *   <>
 *     <RoomPlanView {...viewProps} style={StyleSheet.absoluteFill} />
 *     <Button onPress={controls.finishScan} title="Finish" />
 *   </>
 * );
 * ```
 */
export function useRoomPlanView(options: UseRoomPlanViewOptions = {}): UseRoomPlanViewReturn {
  const {
    scanName,
    exportType,
    exportOnFinish = true,
    sendFileLoc = true,
    audioEnabled = false,
    stopAudioOnFinish = true,
    autoPhotoIntervalSec: initialAutoPhotoInterval,
    autoCloseOnTerminalStatus = false,
    onStatus,
    onPreview,
    onPhoto,
    onAudio,
    onAudioData,
    onExported,
    onPaused,
    onResumed,
    onRelocalizationStatus,
  } = options;

  // Internal control state
  const [running, setRunning] = useState(false);
  const [isPaused, setIsPaused] = useState(false);
  const [finishTrigger, setFinishTrigger] = useState<number | undefined>();
  const [addAnotherTrigger, setAddAnotherTrigger] = useState<number | undefined>();
  const [exportTrigger, setExportTrigger] = useState<number | undefined>();

  // Audio and Photo state
  const [capturePhotoTrigger, setCapturePhotoTrigger] = useState<number | undefined>();
  const [audioRunning, setAudioRunning] = useState<boolean>(false);
  const [autoPhotoIntervalSec, setAutoPhotoIntervalSec] = useState<number | undefined>(
    initialAutoPhotoInterval
  );

  // Pause/Resume state for photo capture mode
  const [pauseTrigger, setPauseTrigger] = useState<number | undefined>();
  const [resumeTrigger, setResumeTrigger] = useState<number | undefined>();

  // Derived UI state
  const [status, setStatus] = useState<ScanStatus | undefined>(undefined);
  const [isPreviewVisible, setPreviewVisible] = useState(false);
  const [lastExport, setLastExport] = useState<{ scanUrl?: string; jsonUrl?: string } | undefined>(
    undefined
  );
  const [lastError, setLastError] = useState<string | undefined>(undefined);
  const [isRelocalizing, setIsRelocalizing] = useState(false);
  const [relocalizationMessage, setRelocalizationMessage] = useState<string | undefined>(undefined);

  // Cache callbacks refs to avoid stale closures in event handlers
  const optsRef = useRef({
    onStatus,
    onPreview,
    onPhoto,
    onAudio,
    onAudioData,
    onExported,
    onPaused,
    onResumed,
    onRelocalizationStatus,
    autoCloseOnTerminalStatus,
  });
  optsRef.current = {
    onStatus,
    onPreview,
    onPhoto,
    onAudio,
    onAudioData,
    onExported,
    onPaused,
    onResumed,
    onRelocalizationStatus,
    autoCloseOnTerminalStatus,
  };

  // Controller methods
  const start = useCallback(() => {
    setRunning(true);
    setPreviewVisible(false);
    setLastError(undefined);
  }, []);

  const cancel = useCallback(() => {
    setRunning(false);
  }, []);

  const finishScan = useCallback(() => {
    setFinishTrigger(Date.now());
  }, []);

  const addRoom = useCallback(() => {
    setAddAnotherTrigger(Date.now());
    setPreviewVisible(false);
  }, []);

  const exportScan = useCallback(() => {
    setExportTrigger(Date.now());
  }, []);

  const capturePhoto = useCallback(() => {
    setCapturePhotoTrigger(Date.now());
  }, []);

  const startAudio = useCallback(() => {
    setAudioRunning(true);
  }, []);

  const stopAudio = useCallback(() => {
    setAudioRunning(false);
  }, []);

  const setAutoPhotoInterval = useCallback((sec?: number) => {
    setAutoPhotoIntervalSec(sec);
  }, []);

  /**
   * Pause the scan and enter photo capture mode.
   * The AR session is preserved for relocalization when resuming.
   */
  const pauseScan = useCallback(() => {
    const trigger = Date.now();
    console.log('[RoomPlan Hook] pauseScan called, setting trigger:', trigger);
    setPauseTrigger(trigger);
  }, []);

  /**
   * Resume the scan after taking photos.
   * Uses ARKit relocalization to continue from where the scan left off.
   */
  const resumeScan = useCallback(() => {
    setResumeTrigger(Date.now());
  }, []);

  const reset = useCallback(() => {
    setRunning(false);
    setIsPaused(false);
    setIsRelocalizing(false);
    setRelocalizationMessage(undefined);
    setFinishTrigger(undefined);
    setAddAnotherTrigger(undefined);
    setExportTrigger(undefined);
    setCapturePhotoTrigger(undefined);
    setPauseTrigger(undefined);
    setResumeTrigger(undefined);
    setAudioRunning(false);
    setAutoPhotoIntervalSec(initialAutoPhotoInterval);
    setPreviewVisible(false);
    setStatus(undefined);
    setLastError(undefined);
    setLastExport(undefined);
  }, [initialAutoPhotoInterval]);

  // Event handlers that keep internal state in sync but forward to user callbacks
  const handleStatus: NonNullable<RoomPlanViewProps['onStatus']> = useCallback((e) => {
    const s = e.nativeEvent.status as ScanStatus;
    const errorMessage = e.nativeEvent.errorMessage;
    setStatus(s);
    if (errorMessage) setLastError(errorMessage);
    if (optsRef.current.onStatus) optsRef.current.onStatus(e);

    if (optsRef.current.autoCloseOnTerminalStatus) {
      if (s === 'OK' || s === 'Error' || s === 'Canceled') {
        setRunning(false);
      }
    }
  }, []);

  const handlePreview = useCallback(() => {
    setPreviewVisible(true);
    if (optsRef.current.onPreview) optsRef.current.onPreview();
  }, []);

  const handlePhoto: RoomPlanViewProps['onPhoto'] = useCallback(
    (e: Parameters<NonNullable<RoomPlanViewProps['onPhoto']>>[0]) => {
      if (optsRef.current.onPhoto) optsRef.current.onPhoto(e);
    },
    []
  );

  const handleAudio: RoomPlanViewProps['onAudio'] = useCallback(
    (e: Parameters<NonNullable<RoomPlanViewProps['onAudio']>>[0]) => {
      if (optsRef.current.onAudio) optsRef.current.onAudio(e);
    },
    []
  );

  const handleAudioData: RoomPlanViewProps['onAudioData'] = useCallback(
    (e: Parameters<NonNullable<RoomPlanViewProps['onAudioData']>>[0]) => {
      if (optsRef.current.onAudioData) optsRef.current.onAudioData(e);
    },
    []
  );

  const handleExported: NonNullable<RoomPlanViewProps['onExported']> = useCallback((e) => {
    setLastExport({ ...e.nativeEvent });
    if (optsRef.current.onExported) optsRef.current.onExported(e);
  }, []);

  const handlePaused = useCallback(() => {
    setIsPaused(true);
    if (optsRef.current.onPaused) optsRef.current.onPaused();
  }, []);

  const handleResumed = useCallback(() => {
    setIsPaused(false);
    if (optsRef.current.onResumed) optsRef.current.onResumed();
  }, []);

  const handleRelocalizationStatus: RoomPlanViewProps['onRelocalizationStatus'] = useCallback(
    (e: Parameters<NonNullable<RoomPlanViewProps['onRelocalizationStatus']>>[0]) => {
      const { status, message } = e.nativeEvent;
      setRelocalizationMessage(message);

      if (status === 'relocalizing' || status === 'starting') {
        setIsRelocalizing(true);
      } else if (status === 'success' || status === 'unavailable') {
        setIsRelocalizing(false);
      }

      if (optsRef.current.onRelocalizationStatus) {
        optsRef.current.onRelocalizationStatus(e);
      }
    },
    []
  );

  const viewProps: RoomPlanViewProps = useMemo(
    () => ({
      // Identity props
      scanName,
      exportType,
      exportOnFinish,
      sendFileLoc,
      // Control props
      running,
      finishTrigger,
      addAnotherTrigger,
      exportTrigger,
      // Audio and Photo props
      audioEnabled,
      audioRunning,
      capturePhotoTrigger,
      autoPhotoIntervalSec,
      stopAudioOnFinish,
      // Pause/Resume props
      pauseTrigger,
      resumeTrigger,
      // Events
      onStatus: handleStatus,
      onPreview: handlePreview,
      onPhoto: handlePhoto,
      onAudio: handleAudio,
      onAudioData: handleAudioData,
      onExported: handleExported,
      onPaused: handlePaused,
      onResumed: handleResumed,
      onRelocalizationStatus: handleRelocalizationStatus,
    }),
    [
      scanName,
      exportType,
      exportOnFinish,
      sendFileLoc,
      running,
      finishTrigger,
      addAnotherTrigger,
      exportTrigger,
      audioEnabled,
      audioRunning,
      capturePhotoTrigger,
      autoPhotoIntervalSec,
      stopAudioOnFinish,
      pauseTrigger,
      resumeTrigger,
      handleStatus,
      handlePreview,
      handlePhoto,
      handleAudio,
      handleAudioData,
      handleExported,
      handlePaused,
      handleResumed,
      handleRelocalizationStatus,
    ]
  );

  return {
    viewProps,
    controls: {
      start,
      cancel,
      finishScan,
      addRoom,
      exportScan,
      capturePhoto,
      startAudio,
      stopAudio,
      setAutoPhotoInterval,
      reset,
      pauseScan,
      resumeScan,
    },
    state: {
      isRunning: running,
      isPaused,
      isRelocalizing,
      status,
      isPreviewVisible,
      lastExport,
      lastError,
      relocalizationMessage,
    },
  };
}

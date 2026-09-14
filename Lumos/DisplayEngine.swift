import CoreGraphics
import Foundation
import QuartzCore

/// Content-adaptive brightness controller for a single display. Same pipeline as before
/// (ScreenCaptureKit frame -> luminance -> stabilizer -> learnable curve -> ramped brightness),
/// but the actuation is injected as a `BrightnessBackend` so it works for the built-in panel
/// (DisplayServices) or an external monitor (DDC).
///
/// Corrections:
/// - Built-in (backend supports readback): a poll detects brightness-key / Control-Center changes.
/// - External (DDC): the in-app slider calls `commitUserBrightness`, and a background DDC poll
///   picks up changes made elsewhere (MonitorControl, the monitor's own buttons).
/// Both feed the same learning (`reinforce`) on this display's own curve.
final class DisplayEngine {
    let info: DisplayInfo

    // Reaction tuning.
    var jumpThreshold: Double = 0.15
    var fastRampPerSecond: Double = 6.0     // big brightening (dark content) — kept gentle to avoid a flash
    var dimRampPerSecond: Double = 50.0     // big dimming (content got brighter) — ~instant (one frame)
    var gentleRampPerSecond: Double = 2.0
    var settleTime: CFTimeInterval = 0.0 {
        didSet { stabilizer.settleTime = settleTime }
    }

    // Learning tuning.
    var overrideThreshold: Double = 0.04
    var overrideSettleTime: CFTimeInterval = 0.4
    /// Settle time for changes seen by the background (DDC) poll. Longer than the built-in's:
    /// shortcut taps arrive as separate steps with gaps, and the slider already reflects each
    /// step immediately, so only learn once the level has clearly stopped moving.
    var backgroundOverrideSettleTime: CFTimeInterval = 1.5

    var onUpdate: ((Double, Double) -> Void)?
    var onError: ((Error) -> Void)?
    var onLearn: (() -> Void)?
    /// Called when the user changes brightness while paused for an ignored app, so the
    /// coordinator can persist it as that app's remembered level for this display.
    var onIgnoredBrightnessSet: ((Double) -> Void)?

    private let sampler: LuminanceSampler
    private let backend: BrightnessBackend

    private var model: AdaptiveBrightnessModel

    private var stabilizer = LuminanceStabilizer()
    private var latestLuminance: Double = 0
    private var targetBrightness: Double = 1.0
    private var currentBrightness: Double = 1.0
    private var rampPerSecond: Double = 2.0
    private var controlTimer: Timer?
    private var lastTick: CFTimeInterval = 0

    // Override / manual-edit state.
    private var monitorTimer: Timer?                 // fallback poll when notifications unavailable
    private var pendingOverride: Double?             // used by the poll fallback
    private var pendingOverrideSince: CFTimeInterval = 0
    private var overrideDebounce: DispatchWorkItem?  // notification path: settle before committing
    private var isUserEditing = false

    // Background readback (slow backends, i.e. DDC). A read is skipped while our own writes are
    // recent — the monitor may still report the previous level — and ignored if a write raced it.
    // Readback is only trusted once the monitor has reported a level Lumos itself set, so a
    // monitor that returns a stale/constant value can't masquerade as a user change.
    private let readbackQueue = DispatchQueue(label: "Lumos.readback", qos: .utility)
    private var readbackGraceTime: CFTimeInterval = 1.0
    private var lastWriteTime: CFTimeInterval = 0
    private var hasWritten = false
    private var readbackVerified = false
    private var backgroundReadInFlight = false

    // Per-app pause (ignore list). While `ignoredMode` is on, content-adaptive adjustment is
    // suspended and the display holds the app's remembered level; manual changes update that
    // remembered level instead of the learning curve.
    private var ignoredMode = false
    private var ignoredPreferred: Double?

    // Capture recovery.
    private var isLaunching = false
    private var captureRetry = 0
    private let maxCaptureRetries = 12

    private(set) var isRunning = false

    init(info: DisplayInfo, backend: BrightnessBackend) {
        self.info = info
        self.backend = backend
        self.sampler = LuminanceSampler(displayID: info.displayID)
        self.model = AdaptiveBrightnessModel.loadOrDefault(key: info.persistKey)
    }

    var brightnessAvailable: Bool { backend.isAvailable }
    var displayedBrightness: Double { currentBrightness }
    var displayedLuminance: Double { latestLuminance }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if let hw = backend.read() {
            currentBrightness = hw
            targetBrightness = hw
        }

        stabilizer = LuminanceStabilizer()
        stabilizer.settleTime = settleTime

        sampler.onFrame = { [weak self] lum in
            DispatchQueue.main.async { self?.ingest(luminance: lum) }
        }
        sampler.onError = { [weak self] error in
            // Stream stopped (display sleep, resolution change, etc.) — recover, don't give up.
            DispatchQueue.main.async { self?.handleCaptureStopped(error) }
        }

        if backend.supportsReadback {
            // Prefer event-driven brightness-change notifications; poll only if unavailable.
            let observing = backend.observeBrightnessChanges { [weak self] in
                self?.handleBrightnessChangeNotification()
            }
            if !observing { startMonitor() }
        } else if let interval = backend.backgroundPollInterval {
            startBackgroundMonitor(interval: interval)
        }

        launchCapture()
    }

    // MARK: - Capture lifecycle / recovery

    /// Re-establishes capture after a sleep/wake or display reconfiguration. Resets the retry
    /// budget so a long-asleep display reconnects cleanly.
    ///
    /// Critically, it re-synchronizes our brightness belief with the hardware. During sleep/wake
    /// macOS can change the actual brightness (wake fade-in, a restored level), leaving
    /// `currentBrightness` stale. Without re-syncing, the override monitor reads the hardware,
    /// sees it differ from our stale belief, and treats it as a *user* change — which parks
    /// auto-adjust (`pendingOverride`) until the user manually nudges brightness. Re-reading here
    /// keeps the override detector honest and lets auto-adjust resume immediately.
    func restartCapture() {
        guard isRunning else { start(); return }
        captureRetry = 0
        pendingOverride = nil
        overrideDebounce?.cancel(); overrideDebounce = nil
        if backend.supportsReadback, let hw = backend.read() {
            currentBrightness = hw
            // Retarget to what the current (already-settled) content wants, so the loop ramps
            // from the true hardware level to the content-appropriate brightness. If no content
            // has settled yet, leave the target at the hardware level and let frames drive it.
            targetBrightness = stabilizer.committed >= 0
                ? model.brightness(forLuminance: stabilizer.committed)
                : hw
            ensureControlTimer() // guarantee the ramp runs even if no new frame arrives
        }
        launchCapture()
    }

    private func launchCapture() {
        guard isRunning, !isLaunching else { return }
        isLaunching = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sampler.start()
                await MainActor.run { self.isLaunching = false }
            } catch {
                await MainActor.run {
                    self.isLaunching = false
                    self.scheduleCaptureRetry(error)
                }
            }
        }
    }

    private func handleCaptureStopped(_ error: Error) {
        guard isRunning else { return }
        scheduleCaptureRetry(error)
    }

    /// During wake, displays are briefly unavailable (`SCShareableContent` returns none). Retry
    /// with backoff; only surface an error after many failures (e.g. permission truly revoked).
    private func scheduleCaptureRetry(_ error: Error) {
        guard isRunning else { return }
        guard captureRetry < maxCaptureRetries else {
            onError?(error)
            return
        }
        captureRetry += 1
        let delay = min(0.5 * Double(captureRetry), 3.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning else { return }
            self.launchCapture()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sampler.onFrame = nil
        Task { [sampler] in await sampler.stop() }
        DispatchQueue.main.async { [weak self] in
            self?.controlTimer?.invalidate(); self?.controlTimer = nil
            self?.monitorTimer?.invalidate(); self?.monitorTimer = nil
            self?.overrideDebounce?.cancel(); self?.overrideDebounce = nil
            self?.pendingOverride = nil
            self?.backend.stopObservingBrightnessChanges()
        }
    }

    func resetLearning() {
        model = AdaptiveBrightnessModel()
        model.save(key: info.persistKey)
        onLearn?()
    }

    // MARK: - Per-app pause (ignore list)

    /// Enters or leaves "paused" mode for the frontmost app. When paused, auto-adjust stops and
    /// the display ramps to `preferredBrightness` (the app's remembered level), if known;
    /// otherwise it simply holds where it is until the user picks a level. Leaving paused mode
    /// resumes adaptation from the current content.
    func setIgnored(_ ignored: Bool, preferredBrightness: Double?) {
        if ignored {
            ignoredPreferred = preferredBrightness
            if let pref = preferredBrightness {
                ignoredMode = true
                targetBrightness = max(0, min(1, pref))
                rampPerSecond = gentleRampPerSecond
                ensureControlTimer()
            } else if !ignoredMode {
                // No remembered level yet — stop adapting and hold the current brightness.
                ignoredMode = true
                targetBrightness = currentBrightness
            } else {
                ignoredMode = true
            }
        } else {
            guard ignoredMode else { return }
            ignoredMode = false
            ignoredPreferred = nil
            // Resume auto-adjust: retarget to what the current content wants and ramp there.
            let newTarget = model.brightness(forLuminance: max(0, min(1, latestLuminance)))
            let delta = newTarget - currentBrightness
            rampPerSecond = abs(delta) >= jumpThreshold
                ? (delta < 0 ? dimRampPerSecond : fastRampPerSecond)
                : gentleRampPerSecond
            targetBrightness = newTarget
            ensureControlTimer()
        }
    }

    // MARK: - Manual correction (slider)

    /// Live preview while dragging: apply immediately and pause auto-adjust, without learning yet.
    func previewUserBrightness(_ value: Double) {
        isUserEditing = true
        let v = max(0, min(1, value))
        currentBrightness = v
        targetBrightness = v
        writeHardware(v)
        onUpdate?(latestLuminance, v)
    }

    /// Final value when the user releases the slider: apply, learn, and resume auto-adjust.
    func commitUserBrightness(_ value: Double) {
        let v = max(0, min(1, value))
        currentBrightness = v
        targetBrightness = v
        writeHardware(v)
        isUserEditing = false
        if ignoredMode {
            // Paused for an app: remember this as the app's preferred level, don't reshape the curve.
            ignoredPreferred = v
            onUpdate?(latestLuminance, v)
            onIgnoredBrightnessSet?(v)
        } else {
            model.reinforce(luminance: stabilizer.committed, brightness: v)
            model.save(key: info.persistKey)
            onUpdate?(latestLuminance, v)
            onLearn?()
        }
    }

    // MARK: - Control loop (main thread)

    private func ingest(luminance lum: Double) {
        captureRetry = 0 // frames are flowing again
        latestLuminance = lum
        ensureControlTimer()
    }

    private func ensureControlTimer() {
        guard controlTimer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.controlTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        controlTimer = timer
    }

    private func controlTick() {
        let now = CACurrentMediaTime()
        let dt = max(0, now - lastTick)
        lastTick = now

        // Keep advancing the stabilizer so `committed` stays fresh for when we resume, but only
        // retarget from content while not paused for an ignored app.
        let settled = stabilizer.update(luminance: latestLuminance, now: now)
        if settled, !ignoredMode {
            let newTarget = model.brightness(forLuminance: stabilizer.committed)
            let delta = newTarget - currentBrightness
            if abs(delta) >= jumpThreshold {
                // Dimming (content got brighter) is sped up to minimize the brightness flare;
                // brightening stays gentler so it doesn't flash.
                rampPerSecond = delta < 0 ? dimRampPerSecond : fastRampPerSecond
            } else {
                rampPerSecond = gentleRampPerSecond
            }
            targetBrightness = newTarget
        }

        // Don't fight the user (key override in progress, or actively dragging the slider).
        if !isUserAdjustingBrightness, !isUserEditing {
            let diff = targetBrightness - currentBrightness
            if abs(diff) > 0.0005 {
                let step = rampPerSecond * dt
                currentBrightness = abs(diff) <= step
                    ? targetBrightness
                    : currentBrightness + (diff > 0 ? step : -step)
                writeHardware(currentBrightness)
            }
        }
        onUpdate?(latestLuminance, currentBrightness)

        // While paused, brightness is decoupled from content, so the timer can stop as soon as
        // the backlight has settled — even if the (ignored) content keeps changing.
        let luminanceSettled = abs(latestLuminance - stabilizer.committed) <= stabilizer.noiseBand
        let brightnessSettled = abs(targetBrightness - currentBrightness) <= 0.0005
        let canStop = brightnessSettled && (ignoredMode || luminanceSettled)
        if !isUserAdjustingBrightness, !isUserEditing, canStop {
            controlTimer?.invalidate()
            controlTimer = nil
        }
    }

    /// True only while the loop is genuinely driving the backlight toward a content target — the
    /// control timer is live AND we're not parked. When auto-adjust is parked by a detected
    /// override (`pendingOverride`) or an active slider edit, the loop isn't writing, so it must
    /// NOT count as "ramping".
    ///
    /// Without the parked checks this deadlocks: the override poll skips ticks while "ramping", but
    /// a parked loop never closes the target/current gap, so it looks like it's ramping forever —
    /// the poll keeps skipping and the override never commits, so the park never lifts. That is
    /// what stranded auto-adjust after sleep/wake: macOS nudges the backlight during the wake fade,
    /// the poll reads it as an override and parks, and only a manual brightness change (which snaps
    /// current==target) could break the cycle. Now the poll resolves it on its own.
    private var isActivelyRamping: Bool {
        controlTimer != nil && !isUserAdjustingBrightness && !isUserEditing
            && abs(targetBrightness - currentBrightness) > 0.005
    }

    /// True while the user is actively changing brightness (poll pending, or a notification
    /// debounce in flight) — auto-adjust pauses so we don't fight them.
    private var isUserAdjustingBrightness: Bool { pendingOverride != nil || overrideDebounce != nil }

    // MARK: - Override detection

    /// Event-driven override detection. DisplayServices calls this (on the main thread) for
    /// every hardware brightness change — including our own ramp writes, which the
    /// `overrideThreshold` check in `commitBrightnessOverrideIfNeeded` filters out. We debounce
    /// so a brightness key held down (which ramps in many small steps) commits a single override.
    private func handleBrightnessChangeNotification() {
        guard !isActivelyRamping, !isUserEditing else { return }
        overrideDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitBrightnessOverrideIfNeeded() }
        overrideDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + overrideSettleTime, execute: work)
    }

    private func commitBrightnessOverrideIfNeeded() {
        overrideDebounce = nil
        guard !isActivelyRamping, !isUserEditing, let hw = backend.read() else { return }
        if abs(hw - currentBrightness) > overrideThreshold {
            commitOverride(brightness: hw)
        }
    }

    private func startMonitor() {
        guard monitorTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.monitorTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
    }

    private func writeHardware(_ value: Double) {
        backend.write(value)
        lastWriteTime = CACurrentMediaTime()
        hasWritten = true
    }

    private func monitorTick() {
        guard !isActivelyRamping, !isUserEditing else { return }
        guard let hw = backend.read() else { return }
        evaluateReadback(hw, settleTime: overrideSettleTime)
    }

    private func startBackgroundMonitor(interval: TimeInterval) {
        guard monitorTimer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.backgroundMonitorTick()
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
    }

    /// Same override detection as `monitorTick`, but the (blocking) read runs off the main thread.
    private func backgroundMonitorTick() {
        let startedAt = CACurrentMediaTime()
        guard !backgroundReadInFlight, !isActivelyRamping, !isUserEditing,
              startedAt - lastWriteTime >= readbackGraceTime else { return }
        backgroundReadInFlight = true
        readbackQueue.async { [weak self, backend] in
            let hw = backend.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.backgroundReadInFlight = false
                guard self.isRunning, let hw, !self.isActivelyRamping, !self.isUserEditing,
                      self.lastWriteTime < startedAt else { return }
                if !self.readbackVerified {
                    if self.hasWritten, abs(hw - self.currentBrightness) <= 0.02 {
                        self.readbackVerified = true
                    }
                    return
                }
                self.evaluateReadback(hw, settleTime: self.backgroundOverrideSettleTime)
            }
        }
    }

    private func evaluateReadback(_ hw: Double, settleTime: CFTimeInterval) {
        let now = CACurrentMediaTime()

        if let pending = pendingOverride {
            if abs(hw - pending) > 0.005 {
                pendingOverride = hw
                pendingOverrideSince = now
                reflectPendingOverride(hw)
            } else if now - pendingOverrideSince >= settleTime {
                commitOverride(brightness: hw)
            }
        } else if abs(hw - currentBrightness) > overrideThreshold {
            pendingOverride = hw
            pendingOverrideSince = now
            reflectPendingOverride(hw)
        }
    }

    /// Shows an outside change right away instead of waiting for it to settle; learning still
    /// waits for `commitOverride`. Safe because the control loop is parked while an override is
    /// pending, so nothing writes `currentBrightness` back to the hardware meanwhile.
    private func reflectPendingOverride(_ hw: Double) {
        currentBrightness = hw
        onUpdate?(latestLuminance, hw)
    }

    private func commitOverride(brightness hw: Double) {
        pendingOverride = nil
        currentBrightness = hw
        targetBrightness = hw
        if ignoredMode {
            // Paused for an app: remember this level for the app, don't reshape the curve.
            ignoredPreferred = hw
            onUpdate?(latestLuminance, currentBrightness)
            onIgnoredBrightnessSet?(hw)
        } else {
            model.reinforce(luminance: stabilizer.committed, brightness: hw)
            model.save(key: info.persistKey)
            onUpdate?(latestLuminance, currentBrightness)
            onLearn?()
        }
    }
}

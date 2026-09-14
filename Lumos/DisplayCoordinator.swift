import AppKit
import CoreGraphics
import Foundation

/// Identity + metadata for a controllable display.
struct DisplayInfo: Identifiable, Equatable {
    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    /// Stable key for persisting this display's learned curve across reconnects/reboots.
    let persistKey: String

    var id: CGDirectDisplayID { displayID }
}

/// Owns one `DisplayEngine` per controllable display (built-in via DisplayServices + every
/// DDC-controllable external), starting/stopping them together and rebuilding on hotplug.
final class DisplayCoordinator {
    private(set) var engines: [CGDirectDisplayID: DisplayEngine] = [:]
    private(set) var order: [CGDirectDisplayID] = []

    var settleTime: CFTimeInterval = 0.0 {
        didSet { engines.values.forEach { $0.settleTime = settleTime } }
    }

    /// Called on the main thread when the set of displays changes (hotplug).
    var onDisplaysChanged: (() -> Void)?
    /// (displayID, luminance, brightness) on the main thread.
    var onUpdate: ((CGDirectDisplayID, Double, Double) -> Void)?
    /// (displayID) on the main thread when a display's curve learns.
    var onLearn: ((CGDirectDisplayID) -> Void)?
    var onError: ((Error) -> Void)?
    /// Called on the main thread when the frontmost app or the ignore list changes.
    var onIgnoreStateChanged: (() -> Void)?

    private let externalManager = ExternalDisplayManager()
    private let ignoreStore = IgnoredAppsStore()
    private var isRunning = false
    private var observing = false

    /// Most recent frontmost app that isn't Lumos itself — the app the "pause" control acts on.
    private(set) var lastActiveBundleID: String?
    private(set) var lastActiveAppName: String?
    /// The bundle ID currently gating brightness, when it's an ignored app (else nil).
    private var currentIgnoredBundleID: String?

    var displays: [DisplayInfo] { order.compactMap { engines[$0]?.info } }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        rebuild()
        observeHotplug()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engines.values.forEach { $0.stop() }
        engines.removeAll()
        order.removeAll()
    }

    func resetLearning(displayID: CGDirectDisplayID) { engines[displayID]?.resetLearning() }
    func resetAllLearning() { engines.values.forEach { $0.resetLearning() } }

    func previewBrightness(displayID: CGDirectDisplayID, _ value: Double) {
        engines[displayID]?.previewUserBrightness(value)
    }
    func commitBrightness(displayID: CGDirectDisplayID, _ value: Double) {
        engines[displayID]?.commitUserBrightness(value)
    }

    // MARK: - Per-app pause (ignore list)

    var ignoredApps: [IgnoredApp] { ignoreStore.all }
    func isIgnored(_ bundleID: String) -> Bool { ignoreStore.isIgnored(bundleID) }

    /// The app the "pause" control currently acts on (the last frontmost app that isn't Lumos).
    var pausableApp: (bundleID: String, name: String)? {
        guard let id = lastActiveBundleID, let name = lastActiveAppName else { return nil }
        return (id, name)
    }

    func toggleIgnore(bundleID: String, name: String) {
        if ignoreStore.isIgnored(bundleID) {
            ignoreStore.remove(bundleID: bundleID)
        } else {
            ignoreStore.add(bundleID: bundleID, name: name)
        }
        applyIgnoreState()
        onIgnoreStateChanged?()
    }

    /// Pauses an app picked by search (it doesn't have to be, or have been, frontmost).
    func addIgnored(bundleID: String, name: String) {
        ignoreStore.add(bundleID: bundleID, name: name)
        applyIgnoreState()
        onIgnoreStateChanged?()
    }

    func removeIgnored(bundleID: String) {
        ignoreStore.remove(bundleID: bundleID)
        applyIgnoreState()
        onIgnoreStateChanged?()
    }

    /// Pushes the current pause state (driven by the frontmost app) to every engine.
    private func applyIgnoreState() {
        let bundleID = lastActiveBundleID
        let ignored = bundleID.map { ignoreStore.isIgnored($0) } ?? false
        currentIgnoredBundleID = ignored ? bundleID : nil
        for engine in engines.values {
            if ignored, let bundleID {
                let pref = ignoreStore.preferredBrightness(bundleID: bundleID,
                                                           persistKey: engine.info.persistKey)
                engine.setIgnored(true, preferredBrightness: pref)
            } else {
                engine.setIgnored(false, preferredBrightness: nil)
            }
        }
    }

    private func handleFrontmostChange(_ app: NSRunningApplication?) {
        if let bundleID = app?.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier {
            lastActiveBundleID = bundleID
            lastActiveAppName = app?.localizedName ?? bundleID
        }
        applyIgnoreState()
        onIgnoreStateChanged?()
    }

    // MARK: - Building the engine set

    /// Rebuilds engines to match currently connected, controllable displays. Keeps existing
    /// engines for displays that are still present (preserves their running state/curve cache).
    private func rebuild() {
        guard isRunning else { return }
        let desired = currentControllableDisplays()      // [(DisplayInfo, BrightnessBackend)]
        let desiredIDs = Set(desired.map { $0.info.displayID })

        // Remove engines for displays that went away.
        for (id, engine) in engines where !desiredIDs.contains(id) {
            engine.stop()
            engines[id] = nil
        }

        // Add engines for new displays.
        for (info, backend) in desired where engines[info.displayID] == nil {
            let engine = DisplayEngine(info: info, backend: backend)
            engine.settleTime = settleTime
            engine.onUpdate = { [weak self] lum, bri in self?.onUpdate?(info.displayID, lum, bri) }
            engine.onLearn = { [weak self] in self?.onLearn?(info.displayID) }
            engine.onError = { [weak self] err in self?.onError?(err) }
            engine.onIgnoredBrightnessSet = { [weak self] value in
                guard let self, let bundleID = self.currentIgnoredBundleID else { return }
                self.ignoreStore.setPreferredBrightness(value, bundleID: bundleID,
                                                         persistKey: info.persistKey)
            }
            engines[info.displayID] = engine
            engine.start()
        }

        order = desired.map { $0.info.displayID }
        applyIgnoreState() // newly created engines need the current pause state pushed to them
        onDisplaysChanged?()
    }

    private func currentControllableDisplays() -> [(info: DisplayInfo, backend: BrightnessBackend)] {
        var result: [(DisplayInfo, BrightnessBackend)] = []

        // Built-in panel — only when it's actually active (not with the lid closed).
        if let builtInID = BrightnessController.activeBuiltInDisplayID() {
            let builtIn = BuiltInBrightnessBackend(displayID: builtInID)
            if builtIn.isAvailable {
                let info = DisplayInfo(displayID: builtInID,
                                       name: "Built-in Display",
                                       isBuiltIn: true,
                                       persistKey: persistKey(for: builtInID, fallback: "builtin"))
                result.append((info, builtIn))
            }
        }

        // DDC-controllable externals. Display IDs must be unique: engines and the menu's
        // ForEach are keyed by them, and a duplicate renders one display twice.
        for ext in externalManager.detect() where !result.contains(where: { $0.0.displayID == ext.displayID }) {
            let info = DisplayInfo(displayID: ext.displayID,
                                   name: ext.name,
                                   isBuiltIn: false,
                                   persistKey: persistKey(for: ext.displayID, fallback: ext.name))
            result.append((info, ext.backend))
        }
        return result
    }

    /// Stable per-display key from its CoreGraphics UUID (survives reconnect); falls back to a name.
    private func persistKey(for displayID: CGDirectDisplayID, fallback: String) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return fallback
    }

    // MARK: - Hotplug & sleep/wake recovery

    private func observeHotplug() {
        guard !observing else { return }
        observing = true

        // Display add/remove/resolution change.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleDisplayChange()
        }

        // System / display wake (lid open, sleep/wake): streams die while asleep, so re-establish.
        let wsnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wsnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleWake()
            }
        }

        // Frontmost app changes drive the per-app pause (ignore list).
        wsnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                         object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.handleFrontmostChange(app)
        }
        handleFrontmostChange(NSWorkspace.shared.frontmostApplication) // seed initial state
    }

    private func handleDisplayChange() {
        guard isRunning else { return }
        rebuild() // add new / remove gone displays
        engines.values.forEach { $0.restartCapture() } // re-establish streams that may have dropped
        applyIgnoreState() // restartCapture retargets to content; restore pause state on top
    }

    private func handleWake() {
        guard isRunning else { return }
        // External DDC service handles (IOAVService) can go stale across a sleep where the display
        // dropped, so drop external engines and let rebuild() recreate them with fresh services.
        // The built-in's DisplayServices handle stays valid, so its engine is kept.
        let externalIDs = engines.filter { !$0.value.info.isBuiltIn }.map(\.key)
        for id in externalIDs {
            engines[id]?.stop()
            engines[id] = nil
        }
        rebuild() // recreates externals with fresh backends; adds/removes displays as needed
        engines.values.forEach { $0.restartCapture() } // re-establish streams that died while asleep
        applyIgnoreState() // restartCapture retargets to content; restore pause state on top
    }
}

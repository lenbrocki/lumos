import CoreGraphics
import Foundation

/// Wraps the private `DisplayServices.framework` brightness symbols, resolved at
/// runtime via `dlopen`/`dlsym` so there is no link-time dependency on a private
/// framework. Operates on the built-in display. If the symbols cannot be resolved
/// (future macOS change), `isAvailable` is false and calls become no-ops.
final class BrightnessController {
    private typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    // Notification callback's args are unreliable (the display id comes through as 0), so we
    // ignore them and re-read hardware. Verified ABI: a C function pointer, not a block.
    private typealias ChangeCallback = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Void
    private typealias RegisterFunc = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, ChangeCallback) -> Void

    private let setFunc: SetBrightnessFunc?
    private let getFunc: GetBrightnessFunc?
    private let registerFunc: RegisterFunc?
    private let unregisterFunc: RegisterFunc?
    private let displayID: CGDirectDisplayID

    init(displayID: CGDirectDisplayID = BrightnessController.builtInDisplayID()) {
        self.displayID = displayID

        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else {
            NSLog("Lumos: failed to dlopen DisplayServices: \(String(cString: dlerror()))")
            setFunc = nil
            getFunc = nil
            registerFunc = nil
            unregisterFunc = nil
            return
        }
        setFunc = dlsym(handle, "DisplayServicesSetBrightness").map {
            unsafeBitCast($0, to: SetBrightnessFunc.self)
        }
        getFunc = dlsym(handle, "DisplayServicesGetBrightness").map {
            unsafeBitCast($0, to: GetBrightnessFunc.self)
        }
        registerFunc = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications").map {
            unsafeBitCast($0, to: RegisterFunc.self)
        }
        unregisterFunc = dlsym(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications").map {
            unsafeBitCast($0, to: RegisterFunc.self)
        }
        if setFunc == nil {
            NSLog("Lumos: DisplayServicesSetBrightness symbol not found")
        }
    }

    var isAvailable: Bool { setFunc != nil }

    /// Current backlight level in 0...1, or nil if unavailable.
    func getBrightness() -> Float? {
        guard let getFunc else { return nil }
        var value: Float = 0
        return getFunc(displayID, &value) == 0 ? value : nil
    }

    /// Sets the backlight level, clamped to 0...1. Returns true on success.
    @discardableResult
    func setBrightness(_ value: Float) -> Bool {
        guard let setFunc else { return false }
        let clamped = max(0, min(1, value))
        return setFunc(displayID, clamped) == 0
    }

    // MARK: - Brightness-change notifications

    /// Whether event-driven brightness-change notifications are available (replaces polling).
    var supportsChangeNotifications: Bool { registerFunc != nil }

    // The C callback can't capture, so handlers live in a static registry keyed by display.
    private static let registryLock = NSLock()
    private static var handlers: [CGDirectDisplayID: () -> Void] = [:]

    /// Invoked by DisplayServices (on a background dispatch queue) for any brightness change.
    /// The display argument is not reliable, so we notify every registered handler; each
    /// re-reads its own hardware and decides whether anything actually changed.
    private static let trampoline: ChangeCallback = { _, _ in
        registryLock.lock()
        let handlers = Array(BrightnessController.handlers.values)
        registryLock.unlock()
        DispatchQueue.main.async { handlers.forEach { $0() } }
    }

    /// Subscribes to hardware brightness changes for this display. `handler` runs on the main
    /// thread. Returns false if the private symbol is unavailable (caller should fall back to
    /// polling).
    @discardableResult
    func observeBrightnessChanges(_ handler: @escaping () -> Void) -> Bool {
        guard let registerFunc else { return false }
        BrightnessController.registryLock.lock()
        let alreadyRegistered = BrightnessController.handlers[displayID] != nil
        BrightnessController.handlers[displayID] = handler
        BrightnessController.registryLock.unlock()
        if !alreadyRegistered {
            registerFunc(displayID, nil, BrightnessController.trampoline)
        }
        return true
    }

    func stopObservingBrightnessChanges() {
        BrightnessController.registryLock.lock()
        let wasRegistered = BrightnessController.handlers.removeValue(forKey: displayID) != nil
        BrightnessController.registryLock.unlock()
        if wasRegistered, let unregisterFunc {
            unregisterFunc(displayID, nil, BrightnessController.trampoline)
        }
    }

    /// Finds the built-in panel; falls back to the main display.
    static func builtInDisplayID() -> CGDirectDisplayID {
        activeBuiltInDisplayID() ?? CGMainDisplayID()
    }

    /// The built-in panel's ID if it is currently active, else nil (e.g. lid closed in clamshell
    /// mode, where the main display is an external and must not be mistaken for the built-in).
    static func activeBuiltInDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
    }
}

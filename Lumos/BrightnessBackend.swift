import CoreGraphics
import Foundation

/// Abstracts "set the brightness of one display" so the engine can drive either the built-in
/// panel (DisplayServices) or an external monitor (DDC/CI over I2C) the same way.
protocol BrightnessBackend: AnyObject {
    var isAvailable: Bool { get }
    /// Whether `read()` reliably reflects the hardware (built-in: yes; DDC: no on many monitors).
    /// Used to decide whether the engine can detect user overrides by polling.
    var supportsReadback: Bool { get }
    func read() -> Double?
    func write(_ value: Double)

    /// For backends whose `read()` is slow (blocking I/O) and has no change notifications: how
    /// often the engine should poll it off the main thread to catch changes made outside Lumos
    /// (another app, the monitor's own buttons). nil = don't background-poll.
    var backgroundPollInterval: TimeInterval? { get }

    /// Subscribe to hardware brightness changes (event-driven; the handler runs on the main
    /// thread). Returns false if change notifications aren't supported, in which case the
    /// engine falls back to polling `read()`.
    func observeBrightnessChanges(_ handler: @escaping () -> Void) -> Bool
    func stopObservingBrightnessChanges()
}

/// Built-in panel via the private DisplayServices framework (wraps `BrightnessController`).
final class BuiltInBrightnessBackend: BrightnessBackend {
    private let controller: BrightnessController

    init(displayID: CGDirectDisplayID = BrightnessController.builtInDisplayID()) {
        controller = BrightnessController(displayID: displayID)
    }

    var isAvailable: Bool { controller.isAvailable }
    var supportsReadback: Bool { true }
    var backgroundPollInterval: TimeInterval? { nil }
    func read() -> Double? { controller.getBrightness().map(Double.init) }
    func write(_ value: Double) { controller.setBrightness(Float(value)) }

    func observeBrightnessChanges(_ handler: @escaping () -> Void) -> Bool {
        controller.observeBrightnessChanges(handler)
    }
    func stopObservingBrightnessChanges() { controller.stopObservingBrightnessChanges() }
}

/// External monitor via DDC/CI (VCP `0x10` = luminance), using the vendored `Arm64DDC`.
/// Readback is slow (blocking I2C) and not trusted on every monitor, so it isn't used for the
/// main-thread readback path; instead the engine polls it in the background and only acts on it
/// once the monitor has shown that it reports back what Lumos wrote.
final class DDCBrightnessBackend: BrightnessBackend {
    private let service: IOAVService?
    private let maxValue: UInt16
    private let canRead: Bool
    /// Serializes I2C transactions: writes come from the main thread, polled reads from a
    /// background queue, and interleaving them on one service garbles both.
    private let ioLock = NSLock()
    private(set) var lastWritten: Double

    init?(match: Arm64DDC.Arm64Service) {
        guard match.service != nil, !match.dummy else { return nil }
        service = match.service
        // Probe the display's max VCP value (most report 100); fall back to 100.
        let probe = Arm64DDC.read(service: match.service, command: 0x10)
        maxValue = (probe?.max ?? 0) > 0 ? probe!.max : 100
        if let p = probe, p.max > 0 {
            lastWritten = Double(p.current) / Double(p.max)
            canRead = p.current <= p.max
        } else {
            lastWritten = 1.0
            canRead = false
        }
    }

    var isAvailable: Bool { service != nil }
    var supportsReadback: Bool { false }
    // A read is ~70 ms of I2C on a background queue, so this is cheap; shorter feels instant.
    var backgroundPollInterval: TimeInterval? { canRead ? 0.5 : nil }

    func read() -> Double? {
        ioLock.lock(); defer { ioLock.unlock() }
        guard let r = Arm64DDC.read(service: service, command: 0x10), r.max > 0, r.current <= r.max
        else { return nil }
        return Double(r.current) / Double(r.max)
    }

    func write(_ value: Double) {
        let clamped = max(0, min(1, value))
        lastWritten = clamped
        let raw = UInt16((Double(maxValue) * clamped).rounded())
        ioLock.lock(); defer { ioLock.unlock() }
        _ = Arm64DDC.write(service: service, command: 0x10, value: raw)
    }

    // DDC monitors have no change-notification path; the engine polls via `backgroundPollInterval`.
    func observeBrightnessChanges(_ handler: @escaping () -> Void) -> Bool { false }
    func stopObservingBrightnessChanges() {}
}

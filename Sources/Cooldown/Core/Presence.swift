import AppKit
import CoreGraphics
import Foundation

/// Whether someone is actually at this Mac. Only real input counts: a hardware mouse, trackpad or
/// keyboard. Input other apps make up — Codex Computer Use, remote control from a phone, scripts —
/// keeps the Mac's own idle timer at zero, which made the phone think you were here.
///
/// Listens (never changes anything) through an event tap; needs the Accessibility permission
/// Cooldown already has for Claude. Without it, falls back to the system idle time.
final class Presence: @unchecked Sendable {
    static let shared = Presence()

    private let lock = NSLock()
    private var lastPhysical = Date()       // at launch: assume someone is here
    private var lastSynthetic: Date?
    private var displayAsleep = false
    private var tap: CFMachPort?
    private(set) var reading = false        // the event tap works

    /// Seconds since the last real input.
    var idle: TimeInterval {
        guard reading else { return Self.systemIdle }
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastPhysical)
    }

    /// Something other than a person is moving the mouse or typing right now (within a minute).
    var drivenByApp: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let lastSynthetic else { return false }
        return Date().timeIntervalSince(lastSynthetic) < 60
    }

    var asleep: Bool {
        lock.lock(); defer { lock.unlock() }
        return displayAsleep
    }

    static var locked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static var systemIdle: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Nobody at the Mac, and why — for the phone and for the log.
    func away(after seconds: TimeInterval = 120) -> (away: Bool, reason: String) {
        if Self.locked { return (true, "locked") }
        if asleep { return (true, "display asleep") }
        let idle = idle
        if idle > seconds { return (true, "no input for \(Int(idle)) s" + (drivenByApp ? " (an app is driving the Mac)" : "")) }
        return (false, "input \(Int(idle)) s ago" + (reading ? "" : " (system idle)"))
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.set(asleep: true)
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.set(asleep: false)
        }
        openTap()
    }

    private func set(asleep: Bool) {
        lock.lock(); displayAsleep = asleep; lock.unlock()
        AgentActivity.trace("presence: display \(asleep ? "asleep" : "awake")")
    }

    private func openTap() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
                                    .leftMouseDragged, .keyDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<Presence>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            // Hardware input comes from the HID system with no process behind it.
            let physical = event.getIntegerValueField(.eventSourceUnixProcessID) == 0
                && event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue)
            me.lock.lock()
            if physical { me.lastPhysical = Date() } else { me.lastSynthetic = Date() }
            me.lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            AgentActivity.trace("presence: no event tap (permission?) — using the system idle time")
            // Try again later: the permission may be granted while Cooldown runs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in self?.openTap() }
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        reading = true
        AgentActivity.trace("presence: reading real input")
    }
}

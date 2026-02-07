import AppKit
import Carbon

/// Listens for a configurable modifier key being held/released to control push-to-talk dictation.
/// Uses NSEvent global monitor for flagsChanged events to detect modifier key state.
/// The trigger key is read from AppSettings; call `restartListening()` after changing it.
class HotkeyManager {

    // MARK: - Properties

    /// Callback invoked when the trigger key is pressed down (start recording).
    private let onKeyDown: () -> Void

    /// Callback invoked when the trigger key is released (stop recording).
    private let onKeyUp: () -> Void

    /// The global event monitor handle.
    private var globalMonitor: Any?

    /// The local event monitor handle (for when our app is focused).
    private var localMonitor: Any?

    /// Track whether the trigger key is currently held to avoid duplicate events.
    private var keyIsDown = false

    /// Timestamp of the last processed event, used to deduplicate.
    private var lastEventTimestamp: TimeInterval = 0

    // MARK: - Initialization

    /// Create a hotkey manager with separate press/release callbacks.
    /// - Parameters:
    ///   - onKeyDown: Called when the trigger key is pressed (start recording).
    ///   - onKeyUp: Called when the trigger key is released (stop recording).
    init(onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void) {
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
    }

    deinit {
        stopListening()
    }

    // MARK: - Listening

    /// Start listening for the configured trigger key press/release.
    func startListening() {
        let triggerKey = AppSettings.shared.triggerKey
        print("[HotkeyManager] Listening for \(triggerKey.shortName) key (hold to record, release to stop)")

        // Global monitor — fires when any other app is focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Local monitor — fires when our app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    /// Stop listening for key events.
    func stopListening() {
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        keyIsDown = false
    }

    /// Restart listening (e.g. after trigger key configuration changes).
    func restartListening() {
        stopListening()
        startListening()
    }

    // MARK: - Event Handling

    private func handleFlagsChanged(_ event: NSEvent) {
        // Deduplicate: both global and local monitors can fire for the same event.
        // NSEvent.timestamp is the same for both, so skip if we've already seen it.
        guard event.timestamp != lastEventTimestamp else { return }
        lastEventTimestamp = event.timestamp

        let triggerKey = AppSettings.shared.triggerKey
        let targetFlag = triggerKey.modifierFlag

        // Build the set of "other" modifiers — everything except the trigger key.
        // We require the trigger key to be pressed alone to avoid false triggers
        // from key combos like Cmd+C, Shift+Arrow, etc.
        let allModifiers: [NSEvent.ModifierFlags] = [.function, .shift, .control, .option, .command]
        var otherModifiers: NSEvent.ModifierFlags = []
        for mod in allModifiers {
            if mod != targetFlag {
                otherModifiers.insert(mod)
            }
        }

        let hasOtherModifiers = !event.modifierFlags.intersection(otherModifiers).isEmpty
        let triggerPressed = event.modifierFlags.contains(targetFlag) && !hasOtherModifiers

        if triggerPressed && !keyIsDown {
            // Trigger key was just pressed down
            keyIsDown = true
            print("[HotkeyManager] \(triggerKey.shortName) pressed — start recording")
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDown()
            }
        } else if !triggerPressed && keyIsDown {
            // Trigger key was just released
            keyIsDown = false
            print("[HotkeyManager] \(triggerKey.shortName) released — stop recording")
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp()
            }
        }
    }
}

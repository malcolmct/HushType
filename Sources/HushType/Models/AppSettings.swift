import AppKit
import ServiceManagement

/// The modifier key used as the push-to-talk trigger.
/// Stored as a string in UserDefaults for easy serialization.
enum TriggerKey: String, CaseIterable {
    case fn       = "fn"
    case control  = "control"
    case option   = "option"

    /// The NSEvent.ModifierFlags value for this key.
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .fn:      return .function
        case .control: return .control
        case .option:  return .option
        }
    }

    /// Human-readable label for display in menus and UI.
    var displayName: String {
        switch self {
        case .fn:      return "🌐 Fn"
        case .control: return "⌃ Control"
        case .option:  return "⌥ Option"
        }
    }

    /// Short name for use in status text (e.g. "Hold Fn to Dictate").
    var shortName: String {
        switch self {
        case .fn:      return "Fn"
        case .control: return "Control"
        case .option:  return "Option"
        }
    }
}

/// Notification posted when the trigger key setting changes.
extension Notification.Name {
    static let triggerKeyDidChange = Notification.Name("HushTypeTriggerKeyDidChange")
    static let menuBarIconDidChange = Notification.Name("HushTypeMenuBarIconDidChange")
}

/// Menu bar icon style: system (Apple SF Symbol) or custom (HushType branded).
enum MenuBarIconStyle: String, CaseIterable {
    case system = "system"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .system: return "System mic (SF Symbol)"
        case .custom: return "HushType mic"
        }
    }
}

/// Persistent user settings backed by UserDefaults.
class AppSettings {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let modelSize = "modelSize"
        static let useClipboardInjection = "useClipboardInjection"
        static let triggerKey = "triggerKey"
        static let audioInputDeviceID = "audioInputDeviceID"
        static let showOverlay = "showOverlay"
        static let language = "language"
        static let menuBarIconStyle = "menuBarIconStyle"
        static let useRealtimeTranscription = "useRealtimeTranscription"
    }

    // MARK: - Settings

    /// WhisperKit model size: "tiny", "base", "small", "medium", "large-v3", etc.
    var modelSize: String {
        get { defaults.string(forKey: Keys.modelSize) ?? "small.en" }
        set { defaults.set(newValue, forKey: Keys.modelSize) }
    }

    /// Whether to use clipboard paste (Cmd+V) for text injection.
    /// If false, uses CGEvent keystroke simulation instead.
    var useClipboardInjection: Bool {
        get {
            if defaults.object(forKey: Keys.useClipboardInjection) == nil {
                return true // Default to clipboard mode (most reliable)
            }
            return defaults.bool(forKey: Keys.useClipboardInjection)
        }
        set { defaults.set(newValue, forKey: Keys.useClipboardInjection) }
    }

    /// The modifier key used as the push-to-talk dictation trigger.
    /// Default is Fn. Posts `.triggerKeyDidChange` when changed.
    var triggerKey: TriggerKey {
        get {
            if let raw = defaults.string(forKey: Keys.triggerKey),
               let key = TriggerKey(rawValue: raw) {
                return key
            }
            return .fn
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.triggerKey)
            NotificationCenter.default.post(name: .triggerKeyDidChange, object: nil)
        }
    }

    /// Unique ID of the selected audio input device (nil = system default).
    var audioInputDeviceID: String? {
        get { defaults.string(forKey: Keys.audioInputDeviceID) }
        set { defaults.set(newValue, forKey: Keys.audioInputDeviceID) }
    }

    /// Whether to show the floating recording overlay.
    var showOverlay: Bool {
        get {
            if defaults.object(forKey: Keys.showOverlay) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showOverlay)
        }
        set { defaults.set(newValue, forKey: Keys.showOverlay) }
    }

    /// Transcription language (nil = auto-detect).
    var language: String? {
        get { defaults.string(forKey: Keys.language) }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    /// Whether to use real-time transcription (text typed while still recording).
    /// When false (default), transcription happens after the trigger key is released.
    /// Marked experimental — real-time mode can produce timing artefacts in some apps.
    var useRealtimeTranscription: Bool {
        get {
            if defaults.object(forKey: Keys.useRealtimeTranscription) == nil {
                return false // Default off — experimental feature
            }
            return defaults.bool(forKey: Keys.useRealtimeTranscription)
        }
        set { defaults.set(newValue, forKey: Keys.useRealtimeTranscription) }
    }

    /// Menu bar icon style: system SF Symbol or custom HushType icon.
    /// Posts `.menuBarIconDidChange` when changed so the menu bar updates immediately.
    var menuBarIconStyle: MenuBarIconStyle {
        get {
            if let raw = defaults.string(forKey: Keys.menuBarIconStyle),
               let style = MenuBarIconStyle(rawValue: raw) {
                return style
            }
            return .custom
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.menuBarIconStyle)
            NotificationCenter.default.post(name: .menuBarIconDidChange, object: nil)
        }
    }

    // MARK: - Login Item (via ServiceManagement)

    /// Whether HushType is registered to start at login.
    /// Uses SMAppService (macOS 13+) which integrates with System Settings > Login Items.
    /// This is NOT stored in UserDefaults — the source of truth is the system's login item registry.
    var startAtLogin: Bool {
        get {
            return SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                    print("[AppSettings] Registered as login item")
                } else {
                    try SMAppService.mainApp.unregister()
                    print("[AppSettings] Unregistered as login item")
                }
            } catch {
                print("[AppSettings] Failed to \(newValue ? "register" : "unregister") login item: \(error)")
            }
        }
    }
}

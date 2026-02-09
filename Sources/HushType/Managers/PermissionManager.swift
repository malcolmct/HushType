import AppKit
import AVFoundation

/// Manages system permission checks and requests for microphone and accessibility access.
class PermissionManager {

    // MARK: - Version Tracking

    /// Key used to store the last version that had accessibility granted.
    private static let lastAccessibilityVersionKey = "LastAccessibilityGrantedVersion"

    /// The current app version string from the bundle.
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// Whether the app was recently updated (version changed since last accessibility grant).
    private var wasRecentlyUpdated: Bool {
        let lastVersion = UserDefaults.standard.string(forKey: Self.lastAccessibilityVersionKey)
        return lastVersion != nil && lastVersion != currentVersion
    }

    /// Record that accessibility was granted for the current version.
    func recordAccessibilityGranted() {
        UserDefaults.standard.set(currentVersion, forKey: Self.lastAccessibilityVersionKey)
    }

    // MARK: - Microphone Permission

    /// Whether the app currently has microphone access.
    var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Request microphone permission from the user.
    func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    print("[PermissionManager] Microphone permission granted")
                } else {
                    print("[PermissionManager] Microphone permission denied")
                    DispatchQueue.main.async {
                        self.showMicrophonePermissionAlert()
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.showMicrophonePermissionAlert()
            }
        case .authorized:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Accessibility Permission

    /// Whether the app has accessibility access (needed for text injection via CGEvent).
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Check accessibility permission and show an appropriate dialog if not granted.
    /// Detects post-update situations and shows tailored instructions.
    func promptForAccessibility() {
        if AXIsProcessTrusted() {
            recordAccessibilityGranted()
            print("[PermissionManager] Accessibility permission already granted")
            return
        }

        if wasRecentlyUpdated {
            print("[PermissionManager] Accessibility lost after update — showing re-auth dialog")
            showPostUpdateAccessibilityAlert()
        } else {
            print("[PermissionManager] Accessibility not granted — showing first-time dialog")
            showFirstTimeAccessibilityAlert()
        }
    }

    /// Periodically re-check accessibility (call after app is ready).
    /// If permission was lost silently (e.g. after an update), show the dialog.
    func recheckAccessibility() {
        if AXIsProcessTrusted() {
            recordAccessibilityGranted()
        }
    }

    // MARK: - Aggregate Permission Checks

    /// Whether both required permissions are currently granted.
    func allPermissionsGranted() -> Bool {
        return hasMicrophonePermission && hasAccessibilityPermission
    }

    /// Request microphone access silently (triggers system dialog, no custom alert).
    func requestMicrophonePermissionSilent() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("[PermissionManager] Microphone permission \(granted ? "granted" : "denied")")
            }
        case .denied, .restricted:
            openSystemPreferences(to: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .authorized:
            break
        @unknown default:
            break
        }
    }

    /// Open System Settings to the Accessibility pane (no custom alert).
    func openAccessibilitySettingsDirectly() {
        openAccessibilitySettings()
    }

    // MARK: - Alert Dialogs

    private func showFirstTimeAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "HushType needs Accessibility access to type transcribed text into other applications.\n\n1. Click \"Open Settings\" below\n2. Click the \"+\" button\n3. Find and select HushType\n4. Make sure the toggle is enabled\n\nWithout this permission, transcribed text will be copied to the clipboard instead of typed directly."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func showPostUpdateAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Needs Refreshing"
        alert.informativeText = "HushType was updated and macOS needs you to re-authorise Accessibility access. This is a one-time step after updates.\n\n1. Click \"Open Settings\" below\n2. Find HushType in the list\n3. Remove it (select it and click the \"−\" button)\n4. Re-add it (click \"+\" and select HushType)\n\nThis is required by macOS whenever an app's code changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "HushType needs microphone access to transcribe your speech. Please grant access in System Settings > Privacy & Security > Microphone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemPreferences(to: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func openAccessibilitySettings() {
        openSystemPreferences(to: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func openSystemPreferences(to urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

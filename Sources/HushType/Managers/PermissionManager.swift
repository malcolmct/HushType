import AppKit
import AVFoundation

/// Manages system permission checks and requests for microphone and accessibility access.
class PermissionManager {

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

    /// Prompt the user to grant accessibility permission.
    /// This opens the System Preferences dialog with the app pre-selected.
    func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            print("[PermissionManager] Accessibility permission not yet granted — user prompted")
        } else {
            print("[PermissionManager] Accessibility permission already granted")
        }
    }

    // MARK: - Alert Dialogs

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

    private func openSystemPreferences(to urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

import AppKit
import Carbon

/// Main application delegate that manages the menu bar item, recording lifecycle,
/// and coordinates all managers (audio, transcription, text injection, hotkey).
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var audioManager: AudioManager!
    private var transcriptionEngine: TranscriptionEngine!
    private var textInjector: TextInjector!
    private var hotkeyManager: HotkeyManager!
    private var permissionManager: PermissionManager!
    private var recordingOverlay: RecordingOverlayWindow?
    private var modelProgressWindow: ModelProgressWindow?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    private var isRecording = false
    private var isTranscribing = false
    private var recordingStartTime: Date?

    /// Minimum recording duration in seconds — ignore very short key taps
    private let minimumRecordingDuration: TimeInterval = 0.3

    /// Short name of the current trigger key, for use in UI text.
    private var triggerKeyName: String {
        AppSettings.shared.triggerKey.shortName
    }

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize managers
        permissionManager = PermissionManager()
        audioManager = AudioManager()
        transcriptionEngine = TranscriptionEngine()
        textInjector = TextInjector()

        // Set up the menu bar
        setupStatusItem()

        // Set up global hotkey (hold trigger key to record)
        hotkeyManager = HotkeyManager(
            onKeyDown: { [weak self] in
                self?.startRecording()
            },
            onKeyUp: { [weak self] in
                self?.stopRecordingAndTranscribe()
            }
        )
        hotkeyManager.startListening()

        // Check permissions on launch
        checkPermissions()

        // Listen for model changes (from Settings or fallback)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleModelDidChange),
            name: .modelDidChange,
            object: nil
        )

        // Listen for trigger key changes (from Settings)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTriggerKeyDidChange),
            name: .triggerKeyDidChange,
            object: nil
        )

        // Listen for menu bar icon style changes (from Settings)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMenuBarIconDidChange),
            name: .menuBarIconDidChange,
            object: nil
        )

        // Set up progress reporting for model downloads (window shown only when downloading)
        setupModelProgressReporting()

        // Start loading the Whisper model in the background
        updateStartStopMenuItem(title: "Loading model…")
        Task {
            await transcriptionEngine.loadModel()
            await MainActor.run {
                hideModelProgress()
                if transcriptionEngine.isReady {
                    updateStartStopMenuItem(title: "Hold \(triggerKeyName) to Dictate")
                    updateModelInfoMenuItem()
                    print("[HushType] Ready — hold \(triggerKeyName) to dictate, release to transcribe")
                } else {
                    updateStartStopMenuItem(title: "⚠ Model failed to load")
                    print("[HushType] ERROR: No model loaded — transcription will not work")
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.stopListening()
        if isRecording {
            audioManager.stopRecording()
        }
    }

    // MARK: - Menu Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            applyMenuBarIcon(to: button, recording: false)
        }

        let menu = NSMenu()

        let startStopItem = NSMenuItem(title: "Hold \(triggerKeyName) to Dictate", action: #selector(menuToggleRecording), keyEquivalent: "")
        startStopItem.target = self
        startStopItem.tag = 1
        menu.addItem(startStopItem)

        menu.addItem(NSMenuItem.separator())

        let modelInfoItem = NSMenuItem(title: "Model: \(AppSettings.shared.modelSize)", action: nil, keyEquivalent: "")
        modelInfoItem.isEnabled = false
        modelInfoItem.tag = 2
        menu.addItem(modelInfoItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About HushType…", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        if let icon = loadBundledImage(named: "menubar-icon") {
            icon.isTemplate = true
            icon.size = NSSize(width: 16, height: 16)
            aboutItem.image = icon
        }
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit HushType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Recording Control

    func toggleRecording() {
        if isTranscribing {
            // Don't interrupt active transcription
            return
        }

        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording, !isTranscribing else { return }

        // Don't start recording if the model isn't loaded yet
        guard transcriptionEngine.isReady else {
            print("[HushType] Model not ready yet — ignoring key press")
            return
        }

        // Verify permissions
        guard permissionManager.hasMicrophonePermission else {
            permissionManager.requestMicrophonePermission()
            return
        }

        do {
            try audioManager.startRecording()
            isRecording = true
            recordingStartTime = Date()
            updateMenuBarIcon(recording: true)
            showRecordingOverlay()
            updateStartStopMenuItem(title: "Recording… (release \(triggerKeyName) to stop)")
            print("[HushType] Recording started")
        } catch {
            print("[HushType] Failed to start recording: \(error)")
            showError("Failed to start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }

        // Ignore very short recordings (trigger key bounce)
        if let start = recordingStartTime,
           Date().timeIntervalSince(start) < minimumRecordingDuration {
            print("[HushType] Recording too short — ignoring (likely key bounce)")
            audioManager.stopRecording()
            isRecording = false
            recordingStartTime = nil
            updateMenuBarIcon(recording: false)
            updateStartStopMenuItem(title: "Hold \(triggerKeyName) to Dictate")
            hideRecordingOverlay()
            return
        }

        let samples = audioManager.stopRecording()
        isRecording = false
        updateMenuBarIcon(recording: false)

        // If no meaningful audio was captured, just reset silently
        if samples.isEmpty || samples.count < 8000 {
            // Less than 0.5s of audio at 16kHz — nothing worth transcribing
            print("[HushType] No meaningful audio captured — skipping transcription")
            updateStartStopMenuItem(title: "Hold \(triggerKeyName) to Dictate")
            hideRecordingOverlay()
            return
        }

        // Check if audio is effectively silent (very low RMS)
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        if rms < 0.001 {
            print("[HushType] Audio is silent — skipping transcription")
            updateStartStopMenuItem(title: "Hold \(triggerKeyName) to Dictate")
            hideRecordingOverlay()
            return
        }

        isTranscribing = true
        updateStartStopMenuItem(title: "Transcribing…")

        print("[HushType] Recording stopped — \(samples.count) samples captured, transcribing…")

        // Update overlay to show transcribing state
        recordingOverlay?.updateState(.transcribing)

        Task {
            do {
                let startTime = Date()
                let text = try await transcriptionEngine.transcribe(samples)
                let elapsed = Date().timeIntervalSince(startTime)

                print("[HushType] Transcribed in \(String(format: "%.1f", elapsed))s: \"\(text)\"")

                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Check accessibility permission before injecting
                    if permissionManager.hasAccessibilityPermission {
                        textInjector.injectText(text)
                    } else {
                        // Fall back to copying to clipboard
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        print("[HushType] No accessibility permission — text copied to clipboard instead")
                    }
                } else {
                    print("[HushType] No speech detected")
                }

                await MainActor.run {
                    isTranscribing = false
                    updateStartStopMenuItem(title: "Hold \(triggerKeyName) to Dictate")
                    hideRecordingOverlay()
                }
            } catch {
                print("[HushType] Transcription failed: \(error)")
                await MainActor.run {
                    isTranscribing = false
                    updateStartStopMenuItem(title: "Hold \(triggerKeyName) to Dictate")
                    hideRecordingOverlay()
                }
            }
        }
    }

    // MARK: - UI Updates

    private func updateMenuBarIcon(recording: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusItem.button else { return }
            self?.applyMenuBarIcon(to: button, recording: recording)
        }
    }

    /// Set the menu bar button image based on the current icon style preference.
    private func applyMenuBarIcon(to button: NSStatusBarButton, recording: Bool) {
        switch AppSettings.shared.menuBarIconStyle {
        case .system:
            let symbolName = recording ? "mic.fill" : "mic"
            button.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: recording ? "Recording" : "Dictation"
            )
            button.image?.isTemplate = true
        case .custom:
            let imageName = recording ? "menubar-icon-recording" : "menubar-icon"
            if let img = loadBundledImage(named: imageName) {
                img.isTemplate = true
                button.image = img
            } else {
                // Fallback to SF Symbol if custom icon not found
                let symbolName = recording ? "mic.fill" : "mic"
                button.image = NSImage(
                    systemSymbolName: symbolName,
                    accessibilityDescription: recording ? "Recording" : "Dictation"
                )
                button.image?.isTemplate = true
            }
        }

        // Tint the button when recording
        button.contentTintColor = recording ? .systemRed : nil
    }

    /// Load a PNG image from the app bundle's Resources directory.
    /// Handles @2x variants automatically by loading both and setting the
    /// correct size so macOS selects the right representation for the display.
    private func loadBundledImage(named name: String) -> NSImage? {
        let executablePath = ProcessInfo.processInfo.arguments[0]
        let macOSDir = (executablePath as NSString).deletingLastPathComponent
        let contentsDir = (macOSDir as NSString).deletingLastPathComponent
        let resourcesDir = (contentsDir as NSString).appendingPathComponent("Resources")

        let path1x = (resourcesDir as NSString).appendingPathComponent("\(name).png")
        let path2x = (resourcesDir as NSString).appendingPathComponent("\(name)@2x.png")

        // Prefer the @2x image, sized at the 1x point dimensions
        if FileManager.default.fileExists(atPath: path2x),
           let img = NSImage(contentsOfFile: path2x) {
            img.size = NSSize(width: 18, height: 18)
            return img
        }

        if FileManager.default.fileExists(atPath: path1x) {
            return NSImage(contentsOfFile: path1x)
        }

        return nil
    }

    @objc private func handleMenuBarIconDidChange() {
        // Re-apply the icon with the current recording state
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusItem.button else { return }
            let recording = self?.isRecording ?? false
            self?.applyMenuBarIcon(to: button, recording: recording)
        }
    }

    private func updateStartStopMenuItem(title: String) {
        DispatchQueue.main.async { [weak self] in
            if let menu = self?.statusItem.menu,
               let item = menu.items.first(where: { $0.tag == 1 }) {
                item.title = title
            }
        }
    }

    private func updateModelInfoMenuItem() {
        DispatchQueue.main.async { [weak self] in
            if let menu = self?.statusItem.menu,
               let item = menu.items.first(where: { $0.tag == 2 }) {
                item.title = "Model: \(AppSettings.shared.modelSize)"
            }
        }
    }

    private func showRecordingOverlay() {
        DispatchQueue.main.async { [weak self] in
            if self?.recordingOverlay == nil {
                self?.recordingOverlay = RecordingOverlayWindow()
            }
            self?.recordingOverlay?.show()
            self?.audioManager.onAudioLevel = { level in
                self?.recordingOverlay?.updateLevel(level)
            }
        }
    }

    private func hideRecordingOverlay() {
        DispatchQueue.main.async { [weak self] in
            self?.recordingOverlay?.hide()
        }
    }

    // MARK: - Model Progress

    /// Wire up the transcription engine's progress callback to the progress window.
    /// The window is created and shown automatically when download progress is first reported,
    /// so bundled models (which skip downloading) never trigger the dialog.
    private func setupModelProgressReporting() {
        transcriptionEngine.onProgress = { [weak self] fraction, statusText in
            DispatchQueue.main.async {
                // Lazily show the progress window on first callback
                if self?.modelProgressWindow == nil || self?.modelProgressWindow?.isVisible != true {
                    self?.showModelProgress(modelName: AppSettings.shared.modelSize)
                }
                self?.modelProgressWindow?.updateProgress(fraction)
                self?.modelProgressWindow?.updateStatus(statusText)
            }
        }
    }

    /// Show the model download/loading progress window.
    private func showModelProgress(modelName: String) {
        DispatchQueue.main.async { [weak self] in
            if self?.modelProgressWindow == nil {
                self?.modelProgressWindow = ModelProgressWindow()
            }
            self?.modelProgressWindow?.show(modelName: modelName)
        }
    }

    /// Hide the model progress window.
    private func hideModelProgress() {
        DispatchQueue.main.async { [weak self] in
            self?.modelProgressWindow?.hide()
        }
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "HushType Error"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Permissions

    private func checkPermissions() {
        if !permissionManager.hasMicrophonePermission {
            permissionManager.requestMicrophonePermission()
        }

        if !permissionManager.hasAccessibilityPermission {
            permissionManager.promptForAccessibility()
        }
    }

    // MARK: - Menu Actions

    @objc private func menuToggleRecording() {
        toggleRecording()
    }

    @objc private func handleModelDidChange() {
        updateModelInfoMenuItem()
        hideModelProgress()
        print("[HushType] Menu bar updated — model: \(AppSettings.shared.modelSize)")
    }

    @objc private func handleTriggerKeyDidChange() {
        let keyName = AppSettings.shared.triggerKey.shortName
        hotkeyManager.restartListening()
        // Update menu bar text if we're in the idle state
        if !isRecording && !isTranscribing {
            updateStartStopMenuItem(title: "Hold \(keyName) to Dictate")
        }
        // Force recreation of settings window so the dropdown reflects any external change
        settingsWindow = nil
        print("[HushType] Trigger key changed to \(keyName) — hotkey listener restarted")
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelName = sender.representedObject as? String else { return }

        // Update menu checkmarks
        if let modelMenu = sender.menu {
            for item in modelMenu.items {
                item.state = .off
            }
        }
        sender.state = .on

        // Update settings and reload model
        AppSettings.shared.modelSize = modelName
        Task {
            await transcriptionEngine.loadModel(name: modelName)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = SettingsWindowController.createWindow(
                audioManager: audioManager,
                transcriptionEngine: transcriptionEngine,
                appSettings: AppSettings.shared
            )
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAbout() {
        if aboutWindow == nil {
            aboutWindow = AboutWindowController.createWindow()
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

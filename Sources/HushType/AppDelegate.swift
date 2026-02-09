import AppKit
import Carbon
import Sparkle

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
    private var permissionsWindow: NSWindow?
    private var updaterController: SPUStandardUpdaterController?

    private var isRecording = false
    private var isTranscribing = false
    private var recordingStartTime: Date?

    // Real-time transcription state
    private var realtimeTimer: Timer?
    private var lastInjectedText: String = ""
    private var lastFullTranscription: String = ""   // Previous tick's output, for stability checking
    private var isRealtimeTranscribing = false

    /// Minimum recording duration in seconds — ignore very short key taps
    private let minimumRecordingDuration: TimeInterval = 0.3

    /// Interval between real-time transcription passes (seconds)
    private let realtimeTranscriptionInterval: TimeInterval = 2.0

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

        // Set up Sparkle auto-updater (before menu setup so the menu item can reference it)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

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

        // Show permissions window if any required permission is missing
        showPermissionsWindowIfNeeded()

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
                    // Re-check accessibility now that the app is ready
                    permissionManager.recheckAccessibility()
                    print("[HushType] Ready — hold \(triggerKeyName) to dictate, release to transcribe")
                } else {
                    updateStartStopMenuItem(title: "⚠ Model failed to load")
                    print("[HushType] ERROR: No model loaded — transcription will not work")
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRealtimeTimer()
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

        let checkUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdatesItem.target = self
        if let updateIcon = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Check for Updates") {
            updateIcon.isTemplate = true
            checkUpdatesItem.image = updateIcon
        }
        menu.addItem(checkUpdatesItem)

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

            let isRealtime = AppSettings.shared.useRealtimeTranscription
                && permissionManager.hasAccessibilityPermission

            if isRealtime {
                // Start real-time transcription timer
                lastInjectedText = ""
                lastFullTranscription = ""
                isRealtimeTranscribing = false
                recordingOverlay?.updateState(.realtimeRecording)
                recordingOverlay?.updateTranscriptionPreview("")
                updateStartStopMenuItem(title: "Recording (real-time)… (release \(triggerKeyName) to stop)")

                realtimeTimer = Timer.scheduledTimer(withTimeInterval: realtimeTranscriptionInterval, repeats: true) { [weak self] _ in
                    self?.realtimeTranscriptionTick()
                }

                print("[HushType] Recording started (real-time mode)")
            } else {
                updateStartStopMenuItem(title: "Recording… (release \(triggerKeyName) to stop)")
                print("[HushType] Recording started")
            }
        } catch {
            print("[HushType] Failed to start recording: \(error)")
            showError("Failed to start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }

        let wasRealtime = realtimeTimer != nil
        stopRealtimeTimer()

        // Ignore very short recordings (trigger key bounce)
        if let start = recordingStartTime,
           Date().timeIntervalSince(start) < minimumRecordingDuration {
            print("[HushType] Recording too short — ignoring (likely key bounce)")
            audioManager.stopRecording()
            isRecording = false
            recordingStartTime = nil
            lastInjectedText = ""
            lastFullTranscription = ""
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
            if wasRealtime { lastInjectedText = ""; lastFullTranscription = "" }
            updateStartStopMenuItem(title: "Hold \(triggerKeyName) to Dictate")
            hideRecordingOverlay()
            return
        }

        // Check if audio is effectively silent (very low RMS)
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        if rms < 0.001 {
            print("[HushType] Audio is silent — skipping transcription")
            if wasRealtime { lastInjectedText = ""; lastFullTranscription = "" }
            updateStartStopMenuItem(title: "Hold \(triggerKeyName) to Dictate")
            hideRecordingOverlay()
            return
        }

        isTranscribing = true
        updateStartStopMenuItem(title: "Transcribing…")

        print("[HushType] Recording stopped — \(samples.count) samples captured, transcribing…")

        // Update overlay to show transcribing state
        recordingOverlay?.updateState(.transcribing)

        // Capture the text injected so far (for real-time final correction)
        let previouslyInjected = wasRealtime ? lastInjectedText : ""

        Task {
            do {
                let startTime = Date()
                let text = try await transcriptionEngine.transcribe(samples)
                let elapsed = Date().timeIntervalSince(startTime)
                let trimmed = ensureDoubleSpaces(
                    text.trimmingCharacters(in: .whitespacesAndNewlines))

                print("[HushType] Transcribed in \(String(format: "%.1f", elapsed))s: \"\(trimmed)\"")

                if !trimmed.isEmpty {
                    // Add trailing spaces so cursor is positioned for the next sentence
                    let finalText = withTrailingSpaces(trimmed)

                    if permissionManager.hasAccessibilityPermission {
                        if wasRealtime {
                            // Final correction: apply any remaining text not committed during real-time
                            if trimmed != previouslyInjected {
                                if previouslyInjected.isEmpty {
                                    // Nothing was committed during real-time — inject the full text
                                    // using normal injection (clipboard paste) for reliable formatting
                                    textInjector.injectText(finalText)
                                    print("[HushType] Final real-time: full text injected via paste")
                                } else {
                                    // Check if committed text still matches the start of the final transcription
                                    let matchEnd = committedPrefixMatch(
                                        committed: previouslyInjected, current: trimmed)
                                    if matchEnd > 0 {
                                        // Committed text matches — append the remainder via paste
                                        let remaining = String(finalText.dropFirst(matchEnd))
                                        if !remaining.isEmpty {
                                            textInjector.injectText(remaining)
                                        }
                                        print("[HushType] Final real-time: appended remainder via paste")
                                    } else {
                                        // Committed text diverged — need incremental correction
                                        textInjector.injectIncremental(
                                            replacing: previouslyInjected, with: finalText)
                                        print("[HushType] Final real-time: incremental correction applied")
                                    }
                                }
                            }
                        } else {
                            textInjector.injectText(finalText)
                        }
                    } else {
                        // Fall back to copying to clipboard
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(trimmed, forType: .string)
                        print("[HushType] No accessibility permission — text copied to clipboard instead")
                    }
                } else {
                    print("[HushType] No speech detected")
                }

                await MainActor.run {
                    isTranscribing = false
                    lastInjectedText = ""
                    lastFullTranscription = ""
                    updateStartStopMenuItem(title: "Hold \(triggerKeyName) to Dictate")
                    hideRecordingOverlay()
                }
            } catch {
                print("[HushType] Transcription failed: \(error)")
                await MainActor.run {
                    isTranscribing = false
                    lastInjectedText = ""
                    lastFullTranscription = ""
                    updateStartStopMenuItem(title: "Hold \(triggerKeyName) to Dictate")
                    hideRecordingOverlay()
                }
            }
        }
    }

    // MARK: - Real-time Transcription

    /// Called by the repeating timer during real-time mode. Snapshots the current audio,
    /// transcribes it, and appends any newly completed sentences.
    ///
    /// Committed-prefix append-only strategy:
    /// 1. Each tick, check if the current transcription still begins with what we've
    ///    already committed (word-level match, ignoring case/punctuation changes).
    /// 2. If so, look for new complete sentences (ending with . ! ?) beyond the committed
    ///    portion and append them immediately — no need to wait for a second tick.
    /// 3. Never backspace or revise — only append. The overlay shows the full in-progress text.
    /// 4. When recording stops, a final correction pass handles remaining text and any revisions.
    private func realtimeTranscriptionTick() {
        // Skip if a previous tick is still transcribing
        guard !isRealtimeTranscribing else {
            print("[HushType] Real-time tick skipped — previous transcription still running")
            return
        }

        let samples = audioManager.getCurrentSamples()

        // Wait for at least 1 second of audio (16000 samples at 16kHz)
        guard samples.count >= 16000 else { return }

        isRealtimeTranscribing = true

        Task {
            do {
                let text = try await transcriptionEngine.transcribe(samples)
                let trimmed = ensureDoubleSpaces(
                    text.trimmingCharacters(in: .whitespacesAndNewlines))

                await MainActor.run {
                    // Always update the overlay preview with the full transcription
                    recordingOverlay?.updateTranscriptionPreview(trimmed)

                    if !trimmed.isEmpty {
                        if lastInjectedText.isEmpty {
                            // First commit: find complete sentences in the transcription
                            let boundary = lastSentenceBoundary(in: trimmed)
                            if boundary > 0 {
                                let toCommit = String(trimmed.prefix(boundary))
                                textInjector.injectText(toCommit)
                                lastInjectedText = toCommit
                                print("[HushType] Real-time first commit: \"\(toCommit)\"")
                            }
                        } else {
                            // Subsequent commits: check if our committed text is still
                            // at the start of the current transcription, then commit
                            // any new complete sentences immediately.
                            let matchEnd = committedPrefixMatch(
                                committed: lastInjectedText, current: trimmed)
                            if matchEnd > 0 {
                                let remaining = String(trimmed.dropFirst(matchEnd))
                                if !remaining.isEmpty {
                                    let boundary = lastSentenceBoundary(in: remaining)
                                    if boundary > 0 {
                                        let toCommit = String(remaining.prefix(boundary))
                                        textInjector.injectText(toCommit)
                                        lastInjectedText += toCommit
                                        print("[HushType] Real-time appended: \"\(toCommit)\"")
                                    }
                                }
                            }
                            // If match fails, Whisper revised earlier text.
                            // We can't fix it during real-time — the final correction handles it.
                        }
                    }

                    lastFullTranscription = trimmed
                    isRealtimeTranscribing = false
                }
            } catch {
                print("[HushType] Real-time transcription tick failed: \(error)")
                await MainActor.run {
                    isRealtimeTranscribing = false
                }
            }
        }
    }

    /// Check if `current` starts with the same words as `committed`, ignoring case and
    /// punctuation differences.  Returns the character offset in `current` right after the
    /// last matched word (NOT including trailing spaces, so the remaining text preserves
    /// inter-sentence spacing like double spaces after periods).
    /// Returns 0 if the committed text doesn't match the start of the current transcription.
    private func committedPrefixMatch(committed: String, current: String) -> Int {
        let comWords = committed.split(separator: " ", omittingEmptySubsequences: true)
        let curWords = current.split(separator: " ", omittingEmptySubsequences: true)

        guard !comWords.isEmpty, curWords.count >= comWords.count else { return 0 }

        // Every word in committed must match the corresponding word in current
        for i in 0..<comWords.count {
            let a = comWords[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            let b = curWords[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            if a != b { return 0 }
        }

        // Find the character offset right after the last committed word in current
        var charOffset = 0
        var wordsFound = 0
        let chars = Array(current)
        var idx = 0
        while idx < chars.count && wordsFound < comWords.count {
            // Skip spaces
            while idx < chars.count && chars[idx] == " " { idx += 1 }
            // Walk through the word
            let wordStart = idx
            while idx < chars.count && chars[idx] != " " { idx += 1 }
            if idx > wordStart {
                wordsFound += 1
                charOffset = idx
            }
        }

        // Do NOT include trailing spaces — they belong to the next commit,
        // preserving double-space formatting between sentences.
        return charOffset
    }

    /// Find the character count up to the end of the last complete sentence in the text.
    /// A complete sentence ends with . ! or ? followed by whitespace or end-of-string.
    /// Returns 0 if no sentence boundary is found.
    private func lastSentenceBoundary(in text: String) -> Int {
        let chars = Array(text)
        var boundary = 0

        for i in 0..<chars.count {
            if ".!?".contains(chars[i]) {
                if i == chars.count - 1 {
                    // Punctuation at end of text — sentence is complete
                    boundary = chars.count
                } else if chars[i + 1] == " " {
                    // Punctuation followed by space — skip trailing spaces
                    var end = i + 1
                    while end < chars.count && chars[end] == " " {
                        end += 1
                    }
                    boundary = end
                }
            }
        }

        return boundary
    }

    /// Ensure exactly two spaces after every sentence-ending punctuation mark (. ! ?)
    /// that is followed by more text. Uses a simple character walk — no regex.
    private func ensureDoubleSpaces(_ text: String) -> String {
        var result = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            result.append(chars[i])
            if ".!?".contains(chars[i]) && i + 1 < chars.count && chars[i + 1] == " " {
                // Punctuation followed by space(s) — skip all existing spaces
                var j = i + 1
                while j < chars.count && chars[j] == " " { j += 1 }
                if j < chars.count {
                    // More text follows — insert exactly two spaces
                    result.append("  ")
                    i = j
                    continue
                }
            }
            i += 1
        }
        return result
    }

    /// Append two trailing spaces if the text ends with sentence-ending punctuation.
    /// This positions the cursor ready for the next sentence after dictation finishes.
    private func withTrailingSpaces(_ text: String) -> String {
        guard let last = text.last, ".!?".contains(last) else { return text }
        return text + "  "
    }

    /// Stop the real-time transcription timer and clean up state.
    private func stopRealtimeTimer() {
        realtimeTimer?.invalidate()
        realtimeTimer = nil
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

    /// Show the unified permissions window if any permission is missing.
    /// Replaces the old sequential-alert approach with a Snagit-style table UI
    /// that polls for status changes and updates live.
    private func showPermissionsWindowIfNeeded() {
        guard !permissionManager.allPermissionsGranted() else {
            print("[HushType] All permissions granted — skipping permissions window")
            return
        }

        print("[HushType] Missing permissions detected — showing permissions window")
        let window = PermissionsWindowController.createWindow(permissionManager: permissionManager)
        permissionsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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

    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(self)
    }
}

import AppKit

/// A floating, non-activating window that shows recording/transcription state
/// and real-time audio levels. Appears near the top of the screen and doesn't
/// steal focus from the active application.
class RecordingOverlayWindow {

    enum State {
        case recording
        case transcribing
        case realtimeRecording   // Real-time mode: recording + showing partial transcription
    }

    // MARK: - Properties

    private var window: NSPanel?
    private var levelIndicator: NSView?
    private var statusLabel: NSTextField?
    private var transcriptionLabel: NSTextField?
    private var levelBar: NSView?
    private var currentState: State = .recording

    private let windowWidth: CGFloat = 200
    private let expandedWidth: CGFloat = 400
    private let windowHeight: CGFloat = 44
    private let expandedHeight: CGFloat = 72

    // MARK: - Show / Hide

    func show() {
        if window == nil {
            createWindow()
        }
        currentState = .recording
        statusLabel?.stringValue = "🎤 Recording…"
        levelBar?.frame.size.width = 0
        window?.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    // MARK: - Updates

    func updateLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let levelBar = self.levelBar else { return }
            let maxWidth: CGFloat = self.windowWidth - 32
            levelBar.frame.size.width = CGFloat(level) * maxWidth
        }
    }

    func updateState(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentState = state
            switch state {
            case .recording:
                self.statusLabel?.stringValue = "🎤 Recording…"
                self.resizeWindow(expanded: false)
                self.transcriptionLabel?.isHidden = true
            case .transcribing:
                self.statusLabel?.stringValue = "⏳ Transcribing…"
                self.levelBar?.frame.size.width = 0
                self.transcriptionLabel?.isHidden = true
            case .realtimeRecording:
                self.statusLabel?.stringValue = "🎤 Recording (real-time)…"
                self.resizeWindow(expanded: true)
                self.transcriptionLabel?.isHidden = false
            }
        }
    }

    /// Update the transcription preview text shown in the overlay during real-time mode.
    func updateTranscriptionPreview(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.transcriptionLabel == nil {
                self.addTranscriptionLabel()
            }
            self.transcriptionLabel?.stringValue = text.isEmpty ? "Listening…" : text
            self.transcriptionLabel?.isHidden = false
        }
    }

    /// Resize the overlay window (expanding for real-time preview or shrinking back).
    private func resizeWindow(expanded: Bool) {
        guard let window = self.window, let screen = NSScreen.main else { return }
        let newWidth = expanded ? expandedWidth : windowWidth
        let newHeight = expanded ? expandedHeight : windowHeight
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - newWidth / 2
        let y = screenFrame.maxY - newHeight - 10
        window.setFrame(NSRect(x: x, y: y, width: newWidth, height: newHeight), display: true, animate: true)

        // Update content view and sublabel positions
        window.contentView?.frame.size = NSSize(width: newWidth, height: newHeight)
        statusLabel?.frame = NSRect(x: 16, y: newHeight - 22, width: newWidth - 32, height: 18)
        levelBar?.frame.origin.y = expanded ? newHeight - 36 : 8
        if let levelBg = window.contentView?.subviews.first(where: {
            $0 !== statusLabel && $0 !== levelBar && $0 !== transcriptionLabel && $0.frame.size.height == 6
        }) {
            levelBg.frame = NSRect(x: 16, y: levelBar?.frame.origin.y ?? 8, width: newWidth - 32, height: 6)
        }
    }

    // MARK: - Window Creation

    private func createWindow() {
        // Position at the top center of the main screen
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let x = screenFrame.midX - windowWidth / 2
        let y = screenFrame.maxY - windowHeight - 10

        let frame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Content view
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 10

        // Status label
        let label = NSTextField(frame: NSRect(x: 16, y: 20, width: windowWidth - 32, height: 18))
        label.stringValue = "🎤 Recording…"
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        contentView.addSubview(label)
        statusLabel = label

        // Level bar background
        let levelBg = NSView(frame: NSRect(x: 16, y: 8, width: windowWidth - 32, height: 6))
        levelBg.wantsLayer = true
        levelBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        levelBg.layer?.cornerRadius = 3
        contentView.addSubview(levelBg)

        // Level bar fill
        let bar = NSView(frame: NSRect(x: 16, y: 8, width: 0, height: 6))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.systemGreen.cgColor
        bar.layer?.cornerRadius = 3
        contentView.addSubview(bar)
        levelBar = bar

        panel.contentView = contentView
        window = panel

        // Pre-create the transcription label (hidden by default)
        addTranscriptionLabel()
    }

    /// Add a second label below the status line for showing partial transcription text.
    private func addTranscriptionLabel() {
        guard let contentView = window?.contentView else { return }
        let width = contentView.frame.width
        let label = NSTextField(frame: NSRect(x: 16, y: 8, width: width - 32, height: 18))
        label.stringValue = "Listening…"
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.textColor = NSColor.white.withAlphaComponent(0.7)
        label.font = NSFont.systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = true
        contentView.addSubview(label)
        transcriptionLabel = label
    }
}

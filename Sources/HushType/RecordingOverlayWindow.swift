import AppKit

/// A floating, non-activating window that shows recording/transcription state
/// and real-time audio levels. Appears near the top of the screen and doesn't
/// steal focus from the active application.
class RecordingOverlayWindow {

    enum State {
        case recording
        case transcribing
    }

    // MARK: - Properties

    private var window: NSPanel?
    private var levelIndicator: NSView?
    private var statusLabel: NSTextField?
    private var levelBar: NSView?
    private var currentState: State = .recording

    private let windowWidth: CGFloat = 200
    private let windowHeight: CGFloat = 44

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
            self?.currentState = state
            switch state {
            case .recording:
                self?.statusLabel?.stringValue = "🎤 Recording…"
            case .transcribing:
                self?.statusLabel?.stringValue = "⏳ Transcribing…"
                self?.levelBar?.frame.size.width = 0
            }
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
    }
}

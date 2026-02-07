import AppKit

/// A floating window that shows model download/loading progress.
/// Appears centered on screen and doesn't steal focus from the active application.
class ModelProgressWindow {

    // MARK: - Properties

    private var window: NSPanel?
    private var titleLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var percentLabel: NSTextField?
    private var statusLabel: NSTextField?

    private let windowWidth: CGFloat = 360
    private let windowHeight: CGFloat = 120

    /// Whether the progress window is currently visible on screen.
    var isVisible: Bool {
        return window?.isVisible ?? false
    }

    // MARK: - Show / Hide

    /// Show the progress window with the given model name.
    func show(modelName: String) {
        if window == nil {
            createWindow()
        }
        titleLabel?.stringValue = "Downloading model: \(modelName)"
        progressBar?.doubleValue = 0
        percentLabel?.stringValue = "0%"
        statusLabel?.stringValue = "Connecting…"
        window?.center()
        window?.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    // MARK: - Updates

    /// Update the progress bar and percentage label.
    /// - Parameter fraction: Progress from 0.0 to 1.0
    func updateProgress(_ fraction: Double) {
        DispatchQueue.main.async { [weak self] in
            let percent = Int(fraction * 100)
            self?.progressBar?.doubleValue = fraction * 100
            self?.percentLabel?.stringValue = "\(percent)%"
            if fraction < 1.0 {
                self?.statusLabel?.stringValue = "Downloading…"
            } else {
                self?.statusLabel?.stringValue = "Loading model…"
            }
        }
    }

    /// Update the status text (e.g. "Loading model…", "Prewarming…")
    func updateStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel?.stringValue = text
        }
    }

    // MARK: - Window Creation

    private func createWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let x = screenFrame.midX - windowWidth / 2
        let y = screenFrame.midY - windowHeight / 2

        let frame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.title = "HushType"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))

        // Title label (e.g. "Downloading model: small.en")
        let title = NSTextField(frame: NSRect(x: 20, y: 78, width: windowWidth - 40, height: 20))
        title.stringValue = "Downloading model…"
        title.isEditable = false
        title.isBordered = false
        title.backgroundColor = .clear
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        contentView.addSubview(title)
        titleLabel = title

        // Progress bar
        let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 50, width: windowWidth - 80, height: 20))
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = 0
        progress.isIndeterminate = false
        contentView.addSubview(progress)
        progressBar = progress

        // Percentage label
        let percent = NSTextField(frame: NSRect(x: windowWidth - 55, y: 50, width: 40, height: 20))
        percent.stringValue = "0%"
        percent.isEditable = false
        percent.isBordered = false
        percent.backgroundColor = .clear
        percent.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        contentView.addSubview(percent)
        percentLabel = percent

        // Status label (e.g. "Downloading…", "Loading model…")
        let status = NSTextField(frame: NSRect(x: 20, y: 22, width: windowWidth - 40, height: 16))
        status.stringValue = "Connecting…"
        status.isEditable = false
        status.isBordered = false
        status.backgroundColor = .clear
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        contentView.addSubview(status)
        statusLabel = status

        panel.contentView = contentView
        window = panel
    }
}

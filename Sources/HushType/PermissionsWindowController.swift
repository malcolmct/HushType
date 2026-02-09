import AppKit
import AVFoundation

/// A Snagit-style permissions window that shows the status of all required
/// permissions in a single table-like UI.  Shown on launch when any permission
/// is missing; polls every second so rows update live as the user grants access.
class PermissionsWindowController: NSObject, NSWindowDelegate {

    // MARK: - Row model

    private struct PermissionRow {
        let iconName: String          // SF Symbol name
        let title: String
        let description: String
        let enableAction: Selector
    }

    // MARK: - Properties

    private weak var window: NSWindow?
    private var permissionManager: PermissionManager!
    private var pollTimer: Timer?

    // Row UI references (icon, title, desc are static; status area updates)
    private var statusViews: [(button: NSButton, checkImage: NSImageView, checkLabel: NSTextField)] = []
    private var counterLabel: NSTextField!
    private var staleHintLabel: NSTextField?

    // Track how many poll cycles Accessibility has been not-granted after the user clicked Enable
    private var accessibilityEnableClickCount = 0
    private var accessibilityPollsSinceClick = 0
    private static let staleHintThreshold = 5  // Show hint after 5 seconds of polling post-click

    // The permission rows to display (built dynamically based on relevance)
    private var rows: [PermissionRow] = []

    /// Build the list of permission rows.
    private func buildRows() {
        rows = [
            PermissionRow(
                iconName: "mic.fill",
                title: "Microphone",
                description: "Record audio from your microphone for speech-to-text transcription.",
                enableAction: #selector(enableMicrophone)
            ),
            PermissionRow(
                iconName: "hand.raised.fill",
                title: "Accessibility",
                description: "Type transcribed text directly into other applications.",
                enableAction: #selector(enableAccessibility)
            ),
        ]
    }

    // Singleton to prevent deallocation while the window is open
    private static var retainedInstance: PermissionsWindowController?

    // MARK: - Factory

    /// Create and return the permissions window.  The controller retains itself
    /// while the window is open (released on close via the delegate).
    static func createWindow(permissionManager: PermissionManager) -> NSWindow {
        let controller = PermissionsWindowController()
        controller.permissionManager = permissionManager
        controller.buildRows()
        retainedInstance = controller

        let window = controller.buildWindow()
        controller.window = window
        window.delegate = controller

        controller.refreshStatus()
        controller.startPolling()

        return window
    }

    // MARK: - Window construction

    private func buildWindow() -> NSWindow {
        let windowWidth: CGFloat = 520
        let rowCount = CGFloat(rows.count)
        let windowHeight: CGFloat = 200 + rowCount * 72 + (rowCount - 1)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "System Permissions"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        content.wantsLayer = true
        window.contentView = content

        let margin: CGFloat = 24
        let rowHeight: CGFloat = 72
        let rowSpacing: CGFloat = 1        // 1px separator between rows
        let availWidth = windowWidth - margin * 2

        var y = windowHeight - margin

        // --- Title ---
        let titleLabel = NSTextField(labelWithString: "HushType needs additional permissions")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: margin, y: y - 22, width: availWidth, height: 22)
        content.addSubview(titleLabel)
        y -= 32

        // --- Subtitle ---
        let subtitle = NSTextField(labelWithString: "HushType needs system level permissions to transcribe and type text. To change permissions at a later time, open System Settings.")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 3
        subtitle.preferredMaxLayoutWidth = availWidth
        subtitle.frame = NSRect(x: margin, y: y - 42, width: availWidth, height: 42)
        content.addSubview(subtitle)
        y -= 56

        // --- Permission rows ---
        let tableTop = y
        let borderColor = NSColor.separatorColor.withAlphaComponent(0.5)

        // Outer border (rounded rect)
        let totalRowsHeight = CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * rowSpacing
        let tableFrame = NSRect(x: margin, y: tableTop - totalRowsHeight, width: availWidth, height: totalRowsHeight)
        let tableBox = NSBox(frame: tableFrame)
        tableBox.boxType = .custom
        tableBox.borderType = .lineBorder
        tableBox.borderColor = borderColor
        tableBox.borderWidth = 1
        tableBox.cornerRadius = 8
        tableBox.fillColor = .clear
        tableBox.contentViewMargins = .zero
        content.addSubview(tableBox)

        for (index, row) in rows.enumerated() {
            let rowY = tableTop - CGFloat(index + 1) * rowHeight - CGFloat(index) * rowSpacing
            let rowFrame = NSRect(x: margin, y: rowY, width: availWidth, height: rowHeight)

            // Alternating background
            if index % 2 == 1 {
                let bg = NSView(frame: rowFrame)
                bg.wantsLayer = true
                bg.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.1).cgColor
                content.addSubview(bg)
            }

            // Separator between rows (except last)
            if index < rows.count - 1 {
                let sep = NSBox(frame: NSRect(x: margin + 12, y: rowY, width: availWidth - 24, height: 1))
                sep.boxType = .separator
                content.addSubview(sep)
            }

            // Icon
            let iconSize: CGFloat = 32
            let iconX = margin + 16
            let iconY = rowY + (rowHeight - iconSize) / 2
            let iconView = NSImageView(frame: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
            if let img = NSImage(systemSymbolName: row.iconName, accessibilityDescription: row.title) {
                let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
                iconView.image = img.withSymbolConfiguration(config)
            }
            iconView.contentTintColor = .secondaryLabelColor
            content.addSubview(iconView)

            // Title
            let textX = iconX + iconSize + 16
            let statusWidth: CGFloat = 110
            let textWidth = availWidth - (textX - margin) - statusWidth - 16
            let titleField = NSTextField(labelWithString: row.title)
            titleField.font = NSFont.systemFont(ofSize: 13, weight: .bold)
            titleField.textColor = .labelColor
            titleField.frame = NSRect(x: textX, y: rowY + rowHeight - 28, width: textWidth, height: 18)
            content.addSubview(titleField)

            // Description
            let descField = NSTextField(labelWithString: row.description)
            descField.font = NSFont.systemFont(ofSize: 11)
            descField.textColor = .secondaryLabelColor
            descField.lineBreakMode = .byWordWrapping
            descField.maximumNumberOfLines = 2
            descField.frame = NSRect(x: textX, y: rowY + 8, width: textWidth, height: 32)
            content.addSubview(descField)

            // Status area (right side)
            let statusX = margin + availWidth - statusWidth - 8

            // Enable button
            let enableBtn = NSButton(title: "Enable", target: self, action: row.enableAction)
            enableBtn.bezelStyle = .rounded
            enableBtn.controlSize = .regular
            enableBtn.frame = NSRect(x: statusX, y: rowY + (rowHeight - 28) / 2, width: 90, height: 28)
            enableBtn.keyEquivalent = ""
            // Make the button blue
            enableBtn.contentTintColor = .white
            enableBtn.bezelColor = .controlAccentColor
            content.addSubview(enableBtn)

            // Checkmark + "Enabled!" (hidden initially)
            let checkImage = NSImageView(frame: NSRect(x: statusX + 8, y: rowY + (rowHeight - 20) / 2 + 1, width: 22, height: 22))
            if let checkSym = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Enabled") {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                checkImage.image = checkSym.withSymbolConfiguration(config)
            }
            checkImage.contentTintColor = .systemGreen
            checkImage.isHidden = true
            content.addSubview(checkImage)

            let checkLabel = NSTextField(labelWithString: "Enabled!")
            checkLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            checkLabel.textColor = .systemGreen
            checkLabel.frame = NSRect(x: statusX + 34, y: rowY + (rowHeight - 18) / 2, width: 70, height: 18)
            checkLabel.isHidden = true
            content.addSubview(checkLabel)

            statusViews.append((button: enableBtn, checkImage: checkImage, checkLabel: checkLabel))
        }

        y = tableTop - totalRowsHeight - 20

        // --- Counter ---
        counterLabel = NSTextField(labelWithString: "0 of \(rows.count) Enabled")
        counterLabel.font = NSFont.systemFont(ofSize: 12)
        counterLabel.textColor = .secondaryLabelColor
        counterLabel.alignment = .center
        counterLabel.frame = NSRect(x: margin, y: y - 18, width: availWidth / 2 - 50, height: 18)
        content.addSubview(counterLabel)

        // --- Done button ---
        let doneBtn = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        doneBtn.bezelStyle = .rounded
        doneBtn.controlSize = .regular
        doneBtn.keyEquivalent = "\r"
        doneBtn.frame = NSRect(x: margin + availWidth - 80, y: y - 22, width: 80, height: 28)
        content.addSubview(doneBtn)

        // --- Stale permission hint (hidden until needed, positioned when shown) ---
        let hintText = "⚠ If Accessibility isn't being recognised, a previous version of HushType may already be in the Accessibility list. Open System Settings → Privacy & Security → Accessibility, select the old HushType entry and remove it using the \"−\" button at the lower left of the list, then click Enable above to re-add it."
        let hint = NSTextField(wrappingLabelWithString: hintText)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .systemOrange
        hint.alignment = .left
        hint.maximumNumberOfLines = 0
        hint.preferredMaxLayoutWidth = availWidth
        hint.frame = NSRect(x: margin, y: 0, width: availWidth, height: 54)
        hint.isHidden = true
        content.addSubview(hint)
        staleHintLabel = hint

        return window
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshStatus() {
        let statuses: [Bool] = [
            permissionManager.hasMicrophonePermission,
            permissionManager.hasAccessibilityPermission,
        ]

        let total = statuses.count
        var enabledCount = 0
        for (index, granted) in statuses.enumerated() {
            guard index < statusViews.count else { break }
            let views = statusViews[index]
            if granted {
                views.button.isHidden = true
                views.checkImage.isHidden = false
                views.checkLabel.isHidden = false
                enabledCount += 1
            } else {
                views.button.isHidden = false
                views.checkImage.isHidden = true
                views.checkLabel.isHidden = true
            }
        }

        counterLabel?.stringValue = "\(enabledCount) of \(total) Enabled"

        // If accessibility was just granted, record it and hide the hint
        if permissionManager.hasAccessibilityPermission {
            permissionManager.recordAccessibilityGranted()
            staleHintLabel?.isHidden = true
            accessibilityPollsSinceClick = 0
        } else if accessibilityEnableClickCount > 0 {
            // User has clicked Enable but Accessibility still isn't granted.
            // After a few seconds, show a hint about stale permission entries.
            accessibilityPollsSinceClick += 1
            if accessibilityPollsSinceClick >= Self.staleHintThreshold
                && staleHintLabel?.isHidden == true {
                // Grow the window to make room for the hint, then show it.
                // In macOS's bottom-up coordinate system, growing the window
                // downward shifts all existing content down on screen. To keep
                // everything visually in place, move all existing subviews UP
                // by the growth amount, then position the hint in the new space.
                if let w = window, let contentView = w.contentView {
                    let extraHeight: CGFloat = 70
                    var frame = w.frame
                    frame.size.height += extraHeight
                    frame.origin.y -= extraHeight  // grow downward on screen
                    w.setFrame(frame, display: true, animate: true)

                    // Shift all existing subviews up so they stay visually in place
                    for subview in contentView.subviews {
                        if subview !== staleHintLabel {
                            var f = subview.frame
                            f.origin.y += extraHeight
                            subview.frame = f
                        }
                    }

                    // Position the hint in the newly available space at the bottom
                    let margin: CGFloat = 24
                    let hintWidth = contentView.frame.width - margin * 2
                    staleHintLabel?.frame = NSRect(
                        x: margin, y: 8, width: hintWidth, height: 54)
                    staleHintLabel?.isHidden = false
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func enableMicrophone() {
        permissionManager.requestMicrophonePermissionSilent()
    }

    @objc private func enableAccessibility() {
        accessibilityEnableClickCount += 1
        accessibilityPollsSinceClick = 0
        permissionManager.openAccessibilitySettingsDirectly()
    }

    @objc private func doneClicked() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        Self.retainedInstance = nil
    }
}

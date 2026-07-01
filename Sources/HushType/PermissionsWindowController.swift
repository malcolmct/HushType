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
        let buttonTitle: String       // "Enable" for required, "Setup…" for optional
    }

    // MARK: - Properties

    private weak var window: NSWindow?
    private var permissionManager: PermissionManager!
    private var pollTimer: Timer?

    // Row UI references (icon, title, desc are static; status area updates)
    private var statusViews: [(button: NSButton, checkImage: NSImageView, checkLabel: NSTextField)] = []
    private var counterLabel: NSTextField!

    // Guidance area views (all hidden initially, positioned when shown)
    private var staleHintLabel: NSTextField?
    private var restartButton: NSButton?
    private var appMgmtGuidanceLabel: NSTextField?

    // Track how many poll cycles Accessibility has been not-granted after the user clicked Enable
    private var accessibilityEnableClickCount = 0
    private var accessibilityPollsSinceClick = 0
    private static let staleHintThreshold = 5  // Show hint after 5 seconds of polling post-click

    // Guidance area expansion tracking — generalised so multiple guidance
    // items (accessibility stale hint, App Management guidance) can coexist.
    private var staleHintVisible = false
    private var appMgmtGuidanceVisible = false
    private var currentWindowGrowth: CGFloat = 0
    private static let staleHintHeight: CGFloat = 120    // hint text + restart button + spacing
    private static let appMgmtGuidanceHeight: CGFloat = 110 // guidance text + spacing

    // The permission rows to display (built dynamically based on relevance)
    private var rows: [PermissionRow] = []

    /// Build the list of permission rows.
    private func buildRows() {
        rows = [
            PermissionRow(
                iconName: "mic.fill",
                title: "Microphone",
                description: "Record audio from your microphone for speech-to-text transcription.",
                enableAction: #selector(enableMicrophone),
                buttonTitle: "Enable"
            ),
            PermissionRow(
                iconName: "hand.raised.fill",
                title: "Accessibility",
                description: "Type transcribed text directly into other applications.",
                enableAction: #selector(enableAccessibility),
                buttonTitle: "Enable"
            ),
            PermissionRow(
                iconName: "arrow.triangle.2.circlepath",
                title: "App Management",
                description: "Allow automatic updates. Recommended but not required.",
                enableAction: #selector(enableAppManagement),
                buttonTitle: "Setup…"
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
        window.level = .floating               // Stay above normal windows
        window.hidesOnDeactivate = false        // Stay visible when user switches to System Settings
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

            // Enable / Setup button
            let enableBtn = NSButton(title: row.buttonTitle, target: self, action: row.enableAction)
            enableBtn.bezelStyle = .rounded
            enableBtn.controlSize = .regular
            enableBtn.frame = NSRect(x: statusX, y: rowY + (rowHeight - 28) / 2, width: 90, height: 28)
            enableBtn.keyEquivalent = ""
            // Blue accent for required permissions; default styling for optional
            if row.buttonTitle == "Enable" {
                enableBtn.contentTintColor = .white
                enableBtn.bezelColor = .controlAccentColor
            }
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

        // --- Counter (only counts required permissions: Microphone + Accessibility) ---
        counterLabel = NSTextField(labelWithString: "0 of 2 Required")
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
        let hintText = "⚠ If a previous version of HushType is already in the Accessibility list, it must be removed first. Open System Settings → Privacy & Security → Accessibility, select the old HushType entry and click \"−\" to remove it. Then click Restart below — a restart is needed for macOS to recognise the new permission."
        let hint = NSTextField(wrappingLabelWithString: hintText)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .systemOrange
        hint.alignment = .left
        hint.maximumNumberOfLines = 0
        hint.preferredMaxLayoutWidth = availWidth
        hint.frame = NSRect(x: margin, y: 0, width: availWidth, height: 70)
        hint.isHidden = true
        content.addSubview(hint)
        staleHintLabel = hint

        // --- Restart button (hidden until hint is shown) ---
        let restBtn = NSButton(title: "Restart HushType", target: self, action: #selector(restartApp))
        restBtn.bezelStyle = .rounded
        restBtn.controlSize = .regular
        restBtn.frame = NSRect(x: margin, y: 0, width: 150, height: 30)
        restBtn.contentTintColor = .white
        restBtn.bezelColor = .systemOrange
        restBtn.isHidden = true
        content.addSubview(restBtn)
        restartButton = restBtn

        // --- App Management guidance (hidden until user clicks Setup…) ---
        let guidanceText = "In the System Settings window, select Privacy & Security in the sidebar, then scroll down to find \"App Management\". Click it and enable the toggle next to HushType. If HushType isn't listed, it will appear the next time an update is available. Alternatively, you may click the plus button below the list, then select the HushType app from the Applications folder which will add it."
        let guidance = NSTextField(wrappingLabelWithString: guidanceText)
        guidance.font = NSFont.systemFont(ofSize: 11)
        guidance.textColor = .secondaryLabelColor
        guidance.alignment = .left
        guidance.maximumNumberOfLines = 0
        guidance.preferredMaxLayoutWidth = availWidth
        guidance.frame = NSRect(x: margin, y: 0, width: availWidth, height: 60)
        guidance.isHidden = true
        content.addSubview(guidance)
        appMgmtGuidanceLabel = guidance

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
        // Only the first two rows (Microphone, Accessibility) are auto-detectable.
        // The third row (App Management) has no public API to check — its Setup
        // button always stays visible so the user can access the guidance.
        let requiredStatuses: [Bool] = [
            permissionManager.hasMicrophonePermission,
            permissionManager.hasAccessibilityPermission,
        ]

        var enabledCount = 0
        for (index, granted) in requiredStatuses.enumerated() {
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

        counterLabel?.stringValue = "\(enabledCount) of \(requiredStatuses.count) Required"

        // Notify the app when all required permissions are granted
        if enabledCount == requiredStatuses.count {
            NotificationCenter.default.post(name: .allRequiredPermissionsGranted, object: nil)
        }

        // If accessibility was just granted, record it and hide the stale hint.
        if permissionManager.hasAccessibilityPermission {
            permissionManager.recordAccessibilityGranted()
            accessibilityPollsSinceClick = 0
            if staleHintVisible {
                staleHintVisible = false
                updateGuidanceArea()
            }
        } else if accessibilityEnableClickCount > 0 {
            // User has clicked Enable but Accessibility still isn't granted.
            // After a few seconds, show a hint about stale permission entries.
            accessibilityPollsSinceClick += 1
            if accessibilityPollsSinceClick >= Self.staleHintThreshold
                && !staleHintVisible {
                staleHintVisible = true
                updateGuidanceArea()
            }
        }
    }

    // MARK: - Guidance area management

    /// Calculate the total window growth needed for all visible guidance content.
    private var neededWindowGrowth: CGFloat {
        var h: CGFloat = 0
        if staleHintVisible { h += Self.staleHintHeight }
        if appMgmtGuidanceVisible { h += Self.appMgmtGuidanceHeight }
        return h
    }

    /// Adjust the window size for guidance content and reposition all views.
    ///
    /// The guidance area lives at the very bottom of the window.  When it needs
    /// to grow or shrink, the window frame changes and all non-guidance subviews
    /// are shifted to keep them visually stable on screen.
    private func updateGuidanceArea() {
        let needed = neededWindowGrowth
        let delta = needed - currentWindowGrowth

        if delta != 0, let w = window, let contentView = w.contentView {
            currentWindowGrowth = needed

            // Resize window (positive delta = grow downward, negative = shrink upward)
            var frame = w.frame
            frame.size.height += delta
            frame.origin.y -= delta
            w.setFrame(frame, display: true, animate: true)

            // Shift all non-guidance subviews so they stay visually in place
            let guidanceSubviews: [NSView?] = [staleHintLabel, restartButton, appMgmtGuidanceLabel]
            for subview in contentView.subviews {
                if !guidanceSubviews.contains(where: { $0 === subview }) {
                    var f = subview.frame
                    f.origin.y += delta
                    subview.frame = f
                }
            }
        }

        layoutGuidanceContent()
    }

    /// Position all visible guidance views in the expanded area at the bottom.
    /// Items are stacked from bottom to top: App Management guidance first
    /// (at the very bottom), then the accessibility stale hint above it.
    private func layoutGuidanceContent() {
        guard let contentView = window?.contentView else { return }
        let margin: CGFloat = 24
        let guidanceWidth = contentView.frame.width - margin * 2
        var y: CGFloat = 12  // start from bottom of window

        // App Management guidance (at the very bottom if visible)
        if appMgmtGuidanceVisible {
            appMgmtGuidanceLabel?.frame = NSRect(x: margin, y: y, width: guidanceWidth, height: 60)
            appMgmtGuidanceLabel?.isHidden = false
            y += 68
        } else {
            appMgmtGuidanceLabel?.isHidden = true
        }

        // Accessibility stale hint + restart button (above App Management if both visible)
        if staleHintVisible {
            restartButton?.frame = NSRect(x: margin, y: y, width: 150, height: 30)
            restartButton?.isHidden = false
            y += 38
            staleHintLabel?.frame = NSRect(x: margin, y: y, width: guidanceWidth, height: 70)
            staleHintLabel?.isHidden = false
        } else {
            staleHintLabel?.isHidden = true
            restartButton?.isHidden = true
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

    @objc private func enableAppManagement() {
        permissionManager.openPrivacySecuritySettings()
        if !appMgmtGuidanceVisible {
            appMgmtGuidanceVisible = true
            updateGuidanceArea()
        }
    }

    @objc private func restartApp() {
        // AXIsProcessTrusted() is cached per-PID at launch — macOS will not
        // recognise a newly-added Accessibility entry for an already-running
        // process.  We must quit and relaunch so the new PID picks it up.
        let bundlePath = Bundle.main.bundlePath
        // Launch a shell process that waits for us to terminate, then reopens the app
        Process.launchedProcess(
            launchPath: "/bin/sh",
            arguments: ["-c", "sleep 1 && open \"\(bundlePath)\""]
        )
        NSApp.terminate(nil)
    }

    @objc private func doneClicked() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        Self.retainedInstance = nil

        // If the user closes the window before granting all required permissions,
        // the app can't function — quit cleanly rather than sitting silently in
        // the menu bar with no icon and no way to interact.
        if !permissionManager.allPermissionsGranted() {
            NSApp.terminate(nil)
        }
    }
}

import AppKit
import ServiceManagement

// MARK: - Brand Colours

/// Centralised colour constants for HushType's branded UI.
private enum HushTypeColors {
    /// Warm teal accent — provides subtle brand personality for section headers.
    static let accent = NSColor(srgbRed: 0.18, green: 0.58, blue: 0.58, alpha: 1.0)

    /// Section container fill — adapts to light (white) and dark (dark gray) mode.
    static let sectionBackground = NSColor.controlBackgroundColor

    /// Subtle border for section container edges.
    static let sectionBorder = NSColor.separatorColor.withAlphaComponent(0.4)

    /// Window background — very slight teal tint so section cards stand out.
    /// Adapts to light/dark mode automatically.
    static let windowBackground = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.11, green: 0.13, blue: 0.14, alpha: 1.0)
        } else {
            return NSColor(srgbRed: 0.90, green: 0.93, blue: 0.93, alpha: 1.0)
        }
    }
}

/// Creates and manages the Settings window for configuring the dictation app.
class SettingsWindowController {

    /// Create the settings window.
    static func createWindow(
        audioManager: AudioManager,
        transcriptionEngine: TranscriptionEngine,
        appSettings: AppSettings
    ) -> NSWindow {
        let windowWidth: CGFloat = 460
        let windowHeight: CGFloat = 960

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HushType Settings"
        window.backgroundColor = HushTypeColors.windowBackground
        window.center()
        window.isReleasedWhenClosed = false

        // Lock horizontal size, allow vertical resizing for short screens
        window.minSize = NSSize(width: windowWidth, height: 400)
        window.maxSize = NSSize(width: windowWidth, height: 2000)

        // Add an empty toolbar so macOS centers the title in the title bar
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        // Use a scroll view so the form remains fully accessible on short screens
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false

        // The document view holds all controls — its height is the full form height
        let contentHeight: CGFloat = 960
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: contentHeight))
        contentView.autoresizingMask = [.width]

        let labelX: CGFloat = 52
        let controlX: CGFloat = 186
        let controlWidth: CGFloat = 224
        let labelWidth: CGFloat = 126
        var y: CGFloat = contentHeight - 12

        // MARK: - General Section
        y = addSectionHeader("General", to: contentView, y: y)
        let generalTop = y

        let loginCheck = NSButton(checkboxWithTitle: "Start HushType at login", target: nil, action: nil)
        loginCheck.frame = NSRect(x: controlX, y: y - 26, width: controlWidth, height: 20)
        loginCheck.state = appSettings.startAtLogin ? .on : .off
        loginCheck.target = SettingsActions.shared
        loginCheck.action = #selector(SettingsActions.startAtLoginToggled(_:))

        let loginLabel = makeLabel("Startup:", frame: NSRect(x: labelX, y: y - 26, width: labelWidth, height: 20))
        contentView.addSubview(loginLabel)
        contentView.addSubview(loginCheck)

        let loginHint = makeHintLabel(
            "Automatically launch HushType when you log in.",
            frame: NSRect(x: controlX, y: y - 50, width: controlWidth, height: 20)
        )
        contentView.addSubview(loginHint)
        y -= 64

        addSectionBackground(to: contentView, top: generalTop + 2, bottom: y + 4, width: windowWidth)
        y -= 16

        // MARK: - Activation Section
        y = addSectionHeader("Activation", to: contentView, y: y)
        let activationTop = y

        let hotkeyLabel = makeLabel("Trigger key:", frame: NSRect(x: labelX, y: y - 26, width: labelWidth, height: 20))

        let hotkeyPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y - 28, width: controlWidth, height: 26))
        for key in TriggerKey.allCases {
            hotkeyPopup.addItem(withTitle: key.displayName)
            hotkeyPopup.lastItem?.representedObject = key.rawValue
        }
        // Select the current trigger key
        let currentKey = appSettings.triggerKey
        for (index, key) in TriggerKey.allCases.enumerated() {
            if key == currentKey {
                hotkeyPopup.selectItem(at: index)
                break
            }
        }
        hotkeyPopup.target = SettingsActions.shared
        hotkeyPopup.action = #selector(SettingsActions.triggerKeyChanged(_:))
        contentView.addSubview(hotkeyLabel)
        contentView.addSubview(hotkeyPopup)

        let hotkeyHint = makeHintLabel(
            "Hold to record, release to transcribe. Text is typed at the cursor.",
            frame: NSRect(x: controlX, y: y - 62, width: controlWidth, height: 28)
        )
        contentView.addSubview(hotkeyHint)
        y -= 78

        addSectionBackground(to: contentView, top: activationTop + 2, bottom: y + 4, width: windowWidth)
        y -= 16

        // MARK: - Model Section
        y = addSectionHeader("Whisper Model", to: contentView, y: y)
        let modelTop = y
        SettingsActions.shared.transcriptionEngine = transcriptionEngine

        // Current model display
        let modelLabel = makeLabel("Current:", frame: NSRect(x: labelX, y: y - 26, width: labelWidth, height: 20))
        let modelValue = NSTextField(frame: NSRect(x: controlX, y: y - 26, width: controlWidth, height: 20))
        modelValue.stringValue = appSettings.modelSize
        modelValue.isEditable = false
        modelValue.isBordered = false
        modelValue.backgroundColor = .clear
        modelValue.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        modelValue.textColor = .labelColor
        modelValue.tag = 100
        contentView.addSubview(modelLabel)
        contentView.addSubview(modelValue)

        let modelHint = makeHintLabel(
            "Fast and accurate for English. Use a larger model for other languages or accents.",
            frame: NSRect(x: controlX, y: y - 56, width: controlWidth, height: 28)
        )
        contentView.addSubview(modelHint)

        // Advanced: show model picker
        let advancedCheck = NSButton(checkboxWithTitle: "Show all models (advanced)", target: nil, action: nil)
        advancedCheck.frame = NSRect(x: controlX, y: y - 80, width: controlWidth, height: 20)
        advancedCheck.state = .off
        advancedCheck.target = SettingsActions.shared
        advancedCheck.action = #selector(SettingsActions.advancedModelToggled(_:))
        contentView.addSubview(advancedCheck)

        // Hidden model popup — revealed by the advanced checkbox
        let modelPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y - 108, width: controlWidth, height: 26))
        for model in TranscriptionEngine.availableModels {
            modelPopup.addItem(withTitle: model)
        }
        modelPopup.selectItem(withTitle: appSettings.modelSize)
        modelPopup.target = SettingsActions.shared
        modelPopup.action = #selector(SettingsActions.modelChanged(_:))
        modelPopup.tag = 101
        modelPopup.isHidden = true
        contentView.addSubview(modelPopup)

        let advancedHint = makeHintLabel(
            "Smaller models are faster. Larger models are more accurate.",
            frame: NSRect(x: controlX, y: y - 140, width: controlWidth, height: 28)
        )
        advancedHint.tag = 102
        advancedHint.isHidden = true
        contentView.addSubview(advancedHint)

        // Store reference to model value label so it can be updated
        SettingsActions.shared.modelValueLabel = modelValue

        y -= 96

        let modelBg = addSectionBackground(to: contentView, top: modelTop + 2, bottom: y + 4, width: windowWidth)
        SettingsActions.shared.modelSectionBackground = modelBg
        y -= 16

        // MARK: - Language Section
        y = addSectionHeader("Language", to: contentView, y: y)
        let languageTop = y

        let langLabel = makeLabel("Language:", frame: NSRect(x: labelX, y: y - 26, width: labelWidth, height: 20))

        let langPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y - 28, width: controlWidth, height: 26))
        for lang in TranscriptionEngine.supportedLanguages {
            langPopup.addItem(withTitle: lang.name)
            langPopup.lastItem?.representedObject = lang.code as Any
        }
        // Select the current language
        let currentLang = appSettings.language
        for (index, lang) in TranscriptionEngine.supportedLanguages.enumerated() {
            if lang.code == currentLang {
                langPopup.selectItem(at: index)
                break
            }
        }
        langPopup.target = SettingsActions.shared
        langPopup.action = #selector(SettingsActions.languageChanged(_:))
        contentView.addSubview(langLabel)
        contentView.addSubview(langPopup)

        let langHint = makeHintLabel(
            "Auto-detect works for most languages. Set explicitly for better accuracy.",
            frame: NSRect(x: controlX, y: y - 62, width: controlWidth, height: 28)
        )
        contentView.addSubview(langHint)
        y -= 78

        addSectionBackground(to: contentView, top: languageTop + 2, bottom: y + 4, width: windowWidth)
        y -= 16

        // MARK: - Text Injection Section
        y = addSectionHeader("Text Injection", to: contentView, y: y)
        let injectionTop = y

        let pasteRadio = NSButton(radioButtonWithTitle: "Clipboard paste (⌘V)", target: nil, action: nil)
        pasteRadio.frame = NSRect(x: controlX, y: y - 26, width: controlWidth, height: 20)
        pasteRadio.state = appSettings.useClipboardInjection ? .on : .off

        let keystrokeRadio = NSButton(radioButtonWithTitle: "Simulated keystrokes", target: nil, action: nil)
        keystrokeRadio.frame = NSRect(x: controlX, y: y - 48, width: controlWidth, height: 20)
        keystrokeRadio.state = appSettings.useClipboardInjection ? .off : .on

        pasteRadio.target = SettingsActions.shared
        pasteRadio.action = #selector(SettingsActions.injectionModeChanged(_:))
        pasteRadio.tag = 1
        keystrokeRadio.target = SettingsActions.shared
        keystrokeRadio.action = #selector(SettingsActions.injectionModeChanged(_:))
        keystrokeRadio.tag = 2

        let injectionLabel = makeLabel("Method:", frame: NSRect(x: labelX, y: y - 26, width: labelWidth, height: 20))
        contentView.addSubview(injectionLabel)
        contentView.addSubview(pasteRadio)
        contentView.addSubview(keystrokeRadio)

        let injectionHint = makeHintLabel(
            "Paste handles all characters. Keystrokes feel more natural but may miss symbols.",
            frame: NSRect(x: controlX, y: y - 76, width: controlWidth, height: 28)
        )
        contentView.addSubview(injectionHint)
        y -= 92

        addSectionBackground(to: contentView, top: injectionTop + 2, bottom: y + 4, width: windowWidth)
        y -= 16

        // MARK: - Audio Input Section
        y = addSectionHeader("Audio Input", to: contentView, y: y)
        let audioTop = y

        let inputPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y - 28, width: controlWidth, height: 26))
        inputPopup.addItem(withTitle: "System Default")
        for device in audioManager.availableInputDevices {
            inputPopup.addItem(withTitle: device.name)
        }

        let inputLabel = makeLabel("Input device:", frame: NSRect(x: labelX, y: y - 26, width: labelWidth, height: 20))
        contentView.addSubview(inputLabel)
        contentView.addSubview(inputPopup)
        y -= 44

        addSectionBackground(to: contentView, top: audioTop + 2, bottom: y + 4, width: windowWidth)
        y -= 16

        // MARK: - Display Section
        y = addSectionHeader("Display", to: contentView, y: y)
        let displayTop = y

        let overlayCheck = NSButton(checkboxWithTitle: "Show recording overlay", target: nil, action: nil)
        overlayCheck.frame = NSRect(x: controlX, y: y - 26, width: controlWidth, height: 20)
        overlayCheck.state = appSettings.showOverlay ? .on : .off
        overlayCheck.target = SettingsActions.shared
        overlayCheck.action = #selector(SettingsActions.overlayToggled(_:))

        let overlayLabel = makeLabel("Overlay:", frame: NSRect(x: labelX, y: y - 26, width: labelWidth, height: 20))
        contentView.addSubview(overlayLabel)
        contentView.addSubview(overlayCheck)

        let overlayHint = makeHintLabel(
            "Shows a floating indicator with audio levels while recording.",
            frame: NSRect(x: controlX, y: y - 52, width: controlWidth, height: 28)
        )
        contentView.addSubview(overlayHint)
        y -= 72

        // Menu bar icon style
        let iconLabel = makeLabel("Menu bar icon:", frame: NSRect(x: labelX, y: y - 26, width: labelWidth, height: 20))

        let iconPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y - 28, width: controlWidth, height: 26))
        for style in MenuBarIconStyle.allCases {
            iconPopup.addItem(withTitle: style.displayName)
            iconPopup.lastItem?.representedObject = style.rawValue
        }
        // Select current style
        let currentStyle = appSettings.menuBarIconStyle
        for (index, style) in MenuBarIconStyle.allCases.enumerated() {
            if style == currentStyle {
                iconPopup.selectItem(at: index)
                break
            }
        }
        iconPopup.target = SettingsActions.shared
        iconPopup.action = #selector(SettingsActions.menuBarIconStyleChanged(_:))
        contentView.addSubview(iconLabel)
        contentView.addSubview(iconPopup)

        let iconHint = makeHintLabel(
            "Use the HushType icon to distinguish it from Apple's system mic.",
            frame: NSRect(x: controlX, y: y - 62, width: controlWidth, height: 28)
        )
        contentView.addSubview(iconHint)
        y -= 78

        addSectionBackground(to: contentView, top: displayTop + 2, bottom: y + 4, width: windowWidth)

        scrollView.documentView = contentView
        window.contentView = scrollView

        // Cap window height to available screen space so the scroll bar activates on short screens
        if let screen = NSScreen.main {
            let usable = screen.visibleFrame.height
            if windowHeight > usable {
                window.setContentSize(NSSize(width: windowWidth, height: usable - 20))
            }
        }
        window.center()

        // Always show the top of the form when the window opens
        contentView.scroll(NSPoint(x: 0, y: contentHeight))

        return window
    }

    // MARK: - UI Helpers

    /// Add a teal-coloured section header label (no separator line — the section
    /// background provides visual grouping instead).
    @discardableResult
    private static func addSectionHeader(_ title: String, to view: NSView, y: CGFloat) -> CGFloat {
        let label = NSTextField(frame: NSRect(x: 52, y: y - 18, width: 388, height: 18))
        label.stringValue = title
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = HushTypeColors.accent
        view.addSubview(label)

        return y - 26
    }

    /// Add a rounded-rect background behind a section's controls.
    /// Inserted at the back of the z-order so controls appear on top.
    @discardableResult
    private static func addSectionBackground(to view: NSView, top: CGFloat, bottom: CGFloat, width: CGFloat) -> NSBox {
        let inset: CGFloat = 38
        let bg = NSBox(frame: NSRect(x: inset, y: bottom, width: width - inset * 2, height: top - bottom))
        bg.boxType = .custom
        bg.fillColor = HushTypeColors.sectionBackground
        bg.cornerRadius = 10
        bg.borderColor = HushTypeColors.sectionBorder
        bg.borderWidth = 0.5
        bg.titlePosition = .noTitle
        bg.contentViewMargins = .zero

        // Insert behind all existing subviews so controls draw on top
        if let first = view.subviews.first {
            view.addSubview(bg, positioned: .below, relativeTo: first)
        } else {
            view.addSubview(bg)
        }
        return bg
    }

    private static func makeLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(frame: frame)
        label.stringValue = text
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.alignment = .right
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func makeHintLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(frame: frame)
        label.stringValue = text
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        return label
    }
}

// MARK: - Settings Actions

/// Helper class to handle UI actions from the settings window.
/// (NSMenuItem/NSButton targets must be NSObject subclasses.)
class SettingsActions: NSObject {
    static let shared = SettingsActions()
    var transcriptionEngine: TranscriptionEngine?
    weak var modelValueLabel: NSTextField?
    weak var modelSectionBackground: NSBox?
    var modelProgressWindow: ModelProgressWindow?
    private var modelExpanded = false
    private static let modelExpansionDelta: CGFloat = 72

    @objc func modelChanged(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title else { return }
        AppSettings.shared.modelSize = title
        modelValueLabel?.stringValue = title
        print("[Settings] Model changed to: \(title)")

        // Show progress window for the download
        if modelProgressWindow == nil {
            modelProgressWindow = ModelProgressWindow()
        }
        modelProgressWindow?.show(modelName: title)

        Task {
            await transcriptionEngine?.loadModel(name: title)
            // After loading, update the label and hide progress
            await MainActor.run {
                let actualModel = AppSettings.shared.modelSize
                modelValueLabel?.stringValue = actualModel
                modelProgressWindow?.hide()
            }
        }
    }

    @objc func advancedModelToggled(_ sender: NSButton) {
        let show = sender.state == .on
        guard let scrollView = sender.window?.contentView as? NSScrollView,
              let documentView = scrollView.documentView else { return }

        // Toggle model popup and hint visibility
        documentView.viewWithTag(101)?.isHidden = !show
        documentView.viewWithTag(102)?.isHidden = !show

        // Only resize if the expansion state actually changed
        guard show != modelExpanded else { return }
        modelExpanded = show

        let delta = Self.modelExpansionDelta
        let shift: CGFloat = show ? delta : -delta

        guard let modelBg = modelSectionBackground else { return }

        // Strategy: shift the model section + everything above it UP when expanding
        // (and back down when collapsing). Below-model views stay in place.
        // This avoids adding empty space at the top of the scroll view.
        //
        // The threshold is the model bg's bottom edge (origin.y). Views at or
        // above this Y are part of the model section or above it and should shift.
        // The bg origin never changes (only its height), so the threshold is stable.
        let threshold = modelBg.frame.origin.y

        // Shift model section + above-model views (everything at or above the bg bottom)
        for subview in documentView.subviews {
            if subview === modelBg { continue }  // Handle bg separately
            if subview.frame.origin.y >= threshold {
                var f = subview.frame
                f.origin.y += shift   // +delta up when expanding, -delta down when collapsing
                subview.frame = f
            }
        }

        // The popup (tag 101) and hint (tag 102) are below the threshold in the
        // collapsed layout (they overlap with below-model content). Shift them too
        // so they stay correctly positioned relative to the checkbox.
        // When collapsing, they'll be above the threshold (shifted up earlier),
        // so the main loop already handled them — the condition guards against
        // double-shifting.
        for tag in [101, 102] {
            if let view = documentView.viewWithTag(tag), view.frame.origin.y < threshold {
                var f = view.frame
                f.origin.y += shift
                view.frame = f
            }
        }

        // Grow/shrink the model bg upward so its top follows the shifted content.
        // The origin (bottom edge) stays fixed — only the height changes.
        var bgFrame = modelBg.frame
        bgFrame.size.height += shift
        modelBg.frame = bgFrame

        // Resize the document view so the scroll view knows the new content height
        var docFrame = documentView.frame
        docFrame.size.height += shift
        documentView.frame = docFrame

        // Resize the window to keep all content visible (capped to screen height)
        if let window = sender.window {
            var wf = window.frame
            wf.size.height += shift
            wf.origin.y -= shift   // Keep the top edge anchored
            if let screen = window.screen ?? NSScreen.main {
                let maxHeight = screen.visibleFrame.height
                if wf.size.height > maxHeight {
                    wf.size.height = maxHeight
                    wf.origin.y = screen.visibleFrame.origin.y
                }
            }
            window.setFrame(wf, display: true, animate: true)
        }
    }

    @objc func triggerKeyChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let key = TriggerKey(rawValue: rawValue) else { return }
        AppSettings.shared.triggerKey = key
        print("[Settings] Trigger key changed to: \(key.shortName)")
    }

    @objc func injectionModeChanged(_ sender: NSButton) {
        AppSettings.shared.useClipboardInjection = (sender.tag == 1)
        print("[Settings] Injection mode: \(sender.tag == 1 ? "paste" : "keystrokes")")
    }

    @objc func overlayToggled(_ sender: NSButton) {
        AppSettings.shared.showOverlay = (sender.state == .on)
        print("[Settings] Overlay: \(sender.state == .on ? "on" : "off")")
    }

    @objc func menuBarIconStyleChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let style = MenuBarIconStyle(rawValue: rawValue) else { return }
        AppSettings.shared.menuBarIconStyle = style
        print("[Settings] Menu bar icon: \(style.displayName)")
    }

    @objc func languageChanged(_ sender: NSPopUpButton) {
        // representedObject is the language code (String) or NSNull for auto-detect (nil)
        let selectedObj = sender.selectedItem?.representedObject
        let code: String?
        if let str = selectedObj as? String {
            code = str
        } else {
            code = nil
        }
        AppSettings.shared.language = code
        print("[Settings] Language changed to: \(code ?? "auto-detect")")

        // If a non-English language is selected and the current model is English-only (.en),
        // automatically switch to the multilingual equivalent
        if let langCode = code, langCode != "en" {
            let currentModel = AppSettings.shared.modelSize
            if currentModel.hasSuffix(".en") {
                let multilingualModel = String(currentModel.dropLast(3))  // "small.en" → "small"
                AppSettings.shared.modelSize = multilingualModel
                modelValueLabel?.stringValue = multilingualModel
                print("[Settings] Auto-switched model from \(currentModel) to \(multilingualModel) for \(langCode)")

                // Reload the model
                Task {
                    await transcriptionEngine?.loadModel(name: multilingualModel)
                    await MainActor.run {
                        let actualModel = AppSettings.shared.modelSize
                        modelValueLabel?.stringValue = actualModel
                    }
                }
            }
        }
    }

    @objc func startAtLoginToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppSettings.shared.startAtLogin = enabled
        // Re-read the actual state in case registration failed
        let actualState = AppSettings.shared.startAtLogin
        sender.state = actualState ? .on : .off
        print("[Settings] Start at login: \(actualState ? "on" : "off")")
    }
}

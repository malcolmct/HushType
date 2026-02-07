import AppKit
import ServiceManagement

/// Creates and manages the Settings window for configuring the dictation app.
class SettingsWindowController {

    /// Create the settings window.
    static func createWindow(
        audioManager: AudioManager,
        transcriptionEngine: TranscriptionEngine,
        appSettings: AppSettings
    ) -> NSWindow {
        let windowWidth: CGFloat = 460
        let windowHeight: CGFloat = 900

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HushType Settings"
        window.center()
        window.isReleasedWhenClosed = false

        // Lock horizontal size, allow vertical resizing for short screens
        window.minSize = NSSize(width: windowWidth, height: 400)
        window.maxSize = NSSize(width: windowWidth, height: windowHeight)

        // Add an empty toolbar so macOS centers the title in the title bar
        // (without a toolbar, modern macOS left-aligns the title next to the traffic lights)
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
        let contentHeight: CGFloat = 900
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: contentHeight))
        contentView.autoresizingMask = [.width]

        let labelX: CGFloat = 20
        let controlX: CGFloat = 160
        let controlWidth: CGFloat = 270
        let labelWidth: CGFloat = 130
        var y: CGFloat = contentHeight - 20

        // MARK: - General Section
        y = addSectionHeader("General", to: contentView, y: y)

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
            frame: NSRect(x: controlX, y: y - 56, width: controlWidth, height: 20)
        )
        contentView.addSubview(loginHint)
        y -= 72

        // MARK: - Activation Section
        y = addSectionHeader("Activation", to: contentView, y: y)

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
        y -= 82

        // MARK: - Model Section
        y = addSectionHeader("Whisper Model", to: contentView, y: y)
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

        y -= 100

        // MARK: - Language Section
        y = addSectionHeader("Language", to: contentView, y: y)

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
        y -= 82

        // MARK: - Text Injection Section
        y = addSectionHeader("Text Injection", to: contentView, y: y)

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
            frame: NSRect(x: controlX, y: y - 80, width: controlWidth, height: 28)
        )
        contentView.addSubview(injectionHint)
        y -= 100

        // MARK: - Audio Input Section
        y = addSectionHeader("Audio Input", to: contentView, y: y)

        let inputPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y - 28, width: controlWidth, height: 26))
        inputPopup.addItem(withTitle: "System Default")
        for device in audioManager.availableInputDevices {
            inputPopup.addItem(withTitle: device.name)
        }

        let inputLabel = makeLabel("Input device:", frame: NSRect(x: labelX, y: y - 26, width: labelWidth, height: 20))
        contentView.addSubview(inputLabel)
        contentView.addSubview(inputPopup)
        y -= 50

        // MARK: - Display Section
        y = addSectionHeader("Display", to: contentView, y: y)

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
            frame: NSRect(x: controlX, y: y - 56, width: controlWidth, height: 28)
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

    @discardableResult
    private static func addSectionHeader(_ title: String, to view: NSView, y: CGFloat) -> CGFloat {
        let label = NSTextField(frame: NSRect(x: 20, y: y - 20, width: 420, height: 18))
        label.stringValue = title
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        label.textColor = .labelColor
        view.addSubview(label)

        let separator = NSBox(frame: NSRect(x: 20, y: y - 24, width: 420, height: 1))
        separator.boxType = .separator
        view.addSubview(separator)

        return y - 30
    }

    private static func makeLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(frame: frame)
        label.stringValue = text
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.alignment = .right
        label.font = NSFont.systemFont(ofSize: 13)
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
    var modelProgressWindow: ModelProgressWindow?

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
        // Find the model popup (tag 101) and hint (tag 102) in the same window
        if let contentView = sender.window?.contentView {
            if let popup = contentView.viewWithTag(101) {
                popup.isHidden = !show
            }
            if let hint = contentView.viewWithTag(102) {
                hint.isHidden = !show
            }
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

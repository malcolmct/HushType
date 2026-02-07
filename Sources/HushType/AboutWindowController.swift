import AppKit

/// Creates the About window displaying app information, copyright, and open-source attribution.
class AboutWindowController {

    /// Create the About window.
    static func createWindow() -> NSWindow {
        let windowWidth: CGFloat = 360
        let windowHeight: CGFloat = 400

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About HushType"
        window.center()
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        contentView.autoresizingMask = [.width, .height]

        var y: CGFloat = windowHeight - 20

        // MARK: - App Icon
        let iconSize: CGFloat = 96
        let iconX = (windowWidth - iconSize) / 2

        let iconView = NSImageView(frame: NSRect(x: iconX, y: y - iconSize, width: iconSize, height: iconSize))
        iconView.imageScaling = .scaleProportionallyUpOrDown

        // Load the app icon from the bundle
        if let iconImage = loadAppIcon() {
            iconView.image = iconImage
        } else {
            // Fallback to a system symbol
            iconView.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "HushType")
            iconView.contentTintColor = .controlAccentColor
        }
        contentView.addSubview(iconView)
        y -= iconSize + 12

        // MARK: - App Name
        let nameLabel = NSTextField(frame: NSRect(x: 20, y: y - 24, width: windowWidth - 40, height: 24))
        nameLabel.stringValue = "HushType"
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.backgroundColor = .clear
        nameLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .center
        contentView.addSubview(nameLabel)
        y -= 28

        // MARK: - Version
        let versionLabel = NSTextField(frame: NSRect(x: 20, y: y - 18, width: windowWidth - 40, height: 18))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        versionLabel.stringValue = "Version \(version) (\(build))"
        versionLabel.isEditable = false
        versionLabel.isBordered = false
        versionLabel.backgroundColor = .clear
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        contentView.addSubview(versionLabel)
        y -= 24

        // MARK: - Description
        let descLabel = NSTextField(frame: NSRect(x: 30, y: y - 18, width: windowWidth - 60, height: 18))
        descLabel.stringValue = "On-device speech-to-text dictation for macOS"
        descLabel.isEditable = false
        descLabel.isBordered = false
        descLabel.backgroundColor = .clear
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.alignment = .center
        contentView.addSubview(descLabel)
        y -= 28

        // MARK: - Copyright
        let copyrightLabel = NSTextField(frame: NSRect(x: 20, y: y - 18, width: windowWidth - 40, height: 18))
        copyrightLabel.stringValue = "\u{00A9} 2026 Malcolm Taylor. All rights reserved."
        copyrightLabel.isEditable = false
        copyrightLabel.isBordered = false
        copyrightLabel.backgroundColor = .clear
        copyrightLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        copyrightLabel.textColor = .labelColor
        copyrightLabel.alignment = .center
        contentView.addSubview(copyrightLabel)
        y -= 30

        // MARK: - Separator
        let separator = NSBox(frame: NSRect(x: 30, y: y, width: windowWidth - 60, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)
        y -= 16

        // MARK: - Open Source Acknowledgements
        let ackHeader = NSTextField(frame: NSRect(x: 20, y: y - 16, width: windowWidth - 40, height: 16))
        ackHeader.stringValue = "Open Source Acknowledgements"
        ackHeader.isEditable = false
        ackHeader.isBordered = false
        ackHeader.backgroundColor = .clear
        ackHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        ackHeader.textColor = .labelColor
        ackHeader.alignment = .center
        contentView.addSubview(ackHeader)
        y -= 22

        // Scrollable text view for license details
        let scrollHeight: CGFloat = 110
        let scrollView = NSScrollView(frame: NSRect(x: 30, y: y - scrollHeight, width: windowWidth - 60, height: scrollHeight))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: scrollView.contentSize.height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        textView.textColor = .secondaryLabelColor
        textView.string = Self.acknowledgements

        scrollView.documentView = textView
        contentView.addSubview(scrollView)
        y -= scrollHeight + 12

        // MARK: - Website / link hint
        let linkLabel = NSTextField(frame: NSRect(x: 20, y: y - 14, width: windowWidth - 40, height: 14))
        linkLabel.stringValue = "Built with WhisperKit by Argmax, Inc."
        linkLabel.isEditable = false
        linkLabel.isBordered = false
        linkLabel.backgroundColor = .clear
        linkLabel.font = NSFont.systemFont(ofSize: 10)
        linkLabel.textColor = .tertiaryLabelColor
        linkLabel.alignment = .center
        contentView.addSubview(linkLabel)

        window.contentView = contentView
        return window
    }

    // MARK: - App Icon Loading

    /// Load the app icon from the .app bundle's Resources directory.
    /// Derives the path from the executable location (same approach as TranscriptionEngine)
    /// because SPM-built binaries don't embed standard bundle metadata.
    private static func loadAppIcon() -> NSImage? {
        let executablePath = ProcessInfo.processInfo.arguments[0]
        let macOSDir = (executablePath as NSString).deletingLastPathComponent
        let contentsDir = (macOSDir as NSString).deletingLastPathComponent
        let resourcesDir = (contentsDir as NSString).appendingPathComponent("Resources")
        let iconPath = (resourcesDir as NSString).appendingPathComponent("AppIcon.icns")

        if FileManager.default.fileExists(atPath: iconPath) {
            return NSImage(contentsOfFile: iconPath)
        }

        // Fallback: try Bundle.main (works in Xcode builds)
        if let bundlePath = Bundle.main.resourcePath {
            let bundleIconPath = (bundlePath as NSString).appendingPathComponent("AppIcon.icns")
            if FileManager.default.fileExists(atPath: bundleIconPath) {
                return NSImage(contentsOfFile: bundleIconPath)
            }
        }

        return nil
    }

    // MARK: - License Text

    private static let acknowledgements = """
    WhisperKit
    Copyright (c) 2024 Argmax, Inc.
    MIT License
    https://github.com/argmaxinc/WhisperKit

    Permission is hereby granted, free of charge, to any \
    person obtaining a copy of this software and associated \
    documentation files (the "Software"), to deal in the \
    Software without restriction, including without limitation \
    the rights to use, copy, modify, merge, publish, \
    distribute, sublicense, and/or sell copies of the \
    Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice \
    shall be included in all copies or substantial portions \
    of the Software.

    ─────────────────────────────────────

    OpenAI Whisper
    Copyright (c) 2022 OpenAI
    MIT License
    https://github.com/openai/whisper

    Permission is hereby granted, free of charge, to any \
    person obtaining a copy of this software and associated \
    documentation files (the "Software"), to deal in the \
    Software without restriction, including without limitation \
    the rights to use, copy, modify, merge, publish, \
    distribute, sublicense, and/or sell copies of the \
    Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice \
    shall be included in all copies or substantial portions \
    of the Software.

    ─────────────────────────────────────

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF \
    ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED \
    TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A \
    PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT \
    SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR \
    ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN \
    ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE \
    OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

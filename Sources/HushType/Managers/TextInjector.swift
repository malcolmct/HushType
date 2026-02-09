import AppKit
import Carbon

/// Injects transcribed text into the currently focused application.
/// Supports two modes:
///   1. Clipboard paste (default) — copies text to clipboard, simulates Cmd+V
///   2. Keystroke simulation — sends individual CGEvent keystrokes for each character
class TextInjector {

    // MARK: - Public API

    /// Inject the given text into the focused application.
    /// Uses the injection method specified in AppSettings.
    func injectText(_ text: String) {
        if AppSettings.shared.useClipboardInjection {
            injectViaPaste(text)
        } else {
            injectViaKeystrokes(text)
        }
    }

    // MARK: - Incremental Injection (Real-time Mode)

    /// Incrementally update the text in the focused application by computing the diff
    /// between what was previously injected and the new transcription, then using
    /// backspace to remove divergent characters and typing the new suffix.
    ///
    /// Always uses keystroke mode (not clipboard paste) for character-level control.
    ///
    /// - Parameters:
    ///   - oldText: The text that was previously typed into the application.
    ///   - newText: The new full transcription to display.
    func injectIncremental(replacing oldText: String, with newText: String) {
        // Find the longest common prefix, ignoring case differences.
        // Whisper often flips capitalisation between ticks (e.g. "i went" → "I went").
        // A case-sensitive diff would delete and retype the entire sentence just for
        // that one letter. Case-insensitive matching keeps the prefix long and only
        // updates what actually changed. The final transcription corrects casing.
        let commonPrefixLength = zip(oldText, newText)
            .prefix(while: { $0.lowercased() == $1.lowercased() }).count

        // Delete characters after the common prefix in the old text
        let charsToDelete = oldText.count - commonPrefixLength
        if charsToDelete > 0 {
            sendBackspaces(count: charsToDelete)

            // Give the target app time to process all backspaces before we start
            // typing new characters. Without this pause, the new keystrokes can
            // arrive before the app finishes deleting, producing garbled output.
            let settleTime: UInt32 = charsToDelete > 20
                ? 200_000    // 200ms for large deletions
                : 100_000    // 100ms for small deletions
            usleep(settleTime)
        }

        // Type the new suffix after the common prefix
        let newSuffix = String(newText.dropFirst(commonPrefixLength))
        if !newSuffix.isEmpty {
            for char in newSuffix {
                if let mapping = Self.keycodeMap[char] {
                    simulateKeyPress(keyCode: mapping.keycode, modifiers: mapping.modifiers)
                } else {
                    injectUnicodeCharacter(char)
                }
                usleep(5_000) // 5ms between keystrokes
            }
        }

        let deleted = charsToDelete > 0 ? "deleted \(charsToDelete)" : "no deletes"
        let typed = newSuffix.count > 0 ? "typed \(newSuffix.count)" : "no new chars"
        print("[TextInjector] Incremental update: \(deleted), \(typed)")
    }

    /// Send a number of backspace key events to delete characters before the cursor.
    private func sendBackspaces(count: Int) {
        let backspaceKeyCode = UInt16(kVK_Delete)
        for _ in 0..<count {
            simulateKeyPress(keyCode: backspaceKeyCode)
            usleep(8_000) // 8ms between backspaces — needs to be slightly slower
                          // than typing to let target apps process deletions reliably
        }
    }

    // MARK: - Paste Mode (Primary)

    /// Inject text by copying to clipboard and simulating Cmd+V.
    /// This handles all Unicode characters, punctuation, and special characters perfectly.
    private func injectViaPaste(_ text: String) {
        // Save the current clipboard contents so we can restore it
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Copy our transcribed text to the clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure pasteboard is ready
        usleep(50_000) // 50ms

        // Simulate Cmd+V (paste)
        simulateKeyPress(keyCode: UInt16(kVK_ANSI_V), modifiers: .maskCommand)

        // Wait a moment, then restore the previous clipboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }

        print("[TextInjector] Injected \(text.count) characters via paste")
    }

    // MARK: - Keystroke Mode (Fallback)

    /// Inject text by simulating individual keystrokes via CGEvent.
    /// More "natural" but may miss special characters on non-US keyboard layouts.
    private func injectViaKeystrokes(_ text: String) {
        for char in text {
            if let mapping = Self.keycodeMap[char] {
                simulateKeyPress(keyCode: mapping.keycode, modifiers: mapping.modifiers)
            } else {
                // Fallback: use CGEvent's Unicode input method
                injectUnicodeCharacter(char)
            }

            // Small delay between keystrokes to avoid overwhelming the target app
            usleep(5_000) // 5ms
        }

        print("[TextInjector] Injected \(text.count) characters via keystrokes")
    }

    // MARK: - CGEvent Helpers

    /// Simulate a key press (down + up) with the given keycode and modifier flags.
    private func simulateKeyPress(keyCode: UInt16, modifiers: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        keyDown.flags = modifiers
        keyUp.flags = modifiers

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Inject a single Unicode character using CGEvent's Unicode string method.
    /// Works for characters that don't have a direct keycode mapping.
    private func injectUnicodeCharacter(_ char: Character) {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { return }

        var utf16Units = Array(String(char).utf16)
        event.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
        event.post(tap: .cghidEventTap)

        // Key up
        guard let upEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        upEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Keycode Map (US Layout)

    private struct KeyMapping {
        let keycode: UInt16
        let modifiers: CGEventFlags
    }

    /// Map of common characters to their virtual keycodes and required modifiers.
    /// Based on the US QWERTY keyboard layout.
    private static let keycodeMap: [Character: KeyMapping] = {
        var map: [Character: KeyMapping] = [:]

        // Lowercase letters
        let letterCodes: [(Character, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
            ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
        ]

        for (char, code) in letterCodes {
            map[char] = KeyMapping(keycode: UInt16(code), modifiers: [])
            // Uppercase version with Shift
            let upper = Character(char.uppercased())
            map[upper] = KeyMapping(keycode: UInt16(code), modifiers: .maskShift)
        }

        // Numbers
        let numberCodes: [(Character, Int)] = [
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
            ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ]

        for (char, code) in numberCodes {
            map[char] = KeyMapping(keycode: UInt16(code), modifiers: [])
        }

        // Shifted number row symbols
        let shiftedSymbols: [(Character, Int)] = [
            ("!", kVK_ANSI_1), ("@", kVK_ANSI_2), ("#", kVK_ANSI_3), ("$", kVK_ANSI_4),
            ("%", kVK_ANSI_5), ("^", kVK_ANSI_6), ("&", kVK_ANSI_7), ("*", kVK_ANSI_8),
            ("(", kVK_ANSI_9), (")", kVK_ANSI_0),
        ]

        for (char, code) in shiftedSymbols {
            map[char] = KeyMapping(keycode: UInt16(code), modifiers: .maskShift)
        }

        // Punctuation and special characters
        map[" "] = KeyMapping(keycode: UInt16(kVK_Space), modifiers: [])
        map["\n"] = KeyMapping(keycode: UInt16(kVK_Return), modifiers: [])
        map["\t"] = KeyMapping(keycode: UInt16(kVK_Tab), modifiers: [])

        map["."] = KeyMapping(keycode: UInt16(kVK_ANSI_Period), modifiers: [])
        map[","] = KeyMapping(keycode: UInt16(kVK_ANSI_Comma), modifiers: [])
        map[";"] = KeyMapping(keycode: UInt16(kVK_ANSI_Semicolon), modifiers: [])
        map["'"] = KeyMapping(keycode: UInt16(kVK_ANSI_Quote), modifiers: [])
        map["-"] = KeyMapping(keycode: UInt16(kVK_ANSI_Minus), modifiers: [])
        map["="] = KeyMapping(keycode: UInt16(kVK_ANSI_Equal), modifiers: [])
        map["/"] = KeyMapping(keycode: UInt16(kVK_ANSI_Slash), modifiers: [])
        map["\\"] = KeyMapping(keycode: UInt16(kVK_ANSI_Backslash), modifiers: [])
        map["["] = KeyMapping(keycode: UInt16(kVK_ANSI_LeftBracket), modifiers: [])
        map["]"] = KeyMapping(keycode: UInt16(kVK_ANSI_RightBracket), modifiers: [])
        map["`"] = KeyMapping(keycode: UInt16(kVK_ANSI_Grave), modifiers: [])

        // Shifted punctuation
        map[":"] = KeyMapping(keycode: UInt16(kVK_ANSI_Semicolon), modifiers: .maskShift)
        map["\""] = KeyMapping(keycode: UInt16(kVK_ANSI_Quote), modifiers: .maskShift)
        map["<"] = KeyMapping(keycode: UInt16(kVK_ANSI_Comma), modifiers: .maskShift)
        map[">"] = KeyMapping(keycode: UInt16(kVK_ANSI_Period), modifiers: .maskShift)
        map["?"] = KeyMapping(keycode: UInt16(kVK_ANSI_Slash), modifiers: .maskShift)
        map["_"] = KeyMapping(keycode: UInt16(kVK_ANSI_Minus), modifiers: .maskShift)
        map["+"] = KeyMapping(keycode: UInt16(kVK_ANSI_Equal), modifiers: .maskShift)
        map["|"] = KeyMapping(keycode: UInt16(kVK_ANSI_Backslash), modifiers: .maskShift)
        map["{"] = KeyMapping(keycode: UInt16(kVK_ANSI_LeftBracket), modifiers: .maskShift)
        map["}"] = KeyMapping(keycode: UInt16(kVK_ANSI_RightBracket), modifiers: .maskShift)
        map["~"] = KeyMapping(keycode: UInt16(kVK_ANSI_Grave), modifiers: .maskShift)

        return map
    }()
}

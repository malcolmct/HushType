# CLAUDE.md — HushType Developer Reference

## What is HushType?

HushType is a macOS menu-bar dictation app that transcribes speech to text entirely on-device using WhisperKit (OpenAI's Whisper compiled for CoreML). The user holds a **configurable modifier key** (Fn by default) to record, releases it to transcribe, and the resulting text is automatically typed into whatever application has focus. There is no cloud dependency — all inference runs locally on Apple Silicon via the Neural Engine.

## System Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon** (M1 or later) — validated at startup in `main.swift`; Intel Macs are rejected with an alert dialog
- **Permissions required:**
  - Microphone access (for audio capture)
  - Accessibility access (for injecting text into other apps via CGEvent)

## Tech Stack

- **Language:** Swift 5.9
- **Build system:** Swift Package Manager (not Xcode project)
- **ML framework:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) 0.9.0+ (CoreML-based Whisper inference)
- **Dependencies:** WhisperKit (only external dependency, declared in `Package.swift`)
- **Target platform:** macOS 14+ (`platforms: [.macOS(.v14)]`)
- **App type:** Menu bar accessory app (`LSUIElement: true` — no dock icon)
- **Bundle ID:** `net.hushtype.app`

## Project Structure

```
HushType/
├── Package.swift                          # SPM manifest
├── Package.resolved                       # Dependency lockfile
├── Sources/HushType/
│   ├── main.swift                         # Entry point: Apple Silicon check, app bootstrap
│   ├── AppDelegate.swift                  # Central orchestrator: menu bar, recording lifecycle
│   ├── RecordingOverlayWindow.swift       # Floating HUD showing recording state + audio levels
│   ├── ModelProgressWindow.swift          # Floating HUD showing model download/load progress
│   ├── SettingsWindowController.swift     # Settings window UI + SettingsActions handler
│   ├── AboutWindowController.swift        # About window with copyright + license attribution
│   ├── Models/
│   │   └── AppSettings.swift              # Singleton UserDefaults-backed settings + TriggerKey enum
│   ├── Managers/
│   │   ├── AudioManager.swift             # AVAudioEngine mic capture → 16kHz mono Float32
│   │   ├── TranscriptionEngine.swift      # WhisperKit model loading + transcription
│   │   ├── TextInjector.swift             # CGEvent text injection (paste or keystrokes)
│   │   ├── HotkeyManager.swift            # Configurable modifier key detection via NSEvent monitors
│   │   └── PermissionManager.swift        # Mic + Accessibility permission management
│   └── Resources/
│       ├── Info.plist                      # App metadata + permission usage descriptions
│       ├── HushType.entitlements           # Sandbox entitlements (sandbox, audio-input, network)
│       ├── AppIcon.icns                    # App icon
│       └── Models/
│           └── openai_whisper-small.en/    # Bundled WhisperKit CoreML model
│               ├── AudioEncoder.mlmodelc/
│               ├── TextDecoder.mlmodelc/
│               ├── MelSpectrogram.mlmodelc/
│               ├── config.json
│               └── generation_config.json
├── build-app.sh                           # Builds release binary + creates .app bundle
├── build-dmg.sh                           # Packages .app into .dmg for direct distribution
├── bundle-model.sh                        # Copies cached model into Resources for bundling
├── create-icns.py                         # Generates AppIcon.icns from SVG
├── icon-design.svg                        # Source icon design
├── HushType.app/                          # Built app bundle (output of build-app.sh)
└── HushType.dmg                           # DMG disk image (output of build-dmg.sh)
```

## Architecture

### Core Data Flow

```
Trigger key press (configurable: Fn, Control, or Option) → start recording
    │
    ▼
AudioManager captures mic → resamples to 16kHz mono Float32
    │                        (AVAudioEngine + AVAudioConverter)
    │
Trigger key release → stop recording
    │
    ▼
Validate audio:
    - Duration ≥ 0.3s (debounce key bounce)
    - Sample count ≥ 8000 (~0.5s at 16kHz)
    - RMS level > 0.001 (not silent)
    │
    ▼
TranscriptionEngine.transcribe(samples)
    │  WhisperKit inference with tuned DecodingOptions
    │  Uses last result from temperature fallback iterations
    │
    ▼
TextInjector.injectText(text)
    ├─ Paste mode (default): clipboard save → copy text → Cmd+V → restore clipboard
    └─ Keystroke mode: per-character CGEvent keystrokes using US keycode map
    │
    ▼
If no Accessibility permission → falls back to copying text to clipboard
```

### Component Responsibilities

**`main.swift`** — Entry point. Checks for Apple Silicon via `uname()`. Sets activation policy to `.accessory` (menu bar only). Creates `AppDelegate` and runs the app.

**`AppDelegate`** — Central orchestrator. Owns all managers. Sets up the NSStatusItem menu bar with items: status text (tag 1), model info (tag 2), Settings, About, Quit. Coordinates the recording lifecycle: `startRecording()` → `stopRecordingAndTranscribe()`. Manages UI state for overlay, progress window, and menu bar icon (mic/mic.fill with red tint). Listens for `.modelDidChange` and `.triggerKeyDidChange` notifications. On trigger key change, restarts the HotkeyManager and updates all UI text dynamically. Loads the Whisper model asynchronously on launch.

**`HotkeyManager`** — Detects the configured trigger key hold/release via `NSEvent.addGlobalMonitorForEvents` and `addLocalMonitorForEvents` for `.flagsChanged`. Reads `AppSettings.shared.triggerKey` on each event to determine which modifier to detect. Dynamically builds an exclusion set of all other modifiers so the trigger key must be pressed alone. Deduplicates events between global and local monitors using timestamp comparison. Dispatches `onKeyDown`/`onKeyUp` callbacks to main thread. Call `restartListening()` after changing the trigger key setting.

**`AudioManager`** — Captures audio via `AVAudioEngine`. Installs a tap on the input node with 4096 buffer size in the mic's native format. Uses `AVAudioConverter` to resample to 16kHz mono Float32 (WhisperKit's required format). Accumulates samples in a thread-safe buffer (protected by `bufferQueue` dispatch queue). Calculates RMS audio level (normalized to 0–1 by multiplying by 3.0) and reports via `onAudioLevel` callback. Provides `availableInputDevices` via AVCaptureDevice discovery.

**`TranscriptionEngine`** — Manages WhisperKit model lifecycle and transcription. Model resolution follows a priority chain:

1. **Bundled model** — Checks `.app/Contents/Resources/Models/` (derived from executable path, not `Bundle.main.resourcePath`, because SPM-built binaries don't embed bundle metadata)
2. **Cached model** — Searches the app's sandbox container (Caches and Application Support), then non-sandboxed HuggingFace cache locations (`~/.cache/huggingface/hub/`, `~/huggingface/`)
3. **Download** — Downloads from HuggingFace repo `argmaxinc/whisperkit-coreml` with progress callbacks
4. **Fallback** — If all fail, tries bundled `small.en`, then downloads `base` as last resort (updates `AppSettings.modelSize` on fallback)

Model name resolution handles variants (e.g., `large-v3-turbo` → `large-v3_turbo` → `openai_whisper-large-v3_turbo`).

Transcription uses `DecodingOptions` tuned for accuracy:
- `language`: reads `AppSettings.shared.language` — nil for auto-detect, or an ISO 639-1 code (e.g. `"fr"`, `"de"`)
- `temperature: 0.0` (greedy decoding)
- `temperatureFallbackCount: 5`
- `sampleLength`: 448 for large/medium models, 224 for everything else (including turbo)
- `compressionRatioThreshold: 2.0`, `logProbThreshold: -0.7`, `noSpeechThreshold: 0.5` (stricter thresholds)
- Uses the **last** result from WhisperKit (best quality after temperature fallback)

Also defines `supportedLanguages`: a static list of 30 languages (code + display name) used by the Settings UI language picker.

Posts `Notification.Name.modelDidChange` when a model finishes loading.

**`TextInjector`** — Two injection modes:

- **Paste mode** (default, recommended): Saves clipboard → copies text → waits 50ms → simulates Cmd+V via CGEvent → restores clipboard after 300ms. Handles all Unicode perfectly.
- **Keystroke mode**: Iterates each character, looks up in a static `keycodeMap` (US QWERTY layout: letters, numbers, shifted symbols, punctuation), falls back to `CGEvent.keyboardSetUnicodeString` for unmapped characters. 5ms delay between keystrokes.

Both modes use `CGEventSource(stateID: .hidSystemState)` and post to `.cghidEventTap`.

**`PermissionManager`** — Checks `AVCaptureDevice.authorizationStatus(.audio)` for microphone. Checks `AXIsProcessTrusted()` for accessibility. Prompts via `AXIsProcessTrustedWithOptions` (accessibility) or `AVCaptureDevice.requestAccess` (microphone). Shows alert dialog with link to System Settings if denied.

**`AppSettings`** — Singleton backed by `UserDefaults.standard`. Also defines the `TriggerKey` enum (`fn`, `control`, `option`) with properties for `modifierFlag`, `displayName`, and `shortName`. Shift and Command are excluded because they conflict heavily with system and app shortcuts. The `startAtLogin` property is NOT stored in UserDefaults — it uses `SMAppService.mainApp` (ServiceManagement framework) as its source of truth, which integrates directly with System Settings > Login Items. Settings:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `modelSize` | `String` | `"small.en"` | WhisperKit model identifier |
| `useClipboardInjection` | `Bool` | `true` | Paste mode vs keystroke mode |
| `triggerKey` | `TriggerKey` | `.fn` | Modifier key for push-to-talk (posts `.triggerKeyDidChange` on set) |
| `audioInputDeviceID` | `String?` | `nil` (system default) | Selected microphone device ID |
| `showOverlay` | `Bool` | `true` | Show floating recording overlay |
| `language` | `String?` | `nil` (auto-detect) | Transcription language |
| `startAtLogin` | `Bool` | `false` | Register/unregister via SMAppService (not in UserDefaults) |

**`RecordingOverlayWindow`** — Non-activating `NSPanel` (200x44 px) positioned at top-center of screen. HUD style with black 85% opacity background, corner radius 10. Shows status text ("Recording…" / "Transcribing…") and a green level bar. Uses `.nonactivatingPanel` + `.hudWindow` + `.utilityWindow` style mask. Collection behavior: `.canJoinAllSpaces`, `.stationary`.

**`ModelProgressWindow`** — Non-activating `NSPanel` (360x120 px) centered on screen. Shows title, progress bar (`NSProgressIndicator`), percentage, and status text. Only appears when downloading (bundled/cached models skip it). Created lazily on first progress callback.

**`SettingsWindowController`** — Static factory (`createWindow()`) building a 460x740 settings window with sections:
- **General**: "Start HushType at login" checkbox (uses SMAppService, re-reads actual state after toggle in case registration fails)
- **Activation**: Dropdown (`NSPopUpButton`) to select the trigger key from all `TriggerKey` cases
- **Whisper Model**: Current model display, advanced checkbox revealing model picker dropdown (tag 101) and hint (tag 102)
- **Language**: Dropdown populated from `TranscriptionEngine.supportedLanguages` (30 languages + auto-detect). When a non-English language is selected and the current model has an `.en` suffix, the handler auto-switches to the multilingual equivalent (e.g. `small.en` → `small`) and triggers a model reload.
- **Text Injection**: Radio buttons for paste (tag 1) vs keystrokes (tag 2)
- **Audio Input**: Dropdown of available microphone devices
- **Display**: Checkbox for recording overlay

`SettingsActions` (singleton `NSObject` subclass) handles UI callbacks including `triggerKeyChanged(_:)`, `languageChanged(_:)`, `startAtLoginToggled(_:)`, and triggers model reloading in `TranscriptionEngine`.

**`AboutWindowController`** — Static factory (`createWindow()`) building a 360x400 About window displaying the app icon, name, version, a brief description, copyright notice (© 2026 Malcolm Taylor), and a scrollable open-source acknowledgements section with full MIT license text for both WhisperKit (Argmax, Inc.) and OpenAI Whisper.

## Available Whisper Models

From smallest/fastest to largest/most accurate:

| Model | Best For |
|-------|----------|
| `tiny` | Fastest, lowest accuracy |
| `tiny.en` | English-only tiny |
| `base` | Fast, reasonable accuracy |
| `base.en` | English-only base |
| `small` | Good balance |
| `small.en` | **Default** — recommended for English |
| `medium` | Higher accuracy, slower |
| `medium.en` | English-only medium |
| `large-v3` | Best accuracy, slowest, most memory |
| `large-v3-turbo` | Distilled large (4-layer decoder), faster than large |

Models are hosted at `argmaxinc/whisperkit-coreml` on HuggingFace.

## Building

### Prerequisites

- Xcode 15+ (for Swift 5.9 toolchain)
- macOS 14+ SDK
- Apple Silicon Mac (for running; cross-compilation works but app won't launch on Intel)

### Build and Run

```bash
# Build release binary and create .app bundle (ad-hoc signed, no sandbox)
./build-app.sh

# Build with App Sandbox entitlements (for App Store testing)
./build-app.sh --sandbox

# Run the app
open HushType.app
```

The build script:
1. Runs `swift build -c release`
2. Creates `.app` bundle structure under `HushType.app/Contents/`
3. Copies binary to `Contents/MacOS/`
4. Copies `AppIcon.icns` to `Contents/Resources/`
5. Copies bundled models to `Contents/Resources/Models/`
6. Copies `Info.plist` from `Sources/HushType/Resources/Info.plist` (single source of truth)
7. Creates `PkgInfo`
8. Code-signs the bundle (ad-hoc by default, with entitlements if `--sandbox` flag is passed)

### Bundling a Model

```bash
# Bundle the small.en model from local cache into the app
./bundle-model.sh
```

This copies the model from HuggingFace cache directories into `Sources/HushType/Resources/Models/`. If the model isn't cached, run the app once first (it will download it), then re-run the script.

### Generating the App Icon

```bash
python3 create-icns.py
```

Converts `icon-design.svg` into `Sources/HushType/Resources/AppIcon.icns`.

## Key Design Decisions

- **Configurable trigger key**: The user can choose Fn, Control, or Option as the push-to-talk trigger. Fn is the default because it's universally available on Mac keyboards and rarely conflicts with other shortcuts. Shift and Command are deliberately excluded — Shift is held constantly while typing capitals, and Command is used by virtually every keyboard shortcut. The trigger key is detected alone — if other modifiers are held simultaneously, the press is ignored to avoid false triggers from key combos.
- **Paste mode default**: Clipboard-based injection is the most reliable method — it handles all Unicode, punctuation, and special characters. Keystroke simulation is US-layout-dependent and may miss symbols.
- **Bundled model priority**: The app checks for a bundled model first (instant load), then cached (no network), then downloads as last resort, providing the fastest possible first-launch experience.
- **Non-activating windows**: Both the recording overlay and progress window use `NSPanel` with `.nonactivatingPanel` to avoid stealing focus from the user's active application.
- **SPM-only (no Xcode project)**: The project uses Swift Package Manager exclusively. The `.app` bundle is created by `build-app.sh` rather than Xcode's build system. This means `Bundle.main.resourcePath` doesn't work as expected — the code derives paths from the executable's filesystem location instead.
- **Apple Silicon only**: WhisperKit requires CoreML/Neural Engine for performant on-device inference. Intel Macs are explicitly unsupported.
- **Minimum recording guards**: Recordings under 0.3 seconds are discarded (key bounce), samples under 8000 (~0.5s) are skipped, and near-silent audio (RMS < 0.001) is ignored.

## Notifications

| Name | Posted By | Description |
|------|-----------|-------------|
| `.modelDidChange` | `TranscriptionEngine` | Fired when a model finishes loading (success or fallback) |
| `.triggerKeyDidChange` | `AppSettings.triggerKey` setter | Fired when the user changes the trigger key in Settings |

## Error Types

**`TranscriptionError`** (in `TranscriptionEngine.swift`):
- `.modelNotLoaded` — Whisper model not initialized
- `.noAudioData` — Empty sample array passed to transcribe

**`AudioManagerError`** (in `AudioManager.swift`):
- `.formatCreationFailed` — Could not create 16kHz audio format
- `.converterCreationFailed` — Could not create AVAudioConverter

## Entitlements

| Key | Description |
|-----|-------------|
| `com.apple.security.app-sandbox` | App Sandbox (required for Mac App Store) |
| `com.apple.security.device.audio-input` | Microphone access for speech recording |
| `com.apple.security.network.client` | Outbound network for downloading Whisper models from HuggingFace |

## Distribution (Mac App Store)

### Requirements

- Apple Developer Program membership ($99/year)
- App ID and provisioning profile configured in App Store Connect
- Bundle identifier: `net.hushtype.app`

### Sandbox Considerations

The App Sandbox restricts filesystem access to the app's container. Key adaptations:
- **Model cache**: `TranscriptionEngine.cachedModelPath()` checks the app container's Caches and Application Support directories first, then falls back to standard HuggingFace cache paths (the latter are only reachable in non-sandboxed development builds).
- **Bundled models**: Still accessible read-only from `.app/Contents/Resources/Models/`.
- **WhisperKit downloads**: In a sandbox, HuggingFace Hub resolves to the app container automatically.
- **Accessibility**: Sandboxed apps can request accessibility permissions via the normal TCC prompt — the user grants it in System Settings > Privacy & Security > Accessibility.
- **Microphone and network**: Declared via entitlements; macOS prompts the user as needed.

### Build and Submit

```bash
# 1. Build with sandbox entitlements
./build-app.sh --sandbox

# 2. Re-sign with your Developer ID
codesign --force --sign "Developer ID Application: Your Name (TEAMID)" \
    --entitlements Sources/HushType/Resources/HushType.entitlements \
    --options runtime HushType.app

# 3. Upload via Transporter or altool
xcrun altool --upload-app -f HushType.app -t macos
```

### Info.plist (App Store fields)

The source `Info.plist` includes all fields required by App Store Connect: `CFBundleDisplayName`, `CFBundleExecutable`, `CFBundlePackageType`, `LSMinimumSystemVersion`, `NSPrincipalClass`, `NSHumanReadableCopyright`, and `ITSAppUsesNonExemptEncryption: false` (the app does not use custom encryption).

## Distribution (Direct / Outside App Store)

For distributing outside the Mac App Store, the app is packaged as a `.dmg` disk image. The user opens the DMG, drags HushType into the Applications folder alias, and runs it from there.

### Requirements

- Apple Developer Program membership ($99/year) — same as App Store
- Developer ID Application certificate (for signing)
- App-specific password for notarization (generated at appleid.apple.com)

### Build and Distribute

```bash
# Build app and create DMG (ad-hoc signed, for local testing)
./build-dmg.sh

# Build, sign with Developer ID, and prepare for distribution
./build-dmg.sh --sign "Developer ID Application: Your Name (TEAMID)"

# Create DMG from an already-built app (skip rebuild)
./build-dmg.sh --skip-build
```

After signing, notarize and staple:

```bash
# Submit for notarization (required to avoid Gatekeeper warnings)
xcrun notarytool submit HushType.dmg \
    --apple-id YOUR_APPLE_ID \
    --team-id YOUR_TEAM_ID \
    --password YOUR_APP_SPECIFIC_PASSWORD \
    --wait

# Staple the notarization ticket to the DMG
xcrun stapler staple HushType.dmg
```

The stapled DMG can be distributed from a website, GitHub releases, or any download host. macOS will verify the notarization on first launch and allow the app to run without warnings.

### Differences from App Store Build

The direct distribution build does NOT use the App Sandbox by default (the `--sandbox` flag is only applied by `build-app.sh`). This means the app has full access to the filesystem and does not need sandbox container paths for model storage. The same codebase works for both — `TranscriptionEngine.cachedModelPath()` checks sandbox container paths first, then falls back to standard paths.

## Login Item (Start at Login)

Uses `SMAppService.mainApp` from the ServiceManagement framework (macOS 13+). The toggle is in Settings > General. When enabled, the app registers as a login item that appears in System Settings > General > Login Items, where the user can also toggle it independently. The `startAtLogin` property on `AppSettings` reads directly from `SMAppService.mainApp.status` — it is not stored in UserDefaults.

## Important Implementation Notes

- The app uses `DispatchQueue.main.async` for all UI updates and `Task { await }` for async model loading and transcription.
- `HotkeyManager` uses both global and local NSEvent monitors because global monitors don't fire when the app itself is focused, and local monitors don't fire when other apps are focused. Timestamp-based deduplication prevents duplicate callbacks. The trigger key is read from `AppSettings.shared.triggerKey` on each `.flagsChanged` event, so changes take effect immediately after `restartListening()` is called.
- `AudioManager.bufferQueue` is a serial dispatch queue that protects the sample buffer from concurrent access between the audio tap callback and `stopRecording()`.
- WhisperKit's `sampleLength` must match the model's decoder capacity: 448 for full large-v3 and medium models, 224 for everything else including turbo (which has a distilled 4-layer decoder).
- The `TextInjector` paste mode restores the user's previous clipboard contents after a 300ms delay, minimizing clipboard disruption.
- All windows in the app use `collectionBehavior: [.canJoinAllSpaces, .stationary]` so they appear on all macOS Spaces/desktops.

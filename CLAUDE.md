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
- **Auto-update:** [Sparkle](https://github.com/sparkle-project/Sparkle) 2.0+ (EdDSA-signed updates)
- **Dependencies:** WhisperKit and Sparkle (declared in `Package.swift`)
- **Target platform:** macOS 14+ (`platforms: [.macOS(.v14)]`)
- **App type:** Menu bar accessory app (`LSUIElement: true` — no dock icon)
- **Bundle ID:** `net.hushtype.app`
- **Repository:** https://github.com/malcolmct/HushType

## Project Structure

```
HushType/
├── Package.swift                              # SPM manifest (WhisperKit + Sparkle)
├── Package.resolved                           # Dependency lockfile
├── .gitignore                                 # Excludes .build/, .app, .dmg, .zip, Models/, .DS_Store
├── Sources/HushType/
│   ├── main.swift                             # Entry point: Apple Silicon check, app bootstrap
│   ├── AppDelegate.swift                      # Central orchestrator: menu bar, recording, Sparkle
│   ├── RecordingOverlayWindow.swift           # Floating HUD showing recording state + audio levels
│   ├── ModelProgressWindow.swift              # Floating HUD showing model download/load progress
│   ├── SettingsWindowController.swift         # Settings window UI (scrollable) + SettingsActions handler
│   ├── AboutWindowController.swift            # About window with dynamic version + license attribution
│   ├── PermissionsWindowController.swift      # Snagit-style permissions table window (shown on launch)
│   ├── Models/
│   │   └── AppSettings.swift                  # Singleton UserDefaults settings + TriggerKey + MenuBarIconStyle enums
│   ├── Managers/
│   │   ├── AudioManager.swift                 # AVAudioEngine mic capture → 16kHz mono Float32
│   │   ├── TranscriptionEngine.swift          # WhisperKit model loading + transcription
│   │   ├── TextInjector.swift                 # CGEvent text injection (paste or keystrokes)
│   │   ├── HotkeyManager.swift                # Configurable modifier key detection via NSEvent monitors
│   │   └── PermissionManager.swift            # Mic + Accessibility permission + post-update re-auth
│   └── Resources/
│       ├── Info.plist                          # App metadata, permission descriptions, Sparkle keys
│       ├── HushType.entitlements               # Sandbox entitlements (for App Store builds only)
│       ├── AppIcon.icns                        # App icon
│       ├── menubar-icon.png / @2x.png         # Custom menu bar icon (idle state)
│       ├── menubar-icon-recording.png / @2x.png # Custom menu bar icon (recording state, bolder)
│       └── Models/
│           └── openai_whisper-small.en/        # Bundled WhisperKit CoreML model
│               ├── AudioEncoder.mlmodelc/
│               ├── TextDecoder.mlmodelc/
│               ├── MelSpectrogram.mlmodelc/
│               ├── config.json
│               └── generation_config.json
├── docs/
│   └── appcast.xml                            # Sparkle appcast (served via GitHub Pages)
├── HushType-distribution.entitlements         # Distribution entitlements (no sandbox, microphone only)
├── build-app.sh                               # Builds release binary + creates .app bundle
├── dmg-background.png                         # DMG background image (1320×880 @2x Retina)
├── create-guide.js                            # Generates HushType-User-Guide.docx (Node.js + docx-js)
├── build-dmg.sh                               # Packages .app into signed .dmg for distribution
├── release.sh                                 # Full release automation (build → sign → notarise → publish)
├── bundle-model.sh                            # Copies cached model into Resources for bundling
├── create-icns.py                             # Generates AppIcon.icns from SVG
└── icon-design.svg                            # Source icon design
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

If no Accessibility permission → falls back to copying text to clipboard
```

### Component Responsibilities

**`main.swift`** — Entry point. Checks for Apple Silicon via `uname()`. Sets activation policy to `.accessory` (menu bar only). Creates `AppDelegate` and runs the app.

**`AppDelegate`** — Central orchestrator. Owns all managers and the Sparkle updater controller. Sets up the NSStatusItem menu bar with items: status text (tag 1), model info (tag 2), Settings, Check for Updates, About (with custom icon), and Quit (no keyboard shortcuts — inappropriate for a background app). Coordinates the recording lifecycle: `startRecording()` → `stopRecordingAndTranscribe()`. Manages UI state for overlay, progress window, and menu bar icon (system SF Symbol or custom branded icon, with red tint when recording). The menu bar icon is initially hidden (`statusItem.isVisible = false`) if permissions are not yet granted, and made visible when `.allRequiredPermissionsGranted` is received. Listens for `.modelDidChange`, `.triggerKeyDidChange`, `.menuBarIconDidChange`, and `.allRequiredPermissionsGranted` notifications. Loads the Whisper model asynchronously on launch and re-checks accessibility once loading completes. On launch, calls `showPermissionsWindowIfNeeded()` which shows the `PermissionsWindowController` if any permission is missing (replacing the old `checkPermissions()` sequential-alert approach).

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

Also defines `supportedLanguages`: a static list of 30 languages (code + display name) sorted alphabetically (Auto-detect first, then A–Z) used by the Settings UI language picker.

Post-processing: `removeRepeatedPhrases(_:)` runs on every transcription result with two conservative passes:
1. **Sentence dedup** — removes consecutive duplicate sentences (case-insensitive)
2. **Trailing echo** — detects when a trailing sequence of words echoes the tail of the preceding text (e.g. "...it performs in the long run. It performs in the long run." → removes the trailing echo). Uses word-level comparison (case-insensitive, punctuation stripped per word). Requires ≥3 matching words to avoid false positives.

The raw Whisper output is always logged before post-processing (`[TranscriptionEngine] Raw Whisper output: "..."`), making it easy to diagnose whether artifacts come from Whisper itself or from post-processing.

Helper methods: `splitIntoSentences(_:)` splits on `.!?` boundaries keeping delimiters attached; `removeTrailingEcho(_:)` performs the trailing echo word-level check.

Posts `Notification.Name.modelDidChange` when a model finishes loading.

**`TextInjector`** — Two injection modes:

- **Paste mode** (default, recommended): Saves clipboard → copies text → waits 50ms → simulates Cmd+V via CGEvent → restores clipboard after 300ms. Handles all Unicode perfectly.
- **Keystroke mode**: Iterates each character, looks up in a static `keycodeMap` (US QWERTY layout: letters, numbers, shifted symbols, punctuation), falls back to `CGEvent.keyboardSetUnicodeString` for unmapped characters. 5ms delay between keystrokes.

Both modes use `CGEventSource(stateID: .hidSystemState)` and post to `.cghidEventTap`.

**`PermissionManager`** — Checks `AVCaptureDevice.authorizationStatus(.audio)` for microphone. Checks `AXIsProcessTrusted()` for accessibility. Two distinct accessibility dialogs:
- **First-time**: Instructions to add HushType to the Accessibility list
- **Post-update**: Detects version change via `UserDefaults` tracking (`LastAccessibilityGrantedVersion`) and shows instructions to remove and re-add the entry, explaining this is required by macOS after code changes

Both dialogs include an "Open Settings" button that navigates directly to the Accessibility pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`). Records the current version when accessibility is confirmed granted. Also re-checks accessibility after the model finishes loading via `recheckAccessibility()`.

**App Management permission** is recommended but not required for core functionality. It allows Sparkle to install automatic updates in `/Applications`. Normally, matching Developer ID code signatures mean macOS allows updates without this permission, but edge cases can arise where macOS blocks an update. The permissions window includes an App Management row with a "Setup…" button that opens System Settings to Privacy & Security and shows inline guidance directing the user to scroll down to "App Management" and toggle on HushType. The guidance also explains the alternative of clicking the plus button below the list to add HushType manually from the Applications folder (since HushType won't appear in the App Management list until macOS has blocked an update attempt). There is no public API to check App Management status or deep-link to the App Management section, so the row never auto-detects — its Setup button always remains visible. The counter only tracks the 2 required permissions (Microphone + Accessibility).

Aggregate helper methods (used by `PermissionsWindowController`): `allPermissionsGranted()` combines both required permission checks (microphone + accessibility); `requestMicrophonePermissionSilent()` triggers system dialog or opens Settings without custom alerts; `openAccessibilitySettingsDirectly()` opens Settings immediately; `openPrivacySecuritySettings()` opens Privacy & Security for App Management navigation — terminates System Settings first if it's already running (checks both `com.apple.systempreferences` and `com.apple.SystemSettings` bundle IDs), with a 0.5s delay before reopening, so it navigates to the correct root page instead of staying at a previous section. Also defines `Notification.Name.allRequiredPermissionsGranted`.

**`AppSettings`** — Singleton backed by `UserDefaults.standard`. Also defines the `TriggerKey` enum (`fn`, `control`, `option`) and the `MenuBarIconStyle` enum (`system`, `custom`). Shift and Command are excluded from trigger keys because they conflict heavily with system and app shortcuts. The `startAtLogin` property is NOT stored in UserDefaults — it uses `SMAppService.mainApp` (ServiceManagement framework) as its source of truth, which integrates directly with System Settings > Login Items. Settings:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `modelSize` | `String` | `"small.en"` | WhisperKit model identifier |
| `useClipboardInjection` | `Bool` | `true` | Paste mode vs keystroke mode |
| `triggerKey` | `TriggerKey` | `.fn` | Modifier key for push-to-talk (posts `.triggerKeyDidChange` on set) |
| `audioInputDeviceID` | `String?` | `nil` (system default) | Selected microphone device ID |
| `showOverlay` | `Bool` | `true` | Show floating recording overlay |
| `language` | `String?` | `nil` (auto-detect) | Transcription language |
| `menuBarIconStyle` | `MenuBarIconStyle` | `.custom` | Menu bar icon appearance (posts `.menuBarIconDidChange` on set) |
| `startAtLogin` | `Bool` | `false` | Register/unregister via SMAppService (not in UserDefaults) |

**`RecordingOverlayWindow`** — Non-activating `NSPanel` (200x44 px) positioned at top-center of screen. HUD style with black 85% opacity background, corner radius 10. Shows status text ("Recording…" / "Transcribing…") and a green level bar. Uses `.nonactivatingPanel` + `.hudWindow` + `.utilityWindow` style mask. Collection behavior: `.canJoinAllSpaces`, `.stationary`.

**`ModelProgressWindow`** — Non-activating `NSPanel` (360x120 px) centered on screen. Shows title, progress bar (`NSProgressIndicator`), percentage, and status text. Only appears when downloading (bundled/cached models skip it). Created lazily on first progress callback.

**`SettingsWindowController`** — Static factory (`createWindow()`) building a 460-wide settings window wrapped in an `NSScrollView` for small-screen support (auto-hiding scrollers, min height 400, resizable vertically). Uses an empty `NSToolbar` with `.unifiedCompact` style to center the window title. Always scrolls to the top of the form when opened. Layout uses indented controls: `labelX=52, controlX=186, controlWidth=224, labelWidth=126`, with section backgrounds at `inset=38`. Sections:
- **General**: "Start HushType at login" checkbox (uses SMAppService, re-reads actual state after toggle in case registration fails)
- **Activation**: Dropdown (`NSPopUpButton`) to select the trigger key from all `TriggerKey` cases
- **Whisper Model**: Current model display (tag 100), advanced checkbox revealing model picker dropdown (tag 101) and hint (tag 102). When the checkbox is toggled, the model section background expands/contracts and all sections below shift down/up by 72pt. The window also resizes to accommodate, capped to screen height.
- **Language**: Dropdown populated from `TranscriptionEngine.supportedLanguages` (30 languages + auto-detect, sorted alphabetically). When a non-English language is selected and the current model has an `.en` suffix, the handler auto-switches to the multilingual equivalent (e.g. `small.en` → `small`) and triggers a model reload.
- **Text Injection**: Radio buttons for paste (tag 1) vs keystrokes (tag 2)
- **Audio Input**: Dropdown of available microphone devices
- **Display**: Checkbox for recording overlay, popup for menu bar icon style (system SF Symbol or custom HushType icon)

`SettingsActions` (singleton `NSObject` subclass) handles UI callbacks including `triggerKeyChanged(_:)`, `languageChanged(_:)`, `startAtLoginToggled(_:)`, `menuBarIconStyleChanged(_:)`, and triggers model reloading in `TranscriptionEngine`. Stores `weak var modelSectionBackground: NSBox?` (set during window construction) for the model section expansion logic — `NSBox.tag` is read-only so a direct reference is used instead. Tracks `modelExpanded: Bool` and uses a 72pt `modelExpansionDelta` to shift views below a computed Y threshold.

**`AboutWindowController`** — Static factory (`createWindow()`) building a 360x400 About window displaying the app icon, name, **dynamic version and build number** (read from `Bundle.main` `CFBundleShortVersionString` and `CFBundleVersion` at runtime), a brief description, copyright notice (© 2026 Malcolm Taylor), and a scrollable open-source acknowledgements section with full MIT license text for both WhisperKit (Argmax, Inc.) and OpenAI Whisper.

**`PermissionsWindowController`** — Snagit-style permissions window shown on launch when any required permission is not yet granted. Static factory (`createWindow(permissionManager:)`) returning an NSWindow, matching the pattern used by Settings and About windows. Self-retains via a static `retainedInstance` while open (released on `windowWillClose` via NSWindowDelegate). Shows three permission rows (Microphone, Accessibility, App Management). The window uses `level = .floating` and `hidesOnDeactivate = false` so it stays above other windows even when the user switches to System Settings. Contains:
  - SF Symbol icon (`mic.fill`, `hand.raised.fill`, `arrow.triangle.2.circlepath`)
  - Bold title and description text
  - Right side: blue "Enable" button (for required permissions, when not granted), gray "Setup…" button (for App Management), or green checkmark + "Enabled!" label (when granted)
- Counter label ("N of 2 Required") and a "Done" button

A 1-second polling timer (`refreshStatus()`) checks both required permission states (Microphone + Accessibility) and updates the UI live. When both required permissions are granted, posts `.allRequiredPermissionsGranted` notification (observed by AppDelegate to show the menu bar icon). If the user closes the window before granting all required permissions, `windowWillClose` calls `NSApp.terminate(nil)` — the app can't function without them.

Enable button actions: Microphone triggers `AVCaptureDevice.requestAccess` (system dialog) or opens System Settings if already denied; Accessibility opens System Settings directly. App Management's "Setup…" button calls `permissionManager.openPrivacySecuritySettings()` and reveals inline guidance text.

**Accessibility stale hint**: If the user clicks "Enable" for Accessibility but it remains ungranted after 5 polling cycles, a warning hint appears explaining that a previous HushType entry may need to be removed first. A "Restart HushType" button (orange-styled) appears alongside it, because `AXIsProcessTrusted()` is cached per-PID — macOS won't recognise a newly-added Accessibility entry for an already-running process. The restart uses `Process.launchedProcess(launchPath: "/bin/sh", arguments: ["-c", "sleep 1 && open \"\(bundlePath)\""])` followed by `NSApp.terminate(nil)`. When accessibility is granted, the hint auto-hides and the window contracts.

**Guidance area system**: Both the accessibility stale hint and App Management guidance can coexist simultaneously, stacked from bottom to top. Tracked by `staleHintVisible` and `appMgmtGuidanceVisible` booleans with `currentWindowGrowth: CGFloat`. `updateGuidanceArea()` computes the delta between needed and current growth, resizes the window, and shifts non-guidance subviews. `layoutGuidanceContent()` positions items from bottom to top.

## Menu Bar Icon

HushType offers two menu bar icon styles (configurable in Settings > Display):

- **System**: Apple SF Symbol (`mic` / `mic.fill` when recording)
- **Custom** (default): Branded icon designed to resemble a modified microphone with wave/whisper motifs, distinguishable from Apple's official mic icon

Custom icons are template images (black on transparent, `isTemplate = true`) at 18×18 @1x and 36×36 @2x. All icon variants have been thickened using sub-pixel dilation (2× upscale → Pillow `MaxFilter(3)` → LANCZOS downscale, giving 0.5px stroke thickening at original resolution) to appear more substantial alongside other menu bar icons. The recording variants have additional weight. Icons are loaded from the app bundle's Resources directory, falling back to SF Symbols if not found. The menu bar icon tints red when recording.

The About menu item also displays a small version of the custom icon.

## Sparkle Auto-Update

HushType uses Sparkle 2 for in-app software updates, distributed as a binary XCFramework via SPM.

### Configuration

- **Feed URL**: `https://malcolmct.github.io/HushType/appcast.xml` (served via GitHub Pages from the `docs/` folder on the `main` branch)
- **Public EdDSA key**: Stored in `Info.plist` as `SUPublicEDKey` — `VCp3VRnO850+dcTwfhLh5JjgP6yBTUmz9YaHa9eFJ1A=`
- **Private key**: Stored in the developer's Keychain (generated by Sparkle's `generate_keys`)
- **Update ZIPs**: Hosted on GitHub Releases (not GitHub Pages) — download URLs use `https://github.com/malcolmct/HushType/releases/download/v{VERSION}/HushType-{VERSION}.zip`

### Integration

- `SPUStandardUpdaterController` is initialized in `AppDelegate.applicationDidFinishLaunching` **before** `setupStatusItem()` (so the menu item can reference it)
- "Check for Updates…" menu item routes through `AppDelegate.checkForUpdates()` wrapper (direct `#selector` targeting of `SPUStandardUpdaterController` doesn't work with NSMenu validation)
- Sparkle.framework is embedded at `Contents/Frameworks/Sparkle.framework` by `build-app.sh`, with `@executable_path/../Frameworks` rpath added via `install_name_tool`

### Code Signing for Sparkle

Sparkle's internal helpers (XPC services, Autoupdate, Updater, Installer executables) must be signed **inside-out** before the main app bundle. Both `build-dmg.sh` (when `--sign` is passed) and `release.sh` handle this:
1. Sign XPC services (`*.xpc` bundles)
2. Sign helper Mach-O executables (Autoupdate, Updater, Installer)
3. Sign `Sparkle.framework` itself
4. Sign the main app bundle last

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
5. Copies custom menu bar icon PNGs to `Contents/Resources/`
6. Copies bundled models to `Contents/Resources/Models/`
7. Embeds `Sparkle.framework` into `Contents/Frameworks/` (from SPM build artifacts) and adds rpath
8. Copies `Info.plist` from `Sources/HushType/Resources/Info.plist` (single source of truth)
9. Creates `PkgInfo`
10. Code-signs the bundle in `/tmp` (to avoid iCloud extended attribute interference)

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

## Distribution (Direct / Outside App Store)

HushType is distributed outside the Mac App Store because the sandbox restricts `NSEvent.addGlobalMonitorForEvents` and `CGEvent` keystroke simulation, which are essential for the app's push-to-talk and text injection features.

### Entitlements

Two entitlements files exist for different purposes:

| File | Contains Sandbox? | Used By | Purpose |
|------|-------------------|---------|---------|
| `HushType.entitlements` | Yes | `build-app.sh --sandbox` | App Store builds (not currently viable) |
| `HushType-distribution.entitlements` | No | `build-dmg.sh`, `release.sh` | Developer ID distribution |

The distribution entitlements contain only `com.apple.security.device.audio-input` (microphone access for hardened runtime). No sandbox, no network entitlement needed (network is unrestricted outside the sandbox).

### Build DMG

```bash
# Build app and create DMG (ad-hoc signed, for local testing)
./build-dmg.sh

# Build, sign with Developer ID, and prepare for distribution
./build-dmg.sh --sign "Developer ID Application: Your Name (TEAMID)"

# Create DMG from an already-built app (skip rebuild)
./build-dmg.sh --skip-build
```

The DMG includes a branded Finder layout (AppleScript-configured) with the app, an Applications alias for drag-to-install, and the User Guide (PDF preferred, docx fallback). A custom background image (`dmg-background.png`, 1320×880 @2x Retina) is stored in a hidden `.background` directory inside the DMG and shows a dashed arrow between the app and Applications icons, with "Drag to Applications to install" text. The 660×440 window layout positions HushType.app at (140, 185), Applications at (520, 185), and the User Guide at (330, 345). The `release.sh` script converts the docx to PDF using LibreOffice (`soffice --headless`) or pandoc before building the DMG.

### Release Workflow

The `release.sh` script automates the full release pipeline:

```bash
./release.sh 1.9
```

Steps:
1. **Pre-flight check** — warns if there are uncommitted changes (prompts to continue or abort)
2. **Update version** — sets `CFBundleShortVersionString` and `CFBundleVersion` in Info.plist
3. **Build** — runs `build-app.sh` to compile and create the .app bundle
4. **Sign** — Developer ID signing with inside-out Sparkle framework signing
5. **Create DMG** — packages the signed app via `build-dmg.sh --skip-build`, then signs the DMG
6. **Notarise** — submits the DMG to Apple via `xcrun notarytool` (notarises all binaries inside)
7. **Staple** — staples notarisation tickets to both the `.app` bundle and the `.dmg`
8. **Create Sparkle ZIP** — `ditto` ZIP of the stapled app (notarisation ticket included)
9. **Generate appcast** — runs `generate_appcast` with `--download-url-prefix` pointing to GitHub Releases
10. **GitHub Release** — creates release via `gh release create` with DMG and ZIP attached
11. **Commit & push** — commits updated `appcast.xml` and `Info.plist`, pushes to `main`

Prerequisites:
- `gh` CLI installed and authenticated
- Developer ID certificate in Keychain
- Sparkle EdDSA private key in Keychain
- Notarytool credentials stored: `xcrun notarytool store-credentials "HushType"`

Hardcoded values in release.sh:
- `SIGN_IDENTITY="Developer ID Application: Malcolm Taylor (98MYPLP7G2)"`
- Download URL prefix: `https://github.com/malcolmct/HushType/releases/download/v{VERSION}/`

### Update Distribution Architecture

```
GitHub Pages (docs/ on main branch)
  └── appcast.xml ← Sparkle checks this for updates

GitHub Releases (per version tag)
  ├── HushType-{VERSION}.zip ← Sparkle downloads this
  └── HushType.dmg ← Users download this for first install

Sparkle flow:
  App launch → fetch appcast.xml → compare versions →
  download ZIP from GitHub Releases → extract → install → relaunch
```

**Important**: The GitHub repository must be **public** for GitHub Pages to serve the appcast and for GitHub Releases download URLs to be accessible.

## Notifications

| Name | Posted By | Description |
|------|-----------|-------------|
| `.modelDidChange` | `TranscriptionEngine` | Fired when a model finishes loading (success or fallback) |
| `.triggerKeyDidChange` | `AppSettings.triggerKey` setter | Fired when the user changes the trigger key in Settings |
| `.menuBarIconDidChange` | `AppSettings.menuBarIconStyle` setter | Fired when the user changes the icon style in Settings |
| `.allRequiredPermissionsGranted` | `PermissionsWindowController` | Fired when both Microphone and Accessibility are granted; observed by AppDelegate to show the menu bar icon |

## Error Types

**`TranscriptionError`** (in `TranscriptionEngine.swift`):
- `.modelNotLoaded` — Whisper model not initialized
- `.noAudioData` — Empty sample array passed to transcribe

**`AudioManagerError`** (in `AudioManager.swift`):
- `.formatCreationFailed` — Could not create 16kHz audio format
- `.converterCreationFailed` — Could not create AVAudioConverter

## Login Item (Start at Login)

Uses `SMAppService.mainApp` from the ServiceManagement framework (macOS 13+). The toggle is in Settings > General. When enabled, the app registers as a login item that appears in System Settings > General > Login Items, where the user can also toggle it independently. The `startAtLogin` property on `AppSettings` reads directly from `SMAppService.mainApp.status` — it is not stored in UserDefaults.

## Key Design Decisions

- **Configurable trigger key**: The user can choose Fn, Control, or Option as the push-to-talk trigger. Fn is the default because it's universally available on Mac keyboards and rarely conflicts with other shortcuts. Shift and Command are deliberately excluded — Shift is held constantly while typing capitals, and Command is used by virtually every keyboard shortcut. The trigger key is detected alone — if other modifiers are held simultaneously, the press is ignored to avoid false triggers from key combos.
- **Paste mode default**: Clipboard-based injection is the most reliable method — it handles all Unicode, punctuation, and special characters. Keystroke simulation is US-layout-dependent and may miss symbols.
- **Bundled model priority**: The app checks for a bundled model first (instant load), then cached (no network), then downloads as last resort, providing the fastest possible first-launch experience.
- **Non-activating windows**: Both the recording overlay and progress window use `NSPanel` with `.nonactivatingPanel` to avoid stealing focus from the user's active application.
- **SPM-only (no Xcode project)**: The project uses Swift Package Manager exclusively. The `.app` bundle is created by `build-app.sh` rather than Xcode's build system. This means `Bundle.main.resourcePath` doesn't work as expected — the code derives paths from the executable's filesystem location instead.
- **Apple Silicon only**: WhisperKit requires CoreML/Neural Engine for performant on-device inference. Intel Macs are explicitly unsupported.
- **Minimum recording guards**: Recordings under 0.3 seconds are discarded (key bounce), samples under 8000 (~0.5s) are skipped, and near-silent audio (RMS < 0.001) is ignored.
- **No keyboard shortcuts in menu**: HushType is a background/menu bar app — standard keyboard shortcuts (Cmd+Q, Cmd+,) don't make sense because the app window is never focused in normal use.
- **Custom menu bar icon default**: The custom branded icon is the default because the system SF Symbol `mic` looks too much like an official Apple icon, which confused test users.
- **Distribution outside App Store**: The app sandbox blocks `NSEvent.addGlobalMonitorForEvents` and `CGEvent` keystroke simulation, making App Store distribution non-viable. Distributed via signed, notarised DMG with Sparkle auto-updates.
- **Separate distribution entitlements**: The sandbox entitlements (`HushType.entitlements`) are kept for potential future App Store use, but distribution builds use `HushType-distribution.entitlements` (microphone only, no sandbox) to allow Sparkle updates and CGEvent text injection.
- **Single notarisation submission**: The release script notarises the DMG (which notarises all binaries inside it), then staples both the app and DMG. This avoids uploading twice (once for app, once for DMG). The Sparkle ZIP is created from the stapled app so the update also contains the notarisation ticket.

## User Guide

A Word document user guide (`HushType-User-Guide.docx`) is generated by the `create-guide.js` Node.js script in the project root. The guide covers installation, permissions setup, menu bar items, all Settings panel options, auto-updates, and troubleshooting.

**Important:** Whenever significant changes are made to HushType — new settings, UI changes, new menu items, behaviour changes, or permission requirements — the user guide must be updated to match. Edit `create-guide.js` and regenerate the docx by running `node create-guide.js`. The guide includes a version number (matching the app's `CFBundleShortVersionString` from Info.plist) which should be updated when releasing a new version.

**Screenshots:** The guide embeds real screenshots from `docs/screenshots/` when they exist, falling back to grey placeholder boxes when they don't. The `SCREENSHOT_MAP` at the top of `create-guide.js` maps each placeholder caption to its expected filename. Current mappings: `dmg-install.png`, `menubar-icon.png`, `permission-window.png`, `permission-microphone.png`, `permission-accessibility.png`, `menubar-dropdown.png`, `settings-panel.png`. Images are auto-scaled to fit the page width (max 6.5 inches / 468pt, capped at 4 inches tall).

## Important Implementation Notes

- The app uses `DispatchQueue.main.async` for all UI updates and `Task { await }` for async model loading and transcription.
- `HotkeyManager` uses both global and local NSEvent monitors because global monitors don't fire when the app itself is focused, and local monitors don't fire when other apps are focused. Timestamp-based deduplication prevents duplicate callbacks. The trigger key is read from `AppSettings.shared.triggerKey` on each `.flagsChanged` event, so changes take effect immediately after `restartListening()` is called.
- `AudioManager.bufferQueue` is a serial dispatch queue that protects the sample buffer from concurrent access between the audio tap callback and `stopRecording()`.
- WhisperKit's `sampleLength` must match the model's decoder capacity: 448 for full large-v3 and medium models, 224 for everything else including turbo (which has a distilled 4-layer decoder).
- The `TextInjector` paste mode restores the user's previous clipboard contents after a 300ms delay, minimizing clipboard disruption.
- All windows in the app use `collectionBehavior: [.canJoinAllSpaces, .stationary]` so they appear on all macOS Spaces/desktops.
- The settings window uses `NSScrollView` with auto-hiding scrollers for small-screen support, and an empty `NSToolbar` with `.unifiedCompact` style to center the window title on modern macOS.
- The About window reads version and build numbers dynamically from `Bundle.main` (`CFBundleShortVersionString` and `CFBundleVersion`) rather than hardcoding them.
- `PermissionManager` tracks the last app version that had accessibility granted in UserDefaults. After an update changes the version, it shows a specific "re-authorise" dialog instead of the generic first-time prompt.
- Sparkle's `SPUStandardUpdaterController` must be initialized **before** `setupStatusItem()` in `applicationDidFinishLaunching` — otherwise the updater controller is nil when the "Check for Updates" menu item is created.
- The "Check for Updates" menu item targets an `@objc` wrapper on `AppDelegate` rather than directly targeting `SPUStandardUpdaterController.checkForUpdates(_:)`, because NSMenu validation doesn't work correctly with the direct selector approach.
- Build scripts copy the app bundle to `/tmp` for code signing to avoid iCloud-synced folders (like `~/Documents`) re-adding extended attributes that `codesign` rejects.
- The `find` commands for Sparkle helper signing use `\( -name "X" -o -name "Y" \)` with escaped parentheses to correctly group the `-o` (OR) conditions.

import Foundation
import WhisperKit

/// Notification posted when the active model changes (after loading completes).
extension Notification.Name {
    static let modelDidChange = Notification.Name("HushTypeModelDidChange")
}

/// Manages WhisperKit model loading and audio transcription.
/// Runs Whisper locally on Apple Silicon via CoreML/Neural Engine.
class TranscriptionEngine {

    // MARK: - Properties

    private var whisperKit: WhisperKit?
    private var isLoading = false

    /// The name of the currently loaded model (may differ from requested if fallback occurred).
    private(set) var loadedModelName: String?

    /// Callback for download/loading progress updates.
    /// Called with (fractionCompleted: 0.0–1.0, statusText: String).
    var onProgress: ((Double, String) -> Void)?

    /// Available Whisper model sizes, from fastest/smallest to most accurate/largest.
    static let availableModels = [
        "tiny",
        "tiny.en",
        "base",
        "base.en",
        "small",
        "small.en",
        "medium",
        "medium.en",
        "large-v3",
        "large-v3-turbo",
    ]

    /// Languages well-supported by Whisper, as (code, displayName) pairs.
    /// The code is the Whisper language token (ISO 639-1). nil means auto-detect.
    static let supportedLanguages: [(code: String?, name: String)] = [
        (nil,   "Auto-detect"),
        ("en",  "English"),
        ("es",  "Spanish"),
        ("fr",  "French"),
        ("de",  "German"),
        ("it",  "Italian"),
        ("pt",  "Portuguese"),
        ("nl",  "Dutch"),
        ("ru",  "Russian"),
        ("zh",  "Chinese"),
        ("ja",  "Japanese"),
        ("ko",  "Korean"),
        ("ar",  "Arabic"),
        ("hi",  "Hindi"),
        ("tr",  "Turkish"),
        ("pl",  "Polish"),
        ("sv",  "Swedish"),
        ("da",  "Danish"),
        ("no",  "Norwegian"),
        ("fi",  "Finnish"),
        ("cs",  "Czech"),
        ("el",  "Greek"),
        ("he",  "Hebrew"),
        ("th",  "Thai"),
        ("vi",  "Vietnamese"),
        ("id",  "Indonesian"),
        ("uk",  "Ukrainian"),
        ("ro",  "Romanian"),
        ("hu",  "Hungarian"),
        ("ca",  "Catalan"),
    ]

    /// The HuggingFace repo that hosts WhisperKit CoreML models.
    private static let modelRepo = "argmaxinc/whisperkit-coreml"

    /// The default model bundled with the app (no download needed).
    static let bundledModelName = "small.en"

    /// Whether a model is currently loaded and ready for transcription.
    var isReady: Bool {
        whisperKit != nil
    }

    // MARK: - Model Management

    /// Resolve a user-friendly model name to the WhisperKit model identifier.
    /// WhisperKit expects names like "openai_whisper-large-v3_turbo" on HuggingFace.
    private func resolveModelName(_ shortName: String) -> [String] {
        // Return candidate names to try, in order of preference
        var candidates = [shortName]

        // WhisperKit models on HuggingFace use underscores, not hyphens, for the turbo suffix
        // e.g. "large-v3_turbo" not "large-v3-turbo"
        if shortName.contains("-turbo") {
            candidates.append(shortName.replacingOccurrences(of: "-turbo", with: "_turbo"))
        }

        // Also try with the full HuggingFace prefix
        for candidate in Array(candidates) {
            candidates.append("openai_whisper-\(candidate)")
        }

        return candidates
    }

    /// Check if a model is bundled inside the app's Resources folder.
    /// Returns the path to the model folder if found, nil otherwise.
    ///
    /// Note: We derive the Resources path from the executable's filesystem location
    /// rather than using Bundle.main.resourcePath, because SPM-built binaries
    /// wrapped in .app bundles don't have embedded bundle metadata — Bundle.main
    /// points to the binary itself, not the .app wrapper.
    private func bundledModelPath(for modelName: String) -> String? {
        let candidates = resolveModelName(modelName)

        // Derive the Resources/Models path from the executable location:
        //   .app/Contents/MacOS/HushType  →  .app/Contents/Resources/Models
        let executablePath = ProcessInfo.processInfo.arguments[0]
        let macOSDir = (executablePath as NSString).deletingLastPathComponent   // .app/Contents/MacOS
        let contentsDir = (macOSDir as NSString).deletingLastPathComponent       // .app/Contents
        let resourcesDir = (contentsDir as NSString).appendingPathComponent("Resources")
        let modelsDir = (resourcesDir as NSString).appendingPathComponent("Models")

        print("[TranscriptionEngine] Looking for bundled models in: \(modelsDir)")

        // Also check Bundle.main.resourcePath as a fallback (works in Xcode builds)
        var searchDirs = [modelsDir]
        if let bundlePath = Bundle.main.resourcePath {
            let bundleModelsDir = (bundlePath as NSString).appendingPathComponent("Models")
            if bundleModelsDir != modelsDir {
                searchDirs.append(bundleModelsDir)
            }
        }

        for dir in searchDirs {
            for candidate in candidates {
                let modelPath = (dir as NSString).appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: modelPath) {
                    print("[TranscriptionEngine] Found bundled model at: \(modelPath)")
                    return modelPath
                }
            }
        }

        print("[TranscriptionEngine] No bundled model found for '\(modelName)' in: \(searchDirs)")
        return nil
    }

    /// Check if a model has already been downloaded to the local WhisperKit / HuggingFace cache.
    /// Returns the path to the model folder if found, nil otherwise.
    private func cachedModelPath(for modelName: String) -> String? {
        let candidates = resolveModelName(modelName)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        // Standard HuggingFace cache locations (avoids ~/Documents which triggers a TCC permission prompt).
        // The app container paths come first so sandboxed builds find their own cached models.
        var searchDirs: [String] = []

        // App container caches directory (works in sandbox and non-sandbox)
        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            searchDirs.append(cachesDir.appendingPathComponent("huggingface/hub/models--argmaxinc--whisperkit-coreml").path)
        }

        // App container Application Support (persistent storage in sandbox)
        if let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            searchDirs.append(appSupportDir.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml").path)
        }

        // Standard non-sandboxed HuggingFace cache locations (for development builds)
        searchDirs.append((homeDir as NSString).appendingPathComponent(".cache/huggingface/hub/models--argmaxinc--whisperkit-coreml"))
        searchDirs.append((homeDir as NSString).appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml"))

        for dir in searchDirs {
            for candidate in candidates {
                let modelPath = (dir as NSString).appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: modelPath) {
                    // Verify it has actual model files (not just an empty directory)
                    let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelPath)) ?? []
                    if !contents.isEmpty {
                        print("[TranscriptionEngine] Found cached model at: \(modelPath)")
                        return modelPath
                    }
                }
            }
        }

        return nil
    }

    /// Load (or reload) the Whisper model.
    /// Checks for a bundled model first; downloads from HuggingFace if not found.
    /// Progress is reported via the `onProgress` callback.
    /// - Parameter name: Model name (e.g. "base", "small"). Uses AppSettings default if nil.
    func loadModel(name: String? = nil) async {
        let modelName = name ?? AppSettings.shared.modelSize

        guard !isLoading else {
            print("[TranscriptionEngine] Model load already in progress")
            return
        }

        isLoading = true
        print("[TranscriptionEngine] Loading model: \(modelName)…")

        // Step 1: Check for a bundled model in the app bundle
        if let bundledPath = bundledModelPath(for: modelName) {
            print("[TranscriptionEngine] Using bundled model — no download needed")
            do {
                let startTime = Date()
                whisperKit = try await WhisperKit(
                    modelFolder: bundledPath,
                    verbose: true,
                    prewarm: true
                )
                let elapsed = Date().timeIntervalSince(startTime)
                print("[TranscriptionEngine] Bundled model '\(modelName)' loaded in \(String(format: "%.1f", elapsed))s")
                loadedModelName = modelName
                isLoading = false
                await MainActor.run {
                    NotificationCenter.default.post(name: .modelDidChange, object: nil)
                }
                return
            } catch {
                print("[TranscriptionEngine] Failed to load bundled model: \(error)")
                whisperKit = nil
                // Fall through to download
            }
        }

        // Step 2: Check for a previously downloaded model in the local cache
        if let cachedPath = cachedModelPath(for: modelName) {
            print("[TranscriptionEngine] Using cached model — no download needed")
            do {
                let startTime = Date()
                whisperKit = try await WhisperKit(
                    modelFolder: cachedPath,
                    verbose: true,
                    prewarm: true
                )
                let elapsed = Date().timeIntervalSince(startTime)
                print("[TranscriptionEngine] Cached model '\(modelName)' loaded in \(String(format: "%.1f", elapsed))s")
                loadedModelName = modelName
                isLoading = false
                await MainActor.run {
                    NotificationCenter.default.post(name: .modelDidChange, object: nil)
                }
                return
            } catch {
                print("[TranscriptionEngine] Failed to load cached model: \(error)")
                whisperKit = nil
                // Fall through to download
            }
        }

        // Step 3: Download from HuggingFace
        print("[TranscriptionEngine] Model not found locally — downloading from HuggingFace…")

        let candidates = resolveModelName(modelName)
        var loaded = false

        for candidate in candidates {
            do {
                let startTime = Date()
                print("[TranscriptionEngine] Trying model name: '\(candidate)'")

                await MainActor.run {
                    onProgress?(0.0, "Downloading \(modelName)…")
                }

                let modelFolder = try await WhisperKit.download(
                    variant: candidate,
                    from: Self.modelRepo,
                    progressCallback: { [weak self] progress in
                        let fraction = progress.fractionCompleted
                        DispatchQueue.main.async {
                            self?.onProgress?(fraction, "Downloading \(modelName)…")
                        }
                    }
                )

                await MainActor.run {
                    onProgress?(1.0, "Loading \(modelName)…")
                }

                print("[TranscriptionEngine] Download complete, loading from: \(modelFolder.path)")

                whisperKit = try await WhisperKit(
                    modelFolder: modelFolder.path,
                    verbose: true,
                    prewarm: true
                )

                let elapsed = Date().timeIntervalSince(startTime)
                print("[TranscriptionEngine] Model '\(candidate)' loaded in \(String(format: "%.1f", elapsed))s")
                loadedModelName = modelName
                loaded = true
                break
            } catch {
                print("[TranscriptionEngine] Failed with name '\(candidate)': \(error)")
                whisperKit = nil
            }
        }

        // Step 4: Fallback if nothing worked
        if !loaded {
            print("[TranscriptionEngine] All candidates failed for '\(modelName)'")

            let fallbackName = Self.bundledModelName
            if modelName != fallbackName {
                print("[TranscriptionEngine] Falling back to '\(fallbackName)' model…")

                // Try bundled fallback first
                if let bundledPath = bundledModelPath(for: fallbackName) {
                    await MainActor.run {
                        onProgress?(1.0, "Loading \(fallbackName)…")
                    }
                    do {
                        whisperKit = try await WhisperKit(
                            modelFolder: bundledPath,
                            verbose: true,
                            prewarm: true
                        )
                        print("[TranscriptionEngine] Fallback bundled model loaded successfully")
                        loadedModelName = fallbackName
                        await MainActor.run {
                            AppSettings.shared.modelSize = fallbackName
                        }
                    } catch {
                        print("[TranscriptionEngine] Bundled fallback failed: \(error)")
                        whisperKit = nil
                        loadedModelName = nil
                    }
                } else {
                    // Download base as last resort
                    await MainActor.run {
                        onProgress?(0.0, "Downloading base…")
                    }
                    do {
                        let modelFolder = try await WhisperKit.download(
                            variant: "base",
                            from: Self.modelRepo,
                            progressCallback: { [weak self] progress in
                                DispatchQueue.main.async {
                                    self?.onProgress?(progress.fractionCompleted, "Downloading base…")
                                }
                            }
                        )
                        await MainActor.run {
                            onProgress?(1.0, "Loading base…")
                        }
                        whisperKit = try await WhisperKit(
                            modelFolder: modelFolder.path,
                            verbose: true,
                            prewarm: true
                        )
                        print("[TranscriptionEngine] Fallback model 'base' loaded successfully")
                        loadedModelName = "base"
                        await MainActor.run {
                            AppSettings.shared.modelSize = "base"
                        }
                    } catch {
                        print("[TranscriptionEngine] Fallback model also failed: \(error)")
                        whisperKit = nil
                        loadedModelName = nil
                    }
                }
            }
        }

        isLoading = false

        // Notify observers that the model has changed
        await MainActor.run {
            NotificationCenter.default.post(name: .modelDidChange, object: nil)
        }
    }

    // MARK: - Transcription

    /// Transcribe an array of 16kHz mono Float32 audio samples to text.
    /// - Parameter samples: Audio samples at 16kHz sample rate.
    /// - Returns: The transcribed text string.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let whisperKit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        guard !samples.isEmpty else {
            throw TranscriptionError.noAudioData
        }

        let durationSeconds = Float(samples.count) / 16000.0
        print("[TranscriptionEngine] Transcribing \(String(format: "%.1f", durationSeconds))s of audio…")

        // Configure decoding options — tuned for accuracy
        // sampleLength must match the model's decoder capacity:
        //   - 448 for full large-v3 and medium models
        //   - 224 for everything else (tiny, base, small, and large-v3-turbo)
        // The turbo model is distilled with a reduced decoder (4 layers vs 32)
        // so it uses the smaller token context despite being "large"
        let currentModel = AppSettings.shared.modelSize
        let isFullLargeOrMedium = (currentModel.hasPrefix("large") || currentModel.hasPrefix("medium"))
            && !currentModel.contains("turbo")
        let maxTokens = isFullLargeOrMedium ? 448 : 224

        // Language setting: nil means auto-detect, otherwise an ISO 639-1 code (e.g. "en", "fr")
        let language = AppSettings.shared.language
        if let lang = language {
            print("[TranscriptionEngine] Language: \(lang)")
        } else {
            print("[TranscriptionEngine] Language: auto-detect")
        }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,             // nil = auto-detect, or explicit ISO 639-1 code
            temperature: 0.0,              // Greedy decoding for best accuracy
            temperatureFallbackCount: 5,    // More retries at higher temps for difficult audio
            sampleLength: maxTokens,        // Adapt to model capacity
            usePrefillPrompt: true,
            usePrefillCache: true,
            suppressBlank: true,
            supressTokens: nil,
            compressionRatioThreshold: 2.0, // Stricter — reject repetitive/low-quality output sooner
            logProbThreshold: -0.7,         // Stricter — require higher confidence from the model
            firstTokenLogProbThreshold: -1.0, // Stricter first-token threshold
            noSpeechThreshold: 0.5          // Lower — more sensitive to actual speech vs silence
        )

        // Run transcription
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        // Log each result for debugging
        for (i, result) in results.enumerated() {
            print("[TranscriptionEngine] Result \(i): \"\(result.text)\"")
        }

        // WhisperKit can return multiple results when temperature fallback
        // is enabled — the first is a rough draft, later ones are refined
        // with better punctuation. Always use the LAST (best) result.
        let fullText = results.last?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        print("[TranscriptionEngine] Using final result: \"\(fullText)\"")

        return fullText
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case noAudioData

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model not loaded. Please wait for it to download and initialize."
        case .noAudioData:
            return "No audio data to transcribe."
        }
    }
}

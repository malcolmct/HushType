import AVFoundation

/// Captures microphone audio via AVAudioEngine and converts it to 16kHz mono Float32
/// samples suitable for WhisperKit transcription.
class AudioManager {

    // MARK: - Properties

    private let audioEngine = AVAudioEngine()
    private var sampleBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "net.hushtype.audiobuffer")

    /// Callback fired with the current RMS audio level (0.0–1.0) during recording.
    var onAudioLevel: ((Float) -> Void)?

    /// Whether the audio engine is currently capturing.
    private(set) var isRecording = false

    // MARK: - Recording

    /// Start capturing audio from the default microphone.
    /// Samples are accumulated in an internal buffer until `stopRecording()` is called.
    func startRecording() throws {
        guard !isRecording else { return }

        // Clear previous buffer
        bufferQueue.sync { sampleBuffer.removeAll() }

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        print("[AudioManager] Input format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount) channels")

        // Create the target format WhisperKit expects: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioManagerError.formatCreationFailed
        }

        // Create a converter from the native mic format to 16kHz mono
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw AudioManagerError.converterCreationFailed
        }

        // Install a tap on the input node to receive audio buffers
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Calculate audio level for the UI
            let level = self.calculateRMSLevel(buffer: buffer)
            DispatchQueue.main.async {
                self.onAudioLevel?(level)
            }

            // Convert to 16kHz mono Float32
            let convertedSamples = self.convertBuffer(buffer, converter: converter, targetFormat: targetFormat)

            // Append to our sample buffer
            self.bufferQueue.sync {
                self.sampleBuffer.append(contentsOf: convertedSamples)
            }
        }

        try audioEngine.start()
        isRecording = true
    }

    /// Return a snapshot of the current sample buffer without stopping recording.
    /// Used by real-time transcription to periodically transcribe accumulated audio
    /// while the user is still speaking.
    func getCurrentSamples() -> [Float] {
        var snapshot: [Float] = []
        bufferQueue.sync {
            snapshot = sampleBuffer
        }
        return snapshot
    }

    /// Stop recording and return all captured samples as 16kHz mono Float32.
    @discardableResult
    func stopRecording() -> [Float] {
        guard isRecording else { return [] }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false
        onAudioLevel = nil

        var result: [Float] = []
        bufferQueue.sync {
            result = sampleBuffer
            sampleBuffer.removeAll()
        }

        let duration = Float(result.count) / 16000.0
        print("[AudioManager] Captured \(String(format: "%.1f", duration))s of audio (\(result.count) samples)")

        return result
    }

    // MARK: - Audio Level Monitoring

    /// Returns a list of available audio input devices using AVCaptureDevice discovery.
    var availableInputDevices: [(name: String, id: String)] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices.map { ($0.localizedName, $0.uniqueID) }
    }

    // MARK: - Private Helpers

    /// Convert an audio buffer from the native format to 16kHz mono Float32.
    private func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> [Float] {
        // Calculate output frame count based on sample rate ratio
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard outputFrameCount > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount)
        else {
            return []
        }

        var error: NSError?
        var hasData = true

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                outStatus.pointee = .haveData
                hasData = false
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if let error = error {
            print("[AudioManager] Conversion error: \(error)")
            return []
        }

        // Extract Float32 samples from the output buffer
        guard let channelData = outputBuffer.floatChannelData else { return [] }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))

        return samples
    }

    /// Calculate the RMS (root mean square) audio level from a buffer.
    private func calculateRMSLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        let samples = channelData[0]
        for i in 0..<frameLength {
            let sample = samples[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))

        // Normalize to 0–1 range (typical mic RMS is 0–0.5)
        return min(rms * 3.0, 1.0)
    }
}

// MARK: - Errors

enum AudioManagerError: LocalizedError {
    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create 16kHz audio format"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        }
    }
}

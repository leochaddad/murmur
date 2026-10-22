import AVFoundation
import AudioToolbox
import CoreAudio

struct RecordedAudio {
    let url: URL
    let duration: TimeInterval
    /// Loudest RMS level seen during the recording, in dBFS. Used to skip silent recordings.
    let peakLevel: Float

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum RecorderError: LocalizedError {
    case noInputDevice
    case cannotCreateConverter
    case engine(Error)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .cannotCreateConverter: "The microphone’s audio format isn’t supported."
        case .engine(let error): "The microphone couldn’t start: \(error.localizedDescription)"
        }
    }
}

/// Records from the chosen microphone with AVAudioEngine. Audio is converted to 16 kHz mono
/// (what speech models use) and encoded as AAC into a temporary .m4a file — about 240 KB per
/// minute, so uploads are quick. A fresh engine is created per recording, which keeps device
/// switching (AirPods connecting, a USB mic unplugged) from leaving stale state behind.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// Normalized 0…1 input level, delivered on the main queue ~30 times per second.
    var onLevel: ((Float) -> Void)?
    /// Converted audio, delivered on the audio thread (the streaming-transcription seam).
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// The input device disappeared or changed mid-recording; delivered on the main queue.
    var onInterruption: (() -> Void)?

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var sink: Sink?

    var isRunning: Bool { engine != nil }

    /// Starts capturing. When `writeToFile` is false only levels are produced (microphone test).
    func start(deviceUID: String?, writeToFile: Bool = true) throws {
        cancel()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID, let device = AudioDevices.device(withUID: deviceUID) {
            Self.select(device.id, on: input)
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noInputDevice }

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { throw RecorderError.cannotCreateConverter }
        converter.downmix = true

        var file: AVAudioFile?
        var url: URL?
        if writeToFile {
            let fileURL = AppPaths.recordingsDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            do {
                file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                throw RecorderError.engine(error)
            }
            url = fileURL
        }

        let sink = Sink(converter: converter, outputFormat: outputFormat, file: file, url: url)
        lock.withLock { self.sink = sink }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { self.sink = nil }
            if let url { try? FileManager.default.removeItem(at: url) }
            throw RecorderError.engine(error)
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Log.audio.notice("Audio configuration changed during recording")
            self?.onInterruption?()
        }
        self.engine = engine
        Log.audio.info("Recording started at \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
    }

    /// Stops capturing and finalizes the file.
    func stop() -> RecordedAudio? {
        guard let sink = tearDown() else { return nil }
        sink.close()
        guard let url = sink.url else { return nil }
        let duration = Double(sink.framesWritten) / Self.sampleRate
        if sink.failed {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return RecordedAudio(url: url, duration: duration, peakLevel: sink.peakDecibels)
    }

    /// Stops capturing and throws the recording away.
    func cancel() {
        guard let sink = tearDown() else { return }
        sink.close()
        if let url = sink.url { try? FileManager.default.removeItem(at: url) }
    }

    private func tearDown() -> Sink? {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        return lock.withLock {
            let sink = self.sink
            self.sink = nil
            return sink
        }
    }

    // MARK: Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let sink, let converted = sink.convert(buffer) else { return }

        sink.write(converted)
        onBuffer?(converted)

        let level = Self.rmsDecibels(converted)
        sink.peakDecibels = max(sink.peakDecibels, level)
        let now = CACurrentMediaTime()
        if now - sink.lastLevelUpdate > 1.0 / 30 {
            sink.lastLevelUpdate = now
            let normalized = max(0, min(1, (level + 55) / 50))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(normalized) }
        }
    }

    private static func rmsDecibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return rms > 0 ? 20 * log10(rms) : -160
    }

    /// Points the engine's input unit (an AUHAL) at a specific device instead of the system default.
    private static func select(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Log.audio.error("Selecting input device failed (\(status)); using the system default")
        }
    }

    /// Conversion and file state, only touched under `lock` on the audio thread (or after teardown).
    private final class Sink {
        let converter: AVAudioConverter
        let outputFormat: AVAudioFormat
        var file: AVAudioFile?
        let url: URL?
        var framesWritten: AVAudioFramePosition = 0
        var peakDecibels: Float = -160
        var lastLevelUpdate: CFTimeInterval = 0
        var failed = false

        init(converter: AVAudioConverter, outputFormat: AVAudioFormat, file: AVAudioFile?, url: URL?) {
            self.converter = converter
            self.outputFormat = outputFormat
            self.file = file
            self.url = url
        }

        func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, output.frameLength > 0 else { return nil }
            return output
        }

        func write(_ buffer: AVAudioPCMBuffer) {
            guard let file, !failed else { return }
            do {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
            } catch {
                failed = true
                Log.audio.error("Writing audio failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// Releasing the AVAudioFile finalizes the AAC container.
        func close() {
            if #available(macOS 15.0, *) { file?.close() }
            file = nil
        }
    }
}

import AVFoundation
import XCTest
@testable import Murmur

final class AudioRecorderTests: XCTestCase {
    /// Records one second from the default microphone and checks the encoded file.
    func testRecordsSixteenKilohertzMonoAAC() throws {
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Microphone access not granted")
        try XCTSkipIf(AudioDevices.defaultInputDevice() == nil, "No input device")

        let recorder = AudioRecorder()
        var levels: [Float] = []
        recorder.onLevel = { levels.append($0) }
        try recorder.start(deviceUID: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let audio = try XCTUnwrap(recorder.stop())
        defer { audio.delete() }

        XCTAssertEqual(audio.duration, 1.2, accuracy: 0.35)
        XCTAssertFalse(levels.isEmpty, "Level callbacks should arrive on the main queue")

        let file = try AVAudioFile(forReading: audio.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        let size = try FileManager.default.attributesOfItem(atPath: audio.url.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 20_000, "About 4 KB per second expected")
    }

    func testCancelDeletesTheFile() throws {
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Microphone access not granted")
        let before = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.recordingsDirectory.path)) ?? []
        let recorder = AudioRecorder()
        try recorder.start(deviceUID: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        recorder.cancel()
        let after = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.recordingsDirectory.path)) ?? []
        XCTAssertEqual(Set(after), Set(before))
    }
}

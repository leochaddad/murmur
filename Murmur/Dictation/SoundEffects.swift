import AppKit

/// Short, quiet system sounds marking the start and end of a recording — useful feedback for
/// push-to-talk when your eyes are on the text, not the screen.
@MainActor
enum SoundEffects {
    private static let start = sound("Tink", volume: 0.35)
    private static let stop = sound("Pop", volume: 0.3)
    private static let failure = sound("Basso", volume: 0.25)

    static func playStart() { play(start) }
    static func playStop() { play(stop) }
    static func playFailure() { play(failure) }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }

    private static func sound(_ name: String, volume: Float) -> NSSound? {
        let sound = NSSound(named: NSSound.Name(name))
        sound?.volume = volume
        return sound
    }
}

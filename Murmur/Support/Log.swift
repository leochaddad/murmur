import Foundation
import os

/// Unified logging. Never log API keys, and keep dictated text out of the logs —
/// only metadata such as durations, models and error types.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Murmur"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let openAI = Logger(subsystem: subsystem, category: "openai")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let insertion = Logger(subsystem: subsystem, category: "insertion")
}

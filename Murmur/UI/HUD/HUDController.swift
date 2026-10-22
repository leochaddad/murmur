import AppKit
import ApplicationServices
import Observation
import SwiftUI

struct HUDAction: Identifiable {
    let id = UUID()
    let title: String
    let isPrimary: Bool
    let perform: () -> Void

    init(_ title: String, isPrimary: Bool = false, perform: @escaping () -> Void) {
        self.title = title
        self.isPrimary = isPrimary
        self.perform = perform
    }
}

struct HUDMessage: Identifiable {
    enum Style { case info, warning, error }

    let id = UUID()
    var style: Style
    var title: String
    var detail: String?
    var actions: [HUDAction] = []
    var duration: TimeInterval = 6
}

@MainActor
@Observable
final class HUDModel {
    var message: HUDMessage?
}

/// The small floating indicator at the bottom of the screen. It lives in a non-activating
/// panel, so showing it — or clicking its buttons — never takes focus away from the app you
/// are dictating into.
@MainActor
final class HUDController {
    let model = HUDModel()

    private let panel: HUDPanel
    private let dictation: DictationController
    private let modes: ModeStore
    private let preferences: Preferences
    private var dismissTask: Task<Void, Never>?
    private var modeMenu: NSMenu?
    private var isVisible = false
    private var wasRecording = false

    private static let canvasSize = NSSize(width: 560, height: 150)

    init(dictation: DictationController, modes: ModeStore, preferences: Preferences) {
        self.dictation = dictation
        self.modes = modes
        self.preferences = preferences
        panel = HUDPanel(contentRect: NSRect(origin: .zero, size: Self.canvasSize))

        let root = HUDView(
            dictation: dictation, model: model,
            dismiss: { [weak self] in self?.dismissMessage() },
            showModeMenu: { [weak self] in self?.showModeMenu() }
        )
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.canvasSize)
        panel.contentView = hosting
    }

    func show(_ message: HUDMessage) {
        model.message = message
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(message.duration))
            guard !Task.isCancelled else { return }
            self?.dismissMessage()
        }
        update()
    }

    func dismissMessage() {
        dismissTask?.cancel()
        model.message = nil
        update()
    }

    /// Shows or hides the panel to match the current dictation phase and message.
    func update() {
        let showsActivity = preferences.showOverlay && dictation.phase != .idle
        let shouldShow = showsActivity || model.message != nil
        // Clickable only while there is something to click: the Mode switcher or message buttons.
        panel.ignoresMouseEvents = !dictation.isRecording && (model.message?.actions.isEmpty ?? true)
        if !dictation.isRecording { modeMenu?.cancelTracking() }
        let recordingStarted = dictation.isRecording && !wasRecording
        wasRecording = dictation.isRecording

        if shouldShow, isVisible, recordingStarted {
            // Still showing the previous dictation: follow the user to where they are now.
            position()
        } else if shouldShow, !isVisible {
            isVisible = true
            position()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else if !shouldShow, isVisible {
            isVisible = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isVisible else { return }
                    self.panel.orderOut(nil)
                }
            })
        }
    }

    /// Pops up the enabled Modes with the recording's Mode under the pointer, like a pop-up button.
    private func showModeMenu() {
        guard dictation.isRecording, let view = panel.contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var current: NSMenuItem?
        for mode in modes.enabledModes {
            let item = ClosureMenuItem(title: mode.name) { [weak self] in self?.dictation.switchRecordingMode(to: mode.id) }
            if mode.id == dictation.recordingMode.id {
                item.state = .on
                current = item
            }
            menu.addItem(item)
        }
        let location = NSApp.currentEvent.flatMap { $0.window === panel ? view.convert($0.locationInWindow, from: nil) : nil }
            ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        modeMenu = menu
        menu.popUp(positioning: current, at: location, in: view)
        modeMenu = nil
    }

    /// Bottom center of the screen the user is working on.
    private func position() {
        let screen = ActiveScreen.current() ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - Self.canvasSize.width / 2, y: frame.minY + 12)
        panel.setFrame(NSRect(origin: origin, size: Self.canvasSize), display: false)
    }
}

/// Finds the screen the user is working on: the one showing the frontmost app's focused
/// window (where the dictated text goes), or else the one under the pointer.
/// `NSScreen.main` doesn't work for this: while Murmur is in the background it follows
/// Murmur's own windows and the menu bar, not the app you're typing in.
enum ActiveScreen {
    static func current() -> NSScreen? {
        let screens = NSScreen.screens
        if let window = focusedWindowFrame(), let index = bestMatch(for: window, in: screens.map(\.frame)) {
            return screens[index]
        }
        let pointer = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(pointer, $0.frame, false) }
    }

    /// The index of the screen that shows the largest part of `window`.
    static func bestMatch(for window: NSRect, in screens: [NSRect]) -> Int? {
        let areas = screens.map { screen -> CGFloat in
            let overlap = screen.intersection(window)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        return best
    }

    /// Converts an Accessibility frame (origin at the top left of the primary screen, y down)
    /// to AppKit's global coordinates (origin at the bottom left, y up).
    static func appKitFrame(fromAccessibility origin: CGPoint, size: CGSize, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(x: origin.x, y: primaryScreenHeight - origin.y - size.height, width: size.width, height: size.height)
    }

    private static func focusedWindowFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication, let primary = NSScreen.screens.first else { return nil }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return NSApp.keyWindow?.frame
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Placement must never stall the indicator behind an app that is slow to answer.
        AXUIElementSetMessagingTimeout(element, 0.1)
        var window: CFTypeRef?
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let windowElement = window as! AXUIElement
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &size) == .success,
              let position, CFGetTypeID(position) == AXValueGetTypeID(),
              let size, CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return appKitFrame(fromAccessibility: origin, size: extent, primaryScreenHeight: primary.frame.height)
    }
}

final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        // Visible on every Space, including other apps' full-screen Spaces.
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets HUD buttons respond to the first click even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

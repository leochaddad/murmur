import AppKit

/// Menu bar glyphs, drawn as template images so they follow the menu bar's light/dark appearance.
/// The idle glyph is Murmur's mark: sound bars ending in a text cursor.
enum StatusIcon {
    private static let size = NSSize(width: 20, height: 16)

    static let idle = makeImage { _ in
        drawMark(heights: [0.55, 0.9, 0.4], in: NSRect(origin: .zero, size: size))
    }

    /// Live input level while recording: bars knocked out of a solid pill.
    static func listening(levels: [Float]) -> NSImage {
        makeImage { context in
            let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()
            context.setBlendMode(.clear)
            let recent = Array(levels.suffix(5))
            let heights = (0..<5).map { index -> CGFloat in
                let level = index < recent.count ? CGFloat(recent[index]) : 0
                return 0.18 + 0.82 * level
            }
            drawBars(heights: heights, in: rect.insetBy(dx: 3.5, dy: 3), barWidth: 2)
        }
    }

    /// A travelling wave while transcribing or running a Mode.
    static func processing(phase: Double) -> NSImage {
        makeImage { _ in
            let heights = (0..<5).map { index -> CGFloat in
                0.3 + 0.7 * CGFloat((sin(phase - Double(index) * 0.9) + 1) / 2)
            }
            drawBars(heights: heights, in: NSRect(origin: .zero, size: size).insetBy(dx: 2, dy: 1), barWidth: 2.2)
        }
    }

    private static func makeImage(_ draw: @escaping (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.setFill()
            draw(context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Murmur"
        return image
    }

    private static func drawBars(heights: [CGFloat], in rect: NSRect, barWidth: CGFloat) {
        let spacing = (rect.width - barWidth * CGFloat(heights.count)) / CGFloat(max(1, heights.count - 1))
        for (index, fraction) in heights.enumerated() {
            let height = max(barWidth, rect.height * fraction)
            let bar = NSRect(
                x: rect.minX + CGFloat(index) * (barWidth + spacing),
                y: rect.midY - height / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    /// Three sound bars followed by an I-beam text cursor.
    private static func drawMark(heights: [CGFloat], in rect: NSRect) {
        let barWidth: CGFloat = 2.3
        let spacing: CGFloat = 2.1
        let bars = rect.insetBy(dx: 1.5, dy: 1.5)
        for (index, fraction) in heights.enumerated() {
            let height = bars.height * fraction
            let bar = NSRect(x: bars.minX + CGFloat(index) * (barWidth + spacing), y: bars.midY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        // I-beam
        let x = bars.minX + CGFloat(heights.count) * (barWidth + spacing) + 2.4
        let stem = NSRect(x: x, y: bars.minY, width: 1.8, height: bars.height)
        NSBezierPath(roundedRect: stem, xRadius: 0.9, yRadius: 0.9).fill()
        let serifWidth: CGFloat = 6
        for y in [bars.minY, bars.maxY - 1.6] {
            let serif = NSRect(x: stem.midX - serifWidth / 2, y: y, width: serifWidth, height: 1.6)
            NSBezierPath(roundedRect: serif, xRadius: 0.8, yRadius: 0.8).fill()
        }
    }
}

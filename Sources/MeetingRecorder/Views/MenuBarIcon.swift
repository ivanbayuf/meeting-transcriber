import AppKit

/// The menu-bar glyph — Ivan's mic SVG, drawn in code:
/// capsule, holder arc, stand + base, and a filled "recording" dot top-right.
///
/// ```svg
/// <svg viewBox="0 0 32 32" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
///   <rect x="11" y="4" width="10" height="16" rx="5"/>
///   <path d="M7.5 15v1a8.5 8.5 0 0 0 17 0v-1M16 24.5v4M12 28.5h8"/>
///   <circle cx="24.5" cy="6" r="2.5" fill="#000" stroke="none"/>
/// </svg>
/// ```
///
/// Coordinates below are the SVG's (viewBox 0 0 32 32, y-down), drawn into a
/// flipped 18×18 template image scaled by 18/32. `nonisolated` keeps the
/// drawing handler free of actor isolation — AppKit may call it on any redraw.
enum MenuBarIcon {
    nonisolated static let pointSize: CGFloat = 18
    /// Final on-screen stroke. The SVG's 2/32 scales to 1.125pt, which reads thin
    /// in a crowded menu bar; 1.4pt matches SF Symbols' regular weight.
    nonisolated static let strokeWidth: CGFloat = 1.4

    nonisolated static func make() -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: true) { _ in
            // item 31: shift the glyph up ~1pt optically. The canvas is flipped
            // (y-down = y-up on screen), so a downward SVG-space translation
            // moves the drawn result upward on screen.
            // 1pt screen ÷ (18/32) scale ≈ 1.78 SVG units → round to 1.8.
            var shiftDown = AffineTransform(translationByX: 0, byY: 1.8)
            let scale = AffineTransform(scale: pointSize / 32)

            let stroke = strokedPath()
            stroke.transform(using: shiftDown)
            stroke.transform(using: scale)
            stroke.lineWidth = strokeWidth
            stroke.lineCapStyle = .round
            stroke.lineJoinStyle = .round
            NSColor.black.setStroke()
            stroke.stroke()

            let dot = recordingDot()
            dot.transform(using: shiftDown)
            dot.transform(using: scale)
            NSColor.black.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MeetingRecorder"
        return image
    }

    /// Capsule, holder and stand, in SVG units.
    private nonisolated static func strokedPath() -> NSBezierPath {
        // <rect x="11" y="4" width="10" height="16" rx="5"/> — mic capsule
        let path = NSBezierPath(roundedRect: NSRect(x: 11, y: 4, width: 10, height: 16),
                                xRadius: 5, yRadius: 5)

        // M7.5 15 v1 a8.5 8.5 0 0 0 17 0 v-1 — holder: down, half-circle under
        // the capsule (centre 16,16; sweep 0 in y-down = through the bottom), up.
        // The r=8.5 half-circle as two quarter cubics; k = 0.5523 × 8.5.
        let k: CGFloat = 4.694
        path.move(to: NSPoint(x: 7.5, y: 15))
        path.line(to: NSPoint(x: 7.5, y: 16))
        path.curve(to: NSPoint(x: 16, y: 24.5),
                   controlPoint1: NSPoint(x: 7.5, y: 16 + k),
                   controlPoint2: NSPoint(x: 16 - k, y: 24.5))
        path.curve(to: NSPoint(x: 24.5, y: 16),
                   controlPoint1: NSPoint(x: 16 + k, y: 24.5),
                   controlPoint2: NSPoint(x: 24.5, y: 16 + k))
        path.line(to: NSPoint(x: 24.5, y: 15))

        // M16 24.5 v4 — stand;  M12 28.5 h8 — base
        path.move(to: NSPoint(x: 16, y: 24.5))
        path.line(to: NSPoint(x: 16, y: 28.5))
        path.move(to: NSPoint(x: 12, y: 28.5))
        path.line(to: NSPoint(x: 20, y: 28.5))

        return path
    }

    /// <circle cx="24.5" cy="6" r="2.5" fill="#000" stroke="none"/> — the accent dot.
    private nonisolated static func recordingDot() -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: 24.5 - 2.5, y: 6 - 2.5, width: 5, height: 5))
    }
}

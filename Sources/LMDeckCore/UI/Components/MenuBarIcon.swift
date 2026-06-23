import AppKit

// Menu-bar glyph: the hexagon "node" mark as a monochrome template image so macOS tints it for
// light/dark + highlight. The center dot signals the server is running; `stopped` is the same
// hexagon with the dot removed, so the menu bar shows at a glance whether LMDeck is serving.
enum MenuBarIcon {
    static let running: NSImage = make(dot: true)
    static let stopped: NSImage = make(dot: false)

    private static func make(dot: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let cx = rect.midX, cy = rect.midY
            // pointy-top hexagon (~14pt tall), vertices relative to center
            let v: [(CGFloat, CGFloat)] = [
                (0, 7), (5.96, 3.63), (5.96, -3.63), (0, -7), (-5.96, -3.63), (-5.96, 3.63)
            ]
            let hex = NSBezierPath()
            hex.lineJoinStyle = .round
            hex.lineWidth = 1.5
            for (i, p) in v.enumerated() {
                let pt = NSPoint(x: cx + p.0, y: cy + p.1)
                if i == 0 { hex.move(to: pt) } else { hex.line(to: pt) }
            }
            hex.close()
            NSColor.black.setStroke()
            hex.stroke()

            if dot {
                let r: CGFloat = 1.5
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

import AppKit

/// Renders the menu-bar icon: a base symbol plus a small letter badge (R/G/D) in the
/// top-right corner. Two color states only, per spec:
///   - gray, flat, when neither System Proxy nor TUN is active
///   - adaptive black/white template icon when either is active
enum IconRenderer {
    static func makeIcon(mode: OutboundMode, active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()

        // Base symbol: simple circle/shield stand-in. Swap for a custom asset if desired.
        let baseColor: NSColor = active ? .labelColor : .disabledControlTextColor
        let basePath = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12))
        baseColor.setFill()
        basePath.fill()

        // Badge circle, top-right.
        let badgeRect = NSRect(x: 10, y: 10, width: 8, height: 8)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: -0.5, dy: -0.5)).fill() // halo so letter reads clearly
        baseColor.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        let letter = mode.badgeLetter as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6, weight: .bold),
            .foregroundColor: NSColor.controlBackgroundColor
        ]
        let letterSize = letter.size(withAttributes: attrs)
        let letterOrigin = NSPoint(
            x: badgeRect.midX - letterSize.width / 2,
            y: badgeRect.midY - letterSize.height / 2
        )
        letter.draw(at: letterOrigin, withAttributes: attrs)

        image.unlockFocus()

        // Only template-ize (auto black/white, appearance-adaptive) when active.
        // When inactive we want the flat gray rendering to stick, so isTemplate stays false.
        image.isTemplate = active
        return image
    }
}

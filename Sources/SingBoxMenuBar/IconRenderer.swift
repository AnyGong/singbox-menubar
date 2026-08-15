import AppKit

/// Renders the menu-bar icon as an SF Symbol with the outbound-mode letter
/// (R/G/D) drawn *beside* it rather than overlaid as a tiny corner badge — at
/// actual menu bar scale the old badge was unreadable, and gray-vs-template
/// wasn't a clear enough active/inactive signal. See requirements doc: "Menu bar
/// icon and mode letter are hard to read".
///
///   - Inactive (System Proxy and TUN both off): line-style `bolt.slash`, ~40%
///     opacity, no letter — legible-but-subdued at a glance, in both light and
///     dark menu bars.
///   - Active: filled `bolt.fill` at full opacity, plus the bold monospaced
///     mode letter immediately to its right.
///
/// Both states render as AppKit "template" images (`isTemplate = true`), so the
/// system handles color adaptation itself — only the alpha channel we draw
/// matters; the actual RGB values used while composing are irrelevant.
enum IconRenderer {
    private static let symbolPointSize: CGFloat = 15
    private static let letterPointSize: CGFloat = 11.5
    private static let letterBaselineOffset: CGFloat = 1.25
    private static let iconLetterSpacing: CGFloat = 2
    private static let inactiveOpacity: CGFloat = 0.4

    static func makeIcon(mode: OutboundMode, active: Bool) -> NSImage {
        let symbolName = active ? "bolt.fill" : "bolt.slash"
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: active ? .semibold : .regular)

        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: active ? "sing-box active" : "sing-box inactive")?
            .withSymbolConfiguration(symbolConfig) else {
            // SF Symbols should always resolve on macOS 13+ (this app's deployment
            // target), but don't crash the menu bar over an icon if one ever doesn't.
            return fallbackIcon()
        }
        // Draw it literally below rather than relying on its own template
        // rendering mid-composition — only the *final* image is marked template,
        // once, so there's exactly one place color adaptation happens.
        symbol.isTemplate = false

        guard active else {
            return dimmed(symbol, to: inactiveOpacity)
        }

        return composeWithLetter(symbol, letter: mode.badgeLetter)
    }

    /// Symbol + letter side by side, sized to fit both at full opacity, then
    /// marked template as one unit so they adapt to the menu bar together.
    private static func composeWithLetter(_ symbol: NSImage, letter: String) -> NSImage {
        let letterAttrs: [NSAttributedString.Key: Any] = [
            // Monospaced so the composed width — and hence the status item's
            // width — doesn't jitter as the mode (and thus letter) changes.
            .font: NSFont.monospacedSystemFont(ofSize: letterPointSize, weight: .heavy),
            .foregroundColor: NSColor.black // alpha-only once isTemplate is set below; color is irrelevant
        ]
        let letterString = letter as NSString
        let letterSize = letterString.size(withAttributes: letterAttrs)
        let symbolSize = symbol.size

        let canvasSize = NSSize(
            width: symbolSize.width + iconLetterSpacing + letterSize.width,
            height: max(symbolSize.height, letterSize.height)
        )

        let composed = NSImage(size: canvasSize)
        composed.lockFocus()

        symbol.draw(
            at: NSPoint(x: 0, y: (canvasSize.height - symbolSize.height) / 2),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )

        // Baseline nudge to optically center the letter against the icon rather
        // than its raw glyph bounding box, which tends to sit a touch low.
        letterString.draw(
            at: NSPoint(
                x: symbolSize.width + iconLetterSpacing,
                y: (canvasSize.height - letterSize.height) / 2 + letterBaselineOffset
            ),
            withAttributes: letterAttrs
        )

        composed.unlockFocus()
        composed.isTemplate = true
        return composed
    }

    /// Re-renders `image` at reduced alpha, then marks the result template so the
    /// system still adapts the (now-subdued) icon color to the menu bar.
    private static func dimmed(_ image: NSImage, to opacity: CGFloat) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: .zero,
            operation: .sourceOver,
            fraction: opacity
        )
        result.unlockFocus()
        result.isTemplate = true
        return result
    }

    /// Only reached if `NSImage(systemSymbolName:)` somehow fails to resolve
    /// "bolt"/"bolt.slash" — a plain filled circle, still template-rendered so it
    /// at least adapts correctly even in this unlikely fallback path.
    private static func fallbackIcon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12)).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

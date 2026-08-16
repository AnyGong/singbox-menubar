import AppKit

/// A menu item row rendered as [optional icon] + title label + a native `NSSwitch`,
/// for preferences-style toggles (e.g. "Launch at Login") where a switch reads more
/// clearly at a glance than a checkmark — matches the toggle style macOS itself
/// uses in menu extras like Control Center.
///
/// Set as an `NSMenuItem`'s `view`. Note that view-based menu items opt out of
/// AppKit's normal blue selection highlight — there's nothing to "select" here
/// (clicking anywhere in the row should flip the switch, not choose a menu
/// command), so this doesn't try to reproduce that particular highlight. It does,
/// however, draw its own subtle hover highlight (see `hoverBackground`) — the row
/// having *no* hover feedback at all was the actual gap (see requirements:
/// "Improve the visual feedback for mouse hover ... states"), not the specific
/// look of AppKit's command-selection highlight, which wouldn't make sense for a
/// row that isn't a command. This mirrors how System Settings' and Control
/// Center's own toggle rows behave: a soft highlight on hover, switch flips on click.
final class SwitchMenuItemView: NSView {
    private let iconView: NSImageView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()

    /// System-drawn selection material, shown only while the mouse is over the
    /// row — see `updateTrackingAreas`/`mouseEntered`/`mouseExited`. Using the
    /// real `.selection` material (rather than a hand-picked color) is what keeps
    /// this looking native in both light and dark menu bars and under any accent
    /// color, matching every other hover/highlight state elsewhere in this menu.
    private let hoverBackground: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .selection
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private var trackingArea: NSTrackingArea?

    /// Called on every user-driven flip, with the switch's new (requested) state.
    /// The caller is responsible for actually applying the change and calling
    /// `setOn` afterward to reflect what actually took effect — see
    /// `AppDelegate.toggleLaunchAtLogin` for why that read-back matters (the
    /// underlying `SMAppService` call can silently fail).
    var onToggle: ((Bool) -> Void)?

    /// Horizontal padding matching standard NSMenuItem text/icon insets, so the
    /// label and icon line up with ordinary (non-view) items above/below it in the
    /// same menu.
    private static let horizontalInset: CGFloat = 14
    private static let rowHeight: CGFloat = 22
    private static let hoverInset: CGFloat = 5
    private static let iconTitleSpacing: CGFloat = 6

    /// - Parameter systemSymbolName: Optional SF Symbol shown before the title,
    ///   matching every icon-bearing plain `NSMenuItem` elsewhere in this menu —
    ///   see `AppDelegate.menuIcon`. Omit for a label-only row.
    init(title: String, systemSymbolName: String? = nil, isOn: Bool) {
        if let systemSymbolName {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
            image?.isTemplate = true
            let view = NSImageView(image: image ?? NSImage())
            view.translatesAutoresizingMaskIntoConstraints = false
            iconView = view
        } else {
            iconView = nil
        }

        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.rowHeight))

        addSubview(hoverBackground)

        if let iconView {
            addSubview(iconView)
        }

        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        toggle.state = isOn ? .on : .off
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(switchFlipped)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)

        var constraints = [
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hoverInset),
            hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hoverInset),
            hoverBackground.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Keeps the switch pinned to the trailing edge without the row having
            // to know the label's width up front — matters if this is ever reused
            // for a longer title.
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12)
        ]

        if let iconView {
            constraints += [
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),

                titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconTitleSpacing),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ]
        } else {
            constraints += [
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ]
        }

        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented — SwitchMenuItemView is only ever created programmatically")
    }

    /// Updates the switch's displayed state without re-triggering `onToggle` — use
    /// this to reflect a state change that didn't originate from the switch itself
    /// (e.g. syncing after `LaunchAtLogin.setEnabled` didn't actually take, or any
    /// future external-state sync).
    func setOn(_ isOn: Bool) {
        toggle.state = isOn ? .on : .off
    }

    @objc private func switchFlipped() {
        onToggle?(toggle.state == .on)
    }

    // MARK: - Hover feedback

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverBackground.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverBackground.isHidden = true
    }
}

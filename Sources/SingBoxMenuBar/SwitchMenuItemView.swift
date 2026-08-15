import AppKit

/// A menu item row rendered as a title label + a native `NSSwitch`, for
/// preferences-style toggles (e.g. "Launch at Login") where a switch reads more
/// clearly at a glance than a checkmark — matches the toggle style macOS itself
/// uses in menu extras like Control Center.
///
/// Set as an `NSMenuItem`'s `view`. Note that view-based menu items opt out of
/// AppKit's normal blue selection highlight — there's nothing to highlight *to*
/// here (clicking anywhere in the row should flip the switch, not "select" a menu
/// command), so this deliberately doesn't try to reproduce it; hovering just shows
/// the switch itself, same as System Settings' own toggle rows.
final class SwitchMenuItemView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()

    /// Called on every user-driven flip, with the switch's new (requested) state.
    /// The caller is responsible for actually applying the change and calling
    /// `setOn` afterward to reflect what actually took effect — see
    /// `AppDelegate.toggleLaunchAtLogin` for why that read-back matters (the
    /// underlying `SMAppService` call can silently fail).
    var onToggle: ((Bool) -> Void)?

    /// Horizontal padding matching standard NSMenuItem text insets, so the label
    /// lines up with ordinary (non-view) items above/below it in the same menu.
    private static let horizontalInset: CGFloat = 14
    private static let rowHeight: CGFloat = 22

    init(title: String, isOn: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.rowHeight))

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

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Keeps the switch pinned to the trailing edge without the row having
            // to know the label's width up front — matters if this is ever reused
            // for a longer title.
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12)
        ])
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
}

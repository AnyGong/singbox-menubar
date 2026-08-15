import AppKit

let app = NSApplication.shared
// Menu-bar-only: no Dock icon, no app menu bar at the top of the screen.
// (When packaged as a proper .app, set LSUIElement = true in Info.plist instead —
// see README. This call covers the case where you run it directly via `swift run`.)
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()

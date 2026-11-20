import AppKit

signal(SIGPIPE, SIG_IGN)  // a dead helper must not take the app down on write

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

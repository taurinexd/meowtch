import AppKit

// Writing to a pipe whose reader has gone (e.g. `codex app-server` dying
// before the usage probe hands it a request) otherwise kills the app with
// SIGPIPE; ignore it so the write just fails.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

import AppKit

// Redirect storage before anything touches AppDatabase.shared, so the harness
// never writes to the real database.
if SelfTest.isEnabled {
    AppDatabase.useTemporaryDatabase()
    // No step of the self-test may depend on the network being there.
    FaviconStore.networkEnabled = false
}

// Create the NSApplication first: libghostty setup below queries NSApp, which
// is an implicitly-unwrapped optional and stays nil until this runs.
let app = NSApplication.shared

// Touching GhosttyApp.shared runs ghostty_init, which must happen before any
// other libghostty call.
_ = GhosttyApp.shared

let delegate = AppDelegate()
app.delegate = delegate
app.run()

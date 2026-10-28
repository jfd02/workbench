import AppKit

// A pane's Ghostty surface runs this binary again as its attach process. That
// has nothing to do with the app, so it branches off before any of the app is
// touched — no NSApplication, no libghostty, no database.
if AttachClient.isRequested {
    AttachClient.run()
}

// Redirect storage before anything touches AppDatabase.shared, so the harness
// never writes to the real database.
if SelfTest.isEnabled {
    AppDatabase.useTemporaryDatabase()
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

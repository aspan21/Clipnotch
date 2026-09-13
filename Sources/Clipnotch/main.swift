import AppKit

// Manual bootstrap: SwiftPM executables cannot use @main alongside main.swift,
// and an accessory app needs the activation policy set before the run loop starts.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    // NSApplication.delegate is weak; `appDelegate` stays in scope because
    // run() does not return until the app terminates.
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    application.run()
}

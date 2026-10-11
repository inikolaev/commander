import AppKit
import CommanderUI

if CommandLine.arguments.contains("--verify-bundled-resources") {
    do {
        try BundledResourceCheck.verify()
        print("Packaged shell and Ghostty resources verified")
        exit(0)
    } catch {
        fputs("Resource verification failed: \(error)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = ApplicationDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

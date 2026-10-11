import AppKit
import CommanderUI

if CommandLine.arguments.contains("--verify-bundled-resources") || CommandLine.arguments.contains("--smoke-test") {
    do {
        try BundledResourceCheck.verify()
        print("Packaged shell and Ghostty resources verified")
        if !CommandLine.arguments.contains("--smoke-test") { exit(0) }
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

import AppKit

// HushType requires Apple Silicon (M1 or later) for on-device Whisper inference.
// Check at runtime so this works even when distributed as a Universal Binary
// running under Rosetta 2 on an Intel Mac.

let app = NSApplication.shared

func isAppleSilicon() -> Bool {
    var sysinfo = utsname()
    uname(&sysinfo)
    let machine = withUnsafePointer(to: &sysinfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) {
            String(cString: $0)
        }
    }
    return machine.hasPrefix("arm64")
}

if !isAppleSilicon() {
    app.setActivationPolicy(.regular)
    let alert = NSAlert()
    alert.messageText = "HushType Requires Apple Silicon"
    alert.informativeText = "HushType uses on-device AI for speech recognition and requires a Mac with an M1 chip or later.\n\nThis Mac has an Intel processor, which is not supported."
    alert.alertStyle = .critical
    alert.addButton(withTitle: "Quit")
    alert.runModal()
    exit(1)
}

// Create and run the application
let delegate = AppDelegate()
app.delegate = delegate

// Hide dock icon — menu bar only
app.setActivationPolicy(.accessory)

app.run()

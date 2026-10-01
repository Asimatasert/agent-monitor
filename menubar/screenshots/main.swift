import AppKit
import SwiftUI

// Screenshot harness: shows the popover in a normal window per view and captures it with screencapture -l.
// Views: live quota usage kanban health (accounts) health-models health-chains
let args = Array(CommandLine.arguments.dropFirst())
let out = args.first ?? NSTemporaryDirectory()
let views = args.count > 1 ? Array(args.dropFirst()) : ["live", "quota", "health", "health-models", "health-chains", "usage", "kanban"]
Pref.register()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
MainActor.assumeIsolated {
    let store = Store()
    var win: NSWindow?
    func show(_ i: Int) {
        guard i < views.count else { NSApp.terminate(nil); return }
        let parts = views[i].split(separator: "-").map(String.init)
        UserDefaults.standard.set(parts[0], forKey: "tab")
        UserDefaults.standard.set(parts.count > 1 ? parts[1] : "accounts", forKey: "healthView")
        win?.orderOut(nil)
        let w = NSWindow(contentRect: NSRect(x: 80, y: 60, width: 430, height: 1500), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Popover(store: store))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(w.windowNumber), "\(out)/\(views[i]).png"]
            try? p.run()
            p.waitUntilExit()
            show(i + 1)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { show(0) }
}
app.run()

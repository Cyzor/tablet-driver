import AppKit

/// Minimal NSApplicationDelegate that installs the Apple Events handler on
/// launch and cleans up context state when the front application changes.
final class ShimApp: NSObject, NSApplicationDelegate {

    private var handler: WacomAppleEventHandler!
    private var workspaceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        handler = WacomAppleEventHandler()
        handler.install()

        // Remove context entries for apps that terminate.  Adobe apps send
        // kAEDelete themselves but this covers ungraceful exits.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let app = info[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.handler.removeContext(for: app.processIdentifier)
        }

        print("WacomShim: running (pid \(ProcessInfo.processInfo.processIdentifier))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }
}

import AppKit

extension AppDelegate {
    @objc func showMachineSessions(_ sender: Any? = nil) {
        machineSessionsWindowController.show(appDelegate: self)
    }
}

import Cocoa
import ApplicationServices

class AppActivationMonitor {
    static let shared = AppActivationMonitor()
    
    private var workspaceObserver: Any?
    
    private init() {}
    
    func start() {
        guard workspaceObserver == nil else { return }
        
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            
            // Check whether DockTamer's global feature is enabled
            guard DockClickMonitor.shared.isEnabled else { return }
            
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            
            // Skip our own app and background system apps
            guard app.activationPolicy == .regular else { return }
            
            // Off the main thread: apps that are slow to answer AX (e.g. System Settings) would
            // block the main run loop, which is also where the Dock event tap lives.
            DispatchQueue.global(qos: .userInitiated).async {
                self.unminimizeIfAllMinimized(app: app)
            }
        }
    }
    
    func stop() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
    }
    
    private func unminimizeIfAllMinimized(app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, DockClickMonitor.axTimeout)
        var windowsRef: CFTypeRef?
        
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement], !windows.isEmpty {
            
            var allMinimized = true
            
            for window in windows {
                var minRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
                   let isMinimized = minRef as? Bool {
                    if !isMinimized {
                        allMinimized = false
                        break
                    }
                }
            }
            
            // If it has windows and all of them are minimized, restore them
            if allMinimized {
                for window in windows {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
            }
        }
    }
}

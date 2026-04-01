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
            
            // Verificamos si la función global de DockTamer está encendida
            guard DockClickMonitor.shared.isEnabled else { return }
            
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            
            // Excluimos nuestra propia app o las del sistema background
            guard app.activationPolicy == .regular else { return }
            
            self.unminimizeIfAllMinimized(app: app)
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
            
            // Si tiene ventanas y todas están minimizadas, las restauramos
            if allMinimized {
                for window in windows {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
            }
        }
    }
}

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var toggleItem: NSMenuItem!
    var permissionItem: NSMenuItem!
    
    // Timer to check whether the user granted access in System Settings
    var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenuBar()
        checkAndRequestAccessibilityPermissions()
    }

    func setupMenuBar() {
        // VariableLength so it fits the icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // Native Apple style, with detailed dynamically generated graphics
            button.image = NSImage.macDockMenuBarIcon
        }

        menu = NSMenu()
        
        toggleItem = NSMenuItem(title: NSLocalizedString("Disable Click-to-Minimize", comment: "Menu item to turn the feature off"), action: #selector(toggleFeature), keyEquivalent: "")
        menu.addItem(toggleItem)
        
        permissionItem = NSMenuItem(title: NSLocalizedString("Permission status: Checking...", comment: "Menu item shown while checking permissions"), action: #selector(requestPermissionsManual), keyEquivalent: "")
        menu.addItem(permissionItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit", comment: "Menu item to quit the app"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        // Deferring the menu assignment avoids the "_NSDetectedLayoutRecursion" warning
        // that is common on macOS 13+ when initializing an NSStatusItem.
        DispatchQueue.main.async {
            self.statusItem.menu = self.menu
        }
    }
    
    @objc func toggleFeature() {
        DockClickMonitor.shared.isEnabled.toggle()
        toggleItem.title = DockClickMonitor.shared.isEnabled
            ? NSLocalizedString("Disable Click-to-Minimize", comment: "Menu item to turn the feature off")
            : NSLocalizedString("Enable Click-to-Minimize", comment: "Menu item to turn the feature on")
    }
    
    func checkAndRequestAccessibilityPermissions() {
        // The Prompt option shows the native system alert if permission hasn't been granted
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        
        updatePermissionUI(granted: isTrusted)
        
        if isTrusted {
            DockClickMonitor.shared.start()
            AppActivationMonitor.shared.start()
        } else {
            showPermissionAlert()
            
            // Start a polling timer to start the monitors automatically as soon as the user grants the Privacy permission
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                let granted = AXIsProcessTrusted()
                self?.updatePermissionUI(granted: granted)
                
                if granted {
                    DockClickMonitor.shared.start()
                    AppActivationMonitor.shared.start()
                    timer.invalidate()
                }
            }
        }
    }
    
    func updatePermissionUI(granted: Bool) {
        let status = granted
            ? NSLocalizedString("✅ Granted", comment: "Accessibility permission status")
            : NSLocalizedString("❌ Denied", comment: "Accessibility permission status")
        permissionItem.title = String(format: NSLocalizedString("Accessibility Permissions: %@", comment: "Menu item showing permission status"), status)
        // Once granted, the item no longer needs to be clickable
        permissionItem.action = granted ? nil : #selector(requestPermissionsManual)
    }
    
    @objc func requestPermissionsManual() {
        // Universal URL on modern macOS to open Privacy > Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Permissions Required", comment: "Permission alert title")
        alert.informativeText = NSLocalizedString("DockTamer needs Accessibility permissions to detect your clicks on the Dock and minimize windows.\n\nPlease enable them in System Settings.", comment: "Permission alert body")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Open Settings", comment: "Permission alert button"))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "Permission alert button"))
        
        // Bring the alert to the front so the user sees it, since the app has no regular window
        NSApp.activate(ignoringOtherApps: true)
        
        if alert.runModal() == .alertFirstButtonReturn {
            requestPermissionsManual()
        }
    }
}

extension NSImage {
    /// Dynamically generates a detailed menu bar icon in the style of Apple's utilities
    static var macDockMenuBarIcon: NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            
            // 1. Draw the window's outer frame (rounded rectangle)
            let windowRect = NSRect(x: 3, y: 6.5, width: 12, height: 7.5)
            let windowPath = NSBezierPath(roundedRect: windowRect, xRadius: 1.5, yRadius: 1.5)
            windowPath.lineWidth = 1.2
            windowPath.stroke()
            
            // 2. Draw the window's small title bar
            let titleBarLine = NSBezierPath()
            titleBarLine.move(to: NSPoint(x: 3, y: 11.5))
            titleBarLine.line(to: NSPoint(x: 15, y: 11.5))
            titleBarLine.lineWidth = 1.0
            titleBarLine.stroke()
            
            // 3. Draw a "button" in the title bar (mimicking the macOS traffic lights)
            let dotRect = NSRect(x: 4.5, y: 12.2, width: 1.0, height: 1.0)
            let dotPath = NSBezierPath(ovalIn: dotRect)
            dotPath.fill()
            
            // 4. Draw the Dock (thick rectangle at the bottom)
            let dockRect = NSRect(x: 4, y: 2.5, width: 10, height: 2.0)
            let dockPath = NSBezierPath(roundedRect: dockRect, xRadius: 1, yRadius: 1)
            dockPath.fill()
            
            // 5. Draw a central arrow pointing down into the Dock
            let arrowPath = NSBezierPath()
            arrowPath.lineWidth = 1.2
            arrowPath.lineCapStyle = .round
            arrowPath.lineJoinStyle = .round
            
            // Arrow shaft from the center down to the Dock
            arrowPath.move(to: NSPoint(x: 9, y: 9.5))
            arrowPath.line(to: NSPoint(x: 9, y: 5))
            
            // Arrow head
            arrowPath.move(to: NSPoint(x: 7.0, y: 6.8))
            arrowPath.line(to: NSPoint(x: 9, y: 5))
            arrowPath.line(to: NSPoint(x: 11.0, y: 6.8))
            
            arrowPath.stroke()
            
            return true
        }
        
        image.isTemplate = true
        return image
    }
}

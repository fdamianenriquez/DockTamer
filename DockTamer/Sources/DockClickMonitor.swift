import Cocoa
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.docktamer.DockTamer", category: "DockClickMonitor")

class DockClickMonitor {
    static let shared = DockClickMonitor()
    
    var isEnabled: Bool = true
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Cached system-wide Accessibility element
    private let systemWideElement = AXUIElementCreateSystemWide()
    
    // Short timeout for AX queries inside the tap callback. If the app under the cursor
    // (e.g. System Settings) is slow to respond, the default timeout (~6s) stalls the tap and macOS
    // disables it with `tapDisabledByTimeout`.
    static let hitTestTimeout: Float = 0.1
    static let axTimeout: Float = 1.0
    
    // Prevent instantiation from outside
    private init() {
        AXUIElementSetMessagingTimeout(systemWideElement, DockClickMonitor.hitTestTimeout)
    }
    
    func start() {
        guard eventTap == nil else { return }
        
        // We only care about mouse clicks (left button down)
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<DockClickMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            print("❌ Could not create the EventTap. Accessibility permissions denied?")
            return
        }
        
        // Add the click monitor to the main run loop using .commonModes (prevents system lag)
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
    
    func stop() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            self.eventTap = nil
            self.runLoopSource = nil
        }
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 0. macOS disables the tap if the callback takes too long or due to user input.
        // Without re-enabling it, DockTamer stops working until restarted.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.notice("Event tap disabled by the system (type=\(type.rawValue)), re-enabling")
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        // 1. Fast exit: is this an event we care about?
        guard isEnabled && type == .leftMouseDown else {
            return Unmanaged.passUnretained(event)
        }
        
        // 2. KEY OPTIMIZATION: we only act on the app that is already ACTIVE (frontmost).
        // If there is no frontmost app, pass the event through immediately (0% CPU cost).
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return Unmanaged.passUnretained(event)
        }
        
        let mouseLocation = event.location
        var elementUnderMouse: AXUIElement?
        
        // 3. Ask the system what is at the mouse coordinates
        let start = DispatchTime.now()
        let error = AXUIElementCopyElementAtPosition(systemWideElement, Float(mouseLocation.x), Float(mouseLocation.y), &elementUnderMouse)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        if elapsedMs > 50 {
            logger.notice("Slow AX hit-test: \(elapsedMs, format: .fixed(precision: 1)) ms (error=\(error.rawValue))")
        }
        
        guard error == .success, let element = elementUnderMouse else {
            return Unmanaged.passUnretained(event)
        }
        
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        
        // 4. Bail out quickly if it isn't the macOS Dock
        guard let clickedApp = NSRunningApplication(processIdentifier: pid),
              clickedApp.bundleIdentifier == "com.apple.dock" else {
            return Unmanaged.passUnretained(event)
        }
        
        // 5. Make sure it's an app icon
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        
        if let roleStr = roleRef as? String, roleStr == "AXDockItem" {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            
            // 6. O(1) KEY OPTIMIZATION: compare the Dock item's name directly against the frontmost app.
            // To be more robust (e.g. iTerm vs iTerm2), also check the name of the .app bundle itself.
            let appName = frontmostApp.localizedName ?? ""
            let bundleName = frontmostApp.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
            
            if let targetAppName = titleRef as? String, (targetAppName == appName || targetAppName == bundleName) {
                
                // Off the main thread so we don't block the run loop the tap lives on.
                DispatchQueue.global(qos: .userInteractive).async {
                    let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
                    AXUIElementSetMessagingTimeout(appElement, DockClickMonitor.axTimeout)
                    var windowsRef: CFTypeRef?
                    
                    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                       let windows = windowsRef as? [AXUIElement], !windows.isEmpty {
                        
                        var allMinimized = true
                        for window in windows {
                            var minRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
                               let isMinimized = minRef as? Bool, !isMinimized {
                                allMinimized = false
                                break
                            }
                        }
                        
                        let toggleValue = (allMinimized ? kCFBooleanFalse : kCFBooleanTrue)!
                        
                        var anyChanged = false
                        for window in windows {
                            if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, toggleValue) == .success {
                                anyChanged = true
                            }
                        }

                        if allMinimized {
                            DispatchQueue.main.async {
                                frontmostApp.activate(options: .activateIgnoringOtherApps)
                            }
                        } else if !anyChanged {
                            // No window could be minimized (e.g. no minimize button): hide the app
                            // so the click isn't swallowed with no effect.
                            DispatchQueue.main.async {
                                frontmostApp.hide()
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            frontmostApp.hide()
                        }
                    }
                }
                
                return nil // Swallow the original event
            }
        }
        
        return Unmanaged.passUnretained(event)
    }
}

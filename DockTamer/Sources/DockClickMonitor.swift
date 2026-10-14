import Cocoa
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.docktamer.DockTamer", category: "DockClickMonitor")

class DockClickMonitor {
    static let shared = DockClickMonitor()
    
    var isEnabled: Bool = true
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Cache del objeto global de Accesibilidad
    private let systemWideElement = AXUIElementCreateSystemWide()
    
    // Short timeout for AX queries inside the tap callback. If the app under the cursor
    // (e.g. System Settings) is slow to respond, the default timeout (~6s) stalls the tap and macOS
    // disables it with `tapDisabledByTimeout`.
    static let hitTestTimeout: Float = 0.1
    static let axTimeout: Float = 1.0
    
    // Evita la inicialización desde fuera
    private init() {
        AXUIElementSetMessagingTimeout(systemWideElement, DockClickMonitor.hitTestTimeout)
    }
    
    func start() {
        guard eventTap == nil else { return }
        
        // Nos interesan únicamente los clics de ratón (botón izquierdo hacia abajo)
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
        
        // Añadir el monitor de clics al hilo principal usando .commonModes (previene lag del sistema)
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
        
        // 1. Salida rápida: ¿Es un evento de nuestro interés?
        guard isEnabled && type == .leftMouseDown else {
            return Unmanaged.passUnretained(event)
        }
        
        // 2. SUPER OPTIMIZACIÓN: Solo nos interesa alterar la app que ya está ACTIVA (en primer plano).
        // Si no hay app en primer plano, dejamos pasar el evento inmediatamente (coste CPU 0%).
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return Unmanaged.passUnretained(event)
        }
        
        let mouseLocation = event.location
        var elementUnderMouse: AXUIElement?
        
        // 3. Consultamos el caché del sistema para ver qué hay en las coordenadas del ratón
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
        
        // 4. Descartar rápido si no es el Dock de macOS
        guard let clickedApp = NSRunningApplication(processIdentifier: pid),
              clickedApp.bundleIdentifier == "com.apple.dock" else {
            return Unmanaged.passUnretained(event)
        }
        
        // 5. Verificar que sea un icono de App
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        
        if let roleStr = roleRef as? String, roleStr == "AXDockItem" {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            
            // 6. OPTIMIZACIÓN CLAVE O(1): Comparamos el nombre del ítem del Dock directamente con la app en primer plano.
            // Para ser más robustos (ej. iTerm vs iTerm2), verificamos también el nombre del propio archivo .app.
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
                
                return nil // Traga el evento original
            }
        }
        
        return Unmanaged.passUnretained(event)
    }
}

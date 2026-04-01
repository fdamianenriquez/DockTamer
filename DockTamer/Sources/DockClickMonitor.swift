import Cocoa
import ApplicationServices

class DockClickMonitor {
    static let shared = DockClickMonitor()
    
    var isEnabled: Bool = true
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Cache del objeto global de Accesibilidad
    private let systemWideElement = AXUIElementCreateSystemWide()
    
    // Evita la inicialización desde fuera
    private init() {}
    
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
            print("❌ No se pudo crear el EventTap. ¿Permisos de Accesibilidad denegados?")
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
        let error = AXUIElementCopyElementAtPosition(systemWideElement, Float(mouseLocation.x), Float(mouseLocation.y), &elementUnderMouse)
        
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
                
                DispatchQueue.main.async {
                    let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
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
                        
                        for window in windows {
                            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, toggleValue)
                        }
                        
                        if allMinimized {
                            frontmostApp.activate(options: .activateIgnoringOtherApps)
                        }
                    } else {
                        frontmostApp.hide()
                    }
                }
                
                return nil // Traga el evento original
            }
        }
        
        return Unmanaged.passUnretained(event)
    }
}

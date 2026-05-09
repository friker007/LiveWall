import Foundation
import AppKit
import IOKit.ps

class SystemMonitor {
    static let shared = SystemMonitor()
    
    private var powerTimer: Timer?
    private var fullscreenTimer: Timer?
    
    private var lastBatteryState: Bool?
    private var lastFullscreenState: Bool?
    
    var onBatteryChanged: ((Bool) -> Void)?
    var onFullscreenChanged: ((Bool) -> Void)?
    
    func start() {
        // Power Source Monitoring (every 5 seconds)
        powerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkPowerSource()
        }
        checkPowerSource()
        
        // Fullscreen App Monitoring (every 3 seconds)
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkFullscreen()
        }
        checkFullscreen()
        
        // Global Keyboard Shortcut (Option + Cmd + P)
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Keycode 35 is 'P'
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.option, .command] && event.keyCode == 35 {
                DispatchQueue.main.async {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.engine.togglePause()
                    }
                }
            }
        }
    }
    
    private func checkPowerSource() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return }
        
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                if let type = desc[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType {
                    if let isCharging = desc[kIOPSIsChargingKey] as? Bool {
                        // If internal battery is not charging, we are on battery power
                        let onBattery = !isCharging
                        if onBattery != lastBatteryState {
                            lastBatteryState = onBattery
                            onBatteryChanged?(onBattery)
                        }
                        return
                    }
                }
            }
        }
        if lastBatteryState != false {
            lastBatteryState = false
            onBatteryChanged?(false)
        }
    }
    
    private func checkFullscreen() {
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            if lastFullscreenState != false {
                lastFullscreenState = false
                onFullscreenChanged?(false)
            }
            return
        }
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        
        // System processes that create transient fullscreen-sized windows
        // during app open/close/minimize animations
        let systemProcesses: Set<String> = [
            "Finder", "Dock", "LiveWall", "WindowManager",
            "Window Server", "SystemUIServer", "Control Center"
        ]
        
        var foundFullscreen = false
        for window in windowList {
            if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               let layer = window[kCGWindowLayer as String] as? Int, layer == 0 {
                
                let isFullscreen = rect.width >= screenFrame.width && rect.height >= screenFrame.height
                if isFullscreen {
                    if let ownerName = window[kCGWindowOwnerName as String] as? String,
                       !systemProcesses.contains(ownerName) {
                        foundFullscreen = true
                        break
                    }
                }
            }
        }
        
        if foundFullscreen && lastFullscreenState != true {
            // Debounce: confirm fullscreen is still true after a short delay
            // to avoid false positives from transient window animations
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.confirmFullscreen()
            }
        } else if !foundFullscreen && lastFullscreenState != false {
            lastFullscreenState = false
            onFullscreenChanged?(false)
        }
    }
    
    private func confirmFullscreen() {
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        
        let systemProcesses: Set<String> = [
            "Finder", "Dock", "LiveWall", "WindowManager",
            "Window Server", "SystemUIServer", "Control Center"
        ]
        
        for window in windowList {
            if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               let layer = window[kCGWindowLayer as String] as? Int, layer == 0 {
                
                let isFullscreen = rect.width >= screenFrame.width && rect.height >= screenFrame.height
                if isFullscreen {
                    if let ownerName = window[kCGWindowOwnerName as String] as? String,
                       !systemProcesses.contains(ownerName) {
                        if lastFullscreenState != true {
                            lastFullscreenState = true
                            onFullscreenChanged?(true)
                        }
                        return
                    }
                }
            }
        }
        // Animation ended — no real fullscreen app found, don't fire
    }
}

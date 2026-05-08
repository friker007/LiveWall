import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var prefsWindow: NSWindow!
    var engine: WallpaperEngine!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        engine = WallpaperEngine()
        engine.updateWallpaper()
        setupMenuBar()
        SystemMonitor.shared.start()
        NowPlayingMonitor.shared.start()
        openPreferences()
    }
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if url.pathExtension.lowercased() == "lw" {
                WallpaperManager.shared.importLWFile(url: url)
            }
        }
    }
    
    // MARK: - Menu Bar
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "play.display", accessibilityDescription: "LiveWall")
        }
        
        let menu = NSMenu()
        menu.delegate = self
        
        // Title
        let titleItem = NSMenuItem(title: "LiveWall", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        let font = NSFont.boldSystemFont(ofSize: 14)
        titleItem.attributedTitle = NSAttributedString(string: "LiveWall", attributes: [.font: font])
        menu.addItem(titleItem)
        
        // Now-playing
        let np = NSMenuItem(title: "Playing: None", action: nil, keyEquivalent: "")
        np.isEnabled = false
        np.tag = 1
        menu.addItem(np)
        menu.addItem(.separator())
        
        // Quick actions
        let sound = NSMenuItem(title: "Play Audio", action: #selector(toggleSound), keyEquivalent: "s")
        sound.tag = 2
        menu.addItem(sound)
        
        let pause = NSMenuItem(title: "Pause Wallpaper", action: #selector(togglePause), keyEquivalent: "p")
        pause.tag = 3
        menu.addItem(pause)
        
        menu.addItem(.separator())
        
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(prefs)
        
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LiveWall", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }

    // MARK: - Actions
    
    @objc func openPreferences() {
        if prefsWindow == nil {
            prefsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            prefsWindow.isReleasedWhenClosed = false
            prefsWindow.center()
            prefsWindow.setFrameAutosaveName("LiveWallPrefs")
            prefsWindow.title = "LiveWall"
            prefsWindow.isMovableByWindowBackground = true
            prefsWindow.minSize = NSSize(width: 700, height: 500)
            prefsWindow.contentView = NSHostingController(rootView: ContentView()).view
        }
        prefsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleSound() {
        WallpaperManager.shared.volume = WallpaperManager.shared.volume > 0 ? 0.0 : 1.0
    }
    @objc func togglePause() { engine.togglePause() }
    @objc func quitApp()     { NSApplication.shared.terminate(self) }
}

// MARK: - Dynamic Menu Updates

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let current = WallpaperManager.shared.currentWallpaper
        let name = current?.name ?? "None"
        let isVideo = current?.type == .video
        
        let npItem = menu.item(withTag: 1)
        npItem?.title = "Playing: \(name)"
        if current != nil {
            npItem?.image = NSImage(systemSymbolName: isVideo ? "play.circle" : "photo", accessibilityDescription: nil)
        } else {
            npItem?.image = nil
        }
        
        let isMuted = WallpaperManager.shared.volume == 0.0
        let soundItem = menu.item(withTag: 2)
        soundItem?.isEnabled = isVideo
        soundItem?.state = isMuted ? .off : .on
        soundItem?.image = NSImage(systemSymbolName: isMuted ? "speaker.slash" : "speaker.wave.2", accessibilityDescription: nil)
        
        let pauseItem = menu.item(withTag: 3)
        pauseItem?.isEnabled = isVideo
        pauseItem?.title = engine.isPaused ? "Resume Wallpaper" : "Pause Wallpaper"
        pauseItem?.image = NSImage(systemSymbolName: engine.isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

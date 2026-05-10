import AppKit
import AVKit
import Combine
import SwiftUI

// MARK: - Interactive Panel
// A borderless NSWindow subclass that accepts key/mouse events even when the
// owning application is not frontmost.  Standard borderless windows return
// false from canBecomeKey, which causes macOS to silently drop hover and click
// events when the user has another app focused.

class InteractivePanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class WallpaperEngine: ObservableObject {
    var windows: [NSWindow] = []
    var hudWindow: NSWindow?
    @Published var isPaused = false
    private var isBatteryPaused = false
    private var isFullscreenPaused = false
    private var isLowPowerPaused = false
    private var isAsleep = false
    private var isScreenLocked = false
    
    private var cancellables = Set<AnyCancellable>()
    
    // HUD mouse-tracking state
    private var hudDesktopLevel: NSWindow.Level = .init(rawValue: 0)
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var isHUDPromoted = false
    
    // Active Wallpaper Item tracking
    @Published var activeWallpaperItem: WallpaperItem?
    
    static var shared: WallpaperEngine?
    
    init() {
        Self.shared = self
        createWindow()
        bindState()
        observeScreenChanges()
        setupSystemMonitoring()
        setupHUDMouseTracking()
    }
    
    // MARK: - Window Setup
    
    private func createWindow() {
        for win in windows {
            win.close()
        }
        windows.removeAll()
        
        for screen in NSScreen.screens {
            let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            win.ignoresMouseEvents = true
            win.backgroundColor = .clear
            win.isOpaque = false
            win.contentView = NSHostingView(rootView: RootEngineView(engine: self))
            win.makeKeyAndOrderFront(nil)
            windows.append(win)
        }
        
        hudWindow?.close()
        guard let screen = NSScreen.screens.first else { return }
        let hudRect = self.hudRect(for: screen)
        let hw = InteractivePanel(contentRect: hudRect, styleMask: .borderless, backing: .buffered, defer: false)
        hudDesktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        hw.level = hudDesktopLevel
        hw.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hw.ignoresMouseEvents = true
        hw.backgroundColor = .clear
        hw.isOpaque = false
        hw.hasShadow = false
        hw.acceptsMouseMovedEvents = true
        hw.contentView = NSHostingView(rootView: RootHUDView())
        hw.orderFront(nil)
        hudWindow = hw
    }
    
    // MARK: - HUD Mouse Tracking
    //
    // Instead of relying on macOS window-level event delivery (which fails
    // for desktop-level windows of background apps), we use global+local
    // mouse monitors that fire regardless of app focus. When the cursor
    // enters the HUD frame we promote the window to .floating level and
    // enable mouse events; when it leaves we demote it back.
    
    private func setupHUDMouseTracking() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.evaluateHUDHover()
        }
        
        // Global monitor: fires when OUR app is NOT frontmost
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown],
            handler: handler
        )
        
        // Local monitor: fires when OUR app IS frontmost
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown]
        ) { [weak self] event in
            self?.evaluateHUDHover()
            return event
        }
    }
    
    private func isHUDObscured(by hudFrame: CGRect) -> Bool {
        if isFullscreenPaused {
            return true
        }
        
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [NSDictionary] else {
            return false
        }
        
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            
            if let ownerName = window[kCGWindowOwnerName as String] as? String {
                let systemProcesses: Set<String> = [
                    "Finder", "Dock", "LiveWall", "WindowManager",
                    "Window Server", "SystemUIServer", "Control Center"
                ]
                if systemProcesses.contains(ownerName) {
                    continue
                }
            }
            
            if rect.intersects(hudFrame) {
                return true
            }
        }
        return false
    }
    
    private func evaluateHUDHover() {
        guard let hudWindow = hudWindow else { return }
        let mouseLocation = NSEvent.mouseLocation  // screen coordinates
        let hudFrame = hudWindow.frame
        let isInside = hudFrame.contains(mouseLocation)
        
        // When no song is playing, the HUD is invisible — don't block clicks
        let songPlaying = NowPlayingMonitor.shared.currentSong != nil
        
        // Check if another window is covering the HUD area or if in fullscreen
        let obscured = isHUDObscured(by: hudFrame)
        
        if isInside && !isHUDPromoted && songPlaying && !obscured {
            // Promote: bring the HUD to floating level so it receives all events
            isHUDPromoted = true
            hudWindow.level = .floating
            hudWindow.ignoresMouseEvents = false
            hudWindow.orderFront(nil)
        } else if (!isInside || !songPlaying || obscured) && isHUDPromoted {
            // Demote: drop back to desktop level, stop intercepting events
            isHUDPromoted = false
            hudWindow.ignoresMouseEvents = true
            hudWindow.level = hudDesktopLevel
        }
    }
    
    // MARK: - Reactive Bindings
    
    private func bindState() {
        WallpaperManager.shared.$currentWallpaper
            .receive(on: RunLoop.main)
            .sink { [weak self] item in
                guard let item = item else { return }
                self?.isPaused = false
                self?.show(item)
            }
            .store(in: &cancellables)
            
        Publishers.CombineLatest3(
            WallpaperManager.shared.$smartPauseBattery,
            WallpaperManager.shared.$smartPauseFullscreen,
            WallpaperManager.shared.$smartPauseLowPower
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.evaluatePauseState()
        }
        .store(in: &cancellables)
        
        WallpaperManager.shared.$hudPlacement
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let screen = NSScreen.screens.first, let self = self else { return }
                self.hudWindow?.setFrame(self.hudRect(for: screen), display: true)
            }
            .store(in: &cancellables)
    }
    
    private func setupSystemMonitoring() {
        SystemMonitor.shared.onBatteryChanged = { [weak self] onBattery in
            DispatchQueue.main.async {
                self?.isBatteryPaused = onBattery
                self?.evaluatePauseState()
            }
        }
        SystemMonitor.shared.onFullscreenChanged = { [weak self] isFullscreen in
            DispatchQueue.main.async {
                self?.isFullscreenPaused = isFullscreen
                self?.evaluatePauseState()
            }
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateDidChange),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        self.isLowPowerPaused = ProcessInfo.processInfo.isLowPowerModeEnabled
        
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            self,
            selector: #selector(screensDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        dnc.addObserver(
            self,
            selector: #selector(screensDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }
    
    @objc private func powerStateDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.isLowPowerPaused = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.evaluatePauseState()
        }
    }
    
    @objc private func workspaceWillSleep() {
        DispatchQueue.main.async { [weak self] in
            self?.isAsleep = true
            self?.evaluatePauseState()
        }
    }
    
    @objc private func workspaceDidWake() {
        DispatchQueue.main.async { [weak self] in
            self?.isAsleep = false
            self?.evaluatePauseState()
        }
    }
    
    @objc private func screensDidLock() {
        DispatchQueue.main.async { [weak self] in
            self?.isScreenLocked = true
            self?.evaluatePauseState()
        }
    }
    
    @objc private func screensDidUnlock() {
        DispatchQueue.main.async { [weak self] in
            self?.isScreenLocked = false
            self?.evaluatePauseState()
        }
    }
    
    private func evaluatePauseState() {
        let batteryPauseActive = isBatteryPaused && WallpaperManager.shared.smartPauseBattery
        let fullscreenPauseActive = isFullscreenPaused && WallpaperManager.shared.smartPauseFullscreen
        let lowPowerPauseActive = isLowPowerPaused && WallpaperManager.shared.smartPauseLowPower
        let systemPauseActive = isAsleep || isScreenLocked
        isPaused = batteryPauseActive || fullscreenPauseActive || lowPowerPauseActive || systemPauseActive
    }
    
    private func observeScreenChanges() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.createWindow()
                self.updateWallpaper()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - HUD Placement Helper
    
    private func hudRect(for screen: NSScreen) -> CGRect {
        let hudWidth: CGFloat = 320
        let hudHeight: CGFloat = 260
        let margin: CGFloat = 40
        // safeAreaInsets.top accounts for the notch on MacBook screens
        let notchInset = screen.safeAreaInsets.top
        // visibleFrame excludes the Dock and menu bar;
        // comparing it to frame gives us the exact Dock insets
        let dockBottom = screen.visibleFrame.minY - screen.frame.minY  // Dock at bottom
        let dockLeft = screen.visibleFrame.minX - screen.frame.minX    // Dock on left side
        let dockRight = screen.frame.maxX - screen.visibleFrame.maxX   // Dock on right side
        
        switch WallpaperManager.shared.hudPlacement {
        case .bottomRight:
            return CGRect(
                x: screen.frame.width - hudWidth - margin - dockRight,
                y: dockBottom + margin,
                width: hudWidth,
                height: hudHeight
            )
        case .topCenter:
            return CGRect(
                x: (screen.frame.width - hudWidth) / 2,
                y: screen.frame.height - hudHeight - notchInset - 10,
                width: hudWidth,
                height: hudHeight
            )
        case .topRight:
            return CGRect(
                x: screen.frame.width - hudWidth - margin - dockRight,
                y: screen.frame.height - hudHeight - notchInset - 10,
                width: hudWidth,
                height: hudHeight
            )
        case .bottomLeft:
            return CGRect(
                x: dockLeft + margin,
                y: dockBottom + margin,
                width: hudWidth,
                height: hudHeight
            )
        }
    }
    
    // MARK: - Public API
    
    func updateWallpaper() {
        guard let item = WallpaperManager.shared.currentWallpaper else { return }
        show(item)
    }
    
    func show(_ item: WallpaperItem, force: Bool = false) {
        if !force && activeWallpaperItem?.id == item.id && activeWallpaperItem?.path == item.path {
            return
        }
        self.isPaused = false
        activeWallpaperItem = item
    }
    
    func togglePause() {
        isPaused.toggle()
    }
}

// MARK: - Unified Root Engine Overlay Stack

struct RootEngineView: View {
    @ObservedObject var engine: WallpaperEngine
    @ObservedObject var manager = WallpaperManager.shared
    
    var body: some View {
        WallpaperPlatformViewRepresentable(
            item: engine.activeWallpaperItem,
            isPaused: engine.isPaused,
            volume: manager.volume
        )
        .ignoresSafeArea()
    }
}

struct WallpaperPlatformViewRepresentable: NSViewRepresentable {
    let item: WallpaperItem?
    let isPaused: Bool
    let volume: Float
    
    func makeNSView(context: Context) -> WallpaperPlatformView {
        return WallpaperPlatformView()
    }
    
    func updateNSView(_ nsView: WallpaperPlatformView, context: Context) {
        nsView.update(item: item, isPaused: isPaused, volume: volume)
    }
}

class WallpaperPlatformView: NSView {
    private var playerA: AVPlayer?
    private var playerB: AVPlayer?
    private var layerA: AVPlayerLayer?
    private var layerB: AVPlayerLayer?
    private var imageLayer: CALayer?
    
    private var timeObserverA: Any?
    private var timeObserverB: Any?
    private var isPlayerAOnTop = true
    
    private var loadedItemPath: String?
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    
    func update(item: WallpaperItem?, isPaused: Bool, volume: Float) {
        if loadedItemPath != item?.path {
            load(item: item)
        }
        
        playerA?.volume = volume
        playerB?.volume = volume
        
        if isPaused {
            playerA?.pause()
            playerB?.pause()
        } else {
            if isPlayerAOnTop {
                if playerA?.rate == 0 { playerA?.play() }
            } else {
                if playerB?.rate == 0 { playerB?.play() }
            }
        }
    }
    
    private func cleanup() {
        if let tokenA = timeObserverA { playerA?.removeTimeObserver(tokenA); timeObserverA = nil }
        if let tokenB = timeObserverB { playerB?.removeTimeObserver(tokenB); timeObserverB = nil }
        playerA?.pause(); playerA = nil
        playerB?.pause(); playerB = nil
    }
    
    private func load(item: WallpaperItem?) {
        loadedItemPath = item?.path
        cleanup()
        
        guard let item = item else { return }
        
        let transitionDuration: CFTimeInterval = 0.8
        
        if item.type == .image {
            let url = URL(fileURLWithPath: item.path)
            guard let image = NSImage(contentsOf: url) else { return }
            
            let newImageLayer = CALayer()
            newImageLayer.contents = image
            newImageLayer.contentsGravity = .resizeAspectFill
            newImageLayer.frame = self.bounds
            newImageLayer.opacity = 0.0
            
            self.layer?.addSublayer(newImageLayer)
            
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 0.0
            anim.toValue = 1.0
            anim.duration = transitionDuration
            newImageLayer.add(anim, forKey: "fade")
            newImageLayer.opacity = 1.0
            
            let oldLayers = [layerA, layerB, imageLayer].compactMap { $0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration) {
                oldLayers.forEach { $0.removeFromSuperlayer() }
            }
            
            self.imageLayer = newImageLayer
            self.layerA = nil
            self.layerB = nil
            
        } else {
            let url: URL
            if item.isBundled {
                let ns = item.path as NSString
                url = Bundle.main.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension) ?? URL(fileURLWithPath: item.path)
            } else {
                url = URL(fileURLWithPath: item.path)
            }
            
            let pA = AVPlayer(url: url)
            let pB = AVPlayer(url: url)
            
            let newLayerA = AVPlayerLayer(player: pA)
            newLayerA.videoGravity = .resizeAspectFill
            newLayerA.frame = self.bounds
            newLayerA.opacity = 0.0
            
            let newLayerB = AVPlayerLayer(player: pB)
            newLayerB.videoGravity = .resizeAspectFill
            newLayerB.frame = self.bounds
            newLayerB.opacity = 0.0
            
            self.layer?.addSublayer(newLayerB)
            self.layer?.addSublayer(newLayerA) // A on top
            
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 0.0
            anim.toValue = 1.0
            anim.duration = transitionDuration
            newLayerA.add(anim, forKey: "fade")
            newLayerA.opacity = 1.0
            
            let oldLayers = [layerA, layerB, imageLayer].compactMap { $0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration) {
                oldLayers.forEach { $0.removeFromSuperlayer() }
                newLayerB.opacity = 1.0
            }
            
            self.layerA = newLayerA
            self.layerB = newLayerB
            self.playerA = pA
            self.playerB = pB
            self.imageLayer = nil
            
            self.isPlayerAOnTop = true
            
            let interval = CMTime(seconds: 0.05, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            
            timeObserverA = pA.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak pA, weak pB] time in
                guard let self = self, let pA = pA, let pB = pB, self.isPlayerAOnTop else { return }
                guard let currentItem = pA.currentItem else { return }
                let duration = currentItem.duration.seconds
                guard duration > 0 && !duration.isNaN else { return }
                
                let current = time.seconds
                let fadeDuration = 0.6
                let remaining = duration - current
                
                if remaining <= fadeDuration && remaining > 0 {
                    let opacity = max(0.0, remaining / fadeDuration)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.layerA?.opacity = Float(opacity)
                    CATransaction.commit()
                    
                    if pB.rate == 0 {
                        pB.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            pB.play()
                        }
                    }
                } else if current >= duration - 0.05 {
                    self.isPlayerAOnTop = false
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.layerA?.opacity = 1.0
                    self.layerA?.zPosition = 0
                    self.layerB?.zPosition = 1
                    CATransaction.commit()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak pA] in
                        pA?.pause()
                        pA?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            }
            
            timeObserverB = pB.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak pA, weak pB] time in
                guard let self = self, let pA = pA, let pB = pB, !self.isPlayerAOnTop else { return }
                guard let currentItem = pB.currentItem else { return }
                let duration = currentItem.duration.seconds
                guard duration > 0 && !duration.isNaN else { return }
                
                let current = time.seconds
                let fadeDuration = 0.6
                let remaining = duration - current
                
                if remaining <= fadeDuration && remaining > 0 {
                    let opacity = max(0.0, remaining / fadeDuration)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.layerB?.opacity = Float(opacity)
                    CATransaction.commit()
                    
                    if pA.rate == 0 {
                        pA.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            pA.play()
                        }
                    }
                } else if current >= duration - 0.05 {
                    self.isPlayerAOnTop = true
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.layerB?.opacity = 1.0
                    self.layerB?.zPosition = 0
                    self.layerA?.zPosition = 1
                    CATransaction.commit()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak pB] in
                        pB?.pause()
                        pB?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            }
            
            pA.play()
        }
    }
    
    override func layout() {
        super.layout()
        layerA?.frame = self.bounds
        layerB?.frame = self.bounds
        imageLayer?.frame = self.bounds
    }
}

// MARK: - Now Playing Transparent HUD Widget

struct NowPlayingWidget: View {
    let song: SongInfo
    @State private var isHovered = false
    @State private var isDragTargeted = false
    @State private var animatedPosition: Double = 0
    @State private var animDuration: Double = 1.1
    
    var body: some View {
        let activeHover = isHovered || isDragTargeted
        let layout = activeHover ? AnyLayout(VStackLayout(alignment: .center, spacing: 14)) : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        
        layout {
            // Album Art (Premium Apple-style squircle with high-quality AA scaling)
            ZStack {
                if song.artworkURL != "none", let url = URL(string: song.artworkURL) {
                    AsyncImage(url: url) { image in
                        image.resizable()
                             .interpolation(.high)
                             .antialiased(true)
                             .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        defaultArt(activeHover: activeHover)
                    }
                    .frame(width: activeHover ? 120 : 60, height: activeHover ? 120 : 60)
                    .clipShape(RoundedRectangle(cornerRadius: activeHover ? 18 : 12, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
                } else {
                    defaultArt(activeHover: activeHover)
                }
            }
            
            // Text Details (Floating HUD with white text and elegant drop shadows)
            VStack(alignment: activeHover ? .center : .leading, spacing: 4) {
                Text(song.name)
                    .font(.system(size: activeHover ? 15 : 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
                    .lineLimit(1)
                    .multilineTextAlignment(activeHover ? .center : .leading)
                
                Text(song.artist)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
                    .lineLimit(1)
                    .multilineTextAlignment(activeHover ? .center : .leading)
                
                HStack(spacing: 6) {
                    // Simulated bouncy visualizer bars!
                    AudioVisualizer()
                    
                    Text(song.album)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                        .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: activeHover ? .center : .leading)
                
                if song.duration > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                                .frame(height: 3)
                            Capsule().fill(Color.white)
                                .frame(width: geo.size.width * CGFloat(animatedPosition / max(1, song.duration)), height: 3)
                                .shadow(color: .white.opacity(0.3), radius: 1)
                                .animation(.linear(duration: animDuration), value: animatedPosition)
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 4)
                }
            }
            .frame(width: activeHover ? 200 : 170, alignment: activeHover ? .center : .leading)
        }
        .padding(14)
        .frame(width: activeHover ? 240 : nil) // Keep it beautifully sized and compact
        // Clean transparent HUD with gentle background glow on hover
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(activeHover ? 0.15 : 0.0))
        )
        // Slight, high-end drop shadow on the entire UI as a whole, lifting dynamically on hover
        .shadow(color: .black.opacity(activeHover ? 0.45 : 0.25), radius: activeHover ? 16 : 6, x: 0, y: activeHover ? 12 : 3)
        .onAppear {
            animatedPosition = song.position
        }
        .onChange(of: song.position) { oldPos, newPos in
            let diff = abs(newPos - oldPos)
            if diff > 2.0 {
                animDuration = 0.0
                animatedPosition = newPos
            } else {
                animDuration = 1.1
                animatedPosition = newPos
            }
        }
        .onHover { hovering in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                isHovered = hovering
            }
        }
        .onDrop(of: ["public.file-url"], isTargeted: Binding(
            get: { isDragTargeted },
            set: { targeted in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                    isDragTargeted = targeted
                }
            }
        )) { _ in
            return false
        }
    }
    
    private func defaultArt(activeHover: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: activeHover ? 18 : 12, style: .continuous)
                .fill(Color.white.opacity(0.15))
            Image(systemName: "music.note")
                .foregroundColor(.white.opacity(0.8))
                .font(.system(size: activeHover ? 40 : 22))
        }
        .frame(width: activeHover ? 120 : 60, height: activeHover ? 120 : 60)
    }
}

struct AudioVisualizer: View {
    @State private var amplitudes: [CGFloat] = [0.2, 0.5, 0.3, 0.6]
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 1.5, height: 8)
                    .scaleEffect(y: amplitudes[index], anchor: .bottom)
            }
        }
        .frame(height: 8)
        .onReceive(timer) { _ in
            withAnimation(.spring(response: 0.12, dampingFraction: 0.55)) {
                amplitudes = (0..<4).map { _ in
                    CGFloat.random(in: 0.15...1.0)
                }
            }
        }
    }
}

// MARK: - Root HUD View Container

struct RootHUDView: View {
    @StateObject private var nowPlaying = NowPlayingMonitor.shared
    @StateObject private var wallpaperManager = WallpaperManager.shared
    @State private var activeSong: SongInfo?
    
    var showWidget: Bool {
        nowPlaying.currentSong != nil && (wallpaperManager.currentWallpaper?.nowPlayingEnabled ?? true)
    }
    
    var body: some View {
        ZStack(alignment: .trailing) {
            NowPlayingWidget(song: nowPlaying.currentSong ?? activeSong ?? SongInfo(app: "Spotify", name: "Not Playing", artist: "", album: "", duration: 0, position: 0, artworkURL: "none"))
                .opacity(showWidget ? 1.0 : 0.0)
                .offset(x: showWidget ? 0 : 350)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showWidget)
        .onAppear {
            if let song = nowPlaying.currentSong {
                activeSong = song
            }
        }
        .onChange(of: nowPlaying.currentSong) { _, newValue in
            if let song = newValue {
                activeSong = song
            }
        }
    }
}

// MARK: - Image Brightness (Luminance) Assistant

extension NSImage {
    var isDark: Bool {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        let width = 10
        let height = 10
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var totalLuminance: Double = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Double(pixelData[offset]) / 255.0
                let g = Double(pixelData[offset + 1]) / 255.0
                let b = Double(pixelData[offset + 2]) / 255.0
                let luminance = 0.299 * r + 0.587 * g + 0.114 * b
                totalLuminance += luminance
            }
        }
        
        let avgLuminance = totalLuminance / Double(width * height)
        return avgLuminance < 0.55
    }
}

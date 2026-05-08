import AppKit
import AVKit
import Combine
import SwiftUI

class WallpaperEngine: ObservableObject {
    var window: NSWindow!
    var hudWindow: NSWindow!
    @Published var isPaused = false
    private var isBatteryPaused = false
    private var isFullscreenPaused = false
    
    @Published var playerA: AVPlayer?
    @Published var playerB: AVPlayer?
    @Published var isPlayerAOnTop: Bool = true
    @Published var playerAOpacity: Double = 1.0
    @Published var playerBOpacity: Double = 1.0
    @Published var currentImage: NSImage?
    @Published var currentType: WallpaperType = .video
    
    private var timeObserverA: Any?
    private var timeObserverB: Any?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        createWindow()
        bindState()
        observeScreenChanges()
        setupSystemMonitoring()
    }
    
    // MARK: - Window Setup
    
    private func createWindow() {
        guard let screen = NSScreen.main else { return }
        let level = Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
        
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: level)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.isOpaque = true
        
        // Host the SwiftUI view natively inside the window
        window.contentView = NSHostingView(rootView: RootEngineView(engine: self))
        
        // Dedicated, transparent interactive overlay window for Now Playing HUD
        let hudWidth: CGFloat = 320
        let hudHeight: CGFloat = 260
        let hudRect = CGRect(
            x: screen.frame.width - hudWidth - 40,
            y: screen.frame.height - hudHeight - 40,
            width: hudWidth,
            height: hudHeight
        )
        hudWindow = NSWindow(contentRect: hudRect, styleMask: .borderless, backing: .buffered, defer: false)
        hudWindow.level = NSWindow.Level(rawValue: level + 1)
        hudWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hudWindow.ignoresMouseEvents = false // Allow hovers/clicks!
        hudWindow.backgroundColor = .clear
        hudWindow.isOpaque = false
        hudWindow.hasShadow = false
        
        hudWindow.contentView = NSHostingView(rootView: RootHUDView())
        
        window.makeKeyAndOrderFront(nil)
        hudWindow.makeKeyAndOrderFront(nil)
    }
    
    // MARK: - Reactive Bindings
    
    private func bindState() {
        WallpaperManager.shared.$currentWallpaper
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] item in
                guard let item = item else { return }
                self?.isPaused = false
                self?.show(item)
            }
            .store(in: &cancellables)
        
        WallpaperManager.shared.$volume
            .receive(on: RunLoop.main)
            .sink { [weak self] vol in
                self?.playerA?.volume = vol
                self?.playerB?.volume = vol
            }
            .store(in: &cancellables)
            
        Publishers.CombineLatest(WallpaperManager.shared.$smartPauseBattery, WallpaperManager.shared.$smartPauseFullscreen)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.evaluatePauseState()
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
    }
    
    private func evaluatePauseState() {
        let batteryPauseActive = isBatteryPaused && WallpaperManager.shared.smartPauseBattery
        let fullscreenPauseActive = isFullscreenPaused && WallpaperManager.shared.smartPauseFullscreen
        let shouldPause = isPaused || batteryPauseActive || fullscreenPauseActive
        if shouldPause {
            playerA?.pause()
            playerB?.pause()
        } else {
            if isPlayerAOnTop {
                playerA?.play()
            } else {
                playerB?.play()
            }
        }
    }
    
    private func observeScreenChanges() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let screen = NSScreen.main else { return }
                self?.window.setFrame(screen.frame, display: true)
                
                let hudWidth: CGFloat = 320
                let hudHeight: CGFloat = 260
                let hudRect = CGRect(
                    x: screen.frame.width - hudWidth - 40,
                    y: screen.frame.height - hudHeight - 40,
                    width: hudWidth,
                    height: hudHeight
                )
                self?.hudWindow.setFrame(hudRect, display: true)
                
                self?.updateWallpaper()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public API
    
    func updateWallpaper() {
        guard let item = WallpaperManager.shared.currentWallpaper else { return }
        show(item)
    }
    
    func show(_ item: WallpaperItem) {
        item.type == .video ? showVideo(item) : showImage(item)
    }
    
    func togglePause() {
        isPaused.toggle()
        evaluatePauseState()
    }
    
    // MARK: - Video
    
    private func showVideo(_ item: WallpaperItem) {
        let url: URL
        if item.isBundled {
            let ns = item.path as NSString
            guard let u = Bundle.main.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension) else { return }
            url = u
        } else {
            url = URL(fileURLWithPath: item.path)
        }
        
        let pA = AVPlayer(url: url)
        let pB = AVPlayer(url: url)
        
        pA.volume = WallpaperManager.shared.volume
        pB.volume = WallpaperManager.shared.volume
        
        cleanupObservers()
        
        self.playerA = pA
        self.playerB = pB
        self.isPlayerAOnTop = true
        self.playerAOpacity = 1.0
        self.playerBOpacity = 1.0
        
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
                self.playerAOpacity = max(0.0, remaining / fadeDuration)
                if pB.rate == 0 {
                    pB.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        pB.play()
                    }
                }
            } else if current >= duration - 0.05 {
                self.isPlayerAOnTop = false
                self.playerAOpacity = 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak pA] in
                    pA?.pause()
                    pA?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            } else {
                self.playerAOpacity = 1.0
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
                self.playerBOpacity = max(0.0, remaining / fadeDuration)
                if pA.rate == 0 {
                    pA.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        pA.play()
                    }
                }
            } else if current >= duration - 0.05 {
                self.isPlayerAOnTop = true
                self.playerBOpacity = 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak pB] in
                    pB?.pause()
                    pB?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            } else {
                self.playerBOpacity = 1.0
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentImage = nil
            self.currentType = .video
            
            self.window.makeKeyAndOrderFront(nil)
            pA.play()
            self.evaluatePauseState()
        }
    }
    
    private func cleanupObservers() {
        if let tokenA = timeObserverA {
            playerA?.removeTimeObserver(tokenA)
            timeObserverA = nil
        }
        if let tokenB = timeObserverB {
            playerB?.removeTimeObserver(tokenB)
            timeObserverB = nil
        }
    }
    
    // MARK: - Image
    
    private func showImage(_ item: WallpaperItem) {
        let url = URL(fileURLWithPath: item.path)
        guard let image = NSImage(contentsOf: url) else { return }
        
        cleanupObservers()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.playerA?.pause()
            self.playerB?.pause()
            self.playerA = nil
            self.playerB = nil
            
            self.currentImage = image
            self.currentType = .image
            
            self.window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Unified Root Engine Overlay Stack

struct RootEngineView: View {
    @ObservedObject var engine: WallpaperEngine
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Wallpaper Layer
            if engine.currentType == .video {
                if let pB = engine.playerB {
                    VideoLayerRepresentable(player: pB)
                        .opacity(engine.isPlayerAOnTop ? 1.0 : engine.playerBOpacity)
                        .zIndex(engine.isPlayerAOnTop ? 0 : 1)
                        .ignoresSafeArea()
                }
                if let pA = engine.playerA {
                    VideoLayerRepresentable(player: pA)
                        .opacity(engine.isPlayerAOnTop ? engine.playerAOpacity : 1.0)
                        .zIndex(engine.isPlayerAOnTop ? 1 : 0)
                        .ignoresSafeArea()
                }
            } else {
                if let img = engine.currentImage {
                    ImageLayerRepresentable(image: img)
                        .ignoresSafeArea()
                }
            }
        }
    }
}

struct VideoLayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player != player {
            nsView.player = player
        }
    }
}

struct ImageLayerRepresentable: NSViewRepresentable {
    let image: NSImage
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.contents = image
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.contents = image
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

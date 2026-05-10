import Foundation
import Combine
import AppKit
import AVFoundation
import ServiceManagement

// MARK: - Data Models

enum WallpaperType: String, Codable {
    case video
    case image
}

struct WallpaperItem: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var path: String
    var type: WallpaperType
    var isBundled: Bool
    var enableNowPlaying: Bool?
    
    var nowPlayingEnabled: Bool {
        enableNowPlaying ?? true
    }
    
    static let supportedVideoExts = ["mp4", "mov", "m4v"]
    static let supportedImageExts = ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp"]
    static var allSupportedExts: [String] { supportedVideoExts + supportedImageExts }
}

enum AutoCycleInterval: String, CaseIterable, Identifiable, Codable {
    case off = "Off"
    case fifteenMinutes = "15 minutes"
    case oneHour = "1 hour"
    case oneDay = "1 day"
    
    var id: String { self.rawValue }
    
    var timeInterval: TimeInterval? {
        switch self {
        case .off: return nil
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .oneDay: return 24 * 60 * 60
        }
    }
}

enum HUDPlacement: String, CaseIterable, Identifiable {
    case bottomRight = "Bottom Right"
    case topCenter = "Below Notch"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    
    var id: String { self.rawValue }
}

// MARK: - Wallpaper Manager

class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()
    
    @Published var wallpapers: [WallpaperItem] = []
    @Published var currentWallpaper: WallpaperItem?
    @Published var volume: Float {
        didSet { UserDefaults.standard.set(volume, forKey: "videoVolume") }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin()
        }
    }
    
    @Published var autoCycleInterval: AutoCycleInterval {
        didSet {
            UserDefaults.standard.set(autoCycleInterval.rawValue, forKey: "autoCycleInterval")
            setupAutoCycleTimer()
        }
    }
    
    @Published var smartPauseBattery: Bool {
        didSet { UserDefaults.standard.set(smartPauseBattery, forKey: "smartPauseBattery") }
    }
    
    @Published var smartPauseLowPower: Bool {
        didSet { UserDefaults.standard.set(smartPauseLowPower, forKey: "smartPauseLowPower") }
    }
    
    @Published var smartPauseFullscreen: Bool {
        didSet { UserDefaults.standard.set(smartPauseFullscreen, forKey: "smartPauseFullscreen") }
    }
    
    @Published var hudPlacement: HUDPlacement {
        didSet { UserDefaults.standard.set(hudPlacement.rawValue, forKey: "hudPlacement") }
    }
    
    private(set) var selectedWallpaperId: String? {
        didSet { UserDefaults.standard.set(selectedWallpaperId, forKey: "selectedWallpaperId") }
    }
    
    private var autoCycleTimer: Timer?
    
    private init() {
        if UserDefaults.standard.object(forKey: "videoVolume") == nil {
            // Migrate old playSound boolean if exists
            let playSound = UserDefaults.standard.bool(forKey: "playSound")
            self.volume = playSound ? 1.0 : 0.0
        } else {
            self.volume = UserDefaults.standard.float(forKey: "videoVolume")
        }
        
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        let intervalStr = UserDefaults.standard.string(forKey: "autoCycleInterval") ?? "Off"
        self.autoCycleInterval = AutoCycleInterval(rawValue: intervalStr) ?? .off
        self.smartPauseBattery = UserDefaults.standard.bool(forKey: "smartPauseBattery")
        self.smartPauseLowPower = UserDefaults.standard.bool(forKey: "smartPauseLowPower")
        self.smartPauseFullscreen = UserDefaults.standard.bool(forKey: "smartPauseFullscreen")
        let placementStr = UserDefaults.standard.string(forKey: "hudPlacement") ?? "Bottom Right"
        self.hudPlacement = HUDPlacement(rawValue: placementStr) ?? .bottomRight
        
        self.selectedWallpaperId = UserDefaults.standard.string(forKey: "selectedWallpaperId")
        loadWallpapers()
        ensureDefaultVideo()
        
        // Set initial currentWallpaper
        self.currentWallpaper = wallpapers.first { $0.id == selectedWallpaperId }
        setupAutoCycleTimer()
    }
    
    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }
    
    private func setupAutoCycleTimer() {
        autoCycleTimer?.invalidate()
        guard let interval = autoCycleInterval.timeInterval else { return }
        autoCycleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.cycleToNextWallpaper()
        }
    }
    
    private func cycleToNextWallpaper() {
        guard !wallpapers.isEmpty else { return }
        if let currentId = selectedWallpaperId,
           let currentIndex = wallpapers.firstIndex(where: { $0.id == currentId }) {
            let nextIndex = (currentIndex + 1) % wallpapers.count
            selectWallpaper(wallpapers[nextIndex].id)
        } else if let firstId = wallpapers.first?.id {
            selectWallpaper(firstId)
        }
    }
    
    // MARK: - Selection
    
    func selectWallpaper(_ id: String) {
        selectedWallpaperId = id
        currentWallpaper = wallpapers.first { $0.id == id }
    }
    
    func setNowPlayingEnabled(_ id: String, enabled: Bool) {
        if let index = wallpapers.firstIndex(where: { $0.id == id }) {
            wallpapers[index].enableNowPlaying = enabled
            save()
            if currentWallpaper?.id == id {
                currentWallpaper = wallpapers[index]
            }
        }
    }
    
    // MARK: - Persistence
    
    private func loadWallpapers() {
        guard let data = UserDefaults.standard.data(forKey: "savedWallpapers"),
              let decoded = try? JSONDecoder().decode([WallpaperItem].self, from: data) else { return }
        self.wallpapers = decoded
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(wallpapers) {
            UserDefaults.standard.set(encoded, forKey: "savedWallpapers")
        }
    }
    
    private func ensureDefaultVideo() {
        let defaultId = "default_video"
        guard !wallpapers.contains(where: { $0.id == defaultId }) else { return }
        let item = WallpaperItem(id: defaultId, name: "Default Video", path: "video.mp4", type: .video, isBundled: true, enableNowPlaying: true)
        wallpapers.insert(item, at: 0)
        if selectedWallpaperId == nil { selectWallpaper(defaultId) }
    }
    
    // MARK: - App Support Folder Custom Wallpapers Directory
    
    private var customWallpapersDir: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("LiveWall", isDirectory: true)
        let customDir = appSupport.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        return customDir
    }
    
    // MARK: - Actions
    
    func addWallpaper(url: URL, customName: String? = nil) {
        let ext = url.pathExtension.lowercased()
        let type: WallpaperType = WallpaperItem.supportedVideoExts.contains(ext) ? .video : .image
        
        let id = UUID().uuidString
        let destURL = customWallpapersDir.appendingPathComponent("\(id).\(ext)")
        
        // Copy to our app support folder so it continues working even if original file is moved/deleted
        try? FileManager.default.removeItem(at: destURL)
        try? FileManager.default.copyItem(at: url, to: destURL)
        
        let name = customName ?? url.deletingPathExtension().lastPathComponent
        let item = WallpaperItem(id: id, name: name, path: destURL.path, type: type, isBundled: false, enableNowPlaying: true)
        wallpapers.append(item)
        save()
        selectWallpaper(item.id)
    }
    
    func removeWallpaper(id: String) {
        if let item = wallpapers.first(where: { $0.id == id && !$0.isBundled }) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: item.path))
        }
        wallpapers.removeAll { $0.id == id && !$0.isBundled }
        if selectedWallpaperId == id {
            let fallback = wallpapers.first?.id ?? ""
            selectWallpaper(fallback)
        }
        save()
    }
    
    // MARK: - Custom .lw Format Import/Export (Forwards/Backwards Compatible)
    
    struct LWMetadata: Codable {
        let version: Int
        let name: String
        let type: WallpaperType
        let originalExtension: String
        let extraProperties: [String: String]?
    }
    
    func exportLWFile(item: WallpaperItem, to destinationURL: URL) {
        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let sourceURL = item.isBundled ? Bundle.main.url(forResource: (item.path as NSString).deletingPathExtension, withExtension: (item.path as NSString).pathExtension)! : URL(fileURLWithPath: item.path)
        let ext = sourceURL.pathExtension
        
        let metadata = LWMetadata(version: 1, name: item.name, type: item.type, originalExtension: ext, extraProperties: nil)
        
        if let metaData = try? JSONEncoder().encode(metadata) {
            try? metaData.write(to: tempDir.appendingPathComponent("metadata.json"))
        }
        
        let contentDest = tempDir.appendingPathComponent("content.\(ext)")
        try? fileManager.copyItem(at: sourceURL, to: contentDest)
        
        // Compress using macOS built-in 'ditto'
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, destinationURL.path]
        try? process.run()
        process.waitUntilExit()
        
        try? fileManager.removeItem(at: tempDir)
    }
    
    func importLWFile(url: URL) {
        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Decompress using macOS built-in 'ditto'
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, tempDir.path]
        try? process.run()
        process.waitUntilExit()
        
        let metaURL = tempDir.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaURL),
              let metadata = try? JSONDecoder().decode(LWMetadata.self, from: data) else {
            try? fileManager.removeItem(at: tempDir)
            return
        }
        
        let contentURL = tempDir.appendingPathComponent("content.\(metadata.originalExtension)")
        if fileManager.fileExists(atPath: contentURL.path) {
            DispatchQueue.main.async {
                self.addWallpaper(url: contentURL, customName: metadata.name)
                try? fileManager.removeItem(at: tempDir)
            }
        } else {
            try? fileManager.removeItem(at: tempDir)
        }
    }
}

// MARK: - Thumbnail Cache

class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.livewall.thumbnails", qos: .userInitiated)
    private var memorySource: DispatchSourceMemoryPressure?
    
    init() {
        cache.countLimit = 50
        
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            self?.cache.removeAllObjects()
        }
        source.resume()
        self.memorySource = source
    }
    
    func getCached(for item: WallpaperItem) -> NSImage? {
        if let cached = cache.object(forKey: item.id as NSString) {
            return cached
        }
        let img = generate(for: item)
        if let i = img { cache.setObject(i, forKey: item.id as NSString) }
        return img
    }
    
    func get(for item: WallpaperItem, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache.object(forKey: item.id as NSString) {
            completion(cached)
            return
        }
        queue.async { [weak self] in
            let image = self?.generate(for: item)
            if let img = image { self?.cache.setObject(img, forKey: item.id as NSString) }
            DispatchQueue.main.async { completion(image) }
        }
    }
    
    private func generate(for item: WallpaperItem) -> NSImage? {
        return autoreleasepool {
            let url: URL
            if item.isBundled {
                let ns = item.path as NSString
                guard let u = Bundle.main.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension) else { return nil }
                url = u
            } else {
                url = URL(fileURLWithPath: item.path)
            }
            
            if item.type == .video {
                let asset = AVURLAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 320, height: 320)
                let mid = CMTimeMultiplyByFloat64(asset.duration, multiplier: 0.5)
                if let cg = try? gen.copyCGImage(at: mid, actualTime: nil) {
                    return NSImage(cgImage: cg, size: .zero)
                }
                if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                    return NSImage(cgImage: cg, size: .zero)
                }
                return nil
            } else {
                return NSImage(contentsOf: url)
            }
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case library
    case settings
}

struct ContentView: View {
    @StateObject private var manager = WallpaperManager.shared
    @State private var selection: SidebarItem? = .library
    
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "play.display")
                        .font(.title2)
                        .foregroundStyle(.linearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("LiveWall")
                        .font(.title2)
                        .fontWeight(.bold)
                        .tracking(0.5)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
                
                List(selection: $selection) {
                    Section("Menu") {
                        Label("Library", systemImage: "photo.on.rectangle.angled")
                            .tag(SidebarItem.library)
                        Label("Settings", systemImage: "gearshape")
                            .tag(SidebarItem.settings)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 250)
        } detail: {
            Group {
                switch selection {
                case .library:
                    LibraryView()
                case .settings:
                    SettingsView()
                case nil:
                    Text("Select an item from the sidebar")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Library View

struct LibraryView: View {
    @StateObject private var manager = WallpaperManager.shared
    @StateObject private var nowPlaying = NowPlayingMonitor.shared
    @State private var isHoveringDrop = false
    
    // A nice fluid grid for the gallery
    let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 20)]
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Immersive Preview
            if let current = manager.currentWallpaper {
                ImmersivePreview(item: current)
                    .frame(height: 320)
                    .clipped()
            }
            
            if let song = nowPlaying.currentSong {
                NowPlayingMiniBar(song: song)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            Divider()
            
            // Gallery
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(manager.wallpapers) { item in
                        GalleryCard(item: item)
                    }
                }
                .padding(30)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addWallpaperFiles) {
                    Label("Add Wallpaper", systemImage: "plus")
                }
                .help("Add new wallpaper")
            }
        }
        .navigationTitle("Library")
        // Drag and Drop support
        .onDrop(of: [.fileURL], isTargeted: $isHoveringDrop) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    DispatchQueue.main.async {
                        if url.pathExtension.lowercased() == "lw" {
                            manager.importLWFile(url: url)
                        } else if !manager.wallpapers.contains(where: { $0.path == url.path }) {
                            manager.addWallpaper(url: url)
                        }
                    }
                }
            }
            return true
        }
        .overlay {
            if isHoveringDrop {
                Color.blue.opacity(0.1)
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 48))
                            Text("Drop Files to Add")
                                .font(.title2.bold())
                        }
                        .foregroundColor(.accentColor)
                        .padding(40)
                        .background(Material.regular)
                        .cornerRadius(24)
                        .shadow(radius: 20)
                    )
                    .ignoresSafeArea()
            }
        }
    }
    
    private func addWallpaperFiles() {
        let panel = NSOpenPanel()
        let lwType = UTType(filenameExtension: "lw") ?? .data
        panel.allowedContentTypes = [.movie, .image, lwType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                if url.pathExtension.lowercased() == "lw" {
                    manager.importLWFile(url: url)
                } else {
                    manager.addWallpaper(url: url)
                }
            }
        }
    }
}

// MARK: - Immersive Preview

struct ImmersivePreview: View {
    let item: WallpaperItem
    @State private var image: NSImage?
    @State private var isHovering = false
    @StateObject private var manager = WallpaperManager.shared
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background blurred thumbnail for immersive feel
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 50)
                        .scaleEffect(1.2)
                        .opacity(0.4)
                } else {
                    Color.black.opacity(0.1)
                }
                
                // Actual Image
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 8)
                        .padding(24)
                }
                
                // Overlay Controls on hover
                if isHovering {
                    VStack {
                        Spacer()
                        HStack {
                            VStack(alignment: .leading) {
                                Text("NOW PLAYING")
                                    .font(.caption.bold())
                                    .foregroundColor(.white.opacity(0.7))
                                Text(item.name)
                                    .font(.title3.bold())
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Material.ultraThin)
                            .cornerRadius(12)
                            
                            Spacer()
                            
                            if item.type == .video {
                                HStack(spacing: 8) {
                                    Image(systemName: manager.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                        .font(.title3)
                                        .foregroundColor(.white)
                                    Slider(value: $manager.volume, in: 0...1)
                                        .frame(width: 100)
                                        .accentColor(.white)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Material.ultraThin)
                                .cornerRadius(20)
                            }
                        }
                        .padding(34)
                    }
                    .transition(.opacity)
                }
            }
            .onHover { hoverState in withAnimation(.easeInOut(duration: 0.2)) { isHovering = hoverState } }
        }
        .onAppear { load() }
        .onChange(of: item) { _ in load() }
    }
    
    private func load() {
        ThumbnailCache.shared.get(for: item) { self.image = $0 }
    }
}

// MARK: - Gallery Card

struct GalleryCard: View {
    let item: WallpaperItem
    @StateObject private var manager = WallpaperManager.shared
    @State private var isHovering = false
    
    var isSelected: Bool {
        manager.currentWallpaper?.id == item.id
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                // Thumbnail
                ThumbnailView(item: item)
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                
                // Hover overlay (Delete button)
                if isHovering {
                    Color.black.opacity(0.3)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    
                    if !item.isBundled {
                        VStack {
                            HStack {
                                Spacer()
                                Button(action: {
                                    withAnimation { manager.removeWallpaper(id: item.id) }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(.white.opacity(0.9))
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(8)
                    }
                }
                
                // Selection border / Checkmark
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 3)
                    
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.accentColor))
                                .padding(8)
                        }
                    }
                }
                
                // Type badge
                VStack {
                    Spacer()
                    HStack {
                        Label(item.type == .video ? "VIDEO" : "IMAGE", 
                              systemImage: item.type == .video ? "play.fill" : "photo.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(6)
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    manager.selectWallpaper(item.id)
                }
            }
            
            HStack {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                HStack(spacing: 4) {
                    Text("Show Now Playing")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Toggle("", isOn: Binding(
                        get: { item.nowPlayingEnabled },
                        set: { newValue in
                            withAnimation {
                                manager.setNowPlayingEnabled(item.id, enabled: newValue)
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .scaleEffect(0.7)
                    .frame(width: 38)
                }
                .help("Enable Now Playing HUD for this wallpaper")
            }
            .padding(.horizontal, 4)
        }
        .onHover { isHovering = $0 }
        // Scale effect when hovered
        .scaleEffect(isHovering && !isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        // Native context menu for Sharing & Exporting .lw packages
        .contextMenu {
            Button {
                shareLWPackage()
            } label: {
                Label("Share .lw Package...", systemImage: "square.and.arrow.up")
            }
            
            Button {
                exportLWPackage()
            } label: {
                Label("Export .lw Package...", systemImage: "archivebox")
            }
            
            Button {
                exportOriginalFile()
            } label: {
                Label("Export Original File...", systemImage: "arrow.down.doc")
            }
            
            if !item.isBundled {
                Divider()
                Button(role: .destructive) {
                    withAnimation { manager.removeWallpaper(id: item.id) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
    
    private func getWallpaperURL() -> URL? {
        if item.isBundled {
            let ns = item.path as NSString
            return Bundle.main.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension)
        } else {
            return URL(fileURLWithPath: item.path)
        }
    }
    
    private func shareLWPackage() {
        let fileManager = FileManager.default
        let tempLW = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(item.name).lw")
        try? fileManager.removeItem(at: tempLW)
        WallpaperManager.shared.exportLWFile(item: item, to: tempLW)
        
        let picker = NSSharingServicePicker(items: [tempLW])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }
    
    private func exportLWPackage() {
        let panel = NSSavePanel()
        let lwType = UTType(filenameExtension: "lw") ?? .data
        panel.allowedContentTypes = [lwType]
        panel.nameFieldStringValue = "\(item.name).lw"
        
        if panel.runModal() == .OK, let destinationURL = panel.url {
            WallpaperManager.shared.exportLWFile(item: item, to: destinationURL)
        }
    }
    
    private func exportOriginalFile() {
        guard let sourceURL = getWallpaperURL() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [item.type == .video ? UTType.movie : UTType.image]
        panel.nameFieldStringValue = (item.name as NSString).appendingPathExtension(sourceURL.pathExtension) ?? item.name
        
        if panel.runModal() == .OK, let destinationURL = panel.url {
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var manager = WallpaperManager.shared
    @ObservedObject private var updater = UpdateManager.shared
    
    var body: some View {
        Form {
            Section("Audio & Playback") {
                HStack {
                    Image(systemName: manager.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .foregroundColor(.secondary)
                    Slider(value: $manager.volume, in: 0...1)
                }
                
                Picker("Auto-Cycle Interval", selection: $manager.autoCycleInterval) {
                    ForEach(AutoCycleInterval.allCases) { interval in
                        Text(interval.rawValue).tag(interval)
                    }
                }
            }
            
            Section("System & Integration") {
                Toggle("Launch at Login", isOn: $manager.launchAtLogin)
                    .toggleStyle(.switch)
                
                Picker("Now Playing Position", selection: $manager.hudPlacement) {
                    ForEach(HUDPlacement.allCases) { placement in
                        Text(placement.rawValue).tag(placement)
                    }
                }
            }
            
            Section("Smart Pause") {
                Toggle("Pause on Battery", isOn: $manager.smartPauseBattery)
                    .toggleStyle(.switch)
                Toggle("Pause on Fullscreen App", isOn: $manager.smartPauseFullscreen)
                    .toggleStyle(.switch)
            }
            
            Section("About") {
                LabeledContent("Version", value: updater.currentVersion)
                LabeledContent("Developer", value: "LiveWall Team")
                
                Button(action: {
                    updater.checkForUpdates { available in
                        if available {
                            updater.showUpdateAlert()
                        } else {
                            let alert = NSAlert()
                            alert.messageText = "Up to Date!"
                            alert.informativeText = "You are running the latest version of LiveWall (\(updater.currentVersion))."
                            alert.alertStyle = .informational
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    }
                }) {
                    HStack {
                        if updater.isChecking {
                            ProgressView().controlSize(.small)
                            Text("Checking...")
                        } else {
                            Text("Check for Updates...")
                        }
                    }
                }
                .disabled(updater.isChecking)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

// MARK: - Thumbnail Helper

struct ThumbnailView: View {
    let item: WallpaperItem
    @State private var image: NSImage?
    
    var body: some View {
        ZStack {
            Color.gray.opacity(0.1)
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .onAppear { load() }
        .onChange(of: item) { _ in load() }
    }
    
    private func load() {
        ThumbnailCache.shared.get(for: item) { self.image = $0 }
    }
}

// MARK: - Now Playing Mini Bar

struct NowPlayingMiniBar: View {
    let song: SongInfo
    
    var body: some View {
        HStack(spacing: 12) {
            // Mini Album Art
            ZStack {
                if song.artworkURL != "none", let url = URL(string: song.artworkURL) {
                    AsyncImage(url: url) { image in
                        image.resizable()
                             .interpolation(.high)
                             .antialiased(true)
                             .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        defaultArt
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    defaultArt
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Image(systemName: "music.note")
                .foregroundColor(.accentColor)
                .font(.title3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08))
    }
    
    private var defaultArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
            Image(systemName: "music.note")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
        }
        .frame(width: 36, height: 36)
    }
}

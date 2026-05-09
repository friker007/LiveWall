import Foundation
import Combine
import AppKit

struct SongInfo: Equatable {
    let app: String
    let name: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let artworkURL: String
}

class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()
    
    @Published var currentSong: SongInfo?
    
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.livewall.nowplaying", qos: .background)
    private var artworkCache: [String: String] = [:]
    private var pendingRequests: Set<String> = []
    
    private let scriptSource = """
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is playing then
                set t to current track
                try
                    set art to artwork url of t
                on error
                    set art to "none"
                end try
                return "Spotify|||" & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & (duration of t / 1000 as string) & "|||" & (player position as string) & "|||" & art
            end if
        end tell
    end if
    if application "Music" is running then
        tell application "Music"
            if player state is playing then
                set t to current track
                set artPath to "none"
                try
                    if (count of artworks of t) > 0 then
                        set trackID to id of t
                        set artPath to "/tmp/livewall_music_" & (trackID as string) & ".jpg"
                        set fileExists to false
                        try
                            do shell script "test -f " & quoted form of artPath
                            set fileExists to true
                        end try
                        if not fileExists then
                            set artworkData to raw data of artwork 1 of t
                            set fileRef to (open for access POSIX file artPath with write permission)
                            set eof of fileRef to 0
                            write artworkData to fileRef
                            close access fileRef
                        end if
                        set artPath to "file://" & artPath
                    end if
                on error
                    try
                        close access fileRef
                    end try
                end try
                return "Music|||" & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & (duration of t as string) & "|||" & (player position as string) & "|||" & artPath
            end if
        end tell
    end if
    return "none"
    """
    
    init() {}
    
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkNowPlaying()
        }
    }
    
    private func checkNowPlaying() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", self.scriptSource]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let resultStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   resultStr != "none" {
                    
                    let parts = resultStr.components(separatedBy: "|||")
                    if parts.count >= 7 {
                        var song = SongInfo(
                            app: parts[0],
                            name: parts[1],
                            artist: parts[2],
                            album: parts[3],
                            duration: Double(parts[4]) ?? 0.0,
                            position: Double(parts[5]) ?? 0.0,
                            artworkURL: parts[6]
                        )
                        
                        let cacheKey = "\(song.artist)-\(song.name)"
                        if song.artworkURL == "none" {
                            if let cachedURL = self.artworkCache[cacheKey] {
                                song = SongInfo(
                                    app: song.app,
                                    name: song.name,
                                    artist: song.artist,
                                    album: song.album,
                                    duration: song.duration,
                                    position: song.position,
                                    artworkURL: cachedURL
                                )
                            } else {
                                self.fetchiTunesArtwork(for: song.name, artist: song.artist) { [weak self] url in
                                    guard let self = self else { return }
                                    if let url = url {
                                        DispatchQueue.main.async {
                                            self.artworkCache[cacheKey] = url
                                            if var current = self.currentSong, current.name == song.name && current.artist == song.artist {
                                                current = SongInfo(
                                                    app: current.app,
                                                    name: current.name,
                                                    artist: current.artist,
                                                    album: current.album,
                                                    duration: current.duration,
                                                    position: current.position,
                                                    artworkURL: url
                                                )
                                                self.currentSong = current
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        DispatchQueue.main.async {
                            if self.currentSong != song {
                                self.currentSong = song
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            if self.currentSong != nil {
                                self.currentSong = nil
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        if self.currentSong != nil {
                            self.currentSong = nil
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if self.currentSong != nil {
                        self.currentSong = nil
                    }
                }
            }
        }
    }
    
    private func fetchiTunesArtwork(for track: String, artist: String, completion: @escaping (String?) -> Void) {
        let cacheKey = "\(artist)-\(track)"
        if pendingRequests.contains(cacheKey) { return }
        pendingRequests.insert(cacheKey)
        
        let query = "\(artist) \(track)"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encodedQuery)&entity=song&limit=1") else {
            pendingRequests.remove(cacheKey)
            completion(nil)
            return
        }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            self.queue.async {
                self.pendingRequests.remove(cacheKey)
            }
            guard error == nil, let data = data else {
                completion(nil)
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [[String: Any]],
                   let first = results.first,
                   let artworkUrl100 = first["artworkUrl100"] as? String {
                    let artworkUrl240 = artworkUrl100.replacingOccurrences(of: "100x100bb.jpg", with: "240x240bb.jpg")
                    completion(artworkUrl240)
                } else {
                    completion(nil)
                }
            } catch {
                completion(nil)
            }
        }.resume()
    }
}

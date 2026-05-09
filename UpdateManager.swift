import Foundation
import AppKit

class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var releaseNotes = ""
    @Published var downloadURL: String?
    
    var currentVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    private init() {}
    
    func checkForUpdates(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isChecking else { return }
        isChecking = true
        
        let url = URL(string: "https://api.github.com/repos/friker007/LiveWall/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("LiveWall-Updater", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isChecking = false
                guard let self = self, let data = data, error == nil else {
                    completion(false)
                    return
                }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let tagName = json["tag_name"] as? String,
                       let htmlUrl = json["html_url"] as? String {
                        
                        let cleanTag = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                        let cleanCurrent = self.currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                        
                        if self.isVersion(cleanTag, newerThan: cleanCurrent) {
                            self.updateAvailable = true
                            self.latestVersion = tagName
                            self.releaseNotes = json["body"] as? String ?? ""
                            
                            if let assets = json["assets"] as? [[String: Any]] {
                                for asset in assets {
                                    if let name = asset["name"] as? String, name.hasSuffix(".dmg") {
                                        self.downloadURL = asset["browser_download_url"] as? String
                                        break
                                    }
                                }
                            }
                            if self.downloadURL == nil {
                                self.downloadURL = htmlUrl
                            }
                            completion(true)
                            return
                        }
                    }
                } catch {}
                self.updateAvailable = false
                completion(false)
            }
        }.resume()
    }
    
    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0.trimmingCharacters(in: .decimalDigits.inverted)) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0.trimmingCharacters(in: .decimalDigits.inverted)) }
        for i in 0..<max(parts1.count, parts2.count) {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }
    
    func downloadAndInstallUpdate() {
        guard let urlStr = downloadURL, let url = URL(string: urlStr) else { return }
        
        if !urlStr.hasSuffix(".dmg") {
            NSWorkspace.shared.open(url)
            return
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent("LiveWall_Update.dmg")
        
        try? FileManager.default.removeItem(at: destinationURL)
        
        let downloadTask = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            guard let localURL = localURL, error == nil else { return }
            do {
                try FileManager.default.moveItem(at: localURL, to: destinationURL)
                
                // Mount the DMG using native hdiutil
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                task.arguments = ["mount", destinationURL.path]
                try task.run()
                task.waitUntilExit()
                
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Update Downloaded!"
                    alert.informativeText = "The installer DMG has been mounted successfully. Please drag LiveWall into your Applications folder to finish updating, then restart the app."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    
                    NSApplication.shared.terminate(nil)
                }
            } catch {}
        }
        downloadTask.resume()
    }
    
    func showUpdateAlert() {
        let alert = NSAlert()
        alert.messageText = "New Update Available (\(latestVersion))"
        alert.informativeText = "A new version of LiveWall is available. Would you like to download and install it now?\n\nRelease Notes:\n\(releaseNotes)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download and Install")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Show a progress indicator or alert that download has started
            let progressAlert = NSAlert()
            progressAlert.messageText = "Downloading Update..."
            progressAlert.informativeText = "The update is downloading in the background. The installer will mount automatically once complete."
            progressAlert.alertStyle = .informational
            progressAlert.addButton(withTitle: "OK")
            progressAlert.runModal()
            
            downloadAndInstallUpdate()
        }
    }
}

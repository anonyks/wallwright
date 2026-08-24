//
//  ImportPanels.swift
//  Wallwright
//
//  Created by Haren on 2023/8/4.
//

import Cocoa
import UniformTypeIdentifiers

struct WPImportError: LocalizedError {
    var errorDescription: String?
    var failureReason: String?
    var helpAnchor: String?
    var recoverySuggestion: String?
    
    static let permissionDenied         = WPImportError(errorDescription: "Permission Denied",
                                                failureReason: "This app doesn't have the permission to access to the folder(s) you selected",
                                                helpAnchor: "File Permission",
                                                recoverySuggestion: "Try enable it in 'System Settings' - 'Privacy & Security'")
    
    static let doesNotContainWallpaper  = WPImportError(errorDescription: "No Wallpaper(s) Inside",
                                                       failureReason: "Maybe you selected the wrong folder which doesn't contain any wallpapers",
                                                       helpAnchor: "Contents in Folder(s)",
                                                       recoverySuggestion: "Check the folder(s) you selected and try again")
    
    static let unkown                   = WPImportError(errorDescription: "Unkown Error",
                                                        failureReason: "",
                                                        helpAnchor: "",
                                                        recoverySuggestion: "")
}

extension AppDelegate {
    @objc func openImportFromFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .zip, .movie]
            + VideoImporter.importableExtensions.compactMap { UTType(filenameExtension: $0) }
            + ImageImporter.importableExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: self.mainWindowController.window) { [weak self] response in
            if response != .OK { return }
            guard !panel.urls.isEmpty else { return }

            let fm = FileManager.default
            let docsDir = fm.wallpapersDirectory

            var wallpaperURLs: [URL] = []
            var zipURLs: [URL] = []
            var videoURLs: [URL] = []
            var imageURLs: [URL] = []

            for url in panel.urls {
                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)

                if url.pathExtension.lowercased() == "zip" {
                    zipURLs.append(url)
                } else if exists && !isDir.boolValue && VideoImporter.importableExtensions.contains(url.pathExtension.lowercased()) {
                    videoURLs.append(url)
                } else if exists && !isDir.boolValue && ImageImporter.importableExtensions.contains(url.pathExtension.lowercased()) {
                    imageURLs.append(url)
                } else if fm.fileExists(atPath: url.appending(path: "project.json").path) {
                    wallpaperURLs.append(url)
                } else {
                    // Scan immediate children for wallpaper folders
                    guard let children = try? fm.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: [.isDirectoryKey],
                        options: .skipsHiddenFiles
                    ) else { continue }
                    for child in children {
                        var isChildDir: ObjCBool = false
                        if fm.fileExists(atPath: child.path, isDirectory: &isChildDir),
                           isChildDir.boolValue,
                           fm.fileExists(atPath: child.appending(path: "project.json").path) {
                            wallpaperURLs.append(child)
                        }
                    }
                }
            }

            guard !wallpaperURLs.isEmpty || !zipURLs.isEmpty || !videoURLs.isEmpty || !imageURLs.isEmpty else {
                DispatchQueue.main.async {
                    self?.contentViewModel.alertImportModal(which: .doesNotContainWallpaper)
                }
                return
            }

            DispatchQueue.main.async {
                var copiedAny = false
                for url in wallpaperURLs {
                    // Only video/image wallpapers are supported — skip anything else (scene, web,
                    // ...) rather than importing a package with nothing that can actually render it.
                    guard let data = try? Data(contentsOf: url.appending(path: "project.json")),
                          let project = try? JSONDecoder().decode(WEProject.self, from: data),
                          project.isSupportedType
                    else { continue }

                    let dest = docsDir.appending(path: url.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.copyItem(at: url, to: dest)
                        copiedAny = true
                    }
                }
                if copiedAny {
                    VideoImporter.notifyLibraryChanged()
                }
                for url in zipURLs {
                    ZipImporter.importZip(at: url)
                }
                if !videoURLs.isEmpty {
                    Task { @MainActor in
                        await self?.contentViewModel.enqueueImports(videoURLs)
                    }
                }
                if !imageURLs.isEmpty {
                    Task { @MainActor in
                        await self?.contentViewModel.enqueueImageImports(imageURLs)
                    }
                }
            }
        }
    }
    
}

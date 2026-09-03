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
            let urls = panel.urls

            // Off-main — `beginSheetModal`'s completion handler already runs on the main thread,
            // so the `DispatchQueue.main.async` this used to have below was a main-to-main no-op,
            // not an actual offload: the directory scan (including a recursive listing for
            // wallpaper folders), the wallpaper-folder copy loop, AND the zip extraction loop were
            // all running synchronously on the main thread from the moment the panel closed.
            // Confirmed the same real freeze risk as the drag-and-drop zip path (see
            // `ContentViewModel.performDrop`'s identical fix) — several folders or a zip archive
            // can make this take real, visible time.
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default

                var wallpaperURLs: [URL] = []
                var zipURLs: [URL] = []
                var videoURLs: [URL] = []
                var imageURLs: [URL] = []

                for url in urls {
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

                var copiedAny = false
                for url in wallpaperURLs {
                    // Only video/image wallpapers are supported — skip anything else (scene, web,
                    // ...) rather than importing a package with nothing that can actually render it.
                    guard let data = try? Data(contentsOf: url.appending(path: "project.json")),
                          let project = try? JSONDecoder().decode(WEProject.self, from: data),
                          project.isSupportedType
                    else { continue }

                    // Was `wallpapersDirectory.appending(path: url.lastPathComponent)` + `if
                    // !fileExists`, a silent no-op skip whenever the SOURCE folder's own name
                    // (often a generic "wallpaper"/"content", or a Steam Workshop numeric ID — not
                    // the wallpaper's real title) collided with anything already in the library.
                    // Named by the wallpaper's actual title instead, with a numeric suffix on
                    // collision rather than silently dropping the whole import.
                    let title = project.title.isEmpty ? url.lastPathComponent : project.title
                    let dest = fm.uniqueWallpaperDestination(forTitle: title)
                    try? fm.copyItem(at: url, to: dest)
                    copiedAny = true
                }
                if copiedAny {
                    // Safe to post off-main — `ContentViewModel`'s subscriber already hops to
                    // main via `.receive(on: DispatchQueue.main)`.
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

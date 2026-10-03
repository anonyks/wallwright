//
//  AppResources.swift
//  Wallwright
//
//  Bundled resources that are required for the app to function, resolved once here instead of
//  force-unwrapping Bundle.main.url(forResource:) at every call site.
//

import Foundation

enum AppResources {
    static let wallpaperNotFoundVideoURL: URL = {
        guard let url = Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4") else {
            fatalError("WallpaperNotFound.mp4 is missing from the app bundle — check Xcode target membership")
        }
        return url
    }()
}

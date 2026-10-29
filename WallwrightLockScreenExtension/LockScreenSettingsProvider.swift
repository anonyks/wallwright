//
//  LockScreenSettingsProvider.swift
//  WallwrightLockScreenExtension
//
//  Real implementation of `provideSettingsViewModelsWithContentTypes:reply:`, previously stubbed
//  to always return an error (`LockScreenExtension.swift`'s own doc comment: "Phase 2... deferred,
//  since there's nothing to offer here yet"). Confirmed live (2026-10-29) that stub had a second,
//  unintended effect beyond just not appearing in System Settings' picker: it's also what macOS
//  checks before letting "Use Screen Saver: Automatic" (modern macOS's "use my wallpaper as my
//  screen saver too" toggle) actually use this choice — the repeated Console line "Could not check
//  if screen saver supports choice" traces directly back to this call failing. Returning a real
//  `WallpaperSettingsModels(desktop:, screenSaver:)` — the SAME model for both — is what tells
//  WallpaperAgent this choice is screen-saver-eligible, fixing that without needing a second,
//  differently-protocoled screensaver extension.
//
//  Ported from reference/WallpaperMachine/Extension/WallpaperSettingsProvider.swift (read this
//  session) — same private Codable layout (that file's own header: "verified against
//  WallpaperSettingsViewModelsXPC on macOS 26.6.2", citing kageroumado/phosphene), same
//  NSKeyedArchiver round-trip through a custom NSSecureCoding wrapper class substituted for the
//  real private class name at decode time (there is no public initializer for the private class
//  itself, same reasoning as `WallpaperPrivateRuntime`'s ivar-poke constructors). Trimmed to
//  Wallwright's single always-current-wallpaper case: one choice, not a picker of several.
//

import Foundation

private struct WallpaperChoiceIdentity: Codable {
    var id: String
    var descriptor: WallpaperChoiceDescriptor
}
private struct WallpaperChoiceDescriptor: Codable {
    var provider: String
    var identifier: String
    var files: [URL]
    var configuration: Data
}
private struct WallpaperGroupIdentity: Codable { var id: String }
private enum WallpaperDisposability: Codable { case none }
private enum WallpaperRefreshPolicy: Codable { case `default` }
private enum WallpaperContentBadge: Codable { case video }
private enum WallpaperThumbnail: Codable { case image(url: URL) }
private struct WallpaperChoice: Codable {
    var id: WallpaperChoiceIdentity
    var provider: String
    var identifier: String
    var name: String
    var localizedDescription: String
    var thumbnail: WallpaperThumbnail
    var isDownloaded: Bool
    var options: [String]
}
private struct WallpaperSettingsItem: Codable {
    var id: WallpaperChoiceIdentity
    var localizedName: String
    var thumbnail: WallpaperThumbnail
    var choice: WallpaperChoice
    var contentBadge: WallpaperContentBadge
    var showInTopLevel: Bool
    var sortOrder: Int
    var disposability: WallpaperDisposability
}
private struct WallpaperSettingsGroup: Codable {
    var id: WallpaperGroupIdentity
    var items: [WallpaperSettingsItem]
    var localizedName: String
    var disposability: WallpaperDisposability
    var sortOrder: Int
    var sortID: WallpaperGroupIdentity
    var shouldHideItemLabels: Bool
}
private struct WallpaperSettingsModel: Codable {
    var groups: [WallpaperSettingsGroup]
    var refreshPolicy: WallpaperRefreshPolicy
    var isModificationDisabled: Bool
}
private struct WallpaperSettingsModels: Codable {
    var desktop: WallpaperSettingsModel
    var screenSaver: WallpaperSettingsModel
}

@objc(WWLockScreenSettingsArchive)
private final class LockScreenSettingsArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let value: WallpaperSettingsModels
    init(_ value: WallpaperSettingsModels) { self.value = value }
    required init?(coder: NSCoder) { return nil }
    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else { return }
        do {
            try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
        } catch {
            archiver.failWithError(error)
        }
    }
}

enum LockScreenSettingsProvider {
    private static let providerID = "com.wallwright.Wallwright.LockScreenExtension"

    static func response() throws -> Any {
        // The actual current wallpaper's own poster from the exchange directory, not the bundled
        // static app-icon placeholder this used at first — confirmed live (2026-10-29) that the
        // screen-saver-support fix itself came from the `sortID` change below, not from using a
        // bundled-vs-dynamic thumbnail (both were changed together the first time, never isolated
        // until now); switching the thumbnail back to live content here doesn't touch that fix.
        // Falls back to the bundled resource only if nothing's been published yet.
        let thumbnailURL =
            (try? WallpaperPrivateRuntime.asset("lock-screen.jpg"))
            ?? Bundle.main.url(forResource: "preview", withExtension: "jpg")
        guard let thumbnailURL else {
            throw WallpaperPrivateRuntime.failure("Wallwright lock-screen extension preview is missing.")
        }
        let thumbnail = WallpaperThumbnail.image(url: thumbnailURL)
        let identity = WallpaperChoiceIdentity(
            id: "current",
            descriptor: WallpaperChoiceDescriptor(
                provider: providerID, identifier: "current", files: [], configuration: Data("current".utf8)
            )
        )
        let choice = WallpaperChoice(
            id: identity, provider: providerID, identifier: "current", name: "Wallwright",
            localizedDescription: String(localized: "Applied wallpaper on the lock screen and screen saver"),
            thumbnail: thumbnail, isDownloaded: true, options: []
        )
        let item = WallpaperSettingsItem(
            id: identity, localizedName: "Wallwright", thumbnail: thumbnail, choice: choice,
            // true — shows a real, live thumbnail of the current wallpaper in the main Wallpaper
            // grid (requested 2026-10-29, after the app-icon-thumbnail version looked broken).
            // Still just a static preview, not a working picker: clicking this entry isn't wired
            // to actually select anything (Phase 2, still deferred) — this app always force-selects
            // itself directly via Store/Index.plist instead of waiting to be picked here.
            contentBadge: .video, showInTopLevel: true, sortOrder: 0, disposability: .none
        )
        let group = WallpaperSettingsGroup(
            id: WallpaperGroupIdentity(id: "Wallwright"), items: [item], localizedName: "Wallwright",
            disposability: .none, sortOrder: -100,
            // Matches the reference LITERALLY, not substituted with our own provider id — its own
            // code hardcodes exactly this value with no explanation, which reads as something it
            // found necessary through the same kind of trial and error this file's own header
            // documents, not an arbitrary choice safe to swap out.
            sortID: WallpaperGroupIdentity(id: "com.apple.wallpaper.aerials"), shouldHideItemLabels: false
        )
        let model = WallpaperSettingsModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)

        // Produced and consumed entirely here, never loaded from external input.
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: LockScreenSettingsArchive(WallpaperSettingsModels(desktop: model, screenSaver: model)),
            requiringSecureCoding: false
        )
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.requiresSecureCoding = false
        decoder.decodingFailurePolicy = .setErrorAndReturn
        decoder.setClass(
            NSClassFromString("WallpaperSettingsViewModelsXPC"), forClassName: "WWLockScreenSettingsArchive"
        )
        let response = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        decoder.finishDecoding()
        if let error = decoder.error { throw error }
        guard let response else {
            throw WallpaperPrivateRuntime.failure("macOS rejected the wallpaper provider description.")
        }
        return response
    }
}

//
//  LockScreenExtension.swift
//  WallwrightLockScreenExtension
//
//  The actual macOS ExtensionKit entry point, registered at the `com.apple.wallpaper` extension
//  point (see Info.plist). Adapted from
//  reference/WallpaperMachine/Extension/WallpaperExtension.swift (read in full this session) —
//  same XPC method surface, same Apple-signature connection check.
//
//  Stage 1 (registration/ABI-verification only, every XPC reply a no-op) is done and was verified
//  live: `pluginkit` discovers the extension, `codesign` confirms correct sandboxing/entitlements,
//  and a 2-minute Console capture showed no crash. That alone doesn't put anything on the lock
//  screen — nothing has asked `WallpaperAgent` to use this extension yet. This is stage 2: real
//  content delivery via `LockScreenController`/`LockScreenSurface` (M0, a static image) is wired
//  in below. The one genuinely risky step left is `Wallwright/Services/LockScreenExtensionBridge.swift`
//  actually selecting this extension in `Store/Index.plist` and restarting `WallpaperAgent` — see
//  that file's own header.
//

import AppKit
import ExtensionFoundation

private final class LockScreenXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    // `MainActor.assumeIsolated` was tried first and crashed live (2026-10-28, SIGTRAP/
    // EXC_BREAKPOINT, confirmed via the resulting .ips) — XPC callouts land on a BSXPC-owned GCD
    // queue, not the main thread, so the assumed isolation was simply false. `Task { @MainActor }`
    // actually hops onto the main actor instead of asserting it's already there. Notably, this
    // crash stayed entirely inside this sandboxed extension process — WallpaperAgent itself never
    // destabilized, which is the real safety boundary this design was staged to test.
    func acquire(withId identifier: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        Task { @MainActor in
            LockScreenController.shared.acquire(id: identifier, request: request, reply: reply)
        }
    }

    func update(withId identifier: Any?, request: Any?, reply: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                try LockScreenController.shared.update(id: identifier, request: request)
                reply(nil)
            } catch {
                reply(error)
            }
        }
    }

    func invalidate(withId identifier: Any?, reply: @escaping (Error?) -> Void) {
        Task { @MainActor in
            LockScreenController.shared.invalidate(id: identifier)
            reply(nil)
        }
    }

    func snapshot(withId identifier: Any?, reply: @escaping (Any?, Error?) -> Void) {
        Task { @MainActor in
            LockScreenController.shared.snapshot(id: identifier, reply: reply)
        }
    }

    func provideSettingsViewModels(
        withContentTypes types: Any?, reply: @escaping (Any?, Error?) -> Void
    ) {
        // Still doesn't offer a real System Settings PICKER (Phase 2, still deferred — M0/M1
        // force-select this extension directly via Store/Index.plist, same as AerialsInjector
        // already does). But this call turned out to matter for more than that: confirmed live
        // (2026-10-29) it's also what WallpaperAgent checks before letting "Use Screen Saver:
        // Automatic" use this choice as the screen saver too — see
        // `LockScreenSettingsProvider`'s own header for the full story.
        do {
            reply(try LockScreenSettingsProvider.response(), nil)
        } catch {
            reply(nil, error)
        }
    }

    func isChoiceDownloaded(with choiceID: Any?, reply: @escaping (Bool, Error?) -> Void) {
        reply(true, nil)
    }

    func selectedChoicesDidChange(for identifier: Any?, reply: @escaping (Error?) -> Void) {
        WallpaperPrivateRuntime.log("selectedChoicesDidChange called")
        reply(nil)
    }
}

private struct LockScreenAppExtensionConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        guard WallpaperPrivateRuntime.accepts(connection) else {
            WallpaperPrivateRuntime.log("Rejected untrusted wallpaper host (connection not Apple-signed).")
            return false
        }
        do {
            try WallpaperPrivateRuntime.load()
        } catch {
            WallpaperPrivateRuntime.log("Private-ABI verification failed: \(error.localizedDescription)")
            return false
        }
        let interface = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
        let names = [
            "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperSettingsViewModelsXPC",
        ]
        let classes = NSSet(
            array: names.compactMap(NSClassFromString) + [
                NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self,
                NSURL.self, NSError.self,
            ]
        ) as! Set<AnyHashable>
        for (selector, indexes, reply) in [
            ("acquireWithId:request:reply:", [0, 1], false), ("acquireWithId:request:reply:", [0], true),
            ("updateWithId:request:reply:", [0, 1], false), ("invalidateWithId:reply:", [0], false),
            ("snapshotWithId:reply:", [0], false), ("snapshotWithId:reply:", [0], true),
            ("provideSettingsViewModelsWithContentTypes:reply:", [0], false),
            ("provideSettingsViewModelsWithContentTypes:reply:", [0], true),
            ("isChoiceDownloadedWith:reply:", [0], false),
            ("selectedChoicesDidChangeFor:reply:", [0], false),
        ] as [(String, [Int], Bool)] {
            for index in indexes {
                interface.setClasses(
                    classes, for: NSSelectorFromString(selector), argumentIndex: index, ofReply: reply
                )
            }
        }
        connection.exportedInterface = interface
        connection.exportedObject = LockScreenXPCHandler()
        connection.resume()
        WallpaperPrivateRuntime.log("Accepted native wallpaper host pid=\(connection.processIdentifier)")
        return true
    }
}

@main
final class LockScreenExtension: NSObject, AppExtension {
    override required init() {
        super.init()
        WallpaperPrivateRuntime.log(
            "Wallwright lock-screen extension started: bundle=\(Bundle.main.bundleURL.path)"
        )
        // Never actually wired up before this (2026-10-29) — meant the config-changed Darwin
        // notification listener (and now the lock/unlock pause-resume listener) were both dead
        // code; only a fresh `acquire()` ever picked up a new publish. Harmless until now since
        // most republishes also happened to force a fresh acquire anyway, but worth fixing
        // alongside the pause/resume wiring rather than leaving a second silent gap.
        Task { @MainActor in LockScreenController.shared.start() }
    }

    var configuration: some AppExtensionConfiguration { LockScreenAppExtensionConfiguration() }
}

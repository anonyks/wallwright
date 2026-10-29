//
//  LockScreenSurface.swift
//  WallwrightLockScreenExtension
//
//  One remote CAContext/plain CALayer per (displayID) — no Metal, no vendored renderer. See
//  reference/WallpaperMachine/Extension/WallpaperSurface.swift's own `init` for the CAContext/
//  CALayer setup pattern this mirrors (read in full this session); everything else here is new
//  and much smaller, since Wallwright only ever needs to decode a plain video file, not render an
//  arbitrary Wallpaper Engine scene graph.
//
//  Two content paths, proven live in this order (2026-10-28):
//  - M0, static image: a one-time CGImage-to-IOSurface decode (`applyImage`) — proved the private
//    CAContext/XPC pipeline end to end with the smallest possible rendering surface, so an ABI
//    mistake would be cheap to diagnose. Confirmed working against the real WallpaperAgent: a
//    clean acquire/snapshot/update round trip, no errors, nothing crashed.
//  - M1, live video (`applyVideo`): `AVPlayerItemVideoOutput` pulls decoded frames as
//    IOSurface-backed `CVPixelBuffer`s directly — no per-frame CGImage/CPU copy, unlike M0's
//    one-time still. The poster image from `applyImage` stays on screen until the first real
//    video frame is ready, then frames replace it on a capped timer (not a display link — nobody
//    needs 60fps behind an opaque lock screen; see `frameInterval`'s own doc comment).
//

import AVFoundation
import AppKit
import CoreGraphics
import CoreVideo
import IOSurface

@MainActor
final class LockScreenSurface {
    let context: CAContext
    private let root: CALayer
    private(set) var currentImageSurface: IOSurface?

    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var frameTimer: Timer?
    private var loopObserver: NSObjectProtocol?

    /// Conservative on purpose — this plays behind an opaque lock screen nobody is looking at
    /// closely, and Wallwright's own efficiency positioning (near-0% idle CPU elsewhere in the
    /// app) argues against spending a full decode-rate timer on it. Raise only if it visibly
    /// stutters in real use.
    private static let frameInterval: TimeInterval = 1.0 / 12.0

    init(displayID: UInt32?, size: CGSize, scale: CGFloat) throws {
        context = try WallpaperPrivateRuntime.context(displayID: displayID)
        root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale
        root.contentsGravity = .resizeAspectFill
        context.layer = root
        CATransaction.flush()
    }

    /// Decodes `relativeImageName` (resolved against the exchange directory by
    /// `WallpaperPrivateRuntime.asset(_:)`, which already rejects path traversal) and installs it
    /// as this surface's content — both the live `root.contents` WallpaperAgent composites via the
    /// remote CAContext, and the cached `currentImageSurface` a later `snapshot` XPC call can
    /// answer from without redoing any decode work. Also used as `applyVideo`'s poster frame, and
    /// as `snapshot`'s answer even while video is playing — a live video frame is never cached for
    /// that purpose, since the poster is a perfectly representative cheap stand-in and avoids
    /// synchronizing with the frame timer from an XPC callout.
    func applyImage(relativeImageName: String) throws {
        stopVideo()
        let url = try WallpaperPrivateRuntime.asset(relativeImageName)
        guard let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw WallpaperPrivateRuntime.failure("Could not decode lock-screen image: \(relativeImageName)")
        }
        let surface = try Self.ioSurface(from: cgImage)
        currentImageSurface = surface
        installContents(surface)
    }

    /// Shows `relativePosterName` immediately (so there's never a blank frame while the video
    /// loads), then starts pulling live decoded frames from `relativeVideoName` once playback
    /// actually produces them. Muted unconditionally — matches every other "lock screen/
    /// background" decode path in this app (see `VideoWallpaperViewModel`), nobody expects sound
    /// from behind the lock screen. Loops via the same `AVPlayerItemDidPlayToEndTime` + seek-to-
    /// zero pattern already proven in `VideoWallpaperViewModel.swift`.
    func applyVideo(relativeVideoName: String, relativePosterName: String) throws {
        try applyImage(relativeImageName: relativePosterName)

        let videoURL = try WallpaperPrivateRuntime.asset(relativeVideoName)
        WallpaperPrivateRuntime.log("applyVideo: starting for \(relativeVideoName) at \(videoURL.path)")
        let item = AVPlayerItem(url: videoURL)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        item.add(output)
        videoOutput = output

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        self.player = player

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        // Only auto-play if the screen is ACTUALLY locked right now — `acquire` can be (and
        // confirmed live, 2026-10-29, routinely is) called while the Mac is sitting unlocked on
        // the normal desktop (WallpaperAgent bookkeeping/export, not real on-screen display).
        // `pauseVideo()`/`resumeVideo()` only react to the NEXT lock/unlock transition, so without
        // this check, a surface acquired while already unlocked would decode indefinitely with
        // nothing to ever tell it to stop. The poster frame from `applyImage` above stays showing
        // either way — nothing is visibly blank.
        if Self.isScreenCurrentlyLocked() {
            frameTimer?.invalidate()
            let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
                self?.pullVideoFrame()
            }
            frameTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            player.play()
        }
    }

    private var loggedFirstFrame = false
    private var pullAttempts = 0
    private var pullFailures = 0

    private func pullVideoFrame() {
        pullAttempts += 1
        guard let player, let item = player.currentItem, let output = videoOutput else {
            pullFailures += 1
            return
        }
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) else {
            pullFailures += 1
            if pullAttempts % 60 == 0 {
                WallpaperPrivateRuntime.log("pullVideoFrame: no new pixel buffer (attempts=\(pullAttempts) failures=\(pullFailures) time=\(time.seconds))")
            }
            return
        }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            pullFailures += 1
            WallpaperPrivateRuntime.log("pullVideoFrame: hasNewPixelBuffer true but copyPixelBuffer returned nil")
            return
        }
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            pullFailures += 1
            WallpaperPrivateRuntime.log("pullVideoFrame: pixel buffer has no IOSurface backing (format=\(CVPixelBufferGetPixelFormatType(pixelBuffer)))")
            return
        }
        if !loggedFirstFrame {
            loggedFirstFrame = true
            WallpaperPrivateRuntime.log("pullVideoFrame: first real frame installed (attempts=\(pullAttempts))")
        }
        installContents(surface)
    }

    private func installContents(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.contents = surface
        CATransaction.commit()
    }

    /// Point-in-time lock-state check, used only at `applyVideo`'s own startup decision — ongoing
    /// state changes are driven by the real Darwin lock/unlock notifications in
    /// `LockScreenController`, not by polling this. `CGSessionCopyCurrentDictionary` is a public
    /// CoreGraphics API (no private framework, no entitlement) that works the same from a sandboxed
    /// process.
    private static func isScreenCurrentlyLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Stops decoding without tearing the player down — unlike `stopVideo()`/`invalidate()`,
    /// resumable via `resumeVideo()`. Exists because WallpaperAgent itself doesn't invalidate this
    /// surface promptly on unlock — confirmed live (2026-10-28): it keeps an acquired surface alive
    /// for up to 5 minutes ("Scheduling disconnection for 5 minutes from now"), and without this,
    /// `frameTimer` kept pulling frames and `player` kept decoding via hardware VideoToolbox the
    /// entire time, on the normal unlocked desktop, for no one to see. `LockScreenController`
    /// drives this directly from the real Darwin lock/unlock notifications, not from WallpaperAgent's
    /// own (much coarser) acquire/invalidate lifecycle.
    func pauseVideo() {
        guard player != nil else { return }
        frameTimer?.invalidate()
        frameTimer = nil
        player?.pause()
    }

    /// Reverses `pauseVideo()`. A no-op if there's no video configured (image-only wallpaper) or
    /// it's already running.
    func resumeVideo() {
        guard player != nil, frameTimer == nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            self?.pullVideoFrame()
        }
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        player?.play()
    }

    /// Tears down the player/timer/observer — called before switching to a different content type
    /// and from `invalidate()`, so a rapid image/video toggle or a WallpaperAgent-initiated
    /// teardown never leaves a decode timer or observer running against a surface nobody reads
    /// from anymore.
    private func stopVideo() {
        frameTimer?.invalidate()
        frameTimer = nil
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        player?.pause()
        if let item = player?.currentItem, let videoOutput { item.remove(videoOutput) }
        videoOutput = nil
        player = nil
    }

    func invalidate() {
        stopVideo()
        context.invalidate()
    }

    /// CGImage → IOSurface, drawn directly into the surface's own backing memory (no intermediate
    /// CGImage-to-Data copy) — the same BGRA/premultiplied-first pixel layout
    /// `WallpaperPrivateRuntime.snapshotReply(_:)` hands back to WallpaperAgent unmodified.
    private static func ioSurface(from cgImage: CGImage) throws -> IOSurface {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw WallpaperPrivateRuntime.failure("Lock-screen image has invalid dimensions.")
        }
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let surface = IOSurface(properties: properties) else {
            throw WallpaperPrivateRuntime.failure("Could not allocate IOSurface for lock-screen image.")
        }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard
            let drawContext = CGContext(
                data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: surface.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else {
            throw WallpaperPrivateRuntime.failure("Could not create a draw context for the lock-screen image.")
        }
        drawContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return surface
    }
}

/// Owns every active surface (one per WallpaperAgent-issued id) and answers the XPC calls
/// `LockScreenExtension.swift` forwards to it. Much smaller than
/// `reference/WallpaperMachine/Extension/WallpaperController.swift`'s own controller — no
/// multi-scene replace-in-place logic, since Wallwright only ever has one configured wallpaper at
/// a time (M0/M1 force-select, no System Settings picker — see the approved plan's Phase 2,
/// deferred).
@MainActor
final class LockScreenController {
    static let shared = LockScreenController()
    private var surfaces: [UUID: LockScreenSurface] = [:]
    private var configuration: LockScreenExchangeConfig?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        reload()
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            darwinCenter, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<LockScreenController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { controller.reload() }
            }, LockScreenExchangeConfig.changedNotification as CFString, nil, .deliverImmediately
        )
        // Same ground-truth Darwin notifications `LockScreenSync.swift` listens to in the main
        // app — a sandboxed XPC extension can listen to these directly too, no entitlement needed.
        // Driving pause/resume from here instead of from WallpaperAgent's own acquire/invalidate
        // lifecycle is what actually stops decoding promptly on unlock — see `pauseVideo()`'s own
        // doc comment for why that lifecycle alone isn't enough.
        CFNotificationCenterAddObserver(
            darwinCenter, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<LockScreenController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { controller.pauseAll() }
            }, "com.apple.sessionagent.screenIsUnlocked" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            darwinCenter, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<LockScreenController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { controller.resumeAll() }
            }, "com.apple.sessionagent.screenIsLocked" as CFString, nil, .deliverImmediately
        )
    }

    private func pauseAll() {
        for surface in surfaces.values { surface.pauseVideo() }
        WallpaperPrivateRuntime.log("Screen unlocked — paused \(surfaces.count) surface(s)")
    }

    private func resumeAll() {
        for surface in surfaces.values { surface.resumeVideo() }
        WallpaperPrivateRuntime.log("Screen locked — resumed \(surfaces.count) surface(s)")
    }

    func reload() {
        let next = try? WallpaperPrivateRuntime.configuration()
        guard next != configuration else { return }
        configuration = next
        guard let next else {
            WallpaperPrivateRuntime.log("Configuration unavailable — no wallpaper to show.")
            return
        }
        for surface in surfaces.values { try? Self.apply(next, to: surface) }
        WallpaperPrivateRuntime.log("Configuration loaded revision=\(next.revision)")
    }

    /// M1 if `videoFileName` is set, M0's static image otherwise — the one place this branch is
    /// made, used by both `reload()` (an already-acquired surface picking up a new selection) and
    /// `acquire()` (a freshly created one).
    private static func apply(_ configuration: LockScreenExchangeConfig, to surface: LockScreenSurface) throws {
        if let videoFileName = configuration.videoFileName {
            try surface.applyVideo(relativeVideoName: videoFileName, relativePosterName: configuration.imageFileName)
        } else {
            try surface.applyImage(relativeImageName: configuration.imageFileName)
        }
    }

    func acquire(id value: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        do {
            guard let id = WallpaperPrivateRuntime.identifier(value), let request,
                let destination = WallpaperPrivateRuntime.field("destination", in: request),
                let size = WallpaperPrivateRuntime.field("size", in: destination) as? CGSize,
                let scale = WallpaperPrivateRuntime.field("scaleFactor", in: destination) as? CGFloat
            else {
                throw WallpaperPrivateRuntime.failure("Unsupported lock-screen creation request.")
            }
            let displayID = WallpaperPrivateRuntime.field("directDisplayID", in: destination) as? UInt32
            // Diagnostic — see WallpaperPrivateRuntime.describeFields's own doc comment. Removed
            // once it's established whether a screen-saver-context acquire carries a
            // distinguishing field this handler should branch on.
            WallpaperPrivateRuntime.log(
                "acquire request fields: \(WallpaperPrivateRuntime.describeFields(request))"
            )
            reload()
            guard let configuration else {
                throw WallpaperPrivateRuntime.failure("No Wallwright wallpaper is configured for the lock screen.")
            }
            let surface = try surfaces[id] ?? LockScreenSurface(displayID: displayID, size: size, scale: scale)
            try Self.apply(configuration, to: surface)
            surfaces[id] = surface
            let contextReply = try WallpaperPrivateRuntime.contextReply(surface.context.contextId)
            reply(contextReply, nil)
            WallpaperPrivateRuntime.log("Acquired id=\(id) display=\(displayID.map(String.init) ?? "nil")")
        } catch {
            WallpaperPrivateRuntime.log("Acquire failed: \(error.localizedDescription)")
            reply(nil, error)
        }
    }

    func update(id value: Any?, request: Any?) throws {
        guard let id = WallpaperPrivateRuntime.identifier(value), surfaces[id] != nil else {
            throw WallpaperPrivateRuntime.failure("Unknown lock-screen surface.")
        }
        // M0 has nothing per-update to change (one static image, no presentation/activity-driven
        // behavior yet) — accepting the call without error is enough for WallpaperAgent to
        // consider the surface alive.
    }

    func invalidate(id value: Any?) {
        guard let id = WallpaperPrivateRuntime.identifier(value) else { return }
        surfaces[id]?.invalidate()
        surfaces.removeValue(forKey: id)
    }

    func snapshot(id value: Any?, reply: @escaping (Any?, Error?) -> Void) {
        guard let id = WallpaperPrivateRuntime.identifier(value), let surface = surfaces[id],
            let imageSurface = surface.currentImageSurface
        else {
            reply(nil, WallpaperPrivateRuntime.failure("No lock-screen snapshot is available yet."))
            return
        }
        do {
            let snapshotReply = try WallpaperPrivateRuntime.snapshotReply(imageSurface)
            reply(snapshotReply, nil)
        } catch {
            reply(nil, error)
        }
    }
}

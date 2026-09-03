//
//  VideoWallpaperViewModel.swift
//  Wallwright
//
//  Created by Haren on 2023/8/14.
//

import AVKit
import CoreMedia
import SwiftUI
import Combine
import os
import VideoToolbox

/// Temporary diagnostic logging for the lock/screensaver "paused but not paused" bug — uses
/// `os.Logger` (not `print`) specifically so it's captured by the unified log and queryable via
/// `log show`/Console even when the app was launched normally (not attached to a debugger).
private let wallpaperDebugLog = Logger(subsystem: "com.wallwright.Wallwright", category: "VideoWallpaperDebug")

class VideoWallpaperViewModel: ObservableObject {
    var currentWallpaper: WEWallpaper {
        didSet {
            // Rebuilding the whole AVPlayerItem pipeline synchronously on every single assignment
            // meant rapidly changing wallpapers (spamming "Next Wallpaper") tore it down and
            // rebuilt it again on every intermediate selection, most of which get superseded within
            // milliseconds — wasted decode setup, and a plausible match for a live report
            // (2026-08-04) of a bright white "glare" appearing specifically during rapid switching:
            // `replaceCurrentItem` called again before the previous item ever produced a frame can
            // leave the video layer briefly blank, and the (separately confirmed legitimate) native
            // menu-bar-reveal blur would then be blurring that blank frame instead of real video
            // content. Debouncing so only the final selection in a rapid burst actually rebuilds
            // the pipeline avoids the wasted work regardless, and should eliminate the blank-frame
            // window if that theory is right.
            pendingWallpaperChangeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in self?.applyCurrentWallpaperChange() }
            pendingWallpaperChangeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }
    }

    private var pendingWallpaperChangeWorkItem: DispatchWorkItem?

    private func applyCurrentWallpaperChange() {
        didRetryCurrentItemAfterFailure = false
        swapInFreshItems()
        // Force-apply rate and volume — replaceCurrentItem resets both players to paused.
        // Reads `AppDelegate.shared.wallpaperViewModel.playRate` (the global source of truth), not
        // `self.playRate` — same stale-mirror race documented on `seedInitialFrameIfStartingPaused`
        // above: `VideoWallpaperView.updateNSView` assigns `viewModel.currentWallpaper` before it
        // reassigns `viewModel.playRate` in the same call, so `self.playRate` can still hold a
        // value from before the most recent slider/rate change at the exact moment this fires.
        // Confirmed live (2026-08-08): dragging Playback Rate to its max then immediately picking a
        // new wallpaper applied a stale intermediate rate instead of the one actually set.
        Self.apply(rate: AppDelegate.shared.wallpaperViewModel.playRate, to: player, audioPlayer)
        self.audioPlayer.volume = self.playVolume
        applyBatteryMode()
    }

    /// Builds a fresh video-only/audio-only item pair from `currentWallpaper`'s file and swaps
    /// them into `player`/`audioPlayer`, wiring up the end-of-play and playback-failure observers.
    /// Shared by the normal wallpaper-change path above and `retryAfterPlaybackFailure()` below —
    /// deliberately does NOT touch `didRetryCurrentItemAfterFailure` itself, since a retry needs
    /// this same swap without resetting the guard that bounds it to one attempt.
    @discardableResult
    private func swapInFreshItems() -> AVPlayerItem {
        // Explicit autorelease pool around the whole swap — confirmed live (2026-08-08) that
        // repeated wallpaper switches leave the process's resting footprint permanently elevated
        // even after the old item is replaced (a single switch measured a ~500MB transient spike,
        // and settled ~350MB above the pre-switch baseline afterward). Not a classic leak — `leaks`
        // finds nothing — but AVFoundation's ObjC APIs (`AVPlayerItem`, `AVURLAsset`,
        // `AVMutableComposition`) lean on autorelease, and creating a full new item + a composition
        // for the audio-only player every single switch is a lot of churn to leave for the run
        // loop's own pool to drain on its own schedule. Forcing it to drain deterministically right
        // here, instead of waiting, is a real, standard mitigation for exactly this pattern.
        var builtItem: AVPlayerItem!
        autoreleasepool {
            // Remove observer for old item before replacing
            if let oldItem = self.player.currentItem {
                NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
            }
            let url = currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file)
            let newItem = Self.videoOnlyItem(url: url)
            let newAudioItem = Self.audioOnlyItem(url: url)
            Self.applyTrimEnd(project: currentWallpaper.project, to: newItem, newAudioItem)
            self.player.replaceCurrentItem(with: newItem)
            seedInitialFrameIfStartingPaused(project: currentWallpaper.project, item: newItem)
            seedTrimStartIfNeeded(project: currentWallpaper.project, item: newItem)
            NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: newItem)
            self.audioPlayer.replaceCurrentItem(with: newAudioItem)
            observeForPlaybackFailure(item: newItem)
            builtItem = newItem
        }
        return builtItem
    }

    /// Guards against retrying a failed item forever if the file is genuinely unplayable (e.g.
    /// corrupted, or the undecodable-codec case `warnIfCodecMayNotDecode` already flags) — one
    /// retry per wallpaper is enough to recover from a transient failure (a flaky read on an
    /// external/network volume, the file briefly unavailable) without looping forever against a
    /// permanently broken one. Reset only when the wallpaper actually changes (in
    /// `applyCurrentWallpaperChange`/`init`), never by the retry itself.
    private var didRetryCurrentItemAfterFailure = false

    /// Cancels/replaces itself automatically when reassigned, same pattern as
    /// `pendingFrameSeekCancellable` — a status observer from a superseded item should never fire
    /// after a newer item replaces it.
    private var itemStatusCancellable: AnyCancellable?

    /// Posted once per screen, the first time that screen's very first wallpaper item produces a
    /// real decoded frame — `AppDelegate.setWallpaperWindows` waits for this (with a timeout
    /// fallback) before fading its window in, instead of guessing a fixed delay. `userInfo["screenId"]`
    /// carries which screen. See `observeFirstFrameReady` for the detection mechanism.
    static let didProduceFirstFrameNotification = Notification.Name("VideoWallpaperViewModel.didProduceFirstFrame")

    private var readinessVideoOutput: AVPlayerItemVideoOutput?
    private var readinessTimer: Timer?

    /// Detects when `item` has produced a real decoded frame — pattern from MirageWallpaper (a
    /// sibling macOS wallpaper engine in the same lineage as this app, reference/MirageWallpaper in
    /// this repo): attach a separate `AVPlayerItemVideoOutput` to the same item (doesn't interfere
    /// with the real rendering path — an item can have multiple outputs) and poll
    /// `hasNewPixelBuffer(forItemTime:)` against the item's own current time, rather than a fixed
    /// delay before revealing the wallpaper window. `.status == .readyToPlay` alone isn't enough —
    /// it means the item COULD start, not that a frame has actually been decoded yet. Bounded by a
    /// 2s timeout so a wallpaper that's slow or never produces a frame (corrupt file, thermal
    /// throttling) still eventually reveals instead of leaving the desktop blank forever. Only
    /// called from `init` — a later wallpaper switch (`swapInFreshItems`) doesn't need this, the
    /// window is already visible by then.
    private func observeFirstFrameReady(item: AVPlayerItem, screenId: String) {
        readinessTimer?.invalidate()
        if let oldOutput = readinessVideoOutput { item.remove(oldOutput) }

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        readinessVideoOutput = output

        let deadline = Date().addingTimeInterval(2)
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self, weak item] timer in
            guard let self, let item else { timer.invalidate(); return }
            let ready = output.hasNewPixelBuffer(forItemTime: item.currentTime())
            guard ready || Date() >= deadline else { return }
            timer.invalidate()
            item.remove(output)
            if self.readinessVideoOutput === output { self.readinessVideoOutput = nil }
            NotificationCenter.default.post(
                name: Self.didProduceFirstFrameNotification, object: nil, userInfo: ["screenId": screenId]
            )
        }
        readinessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// `.readyToPlay` only means the item COULD start — it says nothing about a later failure. A
    /// corrupt read, a dropped external/network volume, or the file being deleted out from under
    /// the player mid-playback all surface as a `.status` transition to `.failed`, and until this
    /// fix nothing observed that at all: the desktop would just silently freeze on whatever frame
    /// was last decoded, with nothing in the player's own state to explain why and no attempt to
    /// recover — the exact class of gap a deep dive into a sibling macOS wallpaper engine's own
    /// renderer-crash handling (2026-09-02) surfaced as unaddressed there too.
    private func observeForPlaybackFailure(item: AVPlayerItem) {
        itemStatusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, status == .failed, self.player.currentItem === item else { return }
                let reason = item.error?.localizedDescription ?? "unknown"
                guard !self.didRetryCurrentItemAfterFailure else {
                    wallpaperDebugLog.error("[\(self.screenId, privacy: .public)] wallpaper item failed again after retry (\(reason, privacy: .public)) — giving up, desktop stays on last good frame")
                    return
                }
                wallpaperDebugLog.error("[\(self.screenId, privacy: .public)] wallpaper item failed (\(reason, privacy: .public)) — retrying once")
                self.didRetryCurrentItemAfterFailure = true
                self.retryAfterPlaybackFailure()
            }
    }

    /// The recovery half of `observeForPlaybackFailure` — rebuilds the same wallpaper's items and
    /// swaps them back in. Uses `self.playRate`, not the global mirror `applyCurrentWallpaperChange`
    /// reads: this isn't a wallpaper switch racing a rate change, just recovering the one already
    /// playing, so the local value is already correct.
    private func retryAfterPlaybackFailure() {
        swapInFreshItems()
        Self.apply(rate: playRate, to: player, audioPlayer)
        self.audioPlayer.volume = self.playVolume
    }

    /// `.rate = 0` alone doesn't cancel AVPlayer's internal "waiting to minimize stalling" state —
    /// it can still auto-resume on its own afterward (e.g. once enough of the asset is buffered).
    /// `.pause()` actually cancels that, so every rate-0 case goes through it instead of the raw
    /// property.
    /// `audioPlayer` exists purely to keep audio playing without tying it to the video render
    /// pipeline (see its declaration) — but built from the plain file URL, its `AVPlayerItem`
    /// still has a video track, and VideoToolbox allocates a real hardware decoder session for it
    /// regardless of whether anything ever reads its samples. A first attempt at fixing this
    /// disabled the video track post-creation (`AVPlayerItemTrack.isEnabled = false`) — that does
    /// stop sample delivery/decode work, but confirmed live (2026-08-04) via a clean kill/relaunch
    /// test (killed Wallwright, watched its two `VTDecoderXPCService` processes disappear;
    /// relaunched, watched exactly two new ones spawn immediately for a single enabled screen) that
    /// a second full decoder *session* still gets allocated — the disable happens too late, after
    /// the item (and VideoToolbox's session for it) already exists. Building `audioPlayer`'s item
    /// from a composition containing only the audio track means VideoToolbox never sees a video
    /// track for this item in the first place, so no second session gets created at all. Falls back
    /// to the plain file URL if the asset has no audio track or composition setup fails, so a
    /// wallpaper's own file stays the ultimate source of truth.
    private static func audioOnlyItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            // A silent wallpaper has nothing for this player to contribute at all — falling back
            // to the full file here (as an earlier version of this fix did) would mean
            // `audioPlayer` decodes the entire video a second time for a file with no audio to
            // ever play, defeating the whole point. An item over a genuinely empty composition
            // has zero tracks, so nothing (video or audio) ever gets decoded for it.
            wallpaperDebugLog.notice("audioOnlyItem: no audio track found, using an empty (silent) item")
            return AVPlayerItem(asset: AVMutableComposition())
        }
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            wallpaperDebugLog.notice("audioOnlyItem: addMutableTrack failed, falling back to full URL")
            return AVPlayerItem(url: url)
        }
        do {
            try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
        } catch {
            wallpaperDebugLog.notice("audioOnlyItem: insertTimeRange failed (\(error.localizedDescription, privacy: .public)), falling back to full URL")
            return AVPlayerItem(url: url)
        }
        wallpaperDebugLog.notice("audioOnlyItem: composition built successfully, using audio-only item")
        return AVPlayerItem(asset: composition)
    }

    /// Builds `player`'s (the visual layer's) item with ONLY the video track — the mirror image
    /// of `audioOnlyItem` above. `player.isMuted = true` silences OUTPUT, not decode: an item built
    /// straight from the file URL still carries the audio track, so this player was decoding audio
    /// a second time for nothing on top of `audioPlayer`'s own real decode of the same content —
    /// confirmed live (2026-08-31) via `SystemUsageMonitor` showing real, sustained CPU well above
    /// what a single video decode + single audio decode should cost for a wallpaper with audio. A
    /// composition with just the video track means there's no audio track for this item to ever
    /// decode at all. `preferredTransform` is copied over explicitly — `AVMutableCompositionTrack`
    /// doesn't inherit the source track's rotation/orientation metadata on its own, and losing it
    /// would show some videos sideways or upside down. Falls back to the plain file URL if the
    /// asset has no audio track (nothing to strip) or composition setup fails.
    private static func videoOnlyItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            return AVPlayerItem(url: url)
        }
        warnIfCodecMayNotDecode(videoTrack: videoTrack, url: url)
        guard !asset.tracks(withMediaType: .audio).isEmpty else {
            // Already video-only — nothing to strip, no benefit to building a composition.
            return AVPlayerItem(url: url)
        }
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            wallpaperDebugLog.notice("videoOnlyItem: addMutableTrack failed, falling back to full URL")
            return AVPlayerItem(url: url)
        }
        do {
            try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
        } catch {
            wallpaperDebugLog.notice("videoOnlyItem: insertTimeRange failed (\(error.localizedDescription, privacy: .public)), falling back to full URL")
            return AVPlayerItem(url: url)
        }
        compositionTrack.preferredTransform = videoTrack.preferredTransform
        wallpaperDebugLog.notice("videoOnlyItem: composition built successfully, using video-only item")
        return AVPlayerItem(asset: composition)
    }

    /// VP8/VP9 have no AVFoundation decode path on macOS at all (hardware or software) — an item
    /// built from one can still reach `.readyToPlay` and even advance its own play head with
    /// nothing in the player's own status/error to explain it, producing a wallpaper that just
    /// looks like a frozen/black desktop with no diagnostic anywhere. AV1 support is real but
    /// hardware-dependent (only recent Apple Silicon), so it's checked dynamically via
    /// VideoToolbox rather than assumed either way. This is detection/logging only, not a fix —
    /// making the actual codec play would need transcoding, which is out of scope here.
    private static func warnIfCodecMayNotDecode(videoTrack: AVAssetTrack, url: URL) {
        guard let raw = videoTrack.formatDescriptions.first, let formatDescription = raw as! CMFormatDescription? else {
            return
        }
        let codec = CMFormatDescriptionGetMediaSubType(formatDescription)
        let fourCC = fourCCString(codec)
        switch fourCC {
        case "vp08", "vp09":
            wallpaperDebugLog.error("'\(url.lastPathComponent, privacy: .public)' uses video codec '\(fourCC, privacy: .public)' — macOS has no built-in decoder for this at all; this wallpaper will likely show as black/frozen despite playback appearing to run.")
        case "av01":
            guard !VTIsHardwareDecodeSupported(codec) else { return }
            wallpaperDebugLog.error("'\(url.lastPathComponent, privacy: .public)' uses video codec 'av01' (AV1) and this Mac has no hardware decoder for it — depending on macOS version this may fail to decode, showing as black/frozen despite playback appearing to run.")
        default:
            break
        }
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private static func apply(rate: Float, to players: AVPlayer...) {
        for player in players {
            if rate == 0 {
                player.pause()
            } else {
                player.rate = rate
            }
        }
    }

    /// Bounds a fresh pair of items to `project.trimEnd` (if set) — this is what makes
    /// `AVPlayerItemDidPlayToEndTime` fire at the trim point instead of the file's real end. Set on
    /// both the video and audio items so audio can't drift past the cut point before the next
    /// loop-restart resyncs it. A no-op (whole file plays) when `trimEnd` is nil, same as before
    /// trimming existed.
    private static func applyTrimEnd(project: WEProject, to items: AVPlayerItem...) {
        guard let trimEnd = project.trimEnd, trimEnd > 0 else { return }
        let end = CMTime(seconds: trimEnd, preferredTimescale: 600)
        for item in items {
            item.forwardPlaybackEndTime = end
        }
    }

    private var isOnBattery = false {
        didSet { applyBatteryMode() }
    }

    /// Caps decode resolution on battery power — meaningfully less GPU/CPU work per frame for a
    /// background wallpaper that's never the focus of attention anyway. `preferredPeakBitRate`
    /// used to be set alongside this, but it's an HTTP Live Streaming adaptive-bitrate hint —
    /// AVFoundation only consults it when choosing between multiple bitrate variants of a
    /// *streamed* asset, which never applies here since every wallpaper is a plain local file with
    /// exactly one bitrate to begin with. It was silently doing nothing; removed rather than left
    /// in place implying a battery saving that wasn't real.
    ///
    /// Plugged in previously meant fully uncapped (`.zero`) — decoding at the *source file's*
    /// native resolution regardless of what the actual screen can display. Confirmed live
    /// (2026-08-08): this Mac's built-in display is 3024×1964, not 4K, so a 3840×2160 wallpaper was
    /// being decoded at ~40% more pixels than could ever actually be shown, every frame, all the
    /// time, not just on battery. Now always capped to the real screen's native pixel resolution
    /// (accounting for Retina backing scale); the on-battery path caps further to 1080p on top of
    /// that. Neither path reduces visible quality — pixels beyond what the screen can show were
    /// always imperceptible, just decoded and buffered for nothing.
    private func applyBatteryMode() {
        let native = nativeScreenResolution()
        let cap: CGSize
        if isOnBattery {
            let batteryCeiling = CGSize(width: 1920, height: 1080)
            cap = CGSize(
                width: min(native?.width ?? batteryCeiling.width, batteryCeiling.width),
                height: min(native?.height ?? batteryCeiling.height, batteryCeiling.height)
            )
        } else {
            cap = native ?? .zero
        }
        player.currentItem?.preferredMaximumResolution = cap
    }

    /// This wallpaper's actual screen, by pixel resolution (native size × Retina backing scale) —
    /// decoding beyond this is pure waste, nothing can display more pixels than the screen has.
    /// `nil` if the screen can't currently be resolved (e.g. mid display-reconfiguration), in which
    /// case callers fall back to uncapped rather than guessing a wrong resolution.
    private func nativeScreenResolution() -> CGSize? {
        guard let screen = NSScreen.screens.first(where: { WallpaperViewModel.screenId(for: $0) == screenId }) else {
            return nil
        }
        let scale = screen.backingScaleFactor
        return CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
    }

    /// Seeks `player` to `project.thumbnailTimestamp` once its item is ready to play, but ONLY
    /// when the wallpaper is starting already paused (e.g. the "pause on battery" policy) — left
    /// alone otherwise, so a normally-playing wallpaper still starts from time 0 as always.
    /// Deliberately reads `AppDelegate.shared.wallpaperViewModel.playRate` (the global source of
    /// truth) rather than `self.playRate`: `VideoWallpaperView.updateNSView` assigns
    /// `viewModel.currentWallpaper` (triggering this) before it reassigns `viewModel.playRate` in
    /// the same call, so `self.playRate` can still hold the outgoing wallpaper's stale value at
    /// the exact moment this fires. Called only from `init` and `currentWallpaper`'s `didSet` —
    /// never from `playRate`'s own `didSet` — so a manual pause mid-playback never jumps the frame.
    private func seedInitialFrameIfStartingPaused(project: WEProject, item: AVPlayerItem) {
        guard AppDelegate.shared.wallpaperViewModel.playRate == 0,
              let timestamp = project.thumbnailTimestamp, timestamp > 0
        else {
            pendingFrameSeekCancellable = nil
            return
        }

        let target = CMTime(seconds: timestamp, preferredTimescale: 600)
        pendingFrameSeekCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .filter { $0 == .readyToPlay }
            .first()
            .sink { [weak self] _ in
                guard let self, self.player.currentItem === item else { return }
                self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
    }

    /// Seeks to `project.trimStart` once the item is ready — the starting-position half of
    /// trimming (`applyTrimEnd` above is the bound-the-end half). Skipped when starting already
    /// paused with a `thumbnailTimestamp` set: that case keeps owning "what frame to freeze on,"
    /// unchanged; trim's start otherwise governs where a *playing* wallpaper begins. Called
    /// alongside `seedInitialFrameIfStartingPaused` from `init` and `currentWallpaper`'s `didSet`.
    private func seedTrimStartIfNeeded(project: WEProject, item: AVPlayerItem) {
        let startingPausedWithChosenFrame = AppDelegate.shared.wallpaperViewModel.playRate == 0
            && project.thumbnailTimestamp != nil
        guard !startingPausedWithChosenFrame,
              let trimStart = project.trimStart, trimStart > 0
        else {
            pendingTrimSeekCancellable = nil
            return
        }

        let target = CMTime(seconds: trimStart, preferredTimescale: 600)
        pendingTrimSeekCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .filter { $0 == .readyToPlay }
            .first()
            .sink { [weak self] _ in
                guard let self, self.player.currentItem === item else { return }
                self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                self.audioPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
    }

    var playRate: Float = 0 {
        didSet { Self.apply(rate: playRate, to: player, audioPlayer) }
    }

    var playVolume: Float = 0 {
        didSet {
            self.audioPlayer.volume = playVolume
        }
    }

    /// Muted always — this player exists purely for visual rendering now. See `audioPlayer`.
    var player = AVPlayer()

    /// A second, fully independent player for the same file, with no `AVPlayerLayer`/`AVPlayerView`
    /// ever attached to it — this is what actually produces sound now, not `player`.
    ///
    /// Confirmed via direct log analysis (2026-07-25): `AVPlayerView`'s combined video+audio
    /// pipeline throws a cascade of internal errors (`FigAirPlay_Route`, `VRP` — video rendering
    /// pipeline) specifically after a lock/unlock cycle, and audio silently stops even though
    /// video keeps rendering. Since a plain `AVPlayer` with no view attached has no video
    /// rendering pipeline to speak of, it's immune to whatever's going wrong there — this plays
    /// audio the same way Spotify does: as a background process with no tie to any window or
    /// visual surface, so window occlusion/lock state can't touch it.
    var audioPlayer = AVPlayer()

    private var cancellables = Set<AnyCancellable>()

    /// Set by `VideoWallpaperView.makeNSView` right after creation. Needed so a lock/unlock cycle
    /// can force AVKit to rebuild its internal render pipeline (see `reattachPlayerLayer`) — `weak`
    /// since the NSView, not this view model, owns the lifetime.
    weak var playerView: AVPlayerView?

    /// Cancels/replaces itself automatically when reassigned — so a superseded seed-frame seek
    /// from a prior wallpaper (if the user flips wallpapers quickly) never lands after a newer
    /// item replaces it. See `seedInitialFrameIfStartingPaused`.
    private var pendingFrameSeekCancellable: AnyCancellable?

    /// Same cancel/replace-on-reassignment behavior as `pendingFrameSeekCancellable`, for the trim
    /// start seek. See `seedTrimStartIfNeeded`.
    private var pendingTrimSeekCancellable: AnyCancellable?

    /// Debounces `reattachPlayerLayer` — `systemDidWake` and `screenDidUnlock` both call it, and on
    /// a real lock/sleep/wake/unlock cycle both notifications fire (confirmed live, 2026-08-21: a
    /// wake logged at 18:48:42.154, the matching unlock at 18:48:43.621 — 1.47s apart) for what's a
    /// single "the user is back" event, running the full nil-then-reassign teardown/rebuild twice in
    /// a row for nothing. Whichever trigger fires first already does the real fix; the second is
    /// pure waste.
    private var lastReattachAt = Date.distantPast

    /// Which screen this instance renders for — needed so `playerDidFinishPlaying` can tell
    /// whether it's the one "driving" screen a global playlist advance should be decided from
    /// (see `PlaylistViewModel.drivingScreenId`), rather than every screen independently deciding.
    let screenId: String

    init(wallpaper currentWallpaper: WEWallpaper, screenId: String) {
        self.screenId = screenId
        self.currentWallpaper = currentWallpaper
        let url = currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file)
        // `videoOnlyItem`, not a plain `AVPlayer(url:)` — see its own doc comment. Building
        // straight from the file URL here (init only runs once, for the very first wallpaper
        // shown on this screen at launch) reintroduced the exact double-audio-decode bug already
        // fixed in `applyCurrentWallpaperChange` for every subsequent wallpaper switch — confirmed
        // live (2026-08-31) this was a second, separate construction path for the same player.
        self.player = AVPlayer(playerItem: Self.videoOnlyItem(url: url))
        self.player.isMuted = true
        self.audioPlayer = AVPlayer(playerItem: Self.audioOnlyItem(url: url))
        if let item = self.player.currentItem {
            if let audioItem = self.audioPlayer.currentItem {
                Self.applyTrimEnd(project: currentWallpaper.project, to: item, audioItem)
            } else {
                Self.applyTrimEnd(project: currentWallpaper.project, to: item)
            }
            seedInitialFrameIfStartingPaused(project: currentWallpaper.project, item: item)
            seedTrimStartIfNeeded(project: currentWallpaper.project, item: item)
            observeForPlaybackFailure(item: item)
            observeFirstFrameReady(item: item, screenId: screenId)
        }
        // `preventsDisplaySleepDuringVideoPlayback` defaults to true on macOS — AVFoundation
        // treats an actively-playing video as something the user is watching and wants the
        // display kept awake for. A wallpaper plays continuously by design, so left at the
        // default this would silently defeat the system's own "turn display off after N minutes
        // of inactivity" setting entirely for as long as Wallwright is running, which in turn
        // means the "displayAsleep" pause policy could rarely even get a chance to fire (the
        // display could never *reach* asleep from idle timeout in the first place). Confirmed via
        // direct grep this was never set anywhere in the codebase before this fix.
        self.player.preventsDisplaySleepDuringVideoPlayback = false
        self.audioPlayer.preventsDisplaySleepDuringVideoPlayback = false
        // Local file playback shouldn't wait to buffer ahead before starting/resuming — waiting
        // is what produces a one-frame black flash right at a loop boundary or after a pause.
        self.player.automaticallyWaitsToMinimizeStalling = false
        self.audioPlayer.automaticallyWaitsToMinimizeStalling = false
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: self.player.currentItem)
        // Paired with screensDidSleep, not willSleep/didWake (system-sleep-only notifications) —
        // screensDidSleep also fires for plain display-idle-sleep with the system still fully
        // awake (e.g. "prevent sleep when display is off" while plugged in), which is common and
        // was the actual gap here: pausing correctly on screensDidSleep but only ever resuming on
        // full *system* wake left playback stuck paused forever after a display-only sleep/wake
        // cycle that never involved the system itself sleeping.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        // Switching macOS Spaces occludes then re-reveals the wallpaper window (it's stationary
        // and joined to all Spaces, so the window itself isn't recreated, but AVFoundation's
        // playback pipeline can quietly resume on its own once visibility returns — confirmed
        // live: pausing, then switching Spaces and back, silently un-paused it). Re-asserting the
        // intended rate on every occlusion change (any window's, not just this one — cheap and
        // idempotent either way) closes that gap the same way systemDidWake already does for sleep.
        NotificationCenter.default.addObserver(self, selector: #selector(windowOcclusionStateDidChange), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        // Primary, reliable trigger for the reattach fix — see `LockScreenSync.screenDidUnlockNotification`'s
        // doc comment for why `NSWindow.occlusionState` alone isn't trustworthy for this window.
        NotificationCenter.default.addObserver(self, selector: #selector(screenDidUnlock), name: LockScreenSync.screenDidUnlockNotification, object: nil)

        isOnBattery = BatteryMonitor.shared.isOnBattery
        applyBatteryMode()
        BatteryMonitor.shared.startIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(powerSourceDidChange), name: BatteryMonitor.powerSourceDidChange, object: nil)

        // Directly observe playRate/playVolume changes from the shared WallpaperViewModel
        let wvm = AppDelegate.shared.wallpaperViewModel
        wvm.$playRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.playRate = rate
            }
            .store(in: &cancellables)
        wvm.$playVolume
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in
                self?.playVolume = volume
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        readinessTimer?.invalidate()
    }

    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        // Only the one "driving" screen (see PlaylistViewModel.drivingScreenId) gets to decide
        // whether a global playlist advance happens here — every other screen just falls through
        // to its normal loop below, and picks up the new wallpaper on the next SwiftUI update once
        // WallpaperViewModel.wallpapers actually changes (same path any other wallpaper change
        // already takes). If it DOES advance, a new wallpaper is already on its way in via
        // `currentWallpaper`'s own didSet, so skip re-looping this now-stale item entirely.
        let isDriving = screenId == AppDelegate.shared.playlistViewModel.drivingScreenId
        if isDriving, AppDelegate.shared.playlistViewModel.mainScreenLoopEnded() {
            return
        }

        // Replay video — driven off the video player's own end-of-play notification, since both
        // items are the same source file and reach the end together; re-seek/restart the audio
        // player alongside it to keep the two in sync each loop. Loops back to `trimStart` when
        // set (the notification itself already fires at `trimEnd` instead of the file's real end,
        // via `applyTrimEnd`'s `forwardPlaybackEndTime`) rather than always the file's actual start.
        let restartTime = currentWallpaper.project.trimStart.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .zero
        self.player.seek(to: restartTime)
        self.audioPlayer.seek(to: restartTime)
        Self.apply(rate: playRate, to: player, audioPlayer)
    }

    @objc private func playerDidStopPlaying(_ notification: Notification) {
        // Resume playback
        Self.apply(rate: playRate, to: player, audioPlayer)
    }

    @objc func systemWillSleep(_ notification: Notification) {
        wallpaperDebugLog.notice("[\(self.screenId, privacy: .public)] systemWillSleep (screensDidSleep) fired")
        Self.apply(rate: 0, to: player, audioPlayer)
    }

    @objc private func powerSourceDidChange(_ notification: Notification) {
        isOnBattery = BatteryMonitor.shared.isOnBattery
    }

    /// Fires on `LockScreenSync.screenDidUnlockNotification` — the reliable ground-truth signal
    /// for a real unlock. Unconditional (no elapsed-time gating like `windowOcclusionStateDidChange`
    /// needs): this notification only ever posts on an actual unlock, never on a Space-switch or
    /// other transient blip, so there's no "was this just a blip" ambiguity to guard against here.
    @objc private func screenDidUnlock(_ notification: Notification) {
        wallpaperDebugLog.notice("[\(self.screenId, privacy: .public)] screenDidUnlock notification — reattaching unconditionally")
        reattachPlayerLayer()
    }

    @objc func systemDidWake(_ notification: Notification) {
        wallpaperDebugLog.notice("[\(self.screenId, privacy: .public)] systemDidWake (screensDidWake) fired — playRate=\(self.playRate), player.rate=\(self.player.rate), timeControlStatus=\(self.player.timeControlStatus.rawValue)")
        Self.apply(rate: playRate, to: player, audioPlayer)
        // Full system sleep/wake (lid close, or a long enough display sleep) is exactly the kind of
        // suspension that wedges AVPlayerView's render pipeline the same way lock/unlock does — see
        // `reattachPlayerLayer`.
        reattachPlayerLayer()
    }

    @objc private func windowOcclusionStateDidChange(_ notification: Notification) {
        Self.apply(rate: playRate, to: player, audioPlayer)

        // The rate-reassertion above (any window, not just ours) is cheap/idempotent and is all a
        // normal desktop/Space switch actually needs — confirmed live (2026-07-30) it alone was
        // already enough for playback to quietly resume on its own after one.
        //
        // This used to ALSO call the disruptive `reattachPlayerLayer()` (nil-then-reassign
        // `AVPlayerView.player`, which unavoidably blanks the layer for a frame) once occlusion had
        // lasted >= 2s, on the theory that a real lock screen lasts much longer than a quick Space
        // blip. That theory was wrong in practice: confirmed live (2026-07-31) via
        // `[1] became visible after 16.33s`/`24.63s — calling reattachPlayerLayer()` entries that
        // lined up with nothing but ordinary desktop-switching (no lock/unlock, no sleep in that
        // window) — an entirely normal few-seconds-to-tens-of-seconds visit to another desktop
        // easily clears a 2s bar, so this fired, and forced a visible black flash, on almost every
        // real switch. There's no duration that reliably separates "quick Space blip" from "normal
        // desktop visit" — both routinely span the same few-second-to-a-minute range — so gating on
        // elapsed occlusion time here doesn't work. The genuine lock-screen case this was guarding
        // against is fully covered by `screenDidUnlock` below, which fires unconditionally off
        // `LockScreenSync`'s ground-truth Darwin notification, not off occlusion timing at all — so
        // nothing is lost by no longer also trying (and misfiring) here.
        guard let ownWindow = playerView?.window else { return }
        let isVisible = ownWindow.occlusionState.contains(.visible)
        wallpaperDebugLog.notice("[\(self.screenId, privacy: .public)] occlusionStateDidChange (checking own window directly) — visible=\(isVisible)")
    }

    /// Detaches and reattaches the player from its `AVPlayerView` to force AVKit to rebuild its
    /// internal render pipeline. Confirmed via live log analysis (2026-07-29): after a lock/unlock
    /// cycle, `player.rate` reports 1.0 (AVFoundation thinks it's playing) but the IQ-CA compositing
    /// layer shows `displayed: 0` against hundreds of `enqueued` frames — the pipeline is wedged,
    /// not paused, so re-asserting `.rate` (which only ever toggles play/pause state) does nothing.
    /// Nil-ing `AVPlayerView.player` and reassigning it forces a fresh render connection instead.
    private func reattachPlayerLayer() {
        guard let view = playerView else {
            wallpaperDebugLog.notice("[\(self.screenId, privacy: .public)] reattachPlayerLayer called but playerView is nil")
            return
        }
        // See `lastReattachAt`'s doc comment — collapses the wake+unlock double-fire into one run.
        let now = Date()
        guard now.timeIntervalSince(lastReattachAt) > 2 else {
            wallpaperDebugLog.notice("[\(self.screenId, privacy: .public)] reattachPlayerLayer skipped — already ran \(now.timeIntervalSince(self.lastReattachAt), format: .fixed(precision: 2))s ago")
            return
        }
        lastReattachAt = now
        wallpaperDebugLog.notice("[\(self.screenId, privacy: .public)] reattachPlayerLayer RUNNING — before: rate=\(self.player.rate), timeControlStatus=\(self.player.timeControlStatus.rawValue)")
        view.player = nil
        view.player = player
        Self.apply(rate: playRate, to: player, audioPlayer)
        wallpaperDebugLog.notice("[\(self.screenId, privacy: .public)] reattachPlayerLayer DONE — after: rate=\(self.player.rate), timeControlStatus=\(self.player.timeControlStatus.rawValue)")
    }
}

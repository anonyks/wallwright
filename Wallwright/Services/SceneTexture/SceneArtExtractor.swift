//
//  SceneArtExtractor.swift
//  Wallwright
//
//  Tries to pull the real background artwork out of a scene's own scene.pkg, instead of settling
//  for the small bundled preview image. Confirmed live against 4 real downloaded Workshop scenes
//  (2026-10-05): 2 had a directly-decodable embedded JPEG/PNG texture, 1 needed the DXT5 decoder
//  (TEXTexture.swift), 1 needed a video-frame grab (its "texture" was a literal embedded MP4).
//  This never throws: any failure (no .pkg, no usable candidate, corrupt data) just means the
//  caller falls back to the preview-based path in SceneFallback.swift, unchanged.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation

enum SceneArtExtractor {
    struct Extracted {
        let jpegData: Data
        let width: Int
        let height: Int
    }

    /// One successfully-decoded candidate background texture, for `extractCandidates` below.
    struct Candidate {
        let extracted: Extracted
        /// See `SceneTextureCandidate.isLikelyBackground` — carried through so the caller can
        /// present the most-plausible candidate first without re-deriving the signal.
        let isLikelyBackground: Bool
    }

    /// First-successful-decode convenience, used wherever nothing asked the user to choose
    /// between candidates (the manual-folder-drop and .zip import paths, and as the fallback when
    /// `extractCandidates` found nothing or a review was skipped). Equivalent to taking the first
    /// element `extractCandidates` would have returned.
    static func extract(directory: URL) async -> Extracted? {
        await extractCandidates(directory: directory, limit: 1).first?.extracted
    }

    /// Decodes every plausible background-art candidate in the scene (not just the first that
    /// works), most-likely-background first, so a caller can show the user a picker instead of
    /// silently committing to whichever texture happened to resolve first. `limit` caps how many
    /// are actually decoded — real scenes can bundle dozens of textures (particle sprites, UI
    /// chrome, masks), and decoding all of them (DXT block-decompression, LZ4, embedded-video
    /// frame grabs) for a one-time import review isn't worth the wait past a reasonable choice set.
    static func extractCandidates(directory: URL, limit: Int = 8) async -> [Candidate] {
        // Always "scene.pkg" on disk, regardless of project.file: that field holds the scene's
        // logical entry point ("scene.json"), which is itself an entry *inside* this archive, not
        // the archive's own filename. Confirmed against every real downloaded scene this session
        // and against MacWall's own SceneRenderer (Scene.swift), which hardcodes the same name.
        let pkgURL = directory.appending(path: "scene.pkg")
        guard FileManager.default.fileExists(atPath: pkgURL.path),
              let archive = try? PKGArchive(url: pkgURL)
        else { return [] }

        var results: [Candidate] = []
        // Two objects can legitimately reference the same texture file (e.g. a repeated tiling
        // element) — no point offering the user the same image twice.
        var seenPaths = Set<String>()
        for candidate in SceneTextureResolver.candidateTexturePaths(in: archive) {
            guard results.count < limit else { break }
            guard !seenPaths.contains(candidate.path) else { continue }
            seenPaths.insert(candidate.path)
            guard let textureData = archive[candidate.path] else { continue }
            do {
                // Decoding a DXT/embedded-image texture and converting it to JPEG runs several
                // CoreGraphics/ImageIO calls that create autoreleased intermediates (CGDataProvider,
                // NSBitmapImageRep's own representation encode, ...) — without an explicit pool,
                // those only drain once this whole async function returns, not per loop iteration,
                // so up to `limit` full-resolution decodes' worth of intermediates can be resident
                // at once for a scene with many candidate textures.
                let extracted: Extracted? = try autoreleasepool {
                    let texture = try TEXTexture(data: textureData)
                    return cgImage(
                        fromRGBA: texture.rgba,
                        width: texture.width,
                        height: texture.height,
                        imageWidth: texture.imageWidth,
                        imageHeight: texture.imageHeight
                    )
                }
                guard let extracted else { continue }
                results.append(Candidate(extracted: extracted, isLikelyBackground: candidate.isLikelyBackground))
            } catch SceneTextureFormatError.videoPayload(let mp4Data) {
                if let extracted = await frameFromVideo(mp4Data) {
                    results.append(Candidate(extracted: extracted, isLikelyBackground: candidate.isLikelyBackground))
                }
            } catch {
                continue
            }
        }
        return results
    }

    private static func cgImage(
        fromRGBA rgba: Data,
        width: Int,
        height: Int,
        imageWidth: Int = 0,
        imageHeight: Int = 0
    ) -> Extracted? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: rgba as CFData),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }

        // Textures in Wallpaper Engine are often power-of-two or block-padded. If `imageWidth`/
        // `imageHeight` declare a smaller true image size, crop off the trailing padding so the
        // wallpaper doesn't render with empty borders.
        let finalImage: CGImage
        if imageWidth > 0 && imageHeight > 0 && (imageWidth < width || imageHeight < height) {
            finalImage = cgImage.cropping(to: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)) ?? cgImage
        } else {
            finalImage = cgImage
        }

        let outW = finalImage.width
        let outH = finalImage.height
        guard let jpegData = NSImage(cgImage: finalImage, size: NSSize(width: outW, height: outH)).jpegData else { return nil }
        return Extracted(jpegData: jpegData, width: outW, height: outH)
    }

    /// Same AVAssetImageGenerator convention already used across the app (VideoImporter.swift,
    /// AerialsInjector.swift): appliesPreferredTrackTransform, grab at time zero.
    /// Does not restrict `maximumSize`, preserving native full resolution (e.g. 4K) for the
    /// wallpaper image file; `SceneFallback` generates the smaller `preview.jpg` thumbnail via
    /// `ThumbnailDownsampler` separately.
    private static func frameFromVideo(_ mp4Data: Data) async -> Extracted? {
        let tempURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard (try? mp4Data.write(to: tempURL)) != nil else { return nil }

        let asset = AVURLAsset(url: tempURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        guard let cgImage = try? await generator.image(at: .zero).image,
              let jpegData = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)).jpegData
        else { return nil }
        return Extracted(jpegData: jpegData, width: cgImage.width, height: cgImage.height)
    }
}

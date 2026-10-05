//
//  TEXTexture.swift
//  Wallwright
//
//  Decodes a Wallpaper Engine .tex texture container: RGBA8888/RG88/R8 direct, DXT1/DXT3/DXT5
//  block-compressed, or an embedded JPEG/PNG ("FreeImage" container), with LZ4 decompression via
//  Apple's own Compression framework.
//
//  Adapted from MacWall (MIT License, Copyright (c) 2026 Emidolo)
//  https://github.com/Emidolo/MacWall
//
//  One deliberate change from the original: its video-texture detection just threw and discarded
//  the bytes. SceneFallback needs them (to hand to AVAssetImageGenerator for a still frame), so
//  that path now throws SceneTextureFormatError.videoPayload(Data) carrying the raw MP4 bytes
//  instead of SceneTextureFormatError.unsupported("video texture").
//

import Compression
import CoreGraphics
import Foundation
import ImageIO

/// A decoded Wallpaper Engine .tex texture: mip 0 of the first image as straight RGBA8. The image
/// occupies the top-left imageWidth x imageHeight of the width x height buffer (textures are
/// padded, usually to powers of two).
struct TEXTexture {
    enum Format: Int32 { case rgba8888 = 0, dxt5 = 4, dxt3 = 6, dxt1 = 7, rg88 = 8, r8 = 9 }

    let format: Format
    let flags: UInt32
    let width: Int, height: Int
    let imageWidth: Int, imageHeight: Int
    let rgba: Data

    init(data: Data) throws {
        var r = SceneByteReader(data)
        let magic = try r.cString(max: 16)
        guard magic == "TEXV0005" else { throw SceneTextureFormatError.badMagic(magic) }
        let info = try r.cString(max: 16)
        guard info == "TEXI0001" else { throw SceneTextureFormatError.badMagic(info) }
        let rawFormat = try r.i32()
        guard let format = Format(rawValue: rawFormat) else { throw SceneTextureFormatError.unsupported("texture format \(rawFormat)") }
        self.format = format
        flags = try r.u32()
        _ = try r.bytes(8)  // padded texture size; mip 0 carries the same for raw formats
        imageWidth = Int(try r.u32())
        imageHeight = Int(try r.u32())
        _ = try r.u32()

        let container = try r.cString(max: 16)
        guard ["TEXB0001", "TEXB0002", "TEXB0003", "TEXB0004"].contains(container) else { throw SceneTextureFormatError.badMagic(container) }
        let imageCount = try r.u32()
        guard imageCount > 0 else { throw SceneTextureFormatError.truncated }
        var freeImageFormat: Int32 = -1
        if container == "TEXB0003" || container == "TEXB0004" { freeImageFormat = try r.i32() }
        if container == "TEXB0004" {
            // Conditional-patch table (open-wallpaper-engine's reading); patches apply to later data we skip.
            for _ in 0..<(try r.u32()) {
                _ = try r.bytes(12)
                _ = try r.cString(max: 1 << 16)
            }
        }
        if freeImageFormat == 35 || flags & 32 != 0 {
            // Video texture, but we don't yet know where the payload starts relative to our
            // reader without continuing to parse past the mip/LZ4 header below, same as the
            // non-video path does, then returning those bytes instead of decoding them as pixels.
            let videoBytes = try Self.remainingPayloadBytes(&r, container: container)
            throw SceneTextureFormatError.videoPayload(videoBytes)
        }

        guard try r.u32() > 0 else { throw SceneTextureFormatError.truncated }  // mipmap count
        let mipW = Int(try r.u32()), mipH = Int(try r.u32())
        var lz4 = false, rawSize = 0
        if container != "TEXB0001" {
            lz4 = try r.u32() == 1
            rawSize = Int(try r.u32())
        }
        var bytes = try r.bytes(Int(try r.u32()))
        if lz4 { bytes = try Self.lz4(bytes, size: rawSize) }

        if bytes.count > 8, bytes[bytes.startIndex + 4..<bytes.startIndex + 8] == Data("ftyp".utf8) {
            throw SceneTextureFormatError.videoPayload(bytes)
        }
        // Some newer files embed a PNG/JPEG while declaring format -1, so sniff too.
        if freeImageFormat != -1 || bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) || bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            (width, height, rgba) = try Self.decodeImageFile(bytes)
        } else {
            guard mipW > 0, mipH > 0, mipW * mipH <= 16384 * 16384 else { throw SceneTextureFormatError.unsupported("size \(mipW)x\(mipH)") }
            (width, height) = (mipW, mipH)
            rgba = try Self.decode(bytes, format: format, width: mipW, height: mipH)
        }
    }

    init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    // MARK: - Video payload extraction

    /// Mirrors the non-video path's own header walk (mip count/size, LZ4 flag, raw/compressed
    /// size) just far enough to slice out the payload bytes, decompressing them if needed, same
    /// as the pixel path does, but returning the bytes untouched instead of decoding them.
    private static func remainingPayloadBytes(_ r: inout SceneByteReader, container: String) throws -> Data {
        guard try r.u32() > 0 else { throw SceneTextureFormatError.truncated }
        _ = try r.u32(); _ = try r.u32()  // mip width/height, unused for a video payload
        var lz4 = false, rawSize = 0
        if container != "TEXB0001" {
            lz4 = try r.u32() == 1
            rawSize = Int(try r.u32())
        }
        let bytes = try r.bytes(Int(try r.u32()))
        return lz4 ? try Self.lz4(bytes, size: rawSize) : bytes
    }

    // MARK: - Decoding

    static func lz4(_ src: Data, size: Int) throws -> Data {
        guard size > 0, size < 1 << 30 else { throw SceneTextureFormatError.truncated }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard n == size else { throw SceneTextureFormatError.truncated }
        return out
    }

    static func decode(_ src: Data, format: Format, width w: Int, height h: Int) throws -> Data {
        let s = [UInt8](src)
        switch format {
        case .rgba8888:
            guard s.count >= w * h * 4 else { throw SceneTextureFormatError.truncated }
            return Data(s[0..<w * h * 4])
        case .rg88, .r8:
            // RG88 = luminance + alpha (as sampled "rrrg" on the GPU); R8 = opaque greyscale.
            let bpp = format == .rg88 ? 2 : 1
            guard s.count >= w * h * bpp else { throw SceneTextureFormatError.truncated }
            var out = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0..<w * h {
                let l = s[i * bpp]
                out[4 * i] = l; out[4 * i + 1] = l; out[4 * i + 2] = l
                if bpp == 2 { out[4 * i + 3] = s[i * 2 + 1] }
            }
            return Data(out)
        case .dxt1, .dxt3, .dxt5:
            return try decodeDXT(s, format: format, width: w, height: h)
        }
    }

    private static func decodeDXT(_ s: [UInt8], format: Format, width w: Int, height h: Int) throws -> Data {
        let blockSize = format == .dxt1 ? 8 : 16
        let bw = (w + 3) / 4, bh = (h + 3) / 4
        guard s.count >= bw * bh * blockSize else { throw SceneTextureFormatError.truncated }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for by in 0..<bh {
            for bx in 0..<bw {
                let o = (by * bw + bx) * blockSize
                let colorOffset = format == .dxt1 ? o : o + 8
                let colors = dxtColors(s, colorOffset, allowPunchThrough: format == .dxt1)
                let indices = UInt32(s[colorOffset + 4]) | UInt32(s[colorOffset + 5]) << 8
                    | UInt32(s[colorOffset + 6]) << 16 | UInt32(s[colorOffset + 7]) << 24
                let alpha = format == .dxt5 ? dxt5Alpha(s, o) : nil
                for p in 0..<16 {
                    let x = bx * 4 + p % 4, y = by * 4 + p / 4
                    guard x < w, y < h else { continue }
                    var c = colors[Int(indices >> (2 * p) & 3)]
                    if format == .dxt3 {
                        let nibble = s[o + p / 2] >> (4 * (p % 2)) & 0xF
                        c[3] = nibble * 17
                    } else if let alpha {
                        c[3] = alpha[p]
                    }
                    let d = (y * w + x) * 4
                    out[d..<d + 4] = c[0..<4]
                }
            }
        }
        return Data(out)
    }

    private static func dxtColors(_ s: [UInt8], _ o: Int, allowPunchThrough: Bool) -> [[UInt8]] {
        let c0 = UInt16(s[o]) | UInt16(s[o + 1]) << 8, c1 = UInt16(s[o + 2]) | UInt16(s[o + 3]) << 8
        func rgb(_ c: UInt16) -> [Int] {
            let r = Int(c >> 11 & 31), g = Int(c >> 5 & 63), b = Int(c & 31)
            return [r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2]
        }
        let a = rgb(c0), b = rgb(c1)
        func mix(_ wa: Int, _ wb: Int, _ d: Int) -> [UInt8] { (0..<3).map { UInt8((a[$0] * wa + b[$0] * wb) / d) } + [255] }
        if c0 > c1 || !allowPunchThrough {
            return [mix(1, 0, 1), mix(0, 1, 1), mix(2, 1, 3), mix(1, 2, 3)]
        }
        return [mix(1, 0, 1), mix(0, 1, 1), mix(1, 1, 2), [0, 0, 0, 0]]
    }

    private static func dxt5Alpha(_ s: [UInt8], _ o: Int) -> [UInt8] {
        let a0 = Int(s[o]), a1 = Int(s[o + 1])
        var table = [a0, a1]
        if a0 > a1 {
            table += (1...6).map { ((7 - $0) * a0 + $0 * a1) / 7 }
        } else {
            table += (1...4).map { ((5 - $0) * a0 + $0 * a1) / 5 } + [0, 255]
        }
        let bits = (0..<6).reduce(UInt64(0)) { $0 | UInt64(s[o + 2 + $1]) << (8 * UInt64($1)) }
        return (0..<16).map { UInt8(table[Int(bits >> (3 * UInt64($0)) & 7)]) }
    }

    /// PNG/JPEG/etc. stored inside the texture ("FreeImage" containers).
    static func decodeImageFile(_ bytes: Data) throws -> (Int, Int, Data) {
        guard let src = CGImageSourceCreateWithData(bytes as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw SceneTextureFormatError.unsupported("embedded image") }
        let w = img.width, h = img.height
        var out = Data(count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw SceneTextureFormatError.unsupported("embedded image") }
        // Un-premultiply so every path yields straight alpha.
        out.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] != 0 && p[i + 3] != 255 {
                let a = Int(p[i + 3])
                for c in 0..<3 { p[i + c] = UInt8(min(255, Int(p[i + c]) * 255 / a)) }
            }
        }
        return (w, h, out)
    }
}

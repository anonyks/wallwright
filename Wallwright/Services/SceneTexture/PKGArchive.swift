//
//  PKGArchive.swift
//  Wallwright
//
//  Reads a Wallpaper Engine scene.pkg: "PKGVxxxx" header, a file table of (name, offset, size),
//  then the file bodies, offsets relative to the end of the table.
//
//  Adapted from MacWall (MIT License, Copyright (c) 2026 Emidolo)
//  https://github.com/Emidolo/MacWall
//

import Foundation

enum SceneTextureFormatError: Error, Equatable {
    case truncated
    case badMagic(String)
    case unsupported(String)
    /// The texture's payload is a literal embedded video clip (an MP4 "ftyp" box), not a still
    /// image. Carries the raw, already LZ4-decompressed bytes so the caller can hand them to
    /// AVAssetImageGenerator for a single frame, instead of this just being a dead end like the
    /// original upstream parsing treats it. The one deliberate change from the ported original,
    /// which discards these bytes and only reports "unsupported".
    case videoPayload(Data)
}

/// Little-endian cursor over a byte buffer; every read is bounds-checked.
struct SceneByteReader {
    let data: Data
    var pos: Int

    init(_ data: Data) { self.data = data; pos = data.startIndex }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, pos + n <= data.endIndex else { throw SceneTextureFormatError.truncated }
        defer { pos += n }
        return data[pos..<pos + n]
    }

    mutating func u32() throws -> UInt32 {
        try bytes(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    /// uint32 length followed by that many bytes.
    mutating func lengthPrefixedString() throws -> String {
        String(decoding: try bytes(Int(try u32())), as: UTF8.self)
    }

    /// NUL-terminated string (terminator consumed).
    mutating func cString(max: Int = 32) throws -> String {
        var out = [UInt8]()
        while true {
            guard let b = try bytes(1).first else { throw SceneTextureFormatError.truncated }
            if b == 0 { break }
            out.append(b)
            if out.count > max { throw SceneTextureFormatError.truncated }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

struct PKGArchive {
    let version: String
    let names: [String]
    private let entries: [String: Range<Int>]
    private let data: Data

    init(data: Data) throws {
        var r = SceneByteReader(data)
        version = try r.lengthPrefixedString()
        guard version.hasPrefix("PKGV") else { throw SceneTextureFormatError.badMagic(String(version.prefix(8))) }
        let count = Int(try r.u32())
        var table: [(String, Int, Int)] = []
        for _ in 0..<count {
            table.append((try r.lengthPrefixedString(), Int(try r.u32()), Int(try r.u32())))
        }
        let base = r.pos
        var entries: [String: Range<Int>] = [:]
        for (name, offset, size) in table {
            let range = base + offset..<base + offset + size
            guard range.upperBound <= data.endIndex else { throw SceneTextureFormatError.truncated }
            entries[name] = range
        }
        names = table.map(\.0)
        self.entries = entries
        self.data = data
    }

    init(url: URL) throws { try self.init(data: Data(contentsOf: url, options: .mappedIfSafe)) }

    subscript(name: String) -> Data? { entries[name].map { data[$0] } }
}

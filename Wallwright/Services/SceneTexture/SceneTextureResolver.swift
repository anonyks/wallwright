//
//  SceneTextureResolver.swift
//  Wallwright
//
//  Walks a Wallpaper Engine scene.json's objects to find candidate textures that plausibly
//  represent the scene's actual background art, as opposed to particle sprites, effect masks, or
//  UI chrome. Unlike a real renderer (MacWall's SceneRenderer, this app's own upstream
//  SceneWallpaperViewModel), this never draws anything, it just resolves object -> model ->
//  material -> texture file paths, in a preference order a caller can try one at a time.
//
//  Plain JSONSerialization, not a typed Codable scene graph: third-party scene.json content is
//  free-form enough (fields that are sometimes a plain value, sometimes a {"user":...,"value":...}
//  wrapper) that defensive dictionary digging is a better fit than a strict Decodable model that
//  would fail the whole parse on one unexpected shape.
//

import Foundation

struct SceneTextureCandidate {
    let path: String
    /// True when the object's model is flagged `fullscreen`, or its declared size matches the
    /// scene's own canvas size — both are signals this is the background layer, not an overlay.
    let isLikelyBackground: Bool
}

enum SceneTextureResolver {
    /// `archive` must contain `scene.json` (the caller already knows this, since it's what
    /// triggered trying this path at all). Returns candidates most-likely-background first;
    /// within each group, original document order (bottom-most/background layers are
    /// conventionally authored first in Wallpaper Engine's own editor, though this isn't a hard
    /// guarantee, which is exactly why `isLikelyBackground` exists as a stronger signal).
    static func candidateTexturePaths(in archive: PKGArchive) -> [SceneTextureCandidate] {
        guard let sceneData = archive["scene.json"],
              let scene = try? JSONSerialization.jsonObject(with: sceneData) as? [String: Any],
              let objects = scene["objects"] as? [[String: Any]]
        else { return [] }

        let canvasSize = canvasSize(from: scene)
        var background: [SceneTextureCandidate] = []
        var rest: [SceneTextureCandidate] = []

        for object in objects {
            guard let modelPath = object["image"] as? String,
                  let model = json(archive, modelPath),
                  let materialPath = model["material"] as? String,
                  let material = json(archive, materialPath),
                  let textureName = firstTextureName(in: material)
            else { continue }

            let texturePath = "materials/\(textureName).tex"
            let isFullscreen = (model["fullscreen"] as? Bool) == true
            let sizeMatches = canvasSize.map { matches($0, modelSize(model) ?? objectSize(object)) } ?? false
            let candidate = SceneTextureCandidate(path: texturePath, isLikelyBackground: isFullscreen || sizeMatches)
            if candidate.isLikelyBackground {
                background.append(candidate)
            } else {
                rest.append(candidate)
            }
        }
        return background + rest
    }

    private static func json(_ archive: PKGArchive, _ path: String) -> [String: Any]? {
        guard let data = archive[path] else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Material JSON varies between a single implicit pass (`textures` at the top level) and an
    /// explicit `passes` array (`passes[0].textures`) — tried in that order, first non-empty wins.
    private static func firstTextureName(in material: [String: Any]) -> String? {
        if let textures = material["textures"] as? [Any], let name = firstNonEmptyString(textures) {
            return name
        }
        if let passes = material["passes"] as? [[String: Any]],
           let firstPass = passes.first,
           let textures = firstPass["textures"] as? [Any],
           let name = firstNonEmptyString(textures) {
            return name
        }
        return nil
    }

    private static func firstNonEmptyString(_ values: [Any]) -> String? {
        for value in values {
            if let s = value as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private static func canvasSize(from scene: [String: Any]) -> (Double, Double)? {
        guard let general = scene["general"] as? [String: Any],
              let projection = general["orthogonalprojection"] as? [String: Any],
              let width = number(projection["width"]), let height = number(projection["height"])
        else { return nil }
        return (width, height)
    }

    private static func modelSize(_ model: [String: Any]) -> (Double, Double)? {
        guard let width = number(model["width"]), let height = number(model["height"]) else { return nil }
        return (width, height)
    }

    private static func objectSize(_ object: [String: Any]) -> (Double, Double)? {
        guard let size = object["size"] as? [Any], size.count >= 2,
              let width = number(size[0]), let height = number(size[1])
        else { return nil }
        return (width, height)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// A small tolerance, not exact equality — scene canvas sizes and layer sizes in real content
    /// are occasionally off by a pixel or two from rounding in the original authoring tool.
    private static func matches(_ a: (Double, Double), _ b: (Double, Double)?) -> Bool {
        guard let b else { return false }
        return abs(a.0 - b.0) < 2 && abs(a.1 - b.1) < 2
    }
}

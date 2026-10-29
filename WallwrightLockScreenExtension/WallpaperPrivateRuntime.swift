//
//  WallpaperPrivateRuntime.swift
//  WallwrightLockScreenExtension
//
//  There is no public API for a third-party macOS wallpaper provider. This talks to
//  WallpaperAgent over a private XPC protocol defined in a private framework
//  (WallpaperExtensionKit), using private classes with no public initializer. Adapted from
//  reference/WallpaperMachine/Extension/WallpaperRuntime.swift (read in full this session) —
//  that file's own header comment states the governing principle this one keeps: "All private
//  ABI assumptions are checked against the loaded system classes. No fallback offsets, process
//  injection, or lock-screen window impersonation." A macOS update that changes the private
//  class layout must make `load()` throw, not silently poke the wrong memory.
//

import AppKit
import IOSurface
import Security

enum WallpaperPrivateRuntime {
    static let exchange = LockScreenExchangeConfig.exchangeDirectory
    private static var handle: UnsafeMutableRawPointer?

    /// Call once, before touching anything else here. Throws instead of crashing if this macOS
    /// version doesn't have the expected private framework/classes/memory layout.
    static func load() throws {
        if handle == nil {
            guard
                let framework = dlopen(
                    "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit",
                    RTLD_LAZY
                )
            else {
                throw failure("This macOS version does not provide WallpaperExtensionKit.")
            }
            handle = framework
        }
        for name in [
            "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperCreationRequestXPC",
            "WallpaperUpdateRequestXPC", "WallpaperIDXPC", "WallpaperSettingsViewModelsXPC",
        ] {
            guard NSClassFromString(name) != nil else {
                throw failure("Missing macOS wallpaper type: \(name)")
            }
        }
        _ = try storage(className: "WallpaperRemoteContextXPC", member: "box", count: 4)
        _ = try storage(
            className: "WallpaperSnapshotXPC", member: "rawValue",
            count: MemoryLayout<UnsafeRawPointer>.size
        )
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Wallwright.LockScreenExtension", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Confirms a private class still has the exact ivar this code is about to poke, at the
    /// exact offset expected, before any `class_createInstance`/`storeBytes` call happens —
    /// the actual safety check, not just "does the class exist."
    private static func storage(className: String, member: String, count: Int) throws -> (AnyClass, Int) {
        guard let cls = NSClassFromString(className), let ivar = class_getInstanceVariable(cls, member)
        else {
            throw failure("Unsupported macOS wallpaper layout: \(className).\(member)")
        }
        let offset = ivar_getOffset(ivar)
        guard offset == MemoryLayout<UnsafeRawPointer>.size,
            offset + count == class_getInstanceSize(cls)
                || (count == 4 && offset + 8 == class_getInstanceSize(cls))
        else {
            throw failure("Unsupported macOS wallpaper payload size: \(className)")
        }
        return (cls, offset)
    }

    /// Hand-constructs an instance of Apple's own private `WallpaperRemoteContextXPC` reply
    /// class — there's no public initializer, so this allocates a bare instance via the
    /// Objective-C runtime and writes the context ID directly into its one ivar at the
    /// `storage(...)`-verified offset.
    static func contextReply(_ contextID: UInt32) throws -> AnyObject {
        let (cls, offset) = try storage(className: "WallpaperRemoteContextXPC", member: "box", count: 4)
        guard let raw = class_createInstance(cls, 0) else {
            throw failure("Cannot allocate wallpaper context reply.")
        }
        let object = raw as AnyObject
        Unmanaged.passUnretained(object).toOpaque().advanced(by: offset)
            .storeBytes(of: contextID, as: UInt32.self)
        return object
    }

    /// Same hand-construction for `WallpaperSnapshotXPC`, carrying a retained `IOSurface`
    /// pointer instead of a context ID.
    static func snapshotReply(_ surface: IOSurface) throws -> AnyObject {
        let (cls, offset) = try storage(
            className: "WallpaperSnapshotXPC", member: "rawValue",
            count: MemoryLayout<UnsafeRawPointer>.size
        )
        guard let raw = class_createInstance(cls, 0) else {
            throw failure("Cannot allocate wallpaper snapshot reply.")
        }
        let object = raw as AnyObject
        let retained = Unmanaged.passRetained(surface).toOpaque()
        Unmanaged.passUnretained(object).toOpaque().advanced(by: offset)
            .storeBytes(of: retained, as: UnsafeMutableRawPointer.self)
        return object
    }

    /// A remote `CAContext` WallpaperAgent can composite into its own process — obtained via a
    /// private `CAContext` class method, since there's no public API to create a cross-process
    /// rendering surface like this.
    static func context(displayID: UInt32?) throws -> CAContext {
        guard let cls = NSClassFromString("CAContext"),
            class_getClassMethod(cls, NSSelectorFromString("remoteContextWithOptions:")) != nil,
            class_getInstanceMethod(cls, NSSelectorFromString("contextId")) != nil,
            class_getInstanceMethod(cls, NSSelectorFromString("setLayer:")) != nil,
            class_getInstanceMethod(cls, NSSelectorFromString("invalidate")) != nil
        else {
            throw failure("Remote wallpaper composition is unavailable on this macOS version.")
        }
        let options: [String: Any] = displayID.map { ["displayId": $0] } ?? [:]
        guard
            let context = (cls as AnyObject).perform(
                NSSelectorFromString("remoteContextWithOptions:"), with: options
            )?.takeUnretainedValue() as? CAContext,
            context.contextId != 0
        else { throw failure("macOS refused to create a remote wallpaper surface.") }
        return context
    }

    /// Refuses any caller that isn't Apple-signed — `accept(connection:)` is the one thing
    /// standing between this extension and an arbitrary process pretending to be WallpaperAgent.
    static func accepts(_ connection: NSXPCConnection) -> Bool {
        guard connection.responds(to: NSSelectorFromString("auditToken")) else { return false }
        var token = connection.auditToken
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(
                nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code
            ) == errSecSuccess, let code
        else { return false }
        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// WallpaperAgent's own request/reply objects are private classes this code can't import —
    /// reflects into them by field name instead, same `Mirror`-based approach WallpaperMachine's
    /// own `WallpaperRuntime.field(_:in:)` uses, since a private header can't be imported either
    /// way.
    static func field(_ label: String, in value: Any, depth: Int = 0) -> Any? {
        guard depth < 8 else { return nil }
        let mirror = Mirror(reflecting: value)
        if let child = mirror.children.first(where: { $0.label == label }) { return child.value }
        for child in mirror.children {
            if let result = field(label, in: child.value, depth: depth + 1) { return result }
        }
        return nil
    }

    static func identifier(_ value: Any?, depth: Int = 0) -> UUID? {
        guard let value, depth < 8 else { return nil }
        if let uuid = value as? UUID { return uuid }
        for child in Mirror(reflecting: value).children {
            if let uuid = identifier(child.value, depth: depth + 1) { return uuid }
        }
        return nil
    }

    /// Diagnostic only — dumps every top-level field name (and, one level deep, nested field
    /// names) of a reflected private object, so a real `acquire` request's actual shape can be
    /// inspected live without guessing at field names ahead of time. Added specifically to find
    /// out whether a real screen-saver-context `acquire` call carries a distinguishing field
    /// (e.g. a "purpose"/"context"/"isScreenSaver" case) that `acquire(id:request:reply:)`
    /// isn't currently reading — see that function's own call to this.
    static func describeFields(_ value: Any, depth: Int = 0) -> String {
        guard depth < 3 else { return "…" }
        let mirror = Mirror(reflecting: value)
        let parts = mirror.children.map { child -> String in
            let name = child.label ?? "?"
            let nested = Mirror(reflecting: child.value)
            if nested.children.isEmpty || depth >= 2 {
                return name
            }
            return "\(name)(\(describeFields(child.value, depth: depth + 1)))"
        }
        return parts.joined(separator: ", ")
    }

    static func enumCase(_ value: Any) -> String {
        Mirror(reflecting: value).children.first?.label ?? String(describing: value)
    }

    static func configuration() throws -> LockScreenExchangeConfig {
        let url = exchange.appendingPathComponent(LockScreenExchangeConfig.fileName)
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(LockScreenExchangeConfig.self, from: data)
        guard config.version == LockScreenExchangeConfig.supportedVersion else {
            throw failure("Unsupported lock-screen configuration version \(config.version).")
        }
        return config
    }

    /// Same path-traversal hardening as `WallpaperRuntime.asset(_:)` — resolves a relative
    /// filename against the exchange directory and refuses anything that escapes it.
    static func asset(_ relativeName: String) throws -> URL {
        guard !relativeName.isEmpty, !relativeName.hasPrefix("/"), !relativeName.contains("..") else {
            throw failure("Invalid lock-screen asset path.")
        }
        let root = exchange.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(relativeName).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"),
            FileManager.default.isReadableFile(atPath: url.path)
        else { throw failure("Lock-screen asset is unavailable: \(relativeName)") }
        return url
    }

    static func log(_ message: String) {
        NSLog("[Wallwright LockScreen] %@", message)
        let file = exchange.appendingPathComponent("extension.log")
        try? FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512 * 1024 {
            try? FileManager.default.removeItem(at: file)
        }
        let data = Data("\(Date()) \(message)\n".utf8)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? data.write(to: file)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

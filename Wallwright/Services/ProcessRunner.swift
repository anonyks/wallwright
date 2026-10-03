//
//  ProcessRunner.swift
//  Wallwright
//
//  Shared binary resolution for external tools (yt-dlp, ffmpeg/ffprobe, steamcmd), previously
//  copy-pasted identically into YtDlpService, VideoTranscoder, and SteamWorkshopService.
//

import Foundation

enum ProcessRunner {
    /// Checked in order before falling back to a PATH lookup — a GUI-launched app's process
    /// environment often doesn't include Homebrew's (or MacPorts', or Nix's) bin directory on PATH
    /// the way an interactive Terminal session does, so the common install locations are tried
    /// directly first.
    static func resolveBinary(named name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)",
            "/opt/local/bin/\(name)",
            NSString(string: "~/.nix-profile/bin/\(name)").expandingTildeInPath,
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        guard (try? which.run()) != nil else { return nil }
        which.waitUntilExit()
        guard which.terminationStatus == 0,
              let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return path
    }
}

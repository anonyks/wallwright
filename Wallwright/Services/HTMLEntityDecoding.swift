//
//  HTMLEntityDecoding.swift
//  Wallwright
//
//  Shared by every scraped browse source (AlphaCoders, DesktopHut, Steam Workshop) to unescape
//  HTML entities in titles/tags pulled out of raw page HTML.
//

import Foundation

extension String {
    /// Decodes HTML entities (`&amp;`, `&quot;`, `&#39;`, `&#x2019;`, ...) via plain string
    /// replacement plus a numeric-reference regex — not `NSAttributedString(documentType: .html)`,
    /// which routes through WebKit's legacy HTML importer. Apple doesn't document that path as
    /// safe to call off the main thread, and every caller here runs from a background scraping
    /// task. Covers the named entities that actually show up in scraped listing/detail pages plus
    /// decimal and hex numeric references, which covers everything a source could reasonably emit
    /// without needing a full HTML parser.
    func decodingHTMLEntities() -> String {
        var result = self
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        guard let regex = try? NSRegularExpression(pattern: "&#x?([0-9a-fA-F]+);", options: [.caseInsensitive]) else {
            return result
        }
        let fullRange = NSRange(result.startIndex..<result.endIndex, in: result)
        // Replaced back-to-front so each match's range stays valid as earlier replacements shift
        // the string's indices.
        for match in regex.matches(in: result, range: fullRange).reversed() {
            guard let matchRange = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: result)
            else { continue }
            let isHex = result[matchRange].lowercased().hasPrefix("&#x")
            guard let scalarValue = UInt32(result[numberRange], radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(scalarValue)
            else { continue }
            result.replaceSubrange(matchRange, with: String(Character(scalar)))
        }
        return result
    }
}

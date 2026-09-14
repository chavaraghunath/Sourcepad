// SPDX-License-Identifier: MIT
// Sourcepad — lightweight markdown → NSAttributedString for chat bubbles.
//
// Agent replies are markdown-heavy (code fences, headers, lists, inline
// styling). Foundation's NSAttributedString(markdown:) handles inline syntax
// well but doesn't render block structure (headers/lists) or fenced code
// blocks the way a chat transcript needs, so we handle those ourselves:
// fenced spans become monospaced, background-filled paragraphs; header and
// list lines get their marker stripped and real styling (size/weight/bullet)
// applied; everything else goes through the system inline markdown parser.
// Good enough for a chat transcript without pulling in a full markdown engine.

import AppKit

enum AgentMarkdown {

    static func render(_ source: String,
                       baseFont: NSFont,
                       textColor: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let monoFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 0.5, weight: .regular)

        // Split into alternating non-code / code segments on ``` fences.
        let segments = source.components(separatedBy: "```")
        for (i, seg) in segments.enumerated() {
            let isCode = (i % 2 == 1)
            if isCode {
                out.append(codeBlock(seg, font: monoFont))
            } else if !seg.isEmpty {
                out.append(block(seg, baseFont: baseFont, textColor: textColor, monoFont: monoFont))
            }
        }
        return out
    }

    // MARK: - Block-level (headers, lists) within a non-fenced segment

    private static let headerRegex = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#)
    private static let unorderedRegex = try! NSRegularExpression(pattern: #"^[-*+]\s+(.*)$"#)
    private static let orderedRegex = try! NSRegularExpression(pattern: #"^(\d+)[.)]\s+(.*)$"#)

    private static func block(_ text: String,
                              baseFont: NSFont,
                              textColor: NSColor,
                              monoFont: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var plainBuffer: [String] = []

        func flushPlain() {
            guard !plainBuffer.isEmpty else { return }
            out.append(inline(plainBuffer.joined(separator: "\n"), baseFont: baseFont, textColor: textColor, monoFont: monoFont))
            out.append(NSAttributedString(string: "\n"))
            plainBuffer.removeAll()
        }

        for line in lines {
            let full = NSRange(line.startIndex..<line.endIndex, in: line)
            if let m = headerRegex.firstMatch(in: line, range: full), let levelRange = Range(m.range(at: 1), in: line), let bodyRange = Range(m.range(at: 2), in: line) {
                flushPlain()
                out.append(headerLine(String(line[bodyRange]), level: line[levelRange].count,
                                      baseFont: baseFont, textColor: textColor, monoFont: monoFont))
            } else if let m = unorderedRegex.firstMatch(in: line, range: full), let bodyRange = Range(m.range(at: 1), in: line) {
                flushPlain()
                out.append(listLine(marker: "•", content: String(line[bodyRange]),
                                    baseFont: baseFont, textColor: textColor, monoFont: monoFont))
            } else if let m = orderedRegex.firstMatch(in: line, range: full), let numRange = Range(m.range(at: 1), in: line), let bodyRange = Range(m.range(at: 2), in: line) {
                flushPlain()
                out.append(listLine(marker: "\(line[numRange]).", content: String(line[bodyRange]),
                                    baseFont: baseFont, textColor: textColor, monoFont: monoFont))
            } else {
                plainBuffer.append(line)
            }
        }
        flushPlain()
        return out
    }

    private static func headerLine(_ content: String, level: Int,
                                   baseFont: NSFont, textColor: NSColor, monoFont: NSFont) -> NSAttributedString {
        let rendered = NSMutableAttributedString(attributedString: inline(content, baseFont: baseFont, textColor: textColor, monoFont: monoFont))
        let bump: CGFloat = [6, 4, 2.5, 1.5, 1, 0.5][min(max(level, 1), 6) - 1]
        let desc = baseFont.fontDescriptor.withSymbolicTraits(.bold)
        let font = NSFont(descriptor: desc, size: baseFont.pointSize + bump) ?? baseFont
        let full = NSRange(location: 0, length: rendered.length)
        rendered.addAttribute(.font, value: font, range: full)

        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 6
        para.paragraphSpacing = 4
        rendered.addAttribute(.paragraphStyle, value: para, range: full)
        rendered.append(NSAttributedString(string: "\n"))
        return rendered
    }

    private static func listLine(marker: String, content: String,
                                 baseFont: NSFont, textColor: NSColor, monoFont: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: marker + "\t", attributes: [.font: baseFont, .foregroundColor: textColor])
        out.append(inline(content, baseFont: baseFont, textColor: textColor, monoFont: monoFont))

        let para = NSMutableParagraphStyle()
        para.headIndent = 16
        para.firstLineHeadIndent = 0
        para.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
        para.paragraphSpacing = 2
        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        out.append(NSAttributedString(string: "\n"))
        return out
    }

    // MARK: - Inline (non-fenced) markdown

    private static func inline(_ text: String,
                               baseFont: NSFont,
                               textColor: NSColor,
                               monoFont: NSFont) -> NSAttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        opts.allowsExtendedAttributes = true

        let attributed: NSMutableAttributedString
        if let parsed = try? AttributedString(markdown: text, options: opts) {
            attributed = NSMutableAttributedString(parsed)
        } else {
            attributed = NSMutableAttributedString(string: text)
        }

        // Normalize fonts/colors: AttributedString markdown sets intents but not
        // a concrete NSFont. Map bold/italic/inline-code onto our base font.
        let full = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.foregroundColor, value: textColor, range: full)
        attributed.enumerateAttribute(.font, in: full) { value, range, _ in
            let existing = value as? NSFont
            let traits = existing?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.monoSpace) {
                attributed.addAttribute(.font, value: monoFont, range: range)
            } else {
                var desc = baseFont.fontDescriptor
                var merged: NSFontDescriptor.SymbolicTraits = []
                if traits.contains(.bold) { merged.insert(.bold) }
                if traits.contains(.italic) { merged.insert(.italic) }
                if !merged.isEmpty { desc = desc.withSymbolicTraits(merged) }
                attributed.addAttribute(.font, value: NSFont(descriptor: desc, size: baseFont.pointSize) ?? baseFont,
                                        range: range)
            }
        }
        return attributed
    }

    // MARK: - Fenced code block

    private static func codeBlock(_ raw: String, font: NSFont) -> NSAttributedString {
        // Drop an optional language hint on the first line (```swift).
        var body = raw
        if let nl = raw.firstIndex(of: "\n") {
            let firstLine = raw[raw.startIndex..<nl].trimmingCharacters(in: .whitespaces)
            if !firstLine.isEmpty && !firstLine.contains(" ") && firstLine.count < 20 {
                body = String(raw[raw.index(after: nl)...])
            }
        }
        body = body.trimmingCharacters(in: CharacterSet.newlines)

        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 8
        para.headIndent = 8
        para.tailIndent = -8
        para.paragraphSpacingBefore = 6
        para.paragraphSpacing = 6
        para.lineSpacing = 1

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .backgroundColor: NSColor.textColor.withAlphaComponent(0.06),
            .paragraphStyle: para,
        ]
        return NSAttributedString(string: "\n" + body + "\n", attributes: attrs)
    }
}

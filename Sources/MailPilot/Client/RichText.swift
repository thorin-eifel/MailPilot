import AppKit
import SwiftUI

// MARK: - Signatur

/// Signatur-Block in einem Nachrichtentext: Trennzeile „-- “ (wie üblich) und der Text des Kontos.
/// Bei Antworten und Weiterleitungen steht er über dem zitierten Text.
enum Signature {
    static func block(_ signature: String) -> String {
        let s = signature.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n")
        return s.isEmpty ? "" : "\n\n-- \n" + s
    }

    /// Stelle, an der der Block eingefügt wird: vor dem Zitat („Am … schrieb …:“ bzw. „Weitergeleitete Nachricht“), sonst am Ende.
    static func insertionIndex(in text: String) -> String.Index {
        if let r = text.range(of: #"\n\nAm .+ schrieb .+:\n"#, options: .regularExpression) { return r.lowerBound }
        if let r = text.range(of: "\n\n-------- Weitergeleitete Nachricht --------") { return r.lowerBound }
        return text.endIndex
    }

    /// Die nötige Textänderung, um die alte Signatur durch die neue zu ersetzen (oder die neue einzufügen, wenn die alte nicht mehr zu finden ist).
    /// `nil`: nichts zu tun.
    static func edit(old: String?, new: String, in text: String) -> (range: NSRange, replacement: String)? {
        let oldBlock = block(old ?? ""), newBlock = block(new)
        guard oldBlock != newBlock else { return nil }
        if !oldBlock.isEmpty, let r = text.range(of: oldBlock) { return (NSRange(r, in: text), newBlock) }
        guard !newBlock.isEmpty else { return nil }
        return (NSRange(location: NSRange(text.startIndex..<insertionIndex(in: text), in: text).length, length: 0), newBlock)
    }

    static func replacing(_ old: String?, with new: String, in text: String) -> String {
        guard let e = edit(old: old, new: new, in: text), let r = Range(e.range, in: text) else { return text }
        var t = text
        t.replaceSubrange(r, with: e.replacement)
        return t
    }
}

// MARK: - HTML aus formatiertem Text

/// Wandelt den Text des Editors in HTML um: fett, kursiv, unterstrichen, durchgestrichen, Links; Zitate („> “) als Zitatblöcke.
enum HTMLExport {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func runs(_ a: NSAttributedString, _ range: NSRange) -> String {
        var out = ""
        let fm = NSFontManager.shared
        a.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            var s = escape((a.string as NSString).substring(with: r))
            guard !s.isEmpty else { return }
            if let font = attrs[.font] as? NSFont {
                let t = fm.traits(of: font)
                if t.contains(.boldFontMask) { s = "<b>\(s)</b>" }
                if t.contains(.italicFontMask) { s = "<i>\(s)</i>" }
            }
            if let u = attrs[.underlineStyle] as? Int, u != 0 { s = "<u>\(s)</u>" }
            if let st = attrs[.strikethroughStyle] as? Int, st != 0 { s = "<s>\(s)</s>" }
            if let link = attrs[.link] {
                let href = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !href.isEmpty { s = "<a href=\"\(escape(href))\">\(s)</a>" }
            }
            out += s
        }
        return out
    }

    /// Zeilen des Textes mit Zitattiefe (Anzahl führender „>“, je mit optionalem Leerzeichen) und Beginn des Inhalts.
    private static func lines(_ text: NSString) -> [(range: NSRange, depth: Int, content: Int)] {
        var result: [(NSRange, Int, Int)] = []
        var start = 0
        while start <= text.length {
            var end = text.range(of: "\n", range: NSRange(location: start, length: text.length - start)).location
            let last = end == NSNotFound
            if last { end = text.length }
            var i = start, depth = 0
            while i < end, text.character(at: i) == 62 {   // ">"
                depth += 1
                i += 1
                if i < end, text.character(at: i) == 32 { i += 1 }
            }
            result.append((NSRange(location: start, length: end - start), depth, i))
            if last { break }
            start = end + 1
        }
        return result
    }

    /// Enthält der Text irgendeine Formatierung (fett, kursiv, unterstrichen, durchgestrichen, Link)? Sonst genügt reiner Text.
    static func hasFormatting(_ a: NSAttributedString) -> Bool {
        var found = false
        let fm = NSFontManager.shared
        a.enumerateAttributes(in: NSRange(location: 0, length: a.length), options: []) { attrs, _, stop in
            let t = (attrs[.font] as? NSFont).map { fm.traits(of: $0) } ?? []
            if t.contains(.boldFontMask) || t.contains(.italicFontMask) || attrs[.link] != nil
                || ((attrs[.underlineStyle] as? Int) ?? 0) != 0 || ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0 { found = true; stop.pointee = true }
        }
        return found
    }

    /// Jede Zeile ein `<div>` (leere Zeile: `<div><br></div>`), Zitate als verschachtelte `<blockquote>`.
    static func html(from a: NSAttributedString) -> String {
        let text = a.string as NSString
        var out = ""
        var depth = 0
        for line in lines(text) {
            while depth < line.depth { out += "<blockquote style=\"margin:0 0 0 .6em;padding-left:.8em;border-left:2px solid #ccc;color:#555\">"; depth += 1 }
            while depth > line.depth { out += "</blockquote>"; depth -= 1 }
            let content = NSRange(location: line.content, length: max(0, line.range.location + line.range.length - line.content))
            out += content.length == 0 ? "<div><br></div>" : "<div>\(runs(a, content))</div>"
            out += "\n"
        }
        while depth > 0 { out += "</blockquote>"; depth -= 1 }
        return "<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">\n\(out)</div>"
    }
}

// MARK: - Editor

/// Steuert den Texteditor: Formatieren, Text lesen und ersetzen. Der Editor selbst ist ein `NSTextView` (Rückgängig, Rechtschreibung, Einfügen wie in jeder Mac-App).
final class RichTextController: NSObject, ObservableObject, NSTextViewDelegate {
    weak var textView: NSTextView?
    /// Wird bei jeder Änderung des Textes aufgerufen (Klartext).
    var onChange: ((String) -> Void)?
    @Published private(set) var selectionLength = 0
    static let baseFont = NSFont.systemFont(ofSize: 14)

    var string: String { textView?.string ?? "" }
    var attributed: NSAttributedString { textView?.attributedString() ?? NSAttributedString(string: "") }
    var isRich: Bool { textView?.isRichText ?? false }

    func setRich(_ on: Bool) {
        guard let tv = textView, tv.isRichText != on else { return }
        let text = tv.string
        tv.isRichText = on
        if !on {
            // Ohne Formatierung: Text neu setzen, damit keine Auszeichnungen übrig bleiben.
            tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: Self.baseFont, .foregroundColor: NSColor.textColor]))
            tv.typingAttributes = [.font: Self.baseFont, .foregroundColor: NSColor.textColor]
        }
    }

    /// Ersetzt einen Bereich, ohne die Formatierung des Restes anzutasten (für den Signaturwechsel).
    func replace(_ range: NSRange, with s: String) {
        guard let tv = textView, tv.shouldChangeText(in: range, replacementString: s) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: s, attributes: [.font: Self.baseFont, .foregroundColor: NSColor.textColor]))
        tv.didChangeText()
    }

    func textDidChange(_ notification: Notification) { onChange?(string) }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionLength = textView?.selectedRange().length ?? 0
    }

    // MARK: Formatieren

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView, tv.isRichText, let storage = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()
        if range.length == 0 {
            let font = (tv.typingAttributes[.font] as? NSFont) ?? Self.baseFont
            tv.typingAttributes[.font] = fm.traits(of: font).contains(trait) ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
            return
        }
        var all = true
        storage.enumerateAttribute(.font, in: range) { v, _, _ in
            if !fm.traits(of: (v as? NSFont) ?? Self.baseFont).contains(trait) { all = false }
        }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { v, r, _ in
            let font = (v as? NSFont) ?? Self.baseFont
            storage.addAttribute(.font, value: all ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait), range: r)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    func toggleLine(_ key: NSAttributedString.Key) {
        guard let tv = textView, tv.isRichText, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let on = NSUnderlineStyle.single.rawValue
        if range.length == 0 {
            let has = ((tv.typingAttributes[key] as? Int) ?? 0) != 0
            if has { tv.typingAttributes.removeValue(forKey: key) } else { tv.typingAttributes[key] = on }
            return
        }
        var all = true
        storage.enumerateAttribute(key, in: range) { v, _, _ in if ((v as? Int) ?? 0) == 0 { all = false } }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        if all { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: on, range: range) }
        tv.didChangeText()
    }

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }
    func toggleUnderline() { toggleLine(.underlineStyle) }
    func toggleStrikethrough() { toggleLine(.strikethroughStyle) }

    /// Setzt oder entfernt einen Link an der Auswahl. Gültig sind http, https und mailto.
    func setLink(_ text: String) {
        guard let tv = textView, tv.isRichText, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            storage.removeAttribute(.link, range: range)
        } else {
            var s = trimmed
            if !s.contains(":") { s = s.contains("@") ? "mailto:\(s)" : "https://\(s)" }
            guard let url = URL(string: s), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            storage.addAttribute(.link, value: url, range: range)
        }
        tv.didChangeText()
    }

    var selectedHasLink: Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        let r = tv.selectedRange()
        guard r.length > 0 else { return false }
        return storage.attribute(.link, at: r.location, effectiveRange: nil) != nil
    }
}

struct RichTextEditor: NSViewRepresentable {
    let controller: RichTextController
    let initialText: String
    let rich: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = controller
        tv.allowsUndo = true
        tv.isRichText = rich
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.drawsBackground = false
        tv.font = RichTextController.baseFont
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.typingAttributes = [.font: RichTextController.baseFont, .foregroundColor: NSColor.textColor]
        tv.textStorage?.setAttributedString(NSAttributedString(string: initialText, attributes: tv.typingAttributes))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        controller.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if controller.isRich != rich { controller.setRich(rich) }
    }
}

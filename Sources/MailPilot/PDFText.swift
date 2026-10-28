import Foundation
import PDFKit
import Vision

/// Text aus PDF-Anhängen: eingebetteter Text, bei gescannten PDFs per Texterkennung (OCR).
enum PDFText {
    static func extract(_ url: URL, maxChars: Int = 7000, maxPages: Int = 6) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var text = ""
        for i in 0..<min(doc.pageCount, maxPages) {
            text += (doc.page(at: i)?.string ?? "") + "\n"
            if text.count >= maxChars { break }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count < 40 { text = ocr(doc, pages: 2).trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text.prefix(maxChars))
    }

    static func ocr(_ doc: PDFDocument, pages: Int) -> String {
        var out = ""
        for i in 0..<min(doc.pageCount, pages) {
            guard let page = doc.page(at: i) else { continue }
            let size = page.bounds(for: .mediaBox).size
            guard size.width > 0, size.height > 0 else { continue }
            let scale = 2000 / max(size.width, size.height)
            let image = page.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            out += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") + "\n"
        }
        return out
    }
}

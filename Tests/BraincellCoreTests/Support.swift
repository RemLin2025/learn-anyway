import Foundation
import CoreGraphics
import CoreText
@testable import BraincellCore

func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("braincell-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Writes a real PDF whose pages carry the given strings as selectable text ("" = blank page).
func makePDF(pages: [String], at url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for text in pages {
        ctx.beginPDFPage(nil)
        if !text.isEmpty {
            let attr = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

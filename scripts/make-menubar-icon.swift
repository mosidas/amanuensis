// メニューバーのアイコン 2 つを、元の Resources/MenuBarIcon.svg から AppKit で生成する。
// - 待機時の Resources/MenuBarIcon.pdf: SVG をそのままベクターの PDF に変換する。
// - 録音中の Resources/MenuBarIconRecording.tiff: 正本は amanuensis-menubar-icon-recording.svg
//   (半径 8.5 の円から、下線を除いた羽根ペンを中心 (9,9)・0.92 倍で抜いた形)。AppKit は SVG の <mask> を描けず、
//   PDF は destinationOut を表現できないため、18px(@1x)と 36px(@2x)の 2 表現のビットマップにする。
// アプリは実行時にどちらもテンプレート画像として読む。SVG を変えたら `swift scripts/make-menubar-icon.swift` を実行して作り直す。
import AppKit

let resources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "Resources")
let svg = resources.appending(path: "MenuBarIcon.svg")
let pdf = resources.appending(path: "MenuBarIcon.pdf")
let tiff = resources.appending(path: "MenuBarIconRecording.tiff")

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("make-menubar-icon: \(message)\n".utf8))
  exit(1)
}

guard let image = NSImage(contentsOf: svg) else { fail("SVG を読めない: \(svg.path)") }
var box = CGRect(origin: .zero, size: image.size)
guard let context = CGContext(pdf as CFURL, mediaBox: &box, nil) else {
  fail("PDF を書けない: \(pdf.path)")
}
context.beginPDFPage(nil)
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
image.draw(in: box)
context.endPDFPage()
context.closePDF()
print("make-menubar-icon: \(pdf.path) \(Int(box.width))x\(Int(box.height))")

guard let source = try? String(contentsOf: svg, encoding: .utf8),
  let quill = NSImage(
    data: Data(
      source.replacingOccurrences(of: #"<line[^>]*/>"#, with: "", options: .regularExpression).utf8))
else { fail("下線を除いた羽根ペンの SVG を読めない: \(svg.path)") }

// rep の size を 18pt にすると、NSGraphicsContext が 36px の rep に 2 倍の変換を掛ける。scaleBy は重ねない。
func rep(_ pixels: Int) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: 18, height: 18)
  let graphics = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = graphics
  let cg = graphics.cgContext
  cg.setFillColor(NSColor.black.cgColor)
  cg.fillEllipse(in: CGRect(x: 0.5, y: 0.5, width: 17, height: 17))
  let scale = 0.92
  quill.draw(
    in: CGRect(x: 9 - 9 * scale, y: 9 - 9 * scale, width: 18 * scale, height: 18 * scale),
    from: .zero, operation: .destinationOut, fraction: 1)
  NSGraphicsContext.current = nil
  return rep
}

let recording = NSImage(size: NSSize(width: 18, height: 18))
recording.addRepresentation(rep(18))
recording.addRepresentation(rep(36))
guard let data = recording.tiffRepresentation(using: .lzw, factor: 0),
  (try? data.write(to: tiff)) != nil
else { fail("TIFF を書けない: \(tiff.path)") }
print("make-menubar-icon: \(tiff.path) 18x18 @1x @2x")

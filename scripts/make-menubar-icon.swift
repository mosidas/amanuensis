// メニューバーのアイコン Resources/MenuBarIcon.pdf を、元の Resources/MenuBarIcon.svg から AppKit でベクターの PDF に変換して生成する。
// アプリは実行時に PDF をテンプレート画像として読む。SVG を変えたら `swift scripts/make-menubar-icon.swift` を実行して作り直す。
import AppKit

let resources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "Resources")
let svg = resources.appending(path: "MenuBarIcon.svg")
let pdf = resources.appending(path: "MenuBarIcon.pdf")
guard let image = NSImage(contentsOf: svg) else {
  FileHandle.standardError.write(Data("make-menubar-icon: SVG を読めない: \(svg.path)\n".utf8))
  exit(1)
}
var box = CGRect(origin: .zero, size: image.size)
guard let context = CGContext(pdf as CFURL, mediaBox: &box, nil) else {
  FileHandle.standardError.write(Data("make-menubar-icon: PDF を書けない: \(pdf.path)\n".utf8))
  exit(1)
}
context.beginPDFPage(nil)
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
image.draw(in: box)
context.endPDFPage()
context.closePDF()
print("make-menubar-icon: \(pdf.path) \(Int(box.width))x\(Int(box.height))")

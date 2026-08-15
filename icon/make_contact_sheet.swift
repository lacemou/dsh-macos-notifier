// 生成三概念对比图（含标签）
import AppKit

func load(_ name: String) -> NSImage {
    let url = URL(fileURLWithPath: name)
    return NSImage(contentsOf: url)!
}

let files = Array(CommandLine.arguments.dropFirst())
let cell: CGFloat = 340
let labelH: CGFloat = 56
let pad: CGFloat = 48
let count = files.count
let W = CGFloat(count) * cell + CGFloat(count + 1) * pad
let H = cell + labelH + pad * 2

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

for (i, f) in files.enumerated() {
    let source = load(f)
    let x = pad + CGFloat(i) * (cell + pad)
    let y = pad + labelH
    // 圆角遮罩
    let rect = NSRect(x: x, y: y, width: cell, height: cell)
    let path = NSBezierPath(roundedRect: rect, xRadius: cell * 0.2237, yRadius: cell * 0.2237)
    path.addClip()
    source.draw(in: rect)
    // 标签
    let label = (f as NSString).lastPathComponent.replacingOccurrences(of: "concept-", with: "").replacingOccurrences(of: "-1024.png", with: "")
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)
    ]
    let size = label.size(withAttributes: attrs)
    label.draw(at: NSPoint(x: x + (cell - size.width) / 2, y: y - labelH * 0.45), withAttributes: attrs)
}
img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: "preview/contact-sheet.png")
try? png.write(to: out)
print("已输出: \(out.path)")

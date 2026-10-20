import AppKit

// 生成一张带文字「垃圾607」的图标 PNG（指定像素尺寸）。
func renderIcon(text: String, size: CGFloat) -> Data? {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return nil
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // 圆角背景 + 渐变
    let radius = size * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()

    let colors = [NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.75, alpha: 1).cgColor] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [])
    }

    // 文字：中文一行 + 数字一行
    let cn = "垃圾"
    let num = "607"

    func draw(_ s: String, fontSize: CGFloat, centerY: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let bounds = str.size()
        let r = CGRect(x: 0, y: centerY - bounds.height / 2,
                       width: size, height: bounds.height)
        str.draw(in: r)
    }

    draw(cn, fontSize: size * 0.34, centerY: size * 0.62)
    draw(num, fontSize: size * 0.30, centerY: size * 0.30)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: GenIcon <outDir> <size1> [size2 ...]\n".data(using: .utf8)!)
    exit(1)
}
let outDir = args[1]
let sizes = args[2...].compactMap { Int($0) }
for s in sizes {
    guard let data = renderIcon(text: "垃圾607", size: CGFloat(s)) else {
        FileHandle.standardError.write("render failed at \(s)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(s).png")
    try? data.write(to: url)
}

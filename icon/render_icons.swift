// DSH Notch Notifier 图标渲染器
// 用法：swift render_icons.swift <concept> <输出目录> [尺寸]
//   concept: A | B | C
// 纯 CoreGraphics 绘制，输出 PNG（全出血 1024 方图，macOS 11+ 由系统套用 squircle 蒙版）
import AppKit

// MARK: - 工具

func spow(_ v: CGFloat, _ p: CGFloat) -> CGFloat {
    v >= 0 ? pow(v, p) : -pow(-v, p)
}

/// 超椭圆（squircle，n=5 接近 iOS/macOS 图标轮廓）
func superellipsePath(center: CGPoint, halfW: CGFloat, halfH: CGFloat, n: CGFloat = 5, steps: Int = 240) -> CGPath {
    let path = CGMutablePath()
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let x = center.x + spow(cos(t), 2 / n) * halfW
        let y = center.y + spow(sin(t), 2 / n) * halfH
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func makeContext(size: CGFloat) -> CGContext {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    // 左上原点，y 向下（与屏幕一致，方便设计）
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func savePNG(ctx: CGContext, size: CGFloat, to url: URL) {
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    let png = rep.representation(using: .png, properties: [:])!
    try? png.write(to: url)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linearGradient(_ ctx: CGContext, colors: [CGColor], from a: CGPoint, to b: CGPoint) {
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(grad, start: a, end: b, options: [])
}

func radialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, colorIn: CGColor, colorOut: CGColor) {
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [colorIn, colorOut] as CFArray, locations: nil)!
    ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// MARK: - 概念 A：DeepSeek 蓝底 + 白色铃铛 + 状态点

func drawConceptA(_ ctx: CGContext, s: CGFloat) {
    // 背景渐变（左上浅蓝 → 右下深蓝）
    linearGradient(ctx, colors: [color(0x5B7CFF), color(0x4D6BFE), color(0x2F42C4)],
                   from: CGPoint(x: 0, y: 0), to: CGPoint(x: s, y: s))
    // 左上柔光
    radialGlow(ctx, center: CGPoint(x: s * 0.22, y: s * 0.18), radius: s * 0.75,
               colorIn: color(0xFFFFFF, 0.22), colorOut: color(0xFFFFFF, 0))
    // 底部轻微暗角
    radialGlow(ctx, center: CGPoint(x: s * 0.5, y: s * 1.05), radius: s * 0.85,
               colorIn: color(0x0A1030, 0.28), colorOut: color(0x0A1030, 0))

    // 铃铛（以画布中心为基准，铃铛高约 0.52s）
    let cx = s * 0.5
    let cy = s * 0.54          // 铃铛中心（y 向下坐标系）
    let h = s * 0.52           // 铃铛总高
    let w = s * 0.40           // 铃铛宽
    let topY = cy - h * 0.5    // 穹顶顶
    let domeR = w * 0.5        // 穹顶半径
    let domeC = CGPoint(x: cx, y: topY + domeR)
    let sideY = topY + domeR * 2          // 穹顶底边 y
    let flare = w * 0.11                  // 下摆外扩
    let bottomY = cy + h * 0.5            // 下摆底
    let clapperR = s * 0.042

    // 铃铛投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.05,
                  color: color(0x0A1030, 0.35))

    let bell = CGMutablePath()
    bell.move(to: CGPoint(x: cx - w * 0.5, y: sideY))
    bell.addArc(center: domeC, radius: domeR, startAngle: .pi, endAngle: 0, clockwise: false)
    bell.addLine(to: CGPoint(x: cx + w * 0.5, y: sideY))
    // 右侧下摆
    bell.addQuadCurve(to: CGPoint(x: cx + w * 0.5 + flare, y: bottomY),
                      control: CGPoint(x: cx + w * 0.5, y: sideY + (bottomY - sideY) * 0.6))
    // 下摆底弧
    bell.addQuadCurve(to: CGPoint(x: cx - w * 0.5 - flare, y: bottomY),
                      control: CGPoint(x: cx, y: bottomY + s * 0.05))
    bell.addQuadCurve(to: CGPoint(x: cx - w * 0.5, y: sideY),
                      control: CGPoint(x: cx - w * 0.5, y: sideY + (bottomY - sideY) * 0.6))
    bell.closeSubpath()
    ctx.addPath(bell)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // 铃舌（圆点）
    ctx.addEllipse(in: CGRect(x: cx - clapperR, y: bottomY + s * 0.035,
                              width: clapperR * 2, height: clapperR * 2))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()

    // 右下状态点（柔绿，呼应"在线/完成"）
    let dotC = CGPoint(x: cx + w * 0.52, y: cy + h * 0.30)
    let dotR = s * 0.046
    radialGlow(ctx, center: dotC, radius: dotR * 2.6,
               colorIn: color(0x67F0B0, 0.45), colorOut: color(0x67F0B0, 0))
    ctx.addEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
    ctx.setFillColor(color(0x7CF5BC))
    ctx.fillPath()
}

// MARK: - 概念 B：深色"刘海夜屏" + 光点

func drawConceptB(_ ctx: CGContext, s: CGFloat) {
    // 背景：深空渐变
    linearGradient(ctx, colors: [color(0x22252E), color(0x17181D), color(0x101116)],
                   from: CGPoint(x: 0, y: 0), to: CGPoint(x: s, y: s))
    // 顶部微光
    radialGlow(ctx, center: CGPoint(x: s * 0.5, y: s * 0.02), radius: s * 0.6,
               colorIn: color(0xFFFFFF, 0.06), colorOut: color(0xFFFFFF, 0))

    // 刘海缺口（顶部居中的胶囊，挖空效果 = 与背景同色覆盖）
    let notchW = s * 0.30
    let notchH = s * 0.055
    let notchRect = CGRect(x: s * 0.5 - notchW / 2, y: -notchH * 0.35,
                           width: notchW, height: notchH)
    ctx.addPath(CGPath(roundedRect: notchRect, cornerWidth: notchH * 0.5, cornerHeight: notchH * 0.5, transform: nil))
    ctx.setFillColor(color(0x101116))   // 与底部背景同色，形成挖空感
    ctx.fillPath()

    // 中央光点：外圈柔光 + 蓝核 + 白芯
    let c = CGPoint(x: s * 0.5, y: s * 0.46)
    radialGlow(ctx, center: c, radius: s * 0.30,
               colorIn: color(0x4D6BFE, 0.55), colorOut: color(0x4D6BFE, 0))
    ctx.addEllipse(in: CGRect(x: c.x - s * 0.085, y: c.y - s * 0.085, width: s * 0.17, height: s * 0.17))
    ctx.setFillColor(color(0x5B7CFF))
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: c.x - s * 0.032, y: c.y - s * 0.032, width: s * 0.064, height: s * 0.064))
    ctx.setFillColor(color(0xFFFFFF, 0.95))
    ctx.fillPath()

    // 下方细弧（呼应"事件流/波纹"，克制的一笔）
    let arcR = s * 0.155
    ctx.addArc(center: c, radius: arcR, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
    ctx.setStrokeColor(color(0xFFFFFF, 0.28))
    ctx.setLineWidth(s * 0.012)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

// MARK: - 概念 C：极简光点（立体版：金属环 + 球体光影）

func drawConceptC(_ ctx: CGContext, s: CGFloat) {
    // 背景：午夜蓝渐变 + 左上主光源 + 底部暗角（纵深）
    linearGradient(ctx, colors: [color(0x3B52D6), color(0x2636B4), color(0x151E66)],
                   from: CGPoint(x: 0, y: 0), to: CGPoint(x: s, y: s))
    radialGlow(ctx, center: CGPoint(x: s * 0.20, y: s * 0.16), radius: s * 0.85,
               colorIn: color(0xFFFFFF, 0.16), colorOut: color(0xFFFFFF, 0))
    radialGlow(ctx, center: CGPoint(x: s * 0.5, y: s * 1.10), radius: s * 0.90,
               colorIn: color(0x05081F, 0.38), colorOut: color(0x05081F, 0))

    let cx = s * 0.5
    let cy = s * 0.50
    let ringR = s * 0.215        // 环外半径
    let ringW = s * 0.030        // 环宽
    let innerR = ringR - ringW   // 环内半径
    let dotR = s * 0.060
    let dotC = CGPoint(x: cx, y: cy + s * 0.045)

    // 元素背后的大气光晕
    radialGlow(ctx, center: CGPoint(x: cx, y: cy), radius: s * 0.42,
               colorIn: color(0x6E86FF, 0.20), colorOut: color(0x6E86FF, 0))

    // 环内凹面（极淡暗色渐变，让环像"陷进去"的实体）
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: cx - innerR, y: cy - innerR, width: innerR * 2, height: innerR * 2))
    ctx.clip()
    radialGlow(ctx, center: CGPoint(x: cx, y: cy), radius: innerR,
               colorIn: color(0x0B1138, 0.30), colorOut: color(0x0B1138, 0))
    ctx.restoreGState()

    // 环（torus）：环形路径
    let annulus = CGMutablePath()
    annulus.addEllipse(in: CGRect(x: cx - ringR, y: cy - ringR, width: ringR * 2, height: ringR * 2))
    annulus.addEllipse(in: CGRect(x: cx - innerR, y: cy - innerR, width: innerR * 2, height: innerR * 2))

    // 环的投影（向下偏移柔化）
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.045), blur: s * 0.040, color: color(0x05081F, 0.45))
    ctx.addPath(annulus)
    ctx.setFillColor(color(0xFFFFFF, 0.95))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // 环的金属光泽：左上亮 → 右下暗
    ctx.saveGState()
    ctx.addPath(annulus)
    ctx.clip(using: .evenOdd)
    linearGradient(ctx, colors: [color(0xFFFFFF, 0.60), color(0xFFFFFF, 0.06), color(0x0B1138, 0.38)],
                   from: CGPoint(x: cx - ringR, y: cy - ringR), to: CGPoint(x: cx + ringR, y: cy + ringR))
    ctx.restoreGState()

    // 环的镜面高光弧（左上内侧）
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: innerR + ringW * 0.55,
               startAngle: .pi * 1.05, endAngle: .pi * 1.55, clockwise: false)
    ctx.setStrokeColor(color(0xFFFFFF, 0.78))
    ctx.setLineWidth(ringW * 0.42)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // 球：投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.035), blur: s * 0.032, color: color(0x05081F, 0.50))
    ctx.addEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
    ctx.setFillColor(color(0xFFFFFF, 0.98))
    ctx.fillPath()
    ctx.restoreGState()

    // 球：球面明暗（左上亮 → 右下暗）
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
    ctx.clip()
    radialGlow(ctx, center: CGPoint(x: dotC.x - dotR * 0.35, y: dotC.y - dotR * 0.35), radius: dotR * 1.7,
               colorIn: color(0xFFFFFF, 1.0), colorOut: color(0xB7C4FF, 0.18))
    radialGlow(ctx, center: CGPoint(x: dotC.x + dotR * 0.45, y: dotC.y + dotR * 0.55), radius: dotR * 1.6,
               colorIn: color(0x3348C8, 0.60), colorOut: color(0x3348C8, 0))
    ctx.restoreGState()

    // 球：镜面高光（小而锐利）
    ctx.addEllipse(in: CGRect(x: dotC.x - dotR * 0.42, y: dotC.y - dotR * 0.54, width: dotR * 0.52, height: dotR * 0.30))
    ctx.setFillColor(color(0xFFFFFF, 0.95))
    ctx.fillPath()
    // 球：底部环境反射（微弱）
    ctx.addEllipse(in: CGRect(x: dotC.x - dotR * 0.26, y: dotC.y + dotR * 0.42, width: dotR * 0.52, height: dotR * 0.16))
    ctx.setFillColor(color(0xFFFFFF, 0.30))
    ctx.fillPath()
}

// MARK: - 主流程

guard CommandLine.arguments.count >= 3 else {
    print("用法: render_icons.swift <A|B|C> <输出目录> [尺寸]")
    exit(1)
}
let concept = CommandLine.arguments[1]
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let size: CGFloat = CommandLine.arguments.count >= 4 ? CGFloat(Double(CommandLine.arguments[3])!) : 1024

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let ctx = makeContext(size: size)
switch concept {
case "A": drawConceptA(ctx, s: size)
case "B": drawConceptB(ctx, s: size)
case "C": drawConceptC(ctx, s: size)
default: fatalError("未知概念: \(concept)")
}

let url = outDir.appendingPathComponent("concept-\(concept)-\(Int(size)).png")
savePNG(ctx: ctx, size: size, to: url)
print("已输出: \(url.path)")

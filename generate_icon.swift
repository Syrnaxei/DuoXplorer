import Cocoa
import Foundation

/// 用代码生成 App 图标 — 遵循 macOS（Big Sur+）图标规范：
/// - 1024 画布，作品区域约 824/1024 居中，四周透明边距（小尺寸按比例放大占比）
/// - 正面平视绘制（无透视），squircle 圆角 + 柔和投影 + 顶面高光
/// - 主体：正面文件夹

/// 各尺寸的作品区域占画布比例：大尺寸 0.824，越小越接近满幅
func artworkFraction(for size: CGFloat) -> CGFloat {
    switch size {
    case ..<24: return 1.0
    case ..<48: return 0.94
    case ..<96: return 0.88
    default: return 0.824
    }
}

func generateAppIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let fraction = artworkFraction(for: size)
    let artwork = size * fraction
    let offset = (size - artwork) / 2
    let cornerRadius = artwork * 0.225
    let squircle = CGRect(x: offset, y: offset, width: artwork, height: artwork)

    // 投影（小尺寸省略，避免糊成一团）
    ctx.saveGState()
    if size >= 96 {
        ctx.setShadow(offset: NSSize(width: 0, height: -size * 0.018),
                      blur: size * 0.045,
                      color: CGColor(gray: 0, alpha: 0.35))
    }
    ctx.addPath(CGPath(roundedRect: squircle, cornerWidth: cornerRadius,
                       cornerHeight: cornerRadius, transform: nil))
    ctx.setFillColor(CGColor(red: 0.10, green: 0.38, blue: 0.90, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 背景渐变 + 顶面高光（裁剪到 squircle 内）
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: squircle, cornerWidth: cornerRadius,
                       cornerHeight: cornerRadius, transform: nil))
    ctx.clip()

    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(srgbRed: 16/255.0, green: 110/255.0, blue: 105/255.0, alpha: 1),
        CGColor(srgbRed: 122/255.0, green: 219/255.0, blue: 212/255.0, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: offset),
                           end: CGPoint(x: 0, y: offset + artwork), options: [])

    let glass = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(gray: 1, alpha: 0.28),
        CGColor(gray: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(glass,
                           start: CGPoint(x: 0, y: offset + artwork),
                           end: CGPoint(x: 0, y: offset + artwork * 0.45),
                           options: [])

    // 文件夹主体（坐标均为 squircle 内的归一化比例，y 向上）
    let A = artwork
    let x0 = offset, y0 = offset
    func rect(_ nx: CGFloat, _ ny: CGFloat, _ nw: CGFloat, _ nh: CGFloat, _ nr: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x0 + nx * A, y: y0 + ny * A,
                                   width: nw * A, height: nh * A),
               cornerWidth: nr * A, cornerHeight: nr * A, transform: nil)
    }

    // 背板 + 标签页（较深蓝，上缘露出）
    let backGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(gray: 1, alpha: 0.10),
        CGColor(gray: 1, alpha: 0.35),
    ] as CFArray, locations: [0, 1])!
    let backTop = CGRect(x: x0 + 0.10 * A, y: y0 + 0.30 * A,
                         width: 0.80 * A, height: 0.44 * A)
    let tab = CGRect(x: x0 + 0.10 * A, y: y0 + 0.30 * A,
                     width: 0.34 * A, height: 0.50 * A)
    ctx.addPath(CGPath(roundedRect: backTop, cornerWidth: 0.045 * A,
                       cornerHeight: 0.045 * A, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(backGrad, start: CGPoint(x: 0, y: y0 + 0.30 * A),
                           end: CGPoint(x: 0, y: y0 + 0.80 * A), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tab, cornerWidth: 0.045 * A,
                       cornerHeight: 0.045 * A, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(backGrad, start: CGPoint(x: 0, y: y0 + 0.30 * A),
                           end: CGPoint(x: 0, y: y0 + 0.80 * A), options: [])
    ctx.restoreGState()

    // 前板（白色系，占文件夹下半部）
    ctx.saveGState()
    let front = CGRect(x: x0 + 0.10 * A, y: y0 + 0.24 * A,
                       width: 0.80 * A, height: 0.44 * A)
    ctx.addPath(CGPath(roundedRect: front, cornerWidth: 0.045 * A,
                       cornerHeight: 0.045 * A, transform: nil))
    ctx.clip()
    let frontGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(srgbRed: 0.88, green: 0.98, blue: 0.97, alpha: 1),
        CGColor(gray: 1, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(frontGrad, start: CGPoint(x: 0, y: y0 + 0.24 * A),
                           end: CGPoint(x: 0, y: y0 + 0.68 * A), options: [])

    ctx.restoreGState()

    image.unlockFocus()
    return image
}

// 生成各种尺寸
let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for (size, name) in sizes {
    let icon = generateAppIcon(size: size)
    let data = icon.tiffRepresentation!
    let rep = NSBitmapImageRep(data: data)!
    let pngData = rep.representation(using: .png, properties: [:])!
    let fileURL = outputDir.appendingPathComponent("\(name).png")
    try! pngData.write(to: fileURL)
    print("Generated \(name).png (\(Int(size))x\(Int(size)))")
}

print("Done! All icons generated.")

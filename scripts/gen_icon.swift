#!/usr/bin/env swift
// Dicto 앱 아이콘 생성기 (코드로 그림, 외부 이미지 없음)
// 검은 둥근 사각형 위에 가운데가 높은 흰 파형 막대 — 녹음 오버레이와 같은 모양
// 실행: swift scripts/gen_icon.swift  (또는 make icon)
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                 : "Dicto/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS 아이콘 격자: 1024 캔버스에 824 크기 둥근 사각형, 위쪽에 약간 여유 (그림자 공간)
    let body = CGRect(x: s * 100/1024, y: s * 110/1024, width: s * 824/1024, height: s * 824/1024)
    let radius = s * 185/1024

    // 은은한 그림자
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10/1024), blur: s * 28/1024,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 배경: 위는 살짝 밝은 차콜 → 아래는 검정
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(white: 0.20, alpha: 1).cgColor, NSColor(white: 0.04, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    // 안쪽 테두리 하이라이트 (오버레이 알약의 흰 테두리 느낌)
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: s * 3/1024, dy: s * 3/1024),
                       cornerWidth: radius - s * 3/1024, cornerHeight: radius - s * 3/1024, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    ctx.setLineWidth(s * 5/1024)
    ctx.strokePath()
    ctx.restoreGState()

    // 파형 막대: 가운데가 가장 높고 바깥으로 낮아짐 (좌우 대칭)
    let heights: [CGFloat] = [0.20, 0.38, 0.62, 0.86, 0.62, 0.38, 0.20]
    let barW = s * 62/1024
    let gap = s * 40/1024
    let maxH = s * 470/1024
    let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = body.midX - totalW / 2
    ctx.setFillColor(NSColor(red: 242/255, green: 241/255, blue: 240/255, alpha: 1).cgColor)
    for h in heights {
        let bh = max(barW, maxH * h)
        let r = CGRect(x: x, y: body.midY - bh / 2, width: barW, height: bh)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        ctx.fillPath()
        x += barW + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// macOS 아이콘 세트 규격
var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
let root = outDir.deletingLastPathComponent().appendingPathComponent("Contents.json")
try! #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!.write(to: root)
print("wrote \(outDir.path)")

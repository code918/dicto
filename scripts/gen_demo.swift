#!/usr/bin/env swift
// README용 데모 GIF 생성기 (실제 화면 녹화가 아니라 같은 색·비율로 그린 재현 영상)
// 흐름: 대기 → fn 녹음(파형) → 정리 중 → 정제된 문장이 커서 자리에 붙음
// 실행: swift scripts/gen_demo.swift  (또는 make demo)
import AppKit
import ImageIO
import UniformTypeIdentifiers

let W = 720, H = 460
let FPS = 12
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images/demo.gif")

// 실제 앱과 같은 색
let ink = NSColor(red: 242/255, green: 241/255, blue: 240/255, alpha: 1)
let pillBG = NSColor.black
let desktop = NSColor(white: 0.93, alpha: 1)

let rawLine = "어, 그러면 음… 이거 로그인 화면부터 만들어줘"
let finalLine = "그러면 이거 로그인 화면부터 만들어줘."

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func draw(_ s: String, _ p: CGPoint, _ f: NSFont, _ c: NSColor) {
    (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: c])
}

func width(_ s: String, _ f: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: f]).width
}

func rounded(_ r: CGRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}

/// 파형 막대 높이: 가운데에서 퍼지는 모양 (앱과 동일하게 10개)
func bars(_ t: Double) -> [CGFloat] {
    (0..<10).map { i in
        let d = abs(Double(i) - 4.5) / 4.5                      // 가운데 0, 바깥 1
        let wave = sin(t * 9 + Double(i) * 0.7) * 0.5 + 0.5
        let amp = (1 - d * 0.65) * (0.35 + 0.65 * wave)
        return CGFloat(3 + amp * 23)
    }
}

/// 한 프레임 그리기
/// - phase: 0 대기, 1 녹음, 2 정리 중, 3 결과
func frame(phase: Int, t: Double, progress: CGFloat, typed: Int, caretOn: Bool) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    desktop.setFill()
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // 글 쓰는 창 (메신저/메모 흉내)
    let win = CGRect(x: 60, y: 150, width: CGFloat(W) - 120, height: 270)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: NSColor.black.withAlphaComponent(0.18).cgColor)
    rounded(win, 12, .white)
    ctx.restoreGState()
    rounded(CGRect(x: win.minX, y: win.maxY - 34, width: win.width, height: 34), 12, NSColor(white: 0.96, alpha: 1))
    rounded(CGRect(x: win.minX, y: win.maxY - 34, width: win.width, height: 12), 0, NSColor(white: 0.96, alpha: 1))
    for (i, c) in [NSColor(red: 1, green: 0.37, blue: 0.35, alpha: 1),
                   NSColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                   NSColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
        rounded(CGRect(x: win.minX + 14 + CGFloat(i) * 18, y: win.maxY - 22, width: 11, height: 11), 5.5, c)
    }
    draw("새 메시지", CGPoint(x: win.midX - 28, y: win.maxY - 25), font(12, .medium), NSColor(white: 0.45, alpha: 1))

    // 본문: 정제된 문장이 붙은 자리 + 커서
    let bodyFont = font(17)
    let shown = String(finalLine.prefix(typed))
    let textY = win.maxY - 90
    draw(shown, CGPoint(x: win.minX + 26, y: textY), bodyFont, NSColor(white: 0.12, alpha: 1))
    if caretOn {
        let cx = win.minX + 26 + width(shown, bodyFont) + 1
        rounded(CGRect(x: cx, y: textY - 1, width: 2, height: 21), 1, NSColor(white: 0.2, alpha: 1))
    }

    // 하단 오버레이
    let cy: CGFloat = 46
    switch phase {
    case 0: // 대기: 작은 손잡이
        rounded(CGRect(x: CGFloat(W) / 2 - 20, y: 12, width: 40, height: 6), 3,
                NSColor(white: 0.5, alpha: 0.5))
    default:
        let pw: CGFloat = 132, ph: CGFloat = 52
        let pill = CGRect(x: CGFloat(W) / 2 - pw / 2, y: cy - ph / 2, width: pw, height: ph)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 12, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        rounded(pill, ph / 2, pillBG)
        ctx.restoreGState()
        NSColor.white.withAlphaComponent(0.32).setStroke()
        let border = NSBezierPath(roundedRect: pill.insetBy(dx: 0.75, dy: 0.75), xRadius: ph / 2, yRadius: ph / 2)
        border.lineWidth = 1.5
        border.stroke()

        if phase == 2 { // 정리 중: 아래에서 차오르는 진행 표시
            ctx.saveGState()
            NSBezierPath(roundedRect: pill, xRadius: ph / 2, yRadius: ph / 2).addClip()
            rounded(CGRect(x: pill.minX, y: pill.minY, width: pill.width, height: pill.height * progress), 0,
                    NSColor(white: 1, alpha: 0.16))
            ctx.restoreGState()
        }

        // 파형 (정리 중에는 흐리게 멈춤)
        let hs = phase == 1 ? bars(t) : bars(1.4).map { $0 * 0.45 }
        let barW: CGFloat = 3, gap: CGFloat = 5
        let total = CGFloat(hs.count) * barW + CGFloat(hs.count - 1) * gap
        var x = pill.midX - total / 2
        (phase == 1 ? ink : ink.withAlphaComponent(0.55)).setFill()
        for h in hs {
            let r = CGRect(x: x, y: pill.midY - h / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }

        // 상태 문구
        let label: String
        switch phase {
        case 1: label = "듣는 중 · fn 키로 완료"
        case 2: label = "정리 중…"
        default: label = "붙여넣기 완료"
        }
        let f = font(13, .medium)
        draw(label, CGPoint(x: pill.midX - width(label, f) / 2, y: cy + 40), f, NSColor(white: 0.35, alpha: 1))

        // 녹음 중에는 들리는 말을 그대로 보여줌 (군말 포함)
        if phase == 1 {
            let f2 = font(15)
            let n = min(rawLine.count, Int(t * 11))
            let s = String(rawLine.prefix(n))
            draw(s, CGPoint(x: CGFloat(W) / 2 - width(rawLine, f2) / 2, y: 114), f2, NSColor(white: 0.55, alpha: 1))
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

// ── 시나리오 (초 단위) ──────────────────────────────────────
var frames: [(CGImage, Double)] = []
func add(_ img: CGImage, _ sec: Double) { frames.append((img, sec)) }
let step = 1.0 / Double(FPS)

// 1) 대기 0.6s
for i in 0..<Int(0.6 * Double(FPS)) {
    add(frame(phase: 0, t: 0, progress: 0, typed: 0, caretOn: i % 8 < 5), step)
}
// 2) 녹음 2.6s
for i in 0..<Int(2.6 * Double(FPS)) {
    add(frame(phase: 1, t: Double(i) * step, progress: 0, typed: 0, caretOn: i % 8 < 5), step)
}
// 3) 정리 중 1.0s
let n3 = Int(1.0 * Double(FPS))
for i in 0..<n3 {
    add(frame(phase: 2, t: 0, progress: CGFloat(i) / CGFloat(n3 - 1), typed: 0, caretOn: i % 8 < 5), step)
}
// 4) 붙여넣기: 한 번에 들어가는 느낌으로 아주 빠르게 채운 뒤 유지
let chars = finalLine.count
for i in stride(from: 0, through: chars, by: max(1, chars / 5)) {
    add(frame(phase: 3, t: 0, progress: 1, typed: i, caretOn: true), step * 0.5)
}
add(frame(phase: 3, t: 0, progress: 1, typed: chars, caretOn: true), 1.6)
add(frame(phase: 0, t: 0, progress: 0, typed: chars, caretOn: true), 0.7)

// ── GIF 쓰기 ────────────────────────────────────────────────
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
    fatalError("GIF 생성 실패")
}
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (img, sec) in frames {
    CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: sec]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
print("wrote \(out.path) (\(frames.count) frames)")

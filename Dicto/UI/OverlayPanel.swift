import AppKit
import SwiftUI

/// 포커스를 뺏지 않는 플로팅 패널 공통
class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// 녹음/처리 상태 오버레이: 화면 하단 중앙
final class OverlayPanel: FloatingPanel {
    private let hosting: NSHostingView<OverlayView>
    /// 화면 바닥에서 알약 아래쪽까지 거리
    static let bottomOffset: CGFloat = 14

    init(state: OverlayState) {
        hosting = NSHostingView(rootView: OverlayView(state: state))
        super.init(size: NSSize(width: 200, height: 100))
        contentView = hosting
    }

    func show() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        setContentSize(size)
        let vf = FloatingPanel.targetScreen().visibleFrame
        // 뷰 안쪽 bottom padding(40)을 감안해 알약이 바닥에서 bottomOffset 위에 오게
        let y = vf.minY + Self.bottomOffset - 40
        setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: y))
        orderFrontRegardless()
    }

    func refit() {
        guard isVisible else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let cx = frame.midX
        setContentSize(size)
        setFrameOrigin(NSPoint(x: cx - size.width / 2, y: frame.minY))
    }

    func hide() { orderOut(nil) }
}

/// 대기 중 작은 회색 손잡이
final class IdlePillPanel: FloatingPanel {
    init() {
        super.init(size: NSSize(width: 52, height: 18))
        contentView = NSHostingView(rootView: IdlePillView())
    }

    func show() {
        let vf = FloatingPanel.targetScreen().visibleFrame
        setFrameOrigin(NSPoint(x: vf.midX - frame.width / 2, y: vf.minY + OverlayPanel.bottomOffset - 6))
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

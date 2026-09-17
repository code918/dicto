import AppKit

/// fn(지구본) 키를 단독으로 한 번 눌렀다 뗐을 때 `onTap`을 호출한다.
/// fn + 다른 키 조합(fn+Delete, fn+화살표 등)은 무시.
/// 접근성(손쉬운 사용) 권한이 있어야 전역 이벤트를 받을 수 있다.
final class FnKeyMonitor {
    var onTap: (() -> Void)?

    private var monitors: [Any] = []
    private var fnDownAt: Date?
    private var otherInputSeen = false
    private let maxTapDuration: TimeInterval = 0.7

    private static let fnKeyCode: UInt16 = 63 // kVK_Function

    func start() {
        stop()
        let flagsHandler: (NSEvent) -> Void = { [weak self] e in self?.handleFlags(e) }
        let otherHandler: (NSEvent) -> Void = { [weak self] _ in self?.otherInputSeen = true }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel], handler: otherHandler) { monitors.append(m) }
        // 우리 앱이 활성일 때(메뉴 열림 등)도 동작하도록 로컬 모니터도 등록
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in flagsHandler(e); return e }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown], handler: { e in otherHandler(e); return e }) { monitors.append(m) }
        log.info("FnKeyMonitor started (\(self.monitors.count) monitors)")
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handleFlags(_ e: NSEvent) {
        guard e.keyCode == Self.fnKeyCode else {
            // 다른 modifier(⌘, ⌥ 등)가 눌리면 fn 단독 탭이 아님
            if fnDownAt != nil { otherInputSeen = true }
            return
        }
        let isDown = e.modifierFlags.contains(.function)
        if isDown {
            fnDownAt = Date()
            otherInputSeen = false
        } else if let t = fnDownAt {
            fnDownAt = nil
            let held = Date().timeIntervalSince(t)
            if !otherInputSeen && held < maxTapDuration {
                DispatchQueue.main.async { [weak self] in self?.onTap?() }
            }
        }
    }
}

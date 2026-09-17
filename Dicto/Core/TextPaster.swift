import AppKit
import ApplicationServices

/// 클립보드에 텍스트를 넣고 ⌘V를 쏴서 현재 포커스된 입력창에 붙여넣는다.
enum TextPaster {
    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func paste(_ text: String, restoreClipboard: Bool) {
        let pb = NSPasteboard.general
        let previous = restoreClipboard ? pb.string(forType: .string) : nil

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        // 붙여넣기 대상 앱이 pasteboard를 읽을 시간을 조금 준다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sendCommandV()
            if let previous {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // 그 사이 사용자가 다른 걸 복사하지 않았을 때만 복원
                    if pb.changeCount == ourChange {
                        pb.clearContents()
                        pb.setString(previous, forType: .string)
                    }
                }
            }
        }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

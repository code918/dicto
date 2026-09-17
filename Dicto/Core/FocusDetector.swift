import AppKit
import ApplicationServices

/// 현재 포커스된 UI 요소가 텍스트 입력 가능한지 (접근성 API)
enum FocusDetector {
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField",
    ]

    enum Result { case editable(String), notEditable(String), unknown }

    static func check() -> Result {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return .unknown }
        let el = focused as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? "?"
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = (subroleRef as? String) ?? ""
        let desc = "\(role)\(subrole.isEmpty ? "" : "/\(subrole)")"

        if editableRoles.contains(role) { return .editable(desc) }

        // 웹/Electron 앱의 contenteditable 등: 값이 설정 가능하면 편집 가능으로 간주
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return .editable(desc + "(settable)")
        }
        // 일부 앱은 AXEditable 속성을 노출
        var editableRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXEditable" as CFString, &editableRef) == .success,
           let b = editableRef as? Bool, b {
            return .editable(desc + "(AXEditable)")
        }
        return .notEditable(desc)
    }
}

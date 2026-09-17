import AppKit
import SwiftUI

/// 텍스트 포커스가 없을 때 화면 중앙에 뜨는 "마지막 전사 복사" 팝업 (클릭 가능, 앱 활성화 안 함)
final class CopyPopupPanel: NSPanel {
    private var hosting: NSHostingView<CopyPopupView>?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(text: String) {
        let view = CopyPopupView(text: text,
                                 onCopy: { [weak self] in
                                     NSPasteboard.general.clearContents()
                                     NSPasteboard.general.setString(text, forType: .string)
                                     self?.hide()
                                 },
                                 onClose: { [weak self] in self?.hide() })
        let h = NSHostingView(rootView: view)
        hosting = h
        contentView = h
        h.layoutSubtreeIfNeeded()
        let size = h.fittingSize
        setContentSize(size)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + 40))
        makeKeyAndOrderFront(nil)
    }

    func hide() { orderOut(nil) }

    override func cancelOperation(_ sender: Any?) { hide() } // Esc
}

struct CopyPopupView: View {
    let text: String
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.accentColor)
                    Text("마지막 전사 복사")
                        .font(.system(size: 16, weight: .semibold))
                }
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("\u{201C}\(text)\u{201D}")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .frame(maxWidth: 460)
                .textSelection(.enabled)
            Button(action: onCopy) {
                Text("복사")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.bordered)
        }
        .padding(22)
        .frame(minWidth: 380)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        )
    }
}

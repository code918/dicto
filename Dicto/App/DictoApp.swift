import SwiftUI
import AppKit

@main
struct DictoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            MenuBarLabel(controller: delegate.controller)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var controller: AppController
    var body: some View {
        Image(systemName: controller.phase == .recording ? "waveform.circle.fill"
              : controller.phase == .processing ? "ellipsis.circle" : "waveform")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    /// 앱을 종료하고 0.5초 뒤 같은 번들을 다시 실행
    static func relaunch() {
        FileLog.write("relaunch")
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"\(path)\""]
        try? p.run()
        _exit(0)
    }

    /// ggml-metal 정적 소멸자가 exit() 중에 abort 하므로 atexit 핸들러를 건너뛴다
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FileLog.write("quit")
        _exit(0)
    }
}

struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Group {
            Text(statusLine)
            Text(engineLine)
            if settings.engine == .claude && controller.claudePath == nil {
                Text("Claude CLI 없음 (정제 불가)")
            }
            if let st = controller.appleSTTStatus, settings.sttEngine == .apple {
                Text(st)
            }
            if settings.engine == .apple && !AppleRefiner.isAvailable {
                Text(AppleRefiner.unavailableReason)
            }
            if !controller.accessibilityOK {
                Button("손쉬운 사용 권한 켜기…") { TextPaster.openAccessibilitySettings() }
            }
        }

        Divider()

        Button(controller.phase == .recording ? "녹음 중지 (fn)" : "녹음 시작 (fn)") { controller.toggle() }
            .disabled(controller.phase == .processing)
        if controller.phase == .recording {
            Button("녹음 취소") { controller.cancelRecording() }
        }

        Divider()

        Picker("받아쓰기 엔진", selection: $settings.sttEngine) {
            ForEach(Settings.STTEngine.allCases) { Text($0.label).tag($0) }
        }
        Picker("정제 엔진", selection: $settings.engine) {
            ForEach(Settings.Engine.allCases) { Text($0.label).tag($0) }
        }
        Picker("Claude 모델", selection: $settings.claudeModel) {
            ForEach(Settings.ClaudeModel.allCases) { Text($0.label).tag($0) }
        }
        Toggle("AI로 정제 (끄면 받아쓴 원문 그대로)", isOn: $settings.refineEnabled)
        Toggle("붙여넣기 후 클립보드 복원", isOn: $settings.restoreClipboard)
        Toggle("자주 쓰는 단어 자동 학습", isOn: $settings.learnVocabulary)
        Toggle("효과음", isOn: $settings.playSounds)
        Toggle("대기 중 하단 손잡이 표시", isOn: $settings.showIdlePill)

        Divider()

        if !controller.lastRefined.isEmpty {
            Button("마지막 결과 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controller.lastRefined, forType: .string)
            }
        }
        Button("개인 사전 열기") {
            _ = Settings.loadVocabulary()
            NSWorkspace.shared.open(Settings.dictionaryURL)
        }
        Button("자동 학습된 단어 열기") {
            if !FileManager.default.fileExists(atPath: Vocabulary.learnedURL.path) {
                try? "# 아직 학습된 단어가 없어요\n".write(to: Vocabulary.learnedURL, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(Vocabulary.learnedURL)
        }
        Button("기록 열기") { NSWorkspace.shared.open(Settings.historyURL) }
        Button("모델 다시 로드") { controller.loadModel() }

        Divider()

        Button("Dicto 재시작") { AppDelegate.relaunch() }
            .keyboardShortcut("r")
        Button("Dicto 종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var engineLine: String {
        let stt = settings.sttEngine == .apple ? "Apple 실시간" : "Whisper"
        let refine: String
        if !settings.refineEnabled { refine = "정제 끔" }
        else if settings.engine == .apple { refine = "Apple 온디바이스" }
        else { refine = "Claude \(settings.claudeModel.rawValue)" }
        return "받아쓰기: \(stt)  ·  정제: \(refine)"
    }

    private var statusLine: String {
        switch controller.phase {
        case .idle: return "대기 중 - fn 키를 눌러 녹음"
        case .recording: return "녹음 중… fn 키로 완료"
        case .processing: return "처리 중…"
        }
    }
}

import SwiftUI

/// 오버레이 상태 (메인 스레드에서만 변경)
final class OverlayState: ObservableObject {
    enum Phase: Equatable {
        case recording
        case processing(String)
        case message(String, isError: Bool)
    }

    /// 파형 영역 38px, 막대 2px + 간격 2px → 10개
    static let barCount = 10
    static let maxBarHeight: CGFloat = 26

    @Published var phase: Phase = .recording
    @Published var levels: [CGFloat] = Array(repeating: 2, count: OverlayState.barCount)
    @Published var progress: CGFloat = 0

    /// 새 볼륨은 가운데에 들어가고 기존 값은 바깥으로 퍼진다 (가운데에서 퍼지는 파형)
    func pushLevel(_ rms: Float) {
        let n = levels.count
        let c = n / 2
        // rms 0.01~0.2 → 2~26px (로그 스케일로 작은 소리도 보이게)
        let norm = min(1, max(0, (log10(1 + Double(rms) * 40)) / log10(9)))
        let h = 2 + CGFloat(norm) * (Self.maxBarHeight - 2)
        var next = levels
        // 왼쪽 절반: 바깥으로(인덱스 감소) 한 칸씩, 오른쪽 절반: 바깥으로(인덱스 증가) 한 칸씩
        for i in 0..<(c - 1) { next[i] = levels[i + 1] }
        for i in stride(from: n - 1, through: c + 1, by: -1) { next[i] = levels[i - 1] }
        // 가운데 두 칸에 살짝 다른 값 (자연스러운 흔들림)
        next[c - 1] = h * CGFloat.random(in: 0.85...1.0)
        next[c] = h * CGFloat.random(in: 0.9...1.05)
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 2, count: Self.barCount)
        progress = 0
    }
}

struct OverlayView: View {
    @ObservedObject var state: OverlayState

    private let pillBG = Color.black
    private let pillBorder = Color.white.opacity(0.32)
    private let ink = Color(red: 242/255, green: 241/255, blue: 240/255)

    var body: some View {
        Group {
            switch state.phase {
            case .recording:
                pill(dim: false, progress: 0)
            case .processing:
                pill(dim: true, progress: state.progress)
            case .message(let text, let isError):
                HStack(spacing: 8) {
                    Image(systemName: isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(isError ? Color(red: 1, green: 0.45, blue: 0.4) : Color.green)
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                        .frame(maxWidth: 360)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: 29/255, green: 26/255, blue: 26/255))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(white: 119/255).opacity(0.3), lineWidth: 1))
                )
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 15, y: 25)
        .shadow(color: .black.opacity(0.15), radius: 10)
        .padding(.horizontal, 30)
        .padding(.top, 20)
        .padding(.bottom, 40)
        .animation(.easeOut(duration: 0.15), value: state.phase)
    }

    /// 검은 알약 + 파형 (+ 처리 중 진행 바)
    private func pill(dim: Bool, progress: CGFloat) -> some View {
        HStack(spacing: 0) {
            WaveformView(levels: state.levels, dim: dim)
                .frame(width: 38, height: OverlayState.maxBarHeight)
                .padding(.horizontal, 8)
        }
        .padding(4)
        .frame(height: 34)
        .background(
            ZStack(alignment: .leading) {
                Capsule().fill(pillBG)
                GeometryReader { geo in
                    Capsule()
                        .fill(ink.opacity(0.25))
                        .frame(width: geo.size.width * progress)
                        .animation(.linear(duration: 0.1), value: progress)
                }
            }
        )
        .overlay(Capsule().strokeBorder(pillBorder, lineWidth: 1))
        .clipShape(Capsule())
    }
}

struct WaveformView: View {
    let levels: [CGFloat]
    let dim: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(dim ? 0.5 : 1))
                    .frame(width: 2, height: max(2, min(OverlayState.maxBarHeight, levels[i])))
                    .animation(.linear(duration: 0.08), value: levels[i])
            }
        }
    }
}

/// 대기 중 화면 맨 아래 작은 회색 손잡이 (40x6, #808080, 50%)
struct IdlePillView: View {
    var body: some View {
        Capsule()
            .fill(Color(white: 128/255))
            .opacity(0.5)
            .frame(width: 40, height: 6)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 2)
            .padding(6)
    }
}

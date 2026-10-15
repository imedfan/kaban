import SwiftUI
import KabanBoardCore

struct KabanMascot: View {
    let emoji: String
    let theme: KabanTheme
    var state = "running"
    var size: CGFloat = 24
    var completionTrigger: Int64 = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduced: Bool { systemReduceMotion || AppArguments.qaValue("--qa-reduce-motion") == "yes" }
    private struct Motion { var scale = 1.0; var angle = 0.0 }
    var body: some View {
        Text(emoji).font(.system(size: size * 0.66)).frame(width:size,height:size)
            .background(theme.dark ? Color.white.opacity(0.1) : Color.white.opacity(0.75),in: RoundedRectangle(cornerRadius:size * 0.3))
            .overlay(RoundedRectangle(cornerRadius:size * 0.3).stroke(theme.line,lineWidth:0.5))
            .overlay(alignment:.bottomTrailing) {
                Circle().fill(theme.status(state).0).frame(width:8,height:8).overlay(Circle().stroke(theme.window,lineWidth:2)).offset(x:3,y:3)
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.3).stroke(state == "incident" ? theme.status("incident").0 : .clear, lineWidth: 1))
            .keyframeAnimator(initialValue: 1.0, trigger: completionTrigger) { content, value in
                content.scaleEffect(value)
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    CubicKeyframe(!reduced && !["incident", "waiting", "running"].contains(state) ? 1.14 : 1, duration: 0.18)
                    CubicKeyframe(1, duration: 0.22)
                }
            }
            .keyframeAnimator(initialValue: Motion(), trigger: state) { content, value in
                content.scaleEffect(value.scale).rotationEffect(.degrees(value.angle))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(reduced ? 1 : state == "done" ? 1.14 : state == "running" ? 1.06 : 1, duration: 0.18)
                    CubicKeyframe(1, duration: 0.22)
                }
                KeyframeTrack(\.angle) {
                    CubicKeyframe(!reduced && state == "waiting" ? -6 : 0, duration: 0.12)
                    CubicKeyframe(!reduced && state == "waiting" ? 6 : 0, duration: 0.12)
                    CubicKeyframe(0, duration: 0.16)
                }
            }

    }
}

import SwiftUI

/// La case ronde de la piste C : au cochage elle s'écrase, se remplit d'Ube puis rebondit.
struct CheckCircle: View {
    let isOn: Bool
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.accent, lineWidth: 2.5)
                .opacity(isOn ? 0 : 1)
            Circle()
                .fill(Palette.accent)
                .scaleEffect(isOn ? 1 : 0.3)
                .opacity(isOn ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.46, weight: .heavy))
                .foregroundStyle(Palette.onAccent)
                .scaleEffect(isOn ? 1 : 0.4)
                .opacity(isOn ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(.ySnappy, value: isOn)
        .keyframeAnimator(initialValue: Squash(), trigger: isOn) { content, value in
            content.scaleEffect(x: value.x, y: value.y)
        } keyframes: { _ in
            KeyframeTrack(\.x) {
                SpringKeyframe(1.25, duration: 0.1)
                SpringKeyframe(0.92, duration: 0.12)
                SpringKeyframe(1, duration: 0.25)
            }
            KeyframeTrack(\.y) {
                SpringKeyframe(0.8, duration: 0.1)
                SpringKeyframe(1.1, duration: 0.12)
                SpringKeyframe(1, duration: 0.25)
            }
        }
        .accessibilityHidden(true)
    }

    private struct Squash {
        var x: CGFloat = 1
        var y: CGFloat = 1
    }
}

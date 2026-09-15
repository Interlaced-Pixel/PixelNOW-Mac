import AppKit
import SwiftUI

struct UpdateProgressView: View {
    let release: GitHubRelease
    @ObservedObject var controller: UpdateProgressController

    private struct StepItem: Identifiable {
        let id: Int
        let title: String
    }

    private let steps: [StepItem] = [
        StepItem(id: 0, title: "Start"),
        StepItem(id: 1, title: "Download"),
        StepItem(id: 2, title: "Extract"),
        StepItem(id: 3, title: "Relaunch")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerView
            stepIndicatorView
            progressBarView
            statusDetailsView
            bottomBarView
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.gfnBackgroundGreen)
        .overlay {
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.gfnStroke, lineWidth: 1)
        }
    }

    private var headerView: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.pixelNowGreen.opacity(0.16))
                    .frame(width: 44, height: 44)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.pixelNowGreen.opacity(0.4), lineWidth: 1)
                    }

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.pixelNowGreen)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Updating PixelNOW")
                    .font(.nvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)

                Text("Version \(release.version)")
                    .font(.nvidia(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()
        }
    }

    private var stepIndicatorView: some View {
        let currentStageIndex = controller.progressState.stage.stageIndex

        return HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stepItemView(step: step, currentIndex: currentStageIndex)

                if index < steps.count - 1 {
                    Rectangle()
                        .fill(currentStageIndex > step.id ? Color.pixelNowGreen : Color.white.opacity(0.12))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func stepItemView(step: StepItem, currentIndex: Int) -> some View {
        VStack(spacing: 6) {
            if currentIndex > step.id {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.pixelNowGreen)
            } else if currentIndex == step.id {
                ZStack {
                    Circle()
                        .stroke(Color.pixelNowGreen, lineWidth: 2)
                        .frame(width: 16, height: 16)
                    Circle()
                        .fill(Color.pixelNowGreen)
                        .frame(width: 8, height: 8)
                }
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.24), lineWidth: 1.5)
                    .frame(width: 16, height: 16)
            }

            Text(step.title)
                .font(.nvidia(size: 10, weight: currentIndex == step.id ? .bold : .medium))
                .foregroundStyle(currentIndex >= step.id ? .white : .white.opacity(0.4))
        }
        .frame(width: 62)
    }

    private var progressBarView: some View {
        GeometryReader { proxy in
            let clampedFraction = min(max(controller.progressState.overallFraction, 0.0), 1.0)
            let fillWidth = max(proxy.size.width * CGFloat(clampedFraction), 6)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 8)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.pixelNowGreen)
                    .frame(width: fillWidth, height: 8)
                    .animation(.easeInOut(duration: 0.25), value: controller.progressState.overallFraction)
            }
        }
        .frame(height: 8)
    }

    private var statusDetailsView: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(controller.progressState.title)
                .font(.nvidia(size: 12, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            Text(controller.progressState.detail)
                .font(.nvidia(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var bottomBarView: some View {
        HStack(spacing: 12) {
            if let error = controller.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.nvidia(size: 11, weight: .regular))
                    .foregroundStyle(.orange)
                    .lineLimit(2)

                Spacer()

                Button("Dismiss") {
                    controller.dismiss()
                }
                .buttonStyle(SecondaryLoginButtonStyle(compact: true))
            } else {
                if !controller.canCancel {
                    Text("Applying update... please do not quit")
                        .font(.nvidia(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Spacer()

                Button("Cancel") {
                    controller.cancel()
                }
                .buttonStyle(SecondaryLoginButtonStyle(compact: true))
                .disabled(!controller.canCancel)
                .opacity(controller.canCancel ? 1.0 : 0.35)
            }
        }
    }
}

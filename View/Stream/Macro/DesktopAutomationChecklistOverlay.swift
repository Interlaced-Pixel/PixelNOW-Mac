import SwiftUI

/// Interactive on-screen checklist overlay displaying the real-time progress
/// of the 8-step SalsaNOW Desktop Mode automation with Cancel and Reset/Retry controls.
public struct DesktopAutomationChecklistOverlay: View {
    public let snapshot: DesktopAutomationSnapshot
    public let onCancel: () -> Void
    public let onReset: () -> Void
    public let onDismiss: () -> Void

    @State private var isCollapsed = false
    @State private var isHoveringCancel = false
    @State private var isHoveringReset = false

    public init(
        snapshot: DesktopAutomationSnapshot,
        onCancel: @escaping () -> Void,
        onReset: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.onCancel = onCancel
        self.onReset = onReset
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            if !isCollapsed {
                Divider()
                    .background(NativeNVSTMediaStreamTheme.divider)
                stepsList
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Divider()
                    .background(NativeNVSTMediaStreamTheme.divider)
                actionToolbar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: isCollapsed ? 280 : 330)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(NativeNVSTMediaStreamTheme.surface.opacity(0.92))
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(overlayBorderColor, lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isCollapsed)
        .animation(.easeInOut(duration: 0.2), value: snapshot)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIconName)
                .font(.nativeNVSTStreamNvidia(size: 13, weight: .bold))
                .foregroundStyle(headerIconColor)

            Text("Desktop Setup")
                .font(.nativeNVSTStreamNvidia(size: 12, weight: .bold))
                .foregroundStyle(NativeNVSTMediaStreamTheme.textPrimary)

            Spacer()

            statusBadge

            Button {
                isCollapsed.toggle()
            } label: {
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.nativeNVSTStreamNvidia(size: 11, weight: .bold))
                    .foregroundStyle(NativeNVSTMediaStreamTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand Checklist" : "Minimize Checklist")

            if snapshot.isComplete || snapshot.isCancelled || snapshot.error != nil {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.nativeNVSTStreamNvidia(size: 10, weight: .bold))
                        .foregroundStyle(NativeNVSTMediaStreamTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss Overlay")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if !snapshot.isComplete && !snapshot.isCancelled && snapshot.error == nil {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color.pixelNowGreen)
            }
            Text(statusBadgeText)
                .font(.nativeNVSTStreamNvidia(size: 10, weight: .bold))
                .foregroundStyle(statusBadgeTextColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(statusBadgeBackground)
        .clipShape(Capsule())
    }

    private var statusBadgeText: String {
        if snapshot.isComplete {
            return "READY"
        } else if snapshot.isCancelled {
            return "CANCELLED"
        } else if snapshot.error != nil {
            return "FAILED"
        } else {
            return "STEP \(snapshot.currentStep.rawValue + 1)/\(DesktopAutomationStep.allCases.count)"
        }
    }

    private var statusBadgeBackground: Color {
        if snapshot.isComplete {
            return Color.pixelNowGreen.opacity(0.2)
        } else if snapshot.isCancelled {
            return Color.orange.opacity(0.2)
        } else if snapshot.error != nil {
            return Color.red.opacity(0.2)
        } else {
            return Color.pixelNowGreen.opacity(0.15)
        }
    }

    private var statusBadgeTextColor: Color {
        if snapshot.isComplete {
            return Color.pixelNowGreen
        } else if snapshot.isCancelled {
            return Color.orange
        } else if snapshot.error != nil {
            return Color.red
        } else {
            return Color.pixelNowGreen
        }
    }

    private var headerIconName: String {
        if snapshot.isComplete {
            return "checkmark.circle.fill"
        } else if snapshot.isCancelled {
            return "slash.circle.fill"
        } else if snapshot.error != nil {
            return "exclamationmark.triangle.fill"
        } else {
            return "desktopcomputer"
        }
    }

    private var headerIconColor: Color {
        if snapshot.isComplete {
            return Color.pixelNowGreen
        } else if snapshot.isCancelled {
            return Color.orange
        } else if snapshot.error != nil {
            return Color.red
        } else {
            return Color.pixelNowGreen
        }
    }

    private var overlayBorderColor: Color {
        if snapshot.isComplete {
            return Color.pixelNowGreen.opacity(0.4)
        } else if snapshot.error != nil {
            return Color.red.opacity(0.4)
        } else {
            return Color.white.opacity(0.12)
        }
    }

    // MARK: - Steps List

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(DesktopAutomationStep.allCases) { step in
                stepRow(step: step)
            }
        }
    }

    private func stepRow(step: DesktopAutomationStep) -> some View {
        let status = snapshot.statuses[step] ?? .pending
        let isCurrent = snapshot.currentStep == step && !snapshot.isComplete && !snapshot.isCancelled

        return HStack(alignment: .top, spacing: 9) {
            stepIcon(for: status, isCurrent: isCurrent)
                .frame(width: 15, height: 15)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(step.rawValue + 1). \(step.title)")
                    .font(.nativeNVSTStreamNvidia(size: 11, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(stepTitleColor(for: status, isCurrent: isCurrent))
                    .lineLimit(1)

                if isCurrent && !snapshot.detailMessage.isEmpty {
                    Text(snapshot.detailMessage)
                        .font(.nativeNVSTStreamNvidia(size: 10, weight: .regular))
                        .foregroundStyle(NativeNVSTMediaStreamTheme.accentSoft)
                        .lineLimit(2)
                        .transition(.opacity)
                } else if case .failed(let err) = status {
                    Text(err)
                        .font(.nativeNVSTStreamNvidia(size: 10, weight: .regular))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func stepIcon(for status: DesktopStepStatus, isCurrent: Bool) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.pixelNowGreen)
        case .inProgress:
            ProgressView()
                .controlSize(.mini)
                .tint(Color.pixelNowGreen)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.red)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.24))
        }
    }

    private func stepTitleColor(for status: DesktopStepStatus, isCurrent: Bool) -> Color {
        switch status {
        case .completed:
            return NativeNVSTMediaStreamTheme.textPrimary
        case .inProgress:
            return Color.white
        case .failed:
            return Color.red
        case .pending:
            return NativeNVSTMediaStreamTheme.textTertiary
        }
    }

    // MARK: - Action Toolbar

    private var actionToolbar: some View {
        HStack(spacing: 8) {
            // Reset / Retry Button
            Button(action: onReset) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.nativeNVSTStreamNvidia(size: 10, weight: .bold))
                    Text(snapshot.error != nil || snapshot.isCancelled ? "Retry" : "Reset")
                        .font(.nativeNVSTStreamNvidia(size: 11, weight: .medium))
                }
                .foregroundStyle(NativeNVSTMediaStreamTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isHoveringReset ? 0.16 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringReset = $0 }
            .help("Restart automation from Step 1")

            Spacer()

            // Cancel Button
            Button(action: onCancel) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.circle")
                        .font(.nativeNVSTStreamNvidia(size: 10, weight: .bold))
                    Text("Cancel")
                        .font(.nativeNVSTStreamNvidia(size: 11, weight: .medium))
                }
                .foregroundStyle(snapshot.isComplete || snapshot.isCancelled ? NativeNVSTMediaStreamTheme.textTertiary : Color.red.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(snapshot.isComplete || snapshot.isCancelled ? Color.clear : Color.red.opacity(isHoveringCancel ? 0.2 : 0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(snapshot.isComplete || snapshot.isCancelled ? Color.white.opacity(0.06) : Color.red.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(snapshot.isComplete || snapshot.isCancelled)
            .onHover { isHoveringCancel = $0 }
            .help("Cancel running automation")
        }
    }
}

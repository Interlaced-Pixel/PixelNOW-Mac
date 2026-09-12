import SwiftUI
import GameController

struct ControllerBatteryIndicator: View {
    let level: Float
    let state: GCDeviceBattery.State

    var body: some View {
        HStack(spacing: 6) {
            batteryIcon
            Text(String(format: "%.0f%%", level * 100))
                .font(.nvidia(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.84))
        }
    }

    @ViewBuilder
    private var batteryIcon: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let cornerRadius = height * 0.15
            let terminalWidth = width * 0.1
            let terminalHeight = height * 0.4
            
            ZStack(alignment: .leading) {
                // Battery Body
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.5), lineWidth: 1)
                    .frame(width: width - terminalWidth, height: height)
                
                // Positive Terminal
                Path { path in
                    path.move(to: CGPoint(x: width - terminalWidth, y: (height - terminalHeight) / 2))
                    path.addLine(to: CGPoint(x: width, y: (height - terminalHeight) / 2))
                    path.addLine(to: CGPoint(x: width, y: (height + terminalHeight) / 2))
                    path.addLine(to: CGPoint(x: width - terminalWidth, y: (height + terminalHeight) / 2))
                }
                .fill(.white.opacity(0.5))
                
                // Battery Level Fill
                let padding: CGFloat = 1.5
                let fillWidth = max(0, (width - terminalWidth - padding * 2) * CGFloat(level))
                RoundedRectangle(cornerRadius: cornerRadius * 0.5, style: .continuous)
                    .fill(fillColor)
                    .frame(width: fillWidth, height: height - padding * 2)
                    .padding(padding)
                
                // Charging Indicator
                if state == .charging {
                    Image(systemName: "bolt.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                        .frame(width: width - terminalWidth, height: height)
                }
            }
        }
        .frame(width: 22, height: 10)
    }
    
    private var fillColor: Color {
        if state == .charging {
            return Color.pixelNowGreen
        }
        if level <= 0.2 {
            return .red
        }
        if level <= 0.35 {
            return .orange
        }
        return Color.pixelNowGreen
    }
}

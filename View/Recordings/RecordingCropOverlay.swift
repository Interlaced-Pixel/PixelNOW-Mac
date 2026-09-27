import SwiftUI

struct RecordingCropOverlay: View {
    private struct CropBox {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    let sourceWidth: CGFloat
    let sourceHeight: CGFloat
    let cropX: Double
    let cropY: Double
    let cropWidth: Double
    let cropHeight: Double
    let lockedAspectRatio: Double?
    let showsSafeAreaGuides: Bool
    let onBeginEdit: () -> Void
    let onChange: (Double, Double, Double, Double) -> Void

    @State private var moveStart: CropBox?
    @State private var resizeStart: CropBox?

    var body: some View {
        GeometryReader { proxy in
            let videoRect = aspectFitRect(in: proxy.size)
            let cropRect = CGRect(
                x: videoRect.minX + videoRect.width * cropX,
                y: videoRect.minY + videoRect.height * cropY,
                width: videoRect.width * cropWidth,
                height: videoRect.height * cropHeight
            )
            ZStack(alignment: .topLeading) {
                if showsSafeAreaGuides {
                    safeGuide(in: videoRect, inset: 0.05, color: .white.opacity(0.42))
                    safeGuide(in: videoRect, inset: 0.10, color: .yellow.opacity(0.5))
                }
                Path { path in
                    path.addRect(videoRect)
                    path.addRect(cropRect)
                }
                .fill(Color.black.opacity(0.48), style: FillStyle(eoFill: true))
                Rectangle()
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: cropRect.width, height: cropRect.height)
                    .position(x: cropRect.midX, y: cropRect.midY)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(in: videoRect))
                    .accessibilityLabel("Crop selection")
                    .accessibilityValue("X \(Int(cropX * 100)) percent, Y \(Int(cropY * 100)) percent, width \(Int(cropWidth * 100)) percent, height \(Int(cropHeight * 100)) percent")
                Circle()
                    .fill(RecordingsLayout.accent)
                    .overlay { Circle().stroke(.white, lineWidth: 1.5) }
                    .frame(width: 18, height: 18)
                    .position(x: cropRect.maxX, y: cropRect.maxY)
                    .gesture(resizeGesture(in: videoRect))
                    .accessibilityLabel("Resize crop")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(true)
    }

    private func aspectFitRect(in size: CGSize) -> CGRect {
        let width = max(sourceWidth, 1)
        let height = max(sourceHeight, 1)
        let scale = min(size.width / width, size.height / height)
        let fitted = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    private func safeGuide(in rect: CGRect, inset: CGFloat, color: Color) -> some View {
        Rectangle()
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(width: rect.width * (1 - inset * 2), height: rect.height * (1 - inset * 2))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    private func moveGesture(in videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if moveStart == nil {
                    onBeginEdit()
                    moveStart = CropBox(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
                }
                guard let start = moveStart else { return }
                let nextX = min(max(0, start.x + Double(value.translation.width / max(videoRect.width, 1))), 1 - start.width)
                let nextY = min(max(0, start.y + Double(value.translation.height / max(videoRect.height, 1))), 1 - start.height)
                onChange(nextX, nextY, start.width, start.height)
            }
            .onEnded { _ in moveStart = nil }
    }

    private func resizeGesture(in videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeStart == nil {
                    onBeginEdit()
                    resizeStart = CropBox(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
                }
                guard let start = resizeStart else { return }
                var width = min(max(0.05, start.width + Double(value.translation.width / max(videoRect.width, 1))), 1 - start.x)
                var height = min(max(0.05, start.height + Double(value.translation.height / max(videoRect.height, 1))), 1 - start.y)
                if let ratio = lockedAspectRatio, ratio.isFinite, ratio > 0 {
                    width = min(max(0.05, width), (1 - start.y) * ratio)
                    height = width / ratio
                    if height > 1 - start.y {
                        height = 1 - start.y
                        width = height * ratio
                    }
                }
                onChange(start.x, start.y, width, height)
            }
            .onEnded { _ in resizeStart = nil }
    }
}

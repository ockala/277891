import SwiftUI

/// 检测框覆盖层：把原图像素坐标的检测框按比例映射到显示尺寸上绘制。
///
/// - `imageSize`：原图尺寸（像素）。
/// - `displaySize`：图片在屏幕上的显示区域尺寸；图片按 aspectFit 居中显示，
///   本视图按同样的 fitted 规则计算框的位置。
/// - 点选某个框时调用 `onSelect`，被选中的框用黄色加粗高亮。
struct DetectionOverlayView: View {
    let imageSize: CGSize
    let displaySize: CGSize
    let detections: [Detection]
    var selectedID: UUID?
    var onSelect: (Detection) -> Void

    /// 图片按 aspectFit 在 displaySize 内实际占用的矩形。
    private func fittedRect() -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              displaySize.width > 0, displaySize.height > 0 else {
            return .zero
        }
        let scale = min(displaySize.width / imageSize.width,
                        displaySize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (displaySize.width - width) / 2,
                      y: (displaySize.height - height) / 2,
                      width: width, height: height)
    }

    /// 原图像素坐标 -> 显示坐标。
    private func mappedBox(_ box: CGRect) -> CGRect {
        let fit = fittedRect()
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scaleX = fit.width / imageSize.width
        let scaleY = fit.height / imageSize.height
        return CGRect(x: fit.minX + box.minX * scaleX,
                      y: fit.minY + box.minY * scaleY,
                      width: box.width * scaleX,
                      height: box.height * scaleY)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(detections) { detection in
                let rect = mappedBox(detection.box)
                let isSelected = detection.id == selectedID
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(isSelected ? Color.yellow : Color.red,
                                lineWidth: isSelected ? 3 : 2)
                    Text("\(DetectionConfig.displayName(for: detection.label)) \(String(format: "%.2f", detection.score))")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background((isSelected ? Color.yellow : Color.red).opacity(0.9))
                }
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
                .onTapGesture { onSelect(detection) }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
    }
}

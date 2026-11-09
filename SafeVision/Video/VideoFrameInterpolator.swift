import CoreGraphics

/// 一次插值得到的框（中间表示，`interpolate` 内部使用后转回 `Detection`）。
public struct InterpolatedBox {
    public let box: CGRect
    public let label: String
    public let score: Float
}

/// 视频检测框插值：视频只隔帧检测，相邻两次检测之间的帧用线性插值补框。
///
/// 对应 Android `VideoDetectionProcessor.blendDetections`，但按本项目管线
/// 规格简化：匹配条件为同标签且 IoU > 0.5，匹配上的框对做纯线性插值；
/// 匹配不上的框不做淡入淡出，靠近哪一端就用哪一端的框（t < 0.5 用上一
/// 帧的框，t >= 0.5 用下一帧的框，另一端不存在的框直接丢弃）。
public enum VideoFrameInterpolator {

    /// 在 `prev` 与 `next` 两次检测之间，对 `frame` 号帧做插值。
    /// `frame` 超出 `[prev.frame, next.frame]` 时钳制到最近一端。
    public static func interpolate(
        prev: (frame: Int, boxes: [Detection]),
        next: (frame: Int, boxes: [Detection]),
        at frame: Int
    ) -> [Detection] {
        let span = next.frame - prev.frame
        guard span > 0 else {
            return frame <= prev.frame ? prev.boxes : next.boxes
        }
        let t = min(max(CGFloat(frame - prev.frame) / CGFloat(span), 0), 1)

        // 贪心匹配：每个上一帧的框找同标签、IoU 最大的下一帧框（IoU > 0.5）。
        var usedNext = [Bool](repeating: false, count: next.boxes.count)
        var interpolated: [InterpolatedBox] = []
        interpolated.reserveCapacity(max(prev.boxes.count, next.boxes.count))

        for prevDetection in prev.boxes {
            var bestIndex = -1
            var bestIoU: CGFloat = 0.5 // 必须严格大于 0.5 才算匹配
            for (index, nextDetection) in next.boxes.enumerated() {
                guard !usedNext[index], nextDetection.label == prevDetection.label else { continue }
                let value = iou(prevDetection.box, nextDetection.box)
                if value > bestIoU {
                    bestIoU = value
                    bestIndex = index
                }
            }
            if bestIndex >= 0 {
                usedNext[bestIndex] = true
                let nextDetection = next.boxes[bestIndex]
                interpolated.append(InterpolatedBox(
                    box: lerpRect(prevDetection.box, nextDetection.box, t),
                    label: prevDetection.label,
                    score: prevDetection.score + (nextDetection.score - prevDetection.score) * Float(t)
                ))
            } else if t < 0.5 {
                // 没有匹配的下一帧框，且更靠近上一端：保留上一帧的框。
                interpolated.append(InterpolatedBox(
                    box: prevDetection.box,
                    label: prevDetection.label,
                    score: prevDetection.score
                ))
            }
            // t >= 0.5 且无匹配：更靠近下一端，那里没有这个框，直接丢弃。
        }

        // 下一帧独有的框：t >= 0.5（更靠近下一端）时出现。
        for (index, nextDetection) in next.boxes.enumerated() where !usedNext[index] {
            if t >= 0.5 {
                interpolated.append(InterpolatedBox(
                    box: nextDetection.box,
                    label: nextDetection.label,
                    score: nextDetection.score
                ))
            }
        }

        return interpolated.map {
            Detection(label: $0.label, score: $0.score, box: $0.box)
        }
    }

    /// 两个矩形的交并比；无交集或任一面积为 0 时返回 0。
    public static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    private static func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.origin.x + (b.origin.x - a.origin.x) * t,
            y: a.origin.y + (b.origin.y - a.origin.y) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }
}

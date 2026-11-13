// InputSense · 废纸篓在哪（纯逻辑）
//
// 废纸篓永远是程序坞的最后一项：程序坞在底部时是最右边那个，在左右两侧时是最下面那个。
// 所以"废纸篓在哪"= "程序坞那一条在哪、每一项占多宽"。有三个信息来源，可信度依次升高：
//   1. 公式：按程序坞的设置（靠哪边、图标大小、项目数、所在显示器）推算那一条的范围；
//   2. 实测：程序坞此刻在屏上时，量出那一条的实际范围（见 `DockBarScan`），废纸篓就是它末端的那一格；
//   3. 自学习：某次拖拽确实把图标送进了废纸篓，松手点就在废纸篓上——用它修正上面两种估算的系统性偏差。
// 公式里的常数是在一台机器上量出来的，见 `docs/模块说明/input-sense.md` 的 b。

import CoreGraphics
import DDMCore
import Foundation

/// 程序坞靠在屏幕的哪一边。
enum DockEdge: String, Sendable, Codable, CaseIterable {
    case bottom
    case left
    case right
}

/// 程序坞的设置里与废纸篓位置有关的全部内容。
struct DockSettings: Sendable, Equatable {
    /// 靠哪一边。
    var edge: DockEdge = .bottom
    /// 设置里的图标大小（点）。项目太多放不下时程序坞会自动缩小，实际大小由 `DockModel` 推算。
    var tileSize: CGFloat = 48
    /// 是否开了"放大"。
    var magnification = false
    /// 放大后的图标大小（点）。
    var largeSize: CGFloat = 0
    /// 是否自动隐藏。
    var autohide = false
    /// 估计的项目数，含访达和废纸篓。占位空格按一项或半项计，所以可以不是整数。
    var tileCount: Double = 2
    /// 分隔线条数。
    var separatorCount = 1
}

/// 这一刻对程序坞的全部了解。
struct DockObservation: Sendable, Equatable {
    var settings: DockSettings
    /// 程序坞所在显示器的范围，全局坐标。
    var displayFrame: CGRect
    /// 这块显示器是查到的，还是只能假定程序坞在主屏。
    var isDisplayKnown = true
    /// 量到的程序坞那一条的范围；此刻量不到（程序坞不在屏上）为 nil。
    var measuredBar: CGRect?
}

/// 程序坞的几何模型。常数来自本机实测（macOS 27，程序坞在底部、被挤满的情形），别的情形未经校准。
enum DockModel {
    /// 每一项占的宽度 − 图标大小。
    static let tileGap: CGFloat = 4.5
    /// 程序坞那一条的厚度（从屏幕边缘算起的可点击范围）− 每一项占的宽度。
    static let barPadding: CGFloat = 12.5
    /// 那一条的两端到第一项、最后一项之间的留白。
    static let endPadding: CGFloat = 10
    /// 一条分隔线占的宽度。
    static let separatorWidth: CGFloat = 12
    /// 项目多到放不下时，那一条最长能到"屏幕长度 − 2 × 这个值"。
    static let edgeMargin: CGFloat = 34
    /// 每一项占的宽度的下限（防止离谱的输入算出零或负数）。
    static let minimumPitch: CGFloat = 16

    /// 沿程序坞方向，这块显示器有多长。
    static func span(of displayFrame: CGRect, edge: DockEdge) -> CGFloat {
        edge == .bottom ? displayFrame.width : displayFrame.height
    }

    /// 按设置推算：那一条有多长、每一项占多宽。
    static func predictedLayout(settings: DockSettings, displayFrame: CGRect) -> (length: CGFloat, pitch: CGFloat) {
        let count = CGFloat(max(settings.tileCount, 2))
        let extras = 2 * endPadding + CGFloat(max(settings.separatorCount, 0)) * separatorWidth
        let naturalPitch = max(settings.tileSize, 16) + tileGap
        let naturalLength = count * naturalPitch + extras
        let longest = max(span(of: displayFrame, edge: settings.edge) - 2 * edgeMargin, extras + count * minimumPitch)
        if naturalLength <= longest {
            return (naturalLength, naturalPitch)
        }
        // 放不下：程序坞把图标缩小到刚好放满。
        return (longest, max((longest - extras) / count, minimumPitch))
    }

    /// 按设置推算那一条的范围：沿所在的边居中。
    static func predictedBar(settings: DockSettings, displayFrame: CGRect) -> (bar: CGRect, pitch: CGFloat) {
        let (length, pitch) = predictedLayout(settings: settings, displayFrame: displayFrame)
        let thickness = pitch + barPadding
        let bar: CGRect
        switch settings.edge {
        case .bottom:
            bar = CGRect(x: displayFrame.midX - length / 2, y: displayFrame.maxY - thickness, width: length, height: thickness)
        case .left:
            bar = CGRect(x: displayFrame.minX, y: displayFrame.midY - length / 2, width: thickness, height: length)
        case .right:
            bar = CGRect(x: displayFrame.maxX - thickness, y: displayFrame.midY - length / 2, width: thickness, height: length)
        }
        return (bar, pitch)
    }

    /// 由量到的厚度反推每一项占多宽。
    static func pitch(forThickness thickness: CGFloat) -> CGFloat {
        max(thickness - barPadding, minimumPitch)
    }

    /// 废纸篓那一格：那一条末端（底部时是右端，左右两侧时是下端）的最后一项。
    static func trashSlot(bar: CGRect, pitch: CGFloat, edge: DockEdge) -> CGRect {
        switch edge {
        case .bottom:
            return CGRect(x: bar.maxX - endPadding - pitch, y: bar.minY, width: pitch, height: bar.height)
        case .left, .right:
            return CGRect(x: bar.minX, y: bar.maxY - endPadding - pitch, width: bar.width, height: pitch)
        }
    }
}

/// 一组程序坞设置的"指纹"。自学习的结果只对学到它时的那组设置有效；指纹变了就重新估算。
/// 不含项目数：开关一个应用，程序坞会变长变短，但公式的系统性偏差大体不变。
struct DockSignature: Sendable, Hashable, Codable {
    var edge: DockEdge
    var tileSize: Double
    var magnification: Bool
    var largeSize: Double
    var autohide: Bool
    var displayWidth: Double
    var displayHeight: Double

    init(_ observation: DockObservation) {
        edge = observation.settings.edge
        tileSize = Double(observation.settings.tileSize)
        magnification = observation.settings.magnification
        largeSize = observation.settings.magnification ? Double(observation.settings.largeSize) : 0
        autohide = observation.settings.autohide
        displayWidth = Double(observation.displayFrame.width)
        displayHeight = Double(observation.displayFrame.height)
    }
}

/// 一次"实际删除"教给我们的东西：松手点比当时的估算（沿程序坞方向）偏了多少。
/// 记的是偏差而不是绝对位置——程序坞变长变短之后，偏差仍然适用，绝对位置就不适用了。
struct TrashLesson: Sendable, Equatable, Codable {
    var signature: DockSignature
    /// 当时的估算是哪一种（`TrashEstimate.Basis` 的原始值）。两种估算的偏差互不通用。
    var basis: String
    /// 松手点 − 当时估算的那一格的中心，沿程序坞方向，点。
    var axisDelta: Double
}

enum TrashEstimator {
    /// 用到的教训最多取最近这么几条。
    static let lessonWindow = 5
    /// 教训的偏差（取中位数）不超过"这个比例 × 一格的宽度"时，说明原估算是对的，不挪位置，只提高可信度。
    static let consistentFraction: CGFloat = 0.35
    /// 偏差超过这么多格的松手点不学：估算再怎么不准也偏不出这么远，多半是别的原因进的废纸篓。
    static let largestLessonInPitches: CGFloat = 3
    /// 几次松手点彼此对不上时，可信度压到这个数——低于"凭位置认定被删"所要求的 0.6。
    static let conflictedConfidence = 0.5

    /// 不考虑自学习时的估算。
    struct Base: Sendable, Equatable {
        /// 废纸篓那一格（不含余量）。
        var slot: CGRect
        /// 每一项占的宽度。
        var pitch: CGFloat
        var basis: TrashEstimate.Basis
        var confidence: Double
    }

    static func base(for observation: DockObservation) -> Base {
        let settings = observation.settings
        var slot: CGRect
        var pitch: CGFloat
        let basis: TrashEstimate.Basis
        var confidence: Double

        if let bar = observation.measuredBar {
            pitch = DockModel.pitch(forThickness: settings.edge == .bottom ? bar.height : bar.width)
            slot = DockModel.trashSlot(bar: bar, pitch: pitch, edge: settings.edge)
            basis = .measured
            confidence = 0.75
        } else {
            let predicted = DockModel.predictedBar(settings: settings, displayFrame: observation.displayFrame)
            pitch = predicted.pitch
            slot = DockModel.trashSlot(bar: predicted.bar, pitch: pitch, edge: settings.edge)
            basis = .formula
            // 左右两侧的公式没有校准过；不知道程序坞在哪块屏时只能假定主屏。
            confidence = settings.edge == .bottom ? 0.45 : 0.3
            if !observation.isDisplayKnown { confidence *= 0.7 }
        }

        // 放大：鼠标靠近时图标变大、整条向两端撑开，废纸篓会往外挪、变大。把区域相应放宽，可信度打折。
        let growth = settings.magnification ? max(0, settings.largeSize - (pitch - DockModel.tileGap)) : 0
        if growth > 0 {
            switch settings.edge {
            case .bottom:
                slot = CGRect(x: slot.minX - growth / 2, y: slot.minY - growth, width: slot.width + growth * 1.5, height: slot.height + growth)
            case .left:
                slot = CGRect(x: slot.minX, y: slot.minY - growth / 2, width: slot.width + growth, height: slot.height + growth * 1.5)
            case .right:
                slot = CGRect(x: slot.minX - growth, y: slot.minY - growth / 2, width: slot.width + growth, height: slot.height + growth * 1.5)
            }
            // 0.75 × 0.75 ≈ 0.56：开了放大时，即使量到了程序坞，也不够"凭位置认定被删"的 0.6。
            confidence *= 0.75
        }
        return Base(slot: slot, pitch: pitch, basis: basis, confidence: confidence)
    }

    /// 最终的估算：基础估算 + 自学习的修正 + 按可信度留的余量。
    static func estimate(observation: DockObservation, lessons: [TrashLesson]) -> TrashEstimate {
        let base = base(for: observation)
        let signature = DockSignature(observation)
        let relevant = lessons.filter { $0.signature == signature && $0.basis == base.basis.rawValue }.suffix(lessonWindow)

        var slot = base.slot
        var confidence = base.confidence
        if !relevant.isEmpty {
            let deltas = relevant.map { CGFloat($0.axisDelta) }.sorted()
            // 取中位数而不是平均：万一混进一条离谱的，不至于把估算带偏。
            let middle = deltas.count / 2
            let typical = deltas.count % 2 == 1 ? deltas[middle] : (deltas[middle - 1] + deltas[middle]) / 2
            let count = Double(deltas.count)
            if abs(typical) <= consistentFraction * base.pitch {
                // 松手点就落在估算的那一格里：估算是对的，不挪，只是更有把握了。
                confidence = 1 - (1 - base.confidence) * pow(0.5, count)
            } else {
                // 估算偏了：把那一格挪到松手点上。
                slot = observation.settings.edge == .bottom ? slot.offsetBy(dx: typical, dy: 0) : slot.offsetBy(dx: 0, dy: typical)
                confidence = 1 - 0.3 * pow(0.5, count - 1)
            }
            confidence = min(confidence, 0.95)
            // 几次松手点彼此差了不止一格：说明中间程序坞变过样，别太自信。
            if deltas[deltas.count - 1] - deltas[0] > base.pitch {
                confidence = min(confidence, conflictedConfidence)
            }
        }

        // 可信度越低，沿程序坞方向留的余量越宽。
        let margin = CGFloat(1 - confidence) * 0.5 * base.pitch
        let rect = observation.settings.edge == .bottom
            ? slot.insetBy(dx: -margin, dy: 0)
            : slot.insetBy(dx: 0, dy: -margin)
        return TrashEstimate(rect: rect, confidence: confidence, basis: base.basis, lessonCount: relevant.count)
    }

    /// 一次确认进了废纸篓的拖拽，松手点能不能当教训。
    ///
    /// 调用方应当已经确认"松手处最上面是程序坞"。这里再把两道关：松手点必须在程序坞那一带的后半段，
    /// 而且离当前的估算不超过三格——否则这次"进了废纸篓"多半另有原因，那个位置和程序坞上的废纸篓无关。
    static func lesson(releasePoint: CGPoint, observation: DockObservation) -> TrashLesson? {
        let base = base(for: observation)
        let frame = observation.displayFrame
        let settings = observation.settings
        let thickness = settings.edge == .bottom ? base.slot.height : base.slot.width
        let band = max(thickness * 1.5, 60)
        guard frame.insetBy(dx: -2, dy: -2).contains(releasePoint) else { return nil }

        let axisDelta: CGFloat
        switch settings.edge {
        case .bottom:
            guard releasePoint.y >= frame.maxY - band, releasePoint.x >= frame.midX else { return nil }
            axisDelta = releasePoint.x - base.slot.midX
        case .left:
            guard releasePoint.x <= frame.minX + band, releasePoint.y >= frame.midY else { return nil }
            axisDelta = releasePoint.y - base.slot.midY
        case .right:
            guard releasePoint.x >= frame.maxX - band, releasePoint.y >= frame.midY else { return nil }
            axisDelta = releasePoint.y - base.slot.midY
        }
        guard abs(axisDelta) <= largestLessonInPitches * base.pitch else { return nil }
        return TrashLesson(signature: DockSignature(observation), basis: base.basis.rawValue, axisDelta: Double(axisDelta))
    }

    /// 把新教训并进旧的里，并控制总量：每组（设置指纹 + 估算种类）只留最近几条，总共不超过 `limit` 条。
    static func remember(_ lesson: TrashLesson, in lessons: [TrashLesson], limit: Int = 40) -> [TrashLesson] {
        var result = lessons
        result.append(lesson)
        let sameGroup = result.indices.filter { result[$0].signature == lesson.signature && result[$0].basis == lesson.basis }
        if sameGroup.count > lessonWindow {
            for index in sameGroup.prefix(sameGroup.count - lessonWindow).reversed() {
                result.remove(at: index)
            }
        }
        if result.count > limit {
            result.removeFirst(result.count - limit)
        }
        return result
    }
}

/// 量出程序坞那一条此刻在屏上的范围。
///
/// 办法：程序坞的窗口是整屏大小的透明窗口，只有那一条接收鼠标点击。所以"鼠标点在这个点上会落到程序坞的窗口"
/// 的那些点，就是那一条。从屏幕边缘的中点出发，用二分法找出它的厚度和两端，一共三十来次查询。
enum DockBarScan {
    /// 探测点离屏幕边缘多远（点）。
    static let edgeInset: CGFloat = 2
    /// 那一条最厚不会超过这么多（点）。
    static let maximumThickness: CGFloat = 320

    /// - Parameter isDockAt: 这个点（全局坐标）上最上面的窗口是不是程序坞那一条。
    /// - Returns: 那一条的范围；程序坞不在这块屏的这条边上（隐藏了、在别的屏、被别的窗口挡着）时为 nil。
    static func measure(edge: DockEdge, displayFrame frame: CGRect, isDockAt: (CGPoint) -> Bool) -> CGRect? {
        guard frame.width > 100, frame.height > 100 else { return nil }
        // along：沿这条边的坐标；depth：离这条边多远。
        let alongLow = edge == .bottom ? frame.minX : frame.minY
        let alongHigh = edge == .bottom ? frame.maxX : frame.maxY
        let middle = (alongLow + alongHigh) / 2
        func point(along: CGFloat, depth: CGFloat) -> CGPoint {
            switch edge {
            case .bottom: return CGPoint(x: along, y: frame.maxY - depth)
            case .left: return CGPoint(x: frame.minX + depth, y: along)
            case .right: return CGPoint(x: frame.maxX - depth, y: along)
            }
        }
        func hit(_ along: CGFloat, _ depth: CGFloat) -> Bool { isDockAt(point(along: along, depth: depth)) }

        // 那一条沿边居中，所以边的中点一定在它里面。
        let deepest = min(maximumThickness, (edge == .bottom ? frame.height : frame.width) / 2)
        guard hit(middle, edgeInset), !hit(middle, deepest) else { return nil }
        let thickness = boundary(inside: edgeInset, outside: deepest) { hit(middle, $0) }
        let midDepth = thickness / 2

        let low = hit(alongLow + 0.5, midDepth) ? alongLow : boundary(inside: middle, outside: alongLow + 0.5) { hit($0, midDepth) }
        let high = hit(alongHigh - 0.5, midDepth) ? alongHigh : boundary(inside: middle, outside: alongHigh - 0.5) { hit($0, midDepth) }
        let length = high - low
        guard thickness >= 20, length >= thickness else { return nil }

        switch edge {
        case .bottom: return CGRect(x: low, y: frame.maxY - thickness, width: length, height: thickness)
        case .left: return CGRect(x: frame.minX, y: low, width: thickness, height: length)
        case .right: return CGRect(x: frame.maxX - thickness, y: low, width: thickness, height: length)
        }
    }

    /// 核对上一次量到的范围此刻是否仍然成立：厚度的内外各查一点、末端（废纸篓那一端）的内外各查一点，共 4 次查询。
    /// 程序坞没变样时（绝大多数时候）用它代替重新量一遍。另一端不查：那一条是居中的，一端动了另一端也会动。
    static func stillHolds(_ bar: CGRect, edge: DockEdge, displayFrame frame: CGRect, isDockAt: (CGPoint) -> Bool) -> Bool {
        let alongLow = edge == .bottom ? frame.minX : frame.minY
        let alongHigh = edge == .bottom ? frame.maxX : frame.maxY
        let middle = (alongLow + alongHigh) / 2
        let high = edge == .bottom ? bar.maxX : bar.maxY
        let thickness = edge == .bottom ? bar.height : bar.width
        let nudge: CGFloat = 1.5
        func hit(_ along: CGFloat, _ depth: CGFloat) -> Bool {
            switch edge {
            case .bottom: return isDockAt(CGPoint(x: along, y: frame.maxY - depth))
            case .left: return isDockAt(CGPoint(x: frame.minX + depth, y: along))
            case .right: return isDockAt(CGPoint(x: frame.maxX - depth, y: along))
            }
        }
        guard hit(middle, thickness - nudge), !hit(middle, thickness + nudge) else { return false }
        // 顶到屏幕边的那一端没有"外面"可查。
        return hit(high - nudge, thickness / 2) && (high >= alongHigh - 0.5 || !hit(high + nudge, thickness / 2))
    }

    /// 二分法找边界：`inside` 处命中、`outside` 处不命中，返回两者之间从命中变成不命中的位置（取整到整点）。
    private static func boundary(inside: CGFloat, outside: CGFloat, isInside: (CGFloat) -> Bool) -> CGFloat {
        var inner = inside
        var outer = outside
        while abs(outer - inner) > 0.5 {
            let middle = (inner + outer) / 2
            if isInside(middle) { inner = middle } else { outer = middle }
        }
        return ((inner + outer) / 2).rounded()
    }
}

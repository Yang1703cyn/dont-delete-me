// Overlay · "没变化就不重画"的判定（纯逻辑）
//
// 一块屏上的一层画布各有一个 ScenePlanner。它记着上一帧每个画布项画成了什么样，
// 拿到这一帧的清单后，逐项判定：不动 / 只挪位置 / 重画 / 该重画但先欠着。
// 规则见 docs/接口约定.md §7.2。

import CoreGraphics
import DDMCore
import Foundation

struct ScenePlanner {
    /// 这一帧对某个画布项要做的事。
    enum Action: Equatable, Sendable {
        /// 内容、尺寸、位置都没变：什么都不做。
        case keep
        /// 只有位置变了：挪图层，不重画。
        case move
        /// 新出现，或内容版本、画布尺寸变了：回调调用方重画。
        case draw
        /// 该重画，但这块屏此刻没人看得见：先欠着（沿用旧图，位置照挪），等看得见了再画。
        case deferred
    }

    /// 这一帧里，某个画布项在这块屏上的安排。
    struct Slot: Equatable, Sendable {
        var item: OverlayItem
        /// 图层该放在哪。`.draw` 时也是新位图的落位。
        var placement: CanvasPlacement
        var action: Action
    }

    private struct Record {
        var contentVersion: UInt64
        var rectSize: CGSize
        var outsets: EdgeOutsets
        /// 上次重画时画布左上角的全局位置，以及当时的落位。之后的"只挪位置"都从这里算起，误差不会累积。
        var drawnOrigin: CGPoint
        var drawnPlacement: CanvasPlacement?
        /// 图层现在的落位。
        var placement: CanvasPlacement
        /// 欠着一次重画。
        var needsDraw: Bool
    }

    private var records: [OverlayItem.Key: Record] = [:]

    /// 这块屏上现在记着多少个画布项。
    var count: Int { records.count }

    /// 是否有欠着没画的项。
    var hasDeferredDraws: Bool { records.values.contains(where: \.needsDraw) }

    /// 按这一帧的清单给出每项的安排，并更新记录。
    /// - Parameters:
    ///   - items: 这一层的画布项，顺序就是叠放次序。同一个 key 出现多次时只认第一个。
    ///   - display: 这块屏。
    ///   - canDraw: 这块屏此刻是否值得作画（看得见）。为 false 时该重画的项一律欠着。
    /// - Returns: 落在这块屏上的项，顺序与 `items` 一致。不相交的项不在其中（等于被移除）。
    mutating func plan(items: [OverlayItem], on display: DisplayInfo, canDraw: Bool) -> [Slot] {
        var next: [OverlayItem.Key: Record] = [:]
        var slots: [Slot] = []
        slots.reserveCapacity(items.count)

        for item in items {
            let key = item.key
            guard next[key] == nil,
                  let fresh = CanvasGeometry.placement(for: item.canvasRect, on: display) else { continue }
            let origin = item.canvasRect.origin

            var record = records[key] ?? Record(
                contentVersion: item.contentVersion, rectSize: item.rect.size, outsets: item.outsets,
                drawnOrigin: origin, drawnPlacement: nil, placement: fresh, needsDraw: true
            )
            let contentChanged = record.needsDraw
                || record.contentVersion != item.contentVersion
                || record.rectSize != item.rect.size
                || record.outsets != item.outsets

            let action: Action
            if contentChanged, canDraw {
                action = .draw
                record = Record(
                    contentVersion: item.contentVersion, rectSize: item.rect.size, outsets: item.outsets,
                    drawnOrigin: origin, drawnPlacement: fresh, placement: fresh, needsDraw: false
                )
            } else {
                // 沿用旧图：位置从"上次重画时"算起。还没有旧图（从没画过）时先按新落位占个位置。
                let target = record.drawnPlacement?.moved(by: CGVector(
                    dx: origin.x - record.drawnOrigin.x, dy: origin.y - record.drawnOrigin.y
                )) ?? fresh
                if contentChanged {
                    action = .deferred
                    record.needsDraw = true
                } else {
                    action = target == record.placement ? .keep : .move
                }
                record.placement = target
            }

            next[key] = record
            slots.append(Slot(item: item, placement: record.placement, action: action))
        }

        records = next
        return slots
    }

    /// 某一项这次没画成（画布造不出来）：记成"还欠着"，下一帧再试。
    mutating func markDrawFailed(_ key: OverlayItem.Key) {
        records[key]?.needsDraw = true
        records[key]?.drawnPlacement = nil
    }

    /// 忘掉一切：下一帧所有项都会重画。显示器的位置或缩放变了之后用。
    mutating func reset() {
        records.removeAll()
    }
}

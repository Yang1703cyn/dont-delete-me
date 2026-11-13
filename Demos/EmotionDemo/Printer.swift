// EmotionDemo · 把一帧的输出打印成人能看的几行字

import CoreGraphics
import DDMCore
import Emotion
import Foundation

func moodName(_ mood: FaceMood) -> String {
    switch mood {
    case .calm: "平静"
    case .shy: "害羞"
    case .dizzy: "头晕"
    case .scared: "害怕"
    case .crying: "哭"
    case .coveringEyes: "捂眼"
    case .dozing: "打瞌睡"
    case .ghost: "幽灵"
    }
}

/// 强度参数的中文名，按打印的先后排。
private func parameterValues(_ state: FaceState) -> [(String, Double)] {
    [
        ("脸红", state.blush), ("惊恐", state.fear), ("汗", state.sweat), ("发抖", state.tremble), ("泪", state.tears),
        ("头晕", state.dizziness), ("捂眼", state.cover), ("偷看", state.peek), ("困意", state.sleepiness), ("闭眼", state.blink),
    ]
}

/// 这个表情的画面多久要重画一次——照表情模块说明（docs/模块说明/faces.md §2 第 4 条）里的规则估算：
/// 0 = 每帧；正数 = 隔这么久；nil = 静止画面，表情不变就不用重画。演示和耗时测量用它数"有多少张脸在每帧重画"。
func redrawInterval(for state: FaceState) -> TimeInterval? {
    if state.mood == .ghost || state.tremble > 0 || state.dizziness > 0 || state.tears > 0.4 { return 0 }
    if state.sweat > 0 { return 1.0 / 30 }
    if state.tears > 0.05 { return 1.0 / 20 }
    if state.sleepiness > 0.35 { return 0.1 }
    return nil
}

/// 中文字符在等宽终端里占两格：按显示宽度补空格。
func pad(_ text: String, _ width: Int) -> String {
    let shown = text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E7F ? 2 : 1) }
    return text + String(repeating: " ", count: max(width - shown, 0))
}

func seconds(_ value: TimeInterval) -> String {
    String(format: "%5.2fs", value)
}

struct Printer {
    let stage: DemoStage

    /// 一行事件。
    func event(_ text: String) {
        print("\(seconds(stage.elapsed))  ▸ \(text)")
    }

    /// 这一帧每张脸一行。
    func sample() {
        let demand: String
        switch stage.output.demand {
        case .continuous: demand = "连续出帧"
        case let .by(time): demand = String(format: "%.2f 秒后再算", time - stage.time.monotonic)
        case .idle: demand = "休息"
        }
        print("\(seconds(stage.elapsed))  ─ 共 \(stage.output.faces.count) 张脸，引擎的需求：\(demand)")
        for face in stage.output.faces {
            print("          " + line(for: face))
        }
    }

    private func line(for face: FacePlacement) -> String {
        let state = face.state
        let name = stage.name(face.iconID)
        if state.mood == .ghost {
            return "\(pad(name + "的幽灵", 10))\(pad("桌面层", 8))\(pad("幽灵", 8))进度 \(String(format: "%.2f", state.ghost))（原位置上方 \(Int((state.ghost * Double(face.rect.height)).rounded())) 点）"
        }
        let who = name + "·" + personalityName(stage.director.personality(of: face.iconID))
        let layer = face.layer == .drag ? "拖拽层" : "桌面层"
        var parts: [String] = []
        for (label, value) in parameterValues(state) where value > 0 {
            parts.append("\(label) \(String(format: "%.2f", value))")
        }
        let parameters = parts.isEmpty ? "—" : parts.joined(separator: " ")
        var text = "\(pad(who, 10))\(pad(layer, 8))\(pad(moodName(state.mood), 8))\(pad(parameters, 44))看：\(looking(face))"
        if face.layer == .drag {
            text += String(format: "  脸在 (%.0f, %.0f)", face.rect.midX, face.rect.midY)
        }
        return text
    }

    /// 这张脸在看什么：拿视线方向和场上的几个点比一比。
    private func looking(_ face: FacePlacement) -> String {
        let state = face.state
        if state.gazeFollow < 0.02 {
            if state.sleepiness > 0.9 { return "（闭着眼）" }
            if state.cover > 0.9 { return "（捂着眼）" }
            return "屏幕外的用户（平视）"
        }
        let center = face.rect.center
        // 先认"正好盯着"的：鼠标、某个邻居、远处的一点（张望）。
        if state.gazeFollow >= 0.98 {
            // 被拖的图标就在鼠标底下：两者重合时，说的是"看着被拖的同伴"。
            for other in stage.output.faces where other.layer == .drag && other.iconID != face.iconID
                && state.gazeTarget == other.rect.center.offset(from: center) {
                return "被拖的" + stage.name(other.iconID)
            }
            if state.gazeTarget == stage.mouse.offset(from: center) { return "鼠标" }
            for icon in stage.icons where icon.id != face.iconID && state.gazeTarget == icon.imageRect.center.offset(from: center) {
                return (icon.id == stage.newcomer ? "新来的" : "邻居") + stage.name(icon.id)
            }
        }
        // 再认会动的目标：方向对得上就算。
        var candidates: [(String, CGPoint)] = []
        if let ghost = stage.ghosts.last {
            candidates.append(("幽灵", CGPoint(x: ghost.rect.midX, y: ghost.rect.midY - CGFloat(ghost.state.ghost) * ghost.rect.height)))
        }
        for other in stage.output.faces where other.layer == .drag && other.iconID != face.iconID {
            candidates.append(("被拖的" + stage.name(other.iconID), other.rect.center))
        }
        if face.layer == .drag || stage.facts.releasedDrags.contains(where: { $0.iconID == face.iconID }),
           let trash = stage.trashRect {
            if trash.center.distance(to: center) < face.rect.height {
                candidates.append(("脚下的废纸篓", CGPoint(x: center.x, y: center.y + face.rect.height)))
            }
            candidates.append(("废纸篓", trash.center))
        }
        if let newcomer = stage.newcomer, newcomer != face.iconID, let icon = stage.icon(newcomer) {
            candidates.append(("新来的" + stage.name(newcomer), icon.imageRect.center))
        }
        candidates.append(("鼠标", stage.mouse))
        let angle = atan2(Double(state.gazeTarget.dy), Double(state.gazeTarget.dx))
        var best: (String, Double)?
        for (label, point) in candidates {
            let offset = point.offset(from: center)
            guard offset.length > 1 else { continue }
            var difference = abs(atan2(Double(offset.dy), Double(offset.dx)) - angle)
            if difference > .pi { difference = 2 * .pi - difference }
            // 排在前面的优先；后面的要明显更准才换。
            if best == nil || difference < best!.1 - 0.05 { best = (label, difference) }
        }
        var text: String
        if let best, best.1 < 0.14 {
            text = best.0
        } else if state.blush > 0.3 {
            text = String(format: "躲开鼠标 (%+.0f, %+.0f)", state.gazeTarget.dx, state.gazeTarget.dy)
        } else if stage.output.demand == .continuous, abs(Double(state.gazeTarget.length) - 400) > 0.001 {
            text = String(format: "正在转头 (%+.0f, %+.0f)", state.gazeTarget.dx, state.gazeTarget.dy)
        } else {
            text = String(format: "别处 (%+.0f, %+.0f)", state.gazeTarget.dx, state.gazeTarget.dy)
        }
        if state.gazeFollow < 0.98 { text += String(format: "（跟随 %.2f）", state.gazeFollow) }
        return text
    }
}

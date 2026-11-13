// EmotionTests · 平时、悬停、被拖着走

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Emotion

@Suite("平时")
struct EverydayTests {
    @Test func 每个图标一张平静的脸_画在图标上() {
        let icons = makeGrid(count: 9)
        let stage = Stage(icons: icons)
        stage.step()
        #expect(stage.output.faces.count == 9)
        for icon in icons {
            let face = stage.face(icon.id)
            #expect(face?.rect == icon.imageRect)
            #expect(face?.layer == .desktop)
            #expect(face?.state.seed == icon.id.faceSeed)
            #expect(face?.state.mood == .calm)
        }
        // 顺序与快照一致。
        #expect(stage.output.faces.map(\.iconID) == icons.map(\.id))
    }

    @Test func 眼睛跟着鼠标() {
        let icons = makeGrid(count: 9)
        let stage = Stage(icons: icons)
        stage.mouse = CGPoint(x: 300, y: 500)
        stage.run(0.5)
        for icon in icons {
            let state = stage.state(icon.id)
            #expect(state.gazeFollow == 1)
            #expect(state.gazeTarget == stage.mouse.offset(from: icon.imageRect.center))
        }
        // 鼠标跑到另一边：眼睛转过去，最后正好盯着它。
        stage.mouse = CGPoint(x: 1400, y: 150)
        stage.step()
        #expect(stage.output.demand == .continuous)
        stage.run(0.6)
        for icon in icons {
            #expect(stage.state(icon.id).gazeTarget == stage.mouse.offset(from: icon.imageRect.center))
        }
    }

    @Test func 各自随机眨眼_互不同步() {
        let icons = makeGrid(count: 9)
        let stage = Stage(icons: icons)
        var starts: [IconID: [Int]] = [:]      // 每个图标每次眨眼开始的帧号
        var peaks: [IconID: Double] = [:]
        var previous: [IconID: Double] = [:]
        var frame = 0
        stage.run(30) { stage in
            frame += 1
            stage.idle = 0   // 不让"无聊"和"安静"掺进来
            for icon in icons {
                let blink = stage.state(icon.id).blink
                if blink > 0, (previous[icon.id] ?? 0) == 0 { starts[icon.id, default: []].append(frame) }
                peaks[icon.id] = max(peaks[icon.id] ?? 0, blink)
                previous[icon.id] = blink
            }
        }
        for icon in icons {
            let count = starts[icon.id]?.count ?? 0
            // 30 秒里，每 2.5～7 秒眨一次（偶尔连眨两下）：至少 4 次，至多 20 来次。
            #expect((4...24).contains(count), "图标 \(icon.id) 眨了 \(count) 次")
            #expect((peaks[icon.id] ?? 0) > 0.95)
        }
        // 互不同步：没有两个图标的眨眼时刻表是一样的，第一次眨眼的时刻也各不相同。
        #expect(Set(starts.values.map { $0 }).count == icons.count)
        #expect(Set(starts.values.compactMap(\.first)).count >= icons.count - 1)
    }

    @Test func 一次眨眼在规定时间内合上再睁开() {
        let icon = makeIcon(1, center: CGPoint(x: 500, y: 300))
        let stage = Stage(icons: [icon])
        var longest = 0
        var current = 0
        var sawClosed = false
        stage.run(20) { stage in
            stage.idle = 0
            let blink = stage.state(icon.id).blink
            if blink > 0 {
                current += 1
                if blink > 0.95 { sawClosed = true }
            } else {
                longest = max(longest, current)
                current = 0
            }
        }
        #expect(sawClosed)
        // 0.17 秒 ≈ 10 帧。
        #expect((6...11).contains(longest), "最长的一次眨眼持续了 \(longest) 帧")
    }
}

@Suite("悬停")
struct HoverTests {
    @Test func 悬停脸红_眼神躲闪_移开后慢慢恢复() {
        let icons = makeGrid(count: 6)
        let shy = icons[2]
        let stage = Stage(icons: icons)
        stage.run(0.5)

        // 鼠标停在图标偏右的地方。
        stage.hoverOn(shy.id)
        stage.mouse.x += 12
        var last = 0.0
        var rising = true
        stage.run(1.0) { stage in
            let blush = stage.state(shy.id).blush
            if blush < last { rising = false }
            last = blush
        }
        #expect(rising, "脸红应当只增不减")
        let state = stage.state(shy.id)
        #expect(state.blush == 1)
        #expect(state.mood == .shy)
        // 躲闪：看向鼠标的反方向（左边）、偏下。
        #expect(state.gazeFollow == 1)
        #expect(state.gazeTarget.dx < -20)
        #expect(state.gazeTarget.dy > 40)
        // 别的图标不脸红，照常看着鼠标。
        for icon in icons where icon.id != shy.id {
            #expect(stage.state(icon.id).blush == 0)
            #expect(stage.state(icon.id).gazeTarget == stage.mouse.offset(from: icon.imageRect.center))
        }

        // 移开：慢慢恢复。
        stage.moveMouse(to: CGPoint(x: 300, y: 600))
        var falling = true
        last = 1
        var blushAt: [Double] = []
        stage.run(4.0) { stage in
            let blush = stage.state(shy.id).blush
            if blush > last { falling = false }
            last = blush
            blushAt.append(blush)
        }
        #expect(falling, "移开后脸红应当只减不增")
        #expect(blushAt[17] > 0.5, "0.3 秒后应当还红着（慢慢恢复），实际 \(blushAt[17])")
        #expect(blushAt[59] > 0.1, "1 秒后还剩一点")
        let recovered = stage.state(shy.id)
        #expect(isCalmAndAwake(recovered))
        #expect(recovered.gazeTarget == stage.mouse.offset(from: shy.imageRect.center))
    }

    @Test func 鼠标在图标左边就往右躲_在右边就往左躲() {
        let icon = makeIcon(1, center: CGPoint(x: 500, y: 300))
        let stage = Stage(icons: [icon])
        stage.hoverOn(icon.id)
        stage.mouse.x -= 14
        stage.run(1)
        #expect(stage.state(icon.id).gazeTarget.dx > 20)
        stage.mouse.x += 28
        stage.run(1)
        #expect(stage.state(icon.id).gazeTarget.dx < -20)
    }
}

@Suite("被拖着走")
struct DragTests {
    @Test func 主角的脸画在拖影上_原位置不画() throws {
        let icons = makeGrid(count: 6)
        let star = icons[1]
        let stage = Stage(icons: icons)
        stage.trashRect = nil
        stage.run(0.3)

        stage.startDrag(star.id)
        stage.dragTo(CGPoint(x: 520, y: 420))
        stage.step()
        let faces = stage.output.faces.filter { $0.iconID == star.id }
        #expect(faces.count == 1)
        let face = try #require(faces.first)
        #expect(face.layer == .drag)
        // 鼠标位置 − 抓取偏移（抓在正中）。
        #expect(face.rect == CGRect(x: 520 - 32, y: 420 - 32, width: 64, height: 64))
        #expect(face.rect == stage.drag?.currentImageRect)
        // 其它图标都在桌面层、原位置；被拿着的脸排在它们后面。
        for icon in icons where icon.id != star.id {
            #expect(stage.face(icon.id)?.layer == .desktop)
            #expect(stage.face(icon.id)?.rect == icon.imageRect)
        }
        #expect(stage.output.faces.last?.iconID == star.id)

        // 跟着鼠标走。
        stage.dragTo(CGPoint(x: 300, y: 700))
        stage.step()
        #expect(stage.face(star.id)?.rect == CGRect(x: 300 - 32, y: 700 - 32, width: 64, height: 64))
    }

    @Test func 主角看着用户_其它图标目光跟着它() {
        let icons = makeGrid(count: 6)
        let star = icons[1]
        let stage = Stage(icons: icons)
        stage.trashRect = nil
        stage.run(0.3)
        stage.startDrag(star.id)
        var position = star.imageRect.center
        stage.run(1.5) { stage in
            position.x -= 4
            position.y += 3
            stage.dragTo(position)
        }
        // 主角：平视前方（看着屏幕外的用户），不害怕。
        let state = stage.state(star.id)
        #expect(state.gazeFollow == 0)
        #expect(isCalmAndAwake(state))
        // 其它图标：盯着它现在的位置。
        let starCenter = stage.drag!.currentImageRect.center
        for icon in icons where icon.id != star.id {
            #expect(stage.state(icon.id).isLooking(toward: starCenter.offset(from: icon.imageRect.center), tolerance: 6))
            #expect(isCalmAndAwake(stage.state(icon.id)))
        }
    }
}

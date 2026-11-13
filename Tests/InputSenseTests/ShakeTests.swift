// InputSenseTests · 甩动强度

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import InputSense

@Suite("甩动强度")
struct ShakeTests {
    /// 抓起图标 A，拖到屏幕中间，再按给定的轨迹甩 `seconds` 秒。返回舞台（仍拖着）。
    func shaken(for seconds: TimeInterval = 2, path: @escaping (TimeInterval) -> CGVector) -> Stage {
        var stage = Stage(at: CGPoint(x: 130, y: 140))
        stage.wait(0.2)
        stage.drag(to: CGPoint(x: 700, y: 500), in: 0.6)
        stage.wait(1.5)   // 停一会儿，让拖过来这一段的影响散掉
        stage.follow(for: seconds) { t in
            let offset = path(t)
            return CGPoint(x: 700 + offset.dx, y: 500 + offset.dy)
        }
        return stage
    }

    /// 左右来回甩：每秒 `frequency` 个来回，幅度 `amplitude` 点。
    func backAndForth(frequency: Double, amplitude: Double) -> Stage {
        shaken { t in CGVector(dx: amplitude * sin(2 * .pi * frequency * t), dy: 0) }
    }

    func shake(_ stage: Stage) -> Double { stage.last.drag?.shake ?? -1 }

    @Test func 平稳的直线拖动接近零() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 140))
        stage.wait(0.2)
        stage.drag(to: CGPoint(x: 1330, y: 740), in: 1.5)   // 约 900 点/秒
        #expect(shake(stage) < 0.03)
        // 全程都很低。
        #expect(stage.facts.compactMap(\.drag).allSatisfy { $0.shake < 0.03 })
    }

    @Test func 平缓的弧线拖动也接近零() throws {
        // 画四分之一个大圆（半径 500），一秒走完。
        let stage = shaken(for: 1) { t in
            CGVector(dx: 500 * sin(t * .pi / 2), dy: 500 * (1 - cos(t * .pi / 2)))
        }
        #expect(shake(stage) < 0.05)
    }

    @Test func 来回甩得越猛越高() throws {
        let gentle = shake(backAndForth(frequency: 1.5, amplitude: 60))    // 慢悠悠地晃
        let moderate = shake(backAndForth(frequency: 2, amplitude: 80))
        let brisk = shake(backAndForth(frequency: 2.5, amplitude: 100))
        let violent = shake(backAndForth(frequency: 4, amplitude: 120))    // 使劲甩

        #expect(gentle < 0.15, "慢晃 \(gentle)")
        #expect(moderate > gentle && moderate < brisk, "中等 \(moderate)")
        #expect(brisk > 0.3 && brisk < 0.8, "较快 \(brisk)")
        #expect(violent > 0.85, "猛甩 \(violent)")
        #expect(violent > brisk)
    }

    @Test func 强度始终在零到一之间() throws {
        let stage = backAndForth(frequency: 8, amplitude: 300)   // 离谱地猛
        let values = stage.facts.compactMap(\.drag).map(\.shake)
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(shake(stage) > 0.95)
    }

    @Test func 上下甩和斜着甩一样算() throws {
        let vertical = shake(shaken { t in CGVector(dx: 0, dy: 120 * sin(2 * .pi * 4 * t)) })
        let diagonal = shake(shaken { t in
            let s = 85 * sin(2 * .pi * 4 * t)
            return CGVector(dx: s, dy: s)
        })
        #expect(vertical > 0.85)
        #expect(diagonal > 0.85)
    }

    @Test func 画圈搅动也会晕_但不如来回猛甩() throws {
        let stirring = shake(shaken { t in
            CGVector(dx: 110 * cos(2 * .pi * 2.5 * t), dy: 110 * sin(2 * .pi * 2.5 * t))
        })
        let violent = shake(backAndForth(frequency: 4, amplitude: 120))
        #expect(stirring > 0.15, "搅动 \(stirring)")
        #expect(stirring < violent)
    }

    @Test func 停手之后一两秒内回落() throws {
        var stage = backAndForth(frequency: 4, amplitude: 120)
        #expect(shake(stage) > 0.85)
        stage.wait(1)
        #expect(shake(stage) < 0.5)
        stage.wait(2)
        #expect(shake(stage) < 0.05)
    }

    @Test func 小幅度的手抖不算甩() throws {
        // 幅度只有 3 点的高频抖动：速度很低。
        let stage = backAndForth(frequency: 10, amplitude: 3)
        #expect(shake(stage) < 0.02)
    }

    @Test func 每次拖拽从零开始() throws {
        var stage = backAndForth(frequency: 4, amplitude: 120)
        stage.release()
        stage.frame()
        stage.reportMoved(Fixture.iconA, to: CGPoint(x: 650, y: 450))
        stage.frame()
        stage.position = CGPoint(x: 680, y: 480)
        stage.wait(0.1)
        stage.drag(to: CGPoint(x: 900, y: 480), in: 0.3)
        #expect(shake(stage) < 0.03)
    }
}

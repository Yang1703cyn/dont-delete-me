// 占位，由 faces 子对话替换。
//
// 写法示范见 Tests/DDMCoreTests/；跑法：swift test --filter FacesTests

import CoreGraphics
import DDMCore
import Testing
@testable import Faces

@Test func 占位的表情绘制者不外扩也没有动画() {
    let renderer = FaceRenderer()
    let state = FaceState(mood: .crying, seed: 7, tears: 1)
    #expect(renderer.outsets(for: state, iconSize: CGSize(width: 64, height: 64)) == .zero)
    #expect(renderer.animationInterval(for: state) == nil)
}

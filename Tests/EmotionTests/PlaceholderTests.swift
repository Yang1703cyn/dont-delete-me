// 占位，由 emotion 子对话替换。
//
// 写法示范见 Tests/DDMCoreTests/；跑法：swift test --filter EmotionTests

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Emotion

@Test func 占位的情绪引擎给每个图标一张平静的脸() {
    let icon = DesktopIcon(id: IconID(rawValue: 1), kind: .folder, imageRect: CGRect(x: 10, y: 20, width: 64, height: 64))
    let snapshot = IconSnapshot(icons: [icon], status: .ok, capturedAt: 0, revision: 1)
    let time = FrameTime(monotonic: 0, wallClock: Date(timeIntervalSince1970: 0))

    var director = EmotionDirector(seed: 42)
    let output = director.update(EmotionInput(time: time, icons: .unchanged(snapshot), facts: InteractionFacts(time: time)))

    #expect(output.faces.count == 1)
    #expect(output.faces.first?.rect == icon.imageRect)
    #expect(output.faces.first?.state.mood == .calm)
    #expect(output.faces.first?.state.seed == icon.id.faceSeed)
}

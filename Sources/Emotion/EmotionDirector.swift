// 占位，由 emotion 子对话替换。
//
// 模块入口：应用以 `EmotionDirector(seed:)` 构造它——请保留这个类型名和这个构造方式
// （可以增加带默认值的参数），内部实现和文件组织随意。
// 要实现的协议与约定见 docs/接口约定.md 第 5 节。本模块不得依赖 AppKit。
//
// 占位行为：给快照里的每个图标一张平视前方、一动不动的平静的脸；没有任何情绪和动画。

import DDMCore
import Foundation

public struct EmotionDirector: EmotionDirecting {
    private let seed: UInt64

    /// - Parameter seed: 随机数种子。同样的种子 + 同样的输入序列 → 同样的输出序列。
    public init(seed: UInt64) {
        self.seed = seed
    }

    public mutating func update(_ input: EmotionInput) -> EmotionOutput {
        let faces = input.icons.snapshot.icons.map { icon in
            FacePlacement(iconID: icon.id, rect: icon.imageRect, layer: .desktop, state: FaceState(seed: icon.id.faceSeed))
        }
        return EmotionOutput(faces: faces, demand: .idle)
    }

    public mutating func reset() {}
}

// swift-tools-version: 6.0
//
// 「别删我」（Don't Delete Me）工程清单。
//
// 这个文件归 scaffold / 总览管理：所有模块、测试目标、演示目标都已在这里声明好，
// 其它子对话不需要、也不应该改它；确需新增目标时向总览提出。
//
// 依赖规则（scripts/check.sh 会检查）：
//   - 五个功能模块（IconBridge / Overlay / Faces / InputSense / Emotion）只依赖 DDMCore，彼此不互相依赖；
//   - 只有可执行入口 DontDeleteMe 把它们接起来；
//   - 每个演示程序只依赖 DDMCore 和它自己的模块；
//   - 零第三方依赖。

import Foundation
import PackageDescription

/// 五个功能模块：目录都是 Sources/<名字>/，测试在 Tests/<名字>Tests/，演示在 Demos/<名字>Demo/。
let featureModules = ["IconBridge", "Overlay", "Faces", "InputSense", "Emotion"]

/// 给所有测试目标用的编译设置：绕开 Swift 6.4 + CommandLineTools 的一个偶发毛病。
///
/// 现象：并行编译测试目标时，构建引擎偶尔漏给编译器传"测试宏插件"，于是随机报
/// `plugin for module 'TestingMacros' not found`（实测约四分之一的测试编译会中招，重跑又好了）。
/// 办法：插件就在工具链的固定位置，这里直接点名加载它，不再依赖引擎去找。
/// 实测：加上之后连续 22 次重新编译测试无一失败。
/// 这个路径只在"只装了 CommandLineTools"的机器上存在；装了完整 Xcode 的机器上文件不存在，
/// 设置为空，一切照常。详见 docs/开发说明.md §6.4。
let testSettings: [SwiftSetting] = {
    let plugin = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    guard FileManager.default.fileExists(atPath: plugin) else { return [] }
    return [.unsafeFlags(["-load-plugin-library", plugin])]
}()

var targets: [Target] = [
    // 共享数据类型 + 各模块协议。完成后只有总览能改。
    .target(name: "DDMCore"),
    .testTarget(name: "DDMCoreTests", dependencies: ["DDMCore"], swiftSettings: testSettings),

    // 可执行入口：菜单栏外壳 + 把各模块按接口接成一条数据流。
    .executableTarget(
        name: "DontDeleteMe",
        dependencies: ["DDMCore"] + featureModules.map { Target.Dependency(stringLiteral: $0) },
        // Resources/ 里是 Info.plist 和本地化文案，由 scripts/build-app.sh 手工拷进 .app，
        // 不走 SwiftPM 的资源机制（它生成的资源包放不进标准的 .app 结构）。
        exclude: ["Resources"]
    ),
    .testTarget(name: "DontDeleteMeTests", dependencies: ["DontDeleteMe", "DDMCore"], swiftSettings: testSettings),
]

for module in featureModules {
    targets += [
        .target(name: module, dependencies: ["DDMCore"]),
        .testTarget(
            name: "\(module)Tests",
            dependencies: [.target(name: module), "DDMCore"],
            swiftSettings: testSettings
        ),
        .executableTarget(
            name: "\(module)Demo",
            dependencies: [.target(name: module), "DDMCore"],
            path: "Demos/\(module)Demo"
        ),
    ]
}

let package = Package(
    name: "DontDeleteMe",
    // 最低 macOS 14。目前只在 macOS 27 上实测过，见 docs/开发说明.md。
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DontDeleteMe", targets: ["DontDeleteMe"]),
    ] + featureModules.map { .executable(name: "\($0)Demo", targets: ["\($0)Demo"]) },
    targets: targets,
    // Swift 6 语言模式：数据竞争检查是编译错误，线程约定（docs/接口约定.md 第 8 节）由编译器把关。
    swiftLanguageModes: [.v6]
)

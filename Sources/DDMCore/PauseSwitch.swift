// DDMCore · 全局"暂停"开关
//
// 菜单栏的「暂停 / 继续」写它；各模块读它。
// 暂停期间：叠加层隐藏所有窗口、停止帧回调；图标桥停止读取；交互感知因为没有帧自然也停了。

import Foundation
import os

/// 全局暂停开关。
///
/// - 读（`isPaused`）：任何线程都可以，无锁竞争时极快；
/// - 写（`setPaused` / `toggle`）：只在主线程，且只应由应用外壳（菜单）来写；
/// - 观察（`addObserver`）：回调在主线程，在写入的那一刻同步发生。
///
/// 应用里各模块统一使用 `PauseSwitch.shared`；测试可以自己 `PauseSwitch()` 一个互不影响的。
public final class PauseSwitch: Sendable {
    /// 全应用共用的那一个。
    public static let shared = PauseSwitch()

    private struct State {
        var isPaused = false
        var nextToken: UInt64 = 0
        var observers: [UInt64: @MainActor (Bool) -> Void] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// 当前是否处于暂停。任何线程可读。
    public var isPaused: Bool {
        state.withLock { $0.isPaused }
    }

    /// 设置暂停状态。值没变时什么都不做；变了则同步通知所有观察者。
    @MainActor
    public func setPaused(_ paused: Bool) {
        let observers: [@MainActor (Bool) -> Void]? = state.withLock { state in
            guard state.isPaused != paused else { return nil }
            state.isPaused = paused
            return state.observers.sorted { $0.key < $1.key }.map(\.value)
        }
        observers?.forEach { $0(paused) }
    }

    /// 切换暂停状态，返回切换后的值。
    @MainActor
    @discardableResult
    public func toggle() -> Bool {
        let paused = !isPaused
        setPaused(paused)
        return paused
    }

    /// 观察暂停状态的变化。回调在主线程，参数是新的状态。
    /// 观察一直有效，直到对返回的凭据调用 `cancel()`；不需要取消的话可以不保存凭据。
    @MainActor
    @discardableResult
    public func addObserver(_ handler: @escaping @MainActor (Bool) -> Void) -> PauseObservation {
        let token = state.withLock { state -> UInt64 in
            state.nextToken += 1
            state.observers[state.nextToken] = handler
            return state.nextToken
        }
        return PauseObservation { [weak self] in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: token) }
        }
    }
}

/// 一次观察的凭据。调用 `cancel()` 结束观察。
public final class PauseObservation: Sendable {
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// 结束观察。可在任何线程调用，重复调用无副作用。
    public func cancel() {
        onCancel()
    }
}

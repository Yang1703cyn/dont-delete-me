// Emotion · 演员表：跟着快照增减演员、排"谁该打瞌睡"

import CoreGraphics
import DDMCore
import Foundation

extension EmotionDirector {
    /// 让演员表与这一帧的快照一致：新出现的图标建演员，不见了的撤掉，还在的原样保留。
    ///
    /// - 只有图标桥**明确报告"新增"**的图标才算"新来的"（触发彩蛋）。
    ///   整体重载、或者快照里直接多出来的图标，都悄悄建好，不当成新来的。
    /// - 图标不见了只是把演员撤掉。放不放幽灵只看交互感知给的删除事件，这里不管。
    /// - 整体重载时，还在的图标保留身上的情绪（免得画面无故跳一下），幽灵全部清掉
    ///   （它们的位置多半已经不对了）。
    mutating func syncCast(with update: IconUpdate, now: TimeInterval) {
        let icons = update.snapshot.icons
        if update.isReset {
            ghosts.removeAll(keepingCapacity: true)
            newcomer = nil
        }

        // 绝大多数帧图标没变：逐个核对编号（和它在快照里的位置）就够了，不必重建。
        var aligned = performers.count == icons.count
        if aligned {
            for index in icons.indices
            where performers[index].id != icons[index].id || performers[index].iconIndex != index {
                aligned = false
                break
            }
        }
        guard !aligned else { return }

        var announced: Set<IconID> = []
        for change in update.changes {
            if case let .added(icon) = change { announced.insert(icon.id) }
        }

        var nextPerformers: [Performer] = []
        nextPerformers.reserveCapacity(icons.count)
        var nextIndex: [IconID: Int] = [:]
        nextIndex.reserveCapacity(icons.count)
        for (iconIndex, icon) in icons.enumerated() {
            // 同一个编号万一出现两次，只认第一次（一个图标一帧只能有一张脸）。
            guard nextIndex[icon.id] == nil else { continue }
            var performer: Performer
            if let old = indexByID[icon.id] {
                performer = performers[old]
                performer.iconIndex = iconIndex
            } else {
                performer = Performer(icon: icon, iconIndex: iconIndex, directorSeed: seed, now: now, tuning: tuning)
                if announced.contains(icon.id) {
                    performer.greet(now: now, tuning: tuning)
                    newcomer = Newcomer(id: icon.id, until: now + tuning.newcomerLook)
                }
            }
            nextIndex[icon.id] = nextPerformers.count
            nextPerformers.append(performer)
        }
        performers = nextPerformers
        indexByID = nextIndex
        sleepersStale = true
    }

    /// 排"谁该打瞌睡"：最近修改时间距今超过半年的图标里，最久没动的优先，
    /// 人数不超过桌面图标总数的三分之一。没有修改时间的图标不参与。
    ///
    /// 只在图标有变化（演员表变了、快照版本号变了）或隔了较长时间时重排，平时不算。
    mutating func refreshSleepers(snapshot: IconSnapshot, wallClock: Date) {
        let overdue = sleepersCheckedAt.map {
            abs(wallClock.timeIntervalSince($0)) >= tuning.dozeRecheckInterval
        } ?? true
        guard sleepersStale || overdue || snapshot.revision != sleepersRevision else { return }
        sleepersStale = false
        sleepersRevision = snapshot.revision
        sleepersCheckedAt = wallClock

        let cutoff = wallClock.addingTimeInterval(-tuning.dozeAfter)
        var candidates: [(modifiedAt: Date, id: UInt64, index: Int)] = []
        for index in performers.indices {
            if let modifiedAt = snapshot.icons[performers[index].iconIndex].modifiedAt, modifiedAt < cutoff {
                candidates.append((modifiedAt, performers[index].id.rawValue, index))
            }
        }
        // 最久没动的排前面；修改时间相同按编号排，保证结果确定。
        candidates.sort { $0.modifiedAt != $1.modifiedAt ? $0.modifiedAt < $1.modifiedAt : $0.id < $1.id }
        let quota = Int((Double(performers.count) * unit(tuning.maxSleepingFraction) + 1e-9).rounded(.down))

        var chosen = [Bool](repeating: false, count: performers.count)
        for candidate in candidates.prefix(quota) {
            chosen[candidate.index] = true
        }
        for index in performers.indices {
            performers[index].isSleeper = chosen[index]
            if performers[index].isFresh {
                // 悄悄建出来的演员：该睡的直接从睡着的样子开始，不演一遍"慢慢睡着"。
                performers[index].isFresh = false
                if chosen[index] { performers[index].sleep = 1 }
            }
        }
    }
}

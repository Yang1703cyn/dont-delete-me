#!/bin/bash
#
# 一键自检。任何子对话交付前都应该跑一遍，全部通过才算数。
#
#   用法：scripts/check.sh            检查全部
#         scripts/check.sh Faces      只跑某个模块的测试和演示（编译与依赖规则检查仍是全工程的）
#
# 依次检查：
#   1. swift build 通过，且没有警告（工具链自带的两条链接器警告除外，见 docs/开发说明.md）；
#   2. 模块依赖规则：功能模块只依赖 DDMCore、彼此不互相依赖；Emotion 不依赖 AppKit；
#   3. swift test 全部通过；
#   4. 每个演示程序都能启动并自己正常结束。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODULES=(IconBridge Overlay Faces InputSense Emotion)
ONLY="${1:-}"
if [ -n "$ONLY" ] && [[ ! " ${MODULES[*]} DDMCore DontDeleteMe " == *" $ONLY "* ]]; then
    echo "不认识的模块：$ONLY（可选：${MODULES[*]} DDMCore DontDeleteMe）"
    exit 2
fi

# 演示程序最长允许运行多久（秒）。演示必须自己限时退出；超过这个时间会被强行结束并判失败。
DEMO_TIMEOUT=180

LOG="$(mktemp -t ddm-check)"
trap 'rm -f "$LOG"' EXIT
failures=0

fail() {
    echo "  ✘ $1"
    failures=$((failures + 1))
}

echo "==> 1/4 编译"
if swift build >"$LOG" 2>&1; then
    # 工具链自带的警告：只有 CommandLineTools 时，链接器会抱怨两个不存在的搜索路径。与工程代码无关。
    warnings="$(grep 'warning:' "$LOG" | grep -v "ld: warning: search path '/Library/Developer/CommandLineTools/Developer/" | sort -u)"
    if [ -n "$warnings" ]; then
        echo "$warnings"
        fail "编译有警告"
    else
        echo "  ✔ 编译通过，无警告"
    fi
else
    grep -E 'error' "$LOG" | sort -u | head -40
    fail "编译失败"
    echo "==> 结果：编译都没过，后面的检查跳过"
    exit 1
fi

echo "==> 2/4 模块依赖规则"
rules_ok=yes
# 在若干目录里找"不该出现的 import"。$1 = 说明，$2 = 正则（匹配模块名），其余 = 目录。
forbid_imports() {
    local what="$1" pattern="$2"
    shift 2
    local hits
    # 能认出：import X、@testable import X、@preconcurrency import X、import struct X.Y 等写法。
    hits="$(grep -rnE "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?($pattern)([^A-Za-z0-9_]|\$)" "$@" --include='*.swift' 2>/dev/null)"
    if [ -n "$hits" ]; then
        echo "$hits"
        fail "$what"
        rules_ok=no
    fi
}
for module in "${MODULES[@]}"; do
    others="DontDeleteMe"
    for other in "${MODULES[@]}"; do
        [ "$other" != "$module" ] && others="$others|$other"
    done
    forbid_imports "$module 只能依赖 DDMCore，不能依赖其它模块" "$others" \
        "Sources/$module" "Tests/${module}Tests" "Demos/${module}Demo"
done
forbid_imports "DDMCore 不能依赖任何功能模块" "$(IFS='|'; echo "${MODULES[*]}")|DontDeleteMe" Sources/DDMCore
forbid_imports "Emotion 是纯逻辑，不能依赖 AppKit" "AppKit|Cocoa|SwiftUI|QuartzCore" Sources/Emotion
[ "$rules_ok" = yes ] && echo "  ✔ 依赖规则没有被破坏"

echo "==> 3/4 测试"
# 用 scripts/test.sh 而不是直接 swift test：它会在工具链偶发毛病时自动重跑（见 docs/开发说明.md §6.4）。
if [ -n "$ONLY" ]; then
    scripts/test.sh --filter "${ONLY}Tests" >"$LOG" 2>&1
else
    scripts/test.sh >"$LOG" 2>&1
fi
test_status=$?
if [ "$test_status" -eq 0 ]; then
    # 每个测试目标各有一行汇总，例如：✔ Test run with 17 tests in 2 suites passed after 0.004 seconds.
    # 把各目标的测试数加起来报一个总数。
    grep -E 'Test run with [0-9]+ tests?' "$LOG" \
        | sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/' \
        | awk '{ runs += 1; tests += $1 } END { printf "  ✔ 测试全部通过：%d 个测试目标，共 %d 个测试\n", runs, tests }'
else
    grep -E '✘|error|failed|recorded an issue' "$LOG" | head -40
    fail "测试没有全部通过"
fi

echo "==> 4/4 演示程序"
BIN_DIR="$(swift build --show-bin-path)"
for module in "${MODULES[@]}"; do
    if [ -n "$ONLY" ] && [ "$ONLY" != "$module" ]; then
        continue
    fi
    demo="${module}Demo"
    "$BIN_DIR/$demo" >"$LOG" 2>&1 &
    pid=$!
    # 看门狗：超时就强行结束。
    ( sleep "$DEMO_TIMEOUT"; kill -9 "$pid" 2>/dev/null ) &
    watchdog=$!
    wait "$pid"
    status=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    if [ "$status" -eq 0 ]; then
        echo "  ✔ $demo 正常结束（输出 $(wc -l <"$LOG" | tr -d ' ') 行）"
    else
        tail -5 "$LOG"
        fail "$demo 退出码 $status（137 表示超过 ${DEMO_TIMEOUT} 秒被强行结束）"
    fi
done

if [ "$failures" -eq 0 ]; then
    echo "==> 结果：全部通过"
else
    echo "==> 结果：$failures 项未通过"
    exit 1
fi

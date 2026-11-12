#!/bin/bash
#
# 跑测试。就是 `swift test`，外加一件事：遇到工具链的偶发毛病时自动重跑。
#
#   用法：scripts/test.sh                      全部测试
#         scripts/test.sh --filter FacesTests  只跑某个模块（参数原样交给 swift test）
#
# 偶发毛病指的是：编译测试目标时，偶尔报
#   external macro implementation type 'TestingMacros.TestDeclarationMacro' could not be found …
#   plugin for module 'TestingMacros' not found
# 这是 Swift 6.4 构建引擎在并行编译时漏传了测试宏插件，与工程代码无关，原样重跑就好（见 docs/开发说明.md §6.4）。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOG="$(mktemp -t ddm-test)"
trap 'rm -f "$LOG"' EXIT

MAX_ATTEMPTS=3
attempt=1
while true; do
    swift test "$@" 2>&1 | tee "$LOG"
    status="${PIPESTATUS[0]}"
    if [ "$status" -ne 0 ] && [ "$attempt" -lt "$MAX_ATTEMPTS" ] \
        && grep -q "plugin for module 'TestingMacros' not found" "$LOG"; then
        attempt=$((attempt + 1))
        echo "==> 工具链的测试宏插件没加载上（与代码无关），重跑（第 $attempt 次）"
        continue
    fi
    exit "$status"
done

#!/usr/bin/env bash
#
# OpenArmX Layer 1: 硬件自动诊断脚本
# ====================================
# 用法:
#   bash openarmx_hwcheck.sh              # 完整硬件诊断
#   bash openarmx_hwcheck.sh --auto-fix   # 诊断 + 自动修复
#   bash openarmx_hwcheck.sh --probe      # 仅探测电机
#
# 前提: Layer 0 已通过（openarmx_setup.sh 运行过）
# 安全: 纯只读操作，不会让电机运动
#

set -uo pipefail

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

AUTO_FIX=false
PROBE_ONLY=false
for arg in "$@"; do
    case $arg in
        --auto-fix) AUTO_FIX=true ;;
        --probe)    PROBE_ONLY=true ;;
        --help|-h)
            echo "用法: bash openarmx_hwcheck.sh [--auto-fix] [--probe]"
            echo "  --auto-fix  自动修复 CAN 接口（启用/配对）"
            echo "  --probe     仅探测电机，跳过 CAN 接口检查"
            exit 0
            ;;
    esac
done

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

PASS=0
FAIL=0
PASS_LIST=()
FAIL_LIST=()

record_pass() { PASS=$((PASS+1)); PASS_LIST+=("$1"); log "$1"; }
record_fail() { FAIL=$((FAIL+1)); FAIL_LIST+=("$1"); err "$1"; }

# ============================================================
echo "🔧 OpenArmX Layer 1: 硬件自动诊断"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "内核: $(uname -r)"
# ============================================================

# ============================================================
step "1/5 CAN 驱动检查"
# ============================================================

if lsmod 2>/dev/null | grep -c kcan >/dev/null 2>&1; then
    VERSION=$(cat /sys/class/kcan/version 2>/dev/null || echo "unknown")
    record_pass "KCAN 驱动已加载 (v$VERSION)"
elif lsmod 2>/dev/null | grep -c peak_usb >/dev/null 2>&1; then
    record_pass "PCAN 驱动已加载"
else
    record_fail "CAN 驱动未加载"
    info "修复: sudo modprobe kcan  或  bash openarmx_setup.sh"
    if $AUTO_FIX; then
        sudo modprobe kcan 2>/dev/null && log "已加载 kcan 模块" || err "加载失败"
    fi
fi

# ============================================================
step "2/5 CAN USB 适配器检测"
# ============================================================

CAN_IFACES=$(ip link show 2>/dev/null | grep -oE "can[0-9]+" | sort -u | tr '\n' ' ' | sed 's/ *$//')
CAN_COUNT=$(echo "$CAN_IFACES" | wc -w)

if [ "$CAN_COUNT" -eq 0 ]; then
    record_fail "未检测到 CAN 接口（USB 适配器未插入？）"
    info "需要: 插入 KCAN/PCAN USB 适配器"
    info "检查: lsusb | grep -iE 'can|kunhong|peak'"
    echo ""
    info "当前 USB 设备:"
    lsusb 2>/dev/null | while read line; do
        echo "    $line"
    done
    exit 1
elif [ "$CAN_COUNT" -lt 4 ]; then
    warn "仅发现 $CAN_COUNT 个 CAN 接口（双臂需要 4 个: can0-can3）"
    for iface in $CAN_IFACES; do
        info "  $iface"
    done
else
    record_pass "CAN 接口: $CAN_COUNT 个 ($CAN_IFACES)"
fi

# ============================================================
step "3/5 CAN 接口状态检查"
# ============================================================

NEED_ENABLE=false
for iface in $CAN_IFACES; do
    STATE=$(ip link show "$iface" 2>/dev/null | grep -oE "UP|DOWN|UNKNOWN" | head -1)
    if [ "$STATE" = "UP" ] || [ "$STATE" = "UNKNOWN" ]; then
        log "$iface: $STATE"
    else
        warn "$iface: $STATE (需要启用)"
        NEED_ENABLE=true
    fi
done

if $NEED_ENABLE && $AUTO_FIX; then
    info "自动启用 CAN 接口..."
    for iface in $CAN_IFACES; do
        sudo ip link set "$iface" up type can bitrate 1000000 2>/dev/null && \
            log "$iface 已启用 (1Mbps)" || \
            warn "$iface 启用失败"
    done
fi

# ============================================================
step "4/5 CAN 通道配对"
# ============================================================

if python3 -c "from openarmx_arm_driver.can_utils import pair_can_channels; pair_can_channels(); print('OK')" 2>/dev/null; then
    record_pass "CAN 通道配对成功"
elif $AUTO_FIX; then
    info "尝试启用全部接口..."
    python3 -c "from openarmx_arm_driver.can_utils import enable_all_can_interfaces; enable_all_can_interfaces()" 2>/dev/null && \
        log "接口已启用" || warn "接口启用失败"
    python3 -c "from openarmx_arm_driver.can_utils import pair_can_channels; pair_can_channels()" 2>/dev/null && \
        record_pass "CAN 通道配对成功" || record_fail "CAN 通道配对失败"
else
    record_fail "CAN 通道配对失败（用 --auto-fix 自动修复）"
fi

# ============================================================
step "5/5 电机逐个探测"
# ============================================================

# 探测函数
probe_arm() {
    local side="$1"
    shift
    local channels="$@"
    local alive=0
    local dead=0
    local dead_list=""

    info "探测${side} ($channels)..."

    PROBE_RESULT=$(python3 << PYEOF 2>&1
import sys, json
try:
    from openarmx_arm_driver import Arm
    arm = Arm(channels=list("$channels".split()))
    results = {}
    for jid in range(1, 8):
        try:
            status = arm.get_status(jid)
            pos = status.get('position', 'N/A')
            cur = status.get('current', 'N/A')
            temp = status.get('temperature', 'N/A')
            results[jid] = {"ok": True, "pos": pos, "cur": cur, "temp": temp}
        except Exception as e:
            results[jid] = {"ok": False, "error": str(e)[:60]}
    arm.close()
    print(json.dumps(results))
except Exception as e:
    print(json.dumps({"error": str(e)[:100]}), file=sys.stderr)
    sys.exit(1)
PYEOF
    )

    if echo "$PROBE_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'error' not in d" 2>/dev/null; then
        # 解析结果
        for jid in 1 2 3 4 5 6 7; do
            OK=$(echo "$PROBE_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['$jid']['ok'])" 2>/dev/null)
            if [ "$OK" = "True" ]; then
                POS=$(echo "$PROBE_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['$jid']['pos'])" 2>/dev/null)
                CUR=$(echo "$PROBE_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['$jid']['cur'])" 2>/dev/null)
                TEMP=$(echo "$PROBE_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['$jid']['temp'])" 2>/dev/null)
                log "  电机 $jid: 位置=${POS}° 电流=${CUR}A 温度=${TEMP}°C"
                alive=$((alive+1))
            else
                ERR=$(echo "$PROBE_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['$jid']['error'])" 2>/dev/null)
                err "  电机 $jid: $ERR"
                dead=$((dead+1))
                dead_list="$dead_list $jid"
            fi
        done
    else
        err "  ${side}通信失败: $PROBE_RESULT"
        return 1
    fi

    echo ""
    if [ $dead -eq 0 ]; then
        record_pass "${side}: $alive/7 电机全部在线"
    elif [ $alive -eq 0 ]; then
        record_fail "${side}: 0/7 电机在线（检查电源/CAN线）"
    else
        record_fail "${side}: $alive/7 在线, 电机${dead_list} 检测不到"
        info "故障排查:"
        info "  - 全部检测不到 → 电源/CAN/背板问题"
        info "  - 部分检测不到 → 线缆断路或电机损坏"
        info "  - 逐个单独供电测试定位故障"
    fi
}

if $PROBE_ONLY; then
    step "电机探测"
fi

# 根据 CAN 接口数量决定探测方式
if [ "$CAN_COUNT" -ge 4 ]; then
    # 双臂: can0+can1=左臂, can2+can3=右臂
    probe_arm "左臂" "can0 can1"
    probe_arm "右臂" "can2 can3"
elif [ "$CAN_COUNT" -ge 2 ]; then
    # 单臂或未配对
    probe_arm "机械臂" "can0 can1"
else
    warn "CAN 接口不足，跳过电机探测"
    record_fail "电机探测: CAN 接口不足（需至少 2 个）"
fi

# ============================================================
step "诊断总结"
# ============================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  结果: $PASS ✅ / $FAIL ❌"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}  🎉 硬件诊断全部通过！可以进入 Layer 2 通信验证。${NC}"
    echo ""
    echo "  下一步:"
    echo "    python3 ~/openarmx_ws/openarmx_debug.py --layer 2"
else
    echo -e "${YELLOW}  ⚠️  有 $FAIL 项未通过:${NC}"
    for item in "${FAIL_LIST[@]}"; do
        echo "    ❌ $item"
    done
    echo ""
    echo "  故障排查参考:"
    echo "    https://docs.openarmx.com/常见问题/硬件常见问题/"
fi

# 输出结构化结果（供上层脚本使用）
RESULT_FILE="/tmp/openarmx_hwcheck_result.json"
python3 -c "
import json
result = {
    'pass': $PASS,
    'fail': $FAIL,
    'pass_list': $(python3 -c "import json; print(json.dumps([$(printf '"%s",' "${PASS_LIST[@]}")]))" 2>/dev/null || echo '[]'),
    'fail_list': $(python3 -c "import json; print(json.dumps([$(printf '"%s",' "${FAIL_LIST[@]}")]))" 2>/dev/null || echo '[]'),
    'can_count': $CAN_COUNT,
}
with open('$RESULT_FILE', 'w') as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
" 2>/dev/null
info "结构化结果: $RESULT_FILE"

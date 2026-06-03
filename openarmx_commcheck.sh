#!/usr/bin/env bash
#
# OpenArmX Layer 2: 通信链路验证脚本
# ====================================
# 用法:
#   bash openarmx_commcheck.sh              # 完整通信验证
#   bash openarmx_commcheck.sh --auto-fix   # 自动修复（启用/配对）
#   bash openarmx_commcheck.sh --left       # 仅测试左臂
#   bash openarmx_commcheck.sh --right      # 仅测试右臂
#
# 前提: Layer 0 + Layer 1 已通过
# 安全: 只读通信，不会让电机运动
#

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

AUTO_FIX=false
TEST_LEFT=true
TEST_RIGHT=true
for arg in "$@"; do
    case $arg in
        --auto-fix) AUTO_FIX=true ;;
        --left)     TEST_RIGHT=false ;;
        --right)    TEST_LEFT=false ;;
        --help|-h)
            echo "用法: bash openarmx_commcheck.sh [--auto-fix] [--left|--right]"
            echo "  --auto-fix  自动启用 CAN 接口并配对通道"
            echo "  --left      仅测试左臂 (can0+can1)"
            echo "  --right     仅测试右臂 (can2+can3)"
            exit 0
            ;;
    esac
done

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

PASS=0; FAIL=0; WARN=0
PASS_LIST=(); FAIL_LIST=(); WARN_LIST=()
record_pass() { PASS=$((PASS+1)); PASS_LIST+=("$1"); log "$1"; }
record_fail() { FAIL=$((FAIL+1)); FAIL_LIST+=("$1"); err "$1"; }
record_warn() { WARN=$((WARN+1)); WARN_LIST+=("$1"); warn "$1"; }

# ============================================================
echo "📡 OpenArmX Layer 2: 通信链路验证"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
# ============================================================

# ============================================================
step "1/5 CAN 接口可用性"
# ============================================================

CAN_IFACES=$(ip link show 2>/dev/null | grep -oE "can[0-9]+" | sort -u | tr '\n' ' ' | sed 's/ *$//')
CAN_COUNT=$(echo "$CAN_IFACES" | wc -w)

if [ "$CAN_COUNT" -eq 0 ]; then
    record_fail "无 CAN 接口（Layer 1 未通过？）"
    exit 1
fi

record_pass "发现 CAN 接口: $CAN_IFACES ($CAN_COUNT 个)"

# 检查接口状态
DOWN_IFACES=""
for iface in $CAN_IFACES; do
    STATE=$(ip link show "$iface" 2>/dev/null | grep -oE "UP|DOWN|UNKNOWN" | head -1)
    if [ "$STATE" = "UP" ] || [ "$STATE" = "UNKNOWN" ]; then
        log "  $iface: $STATE"
    else
        warn "  $iface: $STATE (需要启用)"
        DOWN_IFACES="$DOWN_IFACES $iface"
    fi
done

# 自动修复 DOWN 接口
if [ -n "$DOWN_IFACES" ] && $AUTO_FIX; then
    info "自动启用 DOWN 接口..."
    for iface in $DOWN_IFACES; do
        sudo ip link set "$iface" up type can bitrate 1000000 2>/dev/null && \
            log "  $iface 已启用" || err "  $iface 启用失败"
    done
fi

# ============================================================
step "2/5 CAN 驱动类型识别"
# ============================================================

CAN_TYPE=$(python3 -c "
from openarmx_arm_driver.can_utils import check_can_interface_type
ifaces = [i for i in '$CAN_IFACES'.split() if i]
for i in ifaces:
    t = check_can_interface_type(i)
    print(f'{i}: {t}')
" 2>&1)

if [ $? -eq 0 ]; then
    record_pass "CAN 驱动类型识别成功"
    echo "$CAN_TYPE" | while read line; do info "  $line"; done
else
    record_warn "CAN 驱动类型识别失败（非致命）"
    info "  $CAN_TYPE"
fi

# ============================================================
step "3/5 CAN 接口功能验证"
# ============================================================

VERIFY_RESULT=$(python3 -c "
from openarmx_arm_driver.can_utils import verify_can_interface
ifaces = [i for i in '$CAN_IFACES'.split() if i]
for i in ifaces:
    ok = verify_can_interface(i)
    status = 'PASS' if ok else 'FAIL'
    print(f'{i}:{status}')
" 2>&1)

VERIFY_OK=true
while IFS= read -r line; do
    iface=$(echo "$line" | cut -d: -f1)
    status=$(echo "$line" | cut -d: -f2)
    if [ "$status" = "PASS" ]; then
        log "  $iface 功能验证通过"
    else
        err "  $iface 功能验证失败"
        VERIFY_OK=false
    fi
done <<< "$VERIFY_RESULT"

if $VERIFY_OK; then
    record_pass "全部 CAN 接口功能验证通过"
else
    record_fail "部分 CAN 接口功能验证失败"
    if $AUTO_FIX; then
        info "尝试重新启用全部接口..."
        python3 -c "from openarmx_arm_driver.can_utils import enable_all_can_interfaces; enable_all_can_interfaces()" 2>/dev/null
    fi
fi

# ============================================================
step "4/5 CAN 通道配对"
# ============================================================

PAIR_RESULT=$(python3 -c "
from openarmx_arm_driver.can_utils import pair_can_channels, get_available_can_interfaces
try:
    interfaces = get_available_can_interfaces()
    print(f'可用接口: {interfaces}')
    pair_can_channels()
    print('PAIR_OK')
except Exception as e:
    print(f'PAIR_FAIL: {e}')
" 2>&1)

if echo "$PAIR_RESULT" | grep -q "PAIR_OK"; then
    record_pass "CAN 通道配对成功"
    echo "$PAIR_RESULT" | while IFS= read -r line; do
        [ -n "$line" ] && info "  $line"
    done
else
    record_fail "CAN 通道配对失败"
    echo "$PAIR_RESULT" | while IFS= read -r line; do
        [ -n "$line" ] && err "  $line"
    done
fi

# ============================================================
step "5/5 电机通信验证"
# ============================================================

# 单臂探测函数
probe_arm_comm() {
    local side="$1"
    local channels="$2"

    info "验证${side}通信 ($channels)..."

    RESULT=$(python3 << PYEOF 2>&1
import json, sys
try:
    from openarmx_arm_driver import Arm
    channels = "$channels".split()
    arm = Arm(channels=channels)

    motors_online = 0
    motors_offline = 0
    motor_details = {}
    errors = []

    for jid in range(1, 8):
        try:
            status = arm.get_status(jid)
            motors_online += 1
            motor_details[jid] = {
                "online": True,
                "position": status.get("position", "N/A"),
                "velocity": status.get("velocity", "N/A"),
                "current": status.get("current", "N/A"),
                "temperature": status.get("temperature", "N/A"),
                "error_code": status.get("error_code", 0),
            }
        except Exception as e:
            motors_offline += 1
            motor_details[jid] = {
                "online": False,
                "error": str(e)[:80],
            }
            errors.append(f"电机{jid}: {str(e)[:50]}")

    arm.close()

    output = {
        "side": "$side",
        "channels": channels,
        "motors_online": motors_online,
        "motors_offline": motors_offline,
        "details": motor_details,
        "errors": errors,
    }
    print(json.dumps(output, ensure_ascii=False))

except Exception as e:
    print(json.dumps({
        "side": "$side",
        "error": str(e)[:100],
        "motors_online": 0,
        "motors_offline": 7,
    }, ensure_ascii=False))
PYEOF
    )

    # 解析结果
    ONLINE=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('motors_online',0))" 2>/dev/null)
    OFFLINE=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('motors_offline',7))" 2>/dev/null)
    ERROR_MSG=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)

    if [ -n "$ERROR_MSG" ] && [ "$ERROR_MSG" != "" ]; then
        record_fail "${side}: 通信失败 — $ERROR_MSG"
        return
    fi

    # 输出每个电机状态
    for jid in 1 2 3 4 5 6 7; do
        IS_ONLINE=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['details']['$jid']['online'])" 2>/dev/null)
        if [ "$IS_ONLINE" = "True" ]; then
            POS=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['details']['$jid']['position'],2))" 2>/dev/null)
            CUR=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['details']['$jid']['current'],3))" 2>/dev/null)
            TEMP=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['details']['$jid']['temperature'],1))" 2>/dev/null)
            ERR=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['details']['$jid'].get('error_code',0))" 2>/dev/null)

            if [ "$ERR" = "0" ] || [ "$ERR" = "None" ]; then
                log "  电机 $jid: 位置=${POS}°  电流=${CUR}A  温度=${TEMP}°C"
            else
                warn "  电机 $jid: 位置=${POS}°  电流=${CUR}A  温度=${TEMP}°C  错误码=$ERR"
            fi
        else
            ERR=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['details']['$jid'].get('error','unknown'))" 2>/dev/null)
            err "  电机 $jid: 离线 — $ERR"
        fi
    done

    # 总结
    echo ""
    if [ "$ONLINE" -eq 7 ]; then
        record_pass "${side}: 7/7 电机在线，通信正常"
    elif [ "$ONLINE" -gt 0 ]; then
        record_warn "${side}: $ONLINE/7 在线, $OFFLINE 离线"
    else
        record_fail "${side}: 0/7 电机在线"
    fi
}

if $TEST_LEFT && [ "$CAN_COUNT" -ge 2 ]; then
    probe_arm_comm "左臂" "can0 can1"
fi

if $TEST_RIGHT && [ "$CAN_COUNT" -ge 4 ]; then
    probe_arm_comm "右臂" "can2 can3"
elif $TEST_RIGHT && [ "$CAN_COUNT" -lt 4 ]; then
    warn "CAN 接口不足 4 个，跳过右臂测试"
fi

# ============================================================
step "验证总结"
# ============================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  结果: $PASS ✅  $FAIL ❌  $WARN ⚠️"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}  🎉 通信验证通过！可以进入 Layer 3 运动测试。${NC}"
    echo ""
    echo "  下一步:"
    echo "    bash -c \"\$(wget -qO- https://raw.githubusercontent.com/wxcadk/openarmx-setup/master/openarmx_motioncheck.sh)\""
else
    echo -e "${YELLOW}  ⚠️  有 $FAIL 项未通过:${NC}"
    for item in "${FAIL_LIST[@]}"; do
        echo "    ❌ $item"
    done
    if [ $WARN -gt 0 ]; then
        echo -e "${YELLOW}  $WARN 项警告:${NC}"
        for item in "${WARN_LIST[@]}"; do
            echo "    ⚠️  $item"
        done
    fi
    echo ""
    echo "  故障排查:"
    echo "    - CAN 通信失败 → 检查 CAN 线缆连接"
    echo "    - 电机离线 → 检查电源/CAN线/电机"
    echo "    - 参考: https://docs.openarmx.com/常见问题/硬件常见问题/"
fi

# 结构化结果
RESULT_FILE="/tmp/openarmx_commcheck_result.json"
python3 -c "
import json
result = {
    'pass': $PASS, 'fail': $FAIL, 'warn': $WARN,
    'can_count': $CAN_COUNT,
    'pass_list': $(printf '"%s",' "${PASS_LIST[@]}" 2>/dev/null | python3 -c "import sys; print('[' + sys.stdin.read().rstrip(',') + ']')" 2>/dev/null || echo '[]'),
    'fail_list': $(printf '"%s",' "${FAIL_LIST[@]}" 2>/dev/null | python3 -c "import sys; print('[' + sys.stdin.read().rstrip(',') + ']')" 2>/dev/null || echo '[]'),
    'warn_list': $(printf '"%s",' "${WARN_LIST[@]}" 2>/dev/null | python3 -c "import sys; print('[' + sys.stdin.read().rstrip(',') + ']')" 2>/dev/null || echo '[]'),
}
with open('$RESULT_FILE', 'w') as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
" 2>/dev/null
info "结构化结果: $RESULT_FILE"

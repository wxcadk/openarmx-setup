#!/usr/bin/env bash
#
# OpenArmX 环境一键配置脚本 (v2)
# ===================================
# 用法:
#   bash openarmx_setup.sh                # 完整配置（含 ROS2 + CAN 驱动）
#   bash openarmx_setup.sh --skip-ros2    # 跳过 ROS2 安装（已有 ROS2）
#   bash openarmx_setup.sh --skip-driver  # 跳过 CAN 驱动安装
#   bash openarmx_setup.sh --dry-run      # 仅检查，不执行安装
#   bash openarmx_setup.sh --help         # 帮助
#
# 适用: 全新 Ubuntu 22.04 LTS (Jammy)
# 功能: 镜像源 → ROS2 Humble → 功能包 → Python 依赖 → CAN 驱动 → 工作空间
# 镜像: apt 中科大, pip 中科大, ROS2 中科大
#

set -uo pipefail

# ============================================================
#  配置
# ============================================================
USTC_APT="https://mirrors.ustc.edu.cn/ubuntu/"
ROS2_MIRROR="https://mirrors.ustc.edu.cn/ros2/ubuntu"
PIP_MIRROR="https://mirrors.ustc.edu.cn/pypi/web/simple"
PIP_TRUSTED="mirrors.ustc.edu.cn"
KCAN_SDK_URL="https://gitee.com/ChengDu-KunHong/KH-UCANFD_Linux_SDK/releases/download/v1.2.2/KH-UCANFD_Linux_SDK.zip"
KCAN_VERSION="8.20.0"
WORKSPACE="$HOME/openarmx_ws"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SKIP_ROS2=false
SKIP_DRIVER=false
DRY_RUN=false
for arg in "$@"; do
    case $arg in
        --skip-ros2) SKIP_ROS2=true ;;
        --skip-driver) SKIP_DRIVER=true ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "用法: bash openarmx_setup.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --skip-ros2     跳过 ROS2 Humble 安装（已有 ROS2 时使用）"
            echo "  --skip-driver   跳过 KCAN 驱动安装"
            echo "  --dry-run       仅检查，不执行安装"
            echo "  --help          显示此帮助"
            echo ""
            echo "全新 Ubuntu 22.04 上直接运行: bash openarmx_setup.sh"
            echo "已有 ROS2 的机器:              bash openarmx_setup.sh --skip-ros2"
            exit 0
            ;;
    esac
done

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

run_or_dry() {
    local desc="$1"; shift
    if $DRY_RUN; then
        warn "$desc (dry-run 跳过)"
    else
        "$@"
    fi
}

# ============================================================
#  检查函数
# ============================================================
check_apt()  { dpkg -l "$1" 2>/dev/null | grep -q '^ii'; }
check_pip()  { python3 -c "import $1" 2>/dev/null; }
check_cmd()  { command -v "$1" &>/dev/null; }

# pip 安装封装（自动处理 PEP 668）
pip_install() {
    # 先试 --user，失败则加 --break-system-packages
    pip3 install --user "$@" -i "$PIP_MIRROR" --trusted-host "$PIP_TRUSTED" 2>&1 \
        | grep -E "Successfully|already satisfied|ERROR" || \
    pip3 install --user --break-system-packages "$@" -i "$PIP_MIRROR" --trusted-host "$PIP_TRUSTED" 2>&1 \
        | grep -E "Successfully|already satisfied|ERROR" || true
}

# ============================================================
#  开始
# ============================================================
echo "🤖 OpenArmX 环境一键配置 v2"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "系统: $(lsb_release -ds 2>/dev/null || echo '未知')"
echo "内核: $(uname -r)"
echo "用户: $(whoami)"

# 检查 Ubuntu 版本
UBUNTU_VER=$(lsb_release -cs 2>/dev/null)
if [ "$UBUNTU_VER" != "jammy" ]; then
    err "此脚本仅支持 Ubuntu 22.04 (jammy)，当前: $UBUNTU_VER"
    exit 1
fi

if $DRY_RUN; then
    warn "DRY RUN 模式 — 仅检查，不安装"
fi

TOTAL_STEPS=8
CURRENT_STEP=0

# ============================================================
step "$((++CURRENT_STEP))/$TOTAL_STEPS 配置镜像源（国内加速）"
# ============================================================

# 检查 apt 镜像
if grep -q "mirrors.ustc.edu.cn" /etc/apt/sources.list 2>/dev/null; then
    log "apt 镜像源: 中科大 ✅"
elif grep -q "mirrors.aliyun.com" /etc/apt/sources.list 2>/dev/null; then
    log "apt 镜像源: 阿里云 ✅"
elif grep -q "mirrors.tuna.tsinghua.edu.cn" /etc/apt/sources.list 2>/dev/null; then
    log "apt 镜像源: 清华 ✅"
else
    warn "apt 镜像源: 官方源（国内较慢）"
    if ! $DRY_RUN; then
        info "切换到中科大镜像源..."
        sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s)
        sudo sed -i 's|http://archive.ubuntu.com/ubuntu/|'"$USTC_APT"'|g' /etc/apt/sources.list
        sudo sed -i 's|http://security.ubuntu.com/ubuntu/|'"$USTC_APT"'|g' /etc/apt/sources.list
        log "apt 镜像源已切换到中科大（原文件已备份）"
    fi
fi

# ROS2 镜像源
if ! grep -q "mirrors.ustc.edu.cn/ros2" /etc/apt/sources.list.d/ros2.list 2>/dev/null; then
    if ! $DRY_RUN && [ -f /etc/apt/sources.list.d/ros2.list ]; then
        # 已有 ROS2 源但不是国内镜像
        sudo sed -i 's|http://packages.ros.org/ros2/ubuntu|'"$ROS2_MIRROR"'|g' /etc/apt/sources.list.d/ros2.list
        log "ROS2 apt 源已切换到中科大"
    fi
fi

# ============================================================
step "$((++CURRENT_STEP))/$TOTAL_STEPS 安装 ROS2 Humble"
# ============================================================

if $SKIP_ROS2; then
    warn "跳过 ROS2 安装 (--skip-ros2)"
elif check_cmd ros2; then
    log "ROS2 Humble 已安装"
else
    if $DRY_RUN; then
        warn "将安装 ROS2 Humble Desktop"
    else
        info "安装 ROS2 Humble（首次需几分钟）..."

        # 设置 ROS2 源
        if [ ! -f /etc/apt/sources.list.d/ros2.list ]; then
            sudo apt install -y software-properties-common curl 2>/dev/null
            sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
                -o /usr/share/keyrings/ros-archive-keyring.gpg 2>/dev/null
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] $ROS2_MIRROR $(lsb_release -cs) main" \
                | sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null
        fi

        sudo apt update -qq
        sudo apt install -y ros-humble-ros-base python3-rosdep python3-colcon-common-extensions 2>&1 | tail -5

        # 初始化 rosdep
        if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
            sudo rosdep init 2>/dev/null || true
        fi
        rosdep update 2>/dev/null || true

        # 配置环境自动加载
        if ! grep -q "setup.bash" ~/.bashrc; then
            echo "source /opt/ros/humble/setup.bash" >> ~/.bashrc
        fi
        source /opt/ros/humble/setup.bash 2>/dev/null

        log "ROS2 Humble 安装完成"
    fi
fi

# ============================================================
step "$((++CURRENT_STEP))/$TOTAL_STEPS 安装 ROS2 功能包"
# ============================================================

ROS2_PKGS=(
    ros-humble-moveit
    ros-humble-gripper-controllers
    ros-humble-position-controllers
    ros-humble-joint-state-broadcaster
    ros-humble-joint-trajectory-controller
    ros-humble-xacro
    ros-humble-hardware-interface
    ros-humble-controller-manager
    ros-humble-moveit-plugins
    ros-humble-moveit-ros-perception
    ros-humble-pinocchio
)

MISSING_ROS2=()
for pkg in "${ROS2_PKGS[@]}"; do
    if check_apt "$pkg"; then
        log "$pkg"
    else
        warn "$pkg — 待安装"
        MISSING_ROS2+=("$pkg")
    fi
done

if [ ${#MISSING_ROS2[@]} -gt 0 ]; then
    if $DRY_RUN; then
        warn "将安装 ${#MISSING_ROS2[@]} 个 ROS2 包"
    else
        log "安装 ${#MISSING_ROS2[@]} 个 ROS2 包..."
        sudo apt install -y "${MISSING_ROS2[@]}" 2>&1 | tail -3
        log "ROS2 包安装完成"
    fi
else
    log "全部 ROS2 包已就绪"
fi

# ============================================================
step "$((++CURRENT_STEP))/$TOTAL_STEPS 安装系统工具"
# ============================================================

SYSTEM_PKGS=(can-utils python3-vcstool libxcb-cursor0 libxcb-xinerama0
    libxcb-icccm4 libxcb-keysyms1 libxcb-render-util0 libfuse2 python3-pip
    build-essential g++ dkms wget unzip git libpopt-dev)

MISSING_SYS=()
for pkg in "${SYSTEM_PKGS[@]}"; do
    if check_apt "$pkg"; then
        log "$pkg"
    else
        warn "$pkg — 待安装"
        MISSING_SYS+=("$pkg")
    fi
done

if [ ${#MISSING_SYS[@]} -gt 0 ]; then
    if $DRY_RUN; then
        warn "将安装 ${#MISSING_SYS[@]} 个系统包"
    else
        sudo apt install -y "${MISSING_SYS[@]}" 2>&1 | tail -3
        log "系统工具安装完成"
    fi
else
    log "全部系统工具已就绪"
fi

# ============================================================
step "$((++CURRENT_STEP))/$TOTAL_STEPS 安装 Python 依赖"
# ============================================================

PY_MODULES=("can:python-can" "PySide6:pyside6" "openarmx_arm_driver:openarmx_arm_driver" "casadi:casadi")
MISSING_PY=()

for entry in "${PY_MODULES[@]}"; do
    mod="${entry%%:*}"
    pkg="${entry##*:}"
    if check_pip "$mod"; then
        ver=$(python3 -c "import $mod; print(getattr($mod, '__version__', 'OK'))" 2>/dev/null)
        log "python-$mod ($ver)"
    else
        warn "python-$mod — 待安装"
        MISSING_PY+=("$pkg")
    fi
done

# numpy 版本检查
NUMPY_OK=$(python3 -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo "none")
if [[ "$NUMPY_OK" == "1.26.4" ]]; then
    log "numpy==1.26.4"
else
    warn "numpy 当前=$NUMPY_OK, 需 1.26.4"
    MISSING_PY+=("numpy==1.26.4")
fi

if [ ${#MISSING_PY[@]} -gt 0 ]; then
    if $DRY_RUN; then
        warn "将安装 ${#MISSING_PY[@]} 个 Python 包: ${MISSING_PY[*]}"
    else
        log "安装 ${#MISSING_PY[@]} 个 Python 包..."
        pip_install "${MISSING_PY[@]}"
        log "Python 包安装完成"
    fi
else
    log "全部 Python 包已就绪"
fi

# ============================================================
step "$((++CURRENT_STEP))/$TOTAL_STEPS 配置工作空间"
# ============================================================

if [ -d "$WORKSPACE/src" ]; then
    log "工作空间 $WORKSPACE 已存在"
else
    if $DRY_RUN; then
        warn "将创建 $WORKSPACE/src"
    else
        mkdir -p "$WORKSPACE/src"
        log "工作空间 $WORKSPACE 创建完成"
    fi
fi

# OpenArmX 代码检查
if [ -d "$WORKSPACE/src/openarmx_ros2" ]; then
    log "openarmx_ros2 代码已存在"
else
    warn "openarmx_ros2 未克隆"
    if ! $DRY_RUN; then
        info "自动克隆 openarmx_ros2..."
        cd "$WORKSPACE/src"
        git clone https://github.com/openarmx/openarmx_ros2.git 2>&1 | tail -3
        if [ -f openarmx_ros2/openarmx.repos ]; then
            info "拉取依赖包..."
            vcs import < openarmx_ros2/openarmx.repos 2>&1 | tail -3
        fi
        log "openarmx_ros2 代码拉取完成"
    fi
fi

# ============================================================
step "$((++CURRENT_STEP))/$TOTAL_STEPS 安装 CAN 驱动"
# ============================================================

if $SKIP_DRIVER; then
    warn "跳过 CAN 驱动安装 (--skip-driver)"
elif lsmod | grep -q kcan; then
    log "KCAN 驱动已加载 ($(cat /sys/class/kcan/version 2>/dev/null || echo 'unknown'))"
elif lsmod | grep -q peak_usb; then
    log "PCAN 驱动已加载"
else
    if $DRY_RUN; then
        warn "将安装 KCAN 驱动"
    else
        # 安装 linux-headers（内核模块编译必需）
        if ! dpkg -l "linux-headers-$(uname -r)" 2>/dev/null | grep -q '^ii'; then
            sudo apt install -y "linux-headers-$(uname -r)" 2>&1 | tail -3
        fi

        # 检查 GCC 版本匹配
        KERNEL_GCC=$(grep -oP 'CONFIG_GCC_VERSION=\K\d+' /boot/config-$(uname -r) 2>/dev/null || echo "0")
        if [ "$KERNEL_GCC" -ge 120000 ] 2>/dev/null; then
            if ! check_cmd gcc-12; then
                sudo apt install -y gcc-12 2>&1 | tail -3
            fi
            sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 12 2>/dev/null || true
            log "GCC 已切到 gcc-12 (匹配内核)"
        fi

        # 下载 SDK
        if [ ! -d "$HOME/KH-UCANFD_LinuxSDK-v1.2.2" ]; then
            log "下载 KCAN SDK..."
            cd "$HOME"
            wget -q "$KCAN_SDK_URL" -O KH-UCANFD_Linux_SDK.zip
            unzip -o KH-UCANFD_Linux_SDK.zip -d "$HOME" >/dev/null 2>&1
        fi

        # 修复内核 Makefile
        sudo sed -i 's/-ftrivial-auto-var-init=zero//g' /usr/src/linux-headers-$(uname -r)/Makefile 2>/dev/null || true

        # 编译安装
        cd "$HOME/KH-UCANFD_LinuxSDK-v1.2.2"
        sudo chmod +x ./build.sh
        log "编译 KCAN 驱动..."
        sudo ./build.sh 2>&1 | grep -E "SUCCESS|ERROR|INFO" || true

        # DKMS 配置
        sudo mkdir -p /usr/src/kcan-${KCAN_VERSION}/
        sudo cp -r "$HOME/KH-UCANFD_LinuxSDK-v1.2.2/driver/"* /usr/src/kcan-${KCAN_VERSION}/

        cat << DKMS_EOF | sudo tee /usr/src/kcan-${KCAN_VERSION}/dkms.conf > /dev/null
PACKAGE_NAME="kunhong-linux-driver"
PACKAGE_VERSION="${KCAN_VERSION}"
CLEAN="make clean"
MAKE[0]="cd \${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/source; sed -i 's/-ftrivial-auto-var-init=zero//g' /usr/src/linux-headers-\${kernelver}/Makefile 2>/dev/null || true; make DKMS_KERNEL_DIR=\${kernel_source_dir} MOD=MODVERSIONS PAR=NO_PARPORT_SUBSYSTEM USB=USB_SUPPORT PCI=PCI_SUPPORT PCIEC=PCIEC_SUPPORT ISA=ISA_SUPPORT DNG=NO_DONGLE_SUPPORT PCC=NO_PCCARD_SUPPORT NET=NETDEV_SUPPORT RT=NO_RT"
BUILT_MODULE_NAME[0]="kcan"
BUILT_MODULE_LOCATION[0]="."
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="yes"
DKMS_EOF

        sudo dkms add -m kcan -v ${KCAN_VERSION} 2>/dev/null || true
        sudo dkms build -m kcan -v ${KCAN_VERSION} 2>&1 | tail -3
        sudo dkms install -m kcan -v ${KCAN_VERSION} 2>&1 | tail -3

        # 开机自启
        echo "kcan" | sudo tee /etc/modules-load.d/kcan.conf > /dev/null
        log "KCAN 驱动安装完成 + DKMS + 自启动"
    fi
fi

# ============================================================
step "$((++CURRENT_STEP))/$TOTAL_STEPS 配置用户权限"
# ============================================================

if id -nG | grep -q dialout; then
    log "dialout 权限已生效"
else
    if $DRY_RUN; then
        warn "将添加 dialout 权限"
    else
        sudo usermod -aG dialout "$USER"
        log "dialout 权限已添加（重新登录后生效，当前会话用 sg dialout 刷新）"
    fi
fi

# ============================================================
step "验证总结"
# ============================================================
PASS=0
FAIL=0

verify() {
    local label="$1"; local cmd="$2"
    if bash -c "$cmd" &>/dev/null; then
        log "$label"
        PASS=$((PASS+1))
    else
        err "$label"
        FAIL=$((FAIL+1))
    fi
    return 0
}

verify "Ubuntu 22.04"         "[ \"\$(lsb_release -cs)\" = 'jammy' ]"
verify "ROS2 Humble"          "bash -c 'source /opt/ros/humble/setup.bash 2>/dev/null; ros2 --help'"
verify "ros-humble-moveit"    "dpkg -l ros-humble-moveit 2>/dev/null | grep -q '^ii'"
verify "can-utils"            "command -v cansend"
verify "vcstool"              "command -v vcs"
verify "python-can"           "python3 -c 'import can'"
verify "PySide6"              "python3 -c 'import PySide6'"
verify "openarmx_arm_driver"  "python3 -c 'import openarmx_arm_driver'"
verify "casadi"               "python3 -c 'import casadi'"
verify "numpy==1.26.4"       "python3 -c 'import numpy; assert numpy.__version__==\"1.26.4\"'"
verify "CAN 驱动"             "lsmod | grep -qE 'kcan|peak_usb'"
verify "dialout 权限"         "id -nG | grep -q dialout || sg dialout -c true"
verify "工作空间"             "test -d $WORKSPACE/src"
verify "openarmx_ros2 代码"   "test -d $WORKSPACE/src/openarmx_ros2"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  结果: $PASS ✅ / $FAIL ❌ / $((PASS+FAIL)) 总计"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}  🎉 全部通过！可以进入硬件调试阶段。${NC}"
    echo ""
    echo "  下一步:"
    echo "    1. 重新登录（让 dialout 生效）"
    echo "    2. 连接 CAN USB 适配器 + 机械臂 + 48V 电源"
    echo "    3. cd $WORKSPACE && colcon build"
    echo "    4. python3 $WORKSPACE/openarmx_debug.py --layer 1"
else
    echo -e "${YELLOW}  ⚠️  有 $FAIL 项未通过，请检查上方日志。${NC}"
fi

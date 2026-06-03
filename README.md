# OpenArmX 一键配置与调试工具

全新 Ubuntu 22.04 上一键配置 OpenArmX 双臂机器人开发环境并进行硬件诊断。

## Layer 0: 环境一键配置

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/wxcadk/openarmx-setup/master/openarmx_setup.sh)"
```

已有 ROS2 的机器加 `--skip-ros2`：
```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/wxcadk/openarmx-setup/master/openarmx_setup.sh)" --skip-ros2
```

## Layer 1: 硬件自动诊断

插上 CAN USB 适配器 + 机械臂 + 48V 电源后运行：

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/wxcadk/openarmx-setup/master/openarmx_hwcheck.sh)"
```

自动修复模式（启用 CAN 接口/配对通道）：
```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/wxcadk/openarmx-setup/master/openarmx_hwcheck.sh)" --auto-fix
```

## 功能清单

### Layer 0 (openarmx_setup.sh)
- apt/pip/ROS2 镜像源配置（中科大）
- ROS2 Humble 自动安装
- 11 个 ROS2 功能包（MoveIt/控制器/xacro 等）
- 16 个系统工具（can-utils/dkms/git 等）
- 5 个 Python 包（openarmx_arm_driver/PySide6/casadi）
- 工作空间 + openarmx_ros2 代码自动拉取
- KCAN 驱动（DKMS 内核自动编译 + 自启动）
- dialout 权限配置

### Layer 1 (openarmx_hwcheck.sh)
- CAN 驱动状态检查
- CAN USB 适配器检测
- CAN 接口状态（UP/DOWN）
- CAN 通道自动配对
- 逐个电机探测（位置/电流/温度）
- 故障决策树（全挂/部分挂/单个挂）
- 结构化 JSON 结果输出

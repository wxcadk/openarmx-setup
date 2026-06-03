# OpenArmX 环境一键配置

全新 Ubuntu 22.04 上一键配置 OpenArmX 双臂机器人开发环境。

## 一键安装

```bash
source <(wget -qO- https://raw.githubusercontent.com/wxcadk/openarmx-setup/main/openarmx_setup.sh)
```

## 功能

- 自动配置 apt/pip/ROS2 国内镜像源（中科大）
- 安装 ROS2 Humble + MoveIt + 控制器
- 安装 Python 依赖（openarmx_arm_driver/PySide6/casadi）
- 安装 KCAN 驱动（含 DKMS 内核自动编译）
- 创建工作空间 + 自动拉取 openarmx_ros2 代码
- 配置用户权限（dialout）

## 选项

```bash
# 完整安装（全新机器）
source <(wget -qO- https://raw.githubusercontent.com/wxcadk/openarmx-setup/main/openarmx_setup.sh)

# 已有 ROS2，跳过 ROS2 安装
source <(wget -qO- https://raw.githubusercontent.com/wxcadk/openarmx-setup/main/openarmx_setup.sh) --skip-ros2

# 仅检查不安装
source <(wget -qO- https://raw.githubusercontent.com/wxcadk/openarmx-setup/main/openarmx_setup.sh) --dry-run
```

## 脚本内容

- [openarmx_setup.sh](openarmx_setup.sh)

#!/bin/bash

# 切换到 web_control_center 目录
cd "/Users/hh/Desktop/my/web_control_center"

# 清理屏幕
clear

echo "======================================"
echo "    正在启动 ECMAIN Web 控制中心...   "
echo "======================================"
echo ""

# 加载用户的环境变量 (支持 nvm, homebrew 等)，防止出现 npm command not found
source ~/.zshrc 2>/dev/null || true
source ~/.bash_profile 2>/dev/null || true
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# 提升 Mac OS 默认极低的文件句柄上限（默认只有256，高并发心跳极易导致 Too many open files 崩溃）
ulimit -n 65535 2>/dev/null || true

# 使用 python3 启动 start.py
python3 start.py

# 如果 python 意外退出，保持终端窗口不立刻关闭，方便看报错日志
echo ""
echo "程序已退出，请按任意键关闭窗口..."
read -n 1 -s

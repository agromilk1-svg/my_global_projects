#!/bin/bash
# 启动 Web 控制中心
# 确保在当前目录执行
cd "$(dirname "$0")"

echo "正在启动 ECWDA Web 控制中心..."
echo "访问地址: http://localhost:8000"

python3 web_control/main.py

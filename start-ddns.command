#!/bin/bash

# 获取脚本所在目录并切换过去
cd "$(dirname "$0")"

echo "======================================"
echo "        Cloudflare DDNS 启动器         "
echo "======================================"

# 执行 Node.js 脚本
node cloudflare-ddns.js

# 如果脚本意外退出，给出提示并等待用户手动关闭窗口
echo ""
echo "DDNS 脚本已退出。"
read -p "按回车键关闭此窗口..."

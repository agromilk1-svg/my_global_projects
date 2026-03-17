#!/bin/zsh

# GitHub 自动同步脚本
# 路径: /Users/hh/Desktop/my/sync.sh

PROJECT_DIR="/Users/hh/Desktop/my"

echo "开始同步..."
cd "$PROJECT_DIR" || exit

# 1. 获取远程更更新
echo "正在拉取远程更改..."
git pull --rebase origin main

# 2. 检查是否有本地修改并提交
if [[ -n $(git status -s) ]]; then
    echo "检测到本地修改，正在准备提交..."
    git add .
    COMMIT_MSG="Auto-sync: $(date '+%Y-%m-%d %H:%M:%S')"
    git commit -m "$COMMIT_MSG"
    
    # 3. 推送到远程
    echo "正在推送至远程仓库..."
    git push origin main
else
    echo "没有本地修改需要提交。"
fi

echo "同步完成！"

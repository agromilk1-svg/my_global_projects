#!/usr/bin/env bash

# 进入项目根目录
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "====================================="
echo "  Starting Web Control Center...     "
echo "====================================="

# 0. 启动前的环境自洁（自动查杀可能在上一次意外遗留占用 8088 / 5173 端口的僵尸进程）
echo "[0/2] Cleaning up zombie processes..."
lsof -ti:8088 | xargs kill -9 2>/dev/null
lsof -ti:5173 | xargs kill -9 2>/dev/null

# 1. 启动 FastAPI 后端
echo "[1/2] Starting Python Backend Server..."
source venv/bin/activate
# 在后台运行 backend，必须进入目录以规避相对引用错误
cd backend
uvicorn main:app --host 0.0.0.0 --port 8088 --reload &
BACKEND_PID=$!
cd ..

# 2. 启动 Vue 前端
echo "[2/2] Starting Vue Frontend Server..."
cd frontend
npm run dev -- --host &
FRONTEND_PID=$!

echo "====================================="
echo " Services are running! "
echo " Backend:  http://127.0.0.1:8088"
echo " Frontend: http://localhost:5173"
echo " Press Ctrl+C to stop all services."
echo "====================================="

# 捕获退出信号，清理后台进程
trap "kill $BACKEND_PID $FRONTEND_PID" SIGINT SIGTERM EXIT

# 阻塞保持脚本运行
wait

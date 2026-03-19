from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, UploadFile, File as FastAPIFile, Request, Depends
from fastapi.responses import FileResponse
import asyncio
import uuid
import json
import hmac
import base64
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import requests
import uvicorn
import socket
import logging
import time
import hashlib
from typing import List, Dict, Any, Optional

import os
import sqlite3

from device_manager import device_manager
from script_generator import generate_script
import proxy_parser

# 引入自研高并发数据库管理系统
import database
database.start_heartbeat_flusher()

app = FastAPI(title="Control Center API", description="Backend service for Web Control Center", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ================= Token 认证系统 =================

import os

# Token 签名密钥（生产环境应从环境变量读取）
_TOKEN_SECRET = os.environ.get('TOKEN_SECRET', 'ec_web_control_center_2026_secret_key')
_TOKEN_EXPIRE_SECONDS = 7 * 24 * 3600  # 7 天有效期

def _create_token(user_id: int, username: str, role: str) -> str:
    """生成自建 Token（base64 编码的 JSON 负载 + HMAC-SHA256 签名）"""
    payload = json.dumps({
        "id": user_id,
        "username": username,
        "role": role,
        "exp": time.time() + _TOKEN_EXPIRE_SECONDS
    }, separators=(',', ':'))
    payload_b64 = base64.urlsafe_b64encode(payload.encode()).decode()
    signature = hmac.new(_TOKEN_SECRET.encode(), payload_b64.encode(), hashlib.sha256).hexdigest()
    return f"{payload_b64}.{signature}"

def _verify_token(token: str) -> Optional[dict]:
    """验证 Token 有效性，返回负载或 None"""
    try:
        parts = token.split('.')
        if len(parts) != 2:
            return None
        payload_b64, signature = parts
        expected_sig = hmac.new(_TOKEN_SECRET.encode(), payload_b64.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected_sig):
            return None
        payload = json.loads(base64.urlsafe_b64decode(payload_b64).decode())
        if payload.get('exp', 0) < time.time():
            return None
        return payload
    except Exception:
        return None

def get_current_user(request: Request) -> dict:
    """FastAPI 路由依赖：从 Authorization 头或 query 参数解析当前登录用户"""
    # 优先从 Authorization 头读取
    auth_header = request.headers.get('Authorization', '')
    token = None
    if auth_header.startswith('Bearer '):
        token = auth_header[7:]
    else:
        # 回退：从 query 参数 token 读取（支持 <img src> 等无法附带 Header 的场景）
        token = request.query_params.get('token')
    
    if not token:
        raise HTTPException(status_code=401, detail="未登录或 Token 无效")
    user = _verify_token(token)
    if not user:
        raise HTTPException(status_code=401, detail="Token 已过期或无效，请重新登录")
    return user

def require_super_admin(user: dict = Depends(get_current_user)):
    """FastAPI 路由依赖：要求超级管理员权限"""
    if user.get('role') != 'super_admin':
        raise HTTPException(status_code=403, detail="权限不足，此操作仅限超级管理员")
    return user

def require_device_permission(user: dict, udid: str):
    """
    内部权限校验逻辑：
    1. 超级管理员 (super_admin) 拥有全局权限。
    2. 普通管理员 (admin) 必须被分配了该 UDID 才能操作。
    """
    if user.get("role") == "super_admin":
        return True
    
    assigned_devices = database.get_admin_devices(user.get("id"))
    if udid in assigned_devices:
        return True
        
    raise HTTPException(status_code=403, detail=f"Permission denied: You do not have access to device {udid}")

# ================= 登录与用户管理接口 =================

class LoginRequest(BaseModel):
    username: str
    password: str

class CreateAdminRequest(BaseModel):
    username: str
    password: str
    role: str = 'admin'

class UpdatePasswordRequest(BaseModel):
    password: str

class AssignDeviceRequest(BaseModel):
    device_udid: str

@app.post("/api/auth/login")
def api_login(req: LoginRequest):
    """管理员登录接口"""
    user = database.verify_admin_login(req.username, req.password)
    if not user:
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    token = _create_token(user['id'], user['username'], user['role'])
    return {
        "status": "ok",
        "token": token,
        "user": user
    }

@app.get("/api/auth/me")
def api_get_me(user: dict = Depends(get_current_user)):
    """获取当前登录用户信息"""
    # 刷新用户最新的角色信息（可能被超管修改过）
    db_user = database.get_admin_by_id(user['id'])
    if not db_user:
        raise HTTPException(status_code=401, detail="账号已被删除")
    return {"status": "ok", "user": db_user}

@app.get("/api/admins")
def api_get_admins(user: dict = Depends(require_super_admin)):
    """获取管理员列表（超级管理员专用）"""
    admins = database.get_all_admins()
    # 为每个管理员附加其所属设备列表
    for a in admins:
        a['devices'] = database.get_admin_devices(a['id'])
    return {"status": "ok", "data": admins}

@app.post("/api/admins")
def api_create_admin(req: CreateAdminRequest, user: dict = Depends(require_super_admin)):
    """创建管理员（超级管理员专用）"""
    admin_id = database.create_admin(req.username, req.password, req.role)
    if admin_id:
        return {"status": "ok", "id": admin_id}
    raise HTTPException(status_code=400, detail="创建失败，用户名可能已存在")

@app.delete("/api/admins/{admin_id}")
def api_delete_admin(admin_id: int, user: dict = Depends(require_super_admin)):
    """删除管理员（超级管理员专用）"""
    if admin_id == user['id']:
        raise HTTPException(status_code=400, detail="不能删除自己")
    if database.delete_admin(admin_id):
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="删除失败")

@app.put("/api/admins/{admin_id}/password")
def api_update_admin_password(admin_id: int, req: UpdatePasswordRequest, user: dict = Depends(require_super_admin)):
    """修改管理员密码（超级管理员专用）"""
    if database.update_admin_password(admin_id, req.password):
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="修改失败")

@app.post("/api/admins/{admin_id}/devices")
def api_assign_device(admin_id: int, req: AssignDeviceRequest, user: dict = Depends(require_super_admin)):
    """为管理员分配设备（超级管理员专用）"""
    if database.assign_device_to_admin(admin_id, req.device_udid):
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="分配失败")

@app.delete("/api/admins/{admin_id}/devices/{device_udid}")
def api_remove_device(admin_id: int, device_udid: str, user: dict = Depends(require_super_admin)):
    """取消管理员的设备分配（超级管理员专用）"""
    if database.remove_device_from_admin(admin_id, device_udid):
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="取消分配失败")

class RunTaskRequest(BaseModel):
    udid: str
    ecmain_url: str = ""
    actions: List[Dict[str, Any]] = None
    raw_script: str = ""

class DeviceConfigRequest(BaseModel):
    config_ip: str
    config_vpn: str
    device_no: str = ""
    country: str = ""
    group_name: str = ""
    exec_time: str = ""
    apple_account: str = ""
    apple_password: str = ""
    tiktok_accounts: str = "[]"

@app.get("/api/devices/{udid}/config")
def get_device_config_api(udid: str):
    config = database.get_device_config(udid)
    return {"status": "ok", "config": config}

@app.post("/api/devices/{udid}/config")
def set_device_config(udid: str, req: DeviceConfigRequest, user: dict = Depends(get_current_user)):
    require_device_permission(user, udid)
    success = database.set_device_config(
        udid, req.config_ip, req.config_vpn, 
        req.device_no, req.country, req.group_name, req.exec_time,
        req.apple_account, req.apple_password, req.tiktok_accounts
    )
    if success:
        return {"status": "ok", "message": "配置保存成功"}
    raise HTTPException(status_code=500, detail="保存失败")

class BatchDeviceConfigRequest(BaseModel):
    udids: List[str]
    country: str = None
    group_name: str = None
    exec_time: str = None
    config_vpn: str = None

@app.post("/api/devices/batch_update")
def batch_update_devices(req: BatchDeviceConfigRequest, user: dict = Depends(get_current_user)):
    """批量更新设备的国家、分组、启动时间、VPN配置"""
    # 权限校验（简单遍历校验，无权限的直接拦截整个请求）
    for udid in req.udids:
        require_device_permission(user, udid)
        
    success = database.batch_update_devices_config(
        req.udids, req.country, req.group_name, req.exec_time, req.config_vpn
    )
    if success:
        return {"status": "ok", "message": f"成功更新 {len(req.udids)} 台设备的配置"}
    raise HTTPException(status_code=500, detail="批量更新失败")

class BatchDeleteRequest(BaseModel):
    udids: List[str]

@app.delete("/api/devices/batch_delete")
def batch_delete_devices_api(req: BatchDeleteRequest, user: dict = Depends(get_current_user)):
    """批量删除设备"""
    for udid in req.udids:
        require_device_permission(user, udid)
        
    success = database.batch_delete_devices(req.udids)
    if success:
        return {"status": "ok", "message": f"成功删除 {len(req.udids)} 台设备"}
    raise HTTPException(status_code=500, detail="批量删除失败")

# ================= 配置中心字典 =================

class DictItemReq(BaseModel):
    name: str

@app.get("/api/countries")
def get_countries_api():
    return {"status": "ok", "data": database.get_all_countries()}

@app.post("/api/countries")
def create_country_api(req: DictItemReq):
    if database.add_country(req.name):
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="添加国家失败，可能已存在")

@app.delete("/api/countries/{cid}")
def delete_country_api(cid: int):
    database.delete_country(cid)
    return {"status": "ok"}

@app.get("/api/groups")
def get_groups_api():
    return {"status": "ok", "data": database.get_all_groups()}

@app.post("/api/groups")
def create_group_api(req: DictItemReq):
    if database.add_group(req.name):
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="添加分组失败，可能已存在")

@app.delete("/api/groups/{gid}")
def delete_group_api(gid: int):
    database.delete_group(gid)
    return {"status": "ok"}

# ==================== 执行时间配置 API ====================
@app.get("/api/exec_times")
def read_exec_times():
    return {"status": "ok", "data": database.get_all_exec_times()}

class NamePayloadExecTime(BaseModel):
    name: str

@app.post("/api/exec_times")
def add_exec_time_api(payload: NamePayloadExecTime):
    if database.add_exec_time(payload.name):
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="添加执行时间失败，可能已存在")

@app.delete("/api/exec_times/{tid}")
def delete_exec_time_api(tid: int):
    database.delete_exec_time(tid)
    return {"status": "ok"}


@app.get("/")
def read_root():
    return {"status": "ok", "message": "Web Control Center Backend is running."}

@app.get("/api/devices")
def get_devices():
    return {"devices": device_manager.get_all_devices()}

@app.delete("/api/devices/{udid}")
def delete_device(udid: str, user: dict = Depends(get_current_user)):
    require_device_permission(user, udid)
    database.delete_device(udid)
    return {"status": "ok", "message": f"Device {udid} deleted."}

@app.get("/api/cloud/devices") # 提供给前端查询群控大盘设备列表的接口
def get_cloud_devices(request: Request):
    # 合并云控设备和 USB 设备，使前端能统一展示和操控
    cloud_devs = database.get_all_cloud_devices()
    usb_devs = device_manager.get_all_devices()
    
    usb_udids = set(d['udid'] for d in usb_devs)
    
    # 用 UDID 作为主键合并
    merged = {}
    for d in cloud_devs:
        d['source'] = 'cloud'
        merged[d['udid']] = d
    
    for d in usb_devs:
        udid = d['udid']
        if udid in merged:
            # 同一设备既有 USB 又有云控心跳 → 合并，标记为 usb
            merged[udid].update(d)
            merged[udid]['source'] = 'usb'
        else:
            # 纯 USB 设备（还没发送过心跳）
            d['source'] = 'usb'
            d['status'] = 'online'
            merged[udid] = d
            
    # 新增：检测 3 种信道的实际可用性，直接抛给前端使用
    active_ws_udids = set(ACTIVE_TUNNELS.keys())
    for udid, d in merged.items():
        d['can_usb'] = udid in usb_udids
        d['can_lan'] = bool(d.get('local_ip') or d.get('ip'))
        # 如果有活跃的隧道，或是云端上报过的设备，或存在局域网IP的，都可以被当作具备 WS 控制能力
        d['can_ws'] = (udid in active_ws_udids) or (d.get('source') == 'cloud') or d['can_lan']
    
    # [权限过滤] 如果是普通管理员，仅返回其所属设备
    all_devices = list(merged.values())
    try:
        user = get_current_user(request)
        if user and user.get('role') != 'super_admin':
            allowed_udids = set(database.get_admin_devices(user['id']))
            all_devices = [d for d in all_devices if d.get('udid') in allowed_udids]
    except:
        pass  # Token 缺失时不过滤（兼容心跳等无 Token 调用）
    
    # [附加管理员信息] 批量查询设备→管理员映射
    admin_map = database.get_device_admin_map()
    for d in all_devices:
        d['admin_username'] = admin_map.get(d.get('udid'), '')
    
    return {"status": "ok", "devices": all_devices}

class ParseProxyRequest(BaseModel):
    content: str
    
@app.post("/api/parse_proxy")
def api_parse_proxy(req: ParseProxyRequest, user: dict = Depends(get_current_user)):
    try:
        nodes = proxy_parser.fetch_and_parse(req.content)
        return {"status": "ok", "nodes": nodes}
    except Exception as e:
        return {"status": "error", "msg": str(e)}
        return {"status": "error", "msg": str(e)}

# ================= 脚本任务管理 (Global) =================

class ScriptDataReq(BaseModel):
    name: str
    code: str
    country: str = ""
    group_name: str = ""
    exec_time: str = ""

class UpdateScriptReq(BaseModel):
    name: str = None
    code: str = None
    country: str = None
    group_name: str = None
    exec_time: str = None

class CommentDataReq(BaseModel):
    language: str
    content: str


@app.get("/api/scripts")
async def get_scripts_list():
    """获取所有全局自动动作任务"""
    return {"status": "ok", "data": database.get_all_scripts()}

@app.post("/api/scripts")
async def create_new_script(req: ScriptDataReq):
    script_id = database.create_script(req.name, req.code, req.country, req.group_name, req.exec_time)
    if script_id:
        return {"status": "ok", "id": script_id}
    raise HTTPException(status_code=500, detail="Failed to create script")

@app.put("/api/scripts/{script_id}")
async def update_existing_script(script_id: int, req: UpdateScriptReq):
    success = database.update_script(script_id, req.name, req.code, req.country or "", req.group_name or "", req.exec_time or "")
    if success:
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="Failed to update script or not found")

@app.delete("/api/scripts/{script_id}")
async def delete_existing_script(script_id: int, user: dict = Depends(get_current_user)):
    success = database.delete_script(script_id)
    if success:
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="Failed to delete script or not found")

# ==================== 评论列表接口 ====================

@app.get("/api/comments")
async def get_comments_list(language: str = None):
    """获取指定语言的评论数据（不传则获取所有）"""
    return {"status": "ok", "data": database.get_all_comments(language=language)}

@app.get("/api/comments/random")
async def get_random_comments_list(language: str = None, count: int = 50):
    """获取指定语言的一组随机评论数据，用于静态打包到脚本中"""
    return {"status": "ok", "data": database.get_random_comments(language=language, limit=count)}

@app.post("/api/comments")
async def create_new_comment(req: CommentDataReq, user: dict = Depends(require_super_admin)):
    success = database.add_comment(req.language, req.content)
    if success:
        return {"status": "ok"}
    raise HTTPException(status_code=500, detail="Failed to create comment")

@app.delete("/api/comments/{comment_id}")
async def delete_existing_comment(comment_id: int, user: dict = Depends(require_super_admin)):
    database.delete_comment(comment_id)
    return {"status": "ok"}

# ==================== TikTok 账号管理接口 ====================

class UpdateTikTokAccountReq(BaseModel):
    country: str = ""
    fans_count: int = 0
    is_for_sale: int = 0
    is_window_opened: int = 0
    add_time: str = ""
    window_open_time: str = ""
    sale_time: str = ""

@app.get("/api/tiktok_accounts")
async def get_tiktok_accounts_list(request: Request):
    """获取目前独立管理的全部 TikTok 账号列表及它们的设备关联号"""
    all_accounts = database.get_all_tiktok_accounts()
    # [权限过滤] 普通管理员仅看到自己所属设备的 TikTok 账号
    try:
        user = get_current_user(request)
        if user and user.get('role') != 'super_admin':
            allowed_udids = set(database.get_admin_devices(user['id']))
            all_accounts = [a for a in all_accounts if a.get('device_udid') in allowed_udids]
    except:
        pass
    return {"status": "ok", "data": all_accounts}

@app.put("/api/tiktok_accounts/{account_id}")
async def update_tiktok_account_info(account_id: int, req: UpdateTikTokAccountReq, user: dict = Depends(get_current_user)):
    success = database.update_tiktok_account(
        account_id, 
        req.country, 
        req.fans_count, 
        req.is_for_sale, 
        req.is_window_opened, 
        req.add_time, 
        req.window_open_time, 
        req.sale_time
    )
    if success:
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="Failed to update tiktok account or not found")

@app.delete("/api/tiktok_accounts/{account_id}")
async def delete_tiktok_account_api(account_id: int, user: dict = Depends(get_current_user)):
    """注意：由于前端手机列表依然存活，单独在此处删除只会影响本表的展示"""
    success = database.delete_tiktok_account(account_id)
    if success:
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="Failed to delete tiktok account")


@app.get("/api/device/scripts")
async def get_device_sync_scripts(
    country: str = "",
    group_name: str = ""
):
    """供 ECMAIN 客户端设备独立拉取全局控制脚本使用的接口
    支持按 country/group_name 过滤：
    - 脚本未设置该属性（空字符串或NULL）→ 对所有设备生效
    - 脚本设置了属性 → 仅对属性匹配的设备生效
    """
    scripts = database.get_all_scripts()
    filtered = []
    for s in scripts:
        s_country = (s.get("country") or "").strip()
        s_group = (s.get("group_name") or "").strip()
        # 脚本的每个过滤字段：为空则不限，有值则必须匹配
        if s_country and s_country != country:
            continue
        if s_group and s_group != group_name:
            continue
        filtered.append(s)
    return {"status": "ok", "tasks": filtered}

# ================= 一次性任务 API (One-Time Task) =================

class OneshotTaskReq(BaseModel):
    udids: List[str]
    name: str
    code: str

class OneshotCompleteReq(BaseModel):
    task_id: int

@app.post("/api/oneshot_tasks")
async def create_oneshot_tasks_api(req: OneshotTaskReq, user: dict = Depends(get_current_user)):
    """控制中心下发一次性任务（批量，每个 UDID 一条记录）"""
    if not req.udids or not req.code:
        raise HTTPException(status_code=400, detail="设备列表和脚本代码不能为空")
    created = database.create_oneshot_tasks(req.udids, req.name, req.code)
    return {"status": "ok", "message": f"成功为 {created} 台设备下发一次性任务"}

@app.get("/api/oneshot_tasks")
async def get_oneshot_tasks_api(user: dict = Depends(get_current_user)):
    """控制中心获取所有一次性任务列表"""
    return {"status": "ok", "data": database.get_all_oneshot_tasks()}

@app.delete("/api/oneshot_tasks/{task_id}")
async def delete_oneshot_task_api(task_id: int, user: dict = Depends(get_current_user)):
    """控制中心手动删除指定一次性任务"""
    if database.delete_oneshot_task(task_id):
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="删除失败或任务不存在")

@app.get("/api/device/oneshot_task")
async def get_device_oneshot_task(udid: str = ""):
    """ECMAIN 客户端轮询接口：查询该设备是否有待执行的一次性任务（无需 Token）"""
    if not udid:
        return {"status": "ok", "task": None}
    task = database.get_oneshot_task(udid)
    return {"status": "ok", "task": task}

@app.post("/api/device/oneshot_task/complete")
async def complete_device_oneshot_task(req: OneshotCompleteReq):
    """ECMAIN 客户端完成汇报：删除已完成的一次性任务记录（无需 Token）"""
    if database.complete_oneshot_task(req.task_id):
        return {"status": "ok", "message": "任务已完成并删除"}
    raise HTTPException(status_code=400, detail="任务不存在或已被删除")

# ================= 行动代理服务 =================

class ActionProxyRequest(BaseModel):
    udid: str = ""
    ecmain_url: str = ""
    action_type: str
    x: int = 0
    y: int = 0
    x1: int = 0
    y1: int = 0
    x2: int = 0
    y2: int = 0
    img_w: int = 0
    img_h: int = 0
    text: str = ""
    connection_mode: str = "" # 可选：usb, lan, ws，指示首选控制通路

SESSION_CACHE = {}
SIZE_CACHE = {}

ACTIVE_TUNNELS: Dict[str, WebSocket] = {}
PENDING_TASKS: Dict[str, asyncio.Future] = {}

class WSTunnelManager:
    async def connect(self, ws: WebSocket, device_key: str):
        await ws.accept()
        ACTIVE_TUNNELS[device_key] = ws
        
    def disconnect(self, device_key: str):
        if device_key in ACTIVE_TUNNELS:
            del ACTIVE_TUNNELS[device_key]

tunnel_manager = WSTunnelManager()

@app.websocket("/tunnel/ws/{device_key}")
async def ws_tunnel_endpoint(websocket: WebSocket, device_key: str):
    await tunnel_manager.connect(websocket, device_key)
    try:
        while True:
            data = await websocket.receive_text()
            try:
                msg = json.loads(data)
                if msg.get("type") == "ping":
                    await websocket.send_json({"type": "pong"})
                elif "id" in msg:
                    # 原生 iOS handleTunnelRequest 会原样弹回 id
                    reply_id = msg["id"]
                    if reply_id in PENDING_TASKS:
                        if not PENDING_TASKS[reply_id].done():
                            PENDING_TASKS[reply_id].set_result(msg)
            except Exception as e:
                logging.error(f"WS Parse error: {e}")
    except WebSocketDisconnect:
        tunnel_manager.disconnect(device_key)



@app.post("/api/action_proxy")
async def api_action_proxy(req: ActionProxyRequest, user: dict = Depends(get_current_user)):
    require_device_permission(user, req.udid)
    # 这是一个通用的指令透传代理接口，前端将原本发往本地 8089 的请求包裹后发到这里，由中继后端转发
    # 实现无视内网环境限制的远程操控能力。
    with open("api_debug.log", "a") as f:
        f.write(f"[{req.action_type}] RECVD: {req.dict()}\n")
        
    tunnel_ws = ACTIVE_TUNNELS.get(req.udid)
    
    # 构建一个挂起式异步 HTTP Over WebSocket 代理发射器
    async def _async_wda_request(method, url, json_body=None, timeout=15.0, force_http=False):
        # 优化：如果显式要求走 HTTP (如 USB 模式) 或者没有可用隧道，则降级走物理请求
        if tunnel_ws and not force_http:
            task_id = str(uuid.uuid4())
            loop = asyncio.get_event_loop()
            future = loop.create_future()
            PENDING_TASKS[task_id] = future
            try:
                await tunnel_ws.send_json({
                    "id": task_id,
                    "method": method,
                    "url": url,
                    "body": json_body
                })
                result = await asyncio.wait_for(future, timeout=timeout)
                return result.get("status", 500), result.get("body", {})
            except asyncio.TimeoutError:
                return 504, {"error": "Gateway Timeout over WebSocket"}
            except Exception as e:
                return 500, {"error": str(e)}
            finally:
                PENDING_TASKS.pop(task_id, None)
        else:
            # 降级：走局域网物理 HTTP 请求（通过线程池避免阻塞）
            # 特别：如果是本地 USB 端口 (127.0.0.1)，这部分逻辑现在能在 force_http=True 时被触发
            def _sync_req():
                if method.upper() == "GET":
                    resp = requests.get(url, timeout=timeout)
                else:
                    resp = requests.post(url, json=json_body, timeout=timeout)
                try:
                    return resp.status_code, resp.json()
                except:
                    return resp.status_code, {"raw_text": resp.text}
            return await asyncio.to_thread(_sync_req)
            
    try:
        # Ping 可以回溯基础测试通道
        if req.action_type == "ping":
            base = req.ecmain_url.rstrip('/')
            # Ping 应该基于提供的 URL 类型决定
            is_usb = "127.0.0.1" in base
            status, body = await _async_wda_request("GET", f"{base}/ping", timeout=3.0, force_http=is_usb)
            if status == 200:
                 return {"status": "ok", "detail": "ECMAIN Ping Success"}

        if not req.udid and not req.ecmain_url:
            return {"status": "error", "msg": "Neither UDID nor WLAN IP provided"}
        
        import re
        wlan_ip_match = re.search(r"http://([0-9\.]+)", req.ecmain_url)
        wlan_ip = wlan_ip_match.group(1) if wlan_ip_match else None
        
        dev = device_manager.devices.get(req.udid)
        
        force_http = False
        cache_key = req.udid
        
        # 依照前端选定的模式进行路由隔离
        if req.connection_mode == "usb" and dev:
            wda_url = f"http://127.0.0.1:{dev.wda_port}"
            force_http = True  # 用户/系统强行锁定为 USB, 必须走 HTTP
        elif req.connection_mode == "lan" and wlan_ip:
            wda_url = f"http://{wlan_ip}:10088"
            cache_key = wlan_ip
        elif req.connection_mode == "ws" and (req.udid in ACTIVE_TUNNELS):
            wda_url = f"http://localhost:10088" # 实际上在 WS 中由手机端替换为本地执行, 这里随便填一个占位
            force_http = False
        else:
            # Fallback 策略
            if dev and dev.wda_ready:
                wda_url = f"http://127.0.0.1:{dev.wda_port}"
                force_http = True
            elif wlan_ip:
                wda_url = f"http://{wlan_ip}:10088"
                cache_key = wlan_ip
            else:
                return {"status": "error", "msg": "Device not found in manager and no valid LAN IP."}
            
        # 激活/提取 WDA 通信 Session
        sid = SESSION_CACHE.get(cache_key)
        if sid:
            status, _ = await _async_wda_request("GET", f"{wda_url}/session/{sid}", timeout=2.0, force_http=force_http)
            if status != 200:
                sid = None
            
        if not sid:
            status, data = await _async_wda_request("POST", f"{wda_url}/session", json_body={"capabilities": {}}, timeout=5.0, force_http=force_http)
            if status == 200 and isinstance(data, dict):
                sid = data.get("sessionId") or data.get("value", {}).get("sessionId")
                SESSION_CACHE[cache_key] = sid
                
        if not sid:
             return {"status": "error", "msg": f"Failed to connect active WDA session at {wda_url}"}
             
        # 提取动态屏幕映射比例（如果前端上报了真实图片宽度）
        scale = 1.0
        if req.img_w > 0:
            sz_val = SIZE_CACHE.get(cache_key)
            if not sz_val:
                 status, sz_resp = await _async_wda_request("GET", f"{wda_url}/session/{sid}/window/size", timeout=3.0)
                 if status == 200 and isinstance(sz_resp, dict):
                     sz_val = sz_resp.get("value", {})
                     if "width" in sz_val:
                          SIZE_CACHE[cache_key] = sz_val

            if sz_val and "width" in sz_val and sz_val["width"] > 0:
                 scale = req.img_w / sz_val["width"]
                 
        # 换算最终发向底层的精准 W3C Points 逻辑坐标
        wda_x = int(req.x / scale)
        wda_y = int(req.y / scale)
        wda_x1 = int(req.x1 / scale)
        wda_y1 = int(req.y1 / scale)
        wda_x2 = int(req.x2 / scale)
        wda_y2 = int(req.y2 / scale)

        async def _safe_wda_post(target, **kwargs):
             status, body = await _async_wda_request("POST", target, json_body=kwargs.get("json"), timeout=kwargs.get("timeout", 10.0), force_http=force_http)
             if status == 200:
                 return body
             return {"raw_status": status, "raw_text": body}

        # 分发给 WDA 自定义异步动作端点，避雷标准动作的闲置检测死锁霸屏
        if req.action_type == "click":
             status, res = await _async_wda_request("POST", f"{wda_url}/wda/tapByCoord", json_body={"x": wda_x, "y": wda_y}, timeout=3.0, force_http=force_http)
             return {"status": "ok", "detail": f"Tap at ({wda_x}, {wda_y})"}
            
        elif req.action_type == "longPress":
             status, res = await _async_wda_request("POST", f"{wda_url}/wda/longPress", json_body={"x": wda_x, "y": wda_y, "duration": 1.0}, timeout=3.0, force_http=force_http)
             return {"status": "ok", "detail": f"LongPress at ({wda_x}, {wda_y})"}
            
        elif req.action_type == "swipe":
             status, res = await _async_wda_request("POST", f"{wda_url}/wda/swipeByCoord", json_body={"fromX": wda_x1, "fromY": wda_y1, "toX": wda_x2, "toY": wda_y2, "duration": 0.5}, timeout=3.0, force_http=force_http)
             return {"status": "ok", "detail": f"Swipe from ({wda_x1},{wda_y1}) to ({wda_x2},{wda_y2})"}
            
        elif req.action_type == "home":
             status, res = await _async_wda_request("POST", f"{wda_url}/wda/homescreen", timeout=3.0, force_http=force_http)
             return {"status": "ok", "detail": "Homescreen triggered"}
             
        elif req.action_type == "lock":
             status, res = await _async_wda_request("POST", f"{wda_url}/session/{sid}/wda/lock", timeout=3.0, force_http=force_http)
             return {"status": "ok", "detail": "Screen locked"}
             
        elif req.action_type == "volumeUp":
             status, res = await _async_wda_request("POST", f"{wda_url}/session/{sid}/wda/pressButton", json_body={"name": "volumeUp"}, timeout=3.0, force_http=force_http)
             return {"status": "ok", "detail": "Volume up pressed"}
             
        elif req.action_type == "volumeDown":
             status, res = await _async_wda_request("POST", f"{wda_url}/session/{sid}/wda/pressButton", json_body={"name": "volumeDown"}, timeout=3.0, force_http=force_http)
             return {"status": "ok", "detail": "Volume down pressed"}
             
        elif req.action_type == "launch":
             resp = await _safe_wda_post(f"{wda_url}/session/{sid}/wda/apps/launch", json={"bundleId": req.text}, timeout=10.0)
             return {"status": "ok", "detail": resp}
             
        elif req.action_type == "terminate":
             resp = await _safe_wda_post(f"{wda_url}/session/{sid}/wda/apps/terminate", json={"bundleId": req.text}, timeout=10.0)
             return {"status": "ok", "detail": resp}
             
        elif req.action_type == "ocr":
             resp = await _safe_wda_post(f"{wda_url}/wda/ocr", json={}, timeout=15.0)
             return {"status": "ok", "detail": resp}
             
        elif req.action_type == "findText":
             resp = await _safe_wda_post(f"{wda_url}/wda/findText", json={"text": req.text}, timeout=15.0)
             return {"status": "ok", "detail": resp}
             
        return {"status": "error", "msg": f"Unsupported action {req.action_type}"}
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/run")
async def api_run_script(req: RunTaskRequest, user: dict = Depends(get_current_user)):
    require_device_permission(user, req.udid)
    """
    接收前端生成的脚本指令，并通过双重信道（WS/HTTP）下发至手机。
    """
    udid = req.udid
    try:
        base_js = generate_script(req.actions) if req.actions else ""
        js_code = base_js + "\n\n" + (req.raw_script or "")
        js_code = js_code.strip()
        
        if not js_code:
             raise HTTPException(status_code=400, detail="发令拦截！动作区块图队及原始手打黑窗内皆空空如也，无车可发！长官！")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Script Generate Error: {str(e)}")
    
    # 优先级 0: 检查 WebSocket 隧道（实现跨内网穿透）
    tunnel_ws = ACTIVE_TUNNELS.get(udid)
    if tunnel_ws:
        try:
            task_id = "ws_script_" + str(uuid.uuid4())[:8]
            loop = asyncio.get_event_loop()
            future = loop.create_future()
            PENDING_TASKS[task_id] = future
            
            # 使用手机端已支持的 /api/wakeup_task 拦截器下发脚本
            await tunnel_ws.send_json({
                "id": task_id,
                "method": "POST",
                "url": "/api/wakeup_task",
                "body": {"script": js_code}
            })
            
            # 脚本执行可能较长，给予 120 秒宽限期
            try:
                result = await asyncio.wait_for(future, timeout=120.0)
                # iOS 端现在的 handleTunnelRequest 返回的是 {"id":..., "status":200, "body":...}
                return result.get("body", {"status": "success", "msg": "WS Tunnel Dispatch OK"})
            except asyncio.TimeoutError:
                # 如果超时，说明脚本太长或 WS 断了，尝试降级到传统的 HTTP 通信
                logging.warning(f"[run_script] WS Tunnel Timeout for {udid}, falling back to HTTP...")
            finally:
                PENDING_TASKS.pop(task_id, None)
        except Exception as e:
            logging.error(f"[run_script] WS Tunnel Error: {e}")

    # 【降级通道】：通过各种可能的局域网 IP 尝试直连
    target_host_candidates = []
    
    # 1. 客户端手动携带的降级指令优先
    if req.ecmain_url:
        import re
        m = re.search(r"http://([0-9\.]+)(?::(\d+))?", req.ecmain_url)
        if m:
            target_host_candidates.append((m.group(1), int(m.group(2)) if m.group(2) else 8089))
            
    # 获取 USB 状态
    target_usb = next((d for d in device_manager.get_all_devices() if d["udid"] == req.udid), None)
    
    # 双重保险：即便 device_manager 发生心跳闪断漏报，只要底层 Tidevice 的 relay_8089 进程还在存活，我们依然强制走 USB
    relay_uid = f"{req.udid}_8089"
    relay_proc = _RELAY_PROCS.get(relay_uid)
    is_relay_alive = relay_proc and relay_proc.poll() is None

    # 2. 如果检测到 USB 物理连接，使用 DeviceManager 分配的动态脚本端口
    if target_usb:
        script_port = target_usb.get("script_port") or 8089
        target_host_candidates.append(("127.0.0.1", script_port))
    elif is_relay_alive:
        # 兼容旧的中继进程 (如果存在)
        target_host_candidates.append(("127.0.0.1", 8089))
        
    # 3. 尝试云端心跳上报的局域网 IP 作为兜底
    cloud_devs = database.get_all_cloud_devices()
    target_cloud = next((d for d in cloud_devs if d["udid"] == req.udid), None)
    if target_cloud and target_cloud.get("ip"):
        lan_ip = target_cloud.get("ip")
        if (lan_ip, 8089) not in target_host_candidates:
            target_host_candidates.append((lan_ip, 8089))
         
    if not target_host_candidates:
         # 如果连 WS 都没有，且没 IP，才报寻址失败
         if not tunnel_ws:
            raise HTTPException(status_code=400, detail=f"Target Device [UDID: {req.udid}] went dark. Failed to resolve coordinate IP.")
         else:
            return {"status": "error", "message": "WS 隧道执行超时且无有效局域网通道可回退"}

    # 同步阻塞下发：直接请求 ECMAIN
    payload = {"type": "SCRIPT", "payload": js_code}
    
    last_error = None
    for target_host, target_port in target_host_candidates:
        target_url = f"http://{target_host}:{target_port}/task"
        try:
            resp = requests.post(target_url, json=payload, timeout=64) 
            if resp.status_code == 200:
                return resp.json()
            else:
                return {"status": "error", "message": f"ECMAIN 引擎返回未决状态码 {resp.status_code}", "detail": resp.text}
        except requests.exceptions.Timeout:
            return {"status": "error", "message": "脚本执行超时熔断 (超60秒)"}
        except Exception as ex:
            logging.warning(f"[run_script] 尝试下发到 {target_host}:{target_port} 失败: {ex}")
            last_error = ex
            continue
            
    return {"status": "error", "message": "连通性瘫痪，ECMAIN 所有寻址信道均不可达", "detail": str(last_error)}

from fastapi.responses import StreamingResponse

@app.get("/api/screen/{udid}")
async def get_screen_stream(udid: str, ip: str = None, usb: str = 'true', mode: str = 'usb', token: str = None, user: dict = Depends(get_current_user)):
    require_device_permission(user, udid)
    
    if mode == 'ws':
        async def iter_ws_frames():
            consecutive_errors = 0
            max_errors = 10  # 连续失败 10 次才放弃（慢速网络友好）
            
            while consecutive_errors < max_errors:
                tunnel_ws = ACTIVE_TUNNELS.get(udid)
                if not tunnel_ws:
                    logging.warning(f"WS tunnel for {udid} not active, waiting...")
                    await asyncio.sleep(3.0)
                    consecutive_errors += 1
                    continue

                task_id = str(uuid.uuid4())
                loop = asyncio.get_event_loop()
                future = loop.create_future()
                PENDING_TASKS[task_id] = future
                try:
                    await tunnel_ws.send_json({
                        "id": task_id,
                        "method": "GET",
                        "url": "http://127.0.0.1:10088/screenshot"
                    })
                    # 慢速网络给 15 秒超时（VPN + Cloudflare 穿透链路较长）
                    result = await asyncio.wait_for(future, timeout=15.0)
                    body = result.get("body", {})
                    b64 = body.get("value")
                    if b64:
                        import base64
                        frame = base64.b64decode(b64)
                        yield (
                            b"--myboundary\r\n"
                            b"Content-Type: image/jpeg\r\n"
                            b"Content-Length: " + str(len(frame)).encode() + b"\r\n\r\n" + 
                            frame + b"\r\n"
                        )
                        consecutive_errors = 0  # 成功一次就重置计数
                    else:
                        consecutive_errors += 1
                except asyncio.TimeoutError:
                    logging.warning(f"WS screenshot timeout for {udid} ({consecutive_errors+1}/{max_errors})")
                    consecutive_errors += 1
                except Exception as e:
                    logging.warning(f"WS screenshot stream error: {e}")
                    consecutive_errors += 1
                finally:
                    PENDING_TASKS.pop(task_id, None)
                    
                # 慢速网络下每 2 秒轮询一次（避免堆积请求导致阻塞）
                await asyncio.sleep(2.0)
            
            logging.error(f"WS screenshot stream gave up after {max_errors} consecutive errors for {udid}")

        return StreamingResponse(
            iter_ws_frames(), 
            media_type="multipart/x-mixed-replace; boundary=myboundary"
        )

    # Determine the target IP and PORT for the raw TCP socket
    target_ip = "127.0.0.1"
    target_port = 11100 # 默认候选 (MJPEG 端口池起点)

    # 优先从 DeviceManager 获取 USB 设备动态映射的端口
    dev = device_manager.devices.get(udid)
    if dev:
        target_port = dev.mjpeg_port
    
    if usb.lower() == 'false' and ip:
        target_ip = ip
        target_port = 10089 # 内网模式通常直接访问手机 10089

    # Raw TCP Generator to extract JPEG frames from non-HTTP naked stream
    async def iter_tcp_frames():
        jwt_start = b"\xff\xd8"
        jwt_end = b"\xff\xd9"
        
        retries = 0
        while retries < 3:
            try:
                reader, writer = await asyncio.wait_for(
                    asyncio.open_connection(target_ip, target_port), timeout=3.0
                )
                writer.write(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
                await writer.drain()
            except Exception as e:
                logging.warning(f"MJPEG connect warning: {e}")
                retries += 1
                await asyncio.sleep(1.0)
                continue
                
            buffer = b""
            frames_yielded = 0
            try:
                while True:
                    data = await reader.read(8192)
                    if not data:
                        break
                    buffer += data
                    
                    # Try to extract a full frame
                    start_idx = buffer.find(jwt_start)
                    end_idx = buffer.find(jwt_end)
                    
                    if start_idx != -1 and end_idx != -1 and end_idx > start_idx:
                        # Found a complete JPEG frame
                        frame = buffer[start_idx:end_idx + 2]
                        buffer = buffer[end_idx + 2:]
                        
                        # Yield standard multipart chunk
                        yield (
                            b"--myboundary\r\n"
                            b"Content-Type: image/jpeg\r\n"
                            b"Content-Length: " + str(len(frame)).encode() + b"\r\n\r\n" + 
                            frame + b"\r\n"
                        )
                        frames_yielded += 1
                        if frames_yielded > 5:
                            # Connection is stable, reset retries
                            retries = 0
                    elif start_idx != -1 and end_idx == -1:
                        # Strip trash before start
                        buffer = buffer[start_idx:]
                    elif len(buffer) > 2 * 1024 * 1024:
                        # Prevent buffer overflow
                        buffer = b""
            except Exception as e:
                logging.warning(f"MJPEG stream broken: {e}")
            finally:
                writer.close()
                await writer.wait_closed()
            
            # If we reach here, stream collapsed.
            retries += 1
            await asyncio.sleep(1.0)
            
    return StreamingResponse(
        iter_tcp_frames(), 
        media_type="multipart/x-mixed-replace; boundary=myboundary"
    )

@app.get("/api/probe")
def api_probe(ip: str):
    import requests
    import re
    # 提取干净的 IP
    m = re.search(r"([0-9\.]+)", ip)
    target_ip = m.group(1) if m else "127.0.0.1"
    
    status_8089 = False
    status_10088 = False
    msg_8089 = ""
    msg_10088 = ""
    
    # 探活 8089 (ECMAIN - 模拟下发空指令)
    try:
        r1 = requests.post(
            f"http://{target_ip}:8089/task", 
            json={"type":"SCRIPT", "payload":"console.log('Probe ping');"}, 
            timeout=2.5
        )
        status_8089 = (r1.status_code == 200)
        msg_8089 = "通畅" if status_8089 else f"异常 ({r1.status_code})"
    except requests.exceptions.Timeout:
        msg_8089 = "超时未响应"
    except Exception as e:
        msg_8089 = "离线阻断"
        
    # 探活 10088 (WDA / Status)
    try:
        r2 = requests.get(f"http://{target_ip}:10088/status", timeout=1.5)
        status_10088 = (r2.status_code == 200)
        msg_10088 = "通畅" if status_10088 else f"异常 ({r2.status_code})"
    except Exception as e:
        msg_10088 = "离线阻断"
        
    return {
        "status": "ok",
        "ip": target_ip,
        "detail": f"ECMAIN (8089): {msg_8089} | WDA (10088): {msg_10088}",
        "port_8089": status_8089,
        "port_10088": status_10088
    }

_WDA_PROCS = {}
_RELAY_PROCS = {}
import os
import shutil

def _kill_previous_process(proc_dict, udid):
    if udid in proc_dict:
        try:
            p = proc_dict[udid]
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=2)
        except Exception:
            pass
        finally:
            proc_dict.pop(udid, None)

class LaunchReq(BaseModel):
    udid: str

@app.post("/api/launch_ecwda")
def api_launch_ecwda(req: LaunchReq, user: dict = Depends(get_current_user)):
    require_device_permission(user, req.udid)
    import subprocess
    
    try:
        # 自动查找当前 USB 连接的设备
        # ECMAIN 心跳 UDID (identifierForVendor) 和 USB 硬件 UDID 格式不同，不能直接匹配
        # 所以优先使用 DeviceManager 检测到的 USB 设备
        usb_devices = device_manager.get_all_devices()
        
        if not usb_devices:
            raise HTTPException(status_code=400, detail="未检测到 USB 连接的设备，请确认数据线已插好")
        
        # 如果传入的 UDID 刚好匹配 USB 设备就用它，否则用第一个 USB 设备
        udid = req.udid
        usb_udids = [d['udid'] for d in usb_devices]
        if udid not in usb_udids:
            udid = usb_udids[0]
            logging.info(f"传入 UDID {req.udid[:8]} 非 USB 设备，自动使用 USB 设备: {udid[:8]}")
        
        # 1. 净化历史引用遗留
        _kill_previous_process(_WDA_PROCS, udid)
        
        # 净化系统级残留（仅针对主核心，relay 交由 DeviceManager 管理）
        import platform_utils
        platform_utils.kill_process_by_keyword(f"tidevice -u {udid} xctest")
        
        # 2. 跨平台定位 tidevice 可执行文件
        t_path = platform_utils.find_tidevice()

        env = platform_utils.get_env_with_path()

        # 创建一个真实的伪输出缓冲文件（切忌给 DEVNULL，否则部分 C 级通信套件会判定通道阻塞自杀）
        log_file_path = os.path.join(os.path.dirname(__file__), "wda_run.log")
        wda_log = open(log_file_path, "a")

        # 3. 长生存权：直接被 fastapi 内存池引用，保证 USB 连接稳定
        # 3. 唤醒主核心 XCTest 流
        cmd_wda = [t_path, "-u", udid, "xctest", "-B", "com.facebook.WebDriverAgentRunner.ecwda"]
        _WDA_PROCS[udid] = subprocess.Popen(cmd_wda, stdout=wda_log, stderr=wda_log, env=env)
        
        # 4. 触发 DeviceManager 的重连/转发机制
        # DeviceManager 会自动处理 WDA(10088), MJPEG(10089) 和 ECMAIN(8089) 的 relay
        if udid in device_manager.devices:
            device_manager._start_tunnels(udid)

        logging.info(f"ECWDA 唤醒波已通过 DeviceManager 接管全链转发！USB UDID: {udid}")
        return {"status": "ok", "message": f"底层 tidevice 唤醒波已送达，中继已在后台建立 (USB设备: {udid[:8]})"}
        
    except HTTPException:
        raise
    except Exception as e:
        logging.error(f"启动 EC 严重受阻: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/ping")
def ping():
    return {"ping": "pong"}

# ==================== ECMAIN 群控高并发心跳系统 ====================

class HeartbeatRequest(BaseModel):
    udid: str
    device_no: str = ""
    status: str
    local_ip: str
    battery_level: int = 0
    app_version: int = 0
    ecwda_version: int = -1  # ECWDA 本地版本号，-1 表示客户端未上报
    vpn_active: bool = False  # VPN 连接状态
    vpn_ip: str = ""  # VPN 局域网分配 IP
    ecwda_status: str = "offline" # ECWDA 的探活结果
    config_checksum: str = ""
    task_status: str = ""  # 任务状态 JSON 数组，如 [{"name":"xxx","time":"HH:mm:ss"}]
    admin_username: str = "" # iOS 仪表盘手动输入的所属管理员账号

# ECMAIN / ECWDA 编译后输出的更新包存放目录
ECMAIN_BUILD_OUTPUT = os.path.join(os.path.dirname(__file__), "updates")

# 读取服务器端最新的 ECMAIN 版本信息
def _get_latest_ecmain_version():
    version_path = os.path.join(ECMAIN_BUILD_OUTPUT, "ecmain_version.json")
    try:
        if os.path.exists(version_path):
            with open(version_path, "r") as f:
                return json.load(f)
    except Exception as e:
        logging.error(f"读取版本文件失败: {e}")
    return None

# 读取服务器端最新的 ECWDA 版本信息
def _get_latest_ecwda_version():
    version_path = os.path.join(ECMAIN_BUILD_OUTPUT, "ecwda_version.json")
    try:
        if os.path.exists(version_path):
            with open(version_path, "r") as f:
                return json.load(f)
    except Exception as e:
        logging.error(f"读取 ECWDA 版本文件失败: {e}")
    return None

@app.post("/devices/heartbeat")
def handle_heartbeat(req: HeartbeatRequest):
    """
    接收来自 ECMAIN 每分钟发送的心跳，承接 10万 级并发。
    写数据库靠 database 独有的异步 bulk 消化。
    """
    # 兼容手动点击“保存测试”发送的 ping 状态，将其视为 online
    actual_status = "online" if req.status == "ping" else req.status
    
    database.register_heartbeat(req.udid, {
        "device_no": req.device_no,
        "status": actual_status,
        "local_ip": req.local_ip,
        "battery_level": req.battery_level,
        "app_version": req.app_version,
        "ecwda_version": req.ecwda_version,
        "vpn_active": 1 if req.vpn_active else 0,
        "vpn_ip": req.vpn_ip,
        "ecwda_status": req.ecwda_status,
        "task_status": req.task_status
    })
    
    # 【自动绑定逻辑】如果心跳携带了管理员账号，则自动建立归属关系
    if req.admin_username:
        admin_uname_clean = req.admin_username.strip()
        # 查找管理员 ID (忽略大小写进行匹配)
        with sqlite3.connect(database.DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('SELECT id FROM ec_admins WHERE username COLLATE NOCASE = ?', (admin_uname_clean,))
            admin_row = cursor.fetchone()
            if admin_row:
                admin_id = admin_row['id']
                # 检查是否已绑定，若无则自动绑定
                database.assign_device_to_admin(admin_id, req.udid)
            else:
                logging.warning(f"Heartbeat reported unknown admin: '{req.admin_username}' (cleaned: '{admin_uname_clean}')")
    
    response = {"status": "ok"}
    
    # 获取此手机全局的配置档案，计算 MD5 若不一致，要求客户端下发更新
    device_conf = database.get_device_config(req.udid)
    raw_hash_str = (
        device_conf.get("config_ip", "") + 
        device_conf.get("config_vpn", "") +
        device_conf.get("country", "") +
        device_conf.get("group_name", "") +
        device_conf.get("exec_time", "") +
        device_conf.get("apple_account", "") +
        device_conf.get("apple_password", "") +
        device_conf.get("tiktok_accounts", "[]")
    )
    server_checksum = hashlib.md5(raw_hash_str.encode('utf-8')).hexdigest()
    
    if req.config_checksum != server_checksum:
        response["push_config"] = {
            "config_ip": device_conf.get("config_ip", ""),
            "config_vpn": device_conf.get("config_vpn", ""),
            "country": device_conf.get("country", ""),
            "group_name": device_conf.get("group_name", ""),
            "exec_time": device_conf.get("exec_time", ""),
            "apple_account": device_conf.get("apple_account", ""),
            "apple_password": device_conf.get("apple_password", ""),
            "tiktok_accounts": device_conf.get("tiktok_accounts", "[]"),
            "config_checksum": server_checksum
        }
    
    # 版本检查：如果客户端上报了版本号，则对比服务器最新版本
    if req.app_version > 0:
        latest = _get_latest_ecmain_version()
        if latest and latest.get("version", 0) > req.app_version:
            update_data = {
                "version": latest["version"],
                "build_date": latest.get("build_date", ""),
                "download_url": "/api/ecmain/download"
            }
            response["update"] = update_data
            # 兼容 ViewController.m 中的 PING 检查逻辑 (TEST-PING)
            response["version_url"] = "/api/ecmain/download"
            response["new_version_url"] = "/api/ecmain/download"
    
    # ECWDA 版本检查：对比本地 ECWDA 版本和服务器最新版本
    if req.ecwda_version >= 0:
        latest_wda = _get_latest_ecwda_version()
        if latest_wda and latest_wda.get("version", 0) > req.ecwda_version:
            response["ecwda_update"] = {
                "version": latest_wda["version"],
                "build_date": latest_wda.get("build_date", ""),
                "download_url": "/api/ecwda/download"
            }
    
    # 立即查询是否有这台机器的专属待办 JS 任务
    tasks = database.pop_pending_tasks(req.udid, limit=1)
    if tasks:
        # 下发首个任务给 ECMAIN
        t = tasks[0]
        response["task"] = {
            "id": t["id"],
            "type": t["type"],  # e.g., 'script'
            "script": t["payload"] if t["type"] == "script" else "",
            "payload": t["payload"] if t["type"] != "script" else {}
        }
    
    return response

class ReportTaskRequest(BaseModel):
    task_id: int
    status: str
    result: str = ""

@app.post("/devices/report_task")
def handle_report_task(req: ReportTaskRequest):
    database.report_task_result(req.task_id, req.status, req.result)
    return {"status": "ok"}


class CreateTaskRequest(BaseModel):
    udid: str
    task_type: str = "script"
    payload: str

@app.post("/api/tasks/create")
async def api_create_task(req: CreateTaskRequest, user: dict = Depends(get_current_user)):
    require_device_permission(user, req.udid)
    # 前端网页调用此接口向目标存入指令
    
    # 强力优先通道：如果设备当前有活跃的 WebSocket 隧道，直接下发实现毫秒级响应
    tunnel_ws = ACTIVE_TUNNELS.get(req.udid)
    if tunnel_ws:
        try:
            # 既然设备在线，就不走数据库了，直接透传。
            # 这里巧用 wakeup_task 的 body 将 payload 直接塞给 ECMAIN (iOS端会在响应此请求时顺便拉取，或者干脆我们修改 iOS 端直接执行这里带过去的 script)
            # 不过目前 iOS 端实现是收到 /api/wakeup_task 就会执行 sendHeartbeat 去拉库里任务。
            # 为了实现真正的“不入库直接执行”，我们利用刚才发现的: iOS 端如果发现 json['type'] 还没特别处理，或者干脆把它作为一个“虚拟请求”。
            # 由于当前 iOS 端的 /api/wakeup_task 只是一个纯粹的触发信号，如果没入库，它触发心跳也拉不到任务。
            # 所以，我们要么必须入库，才能让由于信号触发的心跳拉到任务；
            # 除非我们在 iOS 端的 /api/wakeup_task 拦截里，加上直接执行 body['script'] 的逻辑。
            pass
        except Exception as e:
            logging.error(f"WS 推流预备报错: {e}")
            
    # 【传统降级通道】：写入数据库等待执行 (或者是给被唤醒的设备提供弹药)
    tid = database.create_task(req.udid, req.task_type, req.payload)
    if tid:
        # 如果有活跃的 WS，我们发送一条唤醒指令，让客户端立马拉取任务！
        if tunnel_ws:
             try:
                 # 让 iOS 端随便响应一个不存在的 /wakeup 请求，触发网络活动从而顺带可能会检查任务，或者我们可以直接发送特别指令
                 # 最佳做法是前端调用任务后，再调一个 action 促使系统活跃，但最优解是修改 ECMAIN WS handler
                 # 鉴于当前限制，我们先入库，然后尝试通过 WS 发送一个特定的 command 唤醒它
                 asyncio.create_task(tunnel_ws.send_json({
                     "id": "wakeup_" + str(tid),
                     "method": "POST",
                     "url": "/api/wakeup_task", # 虽然不存在，但 ECWDAClient 会打印日志，ECMAIN也会被唤醒一点
                     "body": {}
                 }))
                 return {"status": "ok", "detail": f"任务已秒级下发并尝试唤醒设备执行, ID: {tid}"}
             except:
                 pass
        
        return {"status": "ok", "detail": f"任务已录入排队, ID: {tid}"}
    return {"status": "error", "msg": "内部持久化崩溃"}

# ==================== ECMAIN 自动更新系统 ====================

@app.get("/api/ecmain/version")
def api_ecmain_version():
    """返回服务器上最新的 ECMAIN 版本信息"""
    latest = _get_latest_ecmain_version()
    if latest:
        return {"status": "ok", **latest}
    return {"status": "error", "msg": "暂无版本文件，请先编译生成 ecmain.tar"}

@app.get("/api/ecmain/download")
def api_ecmain_download():
    """下载最新的 ecmain.tar 更新包（直接从编译输出目录读取）"""
    tar_path = os.path.join(ECMAIN_BUILD_OUTPUT, "ecmain.tar")
    if not os.path.exists(tar_path):
        raise HTTPException(status_code=404, detail="更新包不存在，请先运行 build_full.py 编译")
    return FileResponse(
        tar_path,
        media_type="application/x-tar",
        filename="ecmain.tar"
    )

# ==================== ECWDA 自动更新系统 ====================

@app.get("/api/ecwda/version")
def api_ecwda_version():
    """返回服务器上最新的 ECWDA 版本信息"""
    latest = _get_latest_ecwda_version()
    if latest:
        return {"status": "ok", **latest}
    return {"status": "error", "msg": "暂无 ECWDA 版本文件，请先编译生成 ecwda.ipa"}

@app.get("/api/ecwda/download")
def api_ecwda_download():
    """下载最新的 ecwda.ipa 更新包"""
    ipa_path = os.path.join(ECMAIN_BUILD_OUTPUT, "ecwda.ipa")
    if not os.path.exists(ipa_path):
        raise HTTPException(status_code=404, detail="ECWDA 更新包不存在，请先运行 build_wda.py 编译")
    return FileResponse(
        ipa_path,
        media_type="application/octet-stream",
        filename="ecwda.ipa"
    )

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8088, reload=True)

import re
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, UploadFile, File as FastAPIFile, Request, Depends
from fastapi.responses import FileResponse, StreamingResponse
import os
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
    """验证 Token 有效性，返回负载或 None（含诊断日志）"""
    try:
        parts = token.split('.')
        if len(parts) != 2:
            logging.warning(f"[Token] 格式错误：分段数={len(parts)}，期望 2 段")
            return None
        payload_b64, signature = parts
        expected_sig = hmac.new(_TOKEN_SECRET.encode(), payload_b64.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected_sig):
            logging.warning("[Token] 签名不匹配，可能密钥已变更或 Token 被篡改")
            return None
        payload = json.loads(base64.urlsafe_b64decode(payload_b64).decode())
        if payload.get('exp', 0) < time.time():
            # 计算过期了多久，便于排查
            expired_ago = time.time() - payload.get('exp', 0)
            logging.warning(f"[Token] 已过期 {expired_ago:.0f}s（约 {expired_ago/3600:.1f}h），用户={payload.get('username')}")
            return None
        return payload
    except Exception as e:
        logging.warning(f"[Token] 验证过程异常: {e}")
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

# [v1668.24] 权限校验内存缓存：避免高频操作时反复查 DB
_PERM_CACHE: Dict[str, tuple] = {}  # {"uid:udid": (timestamp, bool)}
_PERM_CACHE_TTL = 60  # 缓存有效期 60 秒

async def require_device_permission(user: dict, udid: str):
    """
    内部权限校验逻辑（带缓存加速）：
    1. 超级管理员 (super_admin) 拥有全局权限，直接放行。
    2. 普通管理员 (admin) 首次查 DB，结果缓存 60s。
    """
    if user.get("role") == "super_admin":
        return True
    
    cache_key = f"{user.get('id')}:{udid}"
    cached = _PERM_CACHE.get(cache_key)
    if cached and (time.time() - cached[0]) < _PERM_CACHE_TTL:
        if cached[1]:
            return True
        raise HTTPException(status_code=403, detail=f"Permission denied: You do not have access to device {udid}")
    
    assigned_devices = await asyncio.to_thread(database.get_admin_devices, user.get("id"))
    has_perm = udid in assigned_devices
    _PERM_CACHE[cache_key] = (time.time(), has_perm)
    if has_perm:
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
    wifi_ssid: str = ""
    wifi_password: str = ""
    watchdog_wda: int = 1

@app.get("/api/devices/{udid}/config")
def get_device_config_api(udid: str):
    config = database.get_device_config(udid)
    return {"status": "ok", "config": config}

@app.post("/api/devices/{udid}/config")
async def set_device_config(udid: str, req: DeviceConfigRequest, user: dict = Depends(get_current_user)):
    await require_device_permission(user, udid)
    success = database.set_device_config(
        udid, req.config_ip, req.config_vpn,
        req.device_no, req.country, req.group_name, req.exec_time,
        req.apple_account, req.apple_password, req.tiktok_accounts,
        req.wifi_ssid, req.wifi_password, req.watchdog_wda
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
    wifi_ssid: str = None
    wifi_password: str = None

@app.post("/api/devices/batch_update")
async def batch_update_devices(req: BatchDeviceConfigRequest, user: dict = Depends(get_current_user)):
    """批量更新设备的国家、分组、启动时间、VPN配置"""
    # 权限校验（简单遍历校验，无权限的直接拦截整个请求）
    for udid in req.udids:
        await require_device_permission(user, udid)
        
    success = database.batch_update_devices_config(
        req.udids, req.country, req.group_name, req.exec_time, req.config_vpn, req.wifi_ssid, req.wifi_password
    )
    if success:
        return {"status": "ok", "message": f"成功更新 {len(req.udids)} 台设备的配置"}
    raise HTTPException(status_code=500, detail="批量更新失败")

class BatchDeleteRequest(BaseModel):
    udids: List[str]

@app.delete("/api/devices/batch_delete")
async def batch_delete_devices_api(req: BatchDeleteRequest, user: dict = Depends(get_current_user)):
    """批量删除设备"""
    for udid in req.udids:
        await require_device_permission(user, udid)
        
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
async def delete_device(udid: str, user: dict = Depends(get_current_user)):
    await require_device_permission(user, udid)
    database.delete_device(udid)
    return {"status": "ok", "message": f"Device {udid} deleted."}

# [v1930 P4] 设备列表缓存：高频轮询的 fetchDevices 每秒可能被多次调用，
# 缓存合并后的设备列表 1 秒，避免重复触发 SQLite 全表扫描 + USB 设备枚举
_DEVICE_LIST_CACHE = {"data": None, "ts": 0.0}
_DEVICE_CACHE_TTL = 1.0  # 缓存有效期 1 秒

@app.get("/api/cloud/devices") # 提供给前端查询群控大盘设备列表的接口
def get_cloud_devices(request: Request):
    now = time.time()
    
    # [v1930 P4] 如果缓存仍在有效期内，跳过昂贵的合并计算
    if _DEVICE_LIST_CACHE["data"] is not None and (now - _DEVICE_LIST_CACHE["ts"]) < _DEVICE_CACHE_TTL:
        all_devices_raw = _DEVICE_LIST_CACHE["data"]
    else:
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
                # [v1930] 修复在线虚高问题：纯 USB 物理连接但没有心跳，不应判定为真正的 online，
                # 改回 offline，这样前端的"在线设备: XX台"才能精确反映真正运行 ECMAIN 的数量
                d['status'] = 'offline'
                merged[udid] = d
                
        # 检测 3 种信道的实际可用性
        active_ws_udids = set(ACTIVE_TUNNELS.keys())
        for udid, d in merged.items():
            d['can_usb'] = udid in usb_udids
            d['can_lan'] = bool(d.get('local_ip') or d.get('ip'))
            d['can_ws'] = (udid in active_ws_udids) or (d.get('source') == 'cloud') or d['can_lan']
        
        # [附加管理员信息] 批量查询设备→管理员映射
        admin_map = database.get_device_admin_map()
        for d in merged.values():
            d['admin_username'] = admin_map.get(d.get('udid'), '')
        
        all_devices_raw = list(merged.values())
        # 更新缓存
        _DEVICE_LIST_CACHE["data"] = all_devices_raw
        _DEVICE_LIST_CACHE["ts"] = now
    
    # [权限过滤] 在缓存层之后执行，不影响数据隔离
    all_devices = all_devices_raw
    try:
        user = get_current_user(request)
        if user and user.get('role') != 'super_admin':
            allowed_udids = set(database.get_admin_devices(user['id']))
            all_devices = [d for d in all_devices_raw if d.get('udid') in allowed_udids]
    except:
        pass  # Token 缺失时不过滤（兼容心跳等无 Token 调用）
    
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
    is_primary: int = 0
    password: str = ""
    email: str = ""

class CreateTikTokAccountReq(BaseModel):
    device_udid: str
    account: str
    password: str = ""
    email: str = ""
    country: str = ""
    fans_count: int = 0
    is_for_sale: int = 0
    is_window_opened: int = 0

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
        req.sale_time,
        req.password,
        req.email
    )
    if success:
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="Failed to update tiktok account or not found")

@app.post("/api/tiktok_accounts")
async def create_tiktok_account_api(req: CreateTikTokAccountReq, user: dict = Depends(get_current_user)):
    """手动创建一条 TikTok 账号记录"""
    new_id = database.create_tiktok_account(
        req.device_udid,
        req.account,
        req.password,
        req.email,
        req.country,
        req.fans_count,
        req.is_for_sale,
        req.is_window_opened
    )
    if new_id:
        return {"status": "ok", "id": new_id}
    raise HTTPException(status_code=500, detail="Failed to create tiktok account")

@app.put("/api/tiktok_accounts/{account_id}/primary")
async def set_tiktok_account_primary_api(account_id: int, user: dict = Depends(get_current_user)):
    """设置某 TikTok 账号为该设备的主号"""
    success = database.set_tiktok_account_primary(account_id)
    if success:
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="Failed to set primary account")

@app.delete("/api/tiktok_accounts/{account_id}")
async def delete_tiktok_account_api(account_id: int, user: dict = Depends(get_current_user)):
    """注意：由于前端手机列表依然存活，单独在此处删除只会影响本表的展示"""
    success = database.delete_tiktok_account(account_id)
    if success:
        return {"status": "ok"}
    raise HTTPException(status_code=400, detail="Failed to delete tiktok account")

class BatchImportTikTokReq(BaseModel):
    """批量导入 TikTok 账号请求体"""
    accounts: list  # [{ device_no, account, password, email }, ...]

@app.post("/api/tiktok_accounts/batch_import")
async def batch_import_tiktok_accounts_api(req: BatchImportTikTokReq, user: dict = Depends(get_current_user)):
    """批量导入 TikTok 账号，格式: 设备编号|账号|密码|邮箱
    已存在的账号会被覆盖，所有导入账号自动设为主号"""
    if not req.accounts:
        raise HTTPException(status_code=400, detail="账号列表不能为空")
    result = database.batch_import_tiktok_accounts(req.accounts)
    return {"status": "ok", "data": result}


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

class TaskReportRequest(BaseModel):
    udid: str
    task_name: str
    status: str       # "正在执行" | "执行完成"
    success: bool = False
    error: str = ""
    last_command: str = ""
    duration: str = ""  # 任务执行总耗时（如 "2m 36s"），旧客户端不发此字段时默认空

@app.post("/api/device/task_report")
def api_device_task_report(req: TaskReportRequest):
    """ECMAIN 在执行任务的不同阶段实时上报状态，从而摆脱原来挂载在心跳的不稳定设计"""
    payload = {
        "task_name": req.task_name,
        "status": req.status,
        "success": req.success,
        "error": req.error,
        "last_command": req.last_command,
        "time": time.strftime("%H:%M:%S"),
        "duration": req.duration
    }
    database.update_device_task_status(req.udid, json.dumps(payload, ensure_ascii=False))
    return {"message": "Success"}

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
    img_w: int = 0   # [v1760] 废弃：前端已直接下发逻辑 Points，无需图像尺寸进行缩放计算
    img_h: int = 0   # [v1760] 废弃
    text: str = ""
    connection_mode: str = "" # 可选：usb, lan, ws，指示首选控制通路
    is_normalized: bool = False # [v1760] 废弃：前端已直接下发逻辑 Points，此字段不再使用
    script_code: str = "" # 脚本下发时的原始 JS 内容
    # [v2050] OCR 区域裁剪参数：0~1 的归一化比例，减少 OCR 处理面积以提速 5~10 倍
    region_top: float = 0.0     # 区域顶部 Y 比例 (0=屏幕最顶)
    region_bottom: float = 1.0  # 区域底部 Y 比例 (1=屏幕最底)
    region_left: float = 0.0    # 区域左侧 X 比例 (0=屏幕最左)
    region_right: float = 1.0   # 区域右侧 X 比例 (1=屏幕最右)
    # [v2050] UI 元素定向查询参数：谓词表达式，用于 XCTest 精准搜索单个元素
    predicate: str = ""         # NSPredicate 格式，如 "label == '关注'"
    # [v2105] UI 树扫描与元素定点搜索的层级最大深度
    max_depth: int = 60

SESSION_CACHE = {}
SIZE_CACHE = {}

ACTIVE_TUNNELS: Dict[str, WebSocket] = {}
PENDING_TASKS: Dict[str, asyncio.Future] = {}
# [v1763] MJPEG 流帧广播：设备端通过 WS 二进制帧推送 JPEG 数据，后端广播给所有订阅者（主控+从机）
STREAM_QUEUES: Dict[str, List[asyncio.Queue]] = {}
# [v1760] MJPEG 流取消信号：切换设备时主动终止旧流，防止多个流同时轰炸 WDA /screenshot
ACTIVE_STREAM_STOPS: Dict[str, asyncio.Event] = {}
# [v1934] WS 隧道连续超时计数器：用于检测僵尸连接并主动踢掉
WS_TIMEOUT_COUNTS: Dict[str, int] = {}

class WSTunnelManager:
    async def connect(self, ws: WebSocket, device_key: str):
        # 1. 握手超时保护 (wait_for wrapped websocket.accept)
        try:
            await asyncio.wait_for(ws.accept(), timeout=5.0)
        except asyncio.TimeoutError:
            logging.error(f"[WS] Handshake timeout for {device_key}")
            raise

        # 2. 显式关闭旧连接 (Explicit closure before new connection)
        if device_key in ACTIVE_TUNNELS:
            old_ws = ACTIVE_TUNNELS[device_key]
            try:
                await old_ws.close(code=1000)
                logging.info(f"[WS] Closed existing tunnel for {device_key}")
            except:
                pass

        ACTIVE_TUNNELS[device_key] = ws
        
    def disconnect(self, device_key: str):
        if device_key in ACTIVE_TUNNELS:
            del ACTIVE_TUNNELS[device_key]

tunnel_manager = WSTunnelManager()

@app.websocket("/tunnel/ws/{device_key}")
async def ws_tunnel_endpoint(websocket: WebSocket, device_key: str):
    await tunnel_manager.connect(websocket, device_key)
    try:
        last_heartbeat = time.time()
        while True:
            # 3. 活跃心跳监测 (Active Heartbeat: 180s timeout)
            # [优化] iOS 在后台网络会被系统节流降速，放宽容忍时间至 180 秒，避免频繁断开重连
            try:
                # 阻塞等待消息，180秒无消息则触发主动 Ping
                raw = await asyncio.wait_for(websocket.receive(), timeout=180.0)
                last_heartbeat = time.time()
            except asyncio.TimeoutError:
                # 180秒无数据，发送主动 Ping 并设置 30秒 Pong 超时
                try:
                    await websocket.send_json({"type": "ping"})
                    raw = await asyncio.wait_for(websocket.receive(), timeout=30.0)
                    if raw.get("type") == "websocket.disconnect":
                        break
                    last_heartbeat = time.time()
                except asyncio.TimeoutError:
                    logging.warning(f"[WS] Pong timeout (30s) for {device_key}, forcing disconnect due to iOS sleep or net loss")
                    break

            if raw.get("type") == "websocket.disconnect":
                break

            # 处理文本帧（指令响应、pong）
            text_data = raw.get("text")
            if text_data:
                try:
                    msg = json.loads(text_data)
                    # 收到客户端发来的 ping，立即回 pong
                    if msg.get("type") == "ping":
                        await websocket.send_json({"type": "pong"})
                    # 收到我们发出的 ping 的回应 pong
                    elif msg.get("type") == "pong":
                        pass
                    elif "id" in msg:
                        reply_id = msg["id"]
                        if reply_id in PENDING_TASKS:
                            if not PENDING_TASKS[reply_id].done():
                                PENDING_TASKS[reply_id].set_result(msg)
                except Exception as e:
                    logging.error(f"WS Parse error: {e}")
            
            # [v1763] 处理二进制帧（MJPEG 流帧：8 字节时间戳 + JPEG 数据），广播给所有订阅者
            bytes_data = raw.get("bytes")
            if bytes_data and len(bytes_data) > 8:
                jpeg_data = bytes_data[8:]  # 跳过 8 字节大端时间戳头
                queues = STREAM_QUEUES.get(device_key, [])
                for q in queues:
                    # 非阻塞放入，队列满时丢弃最旧帧防止背压
                    if q.full():
                        try:
                            q.get_nowait()
                        except asyncio.QueueEmpty:
                            pass
                    try:
                        q.put_nowait(jpeg_data)
                    except asyncio.QueueFull:
                        pass
    except WebSocketDisconnect:
        tunnel_manager.disconnect(device_key)
        STREAM_QUEUES.pop(device_key, None)  # [v1683] 隧道断开时清理流队列
    except Exception as e:
        logging.error(f"WS tunnel error for {device_key}: {e}")
        tunnel_manager.disconnect(device_key)
        STREAM_QUEUES.pop(device_key, None)  # [v1683] 隧道异常时清理流队列

@app.post("/api/action_proxy")
async def api_action_proxy(req: ActionProxyRequest, user: dict = Depends(get_current_user)):
    # 构建一个挂起式异步 HTTP Over WebSocket 代理发射器
    async def _async_wda_request(method, url, json_body=None, timeout=15.0, force_http=False, fire_forget=False):
        # [v1682.8] 动态获取隧道对象，解决 initial state 为 None 时的时序竞争
        # [v1742] 增加模糊匹配回退，与 SCRIPT 处理器对齐
        _ws = ACTIVE_TUNNELS.get(req.udid)
        if not _ws:
            for tk, tw in ACTIVE_TUNNELS.items():
                if req.udid in tk or tk in req.udid:
                    _ws = tw
                    break
        
        # [v1684] 判断是否应该走 WS 隧道，加入对于 8089 的白名单
        should_use_ws = not force_http and (":10088" in url or ":10089" in url or ":8089" in url)
        
        if should_use_ws:
            if not _ws:
                # [v1930] 智能降级：先短暂等待 WS 隧道（3秒），如果仍无法建立则自动降级到 LAN HTTP 直连
                # 旧逻辑死等 15 秒后直接 503，导致用户体验极差；新逻辑大幅缩短等待并提供降级路径
                _ws_wait_max = 6  # 最多等 3 秒 (6 * 0.5s)
                for _ws_wait_i in range(_ws_wait_max):
                    await asyncio.sleep(0.5)
                    _ws = ACTIVE_TUNNELS.get(req.udid)
                    if not _ws:
                        for tk, tw in ACTIVE_TUNNELS.items():
                            if req.udid in tk or tk in req.udid:
                                _ws = tw
                                break
                    if _ws:
                        if _ws_wait_i > 0:
                            logging.info(f"[WS_WAIT] 隧道就绪 (等待了 {(_ws_wait_i+1)*0.5:.1f}s), udid={req.udid}")
                        break
                if not _ws:
                    # [v1930] WS 不可用时自动降级到 ECMAIN 8089 的 /wda_proxy 端点
                    # WDA (10088) 绑定 127.0.0.1 外部不可达，但 ECMAIN (8089) 绑定 0.0.0.0 可达
                    # ECMAIN 通过 /wda_proxy 在本机转发请求到 WDA
                    _fallback_ip = None
                    try:
                        _cloud_devs = database.get_all_cloud_devices()
                        _target = next((d for d in _cloud_devs if d.get("udid") == req.udid), None)
                        if _target:
                            _fallback_ip = _target.get("ip") or _target.get("local_ip")
                    except Exception:
                        pass
                    if _fallback_ip:
                        _proxy_url = f"http://{_fallback_ip}:8089/wda_proxy"
                        # 从完整 URL 中提取 WDA 路径部分（如 /session, /window/size, /screenshot 等）
                        import re as _re
                        _path_match = _re.search(r"http://127\.0\.0\.1:\d+(/.+)", url)
                        _wda_path = _path_match.group(1) if _path_match else "/status"
                        
                        logging.warning(f"[WS→8089] 设备 {req.udid} WS 隧道不可用，通过 ECMAIN 8089 /wda_proxy 降级: {method} {_wda_path}")
                        
                        def _sync_wda_proxy():
                            try:
                                proxy_body = {
                                    "method": method.upper(),
                                    "path": _wda_path,
                                    "body": json_body,
                                    "timeout": int(timeout * 1000)
                                }
                                resp = requests.post(_proxy_url, json=proxy_body, timeout=timeout + 5)
                                result = resp.json()
                                # /wda_proxy 返回 {"status": 200, "body": {...WDA原始响应...}}
                                return result.get("status", 502), result.get("body", {})
                            except Exception as e:
                                return 500, {"error": f"ECMAIN 8089 /wda_proxy failed: {str(e)}"}
                        return await asyncio.to_thread(_sync_wda_proxy)
                    else:
                        return 503, {"error": "云端设备 WebSocket 通道未建立或已断线，且无可用局域网 IP 降级"}
                
            task_id = f"{time.monotonic_ns()}"
            if fire_forget:
                asyncio.create_task(_ws.send_json({"id": task_id, "method": method, "url": url, "body": json_body}))
                return 200, {"status": "fire_and_forget"}
            
            loop = asyncio.get_event_loop()
            future = loop.create_future()
            PENDING_TASKS[task_id] = future
            try:
                await _ws.send_json({
                    "id": task_id,
                    "method": method,
                    "url": url,
                    "body": json_body
                })
                result = await asyncio.wait_for(future, timeout=timeout)
                # 命令成功，重置该设备的超时计数器
                WS_TIMEOUT_COUNTS.pop(req.udid, None)
                return result.get("status", 500), result.get("body", {})
            except asyncio.TimeoutError:
                # [v1934] 僵尸隧道自动清理：WS 指令超时后主动踢掉死管道
                _timeout_key = req.udid
                WS_TIMEOUT_COUNTS[_timeout_key] = WS_TIMEOUT_COUNTS.get(_timeout_key, 0) + 1
                _tc = WS_TIMEOUT_COUNTS[_timeout_key]
                if _tc >= 2:
                    # 连续 2 次超时，判定为僵尸连接，主动断开
                    logging.warning(f"[WS] 🔪 设备 {_timeout_key} 连续 {_tc} 次 WS 超时，判定为僵尸隧道，主动断开")
                    try:
                        await _ws.close(code=1000)
                    except Exception:
                        pass
                    tunnel_manager.disconnect(_timeout_key)
                    STREAM_QUEUES.pop(_timeout_key, None)
                    WS_TIMEOUT_COUNTS.pop(_timeout_key, None)
                else:
                    logging.warning(f"[WS] ⚠️ 设备 {_timeout_key} WS 指令超时 ({_tc}/2)，下次超时将主动断开僵尸隧道")
                return 504, {"error": "Gateway Timeout over WebSocket"}
            except Exception as e:
                return 500, {"error": str(e)}
            finally:
                PENDING_TASKS.pop(task_id, None)
        else:
            # 降级：走局域网物理 HTTP 请求（通过线程池避免阻塞）
            def _sync_req():
                try:
                    if method.upper() == "GET":
                        resp = requests.get(url, timeout=timeout)
                    else:
                        resp = requests.post(url, json=json_body, timeout=timeout)
                    return resp.status_code, resp.json()
                except Exception as e:
                    return 500, {"error": str(e)}
            return await asyncio.to_thread(_sync_req)

    try:
        # [v1682.11] 统合路由准备
        if not req.udid and not req.ecmain_url:
            return {"status": "error", "msg": "Neither UDID nor WLAN IP provided"}
            
        wlan_ip_match = re.search(r"http://([0-9\.]+)", req.ecmain_url)
        wlan_ip = wlan_ip_match.group(1) if wlan_ip_match else None
        dev = device_manager.devices.get(req.udid)
        
        # 路由策略定义
        wda_url = ""
        force_http = False
        cache_key = req.udid
        
        if req.connection_mode == "usb":
            if dev:
                wda_url = f"http://127.0.0.1:{dev.wda_port}"
                force_http = True
            else:
                return {"status": "error", "msg": "No valid route: USB path selected but device is missing from local DeviceManager."}
        elif req.connection_mode == "ws":
            wda_url = "http://127.0.0.1:10088"
            force_http = False
        elif req.connection_mode == "lan":
            if wlan_ip:
                wda_url = f"http://{wlan_ip}:10088"
                cache_key = wlan_ip
            else:
                return {"status": "error", "msg": "No valid route: LAN path selected but no WLAN IP provided."}
        else:
            # Auto探测（按优劣优先级：WLAN >= USB > WS）
            if wlan_ip:
                wda_url = f"http://{wlan_ip}:10088"
                cache_key = wlan_ip
            elif dev:
                wda_url = f"http://127.0.0.1:{dev.wda_port}"
                force_http = True
            else:
                wda_url = "http://127.0.0.1:10088"
                force_http = False

        # [v1682.5] 指令分支：主动查询窗口尺寸
        if req.action_type == "WDA_WINDOW_SIZE":
            status, sz_resp = await _async_wda_request("GET", f"{wda_url}/window/size", timeout=3.0, force_http=force_http)
            if status == 200 and isinstance(sz_resp, dict):
                sz_val = sz_resp.get("value", {})
                if "width" in sz_val:
                    SIZE_CACHE[cache_key] = sz_val
                    return {"status": "ok", "window_size": sz_val}
            return {"status": "error", "msg": f"WDA window size failed ({status})", "raw": sz_resp}

        # [v1682.31] 指令分支：获取干净的 base64 截图（用于前端 tainted canvas 裁切）
        if req.action_type == "WDA_SCREENSHOT":
            status, sc_resp = await _async_wda_request("GET", f"{wda_url}/screenshot", timeout=5.0, force_http=force_http)
            if status == 200 and isinstance(sc_resp, dict):
                b64_val = sc_resp.get("value", "")
                if b64_val:
                    return {"status": "ok", "screenshot_b64": b64_val}
            return {"status": "error", "msg": f"WDA screenshot failed ({status})"}

        # [v2104] 获取真实 UI 树 —— 完全对齐 Appium XCUITest Driver 的调用链
        # 参考: https://github.com/appium/appium-xcuitest-driver/blob/master/lib/commands/source.ts
        # 核心差异点:
        #   1. Session 创建时 capabilities 必须带 shouldWaitForQuiescence: false
        #   2. Settings 必须在 source 调用前推送完毕
        #   3. /source 必须带 scope=AppiumAUT（限定只扫描当前活跃 App，不扫全局系统）
        if req.action_type == "WDA_SOURCE":
            custom_depth = getattr(req, "max_depth", 60) or 60
            
            # ═══════════════════════════════════════════════════════════════
            # 视频播放页自适应扫描策略（v3）：
            #
            # 三阶段降级：
            # 1️⃣ 用户请求深度 + 动态超时（深度越深允许时间越长）
            # 2️⃣ /wda/accessibleSource（只返回可交互元素，跳过视频渲染层）
            # 3️⃣ 最浅深度 5 兜底
            #
            # 超时公式：snapTimeout = max(3, depth * 0.4)
            #           httpTimeout = snapTimeout + 5
            # 例：depth=25 → snap=10s, http=15s（暂停视频后足够扫完）
            #     depth=60 → snap=24s, http=29s
            #     depth=10 → snap=4s, http=9s
            # ═══════════════════════════════════════════════════════════════
            
            # 动态计算超时（深度越大越宽容，但有上限）
            snap_t = min(25, max(3, int(custom_depth * 0.4)))
            http_t = snap_t + 5
            
            # 三阶段尝试（v1985 修复：彻底移除 accessibleSource）
            # ⚠️ 关键发现：accessibleSource 内部调用 Apple accessibilitySnapshot API
            # 该 API 隐式触发截图 → "Cannot take a screenshot within 8000 ms timeout"
            # 8000ms 是 iOS 系统级硬编码超时，不受 customSnapshotTimeout 控制
            # 唯一安全的组合：source?format=json + includeHittableInPageSource=NO
            fast_snap_t = min(8, max(3, int(15 * 0.4)))
            fast_http_t = fast_snap_t + 5
            
            if custom_depth == 60:
                attempts = [
                    # 第1阶段：默认深搜时，先用15保护性抢刷
                    {"depth": 15, "snap_timeout": fast_snap_t, "http_timeout": float(fast_http_t),
                     "endpoint": "source?format=json", "label": "快速扫描(depth=15)"},
                    # 第2阶段：如果15不足以捕获，再用60完整扫描
                    {"depth": custom_depth, "snap_timeout": snap_t, "http_timeout": float(http_t),
                     "endpoint": "source?format=json", "label": "完整扫描(depth=60)"},
                    # 第3阶段：5层兜底
                    {"depth": 5, "snap_timeout": 3, "http_timeout": 8.0,
                     "endpoint": "source?format=json", "label": "浅层兜底扫描"},
                ]
            else:
                attempts = [
                    # 第1阶段：用户明确指定了特别深度，必须无条件优先遵从！
                    {"depth": custom_depth, "snap_timeout": snap_t, "http_timeout": float(http_t),
                     "endpoint": "source?format=json", "label": f"专定扫描(depth={custom_depth})"},
                    # 第2阶段：如果挂了再尝试15
                    {"depth": 15, "snap_timeout": fast_snap_t, "http_timeout": float(fast_http_t),
                     "endpoint": "source?format=json", "label": "兜底扫描(depth=15)"},
                    # 第3阶段：5层兜底
                    {"depth": 5, "snap_timeout": 3, "http_timeout": 8.0,
                     "endpoint": "source?format=json", "label": "极浅兜底扫描"},
                ]
            
            for attempt_idx, attempt_cfg in enumerate(attempts):
                try_depth = attempt_cfg["depth"]
                snap_timeout = attempt_cfg["snap_timeout"]
                http_timeout = attempt_cfg["http_timeout"]
                endpoint = attempt_cfg["endpoint"]
                label = attempt_cfg["label"]
                
                # ── Step 1: 获取或创建 Session ──
                sid = SESSION_CACHE.get(cache_key)
                if sid:
                    v_status, _ = await _async_wda_request("GET", f"{wda_url}/session/{sid}", timeout=3.0, force_http=force_http)
                    if v_status != 200:
                        sid = None
                
                if not sid:
                    create_caps = {
                        "capabilities": {
                            "alwaysMatch": {
                                "shouldWaitForQuiescence": False
                            }
                        }
                    }
                    create_st, data = await _async_wda_request(
                        "POST", f"{wda_url}/session", json_body=create_caps, timeout=8.0, force_http=force_http
                    )
                    if create_st == 200 and isinstance(data, dict):
                        sid = data.get("sessionId") or data.get("value", {}).get("sessionId")
                        SESSION_CACHE[cache_key] = sid
                
                if not sid:
                    if attempt_idx < len(attempts) - 1:
                        await asyncio.sleep(3)
                        continue
                    return {"status": "error", "msg": "WDA 无响应。建议：1. 退出视频播放页 2. 重启 WDA"}
                
                # ── Step 2: 推送设置 ──
                settings_ok, _ = await _async_wda_request(
                    "POST", f"{wda_url}/session/{sid}/appium/settings",
                    json_body={
                        "settings": {
                            "snapshotMaxDepth": try_depth,
                            "customSnapshotTimeout": snap_timeout,
                            "includeHittableInPageSource": False,
                            "includeNativeFrameInPageSource": False,
                            "waitForQuiescence": False,
                            "animationCoolOffTimeout": 0,
                            "waitForIdleTimeout": 0,
                            "useFirstMatch": True,
                            "shouldUseCompactResponses": True,
                            "elementResponseAttributes": "type,name,label,value,rect"
                        }
                    },
                    timeout=3.0, force_http=force_http
                )
                
                if settings_ok != 200:
                    SESSION_CACHE.pop(cache_key, None)
                    if attempt_idx < len(attempts) - 1:
                        await asyncio.sleep(3)
                        continue
                    return {"status": "error", "msg": "WDA 无响应（无法推送设置）。建议退出视频播放页或重启 WDA"}
                
                # ── Step 3: 获取 UI 树 ──
                status, sc_resp = await _async_wda_request(
                    "GET",
                    f"{wda_url}/session/{sid}/{endpoint}",
                    timeout=http_timeout,
                    force_http=force_http
                )
                
                if status == 200:
                    if isinstance(sc_resp, dict):
                        val = sc_resp.get("value", sc_resp)
                        result = {"status": "ok", "source": val}
                        if attempt_idx > 0:
                            result["degraded"] = True
                            result["actual_depth"] = try_depth
                            result["msg"] = f"⚠️ [{label}] 成功（第 {attempt_idx+1} 阶段降级）"
                        return result
                    elif isinstance(sc_resp, str):
                        # accessibleSource 返回 XML 字符串
                        return {"status": "ok", "source": sc_resp, 
                                "degraded": attempt_idx > 0,
                                "msg": f"⚠️ [{label}] 返回 XML 格式" if attempt_idx > 0 else None}
                
                # ── 失败：销毁 Session + 等待恢复 ──
                if sid:
                    await _async_wda_request("DELETE", f"{wda_url}/session/{sid}", timeout=2.0, force_http=force_http)
                SESSION_CACHE.pop(cache_key, None)
                
                if attempt_idx < len(attempts) - 1:
                    await asyncio.sleep(3)
            
            return {
                "status": "error", 
                "msg": "⚠️ 三阶段扫描均失败。当前页面 accessibility 服务完全不可用。\n\n建议：\n1. 暂停视频 + 关闭弹幕后重试\n2. 滑到评论区（静态页面）再扫描\n3. 如 WDA 无响应，需重启 WDA"
            }


        # [v1682.13] 指令分支：Ping
        if req.action_type == "ping":
            status, body = await _async_wda_request("GET", f"{wda_url}/ping", timeout=3.0, force_http=force_http)
            return {"status": "ok", "detail": "Ping success"} if status == 200 else {"status": "error", "raw": body}
            
        # [v1668.27] 高频动作极速路径：跳过 Session 校验、Scale 计算，直接发射
        # [v1742] 将 home/lock/volumeUp/volumeDown 也纳入无 Session 快捷通道，确保群控从机无需预建 Session
        _no_session_actions = {"home", "lock", "volumeUp", "volumeDown"}
        if req.action_type in _no_session_actions:
            # [v1742.1] WS 模式优先走 ECMAIN 8089 脚本通道
            # 原因：锁屏时 WDA (10088) 可能被 iOS 挂起无法响应，但 ECMAIN 拥有 SpringBoard 直接唤醒能力
            _action_script_map = {
                "home": "wda.home();",
                "lock": "wda.lock();",
                "volumeUp": "wda.volumeUp();",
                "volumeDown": "wda.volumeDown();",
            }
            
            # 查找可用的 WS 隧道（含模糊匹配）
            _btn_ws = ACTIVE_TUNNELS.get(req.udid)
            if not _btn_ws:
                for tk, tw in ACTIVE_TUNNELS.items():
                    if req.udid in tk or tk in req.udid:
                        _btn_ws = tw
                        break
            
            if _btn_ws and not force_http:
                # WS 通道可用：通过 ECMAIN 8089 脚本引擎执行（能穿透锁屏）
                try:
                    import uuid
                    task_id = "btn_" + str(uuid.uuid4())[:8]
                    loop = asyncio.get_event_loop()
                    future = loop.create_future()
                    PENDING_TASKS[task_id] = future
                    await _btn_ws.send_json({
                        "id": task_id,
                        "method": "POST",
                        "url": "http://127.0.0.1:8089/task",
                        "body": {"type": "SCRIPT", "payload": _action_script_map[req.action_type]}
                    })
                    try:
                        result = await asyncio.wait_for(future, timeout=5.0)
                        return result.get("body", {"status": "ok", "detail": f"{req.action_type} via ECMAIN"})
                    except asyncio.TimeoutError:
                        logging.warning(f"[BTN_WS] {req.action_type} 通过 ECMAIN 超时 ({req.udid})，降级走 WDA")
                    finally:
                        PENDING_TASKS.pop(task_id, None)
                except Exception as e:
                    logging.warning(f"[BTN_WS] ECMAIN 脚本通道异常: {e}，降级走 WDA")
            
            # 降级 / 非 WS 模式：直连 WDA（USB/LAN 物理连接下 WDA 通常可用）
            if req.action_type == "home":
                status, res = await _async_wda_request("POST", f"{wda_url}/wda/homescreen", timeout=3.0, force_http=force_http)
                return {"status": "ok", "detail": "Homescreen triggered"}
            elif req.action_type == "lock":
                status, res = await _async_wda_request("POST", f"{wda_url}/wda/lock", timeout=3.0, force_http=force_http)
                return {"status": "ok", "detail": "Screen locked"}
            elif req.action_type == "volumeUp":
                status, res = await _async_wda_request("POST", f"{wda_url}/wda/pressButton", json_body={"name": "volumeUp"}, timeout=3.0, force_http=force_http)
                return {"status": "ok", "detail": "Volume up pressed"}
            elif req.action_type == "volumeDown":
                status, res = await _async_wda_request("POST", f"{wda_url}/wda/pressButton", json_body={"name": "volumeDown"}, timeout=3.0, force_http=force_http)
                return {"status": "ok", "detail": "Volume down pressed"}

        _fast_actions = {"click", "longPress", "swipe"}
        sid = SESSION_CACHE.get(cache_key)
        
        if req.action_type in _fast_actions and sid:
            # [v1760] 前端已直接下发逻辑 Points，无需坐标转换，直接透传给 WDA
            wda_x, wda_y = req.x, req.y
            wda_x1, wda_y1 = req.x1, req.y1
            wda_x2, wda_y2 = req.x2, req.y2
            sz_val = SIZE_CACHE.get(cache_key)  # 仅用于响应前端更新 deviceSizeMap
            
            logging.info(f"[FAST] {req.action_type} ({wda_x},{wda_y}) mode={req.connection_mode}")
            
            if req.action_type == "click":
                asyncio.create_task(_async_wda_request("POST", f"{wda_url}/wda/tapByCoord", json_body={"x": wda_x, "y": wda_y}, timeout=2.0, force_http=force_http, fire_forget=True))
                return {"status": "ok", "detail": f"Tap at ({wda_x}, {wda_y})", "window_size": sz_val}
            elif req.action_type == "longPress":
                asyncio.create_task(_async_wda_request("POST", f"{wda_url}/wda/longPress", json_body={"x": wda_x, "y": wda_y, "duration": 1.0}, timeout=2.0, force_http=force_http, fire_forget=True))
                return {"status": "ok", "detail": f"LongPress at ({wda_x}, {wda_y})", "window_size": sz_val}
            elif req.action_type == "swipe":
                asyncio.create_task(_async_wda_request("POST", f"{wda_url}/wda/swipeByCoord", json_body={"fromX": wda_x1, "fromY": wda_y1, "toX": wda_x2, "toY": wda_y2, "duration": 0.5}, timeout=2.0, force_http=force_http, fire_forget=True))
                return {"status": "ok", "detail": f"Swipe from ({wda_x1},{wda_y1}) to ({wda_x2},{wda_y2})", "window_size": sz_val}
        
        # 非极速路径：需要校验/创建 Session
        if sid and req.action_type not in _fast_actions:
            status, _ = await _async_wda_request("GET", f"{wda_url}/session/{sid}", timeout=3.0, force_http=force_http)
            if status != 200:
                sid = None
            
        if not sid:
            # [v1760] WDA 主队列可能被 MJPEG 截屏阻塞，增大超时到 10s 并添加重试
            _session_attempts = 0
            while _session_attempts < 3 and not sid:
                _session_attempts += 1
                # [v2104] 对齐 Appium：Session 创建时 capabilities 直接传入 shouldWaitForQuiescence=false
                status, data = await _async_wda_request("POST", f"{wda_url}/session", json_body={
                    "capabilities": {
                        "alwaysMatch": {
                            "shouldWaitForQuiescence": False
                        }
                    }
                }, timeout=10.0, force_http=force_http)
                if status == 200 and isinstance(data, dict):
                    sid = data.get("sessionId") or data.get("value", {}).get("sessionId")
                    SESSION_CACHE[cache_key] = sid
                    
                    # [v2101] 在新建立的 Session 上应用 Appium 高速设置，防止 XCTest 等待动画/深层递归卡死
                    if sid:
                        try:
                            # 通过 fire & forget 方式提速，不需要等待配置回调
                            asyncio.create_task(_async_wda_request(
                                "POST", f"{wda_url}/session/{sid}/appium/settings",
                                json_body={
                                    "settings": {
                                        # "waitForQuiescence": false → 让 XCTest 不要死等屏幕动画停止（关键防死锁！）
                                        "waitForQuiescence": False,
                                        # "snapshotMaxDepth": 10 → 控制递归拍快照的最大层级，防卡死
                                        "snapshotMaxDepth": 10,
                                        # "includeAttributes": 仅返回核心属性不拿乱七八糟的 private 属性
                                        "includeAttributes": "name,type,rect"
                                    }
                                },
                                timeout=3.0, force_http=force_http
                            ))
                        except Exception as e:
                            pass
                            
                elif _session_attempts < 3:
                    logging.warning(f"[SESSION] 第{_session_attempts}次创建失败 (status={status})，1秒后重试...")
                    await asyncio.sleep(1.0)
                
        if not sid:
            # 自愈：如果是有线连接（USB），触发端口重置和隧道重建
            is_rebuilding = False
            if dev and req.connection_mode == "usb":
                loop = asyncio.get_event_loop()
                loop.run_in_executor(
                    None, device_manager.rebuild_device_tunnels, req.udid
                )
                is_rebuilding = True
            
            err_detail = data.get("error", "") if isinstance(data, dict) else str(data)
            rebuild_msg = "（已触发 USB 隧道自愈重建，请等待 15 秒后重试）" if is_rebuilding else f"（{err_detail or '请检查设备连通性'}）"
            return {"status": "error", "msg": f"Failed to connect session at {wda_url} {rebuild_msg}"}
            
        # [v1760] 前端已直接下发逻辑 Points，无需任何坐标转换
        wda_x, wda_y = req.x, req.y
        wda_x1, wda_y1 = req.x1, req.y1
        wda_x2, wda_y2 = req.x2, req.y2
        sz_val = SIZE_CACHE.get(cache_key)  # 仅用于响应前端更新 deviceSizeMap

        async def _safe_wda_post(target, **kwargs):
            status, body = await _async_wda_request("POST", target, json_body=kwargs.get("json"), timeout=kwargs.get("timeout", 10.0), force_http=force_http)
            if status == 200:
                return body
            return {"raw_status": status, "raw_text": body}

        # 非高频动作走普通路径（等待返回）
        if req.action_type == "click":
            asyncio.create_task(_async_wda_request("POST", f"{wda_url}/wda/tapByCoord", json_body={"x": wda_x, "y": wda_y}, timeout=2.0, force_http=force_http, fire_forget=True))
            return {"status": "ok", "detail": f"Tap at ({wda_x}, {wda_y})", "window_size": sz_val}
            
        elif req.action_type == "longPress":
            asyncio.create_task(_async_wda_request("POST", f"{wda_url}/wda/longPress", json_body={"x": wda_x, "y": wda_y, "duration": 1.0}, timeout=2.0, force_http=force_http, fire_forget=True))
            return {"status": "ok", "detail": f"LongPress at ({wda_x}, {wda_y})", "window_size": sz_val}
            
        elif req.action_type == "swipe":
            asyncio.create_task(_async_wda_request("POST", f"{wda_url}/wda/swipeByCoord", json_body={"fromX": wda_x1, "fromY": wda_y1, "toX": wda_x2, "toY": wda_y2, "duration": 0.5}, timeout=2.0, force_http=force_http, fire_forget=True))
            return {"status": "ok", "detail": f"Swipe from ({wda_x1},{wda_y1}) to ({wda_x2},{wda_y2})", "window_size": sz_val}
            

        # [v1742] home/lock/volumeUp/volumeDown 已提升至无 Session 快捷通道处理（见上方 _no_session_actions）
        # 以下分支仅在极端情况下作为兜底（理论上不会执行到这里）
        elif req.action_type in ("home", "lock", "volumeUp", "volumeDown"):
             # 兜底：如果从快捷通道漏掉，使用带 Session 的路径重试
             if req.action_type == "home":
                 status, res = await _async_wda_request("POST", f"{wda_url}/wda/homescreen", timeout=3.0, force_http=force_http)
                 return {"status": "ok", "detail": "Homescreen triggered"}
             elif req.action_type == "lock":
                 status, res = await _async_wda_request("POST", f"{wda_url}/wda/lock", timeout=3.0, force_http=force_http)
                 return {"status": "ok", "detail": "Screen locked"}
             elif req.action_type == "volumeUp":
                 status, res = await _async_wda_request("POST", f"{wda_url}/wda/pressButton", json_body={"name": "volumeUp"}, timeout=3.0, force_http=force_http)
                 return {"status": "ok", "detail": "Volume up pressed"}
             elif req.action_type == "volumeDown":
                 status, res = await _async_wda_request("POST", f"{wda_url}/wda/pressButton", json_body={"name": "volumeDown"}, timeout=3.0, force_http=force_http)
                 return {"status": "ok", "detail": "Volume down pressed"}
             
        elif req.action_type == "launch":
             resp = await _safe_wda_post(f"{wda_url}/session/{sid}/wda/apps/launch", json={"bundleId": req.text}, timeout=10.0)
             return {"status": "ok", "detail": resp}
             
        elif req.action_type == "terminate":
             resp = await _safe_wda_post(f"{wda_url}/session/{sid}/wda/apps/terminate", json={"bundleId": req.text}, timeout=10.0)
             return {"status": "ok", "detail": resp}
             
        elif req.action_type == "INPUT":
             # [v1742] 增加原生文本下发支持：直接调用 WDA /keys 接口
             resp = await _safe_wda_post(f"{wda_url}/session/{sid}/keys", json={"value": list(req.text)}, timeout=5.0)
             return {"status": "ok", "detail": resp}
             
        elif req.action_type == "ocr":
             # [v2050] OCR 区域裁剪：将归一化比例参数透传给 WDA，iOS 端裁剪后再做 OCR 可提速 5~10 倍
             ocr_body = {}
             _has_region = (req.region_top > 0 or req.region_bottom < 1 or req.region_left > 0 or req.region_right < 1)
             if _has_region:
                 ocr_body["region"] = {
                     "top": req.region_top, "bottom": req.region_bottom,
                     "left": req.region_left, "right": req.region_right
                 }
             resp = await _safe_wda_post(f"{wda_url}/wda/ocr", json=ocr_body, timeout=15.0)
             return {"status": "ok", "detail": resp}
              
        elif req.action_type == "findText":
             # [v2050] findText 增强：支持区域裁剪参数透传
             ft_body = {"text": req.text}
             _has_region = (req.region_top > 0 or req.region_bottom < 1 or req.region_left > 0 or req.region_right < 1)
             if _has_region:
                 ft_body["region"] = {
                     "top": req.region_top, "bottom": req.region_bottom,
                     "left": req.region_left, "right": req.region_right
                 }
             resp = await _safe_wda_post(f"{wda_url}/wda/findText", json=ft_body, timeout=15.0)
             return {"status": "ok", "detail": resp}

        elif req.action_type == "findElement":
             # [v2050] UI 元素定向查询：支持两种策略
             # 1. class chain 路径查询（以 **/ 开头）：直接定位树分支，200~500ms
             # 2. predicate 谓词查询：全局搜索匹配，1~3s
             if not req.predicate:
                 return {"status": "error", "msg": "findElement 需要 predicate 参数"}
             # 自动检测查询策略
             _using = "class chain" if req.predicate.strip().startswith("**/") else "predicate string"
             fe_body = {"using": _using, "value": req.predicate}
             resp = await _safe_wda_post(f"{wda_url}/session/{sid}/elements", json=fe_body, timeout=8.0)
             if isinstance(resp, dict):
                 elements = resp.get("value", [])
                 if elements and len(elements) > 0:
                     el_id = elements[0].get("ELEMENT", "")
                     if el_id:
                         rect_status, rect_resp = await _async_wda_request(
                             "GET", f"{wda_url}/session/{sid}/element/{el_id}/rect",
                             timeout=5.0, force_http=force_http
                         )
                         if rect_status == 200 and isinstance(rect_resp, dict):
                             rv = rect_resp.get("value", {})
                             return {"status": "ok", "detail": {
                                 "found": True,
                                 "x": rv.get("x", 0) + rv.get("width", 0) / 2,
                                 "y": rv.get("y", 0) + rv.get("height", 0) / 2,
                                 "width": rv.get("width", 0),
                                 "height": rv.get("height", 0),
                                 "element_id": el_id
                             }}
             return {"status": "ok", "detail": {"found": False}}

        elif req.action_type == "tapElement":
             # [v2050] 查找 UI 元素并直接点击（一步到位），同样支持 class chain / predicate 双策略
             if not req.predicate:
                 return {"status": "error", "msg": "tapElement 需要 predicate 参数"}
             _using = "class chain" if req.predicate.strip().startswith("**/") else "predicate string"
             fe_body = {"using": _using, "value": req.predicate}
             resp = await _safe_wda_post(f"{wda_url}/session/{sid}/elements", json=fe_body, timeout=8.0)
             if isinstance(resp, dict):
                 elements = resp.get("value", [])
                 if elements and len(elements) > 0:
                     el_id = elements[0].get("ELEMENT", "")
                     if el_id:
                         click_status, click_resp = await _async_wda_request(
                             "POST", f"{wda_url}/session/{sid}/element/{el_id}/click",
                             json_body={}, timeout=5.0, force_http=force_http
                         )
                         return {"status": "ok", "detail": {"found": True, "clicked": click_status == 200}}
             return {"status": "ok", "detail": {"found": False, "clicked": False}}
              
        elif req.action_type == "probe_size":
             # [v1769] 增强 probe_size 鲁棒性：超时从 3s 提升到 8s，支持单次重试
             # 原因：断开再重连时 WDA 主队列可能仍被残留 MJPEG 截图线程阻塞
             for _probe_attempt in range(2):
                 status, sz_resp = await _async_wda_request("GET", f"{wda_url}/window/size", timeout=8.0, force_http=force_http)
                 if status == 200 and isinstance(sz_resp, dict):
                     sz_val = sz_resp.get("value", {})
                     if "width" in sz_val:
                         SIZE_CACHE[cache_key] = sz_val
                         return {"status": "ok", "window_size": sz_val}
                 if _probe_attempt == 0:
                     logging.warning(f"[PROBE] 第1次 probe_size 失败 (status={status})，1s 后重试...")
                     await asyncio.sleep(1.0)
             return {"status": "error", "msg": "Probe size failed", "raw": sz_resp}
             
        elif req.action_type == "STOP_ALL_STREAMS":
             old_stop = ACTIVE_STREAM_STOPS.get(req.udid)
             if old_stop:
                 old_stop.set()
                 logging.info(f"[STREAM] 收到前端主动断开指令，释放 {req.udid} 的残留截图队列")
             # [v1773] 断开时主动向设备发送 STOP_STREAM，直接切断 ECMAIN 的原生推源
             _stop_ws = ACTIVE_TUNNELS.get(req.udid)
             if not _stop_ws:
                 for tk, tw in ACTIVE_TUNNELS.items():
                     if req.udid in tk or tk in req.udid:
                         _stop_ws = tw
                         break
             if _stop_ws:
                 try:
                     asyncio.create_task(_stop_ws.send_json({
                         "id": f"stream_stop_force_{time.monotonic_ns()}",
                         "method": "STOP_STREAM",
                         "url": "",
                         "body": None
                     }))
                     logging.info(f"[STREAM] 发送强制 STOP_STREAM 斩首令到设备 {req.udid}")
                 except Exception as e:
                     logging.warning(f"[STREAM] 强制发送 STOP_STREAM 失败: {e}")
             return {"status": "ok"}

        elif req.action_type == "SCRIPT":
             # [v1736] 脚本分发同步化路由：实现从手机端到前端的 logs/return_value 透明传回
             _script_ws = ACTIVE_TUNNELS.get(req.udid)
             
             if not _script_ws:
                 for tk, tw in ACTIVE_TUNNELS.items():
                     if req.udid in tk or tk in req.udid:
                         _script_ws = tw
                         logging.info(f"[SCRIPT] 模糊匹配隧道成功: req.udid={req.udid} → tunnel_key={tk}")
                         break
             
             if _script_ws:
                 try:
                     import uuid
                     task_id = "proxy_script_" + str(uuid.uuid4())[:8]
                     loop = asyncio.get_event_loop()
                     future = loop.create_future()
                     PENDING_TASKS[task_id] = future
                     
                     await _script_ws.send_json({
                         "id": task_id, 
                         "method": "POST", 
                         "url": "http://127.0.0.1:8089/task", 
                         "body": {"type": "SCRIPT", "payload": req.script_code}
                     })
                     
                     # 同步透传等待（120秒超时）
                     try:
                         result = await asyncio.wait_for(future, timeout=120.0)
                         return result.get("body", {"status": "success", "detail": "WS Dispatch OK"})
                     except asyncio.TimeoutError:
                         return {"status": "error", "msg": "Script execution timeout over WS tunnel"}
                     finally:
                         PENDING_TASKS.pop(task_id, None)
                 except Exception as ws_err:
                     logging.error(f"[SCRIPT] WS 隧道发送失败 ({req.udid}): {ws_err}")
             
             # USB 通道：透传原始响应
             if dev:
                 try:
                     script_port = getattr(dev, 'script_port', 8089)
                     status, resp = await _async_wda_request("POST", f"http://127.0.0.1:{script_port}/task", json_body={"type":"SCRIPT", "payload": req.script_code}, timeout=60.0, force_http=True)
                     if status == 200:
                         return resp # 直接透传 iOS 返回的 {"status": "ok", "logs": [...], ...}
                 except Exception as usb_err:
                     logging.error(f"[SCRIPT] USB 通道异常: {usb_err}")
             
             # LAN 通道：透传原始响应
             if wlan_ip:
                 try:
                     status, resp = await _async_wda_request("POST", f"http://{wlan_ip}:8089/task", json_body={"type":"SCRIPT", "payload": req.script_code}, timeout=60.0, force_http=True)
                     if status == 200:
                         return resp
                 except Exception as lan_err:
                     logging.error(f"[SCRIPT] LAN 通道异常: {lan_err}")
             
             # 三路全挂：输出详细诊断信息
             logging.error(f"[SCRIPT] 三通道全部失败! udid={req.udid}, tunnels={list(ACTIVE_TUNNELS.keys())}, dev={'exists' if dev else 'None'}, wlan_ip={wlan_ip}")
             return {"status": "error", "msg": f"No valid channel (WS/USB/LAN) to deliver script payload. Active tunnels: {list(ACTIVE_TUNNELS.keys())}"}
             
        return {"status": "error", "msg": f"Unsupported action {req.action_type}"}
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/run")
async def api_run_script(req: RunTaskRequest, user: dict = Depends(get_current_user)):
    await require_device_permission(user, req.udid)
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
            
            # 修正：通过隧道向手机本地的 EC 核心服务发送指令
            await tunnel_ws.send_json({
                "id": task_id,
                "method": "POST",
                "url": "http://127.0.0.1:8089/task",
                "body": {"type": "SCRIPT", "payload": js_code}
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
from fastapi import WebSocket, WebSocketDisconnect

@app.websocket("/api/ws_stream/{udid}")
async def ws_screen_stream(websocket: WebSocket, udid: str, mode: str = 'ws', slave: str = '1', quality: str = 'low'):
    """[v1930] 方案B从机推流：消费 ECMAIN 主动推送的原生 JPEG 帧，转 base64 推送给前端 WebSocket
    
    优化点：
    - 心跳保活：响应前端 __ping__ 消息，防止中间代理超时断连
    - 发送保护：send_text 失败时优雅退出，不会崩溃整个流
    - 隧道重寻：隧道断开后会自动重新寻找，而不是直接放弃
    - 宽松超时：60s 无帧才终止（原来 30s 太激进）
    - 客户端断线检测：并发监听客户端消息，及时感知断开
    """
    await websocket.accept()
    
    logging.info(f"[WS STREAM] 方案B 从机推流启动: udid={udid}")
    frame_count = 0
    stream_started = False
    client_alive = True
    queue = asyncio.Queue(maxsize=3)
    
    # [v1930] 并发监听任务：持续接收客户端消息（心跳/断开），与帧推送并行
    async def _client_listener():
        nonlocal client_alive
        try:
            while client_alive:
                try:
                    msg = await asyncio.wait_for(websocket.receive(), timeout=60.0)
                    if msg.get("type") == "websocket.disconnect":
                        client_alive = False
                        break
                    # 响应前端心跳保活
                    text = msg.get("text", "")
                    if text == "__ping__":
                        try:
                            await websocket.send_text("__pong__")
                        except:
                            client_alive = False
                            break
                except asyncio.TimeoutError:
                    # 60s 没收到客户端任何消息（包括心跳），视为断线
                    logging.info(f"[WS STREAM] 客户端 60s 无心跳，判定断线 ({udid})")
                    client_alive = False
                    break
        except (WebSocketDisconnect, RuntimeError):
            client_alive = False
        except Exception as e:
            if "close message" not in str(e) and "WebSocket is closed" not in str(e):
                logging.warning(f"[WS STREAM] 客户端监听异常: {e}")
            client_alive = False

    listener_task = asyncio.create_task(_client_listener())
    
    try:
        # 注册为该设备的流订阅者
        if udid not in STREAM_QUEUES:
            STREAM_QUEUES[udid] = []
        STREAM_QUEUES[udid].append(queue)
        
        # [v1930] 寻找隧道（支持重试寻找）
        def _find_tunnel():
            """在 ACTIVE_TUNNELS 中精确或模糊匹配 udid 对应的隧道"""
            ws = ACTIVE_TUNNELS.get(udid)
            if ws:
                return ws
            for tk, tw in ACTIVE_TUNNELS.items():
                if udid in tk or tk in udid:
                    return tw
            return None
        
        # 等待隧道就绪
        tunnel_ws = None
        tunnel_wait = 0
        max_tunnel_wait = 60
        while client_alive and tunnel_wait < max_tunnel_wait:
            tunnel_ws = _find_tunnel()
            if tunnel_ws:
                break
            tunnel_wait += 1
            if tunnel_wait % 10 == 1:
                logging.warning(f"[WS STREAM] 等待设备 {udid} 隧道... (第{tunnel_wait}次)")
            await asyncio.sleep(0.5)
        
        if not tunnel_ws or not client_alive:
            logging.error(f"[WS STREAM] 设备 {udid} 隧道等待超时或客户端已断开")
            return
        
        # 发送 START_STREAM（幂等操作，ECMAIN 已在推流时会忽略重复启动）
        try:
            await tunnel_ws.send_json({
                "id": f"stream_start_{time.monotonic_ns()}",
                "method": "START_STREAM",
                "url": "http://127.0.0.1:10089/",
                "body": None
            })
            stream_started = True
            logging.info(f"[WS STREAM] START_STREAM 已发送 (从机 {udid})")
        except Exception as e:
            logging.error(f"[WS STREAM] 发送 START_STREAM 失败: {e}")
            return
        
        # 从队列消费 ECMAIN 推送的原生 JPEG 帧，转 base64 推送给前端
        empty_streak = 0
        send_failures = 0
        MAX_SEND_FAILURES = 5  # 连续发送失败超过 5 次视为客户端已死
        
        while client_alive:
            try:
                jpeg_data = await asyncio.wait_for(queue.get(), timeout=5.0)
                if jpeg_data and len(jpeg_data) > 100:
                    frame_count += 1
                    empty_streak = 0
                    
                    # 从机降帧：每 5 帧只推 1 帧，节省带宽
                    if slave == '1' and frame_count % 5 != 0:
                        continue
                    
                    # [v1930 P1] PIL 压缩放入线程池，释放事件循环给其他协程
                    # [v1930 P3] 直接发送二进制帧，省掉 base64 编码的 33% CPU+带宽开销
                    def _compress_frame(raw_jpeg):
                        """线程池中执行的同步 PIL 压缩（CPU 密集任务不阻塞 asyncio）"""
                        try:
                            from PIL import Image
                            import io
                            img = Image.open(io.BytesIO(raw_jpeg))
                            new_w = max(img.width // 3, 120)
                            new_h = max(img.height // 3, 200)
                            img = img.resize((new_w, new_h), Image.LANCZOS)
                            buf = io.BytesIO()
                            img.save(buf, format='JPEG', quality=40, optimize=True)
                            return buf.getvalue()
                        except Exception:
                            return raw_jpeg  # 压缩失败时回退原始帧
                    
                    compressed = await asyncio.to_thread(_compress_frame, jpeg_data)
                    
                    # [v1930 P3] 二进制帧直推：前端用 Blob URL 渲染，无需 base64 中间层
                    try:
                        await websocket.send_bytes(compressed)
                        send_failures = 0  # 发送成功则重置失败计数
                    except (RuntimeError, Exception) as send_err:
                        send_failures += 1
                        if send_failures >= MAX_SEND_FAILURES:
                            logging.info(f"[WS STREAM] 连续 {MAX_SEND_FAILURES} 次发送失败，客户端已断开 ({udid})")
                            break
                        if "close message" in str(send_err) or "WebSocket is closed" in str(send_err):
                            break
                        
            except asyncio.TimeoutError:
                empty_streak += 1
                # [v1930] 隧道断开后尝试重新寻找（设备可能短暂掉线后重连了新隧道）
                if not _find_tunnel():
                    # 给隧道重建 10 秒窗口
                    if empty_streak > 2:
                        logging.warning(f"[WS STREAM] 隧道断开超过 10s，从机流终止 (共推 {frame_count} 帧)")
                        break
                elif empty_streak > 12:
                    # 隧道存在但 60s 无帧（12次 * 5s），大概率设备端推流停止
                    logging.warning(f"[WS STREAM] 连续 60s 未收到帧，从机流终止 ({udid})")
                    break
                continue
            except RuntimeError as re:
                if "close message has been sent" in str(re) or "WebSocket is closed" in str(re):
                    logging.info(f"[WS STREAM] 客户端已断开 ({udid})")
                    break
                raise re
    except WebSocketDisconnect:
        logging.info(f"[WS STREAM] 浏览器主动断开从机推流: {udid}")
    except Exception as e:
        err_str = str(e)
        if "close message" not in err_str and "WebSocket is closed" not in err_str:
            logging.error(f"[WS STREAM] 从机流异常: {e}")
    finally:
        client_alive = False
        listener_task.cancel()
        try:
            await listener_task
        except (asyncio.CancelledError, Exception):
            pass
        
        # 取消订阅
        if udid in STREAM_QUEUES:
            try:
                STREAM_QUEUES[udid].remove(queue)
            except ValueError:
                pass
        # 最后一个订阅者离开时才发送 STOP_STREAM，避免中断其他消费者
        remaining = STREAM_QUEUES.get(udid, [])
        if not remaining:
            STREAM_QUEUES.pop(udid, None)
            if stream_started:
                try:
                    _stop_ws = _find_tunnel() if '_find_tunnel' in dir() else ACTIVE_TUNNELS.get(udid)
                    if _stop_ws:
                        await _stop_ws.send_json({
                            "id": f"stream_stop_{time.monotonic_ns()}",
                            "method": "STOP_STREAM",
                            "url": "",
                            "body": None
                        })
                except:
                    pass
        logging.info(f"[WS STREAM] 方案B从机推流结束，共推 {frame_count} 帧")
        try:
            await websocket.close()
        except:
            pass

@app.get("/api/screen/{udid}")
async def get_screen_stream(udid: str, ip: str = None, usb: str = 'true', mode: str = 'usb', token: str = None, user: dict = Depends(get_current_user), slave: str = '0'):
    await require_device_permission(user, udid)
    
    # [v1760] 切换设备时，先取消该设备的旧 MJPEG 流，防止旧流继续轰炸 WDA /screenshot
    old_stop = ACTIVE_STREAM_STOPS.get(udid)
    if old_stop:
        old_stop.set()  # 触发旧流生成器退出
        logging.info(f"[STREAM] 已取消设备 {udid} 的旧 MJPEG 流，等待内核释放 Socket...")
        await asyncio.sleep(0.5)  # [v1769] 强制错峰 0.5s，确保旧的 Socket (11100 端口) 完全断开，避免新连接因为端口占用被拒绝或死锁
    stop_event = asyncio.Event()
    ACTIVE_STREAM_STOPS[udid] = stop_event
    
    if mode == 'ws':
        # [v1762] 方案B：ECMAIN 从 10089 主动推送原生 JPEG 二进制帧，后端从 STREAM_QUEUES 消费
        async def iter_mjpeg_ws_frames():
            tunnel_wait = 0
            max_tunnel_wait = 60
            frame_count = 0
            stream_started = False
            
            logging.info(f"[WS MJPEG] 方案B启动：等待 ECMAIN 推送原生二进制帧 (udid={udid})")
            
            # [v1763] 注册为该设备的流订阅者（容量 3，超出丢弃最旧帧防止背压）
            queue = asyncio.Queue(maxsize=3)
            if udid not in STREAM_QUEUES:
                STREAM_QUEUES[udid] = []
            STREAM_QUEUES[udid].append(queue)
            
            try:
                # 等待隧道就绪
                tunnel_ws = None
                while not stop_event.is_set() and tunnel_wait < max_tunnel_wait:
                    tunnel_ws = ACTIVE_TUNNELS.get(udid)
                    if not tunnel_ws:
                        # 模糊匹配
                        for tk, tw in ACTIVE_TUNNELS.items():
                            if udid in tk or tk in udid:
                                tunnel_ws = tw
                                break
                    if tunnel_ws:
                        break
                    tunnel_wait += 1
                    if tunnel_wait % 10 == 1:
                        logging.warning(f"[WS MJPEG] 等待设备 {udid} 隧道... (第{tunnel_wait}次)")
                    await asyncio.sleep(0.5)
                
                if not tunnel_ws:
                    logging.error(f"[WS MJPEG] 设备 {udid} 隧道等待超时，流终止")
                    return
                
                # 发送 START_STREAM 指令，触发 ECMAIN 连接 10089 并开始主动推帧
                try:
                    await tunnel_ws.send_json({
                        "id": f"stream_start_{time.monotonic_ns()}",
                        "method": "START_STREAM",
                        "url": "http://127.0.0.1:10089/",
                        "body": None
                    })
                    stream_started = True
                    logging.info(f"[WS MJPEG] START_STREAM 已发送，等待 ECMAIN 推帧...")
                except Exception as e:
                    logging.error(f"[WS MJPEG] 发送 START_STREAM 失败: {e}")
                    return
                
                # 从 STREAM_QUEUES 消费 ECMAIN 推过来的原生 JPEG 帧
                empty_streak = 0
                while not stop_event.is_set():
                    try:
                        jpeg_data = await asyncio.wait_for(queue.get(), timeout=3.0)
                        if jpeg_data and len(jpeg_data) > 100:
                            frame_count += 1
                            empty_streak = 0
                            
                            # 从机模式降帧：每 5 帧只推 1 帧
                            if slave == '1' and frame_count % 5 != 0:
                                continue
                            
                            yield (
                                b"--myboundary\r\n"
                                b"Content-Type: image/jpeg\r\n"
                                b"Content-Length: " + str(len(jpeg_data)).encode() + b"\r\n\r\n" +
                                jpeg_data + b"\r\n"
                            )
                    except asyncio.TimeoutError:
                        empty_streak += 1
                        # 检查隧道是否还活着
                        _check_ws = ACTIVE_TUNNELS.get(udid)
                        if not _check_ws:
                            for tk in ACTIVE_TUNNELS:
                                if udid in tk or tk in udid:
                                    _check_ws = True
                                    break
                        if not _check_ws:
                            logging.warning(f"[WS MJPEG] 隧道已断开，流终止 (共推 {frame_count} 帧)")
                            break
                        if empty_streak > 10:
                            logging.warning(f"[WS MJPEG] 连续 30 秒未收到帧，流终止")
                            break
                        continue
            finally:
                # [v1763] 取消订阅
                if udid in STREAM_QUEUES:
                    try:
                        STREAM_QUEUES[udid].remove(queue)
                    except ValueError:
                        pass
                # 最后一个订阅者离开时才发送 STOP_STREAM
                remaining = STREAM_QUEUES.get(udid, [])
                if not remaining:
                    STREAM_QUEUES.pop(udid, None)
                    if stream_started:
                        try:
                            _stop_ws = ACTIVE_TUNNELS.get(udid)
                            if not _stop_ws:
                                for tk, tw in ACTIVE_TUNNELS.items():
                                    if udid in tk or tk in udid:
                                        _stop_ws = tw
                                        break
                            if _stop_ws:
                                await _stop_ws.send_json({
                                    "id": f"stream_stop_{time.monotonic_ns()}",
                                    "method": "STOP_STREAM",
                                    "url": "",
                                    "body": None
                                })
                        except:
                            pass
                logging.info(f"[WS MJPEG] 方案B推流结束，共消费 {frame_count} 帧")

        return StreamingResponse(
            iter_mjpeg_ws_frames(), 
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
        while retries < 3 and not stop_event.is_set():
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
                    data = await reader.read(65536) # [v1777] 增大读取缓冲区到 64KB，显著提升 TCP 吞吐吞吐量
                    if not data:
                        break
                    buffer += data
                    
                    # [v1777] 循环解析缓冲区内的所有完整帧，防止一包多帧或者半帧导致的卡帧/延迟累加问题
                    while True:
                        start_idx = buffer.find(jwt_start)
                        if start_idx != -1:
                            # 确保寻找的是这帧的结束符
                            end_idx = buffer.find(jwt_end, start_idx)
                            if end_idx != -1:
                                # Found a complete JPEG frame
                                frame = buffer[start_idx:end_idx + 2]
                                buffer = buffer[end_idx + 2:]
                                
                                frames_yielded += 1
                                
                                # [v1716] 从机在原生 USB MJPEG 下通过暴降 FPS 节省后端与浏览器间带宽负担 (保留1/15)
                                if slave == '1' and frames_yielded % 15 != 0:
                                    continue
                                    
                                # Yield standard multipart chunk
                                yield (
                                    b"--myboundary\r\n"
                                    b"Content-Type: image/jpeg\r\n"
                                    b"Content-Length: " + str(len(frame)).encode() + b"\r\n\r\n" + 
                                    frame + b"\r\n"
                                )
                                if frames_yielded > 5:
                                    # Connection is stable, reset retries
                                    retries = 0
                                
                                # 继续在 buffer 里寻找下一帧！
                                continue
                            else:
                                # 找到了开头，但结尾还没来完全，把开头之前的垃圾数据丢掉节省空间
                                buffer = buffer[start_idx:]
                                break # 跳出内层循环，去外层继续 read
                        else:
                            # 连开头都没找到，只保留最后的几个字节防止 marker 被截断
                            if len(buffer) > 2 * 1024 * 1024:
                                buffer = buffer[-4:]
                            break # 跳出内层循环，去外层继续 read
            except Exception as e:
                logging.warning(f"MJPEG stream broken: {e}")
            finally:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass  # 连接已断开，忽略清理异常
            
            # If we reach here, stream collapsed.
            retries += 1
            await asyncio.sleep(1.0)
            
        # [v1672.11] 容灾回退：当物理 USB 的 MJPEG 流不工作时，切换到 WDA 端口阻塞拉取
        wda_port = getattr(dev, "wda_port", 0) if getattr(dev, "wda_port", 0) > 0 else 10088
        if retries >= 3 and dev:
            logging.info(f"[容灾介入] 设备 {udid} 的 MJPEG {target_port} 拒绝服务，切换为 WDA-HTTP 直拉 (端口 {wda_port})")
            import base64
            import requests
            def _fetch_tcp_fallback():
                try:
                    r = requests.get(f"http://127.0.0.1:{wda_port}/screenshot", timeout=2.0)
                    return r.json().get("value") if r.status_code == 200 else None
                except:
                    return None
            while True:
                b64 = await asyncio.to_thread(_fetch_tcp_fallback)
                if b64:
                    try:
                        frame = base64.b64decode(b64)
                        yield (b"--myboundary\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(frame)).encode() + b"\r\n\r\n" + frame + b"\r\n")
                    except:
                        pass
                # [v1762] 降低降级轮询频率，防止短时间内高频调用 /screenshot 导致 WDA 彻底卡死死锁
                await asyncio.sleep(1.5)
            
    return StreamingResponse(
        iter_tcp_frames(), 
        media_type="multipart/x-mixed-replace; boundary=myboundary"
    )

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
    tiktok_version: str = "" # TikTok 版本号
    vpn_node: str = "" # VPN 节点名称

class TaskReportRequest(BaseModel):
    udid: str
    task_name: str
    status: str       # "正在执行" | "执行完成"
    success: bool = False
    error: str = ""
    last_command: str = ""

@app.post("/devices/heartbeat")
def handle_heartbeat(req: HeartbeatRequest):
    """
    接收来自 ECMAIN 每分钟发送的心跳，承接 10万 级并发。
    写数据库靠 database 独有的异步 bulk 消化。
    """
    # 兼容手动点击"保存测试"发送的 ping 状态，将其视为 online
    actual_status = "online" if req.status == "ping" else req.status
    
    # [v1930] device_no 回填兜底：如果心跳未携带编号，尝试从数据库已配置的值回填
    # 解决 ECMAIN 旧版本或 bug 导致心跳不携带 device_no 的问题
    effective_device_no = req.device_no
    if not effective_device_no:
        logging.warning(f"[Heartbeat] 设备 {req.udid} 心跳未携带 device_no，尝试从缓存回填")
        # 从内存缓存中快速查找（避免每次空编号都去读 SQLite）
        with database.CACHE_LOCK:
            cached = database.LATEST_STATUS_CACHE.get(req.udid)
            if cached and cached.get('device_no'):
                effective_device_no = cached['device_no']
    
    database.register_heartbeat(req.udid, {
        "device_no": effective_device_no,
        "status": actual_status,
        "local_ip": req.local_ip,
        "battery_level": req.battery_level,
        "app_version": req.app_version,
        "ecwda_version": req.ecwda_version,
        "vpn_active": 1 if req.vpn_active else 0,
        "vpn_ip": req.vpn_ip,
        "ecwda_status": req.ecwda_status,
        "task_status": req.task_status,
        "tiktok_version": req.tiktok_version,
        "vpn_node": req.vpn_node
    })
    
    # 【自动绑定逻辑】如果心跳携带了管理员账号，则自动建立归属关系
    if req.admin_username:
        admin_uname_clean = req.admin_username.strip()
        with sqlite3.connect(database.DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('SELECT id FROM ec_admins WHERE username COLLATE NOCASE = ?', (admin_uname_clean,))
            admin_row = cursor.fetchone()
            if admin_row:
                admin_id = admin_row['id']
                database.assign_device_to_admin(admin_id, req.udid)
            else:
                logging.warning(f"Heartbeat reported unknown admin: '{req.admin_username}' (cleaned: '{admin_uname_clean}')")
    
    response = {"status": "ok"}
    
    # 获取此手机全局的配置档案，计算 MD5 若不一致，要求客户端下发更新
    device_conf = database.get_device_config(req.udid)
    raw_hash_str = "|".join([
        str(device_conf.get("config_ip", "")),
        str(device_conf.get("config_vpn", "")),
        str(device_conf.get("country", "")),
        str(device_conf.get("group_name", "")),
        str(device_conf.get("exec_time", "")),
        str(device_conf.get("apple_account", "")),
        str(device_conf.get("apple_password", "")),
        str(device_conf.get("tiktok_accounts", "[]")),
        str(device_conf.get("watchdog_wda", 1))
    ])
    server_checksum = hashlib.md5(raw_hash_str.encode('utf-8')).hexdigest()

    if req.config_checksum != server_checksum:
        logging.info(f"[Heartbeat] Config mismatch for {req.udid}: client={req.config_checksum}, server={server_checksum}")
        response["push_config"] = {
            "config_ip": device_conf.get("config_ip", ""),
            "config_vpn": device_conf.get("config_vpn", ""),
            "country": device_conf.get("country", ""),
            "group_name": device_conf.get("group_name", ""),
            "exec_time": device_conf.get("exec_time", ""),
            "apple_account": device_conf.get("apple_account", ""),
            "apple_password": device_conf.get("apple_password", ""),
            "tiktok_accounts": device_conf.get("tiktok_accounts", "[]"),
            "watchdog_wda": device_conf.get("watchdog_wda", 1),
            "config_checksum": server_checksum
        }
    
    # 判断当前设备是否有任务正在执行
    _has_running_task = False
    if req.task_status:
        try:
            _ts = json.loads(req.task_status)
            _has_running_task = isinstance(_ts, list) and len(_ts) > 0
        except Exception:
            _has_running_task = bool(req.task_status.strip())

    # 版本检查（有新版本时优先返回更新信息，由客户端主动打断当前任务进行 OTA）
    if req.app_version > 0:
        latest = _get_latest_ecmain_version()
        if latest and latest.get("version", 0) > req.app_version:
            update_data = {
                "version": latest["version"],
                "build_date": latest.get("build_date", ""),
                "download_url": "/api/ecmain/download"
            }
            response["update"] = update_data
            response["version_url"] = "/api/ecmain/download"
            response["new_version_url"] = "/api/ecmain/download"
    
    # ECWDA 版本检查（有新版本时同样优先下发，由客户端打断任务）
    if req.ecwda_version >= 0:
        latest_wda = _get_latest_ecwda_version()
        if latest_wda and latest_wda.get("version", 0) > req.ecwda_version:
            response["ecwda_update"] = {
                "version": latest_wda["version"],
                "build_date": latest_wda.get("build_date", ""),
                "download_url": "/api/ecwda/download"
            }
    elif req.ecwda_version >= 0 and _has_running_task:
        logging.info(f"[OTA跳过] 设备 {req.udid[:8]} 有任务执行中，跳过 ECWDA OTA 检查")
    
    # 立即查询是否有这台机器的专属待办 JS 任务
    tasks = database.pop_pending_tasks(req.udid, limit=1)
    if tasks:
        t = tasks[0]
        response["task"] = {
            "id": t["id"],
            "type": t["type"],
            "script": t["payload"] if t["type"] == "script" else "",
            "payload": t["payload"] if t["type"] != "script" else {}
        }
    
    return response

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
    
    # [v1684] 兼容 WS 隧道模式下的存活探测
    if "ws" in mode.lower() and ip:
        udid_match = next((d["udid"] for d in device_manager.get_all_devices() if d.get("local_ip") == ip or d.get("ip") == ip), None)
        if udid_match and udid_match in ACTIVE_TUNNELS:
            status_8089 = True
            status_10088 = True
            msg_8089 = "通畅 (WS中转)"
            msg_10088 = "通畅 (WS中转)"
        else:
            msg_8089 = "离线 (WS未建)"
            msg_10088 = "离线 (WS未建)"
    else:
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
async def api_launch_ecwda(req: LaunchReq, user: dict = Depends(get_current_user)):
    await require_device_permission(user, req.udid)
    import subprocess
    import platform_utils
    
    try:
        logical_udid = req.udid
        import platform_utils
        t_path = platform_utils.find_tidevice()
        env = platform_utils.get_env_with_path()
        
        # 0. 核心：把逻辑 UDID (SN) 转化为真正的物理硬件 UDID (40位哈希)
        hw_udid = logical_udid
        state = device_manager.devices.get(logical_udid)
        if state:
            hw_udid = state.hardware_udid
            logging.info(f"[v1930] 逻辑 ID ({logical_udid}) -> 底层物理 ID ({hw_udid})")
        else:
            # DeviceManager 未注册 (WiFi 设备)，通过 tidevice list 反查物理 UDID
            try:
                output = subprocess.check_output([t_path, "list"], text=True, timeout=5)
                for line in output.splitlines():
                    if logical_udid in line:
                        parts = line.split()
                        if parts and len(parts[0]) == 40:
                            hw_udid = parts[0]
                            logging.info(f"[v1930] tidevice list 反查: {logical_udid} -> {hw_udid}")
                        break
            except Exception:
                pass
        
        # 0.5 嗅探连接类型
        conn_type = "USB 或 WiFi"
        is_network = False
        try:
            output = subprocess.check_output([t_path, "list"], text=True, timeout=5)
            for line in output.splitlines():
                if hw_udid in line or logical_udid in line:
                    if "network" in line.lower():
                        conn_type = "WiFi 纯无线远控"
                        is_network = True
                    else:
                        conn_type = "USB 有线专网"
                    break
        except Exception:
            pass

        logging.info(f"[v1930] 🚀 通过 {conn_type} 启动 WDA (目标: {hw_udid})")

        # 1. 净化历史遗留
        _kill_previous_process(_WDA_PROCS, logical_udid)
        platform_utils.kill_process_by_keyword(f"tidevice -u {hw_udid} xctest")
        
        # 2. 根据连接类型选择启动策略
        if is_network:
            # ========== WiFi 模式：使用自研 wifi_wda_launcher 绕过 house_arrest 限制 ==========
            logging.info(f"[v1930] 📡 WiFi 模式：启用自研 instruments 协议直连启动器")
            from wifi_wda_launcher import launch_wda_wifi
            
            # 在后台线程中启动 (非阻塞)
            import threading
            def _wifi_launch():
                try:
                    success = launch_wda_wifi(hw_udid, bundle_id="com.apple.accessibility.ecwda")
                    if success:
                        logging.info(f"[v1930] ✅ WiFi WDA 启动成功！")
                    else:
                        logging.error(f"[v1930] ❌ WiFi WDA 启动失败")
                except Exception as e:
                    logging.error(f"[v1930] WiFi WDA 启动异常: {e}")
            
            t = threading.Thread(target=_wifi_launch, daemon=True)
            t.start()
        else:
            # ========== USB 模式：使用 tidevice 标准流程 ==========
            log_file_path = os.path.join(os.path.dirname(__file__), "wda_run.log")
            wda_log = open(log_file_path, "a")
            cmd_wda = [t_path, "-u", hw_udid, "xctest", "-B", "com.apple.accessibility.ecwda"]
            _WDA_PROCS[logical_udid] = subprocess.Popen(cmd_wda, stdout=wda_log, stderr=wda_log, env=env)
        
        # 3. 触发 DeviceManager 的重连/转发机制
        if logical_udid in device_manager.devices:
            device_manager._start_tunnels(logical_udid)

        logging.info(f"[v1930] ECWDA 唤醒波已通过 {conn_type} 通道发出！目标: {logical_udid}")
        return {
            "status": "ok", 
            "message": f"🤖 WDA 已通过【{conn_type}】成功发射！PID 已分配，WDA 正在初始化...", 
            "mode": conn_type.lower()
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logging.error(f"启动 EC 严重受阻: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/ping")
def ping():
    return {"ping": "pong"}

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
    await require_device_permission(user, req.udid)
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
def api_ecmain_version(udid: str = None):
    """返回服务器上最新的 ECMAIN 版本信息（支持防打断任务保护）"""
    
    # [任务保护] 如果传了设备的唯一识别码(由于前端命名遗留问题仍叫udid)，查是否正在跑任务
    if udid:
        try:
            with sqlite3.connect(database.DB_PATH, timeout=5) as conn:
                cursor = conn.cursor()
                cursor.execute('SELECT task_status FROM ec_devices WHERE udid = ?', (udid,))
                row = cursor.fetchone()
                if row and row[0]:
                    import json
                    ts_raw = row[0]
                    _has_running_task = False
                    try:
                        _ts = json.loads(ts_raw)
                        _has_running_task = isinstance(_ts, list) and len(_ts) > 0
                    except Exception:
                        _has_running_task = bool(ts_raw.strip())
                    
                    if _has_running_task:
                        logging.info(f"[主动OTA跳过] 设备 {udid[:8]} 主动请求版本，但有任务运行中，拒绝下发更新。")
                        return {"status": "error", "msg": "有任务正在执行，暂停升级"}
        except Exception as e:
            logging.error(f"检查主动 OTA 任务状态出错: {e}")

    latest = _get_latest_ecmain_version()
    if latest:
        return {"status": "ok", **latest}
    return {"status": "error", "msg": "暂无版本文件，请先编译生成 ecmain.tar"}

@app.get("/api/ecmain/download")
async def api_ecmain_download():
    """下载最新的 ecmain.tar 更新包（改用 FileResponse，防止 StreamingResponse 导致的协议报错）"""
    tar_path = os.path.join(ECMAIN_BUILD_OUTPUT, "ecmain.tar")
    if not os.path.exists(tar_path):
        raise HTTPException(status_code=404, detail="更新包不存在，请先运行 build_full.py 编译")
    
    return FileResponse(
        path=tar_path,
        media_type="application/x-tar",
        filename="ecmain.tar"
    )

# ==================== ECWDA 自动更新系统 ====================

@app.get("/api/ecwda/version")
def api_ecwda_version(udid: str = None):
    """返回服务器上最新的 ECWDA 版本信息（支持防打断任务保护）"""
    
    # [任务保护]
    if udid:
        try:
            with sqlite3.connect(database.DB_PATH, timeout=5) as conn:
                cursor = conn.cursor()
                cursor.execute('SELECT task_status FROM ec_devices WHERE udid = ?', (udid,))
                row = cursor.fetchone()
                if row and row[0]:
                    import json
                    ts_raw = row[0]
                    _has_running_task = False
                    try:
                        _ts = json.loads(ts_raw)
                        _has_running_task = isinstance(_ts, list) and len(_ts) > 0
                    except Exception:
                        _has_running_task = bool(ts_raw.strip())
                    
                    if _has_running_task:
                        logging.info(f"[主动OTA跳过] 设备 {udid[:8]} 主动请求ECWDA版本，但有任务运行中，拒绝下发更新。")
                        return {"status": "error", "msg": "有任务正在执行，暂停升级"}
        except Exception as e:
            logging.error(f"检查主动 OTA(ECWDA) 任务状态出错: {e}")

    latest = _get_latest_ecwda_version()
    if latest:
        return {"status": "ok", **latest}
    return {"status": "error", "msg": "暂无 ECWDA 版本文件，请先编译生成 ecwda.ipa"}

@app.get("/api/ecwda/download")
async def api_ecwda_download():
    """下载最新的 ecwda.ipa 更新包（改用 FileResponse）"""
    ipa_path = os.path.join(ECMAIN_BUILD_OUTPUT, "ecwda.ipa")
    if not os.path.exists(ipa_path):
        raise HTTPException(status_code=404, detail="ECWDA 更新包不存在，请先运行 build_wda.py 编译")

    return FileResponse(
        path=ipa_path,
        media_type="application/octet-stream",
        filename="ecwda.ipa"
    )

# ================= 文件管理 =================

# 共享文件存储目录
SHARED_FILES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shared_files")
os.makedirs(SHARED_FILES_DIR, exist_ok=True)

@app.get("/api/files")
async def list_shared_files(user: dict = Depends(get_current_user)):
    """列出所有共享文件（排除一次性区域）"""
    files = []
    for filename in os.listdir(SHARED_FILES_DIR):
        if filename == "onetime": continue # 忽略隔离区
        filepath = os.path.join(SHARED_FILES_DIR, filename)
        if os.path.isfile(filepath):
            stat = os.stat(filepath)
            files.append({
                "name": filename,
                "size": stat.st_size,
                "upload_time": stat.st_mtime,
            })
    files.sort(key=lambda f: f["upload_time"], reverse=True)
    return {"files": files}
@app.post("/api/files/upload")
async def upload_shared_file(file: UploadFile = FastAPIFile(...), user: dict = Depends(require_super_admin)):
    """上传文件（仅超级管理员）"""
    if not file.filename:
        raise HTTPException(status_code=400, detail="文件名不能为空")
    
    # 安全文件名：移除路径分隔符
    safe_name = os.path.basename(file.filename)
    dest_path = os.path.join(SHARED_FILES_DIR, safe_name)
    
    # 同名自动覆盖
    content = await file.read()
    with open(dest_path, "wb") as f:
        f.write(content)
    
    file_size = os.path.getsize(dest_path)
    return {"ok": True, "filename": safe_name, "size": file_size}

@app.get("/api/files/download/{filename}")
async def download_shared_file(filename: str):
    """下载共享文件（无需认证，支持直链下载）"""
    safe_name = os.path.basename(filename)
    filepath = os.path.join(SHARED_FILES_DIR, safe_name)
    if not os.path.isfile(filepath):
        raise HTTPException(status_code=404, detail="文件不存在")
    return FileResponse(filepath, filename=safe_name, media_type="application/octet-stream")

@app.delete("/api/files/{filename}")
async def delete_shared_file(filename: str, user: dict = Depends(require_super_admin)):
    """删除共享文件（仅超级管理员）"""
    safe_name = os.path.basename(filename)
    filepath = os.path.join(SHARED_FILES_DIR, safe_name)
    if not os.path.isfile(filepath):
        raise HTTPException(status_code=404, detail="文件不存在")
    os.remove(filepath)
    return {"ok": True}

# --- 一次性文件分配机制与扫描系统 (分组排序版) ---

import threading
import uuid
import shutil
import math
from starlette.background import BackgroundTask
from typing import Optional

onetime_file_lock = threading.Lock()
ONETIME_BASE = os.path.join(SHARED_FILES_DIR, "onetime")
os.makedirs(ONETIME_BASE, exist_ok=True)

@app.get("/api/files/onetime/groups")
async def list_onetime_groups(user: dict = Depends(get_current_user)):
    """递归列出所有一次性文件分组列表"""
    groups = []
    # 深度遍历 ONETIME_BASE
    for root, dirs, files in os.walk(ONETIME_BASE):
        # 统计当前目录下未上锁的素材数量
        count = len([f for f in files if not f.endswith('.serving')])
        if count > 0:
            # 计算相对于 ONETIME_BASE 的相对路径作为组名
            rel_path = os.path.relpath(root, ONETIME_BASE)
            if rel_path == ".":
                # 根目录通常不直接放文件，若有则叫 root 或保持空，前端可处理
                continue
            groups.append({"name": rel_path, "count": count})
    
    groups.sort(key=lambda g: g["name"])
    return {"groups": groups}

@app.get("/api/files/onetime")
async def list_onetime_files(group: str, page: int = 1, size: int = 50, user: dict = Depends(get_current_user)):
    """分页列出指定分组下的一次性文件"""
    gpath = os.path.join(ONETIME_BASE, group)
    if not os.path.isdir(gpath):
        return {"files": [], "total": 0, "page": page, "size": size}
    
    all_files = []
    for f in os.listdir(gpath):
        if not f.endswith('.serving'):
             fpath = os.path.join(gpath, f)
             if os.path.isfile(fpath):
                  stat = os.stat(fpath)
                  all_files.append({"name": f, "size": stat.st_size, "time": stat.st_mtime})
                  
    # 按照名称顺序排列保证先被吃
    all_files.sort(key=lambda x: x["name"])
    
    total = len(all_files)
    start = (page - 1) * size
    end = start + size
    return {
        "files": all_files[start:end],
        "total": total,
        "page": page,
        "size": size,
        "total_pages": math.ceil(total / size)
    }

@app.get("/api/files/download_onetime/{media_type}")
async def download_onetime_file(media_type: str, group: Optional[str] = None, filename: Optional[str] = None, preview: bool = False):
    """提取或预览指定分组的一次性文件。preview=true 时仅查看，不销毁。"""
    if preview:
        if not group or not filename:
            raise HTTPException(status_code=400, detail="预览模式必须提供分组(group)和文件名(filename)")
        selected_path = os.path.join(ONETIME_BASE, group, filename)
        if not os.path.exists(selected_path):
            raise HTTPException(status_code=404, detail="预览文件不存在或已被领走")
        return FileResponse(path=selected_path, filename=filename, media_type="application/octet-stream")

    exts = ['.mp4', '.mov', '.avi'] if media_type == 'video' else ['.jpg', '.png', '.jpeg']
    
    selected_path = None
    original_name = None
    
    with onetime_file_lock:
        groups_to_check = [group] if group and os.path.isdir(os.path.join(ONETIME_BASE, group)) else []
        if not groups_to_check:
             # 如果不指定分组则扫全盘所有分发组
             groups_to_check = [g for g in os.listdir(ONETIME_BASE) if os.path.isdir(os.path.join(ONETIME_BASE, g))]
             
        for gname in groups_to_check:
            gpath = os.path.join(ONETIME_BASE, gname)
            files = sorted(os.listdir(gpath)) # 保证顺序取出字典序第一个
            for filename in files:
                if filename.endswith(".serving"): continue
                _, ext = os.path.splitext(filename)
                if ext.lower() in exts:
                    # 找到了顺序顶部的资源！改名上锁
                    old_path = os.path.join(gpath, filename)
                    new_path = old_path + ".serving"
                    os.rename(old_path, new_path)
                    selected_path = new_path
                    original_name = filename
                    break
            if selected_path:
                break
                    
    if not selected_path:
         raise HTTPException(status_code=404, detail=f"仓库里的 {group or '所有'} 特定一次性素材已被耗尽")

    def cleanup(symlink_path):
        try:
             # 解析软链接指向的真实物理路径
             if os.path.islink(symlink_path):
                 real_path = os.path.realpath(symlink_path)
                 # 1. 删除原始物理文件（实现"访问即销毁"）
                 if os.path.exists(real_path):
                     os.remove(real_path)
                 # 2. 删除系统内部的软链接索引
                 os.remove(symlink_path)
             else:
                 # 兼容非软链接模式（如手动放入的文件）
                 os.remove(symlink_path)
        except Exception as e:
             logging.error(f"Cleanup failed for {symlink_path}: {e}")

    return FileResponse(
         path=selected_path, 
         filename=original_name,
         media_type="application/octet-stream",
         background=BackgroundTask(cleanup, selected_path)
    )

class ScanRequest(BaseModel):
    path: str

class DeleteOnetimeRequest(BaseModel):
    group: str
    filename: str

@app.delete("/api/files/onetime/item")
async def delete_onetime_item(req: DeleteOnetimeRequest, user: dict = Depends(require_super_admin)):
    """手动销毁指定的一次性素材：同步物理删除软链接与原始物理文件"""
    symlink_path = os.path.join(ONETIME_BASE, req.group, req.filename)
    if not os.path.exists(symlink_path):
        raise HTTPException(status_code=404, detail="索引文件不存在，可能已被销毁")
    
    try:
        # 1. 如果是软链接，先找到原件
        if os.path.islink(symlink_path):
            real_path = os.path.realpath(symlink_path)
            if os.path.exists(real_path):
                os.remove(real_path) # 销毁原件
        
        # 2. 销毁索引
        os.remove(symlink_path)
        return {"ok": True, "msg": f"已成功从物理磁盘抹除：{req.filename}"}
    except Exception as e:
        logging.error(f"Manual delete failed: {e}")
        raise HTTPException(status_code=500, detail=f"销毁失败: {str(e)}")
    
@app.post("/api/files/scan")
async def scan_local_files_to_shared(req: ScanRequest, user: dict = Depends(require_super_admin)):
    """原地索引：建立指向原始文件的软链接，并保持完整的子目录结构"""
    target_dir = req.path.strip()
    if target_dir.endswith('/') or target_dir.endswith('\\'):
        target_dir = target_dir[:-1]
        
    if not os.path.isdir(target_dir):
        raise HTTPException(status_code=400, detail="提供的路径不存在或不是有效目录")
        
    # 获取扫描目标的基准文件夹名作为根组名
    base_group_name = os.path.basename(target_dir) or "scanned"
    
    count = 0
    # 递归遍历目标目录
    for root, dirs, files in os.walk(target_dir):
        # 统计本级目录下合法的原始媒体文件
        valid_media_files = []
        for file in files:
             _, ext = os.path.splitext(file)
             if ext.lower() in ['.mp4', '.mov', '.avi', '.jpg', '.png', '.jpeg']:
                 valid_media_files.append(file)
        
        if not valid_media_files and not dirs:
            continue

        # 计算在 ONETIME_BASE 构建对应的镜像目录路径
        rel_sub_path = os.path.relpath(root, target_dir)
        if rel_sub_path == ".":
            dest_group_dir = os.path.join(ONETIME_BASE, base_group_name)
        else:
            dest_group_dir = os.path.join(ONETIME_BASE, base_group_name, rel_sub_path)
        
        os.makedirs(dest_group_dir, exist_ok=True)

        # 1. 建立或恢复索引
        for file in valid_media_files:
             abs_path = os.path.join(root, file)
             dest_link_path = os.path.join(dest_group_dir, file)
             
             if not os.path.exists(dest_link_path):
                 try:
                     os.symlink(abs_path, dest_link_path)
                     count += 1
                 except Exception as e:
                     logging.error(f"建立索引受阻 {abs_path}: {e}")
        
        # 2. 清理冗余：删除索引目录下不在原始名单中的多余文件（解决带随机后缀的老旧索引问题）
        try:
            for item in os.listdir(dest_group_dir):
                # 排除正在分发中的锁文件
                if item.endswith(".serving"):
                    continue
                # 如果这个索引文件不在本次扫描的原始名单中，说明是过时的或者是多余的，直接干掉
                if item not in valid_media_files:
                    path_to_del = os.path.join(dest_group_dir, item)
                    if os.path.isfile(path_to_del) or os.path.islink(path_to_del):
                        os.remove(path_to_del)
                        logging.info(f"清理冗余索引: {path_to_del}")
        except Exception as e:
            logging.error(f"同步清理目录失败 {dest_group_dir}: {e}")
                     
    return {"ok": True, "count": count, "msg": f"全同步完成！已对齐原目录结构，并清理了所有冗余索引。"}

# ================= 动态资产：标签与简介 Web 管理接口 =================

class BatchUploadReq(BaseModel):
    country: str
    group_name: str = ""
    text: str

@app.get("/api/assets/tags")
async def api_get_tags(country: str, user: dict = Depends(get_current_user)):
    return {"tags": database.get_tags_by_country(country)}

@app.post("/api/assets/tags/batch")
async def api_add_tags_batch(req: BatchUploadReq, user: dict = Depends(require_super_admin)):
    lines = [L for L in req.text.split('\n') if L.strip()]
    count = database.add_tag_batch(req.country, lines, req.group_name)
    return {"ok": True, "count": count, "msg": f"成功录入 {count} 条标签！"}

@app.delete("/api/assets/tags/{tag_id}")
async def api_delete_tag(tag_id: int, user: dict = Depends(require_super_admin)):
    database.delete_tag(tag_id)
    return {"ok": True}

@app.get("/api/assets/bios")
async def api_get_bios(country: str, user: dict = Depends(get_current_user)):
    return {"bios": database.get_bios_by_country(country)}

@app.post("/api/assets/bios/batch")
async def api_add_bios_batch(req: BatchUploadReq, user: dict = Depends(require_super_admin)):
    lines = [L for L in req.text.split('\n') if L.strip()]
    count = database.add_bio_batch(req.country, lines, req.group_name)
    return {"ok": True, "count": count, "msg": f"成功录入 {count} 条简介！"}

@app.delete("/api/assets/bios/{bio_id}")
async def api_delete_bio(bio_id: int, user: dict = Depends(require_super_admin)):
    database.delete_bio(bio_id)
    return {"ok": True}

# ================= 动态资产：开放随机提取接口 (供脚本使用) =================

@app.get("/api/assets/tags/random")
async def api_get_random_tag(country: str, group_name: str = ""):
    """供 iOS 脚本随机获取一条指定国家的标签，用作盲抽"""
    val = database.get_random_tag(country, group_name)
    return {"ok": True, "value": val}

@app.get("/api/assets/bios/random")
async def api_get_random_bio(country: str, group_name: str = ""):
    """供 iOS 脚本随机获取一条指定国家的简介，用作盲抽"""
    val = database.get_random_bio(country, group_name)
    return {"ok": True, "value": val}
if __name__ == "__main__":
    # [v1930 P0] 关闭 reload 模式，消除文件监控开销，提升约 15-20% 吞吐
    # 注意：不能加 workers>1，因为 ACTIVE_TUNNELS / STREAM_QUEUES 是进程内存态，
    # 多 Worker 之间无法共享 WebSocket 连接状态，会导致隧道寻址失败
    uvicorn.run("main:app", host="0.0.0.0", port=8088, reload=False)

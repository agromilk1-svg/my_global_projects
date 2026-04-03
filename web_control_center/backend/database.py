import sqlite3
import threading
import time
import logging
from typing import Dict, Any, List

logger = logging.getLogger("Database")
logging.basicConfig(level=logging.INFO)

# 核心配置
DB_PATH = "ecmain_control.db"
HEARTBEAT_TIMEOUT = 180 # 设备在线判定超时时间 (秒)，180秒 = 3分钟

# 纯内存的高并发心跳池（UDID -> Details）
HEARTBEAT_CACHE: Dict[str, dict] = {}
# [v1682.3] 持久最新状态缓存：确保 get_all_cloud_devices 能无延迟读到最新心跳（即便尚未 Flush 到磁盘）
LATEST_STATUS_CACHE: Dict[str, dict] = {}
CACHE_LOCK = threading.Lock()

def init_db():
    """初始化数据库与表结构 (启用 WAL 提高并发性能)"""
    with sqlite3.connect(DB_PATH) as conn:
        # WAL 模式加持，防读写锁死
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=NORMAL;")
        
        cursor = conn.cursor()
        
        # 1. 设备在线状态汇总表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_devices (
                udid TEXT PRIMARY KEY,
                ip TEXT,
                status TEXT,
                battery INTEGER,
                last_heartbeat REAL
            )
        ''')
        
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN device_no TEXT;")
        except Exception:
            pass # 列已存在
        
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN app_version INTEGER DEFAULT 0;")
        except Exception:
            pass
        
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN ecwda_version INTEGER DEFAULT 0;")
        except Exception:
            pass
        
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN vpn_active INTEGER DEFAULT 0;")
        except Exception:
            pass
            
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN vpn_ip TEXT;")
        except Exception:
            pass
            
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN ecwda_status TEXT DEFAULT 'offline';")
        except Exception:
            pass
            
        # [配置中心关联] 新增设备关联字段
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN country TEXT;")
        except Exception:
            pass
            
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN group_name TEXT;")
        except Exception:
            pass
            
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN exec_time TEXT;")
        except Exception:
            pass
            
        # [配置中心] 国家配置表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_countries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE
            )
        ''')
        
        # [配置中心] 分组配置表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_groups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE
            )
        ''')
        
        # [配置中心] 执行时间配置表 (取代原先的 0-23 常量)
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_execution_times (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                hour INTEGER UNIQUE
            )
        ''')
        
        # [v1682.2] 自动清理逻辑：剔除 3 天未活跃的“僵尸”设备，解决 UDID 换代后的历史残留干扰
        # 防止由于 UDID 变更导致列表中出现大量同名但 UDID 不同的离线设备
        three_days_ago = time.time() - (3 * 24 * 3600)
        cursor.execute('DELETE FROM ec_devices WHERE last_heartbeat < ?', (three_days_ago,))
        
        conn.commit()
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_exec_times (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE
            )
        ''')
            
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN ecwda_status TEXT DEFAULT 'offline';")
        except Exception:
            pass
            
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN config_ip TEXT;")
        except Exception:
            pass
            
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN config_vpn TEXT;")
        except Exception:
            pass
        
        # [账号管理] Apple 账号/密码 + TikTok 多账号 (JSON)
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN apple_account TEXT;")
        except Exception:
            pass
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN apple_password TEXT;")
        except Exception:
            pass
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN tiktok_accounts TEXT;")
        except Exception:
            pass
        
        # [任务状态] 存储设备上报的任务完成状态（现在直接用作独立存储实时 JSON 字典，如 {"task_name": "...", "status": "正在执行"}）
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN task_status TEXT DEFAULT '';")
        except Exception:
            pass
            
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN wifi_ssid TEXT;")
        except Exception:
            pass
            
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN wifi_password TEXT;")
        except Exception:
            pass
        
        # [日志分离] 独立存储 /api/device/task_report 上报的详细日志，防止被心跳覆盖
        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN task_report TEXT;")
        except Exception:
            pass

        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN tiktok_version TEXT;")
        except Exception:
            pass

        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN vpn_node TEXT;")
        except Exception:
            pass

        try:
            cursor.execute("ALTER TABLE ec_devices ADD COLUMN watchdog_wda INTEGER DEFAULT 1;")
        except Exception:
            pass

        # 2. 任务分发表 (单台下发)
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                udid TEXT NOT NULL,
                task_type TEXT NOT NULL,
                payload TEXT,
                status TEXT DEFAULT 'pending', 
                result TEXT,
                created_at REAL,
                updated_at REAL
            )
        ''')
        
        # 3. 自动动作脚本表 (全局)
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_scripts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                code TEXT NOT NULL,
                created_at REAL,
                updated_at REAL
            )
        ''')
        
        # 为 ec_scripts 补充配置字段
        try:
            cursor.execute("ALTER TABLE ec_scripts ADD COLUMN country TEXT DEFAULT '';")
        except Exception:
            pass
        try:
            cursor.execute("ALTER TABLE ec_scripts ADD COLUMN group_name TEXT DEFAULT '';")
        except Exception:
            pass
        try:
            cursor.execute("ALTER TABLE ec_scripts ADD COLUMN exec_time TEXT DEFAULT '';")
        except Exception:
            pass

        # 4. 评论管理表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_comments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                language TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at REAL
            )
        ''')

        # 5. [TikTok 账号管理] 独立账号表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_tiktok_accounts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                device_udid TEXT NOT NULL,
                account TEXT NOT NULL,
                password TEXT DEFAULT '',
                email TEXT DEFAULT '',
                country TEXT DEFAULT '',
                fans_count INTEGER DEFAULT 0,
                is_for_sale INTEGER DEFAULT 0,
                is_window_opened INTEGER DEFAULT 0,
                add_time TEXT DEFAULT '',
                window_open_time TEXT DEFAULT '',
                sale_time TEXT DEFAULT '',
                is_primary INTEGER DEFAULT 0,
                UNIQUE(device_udid, account)
            )
        ''')
        try:
            cursor.execute("ALTER TABLE ec_tiktok_accounts ADD COLUMN is_primary INTEGER DEFAULT 0;")
        except Exception:
            pass
        try:
            cursor.execute("ALTER TABLE ec_tiktok_accounts ADD COLUMN password TEXT DEFAULT '';")
        except Exception:
            pass
        try:
            cursor.execute("ALTER TABLE ec_tiktok_accounts ADD COLUMN email TEXT DEFAULT '';")
        except Exception:
            pass

        # 建立索引以加速待处理任务的分发查询
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_tasks_udid_status ON ec_tasks(udid, status);')
        
        # 6. [权限系统] 管理员账号表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_admins (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                salt TEXT NOT NULL,
                role TEXT DEFAULT 'admin',
                created_at REAL
            )
        ''')
        
        # 7. [权限系统] 管理员-设备归属关系表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_admin_devices (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                admin_id INTEGER NOT NULL,
                device_udid TEXT NOT NULL,
                UNIQUE(admin_id, device_udid)
            )
        ''')
        
        # 8. [一次性任务] 按设备精确下发的高优先级任务表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS ec_oneshot_tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                udid TEXT NOT NULL,
                name TEXT NOT NULL,
                code TEXT NOT NULL,
                status TEXT DEFAULT 'pending',
                result TEXT,
                created_at REAL
            )
        ''')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_oneshot_udid ON ec_oneshot_tasks(udid);')
        
        # 初始化默认超级管理员（仅在表为空时插入）
        cursor.execute('SELECT COUNT(*) FROM ec_admins')
        if cursor.fetchone()[0] == 0:
            import hashlib, os as _os
            _salt = _os.urandom(16).hex()
            _hash = hashlib.sha256(('admin123' + _salt).encode()).hexdigest()
            cursor.execute('''
                INSERT INTO ec_admins (username, password_hash, salt, role, created_at)
                VALUES (?, ?, ?, ?, ?)
            ''', ('admin', _hash, _salt, 'super_admin', time.time()))
            logger.info("已创建默认超级管理员: admin / admin123")
        
        conn.commit()
    logger.info("Database initialized successfully with WAL concurrent mode.")

def _flush_heartbeat_worker():
    """守护线程：将每秒数万的并发心跳，收敛为每 5 秒一次向磁盘 SQLite 的 Bulk 更新"""
    while True:
        time.sleep(5)
        
        with CACHE_LOCK:
            if not HEARTBEAT_CACHE:
                continue
            # 浅拷贝提走当前批次缓存，原位清空接纳新兵
            snapshot = HEARTBEAT_CACHE.copy()
            HEARTBEAT_CACHE.clear()
            
        if not snapshot:
            continue
            
        try:
            with sqlite3.connect(DB_PATH, timeout=10) as conn:
                cursor = conn.cursor()
                # 批量 UPSERT，遇到重复 UDID 就更新后续字段
                bulk_data = []
                for udid, data in snapshot.items():
                    # 预处理 task_status，确保其为合法的 JSON 字符串，否则 JSON_EXTRACT 会报错
                    ts_raw = data.get('task_status', '')
                    if not ts_raw or ts_raw == '""':
                        ts_json = '[]'
                    else:
                        ts_json = ts_raw

                    # 采取单独 UPSERT 核心心跳字段的形式，以防抹除从别处修改的国家/分组/编号信息
                    bulk_data.append((
                        data.get('device_no', ''),
                        data.get('local_ip', ''), 
                        data.get('status', 'online'),
                        data.get('battery_level', 0),
                        data.get('app_version', 0),
                        data.get('ecwda_version', 0),
                        data.get('vpn_active', 0),
                        data.get('vpn_ip', ''),
                        data.get('ecwda_status', 'offline'),
                        ts_json, # task_status CASE 条件判断
                        ts_json, # task_status CASE 赋值
                        data.get('tiktok_version', ''),
                        data.get('vpn_node', ''),
                        data.get('timestamp', time.time()),
                        udid
                    ))
                
                cursor.executemany('''
                    UPDATE ec_devices 
                    SET device_no = COALESCE(NULLIF(?, ''), device_no),
                        ip = COALESCE(NULLIF(?, ''), ip),
                        status = COALESCE(NULLIF(?, ''), status),
                        battery = COALESCE(NULLIF(?, ''), battery),
                        app_version = COALESCE(NULLIF(?, ''), app_version),
                        ecwda_version = COALESCE(NULLIF(?, ''), ecwda_version),
                        vpn_active = ?,
                        vpn_ip = ?,
                        ecwda_status = COALESCE(NULLIF(?, ''), ecwda_status),
                        task_status = CASE WHEN ? != '[]' THEN ? ELSE task_status END,
                        tiktok_version = ?,
                        vpn_node = ?,
                        last_heartbeat = ?
                    WHERE udid = ?
                ''', bulk_data)
                
                # 若有的设备连UPDATE都命不中（全新UDID），需要额外INSERT
                # 首先收集刚更新受影响的UDID，对于没有受影响的插入全新数据
                # 简单处理：全量 INSERT OR IGNORE
                insert_data = []
                for udid, data in snapshot.items():
                   insert_data.append((
                        udid,
                        data.get('device_no', ''),
                        data.get('local_ip', ''),
                        data.get('status', 'online'),
                        data.get('battery_level', 0),
                        data.get('app_version', 0),
                        data.get('ecwda_version', 0),
                        data.get('vpn_active', 0),
                        data.get('vpn_ip', ''),
                        data.get('ecwda_status', 'offline'),
                        data.get('task_status', ''),
                        data.get('tiktok_version', ''),
                        data.get('vpn_node', ''), # 新增 vpn_node
                        data.get('timestamp', time.time())
                   ))
                cursor.executemany('''
                    INSERT OR IGNORE INTO ec_devices 
                    (udid, device_no, ip, status, battery, app_version, ecwda_version, vpn_active, vpn_ip, ecwda_status, task_status, tiktok_version, vpn_node, last_heartbeat) 
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ''', insert_data)
                conn.commit()
            logger.debug(f"[Heartbeat] Flushed {len(snapshot)} device spikes to disk.")
        except Exception as e:
            logger.error(f"[Heartbeat Flush Error] {e}")

def start_heartbeat_flusher():
    t = threading.Thread(target=_flush_heartbeat_worker, daemon=True)
    t.start()

def register_heartbeat(udid: str, payload: dict):
    """供 API 接口实时吞吐调用，O(1) 写内存，绝不阻塞"""
    payload['timestamp'] = time.time()
    with CACHE_LOCK:
        HEARTBEAT_CACHE[udid] = payload
        # 同步更新持久缓存，供实时接口读取
        if udid not in LATEST_STATUS_CACHE:
            LATEST_STATUS_CACHE[udid] = {}
        LATEST_STATUS_CACHE[udid].update(payload)

def pop_pending_tasks(udid: str, limit: int = 1) -> List[dict]:
    """取出并发给指定设备的待命任务 (直接返回首个任务并打上发送中标签)"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            
            # 使用事务锁定拿到的任务避免重复派发
            cursor.execute('''
                SELECT id, task_type, payload FROM ec_tasks 
                WHERE udid = ? AND status = 'pending' 
                ORDER BY created_at ASC LIMIT ?
            ''', (udid, limit))
            
            rows = cursor.fetchall()
            tasks = []
            
            if rows:
                task_ids = [r['id'] for r in rows]
                placeholders = ','.join(['?'] * len(task_ids))
                cursor.execute(f'''
                    UPDATE ec_tasks SET status = 'sent', updated_at = ? 
                    WHERE id IN ({placeholders})
                ''', [time.time()] + task_ids)
                
                for r in rows:
                    tasks.append({
                        "id": r['id'],
                        "type": r['task_type'],
                        "payload": r['payload']
                    })
                conn.commit()
                
            return tasks
    except Exception as e:
        logger.error(f"Error popping task for {udid}: {e}")
        return []

def report_task_result(task_id: int, status: str, result: str):
    """供设备汇报执行大局观结果"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('''
                UPDATE ec_tasks SET status = ?, result = ?, updated_at = ?
                WHERE id = ?
            ''', (status, result, time.time(), task_id))
            conn.commit()
    except Exception as e:
        logger.error(f"Error reporting task {task_id}: {e}")

def create_task(udid: str, task_type: str, payload: str):
    """控制中心下发新任务记录"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('''
                INSERT INTO ec_tasks (udid, task_type, payload, status, created_at)
                VALUES (?, ?, ?, 'pending', ?)
            ''', (udid, task_type, payload, time.time()))
            conn.commit()
            return cursor.lastrowid
    except Exception as e:
        logger.error(f"Error creating task for {udid}: {e}")
        return None

def get_all_cloud_devices() -> List[dict]:
    """获取目前在管控池子内的所有装备状态"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            # 无论是否超时，都取出所有已记录的设备
            cursor.execute('SELECT * FROM ec_devices ORDER BY last_heartbeat DESC')
            
            devices = []
            now = time.time()
            for r in cursor.fetchall():
                d = dict(r)
                # 超过阈值未有心跳，动态将状态覆盖为离线
                if (now - d.get('last_heartbeat', 0)) >= HEARTBEAT_TIMEOUT:
                    d['status'] = 'offline'
                
                # [v1682.4] 内存热数据覆盖：如果该设备刚发过心跳，直接用内存里的最新值覆盖数据库旧值
                # 这样可以解决 Flusher 5秒周期导致的实时显示延迟
                with CACHE_LOCK:
                    mem_data = LATEST_STATUS_CACHE.get(d['udid'])
                    if mem_data:
                        # 转换字段名对齐 (database vs request)
                        # vpn_node 已经是同名
                        ts = mem_data.get('timestamp', d['last_heartbeat'])
                        d.update({
                            "status": mem_data.get('status', d['status']),
                            "battery": mem_data.get('battery_level', d['battery']),
                            "ip": mem_data.get('local_ip', d['ip']),
                            "vpn_active": 1 if mem_data.get('vpn_active') else 0,
                            "vpn_ip": mem_data.get('vpn_ip', d.get('vpn_ip', '')),
                            "vpn_node": mem_data.get('vpn_node', d.get('vpn_node', '')),
                            "ecwda_status": mem_data.get('ecwda_status', d.get('ecwda_status', 'offline')),
                            "tiktok_version": mem_data.get('tiktok_version', d.get('tiktok_version', '')),
                            "last_heartbeat": ts
                        })
                    # 数据库原始值本身就是绝对时间戳，无需修改
                
                devices.append(d)
                
            return devices
    except Exception as e:
        logger.error(f"Error getting cloud devices: {e}")
        return []

def delete_device(udid: str):
    """从数据库彻底删除指定设备"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM ec_devices WHERE udid = ?', (udid,))
            conn.commit()
    except Exception as e:
        logger.error(f"Error deleting device {udid}: {e}")

def batch_delete_devices(udids: list) -> bool:
    """批量从数据库彻底删除指定设备"""
    if not udids:
        return True
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            placeholders = ','.join(['?'] * len(udids))
            cursor.execute(f'DELETE FROM ec_devices WHERE udid IN ({placeholders})', udids)
            conn.commit()
            return True
    except Exception as e:
        logger.error(f"Error batch deleting devices: {e}")
        return False

def batch_update_devices_config(udids: list, country: str = None, group_name: str = None, exec_time: str = None, config_vpn: str = None, wifi_ssid: str = None, wifi_password: str = None) -> bool:
    """批量更新设备的国家、分组、启动时间、VPN或WiFi配置，值为 None 则不修改"""
    if not udids:
        return True
    updates = []
    params = []
    
    if country is not None:
        updates.append("country = ?")
        params.append(country)
    if group_name is not None:
        updates.append("group_name = ?")
        params.append(group_name)
    if exec_time is not None:
        updates.append("exec_time = ?")
        params.append(exec_time)
    if config_vpn is not None:
        updates.append("config_vpn = ?")
        params.append(config_vpn)
    if wifi_ssid is not None:
        updates.append("wifi_ssid = ?")
        params.append(wifi_ssid)
    if wifi_password is not None:
        updates.append("wifi_password = ?")
        params.append(wifi_password)
        
    if not updates:
        return True # 没有需要修改的字段
        
    placeholders = ','.join(['?'] * len(udids))
    query = f"UPDATE ec_devices SET {', '.join(updates)} WHERE udid IN ({placeholders})"
    params.extend(udids)
    
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute(query, params)
            conn.commit()
            return True
    except Exception as e:
        logger.error(f"Error batch updating configs: {e}")
        return False

def get_device_config(udid: str) -> dict:
    """获取设备的静态 IP 和 VPN 等高级配置"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('SELECT config_ip, config_vpn, device_no, country, group_name, exec_time, apple_account, apple_password, tiktok_accounts, wifi_ssid, wifi_password, watchdog_wda FROM ec_devices WHERE udid = ?', (udid,))
            row = cursor.fetchone()
            if row:
                config_data = {
                    "config_ip": row["config_ip"] or "",
                    "config_vpn": row["config_vpn"] or "",
                    "device_no": row["device_no"] or "",
                    "country": row["country"] or "",
                    "group_name": row["group_name"] or "",
                    "exec_time": row["exec_time"] or "",
                    "apple_account": row["apple_account"] or "",
                    "apple_password": row["apple_password"] or "",
                    "tiktok_accounts": row["tiktok_accounts"] or "[]",
                    "wifi_ssid": row["wifi_ssid"] or "",
                    "wifi_password": row["wifi_password"] or "",
                    "watchdog_wda": row["watchdog_wda"] if row["watchdog_wda"] is not None else 1
                }
                
                # [TikTok 数据补全逻辑] 从独立账号表拉取实时数据，覆盖 devices 表中的老旧 JSON
                import json
                cursor.execute('SELECT account, password, email FROM ec_tiktok_accounts WHERE device_udid = ? ORDER BY is_primary DESC, id ASC', (udid,))
                rows = cursor.fetchall()
                accounts = []
                for r in rows:
                    accounts.append({
                        "account": r["account"],
                        "password": r["password"] or "",
                        "email": r["email"] or ""
                    })
                config_data["tiktok_accounts"] = json.dumps(accounts, ensure_ascii=False)
                return config_data
    except Exception as e:
        logger.error(f"Error getting config for {udid}: {e}")
    return {"config_ip": "", "config_vpn": "", "device_no": "", "country": "", "group_name": "", "exec_time": "", "apple_account": "", "apple_password": "", "tiktok_accounts": "[]", "wifi_ssid": "", "wifi_password": "", "watchdog_wda": 1}

def set_device_config(udid: str, config_ip: str, config_vpn: str, device_no: str = "", country: str = "", group_name: str = "", exec_time: str = "", apple_account: str = "", apple_password: str = "", tiktok_accounts: str = "[]", wifi_ssid: str = "", wifi_password: str = "", watchdog_wda: int = 1):
    """保存设备的静态 IP、网络及高级设置配置"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('''
                UPDATE ec_devices
                SET config_ip = ?, config_vpn = ?,
                    device_no = ?, country = ?, group_name = ?, exec_time = ?,
                    apple_account = ?, apple_password = ?, tiktok_accounts = ?,
                    wifi_ssid = ?, wifi_password = ?, watchdog_wda = ?
                WHERE udid = ?
            ''', (config_ip, config_vpn, device_no, country, group_name, exec_time, apple_account, apple_password, tiktok_accounts, wifi_ssid, wifi_password, watchdog_wda, udid))
            
            # [TikTok 联动逻辑] 自动解析传递过来的 JSON 格式的 tiktok_accounts
            import json
            import datetime
            try:
                accounts_list = json.loads(tiktok_accounts)
            except Exception:
                accounts_list = []
                
            if isinstance(accounts_list, list):
                # 找出该设备现存的 TikTok 账号
                cursor.execute('SELECT account FROM ec_tiktok_accounts WHERE device_udid = ?', (udid,))
                existing_accounts = {row[0] for row in cursor.fetchall()}
                
                # 获取系统当前时间用于添加时间
                now_str = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                
                # 遍历表单传递过来的账号列表，执行增量更新或插入
                for act in accounts_list:
                    if not isinstance(act, dict) or 'account' not in act:
                        continue
                    
                    acc_str = str(act.get('account', '')).strip()
                    pwd_str = str(act.get('password', '')).strip()
                    email_str = str(act.get('email', '')).strip()
                    is_pri = 1 if act.get('is_primary') else 0
                    
                    if not acc_str:
                        continue
                        
                    if acc_str in existing_accounts:
                        # 已存在则更新密码、邮箱和主号标识
                        cursor.execute('''
                            UPDATE ec_tiktok_accounts 
                            SET password = ?, email = ?, is_primary = ?
                            WHERE device_udid = ? AND account = ?
                        ''', (pwd_str, email_str, is_pri, udid, acc_str))
                    else:
                        # 不存在则新增
                        cursor.execute('''
                            INSERT INTO ec_tiktok_accounts 
                            (device_udid, account, password, email, is_primary, add_time)
                            VALUES (?, ?, ?, ?, ?, ?)
                        ''', (udid, acc_str, pwd_str, email_str, is_pri, now_str))
                
                # 我们选择暂时不自动删除遗失的账号记录（避免误删单独编辑过的状态）
                # 仅将它与该设备的关联清空或者留档。为保持独立管理，我们什么也不做。
                
            conn.commit()
            return True
    except Exception as e:
        logger.error(f"Error setting config for {udid}: {e}")
        return False

# ================= 脚本任务管理 (ECMAIN 自动获取) =================

def get_all_scripts() -> List[dict]:
    """获取所有全局自动脚本"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('SELECT id, name, code, country, group_name, exec_time, updated_at FROM ec_scripts ORDER BY created_at ASC')
            return [dict(r) for r in cursor.fetchall()]
    except Exception as e:
        logger.error(f"Error getting scripts: {e}")
        return []

def create_script(name: str, code: str, country: str = "", group_name: str = "", exec_time: str = "") -> int:
    """新增全局自动脚本"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            now = time.time()
            cursor.execute('''
                INSERT INTO ec_scripts (name, code, country, group_name, exec_time, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            ''', (name, code, country, group_name, exec_time, now, now))
            conn.commit()
            return cursor.lastrowid
    except Exception as e:
        logger.error(f"Error creating script: {e}")
        return 0

def update_script(script_id: int, name: str, code: str, country: str = "", group_name: str = "", exec_time: str = "") -> bool:
    """更新全局自动脚本"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('''
                UPDATE ec_scripts SET name = ?, code = ?, country = ?, group_name = ?, exec_time = ?, updated_at = ?
                WHERE id = ?
            ''', (name, code, country, group_name, exec_time, time.time(), script_id))
            conn.commit()
            return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Error updating script {script_id}: {e}")
        return False

def update_device_task_status(udid: str, task_status_json: str) -> bool:
    """实时更新设备的详细任务日志（写入独立的 task_report 字段，不会被心跳覆盖）"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('''
                UPDATE ec_devices SET task_report = ?
                WHERE udid = ?
            ''', (task_status_json, udid))
            conn.commit()
            return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Error updating task report for {udid}: {e}")
        return False

def delete_script(script_id: int) -> bool:
    """删除某全局自动脚本"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM ec_scripts WHERE id = ?', (script_id,))
            conn.commit()
            return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Error deleting script {script_id}: {e}")

# ================= 配置中心字典维护 =================

def get_all_countries() -> List[dict]:
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('SELECT id, name FROM ec_countries ORDER BY name ASC')
            return [dict(r) for r in cursor.fetchall()]
    except Exception as e:
        logger.error(f"Error getting countries: {e}")
        return []

def add_country(name: str) -> bool:
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('INSERT INTO ec_countries (name) VALUES (?)', (name,))
            conn.commit()
            return True
    except sqlite3.IntegrityError:
        return False
    except Exception as e:
        logger.error(f"Error adding country: {e}")
        return False

def delete_country(country_id: int):
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM ec_countries WHERE id = ?', (country_id,))
            conn.commit()
    except Exception as e:
        logger.error(f"Error deleting country {country_id}: {e}")

def get_all_groups() -> List[dict]:
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('SELECT id, name FROM ec_groups ORDER BY name ASC')
            return [dict(r) for r in cursor.fetchall()]
    except Exception as e:
        logger.error(f"Error getting groups: {e}")
        return []

def add_group(name: str) -> bool:
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('INSERT INTO ec_groups (name) VALUES (?)', (name,))
            conn.commit()
            return True
    except sqlite3.IntegrityError:
        return False
    except Exception as e:
        logger.error(f"Error adding group: {e}")
        return False

def delete_group(group_id: int):
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM ec_groups WHERE id = ?', (group_id,))
            conn.commit()
    except Exception as e:
        logger.error(f"Error deleting group {group_id}: {e}")

def get_all_exec_times() -> List[dict]:
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('SELECT id, name FROM ec_exec_times ORDER BY CAST(name AS INTEGER) ASC')
            return [dict(r) for r in cursor.fetchall()]
    except Exception as e:
        logger.error(f"Error getting exec times: {e}")
        return []

def add_exec_time(name: str) -> bool:
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('INSERT INTO ec_exec_times (name) VALUES (?)', (name,))
            conn.commit()
            return True
    except sqlite3.IntegrityError:
        return False
    except Exception as e:
        logger.error(f"Error adding exec time: {e}")
        return False

def delete_exec_time(time_id: int):
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM ec_exec_times WHERE id = ?', (time_id,))
            conn.commit()
    except Exception as e:
        logger.error(f"Error deleting exec time {time_id}: {e}")
        return False

# ================= 评论数据维护 =================

def get_all_comments(limit: int = 20000, language: str = None) -> List[dict]:
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            if language:
                cursor.execute('SELECT id, language, content, created_at FROM ec_comments WHERE language = ? ORDER BY created_at DESC LIMIT ?', (language, limit))
            else:
                cursor.execute('SELECT id, language, content, created_at FROM ec_comments ORDER BY created_at DESC LIMIT ?', (limit,))
            return [dict(r) for r in cursor.fetchall()]
    except Exception as e:
        logger.error(f"Error getting comments: {e}")
        return []

def add_comment(language: str, content: str) -> bool:
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('INSERT INTO ec_comments (language, content, created_at) VALUES (?, ?, ?)', (language, content, time.time()))
            conn.commit()
            return True
    except Exception as e:
        logger.error(f"Error adding comment: {e}")
        return False

def delete_comment(comment_id: int):
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM ec_comments WHERE id = ?', (comment_id,))
            conn.commit()
    except Exception as e:
        logger.error(f"Error deleting comment {comment_id}: {e}")

def get_random_comments(language: str = None, limit: int = 50) -> List[dict]:
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            query = "SELECT id, language, content, created_at FROM ec_comments"
            params = []
            if language:
                query += " WHERE language = ?"
                params.append(language)
            query += " ORDER BY RANDOM() LIMIT ?"
            params.append(limit)
            cursor.execute(query, tuple(params))
            return [dict(r) for r in cursor.fetchall()]
    except Exception as e:
        logger.error(f"Error getting random comments: {e}")
        return []

# ================= TikTok 账号独立管理维护 =================

def get_all_tiktok_accounts() -> List[dict]:
    """获取目前独立管理的全部 TikTok 账号列表及它们的设备关联号"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            # 联表拿 device_no
            cursor.execute('''
                SELECT t.*, d.device_no, d.country as device_country
                FROM ec_tiktok_accounts t
                LEFT JOIN ec_devices d ON t.device_udid = d.udid
                ORDER BY t.id DESC
            ''')
            return [dict(r) for r in cursor.fetchall()]
    except Exception as e:
        logger.error(f"Error getting tiktok accounts: {e}")
        return []

def update_tiktok_account(account_id: int, country: str, fans_count: int, is_for_sale: int, is_window_opened: int, add_time: str, window_open_time: str, sale_time: str, password: str = "", email: str = "") -> bool:
    """更新独立维护的 TikTok 账号全部属性"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            
            # 如果传入国家为空，则尝试自动锁定关联设备的国家
            if not country:
                cursor.execute('SELECT d.country FROM ec_devices d JOIN ec_tiktok_accounts t ON d.udid = t.device_udid WHERE t.id = ?', (account_id,))
                row = cursor.fetchone()
                if row:
                    country = row[0] or ""

            cursor.execute('''
                UPDATE ec_tiktok_accounts 
                SET country = ?, fans_count = ?, is_for_sale = ?, is_window_opened = ?,
                    add_time = ?, window_open_time = ?, sale_time = ?,
                    password = ?, email = ?
                WHERE id = ?
            ''', (country, fans_count, is_for_sale, is_window_opened, add_time, window_open_time, sale_time, password, email, account_id))
            conn.commit()
            return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Error updating tiktok account {account_id}: {e}")
        return False

def create_tiktok_account(device_udid: str, account: str, password: str = "", email: str = "", country: str = "", fans_count: int = 0, is_for_sale: int = 0, is_window_opened: int = 0) -> int:
    """手动创建一条 TikTok 账号记录"""
    try:
        import datetime
        now_str = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('''
                INSERT INTO ec_tiktok_accounts 
                (device_udid, account, password, email, country, fans_count, is_for_sale, is_window_opened, add_time)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (device_udid, account, password, email, country, fans_count, is_for_sale, is_window_opened, now_str))
            conn.commit()
            return cursor.lastrowid
    except Exception as e:
        logger.error(f"Error creating tiktok account for {device_udid}: {e}")
        return 0

def set_tiktok_account_primary(account_id: int) -> bool:
    """设置某账号为所属设备的主号（排他性设置）"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            # 1. 获取该账号关联的设备 UDID
            cursor.execute('SELECT device_udid FROM ec_tiktok_accounts WHERE id = ?', (account_id,))
            row = cursor.fetchone()
            if not row:
                return False
            udid = row[0]
            
            # 2. 开启事务：取消该设备所有其他账号的主号标识，然后设置当前账号
            cursor.execute('UPDATE ec_tiktok_accounts SET is_primary = 0 WHERE device_udid = ?', (udid,))
            cursor.execute('UPDATE ec_tiktok_accounts SET is_primary = 1 WHERE id = ?', (account_id,))
            
            conn.commit()
            return True
    except Exception as e:
        logger.error(f"Error setting primary tiktok account {account_id}: {e}")
        return False

def delete_tiktok_account(account_id: int) -> bool:
    """删除某条独立维护的 TikTok 账号"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            
            # 由于可能涉及到需要同步回终端设备的 tiktok_accounts (如果设备存活)
            # 在这里我们做纯表面的软剔除，因为 set_device_config 时我们只新增。
            
            cursor.execute('DELETE FROM ec_tiktok_accounts WHERE id = ?', (account_id,))
            conn.commit()
            return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Error deleting tiktok account {account_id}: {e}")
        return False

# ================= 管理员权限系统 =================

import hashlib
import os as _os

def _hash_password(password: str, salt: str) -> str:
    """使用 SHA256 + 盐值对密码进行哈希"""
    return hashlib.sha256((password + salt).encode()).hexdigest()

def verify_admin_login(username: str, password: str) -> dict:
    """校验管理员登录，成功返回用户信息字典，失败返回 None"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('SELECT * FROM ec_admins WHERE username = ?', (username,))
            row = cursor.fetchone()
            if row:
                d = dict(row)
                expected = _hash_password(password, d['salt'])
                if expected == d['password_hash']:
                    return {"id": d['id'], "username": d['username'], "role": d['role']}
    except Exception as e:
        logger.error(f"Error verifying admin login: {e}")
    return None

def get_all_admins() -> List[dict]:
    """获取所有管理员列表（不含密码哈希）"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('SELECT id, username, role, created_at FROM ec_admins ORDER BY id ASC')
            return [dict(r) for r in cursor.fetchall()]
    except Exception as e:
        logger.error(f"Error getting admins: {e}")
        return []

def get_admin_by_id(admin_id: int) -> dict:
    """根据 ID 获取管理员信息"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('SELECT id, username, role, created_at FROM ec_admins WHERE id = ?', (admin_id,))
            row = cursor.fetchone()
            if row:
                return dict(row)
    except Exception as e:
        logger.error(f"Error getting admin {admin_id}: {e}")
    return None

def create_admin(username: str, password: str, role: str = 'admin') -> int:
    """创建管理员，返回新用户 ID，失败返回 0"""
    try:
        salt = _os.urandom(16).hex()
        pw_hash = _hash_password(password, salt)
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('''
                INSERT INTO ec_admins (username, password_hash, salt, role, created_at)
                VALUES (?, ?, ?, ?, ?)
            ''', (username, pw_hash, salt, role, time.time()))
            conn.commit()
            return cursor.lastrowid
    except sqlite3.IntegrityError:
        return 0  # 用户名重复
    except Exception as e:
        logger.error(f"Error creating admin: {e}")
        return 0

def update_admin_password(admin_id: int, new_password: str) -> bool:
    """更新管理员密码"""
    try:
        salt = _os.urandom(16).hex()
        pw_hash = _hash_password(new_password, salt)
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('''
                UPDATE ec_admins SET password_hash = ?, salt = ? WHERE id = ?
            ''', (pw_hash, salt, admin_id))
            conn.commit()
            return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Error updating admin password: {e}")
        return False

def delete_admin(admin_id: int) -> bool:
    """删除管理员及其设备分配记录"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM ec_admin_devices WHERE admin_id = ?', (admin_id,))
            cursor.execute('DELETE FROM ec_admins WHERE id = ?', (admin_id,))
            conn.commit()
            return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Error deleting admin {admin_id}: {e}")
        return False

def get_admin_devices(admin_id: int) -> List[str]:
    """获取管理员所属设备的 UDID 列表"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('SELECT device_udid FROM ec_admin_devices WHERE admin_id = ?', (admin_id,))
            return [row[0] for row in cursor.fetchall()]
    except Exception as e:
        logger.error(f"Error getting admin devices: {e}")
        return []

def assign_device_to_admin(admin_id: int, device_udid: str) -> bool:
    """将设备分配给管理员"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('''
                INSERT OR IGNORE INTO ec_admin_devices (admin_id, device_udid)
                VALUES (?, ?)
            ''', (admin_id, device_udid))
            conn.commit()
            return True
    except Exception as e:
        logger.error(f"Error assigning device: {e}")
        return False

def remove_device_from_admin(admin_id: int, device_udid: str) -> bool:
    """取消管理员的设备分配"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM ec_admin_devices WHERE admin_id = ? AND device_udid = ?', (admin_id, device_udid))
            conn.commit()
            return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Error removing device from admin: {e}")
        return False

def get_device_admin_map() -> dict:
    """批量获取 设备UDID -> 管理员用户名 的映射字典"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT d.device_udid, a.username 
                FROM ec_admin_devices d 
                JOIN ec_admins a ON d.admin_id = a.id
            ''')
            return {row[0]: row[1] for row in cursor.fetchall()}
    except Exception as e:
        logger.error(f"Error getting device admin map: {e}")
        return {}

# ================= 一次性任务管理 =================

def create_oneshot_tasks(udids: List[str], name: str, code: str) -> int:
    """批量创建一次性任务（每个 UDID 一条记录）"""
    created = 0
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            now = time.time()
            for udid in udids:
                cursor.execute('''
                    INSERT INTO ec_oneshot_tasks (udid, name, code, status, created_at)
                    VALUES (?, ?, ?, 'pending', ?)
                ''', (udid, name, code, now))
                created += 1
            conn.commit()
    except Exception as e:
        logger.error(f"Error creating oneshot tasks: {e}")
    return created

def get_oneshot_task(udid: str) -> dict:
    """查询指定设备的待执行一次性任务（按创建时间取最早的一条）"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('''
                SELECT id, udid, name, code, status, created_at 
                FROM ec_oneshot_tasks 
                WHERE udid = ? AND status = 'pending'
                ORDER BY created_at ASC LIMIT 1
            ''', (udid,))
            row = cursor.fetchone()
            if row:
                return dict(row)
    except Exception as e:
        logger.error(f"Error getting oneshot task for {udid}: {e}")
    return None

def complete_oneshot_task(task_id: int) -> bool:
    """完成一次性任务（直接删除记录）"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM ec_oneshot_tasks WHERE id = ?', (task_id,))
            conn.commit()
            return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Error completing oneshot task {task_id}: {e}")
        return False

def get_all_oneshot_tasks() -> List[dict]:
    """获取所有一次性任务（供控制中心管理页面展示）"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute('''
                SELECT t.*, d.device_no
                FROM ec_oneshot_tasks t
                LEFT JOIN ec_devices d ON t.udid = d.udid
                ORDER BY t.created_at DESC
            ''')
            return [dict(r) for r in cursor.fetchall()]
    except Exception as e:
        logger.error(f"Error getting all oneshot tasks: {e}")
        return []

def delete_oneshot_task(task_id: int) -> bool:
    """手动删除一次性任务"""
    try:
        with sqlite3.connect(DB_PATH, timeout=5) as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM ec_oneshot_tasks WHERE id = ?', (task_id,))
            conn.commit()
            return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Error deleting oneshot task {task_id}: {e}")
        return False

# 初始化数据库
init_db()

from pydantic import BaseModel, ValidationError
import json

class HeartbeatRequest(BaseModel):
    udid: str
    device_no: str = ""
    status: str
    local_ip: str
    battery_level: int = 0
    app_version: int = 0
    ecwda_version: int = -1
    vpn_active: bool = False
    vpn_ip: str = ""
    ecwda_status: str = "offline"
    config_checksum: str = ""
    task_status: str = ""
    admin_username: str = ""

payload = {
    "udid": "00008101-00123456789ABCDE",
    "device_no": "A001",
    "status": "online",
    "local_ip": "192.168.1.100",
    "battery_level": 80.,
    "app_version": 20231024,
    "ecwda_version": 100,
    "vpn_active": 1,
    "vpn_ip": "",
    "ecwda_status": "online",
    "config_checksum": "",
    "task_status": "{}",
    "admin_username": ""
}

try:
    req = HeartbeatRequest(**payload)
    print("Success:", req.dict())
except ValidationError as e:
    print("Parsing Error:", e)

from fastapi import APIRouter, HTTPException, Depends
from app.models import Device, Task, User
from app.core import auth
from pydantic import BaseModel
from typing import Optional
from datetime import datetime, timezone

router = APIRouter()

class DeviceHeartbeat(BaseModel):
    udid: str
    status: str = "online" # online, busy, offline
    local_ip: Optional[str] = None
    battery_level: Optional[int] = None

class TaskResult(BaseModel):
    task_id: int
    status: str # success, failed
    result: str # JSON string or text

@router.post("/heartbeat")
async def heartbeat(data: DeviceHeartbeat):
    """
    Device sends heartbeat. 
    1. Update device status/IP.
    2. Check for pending tasks.
    3. Return task if exists.
    """
    # Find or Create Device associated with User
    device = await Device.filter(udid=data.udid).first()
    if not device:
        # Auto register device (Unassigned)
        device = await Device.create(udid=data.udid, name=f"Device-{data.udid[:6]}")
    else:
        # Existing device logic
        pass

    # Update Status
    device.status = data.status
    device.local_ip = data.local_ip
    device.last_heartbeat = datetime.utcnow()
    await device.save()

    # Check for Pending Tasks
    # FIFO: Get oldest pending task
    task = await Task.filter(device=device, status="pending").order_by("created_at").first()
    
    if task:
        task.status = "running" # Mark as sent
        await task.save()
        
        # Prepare Task Payload
        response = {
            "status": "ok",
            "task": {
                "id": task.id,
                "type": task.type,
                "payload": task.payload,
                "script": (await task.script).content if task.script else None
            }
        }
        return response

    return {"status": "ok", "message": "No tasks"}

@router.get("/list")
async def list_devices(user: User = Depends(auth.get_current_user)):
    """
    Get list of devices. 
    Admin sees all, User sees own.
    """
    if user.role == "admin":
        devices = await Device.all().order_by("-last_heartbeat")
    else:
        devices = await Device.filter(owner=user).order_by("-last_heartbeat")
    
    # Enrich with computed status if needed
    result = []
    now = datetime.now(timezone.utc)
    for d in devices:
        # Check offline status based on heartbeat > 60s
        status = d.status
        if d.last_heartbeat:
            # Handle Mixed Naive/Aware
            last_hb = d.last_heartbeat
            if last_hb.tzinfo is None:
                 last_hb = last_hb.replace(tzinfo=timezone.utc)
            
            if (now - last_hb).total_seconds() > 60:
                status = "offline"
        
        result.append({
            "id": d.id,
            "name": d.name,
            "udid": d.udid,
            "status": status,
            "local_ip": d.local_ip,
            "last_heartbeat": d.last_heartbeat.strftime("%Y-%m-%d %H:%M:%S") if d.last_heartbeat else "Never"
        })
    return result

@router.post("/report_task")
async def report_task(result: TaskResult):
    task = await Task.get_or_none(id=result.task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
        
    task.status = result.status
    task.result = result.result
    task.finished_at = datetime.utcnow()
    await task.save()
    
    # Update Device Status back to online (idle)
    device = await task.device
    device.status = "online"
    await device.save()
    
    return {"status": "ok"}

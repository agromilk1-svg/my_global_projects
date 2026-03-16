from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from tortoise.contrib.fastapi import register_tortoise
from app.core import config
from app.routers import auth, devices, tunnel
from app.models import User
from app.core import auth as auth_utils

app = FastAPI(title=config.settings.PROJECT_NAME, version=config.settings.VERSION)
templates = Jinja2Templates(directory="cloud_control/app/templates")

# Include Routers
app.include_router(auth.router, prefix="/auth", tags=["auth"])
app.include_router(devices.router, prefix="/devices", tags=["devices"])
app.include_router(tunnel.router, prefix="/tunnel", tags=["tunnel"])

# Database Init (Must be before startup event if we want to rely on it, 
# BUT register_tortoise injects its own startup handler. 
# To be safe, we use register_tortoise, and since we need data seeding,
# we might need to use a separate lifecycle or ensure ordering.
# FastAPI runs startup events in order of registration.
# We will register tortoise FIRST, then our seeder.)

register_tortoise(
    app,
    db_url=config.settings.DB_URL,
    modules={"models": ["app.models"]},
    generate_schemas=True,
    add_exception_handlers=True,
)

@app.on_event("startup")
async def startup_event():
    # Seed Admin User
    # Since register_tortoise runs on startup, and we registered it above,
    # it should run before this function.
    try:
        admin_user = await User.filter(username="admin").first()
        if not admin_user:
            print("Creating default admin user...")
            hashed_password = auth_utils.get_password_hash("admin")
            await User.create(username="admin", password_hash=hashed_password, role="admin")
        else:
            print("Admin user already exists.")
    except Exception as e:
        print(f"Error seeding admin user: {e}")

@app.get("/", response_class=HTMLResponse)
def read_root(request: Request):
    return templates.TemplateResponse("admin.html", {"request": request})

# --- Stream Proxy for Real-time Mirroring ---
import requests
from fastapi.responses import StreamingResponse

# Global set to track UDIDs that should stop streaming
stop_streams: set = set()

@app.post("/proxy/stop_stream")
async def stop_stream_endpoint(udid: str):
    """Explicitly stop streaming for a device"""
    stop_streams.add(udid)
    print(f"[Stream] Stop requested for {udid}")
    return {"status": "ok"}

@app.get("/proxy/stream")
async def stream_proxy(request: Request, url: str, udid: str = None, mode: str = "screenshot"):
    """
    Proxy stream to browser. Uses screenshot polling for both modes.
    mode: 'mjpeg' = fast polling (~10 FPS), 'screenshot' = normal polling (~5 FPS)
    """
    import time
    import base64
    import asyncio
    from urllib.parse import urlparse

    # 0. Check Tunnel (Priority)
    if udid and tunnel.is_device_connected(udid):
        
        # Both modes use screenshot polling now (MJPEG tunnel forwarding is disabled
        # due to iOS NSURLSession threading issues that cause crashes)
        # MJPEG mode just uses faster polling
        fps_target = 10 if mode == "mjpeg" else 5
        frame_interval = 1.0 / fps_target
        
        async def tunnel_screenshot_gen():
            disconnect_count = 0
            while True:
                # Check explicit stop request from frontend
                if udid in stop_streams:
                    stop_streams.discard(udid)
                    print(f"[Stream] Stopped by frontend request for {udid}")
                    break

                if await request.is_disconnected():
                    print(f"Client disconnected for {udid}, stopping stream")
                    break

                # Check if device is still connected
                if not tunnel.is_device_connected(udid):
                    print(f"Device {udid} disconnected, stopping stream")
                    break
                
                try:
                    start = time.time()
                    # Request Screenshot via Tunnel
                    resp = await tunnel.forward_request(udid, "GET", "http://127.0.0.1:10088/screenshot")
                    
                    if resp.get("status") == 200:
                        disconnect_count = 0  # Reset on success
                        body = resp.get("body")
                        img_b64 = body.get("value") if isinstance(body, dict) else None
                        
                        if img_b64:
                            img = base64.b64decode(img_b64)
                            yield (b'--frame\r\n'
                                   b'Content-Type: image/jpeg\r\n\r\n' + img + b'\r\n')
                    else:
                        disconnect_count += 1

                    elapsed = time.time() - start
                    # Control FPS
                    if elapsed < frame_interval: 
                        await asyncio.sleep(frame_interval - elapsed)
                except asyncio.CancelledError:
                    print(f"Stream cancelled for {udid}")
                    break
                except Exception as e:
                    print(f"Tunnel screenshot error: {e}")
                    disconnect_count += 1
                    if disconnect_count > 5:
                        print(f"Too many errors, stopping stream for {udid}")
                        break
                    await asyncio.sleep(1)
        
        return StreamingResponse(tunnel_screenshot_gen(), media_type="multipart/x-mixed-replace;boundary=frame")

    # 1. Try MJPEG Stream (Direct)
    try:
        r = requests.get(url, stream=True, timeout=2)
        if r.status_code == 200:
            return StreamingResponse(
                r.iter_content(chunk_size=8192),
                media_type=r.headers.get("Content-Type", "multipart/x-mixed-replace;boundary=BoundaryString"),
                status_code=r.status_code
            )
    except Exception:
        pass

    # 2. Fallback to Screenshot Shim (Direct)
    if url.endswith("/mjpeg"):
        base = url[:-6] # Strip /mjpeg
        
        def screenshot_gen():
            while True:
                try:
                    start = time.time()
                    resp = requests.get(f"{base}/screenshot", timeout=1)
                    if resp.status_code == 200:
                        data = resp.json().get("value")
                        if data:
                            img = base64.b64decode(data)
                            yield (b'--frame\r\n'
                                   b'Content-Type: image/jpeg\r\n\r\n' + img + b'\r\n')
                    
                    # Cap at ~15 FPS
                    elapsed = time.time() - start
                    if elapsed < 0.06:
                        time.sleep(0.06 - elapsed)
                except Exception:
                    time.sleep(1)

        return StreamingResponse(screenshot_gen(), media_type="multipart/x-mixed-replace;boundary=frame")
        
    return HTMLResponse("Stream unavailable", status_code=500)

@app.post("/proxy/wda")
async def wda_proxy(url: str, payload: dict, udid: str = None):
    """
    Proxy WDA actions. Support Tunnel.
    """
    import asyncio
    
    # 1. Tunnel
    if udid and tunnel.is_device_connected(udid):
        try:
             # Rewrite URL to Localhost for device
             from urllib.parse import urlparse
             parsed = urlparse(url)
             local_url = f"http://127.0.0.1:10088{parsed.path}"
             
             resp = await tunnel.forward_request(udid, "POST", local_url, payload)
             if resp.get("status") == 200:
                 return resp.get("body")
             else:
                 return {"status": "error", "message": f"Tunnel {resp.get('status')}"}
        except Exception as e:
             return {"status": "error", "message": f"Tunnel Exception: {str(e)}"}

    # 2. Direct
    try:
        resp = requests.post(url, json=payload, timeout=2)
        return resp.json()
    except Exception as e:
        return {"status": "error", "message": str(e)}

# ========== WDA Control APIs (Ported from control_center.py) ==========

# Store session IDs per device (in-memory cache)
_wda_sessions = {}

async def _get_or_create_session(udid: str) -> str:
    """Get existing WDA session or create new one via tunnel"""
    if udid in _wda_sessions:
        return _wda_sessions[udid]
    
    # Create new session
    try:
        resp = await tunnel.forward_request(udid, "POST", "http://127.0.0.1:10088/session", {
            "capabilities": {}
        })
        if resp.get("status") == 200:
            body = resp.get("body", {})
            session_id = body.get("sessionId") or body.get("value", {}).get("sessionId")
            if session_id:
                _wda_sessions[udid] = session_id
                print(f"[WDA] Created session {session_id} for {udid}")
                return session_id
    except Exception as e:
        print(f"[WDA] Session creation error: {e}")
    
    # Fallback - try status to get existing session
    try:
        resp = await tunnel.forward_request(udid, "GET", "http://127.0.0.1:10088/status", None)
        if resp.get("status") == 200:
            body = resp.get("body", {})
            session_id = body.get("sessionId")
            if session_id:
                _wda_sessions[udid] = session_id
                return session_id
    except:
        pass
    
    return None

@app.post("/wda/tap")
async def wda_tap(udid: str, x: int, y: int):
    """Tap at coordinates using W3C Actions API"""
    if not tunnel.is_device_connected(udid):
        return {"status": "error", "message": "Device not connected via tunnel"}
    
    session_id = await _get_or_create_session(udid)
    if not session_id:
        return {"status": "error", "message": "Could not get WDA session"}
    
    actions = {
        "actions": [
            {
                "type": "pointer",
                "id": "finger1",
                "parameters": {"pointerType": "touch"},
                "actions": [
                    {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                    {"type": "pointerDown", "button": 0},
                    {"type": "pause", "duration": 50},
                    {"type": "pointerUp", "button": 0}
                ]
            }
        ]
    }
    
    try:
        resp = await tunnel.forward_request(
            udid, "POST", 
            f"http://127.0.0.1:10088/session/{session_id}/actions",
            actions
        )
        return {"status": "ok", "response": resp}
    except Exception as e:
        return {"status": "error", "message": str(e)}

@app.post("/wda/swipe")
async def wda_swipe(udid: str, from_x: int, from_y: int, to_x: int, to_y: int, duration: int = 250):
    """Swipe from one point to another using W3C Actions API"""
    if not tunnel.is_device_connected(udid):
        return {"status": "error", "message": "Device not connected via tunnel"}
    
    session_id = await _get_or_create_session(udid)
    if not session_id:
        return {"status": "error", "message": "Could not get WDA session"}
    
    actions = {
        "actions": [
            {
                "type": "pointer",
                "id": "finger1",
                "parameters": {"pointerType": "touch"},
                "actions": [
                    {"type": "pointerMove", "duration": 0, "x": from_x, "y": from_y},
                    {"type": "pointerDown", "button": 0},
                    {"type": "pause", "duration": 10},
                    {"type": "pointerMove", "duration": duration, "x": to_x, "y": to_y},
                    {"type": "pointerUp", "button": 0}
                ]
            }
        ]
    }
    
    try:
        resp = await tunnel.forward_request(
            udid, "POST",
            f"http://127.0.0.1:10088/session/{session_id}/actions",
            actions
        )
        return {"status": "ok", "response": resp}
    except Exception as e:
        return {"status": "error", "message": str(e)}

@app.post("/wda/home")
async def wda_home(udid: str):
    """Press home button"""
    if not tunnel.is_device_connected(udid):
        return {"status": "error", "message": "Device not connected via tunnel"}
    
    try:
        resp = await tunnel.forward_request(udid, "POST", "http://127.0.0.1:10088/wda/homescreen", {})
        return {"status": "ok", "response": resp}
    except Exception as e:
        return {"status": "error", "message": str(e)}

@app.get("/wda/status")
async def wda_status(udid: str):
    """Get WDA status"""
    if not tunnel.is_device_connected(udid):
        return {"status": "error", "message": "Device not connected via tunnel", "connected": False}
    
    try:
        resp = await tunnel.forward_request(udid, "GET", "http://127.0.0.1:10088/status", None)
        return {"status": "ok", "connected": True, "wda": resp.get("body")}
    except Exception as e:
        return {"status": "error", "message": str(e), "connected": False}


import uvicorn
from fastapi import FastAPI, HTTPException, WebSocket, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import requests
import asyncio
import json
import logging
import time

# Logging Setup
logging.basicConfig(level=logging.INFO, format='[WebControl] %(message)s')
logger = logging.getLogger("WebControl")

app = FastAPI()

# Mount Static Files
try:
    app.mount("/static", StaticFiles(directory="web/static"), name="static")
except RuntimeError:
    logger.warning("web/static directory not found, static files will fail.")

templates = Jinja2Templates(directory="web/templates")

# Config
config = {
    "wda_url": "http://192.168.1.5:10088", # Default, changeable via UI
    "ecmain_url": "http://192.168.1.5:8089"
}

@app.get("/", response_class=HTMLResponse)
async def read_root(request: Request):
    return templates.TemplateResponse("index.html", {"request": request, "config": config})

# --- Stream Proxy ---
@app.get("/stream_proxy")
def stream_proxy(url: str = None):
    """
    Proxy MJPEG stream from WDA to Browser.
    This solves Mixed Content and CORS issues for remote access.
    """
    target_url = url if url else f"{config['wda_url']}/mjpeg"
    
    def iter_content():
        try:
            with requests.get(target_url, stream=True, timeout=5) as r:
                r.raise_for_status()
                for chunk in r.iter_content(chunk_size=8192):
                    yield chunk
        except Exception as e:
            logger.error(f"Stream error: {e}")
            # Return a simple error image or just stop
            return

    return StreamingResponse(iter_content(), media_type="multipart/x-mixed-replace;boundary=BoundaryString")

# --- API Endpoints ---

@app.post("/api/config")
async def update_config(data: dict):
    global config
    config.update(data)
    return {"status": "ok", "config": config}

@app.post("/api/wda/tap")
async def wda_tap(x: float, y: float, start_x: float = None, start_y: float = None, duration: float = 0):
    url = f"{config['wda_url']}/session/87309068-3330-4581-8071-700140228028/wda/touch/perform" # Using cached session ID or need manage?
    # Actually standard WDA needs session. We might need to fetch session first.
    # Simplified: Use /wda/tap endpoint if available or compute session
    
    # Better: Use the raw session-less endpoints if WDA supports, or manage session.
    # WDA standard: /statelessTap or manage session
    # Let's try standard touch actions
    
    # Fallback to simple requests if stateless
    # FBWDA: /wda/tap/0
    try:
        # Simple Tap
        if start_x is None: 
            payload = {"x": x, "y": y}
            requests.post(f"{config['wda_url']}/wda/tap/0", json=payload, timeout=2)
            
        # Swipe / Drag
        else:
            payload = {"fromX": start_x, "fromY": start_y, "toX": x, "toY": y, "duration": duration}
            requests.post(f"{config['wda_url']}/wda/dragfromtoforduration", json=payload, timeout=2)
            
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

@app.post("/api/wda/home")
async def wda_home():
    try:
        requests.post(f"{config['wda_url']}/wda/homescreen", timeout=2)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

@app.post("/api/ecmain/vpn")
async def ecmain_vpn(payload: dict):
    try:
        url = f"{config['ecmain_url']}/task"
        data = {"type": "VPN", "payload": payload}
        requests.post(url, json=data, timeout=5)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": str(e)}
        
@app.post("/api/ecmain/script")
async def ecmain_script(script: str):
    try:
        url = f"{config['ecmain_url']}/task"
        data = {"type": "SCRIPT", "payload": script}
        requests.post(url, json=data, timeout=5)
        return {"status": "ok"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8088)

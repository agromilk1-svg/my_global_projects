import asyncio
import uuid
import json
import base64
from typing import Dict, Optional, Any
from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from starlette.websockets import WebSocketState

router = APIRouter()

class TunnelManager:
    def __init__(self):
        # udid -> WebSocket
        self.active_connections: Dict[str, WebSocket] = {}
        # request_id -> Future
        self.pending_requests: Dict[str, asyncio.Future] = {}
        # udid -> List[asyncio.Queue]
        self.stream_queues: Dict[str, list] = {}

    async def connect(self, websocket: WebSocket, udid: str):
        await websocket.accept()
        self.active_connections[udid] = websocket
        print(f"[Tunnel] Device connected: {udid}")

    def disconnect(self, udid: str):
        if udid in self.active_connections:
            del self.active_connections[udid]
            print(f"[Tunnel] Device disconnected: {udid}")

    async def send_request(self, udid: str, method: str, url: str, json_body: Any = None) -> Dict:
        """
        Send HTTP-like request over WebSocket Tunnel and wait for response.
        """
        if udid not in self.active_connections:
            print(f"[Tunnel] Error: Device {udid} not connected for request {method}")
            raise Exception(f"Device {udid} not connected via Tunnel")
        
        ws = self.active_connections[udid]
        if ws.client_state != WebSocketState.CONNECTED:
             self.disconnect(udid)
             raise Exception("Device WS disconnected")

        req_id = str(uuid.uuid4())
        future = asyncio.get_event_loop().create_future()
        self.pending_requests[req_id] = future

        # Payload to Device
        msg = {
            "id": req_id,
            "type": "request",
            "method": method,
            "url": url, 
            "body": json_body
        }

        print(f"[Tunnel] Sending request {method} to {udid} (id: {req_id})")

        try:
            await ws.send_json(msg)
            # Wait for response (timeout 10s for WDA)
            response = await asyncio.wait_for(future, timeout=10.0)
            return response
        except asyncio.TimeoutError:
            print(f"[Tunnel] Request {req_id} timed out")
            if req_id in self.pending_requests:
                del self.pending_requests[req_id]
            raise Exception("Tunnel request timeout")
        except Exception as e:
            print(f"[Tunnel] Request {req_id} failed: {e}")
            if req_id in self.pending_requests:
                del self.pending_requests[req_id]
            raise e

    def handle_response(self, data: Dict):
        """Handle incoming response from device"""
        req_id = data.get("id")
        if req_id and req_id in self.pending_requests:
            future = self.pending_requests.pop(req_id)
            if not future.done():
                future.set_result(data)

    def broadcast_stream(self, udid: str, data: Dict):
        """Broadcast stream frame to all subscribers"""
        if udid in self.stream_queues:
            # frame payload: {"value": "base64.."} or raw bytes
            body = data.get("body")
            if body:
                for q in self.stream_queues[udid]:
                    # Use nowait to avoid blocking if consumer is slow
                    try:
                        q.put_nowait(body)
                    except asyncio.QueueFull:
                        pass # Drop frame

    async def subscribe_stream(self, udid: str) -> asyncio.Queue:
        """Subscribe to MJPEG stream for a device"""
        if udid not in self.stream_queues:
            self.stream_queues[udid] = []
        
        q = asyncio.Queue(maxsize=10) # Drop old frames if slow
        self.stream_queues[udid].append(q)
        
        count = len(self.stream_queues[udid])
        print(f"[Tunnel] Subscribe stream for {udid}. Subscribers: {count}")

        # Always try to start stream if it's the first one, or just force it for debugging
        if count >= 1:
             try:
                 target_ip = "127.0.0.1"
                 if udid in self.active_connections:
                     ws = self.active_connections[udid]
                     if ws.client and ws.client.host:
                         target_ip = ws.client.host
                 
                 target_url = f"http://{target_ip}:10089/mjpeg"
                 print(f"[Tunnel] Dispatching START_STREAM to {udid} using URL: {target_url}")
                 await self.send_request(udid, "START_STREAM", target_url)
             except Exception as e:
                 print(f"[Tunnel] Start stream error: {e}")

        return q

    async def unsubscribe_stream(self, udid: str, q: asyncio.Queue):
        """Unsubscribe"""
        if udid in self.stream_queues:
            if q in self.stream_queues[udid]:
                self.stream_queues[udid].remove(q)
            
            # If no more subscribers, STOP_STREAM
            if not self.stream_queues[udid]:
                del self.stream_queues[udid]
                try:
                    await self.send_request(udid, "STOP_STREAM", "http://127.0.0.1:10089/mjpeg")
                except Exception as e:
                    print(f"[Tunnel] Stop stream error: {e}")

manager = TunnelManager()

@router.websocket("/ws/{udid}")
async def websocket_endpoint(websocket: WebSocket, udid: str):
    await manager.connect(websocket, udid)
    try:
        while True:
            data = await websocket.receive_json()
            msg_type = data.get("type")
            
            if msg_type == "response":
                manager.handle_response(data)
            elif msg_type == "stream":
                manager.broadcast_stream(udid, data)
            else:
                pass
    except WebSocketDisconnect:
        manager.disconnect(udid)
    except Exception as e:
        print(f"[Tunnel] Error {udid}: {e}")
        manager.disconnect(udid)

# Helper to verify if device is tunneled
def is_device_connected(udid: str) -> bool:
    return udid in manager.active_connections

# Helper for other routers to use
async def forward_request(udid: str, method: str, url: str, json_body: Any = None):
    return await manager.send_request(udid, method, url, json_body)

# Stream helpers
async def get_stream_queue(udid: str):
    return await manager.subscribe_stream(udid)

async def release_stream_queue(udid: str, q: asyncio.Queue):
    await manager.unsubscribe_stream(udid, q)

import socket
import time
import requests

IP = '192.168.110.249'
PORT_HTTP = 10088
PORT_MJPEG = 10089

def check_tcp(port):
    try:
        s = socket.create_connection((IP, port), timeout=1)
        s.close()
        return True
    except Exception:
        return False

def check_http():
    try:
        r = requests.get(f"http://{IP}:{PORT_HTTP}/status", timeout=1)
        return r.status_code == 200
    except Exception:
        return False

print(">>> 开始持续监控 WDA 10088 及 10089 存亡状态 (每秒轮询一次) <<<")
print("请在系统上将 ECWDA 切换到完全后台！")

for i in range(120):
    tcp_10088 = check_tcp(PORT_HTTP)
    http_10088 = check_http()
    tcp_10089 = check_tcp(PORT_MJPEG)
    
    print(f"[{i:03d}] 10088 TCP: {'🟢' if tcp_10088 else '❌'}, 10088 HTTP: {'🟢' if http_10088 else '❌'} | 10089 MJPEG TCP: {'🟢' if tcp_10089 else '❌'}", flush=True)
    time.sleep(1)

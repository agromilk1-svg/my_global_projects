import socket

req = """GET /task HTTP/1.1\r
Host: 127.0.0.1:10089\r
Content-Type: application/json\r
Content-Length: 62\r
Connection: close\r
\r
{"type":"SCRIPT","payload":"if(wda.home()) wda.log('OK123');"}"""

s = socket.socket()
s.connect(('127.0.0.1', 10089))
s.sendall(req.encode('utf-8'))
print(s.recv(4096).decode('utf-8', errors='ignore'))
s.close()

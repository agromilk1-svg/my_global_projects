import socket, struct, plistlib

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("/var/run/lockdown.sock")

req = {
    "Label": "go.ios.control",
    "Request": "QueryType"
}
payload = plistlib.dumps(req, fmt=plistlib.FMT_XML)
sock.sendall(struct.pack(">I", len(payload)) + payload)

length_data = sock.recv(4)
if length_data:
    length = struct.unpack(">I", length_data)[0]
    resp = sock.recv(length)
    print(plistlib.loads(resp))
else:
    print("EOF")

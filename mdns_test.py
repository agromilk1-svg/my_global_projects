import socket
import struct
import select

def build_mdns_query():
    header = struct.pack("!HHHHHH", 0x1234, 0x0000, 1, 0, 0, 0)
    qname = b'\x0e_apple-mobdev2\x04_tcp\x05local\x00'
    qtype = struct.pack("!H", 12)
    qclass = struct.pack("!H", 1)
    return header + qname + qtype + qclass

def scan_mdns():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.bind(('', 5353))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
    
    query = build_mdns_query()
    sock.sendto(query, ('224.0.0.251', 5353))
    print("MDNS Probe Sent. Waiting for response...")
    
    while True:
        ready = select.select([sock], [], [], 2.0)
        if ready[0]:
            data, addr = sock.recvfrom(1024)
            if b'_apple-mobdev' in data:
                print(f"Received MDNS from {addr}: {len(data)} bytes")
                print(''.join(f'{b:02x} ' for b in data))
        else:
            break

if __name__ == "__main__":
    scan_mdns()

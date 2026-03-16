import base64
import json
import urllib.parse
import re
import requests
import yaml

def pad_base64(data):
    missing_padding = len(data) % 4
    if missing_padding:
        data += '=' * (4 - missing_padding)
    return data

def decode_base64_string(s):
    try:
        s = s.replace('-', '+').replace('_', '/')
        return base64.b64decode(pad_base64(s)).decode('utf-8')
    except Exception:
        return ""

def parse_proxy_uri(uri: str) -> dict:
    uri = uri.strip()
    if not uri: return None
    config = {}
    
    try:
        if uri.startswith("vless://"):
            config['type'] = 'VLESS'
            main_part = uri[8:]
            name = "VLESS Node"
            if '#' in main_part:
                main_part, frag = main_part.split('#', 1)
                name = urllib.parse.unquote(frag)
            config['name'] = name
            
            if '?' in main_part:
                main_part, query = main_part.split('?', 1)
                params = dict(urllib.parse.parse_qsl(query))
            else:
                params = {}
                
            if '@' in main_part:
                uuid, server_port = main_part.split('@', 1)
                config['uuid'] = uuid
            else:
                return None
                
            if ':' in server_port:
                server, port = server_port.split(':', 1)
                config['server'] = server
                config['port'] = int(port) if port.isdigit() else 0
                
            config['network'] = params.get('type', 'tcp')
            config['tls'] = (params.get('security') == 'tls')
            if 'sni' in params: config['servername'] = params['sni']
            if 'fp' in params: config['client-fingerprint'] = params['fp']
            if 'flow' in params: config['flow'] = params['flow']
            if params.get('security') == 'reality':
                config['reality-opts'] = {
                    'public-key': params.get('pbk', ''),
                    'short-id': params.get('sid', '')
                }
            return config

        elif uri.startswith("vmess://"):
            config['type'] = 'VMess'
            b64_str = uri[8:]
            json_str = decode_base64_string(b64_str)
            if not json_str: return None
            data = json.loads(json_str)
            config['name'] = data.get('ps', 'VMess Node')
            config['server'] = data.get('add', '')
            config['port'] = int(data.get('port', 0))
            config['uuid'] = data.get('id', '')
            config['alterId'] = int(data.get('aid', 0))
            config['cipher'] = data.get('scy', 'auto')
            config['network'] = data.get('net', 'tcp')
            if data.get('tls') == 'tls': config['tls'] = True
            if data.get('path'): config['ws-path'] = data['path']
            if data.get('host'): config['ws-host'] = data['host']
            return config

        elif uri.startswith("ss://"):
            config['type'] = 'Shadowsocks'
            main_part = uri[5:]
            name = "SS Node"
            if '#' in main_part:
                main_part, frag = main_part.split('#', 1)
                name = urllib.parse.unquote(frag)
            config['name'] = name
            
            if '@' in main_part:
                # SIP002 format
                b64_auth, server_port = main_part.split('@', 1)
                auth_str = decode_base64_string(b64_auth)
            else:
                # Legacy format
                auth_str = decode_base64_string(main_part)
                if '@' in auth_str:
                    auth_str, server_port = auth_str.split('@', 1)
                else:
                    return None
                    
            if ':' in auth_str:
                cipher, pwd = auth_str.split(':', 1)
                config['cipher'] = cipher
                config['password'] = pwd
                
            if ':' in server_port:
                server, port = server_port.split(':', 1)
                config['server'] = server
                config['port'] = int(port) if port.isdigit() else 0
            return config

        elif uri.startswith("trojan://"):
            config['type'] = 'Trojan'
            main_part = uri[9:]
            name = "Trojan Node"
            if '#' in main_part:
                main_part, frag = main_part.split('#', 1)
                name = urllib.parse.unquote(frag)
            config['name'] = name
            
            if '?' in main_part:
                main_part, query = main_part.split('?', 1)
                params = dict(urllib.parse.parse_qsl(query))
            else:
                params = {}
                
            if '@' in main_part:
                pwd, server_port = main_part.split('@', 1)
                config['password'] = pwd
            else:
                return None
                
            if ':' in server_port:
                server, port = server_port.split(':', 1)
                config['server'] = server
                config['port'] = int(port) if port.isdigit() else 0
                
            if 'sni' in params: config['sni'] = params['sni']
            if 'type' in params: config['network'] = params['type']
            return config
            
        elif uri.startswith("socks://"):
            config['type'] = 'Socks5'
            main_part = uri[8:]
            name = "Socks5 Node"
            if '#' in main_part:
                main_part, frag = main_part.split('#', 1)
                name = urllib.parse.unquote(frag)
            config['name'] = name
            
            if '@' in main_part:
                auth, server_port = main_part.split('@', 1)
                if ':' in auth:
                    u, p = auth.split(':', 1)
                    config['user'] = u
                    config['password'] = p
            else:
                server_port = main_part
                
            if ':' in server_port:
                server, port = server_port.split(':', 1)
                config['server'] = server
                config['port'] = int(port) if port.isdigit() else 0
            return config
            
        elif uri.startswith("hysteria2://"):
            config['type'] = 'Hysteria2'
            main_part = uri[12:]
            name = "HY2 Node"
            if '#' in main_part:
                main_part, frag = main_part.split('#', 1)
                name = urllib.parse.unquote(frag)
            config['name'] = name
            
            if '?' in main_part:
                main_part, query = main_part.split('?', 1)
                params = dict(urllib.parse.parse_qsl(query))
            else:
                params = {}
                
            if '@' in main_part:
                pwd, server_port = main_part.split('@', 1)
                config['password'] = pwd
            else:
                return None
                
            if ':' in server_port:
                server, port = server_port.split(':', 1)
                config['server'] = server
                config['port'] = int(port) if port.isdigit() else 0
                
            if 'sni' in params: config['sni'] = params['sni']
            return config
            
        elif uri.startswith("ssr://"):
            config['type'] = 'ShadowsocksR'
            b64_str = uri[6:]
            decoded = decode_base64_string(b64_str)
            if not decoded: return None
            
            parts = decoded.split(':')
            if len(parts) >= 6:
                config['server'] = parts[0]
                config['port'] = int(parts[1]) if parts[1].isdigit() else 0
                config['protocol'] = parts[2]
                config['cipher'] = parts[3]
                config['obfs'] = parts[4]
                
                pass_and_params = parts[5].split('/?')
                config['password'] = decode_base64_string(pass_and_params[0])
                
                if len(pass_and_params) > 1:
                    params = dict(urllib.parse.parse_qsl(pass_and_params[1]))
                    if 'remarks' in params: config['name'] = decode_base64_string(params['remarks'])
                    if 'obfsparam' in params: config['obfs-param'] = decode_base64_string(params['obfsparam'])
                    if 'protoparam' in params: config['protocol-param'] = decode_base64_string(params['protoparam'])
            return config
            
    except Exception as e:
        print(f"Error parsing URI {uri}: {e}")
        return None
        
    return None

def fetch_and_parse(content: str) -> list:
    content = content.strip()
    nodes = []
    
    if content.startswith("ecnode://"):
        try:
            b64_str = content[9:]
            json_str = decode_base64_string(b64_str)
            if json_str:
                data = json.loads(json_str)
                if isinstance(data, list):
                    for p in data:
                        if 'id' not in p:
                            p['id'] = str(abs(hash(p.get('name', 'ECNode'))))
                        p['raw_uri'] = content
                        nodes.append(p)
                elif isinstance(data, dict):
                    if 'id' not in data:
                        data['id'] = str(abs(hash(data.get('name', 'ECNode'))))
                    data['raw_uri'] = content
                    nodes.append(data)
                return nodes
        except Exception as e:
            print(f"Error parsing ecnode URI: {e}")
            pass

    # Is it a URL?
    if content.startswith("http://") or content.startswith("https://"):
        try:
            r = requests.get(content, timeout=10)
            text = r.text.strip()
            # Try to parse as Clash YAML first
            try:
                y = yaml.safe_load(text)
                if isinstance(y, dict) and 'proxies' in y:
                    for p in y['proxies']:
                        # Convert Clash dict to our dict slightly if needed, we'll just pass it down and ECMAIN's JS connectVPN expects standard fields which match Clash mostly.
                        p['id'] = str(abs(hash(p.get('name', ''))))
                        # 如果没有现成的 URI，可以简单利用 base64 打包整个 json （模仿 vmess 或者是自定义）
                        # 这里我们只做一个简单的 fallback 占位，告知用户是通过订阅提取的原始参数
                        import json, base64
                        fallback = "clash://" + base64.b64encode(json.dumps(p).encode('utf-8')).decode('utf-8')
                        p['raw_uri'] = fallback
                        nodes.append(p)
                    return nodes
            except Exception:
                pass
            
            # If not YAML, assume base64
            decoded = decode_base64_string(text)
            if decoded:
                for line in decoded.splitlines():
                    node = parse_proxy_uri(line)
                    if node:
                        node['id'] = str(abs(hash(line)))
                        node['raw_uri'] = line.strip()
                        nodes.append(node)
                return nodes
                
        except Exception as e:
             raise ValueError(f"Failed to fetch or parse subscription: {e}")
             
    else:
        # Check if it's multiple URIs directly
        for line in content.splitlines():
            node = parse_proxy_uri(line)
            if node:
                node['id'] = str(abs(hash(line)))
                node['raw_uri'] = line.strip()
                nodes.append(node)
                
        if not nodes:
            # Maybe it's base64 encoded string directly pasted
            decoded = decode_base64_string(content)
            if decoded:
                for line in decoded.splitlines():
                    node = parse_proxy_uri(line)
                    if node:
                        node['id'] = str(abs(hash(line)))
                        node['raw_uri'] = line.strip()
                        nodes.append(node)
                        
    return nodes

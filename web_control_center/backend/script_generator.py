import base64

def generate_script(actions_data, time_config=None):
    """
    根据传入的纯数据动作列表和全局时间配置，生成完整的 JavaScript 脚本。
    actions_data: [{'type': 'TAP', 'template': '...', 'threshold': 0.8}, ...]
    time_config: {'swipeMin': 50, 'swipeMax': 200, ...}
    """
    if not time_config:
        time_config = {
            'swipeMin': 50, 'swipeMax': 200,
            'longPressMin': 800, 'longPressMax': 1500,
            'waitMin': 1, 'waitMax': 3
        }
    if not actions_data or len(actions_data) == 0:
        return ""

    script = "console.log('Script started');\n\n"

    # Action templates
    action_templates = {
        'TAP': """
            var x = {x};
            var y = {y};
            console.log("Tapping at (" + x + ", " + y + ")");
            wda.tap(x, y);
        """,
        'DOUBLE_TAP': """
            var x = {x};
            var y = {y};
            console.log("Double Tapping at (" + x + ", " + y + ")");
            wda.doubleTap(x, y);
        """,
        'LONG_PRESS': """
            var x = {x};
            var y = {y};
            var dur = {duration};
            console.log("Long pressing at (" + x + ", " + y + ") for " + dur + "s");
            wda.longPress(x, y, dur);
        """,
        'SWIPE': """
            var x1 = {x1}, y1 = {y1}, x2 = {x2}, y2 = {y2};
            var dur = {duration};
            console.log("Swiping from (" + x1 + "," + y1 + ") to (" + x2 + "," + y2 + ")");
            wda.swipe(x1, y1, x2, y2, dur);
        """,
        'SLEEP': """
            var s = {seconds};
            console.log("Sleeping for " + s + "s");
            wda.sleep(s);
        """,
        'FIND_IMAGE': """
            var b64 = "{base64_img}";
            var th = {threshold};
            console.log("Finding image with threshold " + th);
            var res = wda.findImage(b64, th);
            if (res && res.found) {{
                console.log("Found at (" + res.x + ", " + res.y + ")");
            }} else {{
                console.log("Image not found");
            }}
        """,
        'FIND_IMAGE_TAP': """
            var b64 = "{base64_img}";
            var th = {threshold};
            console.log("Finding and tapping image, threshold: " + th);
            var res = wda.findImage(b64, th);
            if (res && res.found) {{
                console.log("Found at (" + res.x + ", " + res.y + "), tapping...");
                wda.tap(res.x + wda.randomInt(0, res.width || 0), res.y + wda.randomInt(0, res.height || 0));
            }} else {{
                console.log("Image not found, skip tap.");
            }}
        """,
        'VPN_HYSTERIA': """
            var config = {config_json};
            console.log("Pushing VPN Configuration to ECMAIN...");
            if (typeof wda.connectVPN === 'function') {{
                wda.connectVPN(config);
            }} else {{
                console.log("Error: wda.connectVPN not found in JSBridge.");
            }}
        """,
        'IS_VPN_CONNECTED': """
            var connected = false;
            if (typeof wda.isVPNConnected === 'function') {{
                connected = wda.isVPNConnected();
                console.log("当前VPN连接状态: " + connected);
            }} else {{
                console.log("Error: wda.isVPNConnected not found in JSBridge. Defaulting to false.");
            }}
        """,
        'NETWORK_CONFIG': """
            var ip = "{ip}";
            var subnet = "{subnet}";
            var gateway = "{gateway}";
            var dns = "{dns}";
            console.log("Setting static IP: " + ip);
            wda.setStaticIP(ip, subnet, gateway, dns);
            wda.sleep(0.5);
            wda.airplaneOn();
            wda.sleep(2.0);
            wda.airplaneOff();
            wda.sleep(1.0);
        """,
        'WIPE_APP': """
            var bundleId = "{bundleId}";
            console.log("Wiping app data for: " + bundleId);
            wda.wipeApp(bundleId);
            wda.sleep(1.0);
        """,
    }

    # Generate code for each action
    for item in actions_data:
        action_type = item.get('type') or item.get('action_type')
        if not action_type:
            continue
            
        script += f"// Action: {action_type}\n"
        
        # Build params
        if action_type == 'TAP':
            x, y = item.get('x', 100), item.get('y', 100)
            script += action_templates[action_type].format(x=x, y=y)
        elif action_type == 'DOUBLE_TAP':
            x, y = item.get('x', 100), item.get('y', 100)
            script += action_templates[action_type].format(x=x, y=y)
        elif action_type == 'LONG_PRESS':
            x, y = item.get('x', 100), item.get('y', 100)
            duration = item.get('duration', (time_config['longPressMin']/1000.0))
            script += action_templates[action_type].format(x=x, y=y, duration=duration)
        elif action_type == 'SWIPE':
            x1, y1 = item.get('x1', 100), item.get('y1', 100)
            x2, y2 = item.get('x2', 200), item.get('y2', 200)
            duration = item.get('duration', (time_config['swipeMin']/1000.0))
            script += action_templates[action_type].format(x1=x1, y1=y1, x2=x2, y2=y2, duration=duration)
        elif action_type == 'SLEEP':
            seconds = item.get('seconds', time_config['waitMin'])
            script += action_templates[action_type].format(seconds=seconds)
        elif action_type in ('FIND_IMAGE', 'FIND_IMAGE_TAP'):
            # 这里必须过滤换行符、确保是纯净的 base64 字符串形式，避免 JS 语法因为换行中断
            raw_b64 = item.get('template', '')
            clean_b64 = str(raw_b64).replace('\\n', '').replace('\\r', '').replace(' ', '+').strip()
            th = item.get('threshold', 0.8)
            script += action_templates[action_type].format(base64_img=clean_b64, threshold=th)
        elif action_type == 'VPN_HYSTERIA':
            import json
            cfg = item.get('config', {})
            # Ensure proper JS serialization
            json_str = json.dumps(cfg, ensure_ascii=False)
            script += action_templates[action_type].format(config_json=json_str)
        elif action_type == 'WIPE_APP':
            bundleId = item.get('bundleId', '')
            script += action_templates[action_type].format(bundleId=bundleId)
        else:
            script += f"// Unsupported action type: {action_type}\n"
            
        script += "\n"

    script += "console.log('Script finished');\n"
    return script

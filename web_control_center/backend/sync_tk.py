import sys
import os

# 确保能 import database
sys.path.append(os.path.dirname(__file__))
import database

def sync_existing():
    devices = database.get_all_cloud_devices()
    count = 0
    for dev in devices:
        udid = dev['udid']
        conf = database.get_device_config(udid)
        
        # 提取 tiktok_accounts 并重新触发 set_device_config 执行同步
        tk_accs = conf.get('tiktok_accounts', '[]')
        
        # 只有在设备配置里确实存了 tiktok 数据时才触发覆写以重新触发新增同步
        if tk_accs and tk_accs != '[]':
            res = database.set_device_config(
                udid=udid,
                config_ip=conf.get('config_ip', ''),
                config_vpn=conf.get('config_vpn', ''),
                device_no=conf.get('device_no', ''),
                country=conf.get('country', ''),
                group_name=conf.get('group_name', ''),
                exec_time=conf.get('exec_time', ''),
                apple_account=conf.get('apple_account', ''),
                apple_password=conf.get('apple_password', ''),
                tiktok_accounts=tk_accs
            )
            if res:
                count += 1
                print(f"✅ 同步成功: 设备 [{dev.get('device_no') or udid}]")
            else:
                print(f"❌ 同步失败: 设备 [{dev.get('device_no') or udid}]")
                
    print(f"\\n🎉 数据全量入库补偿完毕，共处理 {count} 台有效携带 TikTok 账号的设备。")

if __name__ == '__main__':
    sync_existing()

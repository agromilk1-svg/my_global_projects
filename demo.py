#!/usr/bin/env python3
"""
ECWDA 使用示例
演示如何使用 ECWDA SDK 进行 iOS 自动化
"""

from ecwda import ECWDA
import time


def demo_basic():
    """基础功能演示"""
    print("=" * 50)
    print("ECWDA 基础功能演示")
    print("=" * 50)
    
    # 连接设备
    ec = ECWDA("http://localhost:10088")
    
    if not ec.is_connected():
        print("❌ 连接失败!")
        print("请确保:")
        print("  1. WDA 已在 iPhone 上运行")
        print("  2. 端口转发已开启: tidevice relay 10088 10088")
        return
    
    print("✅ 连接成功!")
    
    # 获取设备信息
    info = ec.get_device_info()
    print(f"\n📱 设备信息:")
    print(f"   名称: {info['name']}")
    print(f"   iOS: {info['os_version']}")
    
    # 获取屏幕尺寸
    width, height = ec.get_screen_size()
    print(f"   屏幕: {width}x{height}")
    
    # 截图
    ec.screenshot("demo_screenshot.png")
    print("\n📷 截图已保存: demo_screenshot.png")


def demo_click():
    """点击功能演示"""
    print("\n" + "=" * 50)
    print("点击功能演示")
    print("=" * 50)
    
    ec = ECWDA()
    if not ec.is_connected():
        return
    
    # 创建会话
    ec.create_session()
    
    # 返回主屏幕
    print("\n🏠 返回主屏幕...")
    ec.home()
    time.sleep(1)
    
    # 点击屏幕中心
    width, height = ec.get_screen_size()
    center_x = width // 2
    center_y = height // 2
    
    print(f"👆 点击屏幕中心: ({center_x}, {center_y})")
    ec.click(center_x, center_y)
    time.sleep(0.5)
    
    # 双击
    print(f"👆👆 双击屏幕中心")
    ec.double_click(center_x, center_y)
    time.sleep(0.5)
    
    # 长按
    print(f"👆⏱️ 长按 1 秒")
    ec.long_click(center_x, center_y, duration=1.0)


def demo_swipe():
    """滑动功能演示"""
    print("\n" + "=" * 50)
    print("滑动功能演示")
    print("=" * 50)
    
    ec = ECWDA()
    if not ec.is_connected():
        return
    
    ec.create_session()
    
    # 返回主屏幕
    ec.home()
    time.sleep(1)
    
    # 向上滑动
    print("📜 向上滑动...")
    ec.swipe_up()
    time.sleep(1)
    
    # 向下滑动
    print("📜 向下滑动...")
    ec.swipe_down()
    time.sleep(1)
    
    # 向左滑动
    print("📜 向左滑动...")
    ec.swipe_left()
    time.sleep(1)
    
    # 向右滑动
    print("📜 向右滑动...")
    ec.swipe_right()


def demo_find_color():
    """找色功能演示"""
    print("\n" + "=" * 50)
    print("找色功能演示")
    print("=" * 50)
    
    ec = ECWDA()
    if not ec.is_connected():
        return
    
    ec.create_session()
    
    # 返回主屏幕
    ec.home()
    time.sleep(1)
    
    # 获取像素颜色
    print("\n🎨 获取坐标 (100, 100) 的颜色...")
    color = ec.get_pixel_color(100, 100)
    if color:
        print(f"   颜色: {color}")
    
    # 找色
    print("\n🔍 在屏幕中查找白色 (#FFFFFF)...")
    pos = ec.find_color("#FFFFFF", tolerance=20)
    if pos:
        print(f"   找到: ({pos['x']}, {pos['y']})")
    else:
        print("   未找到")
    
    # 比色
    print("\n🎨 比较坐标 (100, 100) 是否为白色...")
    if ec.cmp_color(100, 100, "#FFFFFF", tolerance=50):
        print("   颜色匹配!")
    else:
        print("   颜色不匹配")


def demo_app_control():
    """应用控制演示"""
    print("\n" + "=" * 50)
    print("应用控制演示")
    print("=" * 50)
    
    ec = ECWDA()
    if not ec.is_connected():
        return
    
    ec.create_session()
    
    # 启动设置
    print("\n📱 启动设置应用...")
    ec.launch_app("com.apple.Preferences")
    time.sleep(2)
    
    # 截图
    ec.screenshot("settings.png")
    print("📷 截图已保存: settings.png")
    
    # 滑动浏览
    print("\n📜 向下滑动...")
    ec.swipe_up()
    time.sleep(1)
    
    # 截图
    ec.screenshot("settings_scrolled.png")
    print("📷 截图已保存: settings_scrolled.png")
    
    # 关闭设置
    print("\n❌ 关闭设置应用...")
    ec.terminate_app("com.apple.Preferences")
    
    # 返回主屏幕
    ec.home()
    print("🏠 已返回主屏幕")


def demo_automation_script():
    """完整自动化脚本示例"""
    print("\n" + "=" * 50)
    print("完整自动化脚本示例")
    print("=" * 50)
    
    ec = ECWDA()
    if not ec.is_connected():
        print("❌ 请先启动 WDA 并开启端口转发")
        return
    
    print("\n🤖 开始自动化任务...")
    
    # 1. 返回主屏幕
    print("1️⃣ 返回主屏幕")
    ec.home()
    time.sleep(1)
    
    # 2. 启动 App Store
    print("2️⃣ 启动 App Store")
    ec.launch_app("com.apple.AppStore")
    time.sleep(3)
    
    # 3. 截图
    print("3️⃣ 截图")
    ec.screenshot("appstore.png")
    
    # 4. 等待某个颜色出现
    print("4️⃣ 等待蓝色出现...")
    pos = ec.wait_color("#007AFF", timeout=5)
    if pos:
        print(f"   找到蓝色: ({pos['x']}, {pos['y']})")
        # 点击蓝色位置
        ec.click(pos['x'], pos['y'])
    
    # 5. 滑动
    print("5️⃣ 向上滑动浏览")
    for i in range(3):
        ec.swipe_up(duration=0.3)
        time.sleep(0.5)
    
    # 6. 返回主屏幕
    print("6️⃣ 返回主屏幕")
    ec.home()
    
    print("\n✅ 自动化任务完成!")


if __name__ == "__main__":
    print("=" * 60)
    print("        ECWDA 功能演示")
    print("=" * 60)
    print("\n请选择演示:")
    print("1. 基础功能")
    print("2. 点击功能")
    print("3. 滑动功能")
    print("4. 找色功能")
    print("5. 应用控制")
    print("6. 完整自动化脚本")
    print("0. 运行所有演示")
    
    choice = input("\n请输入选项 (默认 1): ").strip() or "1"
    
    demos = {
        "1": demo_basic,
        "2": demo_click,
        "3": demo_swipe,
        "4": demo_find_color,
        "5": demo_app_control,
        "6": demo_automation_script,
    }
    
    if choice == "0":
        for demo in demos.values():
            demo()
            print("\n")
    elif choice in demos:
        demos[choice]()
    else:
        print("无效选项")

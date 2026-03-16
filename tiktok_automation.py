#!/usr/bin/env python3
"""
TikTok 自动刷视频脚本示例
演示如何使用 WDA API 实现复杂自动化

功能：
1. 定时启动（16:00-18:00 随机时间）
2. 自动打开 TikTok
3. 检测是否在推荐页面
4. 刷视频 1 小时
5. 检测视频进度条
6. 随机点赞和关注
7. 模拟人类触摸行为
"""
import requests
import time
import random
import datetime
import json
from typing import Optional, Tuple

# ========== 配置 ==========

WDA_HOST = "192.168.110.171"
WDA_PORT = 10088
TIKTOK_BUNDLE_ID = "com.zhiliaoapp.musically"  # TikTok 国际版
# TIKTOK_BUNDLE_ID = "com.ss.iphone.ugc.Aweme"  # 抖音

# 运行时长（秒）
RUN_DURATION = 60 * 60  # 1小时

# 点赞和关注的概率
LIKE_PROBABILITY = 0.3      # 30% 概率点赞
FOLLOW_PROBABILITY = 0.1    # 10% 概率关注

# ========== WDA 客户端 ==========

class WDAClient:
    """WDA HTTP 客户端"""
    
    def __init__(self, host: str, port: int):
        self.base_url = f"http://{host}:{port}"
        self.session_id = None
        self.screen_width = 375
        self.screen_height = 812
    
    def connect(self) -> bool:
        """连接 WDA"""
        try:
            resp = requests.get(f"{self.base_url}/status", timeout=10)
            if resp.status_code != 200:
                return False
            
            # 创建会话
            resp = requests.post(
                f"{self.base_url}/session",
                json={"capabilities": {}},
                timeout=60
            )
            data = resp.json()
            self.session_id = data.get("sessionId") or data.get("value", {}).get("sessionId")
            
            # 获取屏幕尺寸
            resp = requests.get(
                f"{self.base_url}/session/{self.session_id}/window/size",
                timeout=10
            )
            size = resp.json().get("value", {})
            self.screen_width = size.get("width", 375)
            self.screen_height = size.get("height", 812)
            
            print(f"✓ 已连接 WDA，屏幕: {self.screen_width}x{self.screen_height}")
            return True
        except Exception as e:
            print(f"✗ 连接失败: {e}")
            return False
    
    def _random_offset(self, x: int, y: int, radius: int = 10) -> Tuple[int, int]:
        """
        添加随机偏移，模拟人类触摸
        让每次点击位置不完全相同
        """
        dx = random.randint(-radius, radius)
        dy = random.randint(-radius, radius)
        return (x + dx, y + dy)
    
    def tap(self, x: int, y: int, randomize: bool = True):
        """点击（可选随机偏移）"""
        if randomize:
            x, y = self._random_offset(x, y)
        
        # 确保坐标在屏幕范围内
        x = max(10, min(x, self.screen_width - 10))
        y = max(10, min(y, self.screen_height - 10))
        
        requests.post(
            f"{self.base_url}/session/{self.session_id}/wda/tap/0",
            json={"x": x, "y": y},
            timeout=10
        )
        print(f"👆 点击: ({x}, {y})")
    
    def swipe(self, from_x: int, from_y: int, to_x: int, to_y: int, 
              duration: float = 0.3, randomize: bool = True):
        """滑动（可选随机偏移）"""
        if randomize:
            # 添加随机偏移
            from_x, from_y = self._random_offset(from_x, from_y, 20)
            to_x, to_y = self._random_offset(to_x, to_y, 20)
        
        requests.post(
            f"{self.base_url}/session/{self.session_id}/wda/dragfromtoforduration",
            json={
                "fromX": from_x, "fromY": from_y,
                "toX": to_x, "toY": to_y,
                "duration": duration
            },
            timeout=10
        )
        print(f"👆➡️ 滑动: ({from_x},{from_y}) -> ({to_x},{to_y})")
    
    def swipe_up_random(self):
        """向上滑动（刷视频），带随机化"""
        cx = self.screen_width // 2
        
        # 随机化起点和终点
        start_y = int(self.screen_height * random.uniform(0.7, 0.85))
        end_y = int(self.screen_height * random.uniform(0.15, 0.3))
        
        # 随机化滑动速度
        duration = random.uniform(0.2, 0.5)
        
        self.swipe(cx, start_y, cx, end_y, duration)
    
    def home(self):
        """按 Home 键"""
        requests.post(f"{self.base_url}/wda/homescreen", timeout=10)
        print("🏠 按下 Home 键")
    
    def launch_app(self, bundle_id: str):
        """启动 App"""
        requests.post(
            f"{self.base_url}/wda/apps/launch",
            json={"bundleId": bundle_id},
            timeout=30
        )
        print(f"📱 启动 App: {bundle_id}")
    
    def ocr(self) -> list:
        """OCR 识别屏幕文字"""
        try:
            resp = requests.post(f"{self.base_url}/wda/ocr", timeout=30)
            return resp.json().get("value", [])
        except:
            return []
    
    def find_text(self, text: str) -> Optional[dict]:
        """查找文字位置"""
        try:
            resp = requests.post(
                f"{self.base_url}/wda/findText",
                json={"text": text},
                timeout=30
            )
            return resp.json().get("value")
        except:
            return None
    
    def find_color(self, color: str, region: dict = None) -> Optional[dict]:
        """查找颜色"""
        try:
            data = {"color": color}
            if region:
                data["region"] = region
            resp = requests.post(
                f"{self.base_url}/wda/findColor",
                json=data,
                timeout=30
            )
            return resp.json().get("value")
        except:
            return None
    
    def get_pixel_color(self, x: int, y: int) -> str:
        """获取像素颜色"""
        try:
            resp = requests.post(
                f"{self.base_url}/wda/pixel",
                json={"x": x, "y": y},
                timeout=10
            )
            return resp.json().get("value", {}).get("color", "000000")
        except:
            return "000000"


# ========== TikTok 自动化逻辑 ==========

class TikTokAutomation:
    """TikTok 自动化控制器"""
    
    def __init__(self, wda: WDAClient):
        self.wda = wda
        self.videos_watched = 0
        self.likes_given = 0
        self.follows_given = 0
    
    def is_on_recommend_page(self) -> bool:
        """检测是否在推荐页面"""
        texts = self.wda.ocr()
        
        # 检查是否有 "推荐" 或 "For You" 等文字
        for t in texts:
            text = t.get("text", "").lower()
            if "推荐" in text or "for you" in text or "关注" in text:
                print("✓ 检测到推荐页面")
                return True
        
        # 也可以通过检测底部导航栏来判断
        # 检查是否有首页图标等
        
        return False
    
    def detect_progress_bar(self) -> Optional[float]:
        """
        检测视频进度条
        返回：进度条比例 (0-1)，如果没有进度条返回 None
        """
        # 进度条通常在屏幕底部
        # 检测白色进度条的位置
        
        # 方法1：通过颜色检测
        # 进度条通常是白色的
        bar_region = {
            "x": 0,
            "y": int(self.wda.screen_height * 0.9),
            "width": self.wda.screen_width,
            "height": int(self.wda.screen_height * 0.1)
        }
        
        result = self.wda.find_color("FFFFFF", bar_region)
        if result and result.get("found"):
            # 计算进度
            progress = result["x"] / self.wda.screen_width
            print(f"📊 检测到进度条，进度: {progress:.1%}")
            return progress
        
        return None
    
    def wait_for_video(self):
        """等待当前视频播放完成或随机时间"""
        progress = self.detect_progress_bar()
        
        if progress is not None:
            # 有进度条，等待视频播放完
            # 估计剩余时间（假设最长60秒）
            remaining = (1 - progress) * 60
            wait_time = min(remaining, 30)  # 最多等30秒
            print(f"⏳ 等待视频播放: {wait_time:.1f}秒")
            time.sleep(wait_time)
        else:
            # 没有进度条，随机停留 2-15 秒
            wait_time = random.uniform(2, 15)
            print(f"⏳ 随机停留: {wait_time:.1f}秒")
            time.sleep(wait_time)
    
    def find_like_button(self) -> Optional[Tuple[int, int]]:
        """
        查找点赞按钮位置
        TikTok 的点赞按钮通常在右侧
        """
        # 方法1：通过 OCR 查找心形图标附近的文字
        # 方法2：通过固定区域（右侧中间）
        
        # TikTok 点赞按钮大约在屏幕右侧 85%，垂直 35%
        x = int(self.wda.screen_width * 0.92)
        y = int(self.wda.screen_height * 0.42)
        
        return (x, y)
    
    def find_follow_button(self) -> Optional[Tuple[int, int]]:
        """
        查找关注按钮位置
        通常在头像下方的 + 按钮
        """
        # TikTok 关注按钮在头像下方
        x = int(self.wda.screen_width * 0.92)
        y = int(self.wda.screen_height * 0.32)
        
        return (x, y)
    
    def maybe_like(self):
        """随机点赞"""
        if random.random() < LIKE_PROBABILITY:
            pos = self.find_like_button()
            if pos:
                # 双击点赞（TikTok 风格）或单击
                if random.random() < 0.5:
                    # 双击屏幕中间
                    cx = self.wda.screen_width // 2
                    cy = self.wda.screen_height // 2
                    self.wda.tap(cx, cy, randomize=True)
                    time.sleep(0.1)
                    self.wda.tap(cx, cy, randomize=True)
                else:
                    # 点击心形按钮
                    self.wda.tap(pos[0], pos[1], randomize=True)
                
                self.likes_given += 1
                print(f"❤️ 点赞成功！(总计: {self.likes_given})")
                time.sleep(random.uniform(0.5, 1.5))
    
    def maybe_follow(self):
        """随机关注"""
        if random.random() < FOLLOW_PROBABILITY:
            pos = self.find_follow_button()
            if pos:
                self.wda.tap(pos[0], pos[1], randomize=True)
                self.follows_given += 1
                print(f"➕ 关注成功！(总计: {self.follows_given})")
                time.sleep(random.uniform(0.5, 2))
    
    def next_video(self):
        """滑动到下一个视频"""
        self.wda.swipe_up_random()
        self.videos_watched += 1
        print(f"📹 已刷视频: {self.videos_watched}")
    
    def run_session(self, duration_seconds: int):
        """
        运行一个刷视频会话
        duration_seconds: 运行时长（秒）
        """
        print(f"\n🎬 开始刷视频，时长: {duration_seconds//60}分钟")
        start_time = time.time()
        
        while time.time() - start_time < duration_seconds:
            try:
                # 1. 等待当前视频
                self.wait_for_video()
                
                # 2. 随机点赞
                self.maybe_like()
                
                # 3. 随机关注
                self.maybe_follow()
                
                # 4. 滑动到下一个视频
                self.next_video()
                
                # 5. 随机暂停（模拟人类行为）
                if random.random() < 0.1:  # 10% 概率额外暂停
                    pause = random.uniform(3, 10)
                    print(f"☕ 随机暂停: {pause:.1f}秒")
                    time.sleep(pause)
                    
            except Exception as e:
                print(f"⚠️ 错误: {e}")
                time.sleep(2)
        
        print(f"\n✅ 会话结束！")
        print(f"   视频: {self.videos_watched}")
        print(f"   点赞: {self.likes_given}")
        print(f"   关注: {self.follows_given}")


# ========== 定时任务 ==========

def wait_until_scheduled_time():
    """
    等待到 16:00-18:00 之间的随机时间
    """
    now = datetime.datetime.now()
    
    # 生成今天 16:00-18:00 之间的随机时间
    random_hour = random.randint(16, 17)
    random_minute = random.randint(0, 59)
    random_second = random.randint(0, 59)
    
    target_time = now.replace(
        hour=random_hour,
        minute=random_minute,
        second=random_second,
        microsecond=0
    )
    
    # 如果目标时间已过，设为明天
    if target_time <= now:
        target_time += datetime.timedelta(days=1)
    
    print(f"⏰ 计划执行时间: {target_time.strftime('%Y-%m-%d %H:%M:%S')}")
    
    # 计算等待时间
    wait_seconds = (target_time - now).total_seconds()
    print(f"⏳ 等待 {wait_seconds/3600:.1f} 小时后开始...")
    
    # 等待
    time.sleep(wait_seconds)
    
    print("🚀 时间到！开始执行...")


# ========== 主程序 ==========

def main():
    print("=" * 50)
    print("TikTok 自动刷视频脚本")
    print("=" * 50)
    
    # 1. 是否需要定时执行？
    use_scheduler = input("是否使用定时执行？(y/n): ").lower() == 'y'
    
    if use_scheduler:
        wait_until_scheduled_time()
    
    # 2. 连接 WDA
    print("\n📱 连接 WDA...")
    wda = WDAClient(WDA_HOST, WDA_PORT)
    
    if not wda.connect():
        print("❌ 无法连接 WDA，请确保：")
        print("   1. WDA 已通过 tidevice xctest 启动")
        print("   2. 设备 IP 和端口正确")
        return
    
    # 3. 启动 TikTok
    print("\n📱 启动 TikTok...")
    wda.launch_app(TIKTOK_BUNDLE_ID)
    time.sleep(5)  # 等待 App 启动
    
    # 4. 创建自动化控制器
    automation = TikTokAutomation(wda)
    
    # 5. 检测是否在推荐页面
    print("\n🔍 检测页面...")
    if not automation.is_on_recommend_page():
        print("⚠️ 可能不在推荐页面，尝试点击首页...")
        # 点击底部首页按钮（通常在左下角）
        wda.tap(int(wda.screen_width * 0.1), int(wda.screen_height * 0.95))
        time.sleep(2)
    
    # 6. 开始刷视频
    automation.run_session(RUN_DURATION)
    
    print("\n🎉 任务完成！")


if __name__ == "__main__":
    main()

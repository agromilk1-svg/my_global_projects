# ECWDA API 文档

ECWDA (EasyClick WebDriverAgent) 是一个增强版的 WebDriverAgent，提供了丰富的 iOS 自动化功能。

## 快速开始

### 1. 启动 WDA
确保 WDA 已在 iPhone 上运行，并开启端口转发：
```bash
tidevice relay 8100 8100
```

### 2. 导入 SDK
```python
from ecwda import ECWDA

# 连接设备
ec = ECWDA("http://localhost:8100")

# 检查连接
if ec.is_connected():
    print("连接成功!")
```

---

## 一、点击函数

### clickPoint 坐标点击
点击指定坐标位置。

**参数：**
- `x` (int): X 坐标
- `y` (int): Y 坐标

**返回：** bool - 是否成功

**示例：**
```python
# 点击坐标 (100, 200)
result = ec.click(100, 200)
if result:
    print("点击成功")
else:
    print("点击失败")
```

---

### longClick 长按
在指定坐标长按。

**参数：**
- `x` (int): X 坐标
- `y` (int): Y 坐标
- `duration` (float): 长按时间（秒），默认 1.0

**返回：** bool - 是否成功

**示例：**
```python
# 在 (100, 200) 长按 2 秒
ec.long_click(100, 200, duration=2.0)
```

---

### doubleClick 双击
在指定坐标双击。

**参数：**
- `x` (int): X 坐标
- `y` (int): Y 坐标

**返回：** bool - 是否成功

**示例：**
```python
ec.double_click(100, 200)
```

---

## 二、滑动函数

### swipe 滑动
从一个坐标滑动到另一个坐标。

**参数：**
- `from_x` (int): 起始 X 坐标
- `from_y` (int): 起始 Y 坐标
- `to_x` (int): 结束 X 坐标
- `to_y` (int): 结束 Y 坐标
- `duration` (float): 滑动时间（秒），默认 0.5

**返回：** bool - 是否成功

**示例：**
```python
# 向上滑动
ec.swipe(200, 600, 200, 200, duration=0.5)

# 向右滑动
ec.swipe(50, 300, 350, 300, duration=0.3)
```

---

## 三、图色函数

### screenshot 截图
截取当前屏幕。

**参数：**
- `save_path` (str, optional): 保存路径，不传则返回 base64

**返回：** str - Base64 编码的图片或保存路径

**示例：**
```python
# 保存截图
ec.screenshot("screen.png")

# 获取 base64
img_base64 = ec.screenshot()
```

---

### findColor 找色
在屏幕中查找指定颜色的坐标。

**参数：**
- `color` (str): 颜色值，如 "#FF5500"
- `region` (dict, optional): 查找区域 `{"x": 0, "y": 0, "width": 375, "height": 667}`
- `tolerance` (int): 容差值，默认 10

**返回：** dict | None - 找到返回 `{"x": 100, "y": 200}`，否则返回 None

**示例：**
```python
# 全屏找色
pos = ec.find_color("#FF5500")
if pos:
    print(f"找到颜色，坐标: ({pos['x']}, {pos['y']})")
    ec.click(pos['x'], pos['y'])
else:
    print("未找到颜色")

# 区域找色
pos = ec.find_color("#FF5500", region={"x": 0, "y": 100, "width": 375, "height": 200})
```

---

### findMultiColor 多点找色
查找多个颜色点的组合。

**参数：**
- `first_color` (str): 第一个颜色
- `offset_colors` (list): 偏移颜色列表 `[{"offset": [10, 0], "color": "#00FF00"}]`
- `region` (dict, optional): 查找区域
- `tolerance` (int): 容差值，默认 10

**返回：** dict | None - 找到返回第一个颜色的坐标

**示例：**
```python
# 多点找色
pos = ec.find_multi_color(
    first_color="#FF0000",
    offset_colors=[
        {"offset": [10, 0], "color": "#00FF00"},
        {"offset": [20, 0], "color": "#0000FF"}
    ]
)
if pos:
    ec.click(pos['x'], pos['y'])
```

---

### cmpColor 比色
比较指定坐标的颜色是否匹配。

**参数：**
- `x` (int): X 坐标
- `y` (int): Y 坐标
- `color` (str): 颜色值
- `tolerance` (int): 容差值，默认 10

**返回：** bool - 是否匹配

**示例：**
```python
# 检查坐标颜色
if ec.cmp_color(100, 200, "#FF5500"):
    print("颜色匹配")
```

---

### getPixelColor 获取像素颜色
获取指定坐标的颜色值。

**参数：**
- `x` (int): X 坐标
- `y` (int): Y 坐标

**返回：** str - 颜色值，如 "#FF5500"

**示例：**
```python
color = ec.get_pixel_color(100, 200)
print(f"坐标颜色: {color}")
```

---

## 四、OCR 识别

### ocr 文字识别
识别屏幕中的文字。

**参数：**
- `region` (dict, optional): 识别区域

**返回：** list - 识别结果列表

**示例：**
```python
# 全屏识别
texts = ec.ocr()
for item in texts:
    print(f"文字: {item['text']}, 位置: ({item['x']}, {item['y']})")

# 区域识别
texts = ec.ocr(region={"x": 0, "y": 100, "width": 375, "height": 200})
```

---

### findText 找文字
查找指定文字的位置。

**参数：**
- `text` (str): 要查找的文字
- `region` (dict, optional): 查找区域

**返回：** dict | None - 找到返回坐标，否则返回 None

**示例：**
```python
# 查找并点击文字
pos = ec.find_text("设置")
if pos:
    ec.click(pos['x'], pos['y'])
```

---

## 五、设备函数

### getDeviceInfo 获取设备信息
获取设备的详细信息。

**返回：** dict - 设备信息

**示例：**
```python
info = ec.get_device_info()
print(f"设备名称: {info['name']}")
print(f"系统版本: {info['os_version']}")
print(f"屏幕尺寸: {info['screen_width']}x{info['screen_height']}")
print(f"电池电量: {info['battery']}%")
```

---

### getScreenSize 获取屏幕尺寸

**返回：** tuple - (width, height)

**示例：**
```python
width, height = ec.get_screen_size()
print(f"屏幕: {width}x{height}")
```

---

## 六、应用管理

### launchApp 启动应用

**参数：**
- `bundle_id` (str): 应用的 Bundle ID

**示例：**
```python
# 启动设置
ec.launch_app("com.apple.Preferences")

# 启动微信
ec.launch_app("com.tencent.xin")
```

---

### terminateApp 关闭应用

**参数：**
- `bundle_id` (str): 应用的 Bundle ID

**示例：**
```python
ec.terminate_app("com.tencent.xin")
```

---

### home 返回主屏幕

**示例：**
```python
ec.home()
```

---

## 七、完整示例

### 自动化脚本示例
```python
from ecwda import ECWDA
import time

def main():
    # 连接设备
    ec = ECWDA("http://localhost:8100")
    
    if not ec.is_connected():
        print("连接失败!")
        return
    
    print("设备连接成功!")
    
    # 获取设备信息
    info = ec.get_device_info()
    print(f"设备: {info['name']}, iOS {info['os_version']}")
    
    # 返回主屏幕
    ec.home()
    time.sleep(1)
    
    # 启动设置
    ec.launch_app("com.apple.Preferences")
    time.sleep(2)
    
    # 截图
    ec.screenshot("step1.png")
    
    # 找到"通用"并点击
    pos = ec.find_text("通用")
    if pos:
        ec.click(pos['x'], pos['y'])
        time.sleep(1)
    
    # 向下滑动
    width, height = ec.get_screen_size()
    ec.swipe(width/2, height*0.7, width/2, height*0.3)
    
    # 截图
    ec.screenshot("step2.png")
    
    print("自动化完成!")

if __name__ == "__main__":
    main()
```

---

## API 端点参考

| 功能 | HTTP 方法 | 端点 |
|------|-----------|------|
| 状态检查 | GET | `/status` |
| 截图 | GET | `/screenshot` |
| 点击 | POST | `/session/{id}/wda/tap/0` |
| 滑动 | POST | `/session/{id}/wda/dragFromToForDuration` |
| 长按 | POST | `/wda/longPress` |
| 双击 | POST | `/wda/doubleTap` |
| 找色 | POST | `/wda/findColor` |
| 多点找色 | POST | `/wda/findMultiColor` |
| 比色 | POST | `/wda/cmpColor` |
| OCR | POST | `/wda/ocr/recognize` |
| 设备信息 | GET | `/wda/device/info` |
| 返回主屏幕 | POST | `/wda/homescreen` |
| 启动应用 | POST | `/session/{id}/wda/apps/launch` |
| 关闭应用 | POST | `/session/{id}/wda/apps/terminate` |

---

## 八、脱机模式 (ECWDA 扩展)

脱机模式允许 ECMAIN 将脚本发送到 ECWDA 执行，无需电脑持续连接。

### executeScript 执行脚本
在设备上执行一系列命令。

**参数：**
- `commands` (list): 命令列表
- `script_id` (str, optional): 脚本 ID

**支持的命令：**
- `tap`: 点击 - `{"action": "tap", "params": {"x": 100, "y": 200}}`
- `swipe`: 滑动 - `{"action": "swipe", "params": {"fromX": 200, "fromY": 600, "toX": 200, "toY": 200}}`
- `sleep`: 等待 - `{"action": "sleep", "params": {"seconds": 1.0}}`
- `home`: 返回主屏幕 - `{"action": "home", "params": {}}`

**示例：**
```python
# 执行自动化脚本
result = ec.execute_script([
    {"action": "tap", "params": {"x": 100, "y": 200}},
    {"action": "sleep", "params": {"seconds": 1}},
    {"action": "swipe", "params": {"fromX": 200, "fromY": 600, "toX": 200, "toY": 200}},
    {"action": "home", "params": {}}
], script_id="test-001")

print(f"脚本状态: {result}")
```

---

### getScriptStatus 获取脚本状态

**示例：**
```python
# 检查脚本执行状态
status = ec.get_script_status()
print(f"正在运行: {status['running']}")
print(f"执行日志: {status['log']}")
```

---

### stopScript 停止脚本

**示例：**
```python
# 停止当前脚本
ec.stop_script()
```

---

## 九、ECWDA 扩展 API

以下 API 需要编译安装 ECWDA 扩展模块后才能使用。

### findColorNative 原生找色
使用设备端算法找色，比 Python 客户端更快。

**示例：**
```python
# 使用原生 API 找色
pos = ec.find_color_native("#FF5500", tolerance=10)
if pos:
    ec.click(pos['x'], pos['y'])
```

---

### getPixelNative 原生获取像素

**示例：**
```python
# 获取像素颜色
color = ec.get_pixel_native(100, 200)
print(f"颜色: {color['color']}, R={color['r']}, G={color['g']}, B={color['b']}")
```

---

### ocrNative 原生 OCR 识别
使用 iOS Vision Framework 进行文字识别 (需要 iOS 13+)。

**示例：**
```python
# 全屏 OCR
texts = ec.ocr_native()
for t in texts:
    print(f"文字: {t['text']}, 置信度: {t['confidence']}, 位置: ({t['x']}, {t['y']})")

# 区域 OCR
texts = ec.ocr_native(region={"x": 0, "y": 100, "width": 375, "height": 200})
```

---

## 十、脚本生成器

ECWDA 提供了一个类似按键精灵的脚本生成器工具。

### 启动脚本生成器

```bash
python script_generator.py
```

### 功能特点

- **实时屏幕投屏** - 查看手机屏幕
- **鼠标控制** - 点击和滑动手机
- **颜色拾取** - 获取任意位置的颜色值
- **坐标拾取** - 获取任意位置的坐标
- **多点找色** - 设置多个颜色点组合
- **操作录制** - 录制点击和滑动操作
- **脚本回放** - 回放录制的操作
- **代码生成** - 自动生成 Python/JSON 脚本
- **脱机执行** - 发送脚本到设备执行

### 使用方法

1. 启动脚本生成器
2. 输入 WDA 地址，点击"连接"
3. 点击"开始录制"
4. 在屏幕上点击和滑动
5. 点击"停止录制"
6. 点击"生成 Python 代码"导出脚本

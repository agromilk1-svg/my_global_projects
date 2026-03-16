# ECWDA 扩展模块

本目录包含 ECWDA 扩展功能模块，需要在 macOS + Xcode 环境下编译。

## 新增文件

- `FBECWDACommands.h` - 头文件
- `FBECWDACommands.m` - 实现文件

## 新增 API 端点

### 设备信息
```
GET /wda/device/info
```
返回设备详细信息，包括名称、系统版本、屏幕尺寸、电量等。

### 找色
```
POST /wda/findColor
Body: {
  "color": "#FF5500",
  "region": {"x": 0, "y": 0, "width": 375, "height": 667},  // 可选
  "tolerance": 10  // 可选，默认 10
}
Response: {"found": true, "x": 100, "y": 200}
```

### 多点找色
```
POST /wda/findMultiColor
Body: {
  "firstColor": "#FF0000",
  "offsetColors": [
    {"offset": [10, 0], "color": "#00FF00"},
    {"offset": [20, 0], "color": "#0000FF"}
  ],
  "region": {...},  // 可选
  "tolerance": 10   // 可选
}
Response: {"found": true, "x": 100, "y": 200}
```

### 比色
```
POST /wda/cmpColor
Body: {
  "x": 100,
  "y": 200,
  "color": "#FF5500",
  "tolerance": 10
}
Response: {"match": true, "actualColor": "#FF5501"}
```

### 获取像素颜色
```
POST /wda/pixel
Body: {"x": 100, "y": 200}
Response: {"color": "#FF5500", "r": 255, "g": 85, "b": 0}
```

### OCR 文字识别
```
POST /wda/ocr/recognize
Body: {
  "region": {"x": 0, "y": 100, "width": 375, "height": 200}  // 可选
}
Response: {
  "texts": [
    {"text": "设置", "confidence": 0.98, "x": 100, "y": 150, "width": 40, "height": 20}
  ]
}
```

### 脚本执行 (脱机模式)
```
POST /wda/script/execute
Body: {
  "scriptId": "test-001",  // 可选
  "commands": [
    {"action": "tap", "params": {"x": 100, "y": 200}},
    {"action": "sleep", "params": {"seconds": 1}},
    {"action": "swipe", "params": {"fromX": 200, "fromY": 600, "toX": 200, "toY": 200}},
    {"action": "home", "params": {}}
  ]
}
Response: {"scriptId": "test-001", "status": "started"}
```

### 脚本状态
```
GET /wda/script/status
Response: {
  "scriptId": "test-001",
  "running": true,
  "log": [{"action": "tap", "status": "success"}]
}
```

### 停止脚本
```
POST /wda/script/stop
Response: {"status": "stopped"}
```

### 长按
```
POST /wda/longPress
Body: {"x": 100, "y": 200, "duration": 1.0}
```

### 双击
```
POST /wda/doubleTap
Body: {"x": 100, "y": 200}
```

## 编译说明

1. 在 macOS 上使用 Xcode 打开 `WebDriverAgent.xcodeproj`
2. 确保 `FBECWDACommands.m` 已添加到编译目标
3. 选择签名证书并编译

## 脱机模式说明

脱机模式允许 ECMAIN 将脚本发送到 ECWDA 执行，无需电脑持续连接：

1. ECMAIN 从服务器获取脚本
2. ECMAIN 调用 `/wda/script/execute` 执行脚本
3. ECWDA 在后台执行命令序列
4. ECMAIN 可通过 `/wda/script/status` 查询状态
5. 可通过 `/wda/script/stop` 停止执行

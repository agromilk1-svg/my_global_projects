import os
import re

src_file = '/Users/hh/Desktop/my/web_control_center/frontend/src/App.vue'

with open(src_file, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. 替换 testEcmain 和新增 sendDeviceAction
old_test_ecmain = """const testEcmain = async () => {
  log(`测试 ECMAIN 地址: ${ecmainUrl.value}`);
  try {
    const res = await fetch(`${apiBase}/ping`);
    if(res.ok) log('✓ ECMAIN 测试通信正常!');
    else log('✗ ECMAIN 不可达');
  } catch(e:any) {
    log(`✗ ECMAIN 测试失败: ${e.message}`);
  }
}"""

new_test_ecmain = """const sendDeviceAction = async (type: string, x: number = 0, y: number = 0) => {
  if (!selectedDevice.value && type !== 'ping') return false;
  try {
    const res = await fetch(`${apiBase}/action_proxy`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        ecmain_url: ecmainUrl.value,
        action_type: type,
        x: x,
        y: y
      }),
    });
    const data = await res.json();
    if(data.status !== 'ok') {
       log(`✗ 指令下发失败: ${data.msg || data.detail}`);
       return false;
    }
    if (type === 'click') log(`📡 发送点击坐标: (${Math.floor(x)}, ${Math.floor(y)})`);
    return true;
  } catch (e: any) {
    log(`✗ 通信异常: ${e.message}`);
    return false;
  }
};

const testEcmain = async () => {
  log(`探活 ECMAIN: ${ecmainUrl.value}`);
  const ok = await sendDeviceAction('ping');
  if(ok) log('✓ ECMAIN 链路已打通!');
}"""

content = content.replace(old_test_ecmain, new_test_ecmain)

# 2. 替换 Canvas 处理逻辑 (原码行数从 162 附近到 222)
old_canvas_block = """const mouseX = ref('--');
const mouseY = ref('--');

const startDraw = (e: MouseEvent) => {
  if (!canvasRef.value) return;
  const rect = canvasRef.value.getBoundingClientRect();
  startX.value = e.clientX - rect.left;
  startY.value = e.clientY - rect.top;
  isDrawing.value = true;
};

const handleMouseMove = (e: MouseEvent) => {
  if (!canvasRef.value) return;
  const rect = canvasRef.value.getBoundingClientRect();
  
  // Update crosshair coordinates
  const scaleX = imageRef.value ? imageRef.value.naturalWidth / rect.width : 1;
  const scaleY = imageRef.value ? imageRef.value.naturalHeight / rect.height : 1;
  mouseX.value = Math.floor((e.clientX - rect.left) * scaleX).toString();
  mouseY.value = Math.floor((e.clientY - rect.top) * scaleY).toString();

  if(!isDrawing.value) return;
  currX.value = e.clientX - rect.left;
  currY.value = e.clientY - rect.top;
  
  const ctx = canvasRef.value.getContext('2d');
  if(!ctx) return;
  ctx.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height);
  ctx.strokeStyle = '#00ff00';
  ctx.lineWidth = 1;
  ctx.strokeRect(startX.value, startY.value, currX.value - startX.value, currY.value - startY.value);
};

const endDraw = () => {
  if (!isDrawing.value || !canvasRef.value || !imageRef.value) return;
  isDrawing.value = false;
  
  const ctx = canvasRef.value.getContext('2d');
  if(ctx) ctx.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height);

  const rect = canvasRef.value.getBoundingClientRect();
  const scaleX = imageRef.value.naturalWidth / rect.width;
  const scaleY = imageRef.value.naturalHeight / rect.height;
  const w = Math.abs(currX.value - startX.value) * scaleX;
  const h = Math.abs(currY.value - startY.value) * scaleY;
  const sx = Math.min(startX.value, currX.value) * scaleX;
  const sy = Math.min(startY.value, currY.value) * scaleY;

  if (w < 5 || h < 5) return; 

  const tempCanvas = document.createElement('canvas');
  tempCanvas.width = w; tempCanvas.height = h;
  const tCtx = tempCanvas.getContext('2d');
  if(tCtx) {
    tCtx.drawImage(imageRef.value, sx, sy, w, h, 0, 0, w, h);
    const b64 = tempCanvas.toDataURL('image/png').split(',')[1];
    actionQueue.value.push({ type: 'FIND_IMAGE_TAP', label: '[截切找图并点击]', template: b64, threshold: 0.8 });
    updatePreview();
    log(`✓ 截取图片 ${w|0}x${h|0}`);
  }
};"""

new_canvas_block = """const mouseX = ref('--');
const mouseY = ref('--');

const getRealMouseCoord = (e: MouseEvent) => {
  if (!canvasRef.value || !imageRef.value) return null;
  const rect = canvasRef.value.getBoundingClientRect();
  
  const nw = imageRef.value.naturalWidth;
  const nh = imageRef.value.naturalHeight;
  if (!nw || !nh) return null;

  const cw = rect.width;
  const ch = rect.height;

  const imageAspect = nw / nh;
  const containerAspect = cw / ch;

  let renderW, renderH;
  if (imageAspect > containerAspect) {
    renderW = cw;
    renderH = cw / imageAspect;
  } else {
    renderH = ch;
    renderW = ch * imageAspect;
  }

  const offsetX = (cw - renderW) / 2;
  const offsetY = (ch - renderH) / 2;

  let x = e.clientX - rect.left - offsetX;
  let y = e.clientY - rect.top - offsetY;

  if (x < 0 || x > renderW || y < 0 || y > renderH) {
    return null; // out of bounds
  }

  const realScale = nw / renderW;
  return {
    x: Math.floor(x * realScale),
    y: Math.floor(y * realScale),
    rectX: e.clientX - rect.left,
    rectY: e.clientY - rect.top,
  };
};

const startDraw = (e: MouseEvent) => {
  if (!canvasRef.value) return;
  const rect = canvasRef.value.getBoundingClientRect();
  startX.value = e.clientX - rect.left;
  startY.value = e.clientY - rect.top;
  isDrawing.value = true;
};

const handleMouseMove = (e: MouseEvent) => {
  if (!canvasRef.value) return;
  const coord = getRealMouseCoord(e);
  if (coord) {
     mouseX.value = coord.x.toString();
     mouseY.value = coord.y.toString();
  } else {
     mouseX.value = '--';
     mouseY.value = '--';
  }

  if(!isDrawing.value) return;
  
  if (coord) {
      currX.value = coord.rectX;
      currY.value = coord.rectY;
  } else {
      const rect = canvasRef.value.getBoundingClientRect();
      currX.value = e.clientX - rect.left;
      currY.value = e.clientY - rect.top;
  }
  
  const ctx = canvasRef.value.getContext('2d');
  if(!ctx) return;
  ctx.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height);
  ctx.strokeStyle = '#00ff00';
  ctx.lineWidth = 1;
  ctx.strokeRect(startX.value, startY.value, currX.value - startX.value, currY.value - startY.value);
};

const endDraw = (e: MouseEvent) => {
  if (!isDrawing.value || !canvasRef.value || !imageRef.value) return;
  isDrawing.value = false;
  
  const ctx = canvasRef.value.getContext('2d');
  if(ctx) ctx.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height);

  const rect = canvasRef.value.getBoundingClientRect();
  const w = Math.abs(currX.value - startX.value);
  const h = Math.abs(currY.value - startY.value);

  const coord = getRealMouseCoord(e);

  if (w < 5 && h < 5) {
     if (coord) {
         sendDeviceAction('click', coord.x, coord.y);
     }
     return;
  }
  
  const nw = imageRef.value.naturalWidth;
  const nh = imageRef.value.naturalHeight;
  const cw = rect.width;
  const ch = rect.height;

  const imageAspect = nw / nh;
  const containerAspect = cw / ch;

  let renderW, renderH;
  if (imageAspect > containerAspect) {
    renderW = cw;
    renderH = cw / imageAspect;
  } else {
    renderH = ch;
    renderW = ch * imageAspect;
  }

  const offsetX = (cw - renderW) / 2;
  const offsetY = (ch - renderH) / 2;
  const realScale = nw / renderW;

  const realStartX = (startX.value - offsetX) * realScale;
  const realStartY = (startY.value - offsetY) * realScale;
  const realCurrX = (currX.value - offsetX) * realScale;
  const realCurrY = (currY.value - offsetY) * realScale;

  const realW = Math.abs(realCurrX - realStartX);
  const realH = Math.abs(realCurrY - realStartY);
  const rx = Math.min(realStartX, realCurrX);
  const ry = Math.min(realStartY, realCurrY);

  if (rx < 0 || ry < 0 || rx + realW > nw || ry + realH > nh || realW < 5 || realH < 5) return;

  const tempCanvas = document.createElement('canvas');
  tempCanvas.width = realW; tempCanvas.height = realH;
  const tCtx = tempCanvas.getContext('2d');
  if(tCtx) {
    tCtx.drawImage(imageRef.value, rx, ry, realW, realH, 0, 0, realW, realH);
    const b64 = tempCanvas.toDataURL('image/png').split(',')[1];
    actionQueue.value.push({ type: 'FIND_IMAGE_TAP', label: '[截切找图并点击]', template: b64, threshold: 0.8 });
    updatePreview();
    log(`✓ 截取图片 ${realW|0}x${realH|0}`);
  }
};"""

content = content.replace(old_canvas_block, new_canvas_block)

# 3. 关联模板中的按钮 @click
content = content.replace(
    '<button class="flex-1 bg-gray-800 hover:bg-gray-700 text-gray-300 border border-gray-600 text-[11px] py-1.5 rounded-md font-medium transition-colors">🏠 回源</button>',
    '<button @click="sendDeviceAction(\\'home\\')" class="flex-1 bg-gray-800 hover:bg-gray-700 text-gray-300 border border-gray-600 text-[11px] py-1.5 rounded-md font-medium transition-colors">🏠 回源</button>'
)

with open(src_file, 'w', encoding='utf-8') as f:
    f.write(content)

print("Coordinates algorithm and proxy actions patched!")

// NCNN OCR 实现逻辑笔记

// 1. 预处理参数 (PaddleOCR v5 Mobile)
// Det (检测):
//   Input: RGB, Resize to multiple of 32 (e.g. 640x640 limit), Normalize
//   Mean: {0.485, 0.456, 0.406} * 255
//   Std:  {0.229, 0.224, 0.225} * 255
//   (NCNN from_pixels is 0-255, so we use mean/std values directly or scale)
// Rec (识别):
//   Input: RGB, Height=48 (v5 uses 48, v3 uses 32), Width=Dynamic
//   Mean: {0.5, 0.5, 0.5} * 255
//   Std:  {0.5, 0.5, 0.5} * 255

// 2. DBNet 后处理 (无 OpenCV)
// Output: 1 x 1 x H x W probability map (float)
// Steps:
//   a. Thresholding (val > 0.3) -> Binary Map
//   b. Connected Components Labeling (Union-Find or BFS)
//   c. For each component:
//      - Calculate bounding box (min_x, min_y, max_x, max_y)
//      - (Optional) Calculate rotated rect if implementing complex geometry
//      - Unclip: Expand box by ratio (usually 1.5x area)
//      - Filter small boxes

// 3. CRNN 解码
// Output: Sequence length x Num classes (Softmax)
// Post-process:
//   Argmax each time step
//   Remove duplicates and blanks (blank index is usually last)
//   Map index to string using keys.txt

// 关键结构体
struct Box {
  int x0, y0, x1, y1;
  float score;
};

// 辅助函数: Sigmoid
static inline float sigmoid(float x) { return 1.0f / (1.0f + exp(-x)); }

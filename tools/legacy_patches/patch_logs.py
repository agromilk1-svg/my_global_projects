import os

path = '/Users/hh/Desktop/my/web_control_center/frontend/src/App.vue'
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

new_logic = """                // [v1740] 同步透传从机执行日志，与主控体验对齐
                if (data.logs && Array.isArray(data.logs)) {
                    data.logs.forEach((logItem: any) => {
                        batchLogs.value[dev.udid]?.push(`\ud83d\udcf1 ${logItem.log || logItem.message || logItem}`);
                    });
                }
                if (data.status === 'success' || data.status === 'ok') {
                    batchLogs.value[dev.udid]?.push('\u2705 \u811a\u672c\u955c\u50cf\u540c\u6b65\u843d\u5e55\u3002');
"""

# Looking for lines 2104-2105 (0-indexed: 2103-2104)
# 2104:                if (data.status === 'success' || data.status === 'ok') {
# 2105:                   batchLogs.value[dev.udid]?.push('✅ 脚本镜像同步成功。');

target_line = "                   batchLogs.value[dev.udid]?.push('\u2705 \u811a\u672c\u955c\u50cf\u540c\u6b65\u6210\u529f\u3002');"

found = False
for i in range(len(lines)):
    if target_line in lines[i]:
        # Replace the if block around it
        if 'if (data.status === \'success\' || data.status === \'ok\') {' in lines[i-1]:
            lines[i-1:i+1] = [new_logic]
            found = True
            break

if found:
    with open(path, 'w', encoding='utf-8') as f:
        f.writelines(lines)
    print("Success")
else:
    print("Not found")

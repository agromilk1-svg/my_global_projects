/**
 * Cloudflare 动态 DNS (DDNS) 更新脚本
 * 
 * 功能：自动检测本地外网 IP，若发生变化则更新 Cloudflare DNS 记录。
 * 注意：此版本已适配中国大陆环境，使用 myip.ipip.net 获取 IP。
 */

const https = require('https');

// ================= 配置区域 =================
const CONFIG = {
    apiToken: 'cfut_S5Gy8Iz2AqCwl1DpqGg7i7FTV9GHoKvPf8lWKBKZ2a5da1cb',
    zoneId: '8c32007bda9f5c7fbb32787fa7c28124',
    publicRecord: '*.ecmain.site', // 公网 IP 动态更新域名
    localRecord: {
        name: 'l.ecmain.site',   // 内网 IP 静态域名
        ip: '192.168.1.251'      // 目标内网 IP
    },
    ttl: 1, // 1 为自动 (Automatic)
    proxied: false, // 是否开启 Cloudflare 代理
    checkInterval: 10, // 检查间隔（分钟）

    // ======== 路由器关联设置 ========
    router: {
        enabled: true,        // 是否在 IP 发生变化时，顺便同步修改路由器 NAT 配置
        url: 'http://192.168.1.1',
        username: 'useradmin',
        password: 'hX7h3%cu'
    }
};
// ===========================================

/**
 * 通用 HTTPS 请求函数 (支持纯文本和 JSON)
 */
function request(options, data = null) {
    return new Promise((resolve, reject) => {
        const req = https.request(options, (res) => {
            let body = '';
            res.on('data', (chunk) => body += chunk);
            res.on('end', () => {
                // 如果是 JSON 则尝试解析
                if (res.headers['content-type'] && res.headers['content-type'].includes('application/json')) {
                    try {
                        resolve(JSON.parse(body));
                    } catch (e) {
                        resolve(body);
                    }
                } else {
                    resolve(body);
                }
            });
        });

        req.on('error', (err) => reject(err));
        if (data) req.write(JSON.stringify(data));
        req.end();
    });
}

/**
 * 获取本地公网 IP (使用国内稳定的 IPIP.net 服务)
 */
async function getPublicIP() {
    try {
        const response = await request({
            hostname: 'myip.ipip.net',
            path: '/',
            method: 'GET',
            headers: { 'User-Agent': 'curl/7.0.0' }
        });

        // 使用正则从 "当前 IP：x.x.x.x  来自于：..." 中提取 IP
        const match = response.match(/(\d+\.\d+\.\d+\.\d+)/);
        if (match) {
            return match[1];
        }
        throw new Error('无法从响应中解析 IP: ' + response);
    } catch (error) {
        console.error('获取公网 IP 失败:', error.message);
        return null;
    }
}

/**
 * 获取 Cloudflare 上的 DNS 记录信息
 */
async function getDNSRecord(apiToken, zoneId, recordName) {
    try {
        const result = await request({
            hostname: 'api.cloudflare.com',
            path: `/client/v4/zones/${zoneId}/dns_records?name=${recordName}`,
            method: 'GET',
            headers: {
                'Authorization': `Bearer ${apiToken}`,
                'Content-Type': 'application/json'
            }
        });

        if (result.success && result.result.length > 0) {
            return result.result[0];
        } else {
            console.error('未找到对应的 DNS 记录:', recordName);
            return null;
        }
    } catch (error) {
        console.error('查询 DNS 记录时出错:', error.message);
        return null;
    }
}

/**
 * 更新 Cloudflare DNS 记录
 */
async function updateDNSRecord(apiToken, zoneId, record, newIP) {
    try {
        const result = await request({
            hostname: 'api.cloudflare.com',
            path: `/client/v4/zones/${zoneId}/dns_records/${record.id}`,
            method: 'PATCH',
            headers: {
                'Authorization': `Bearer ${apiToken}`,
                'Content-Type': 'application/json'
            }
        }, {
            content: newIP,
            name: record.name,
            type: 'A',
            ttl: CONFIG.ttl,
            proxied: CONFIG.proxied
        });

        if (result.success) {
            console.log(`[成功] DNS 记录已更新为: ${newIP}`);
            return true;
        } else {
            console.error('更新 DNS 记录失败:', result.errors);
            return false;
        }
    } catch (error) {
        console.error('更新 DNS 记录时出错:', error.message);
        return false;
    }
}

/**
 * 打印所有的 DNS 记录
 */
async function printAllDNSRecords(apiToken, zoneId) {
    try {
        const result = await request({
            hostname: 'api.cloudflare.com',
            path: `/client/v4/zones/${zoneId}/dns_records?per_page=100`,
            method: 'GET',
            headers: {
                'Authorization': `Bearer ${apiToken}`,
                'Content-Type': 'application/json'
            }
        });

        if (result.success && result.result) {
            console.log('\n=================================================');
            console.log('             Cloudflare 所有解析记录             ');
            console.log('=================================================');
            result.result.forEach(record => {
                console.log(`- [${record.type.padEnd(5)}] ${record.name.padEnd(25)} => ${record.content}`);
            });
            console.log('=================================================\n');
        } else {
            console.error('无法获取此时的 DNS 记录列表');
        }
    } catch (error) {
        console.error('拉取 DNS 列表时出错:', error.message);
    }
}

/**
 * 主循环逻辑
 */
async function main() {
    console.log(`[${new Date().toLocaleString()}] 正在检查 IP...`);

    // 1. 处理静态内网记录映射
    const localRecordInfo = await getDNSRecord(CONFIG.apiToken, CONFIG.zoneId, CONFIG.localRecord.name);
    if (localRecordInfo && localRecordInfo.content !== CONFIG.localRecord.ip) {
        console.log(`[Cloudflare] 内网记录 ${CONFIG.localRecord.name} IP不一致 (${localRecordInfo.content} -> ${CONFIG.localRecord.ip})，正在同步...`);
        await updateDNSRecord(CONFIG.apiToken, CONFIG.zoneId, localRecordInfo, CONFIG.localRecord.ip);
    } else if (localRecordInfo) {
        console.log(`[Cloudflare] 内网记录 ${CONFIG.localRecord.name} (${localRecordInfo.content}) 状态正确。`);
    }

    // 2. 处理动态公网记录映射
    const pubRecord = await getDNSRecord(CONFIG.apiToken, CONFIG.zoneId, CONFIG.publicRecord);
    if (!pubRecord) return;

    console.log(`[Cloudflare] 当前远端解析公网 IP: ${pubRecord.content}`);

    // 加速优化：先使用非常廉价的 HTTP 探针进行轻量级比对
    const fastCheckIP = await getPublicIP();

    if (fastCheckIP && fastCheckIP === pubRecord.content) {
        console.log(`[FastCheck] 轻检测本地网络出口 (${fastCheckIP}) 与远端解析完全一致，跳出本回合资源消耗。`);
        return;
    } else if (fastCheckIP) {
        console.log(`[FastCheck] 轻检测到外部 IP 为 ${fastCheckIP}，与远端不一致（或遭遇代理劫持），即将调起底层无头浏览器进入光猫验明正身...`);
    } else {
        console.log(`[FastCheck] 接口测速失败，作为防爆跌降级，立刻启动无头浏览器核查...`);
    }

    if (CONFIG.router && CONFIG.router.enabled) {
        // 全新逻辑：直接从路由器抓取绝对真实的物理公网 IP（无视任何本机代理）
        // 如果发现变化，它会在内部顺便搞定所有的 NAT 映射修正
        try {
            const { getAndSyncRouterNAT } = require('./router-ddns.js');
            const routerIP = await getAndSyncRouterNAT(pubRecord.content, CONFIG.router);

            if (routerIP && routerIP !== pubRecord.content) {
                console.log(`[Cloudflare] 感知到光猫物理 IP 已变更 (${pubRecord.content} -> ${routerIP})，开始同步云端 DNS 记录...`);
                await updateDNSRecord(CONFIG.apiToken, CONFIG.zoneId, pubRecord, routerIP);
            } else if (!routerIP) {
                console.log('[Cloudflare] 未能获取光猫 IP，中止本轮更新。');
            } else {
                console.log('[Cloudflare] 经比对光猫 IP 未发生变化，且路由器内部状态已确认一致，无需更新。');
            }
        } catch (err) {
            console.error('[Cloudflare] 无法执行路由器联控脚本:', err.message);
        }
    } else {
        // 如果用户主动关闭了 router 联控，直接使用轻量检测到的 IP 下发更新
        if (fastCheckIP && fastCheckIP !== pubRecord.content) {
            console.log('[Local] 当前外部接口获取 IP 发生变化，正在更新 Cloudflare...');
            await updateDNSRecord(CONFIG.apiToken, CONFIG.zoneId, pubRecord, fastCheckIP);
        } else {
            console.log('[Local] 在没有开启光猫联控的情况下，未检测到任何改动。');
        }
    }
}

// 顶层自执行异步函数：先打印所有记录，再进入主循环
(async () => {
    await printAllDNSRecords(CONFIG.apiToken, CONFIG.zoneId);

    // 立即运行一次并开启定时任务
    main();
    if (CONFIG.checkInterval > 0) {
        setInterval(main, CONFIG.checkInterval * 60 * 1000);
    }
})();

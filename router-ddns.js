const puppeteer = require('puppeteer');

/**
 * 无头浏览器自动化脚本：直接从路由器抓取真实外网 IP，
 * 并与 Cloudflare 的当前解析值对比。如果不同，不仅返回新 IP，且顺便在路由器内完成所有 NAT 同步修改。
 * 
 * @param {string} currentCFIP - Cloudflare 当前解析的 IP
 * @param {object} config - 路由器登录配置
 * @returns {string|null} - 返回路由器实时获取到的公网 IP
 */
async function getAndSyncRouterNAT(currentCFIP, config) {
    if (!config || !config.enabled) return null;
    
    let browser;
    let page;
    let routerIP = null;
    try {
        browser = await puppeteer.launch({ 
            headless: true, // 解决 Puppeteer 最新版 headless 参数变更导致的 WS timeout 报错
            executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
            timeout: 90000, // 将容忍启动的时间延长到一分半钟
            dumpio: true,   // [新增] 将底层 Chrome 报错强行打印到控制台，以便定位真实问题
            ignoreHTTPSErrors: true,
            args: ['--no-sandbox', '--disable-setuid-sandbox', '--window-size=1920,1080', '--disable-dev-shm-usage']
        });
        
        page = await browser.newPage();
        await page.setViewport({ width: 1920, height: 1080 });

        // ================= 1. 执行登录 =================
        await page.goto(config.url, { waitUntil: 'networkidle2' });
        
        try {
            await page.waitForSelector('#user_name', { timeout: 5000 });
        } catch (e) {
            const pageText = await page.evaluate(() => document.body ? document.body.innerText : '');
            if (pageText.includes('其他用户') || pageText.includes('已有用户') || pageText.includes('正在配置') || pageText.includes('管理')) {
                console.log('[Router] 警告：检测到“其他用户正在配置”或光猫被占用！中止本次操作，远端 IP 暂不更新。');
            } else {
                console.log('[Router] 警告：未能找到登录输入框，可能是页面加载异常或光猫重启中。');
            }
            return null; // 直接返回 null 终止所有逻辑，cloudflare 那边接到 null 也不会更新
        }

        await page.type('#user_name', config.username);
        await page.type('#password', config.password);
        
        await Promise.all([
            page.waitForNavigation({ waitUntil: 'networkidle2' }),
            page.click('#LoginId')
        ]);

        // 通用精准点击辅助
        const clickById = async (selectorID) => {
            for (const f of page.frames()) {
                const clicked = await f.evaluate((sel) => {
                    const e = document.querySelector(sel);
                    if (e && e.offsetHeight > 0) {
                        e.click();
                        return true;
                    }
                    return false;
                }, selectorID);
                if (clicked) return true;
            }
            return false;
        };

        // ================= 2. 提取真正的公网 IP =================
        for (const frame of page.frames()) {
            const ip = await frame.evaluate(() => {
                const tds = Array.from(document.querySelectorAll('td'));
                // 天翼网关默认首页是设备概览，包含一个单元格文字是 INTERNET(上网业务)
                const wanTd = tds.find(td => td.textContent.includes('INTERNET(上网业务)'));
                if (wanTd && wanTd.parentElement) {
                    const ipCell = wanTd.parentElement.children[3]; // 第4列表格
                    if (ipCell) return ipCell.textContent.trim();
                }
                return null;
            });
            if (ip) {
                routerIP = ip;
                break;
            }
        }
        
        if (!routerIP) {
            console.log('[Router] 未能在路由器主页系统概览中找到公网 IP！');
        } else {
            console.log(`[Router] 成功从光猫底层提取到绝对真实 IP: ${routerIP}`);
            
            // ================= 3. 对比并进入 NAT 修改 =================
            if (routerIP !== currentCFIP) {
                console.log(`[Router] 发现该 IP (${routerIP}) 与 Cloudflare 上的记录 (${currentCFIP}) 不一致，正在深度进入并同步所有的 NAT 映射...`);
                
                await clickById('#Menu1_Network');
                await new Promise(r => setTimeout(r, 2000));
                
                await clickById('#Menu2_Net_LAN');
                await new Promise(r => setTimeout(r, 1000));

                await clickById('#Menu3_ZQ_AN_VirtualServer');
                await new Promise(r => setTimeout(r, 4000)); // 等 NAT frame 完全加载
                
                let totalUpdated = 0;
                for (const frame of page.frames()) {
                    // Level 1: 扫描外层的规则选定 Checkbox (加 try 防护脱离的 Frame)
                    let level1Count = 0;
                    try {
                        level1Count = await frame.evaluate(() => {
                            return document.querySelectorAll('input[id^="VirtualServer_"][id$="_3_table"]').length;
                        });
                    } catch(e) {
                        continue;
                    }

                    if (level1Count === 0) continue;

                    for (let l1 = 0; l1 < level1Count; l1++) {
                        // 1. 勾选外层菜单以展开内层子列表
                        await frame.evaluate((idx) => {
                            const cbs = document.querySelectorAll('input[id^="VirtualServer_"][id$="_3_table"]');
                            if (cbs[idx]) cbs[idx].click();
                        }, l1);
                        await new Promise(r => setTimeout(r, 1500));
                        
                        // Level 2: 获取内层展开后的修改按钮
                        const level2Count = await frame.evaluate(() => {
                            return document.querySelectorAll('input[id^="Img_Modify"]').length;
                        });
                        
                        for (let l2 = 0; l2 < level2Count; l2++) {
                            // 2. 点击内层子项目的“修改”唤醒输入框
                            await frame.evaluate((idx) => {
                                const editBtns = document.querySelectorAll('input[id^="Img_Modify"]');
                                if (editBtns[idx]) editBtns[idx].click();
                            }, l2);
                            await new Promise(r => setTimeout(r, 1000));
                            
                            // 3. 拦截外部 IP 输入框强制写入，并点击行级套娃修改
                            console.log(`[Router] 正在深度改写并递交规则 [${l1}:${l2}] -> 强刷 IP [${routerIP}]`);
                            await frame.evaluate((ip) => {
                                // 处理“外部IP范围” (格式: IP-IP)
                                const extIpRangeInput = document.getElementById('ExternalIPRange_text');
                                if (extIpRangeInput) {
                                    extIpRangeInput.value = ip + '-' + ip;
                                }
                                
                                // 处理“外部IP”
                                const extIpInput = document.getElementById('ExternalIP_text');
                                if (extIpInput) {
                                    extIpInput.value = ip;
                                }
                                
                                const editSubmitBtn = document.getElementById('Btn_Edit_fwpm') || document.querySelector('input[onclick*="pageMOD"]');
                                if (editSubmitBtn) {
                                    editSubmitBtn.click();
                                }
                            }, routerIP);
                            
                            totalUpdated++;
                            await new Promise(r => setTimeout(r, 1500));
                        }
                    }
                    
                    if (totalUpdated > 0) {
                        // 4. 全局页面最终应用
                        try {
                            await frame.evaluate(() => {
                                const saveBtn = document.getElementById('Save_button') || document.querySelector('input[onclick*="pageSave"]');
                                if (saveBtn) saveBtn.click();
                            });
                            console.log('[Router] 全部子规则装填完毕，已点击页面底部的【全局保存】正式入库。');
                        } catch(e) {
                            console.log('[Router] 提交时框架重载，已确认发送指令。');
                        }
                        await new Promise(r => setTimeout(r, 2000));
                        break; // 必须跳出 frame 循环，否则由于表单提交导致所有 frame detach 会引发崩溃
                    }
                }
                console.log(`[Router] 本轮修复处理了 ${totalUpdated} 个 NAT 映射子项。`);
            } else {
                console.log('[Router] IP 与 Cloudflare 完全一致，无需修改路由器 NAT 配置。');
            }
        }

    } catch (error) {
        console.error('[Router] 脚本遇到了网络或 DOM 错误:', error.message);
    } finally {
        // ================= 4. 安全退出 =================
        if (page && !page.isClosed()) {
            try {
                console.log('[Router] 正在释放光猫管理会话...');
                await page.evaluate(() => {
                    try {
                        if (typeof window.onClickLogout === 'function') {
                            window.onClickLogout();
                        } else if (typeof top.onClickLogout === 'function') {
                            top.onClickLogout();
                        }
                    } catch(e) {}
                }).catch(e => {});

                // 第二层保障，直接模拟点击
                const clickById = async (selectorID) => {
                    for (const f of page.frames()) {
                        const clicked = await f.evaluate((sel) => {
                            const e = document.querySelector(sel);
                            if (e && e.offsetHeight > 0) { e.click(); return true; }
                            return false;
                        }, selectorID).catch(e => false);
                        if (clicked) return true;
                    }
                    return false;
                };
                await clickById('#buttonLogout'); 
                await new Promise(r => setTimeout(r, 2000));
                console.log('[Router] 会话已安全释放，完美退出。');
            } catch(e) {}
        }

        if (browser) {
            await browser.close();
        }
    }
    return routerIP;
}

module.exports = { getAndSyncRouterNAT };

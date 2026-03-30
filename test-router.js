const puppeteer = require('puppeteer');
const fs = require('fs');

(async () => {
    let browser;
    try {
        console.log('启动浏览器...');
        browser = await puppeteer.launch({ 
            headless: 'new',
            executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
            args: ['--no-sandbox', '--disable-setuid-sandbox', '--window-size=1920,1080']
        });
        
        const page = await browser.newPage();
        await page.setViewport({ width: 1920, height: 1080 });

        console.log('登录...');
        await page.goto('http://192.168.1.1', { waitUntil: 'networkidle2' });
        await page.type('#user_name', 'useradmin');
        await page.type('#password', 'hX7h3%cu');
        await Promise.all([
            page.waitForNavigation({ waitUntil: 'networkidle2' }),
            page.click('#LoginId')
        ]);

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

        console.log('进入网络配置...');
        let clicked = await clickById('#Menu1_Network');
        console.log('Menu1_Network clicked:', clicked);
        await new Promise(r => setTimeout(r, 4000));
        
        console.log('进入高级选项...');
        clicked = await clickById('#Menu2_Net_LAN');
        console.log('Menu2_Net_LAN clicked:', clicked);
        await new Promise(r => setTimeout(r, 4000));

        console.log('进入 NAT...');
        clicked = await clickById('#Menu3_ZQ_AN_VirtualServer');
        console.log('Menu3_ZQ_AN_VirtualServer clicked:', clicked);
        await new Promise(r => setTimeout(r, 6000)); 

        console.log('查找框架并全部 Dump...');
        let idx = 0;
        for (const frame of page.frames()) {
            const html = await frame.evaluate(() => document.documentElement.outerHTML);
            if (html.length > 500) {
               fs.writeFileSync(`router-nat-dump-${idx}.html`, html);
               console.log(`Saved frame ${idx} with ${html.length} bytes`);
            }
            idx++;
        }
        
    } catch (e) {
        console.error(e);
    } finally {
        if (browser) await browser.close();
    }
})();

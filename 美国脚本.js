// [样例参考]: [系统弹窗自动扫雷] Auto Alert Handling
function autoHandleAlert() {
    let msg = wda.getAlertText();
    if (!msg) return false;
    let rawMsg = msg;
    msg = msg.toLowerCase();
    let btns = wda.getAlertButtons() || [];


    var deny = ["不允许", "不", "don\'t", "nicht", "しない", "ne ", "non ", "no ", "não", "refuser"];

    function clickBtn(keywords, excludeWords) {
        if (!excludeWords) excludeWords = [];
        for (var i = 0; i < btns.length; i++) {
            var b = btns[i].toLowerCase();
            var skip = false;
            for (var e = 0; e < excludeWords.length; e++) {
                if (b.indexOf(excludeWords[e].toLowerCase()) >= 0) { skip = true; break; }
            }
            if (skip) continue;
            for (var j = 0; j < keywords.length; j++) {
                if (b.indexOf(keywords[j].toLowerCase()) >= 0) {
                    wda.clickAlertButton(btns[i]);
                    return true;
                }
            }
        }
        return false;
    }

    function has(keywords) {
        for (var i = 0; i < keywords.length; i++) {
            if (msg.indexOf(keywords[i].toLowerCase()) >= 0) return true;
        }
        return false;
    }

    if (has(["photo", "照片", "相片", "相册", "写真", "foto", "フォト"])) {
        if (clickBtn(["完全", "所有", "full", "すべて", "vollen zugriff", "accès complet", "accesso completo", "acceso total", "acesso a todas"])) return true;
        if (clickBtn(["允许", "allow", "許可", "erlauben", "autoriser", "consenti", "permitir", "zulassen"], deny)) return true;
    }
    else if (has(["location", "位置", "定位", "standort", "localização", "ubicación", "posizione", "position", "位置情報"])) {
        if (clickBtn(["不允许", "don\'t allow", "許可しない", "nicht erlauben", "nicht zulassen", "ne pas autoriser", "non consentire", "no permitir", "não permitir"])) return true;
    }
    else if (has(["wlan", "cellular", "wi-fi", "network", "网络", "局域网", "蜂窝", "ネット", "netzwerk", "rede", "red", "rete", "réseau", "モバイルデータ"])) {
        if (clickBtn(["蜂窝", "cellular", "モバイルデータ", "wlan &", "celular", "cellulare", "cellulaires", "mobilfunk"])) return true;
        if (clickBtn(["允许", "allow", "ok", "好", "許可", "erlauben", "autoriser", "consenti", "permitir", "zulassen"], deny)) return true;
    }
    else if (has(["calendar", "reminder", "日历", "备忘录", "カレンダー", "kalender", "erinnerungen", "calendário", "calendario", "promemoria", "calendrier", "リマインダー"])) {
        if (clickBtn(["完全", "full", "フル", "vollen", "complet", "completo", "total"])) return true;
        if (clickBtn(["允许", "allow", "ok", "好", "許可", "erlauben", "autoriser", "consenti", "permitir", "zulassen"], deny)) return true;
    }
    else if (has(["track", "跟踪", "追踪", "トラッキング", "rastrear", "rastreo", "tracciamento", "suivi", "tracking"])) {
        if (clickBtn(["不跟踪", "not to track", "トラッキングしないよう", "ablehnen", "ne pas suivre", "non consentire", "no permitir", "não rastrear", "nicht erlauben"])) return true;
    }
    else if (has(["contact", "通讯录", "联系人", "連絡先", "kontakte", "contato", "contacto", "contatti", "contacts"])) {
        if (clickBtn(["不允许", "don\'t allow", "許可しない", "nicht erlauben", "nicht zulassen", "ne pas autoriser", "non consentire", "no permitir", "não permitir", "refuser"])) return true;
    }
    else if (has(["paste", "粘贴", "剪贴板", "local network", "本地", "ローカル", "bluetooth", "camera", "microphone", "蓝牙", "相机", "摄像头", "麦克风", "マイク", "カメラ", "notification", "通知", "vpn", "profile", "描述文件", "benachrichtigung", "notifica"])) {
        if (clickBtn(["允许", "allow", "許可", "好", "ok", "erlauben", "autoriser", "consenti", "permitir", "zulassen", "aceptar"], deny)) return true;
    }
    if (clickBtn(["好", "ok", "是", "yes", "はい", "允许", "allow", "erlauben", "autoriser", "consenti", "permitir", "zulassen", "accept", "同意", "aceptar", "ja", "sì", "oui"], deny)) {
        return true;
    }

    wda.acceptAlert();
    return true;
}

// 关闭各种带有叉的提示
function autoCloseAlert() {
    var res = wda.findImage("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", 0.7);
    if (res && res.value && res.value.found) {
        wda.tap(res.value.x + wda.randomInt(0, res.value.width || 0), res.value.y + wda.randomInt(0, res.value.height || 0));
        wda.sleep(1);
    }

    var res = wda.findImage("iVBORw0KGgoAAAANSUhEUgAAABoAAAAaCAYAAACpSkzOAAAEhElEQVR4AdyW10ouawyGE3vBXlARu2Lv9UAseOSp1+BdigqiotgLFrAXVOy9zr/nyaz5XDewT5aQf2a+SfImb8oY5XlexPO8SPj38vISeXt7M3l8fIy8vr7ae65fX1+hml2/v79N7/n5OfLx8RH5+fkxXXvp/3jer98o+fPnn4vvTHxliYuLk4SEBElJSZHY2FjxPE+ioqIkOjr6j/bvJT4+XpKTk82G04eHB/ODP1XlSLiPsjv/Z3FxUWZmZmRzc1NQxrl/LDExMQ5cNTDkHGOAVYMznre2tmRqakpWV1fl6enJAND1MxcHhNL8/LxMT0/LwsKC3N/fWyYokpVq4BAjhPNQfEoF28nJSbM9Pj4Wn04HBBsOqLKyUrKysuT29lbW1taEDE9PT8XnPvRnmQGCoWoAfH5+brorKytydXVldBcXF0tmZqbZfX5+Gu0OqLu7W7q6ukzh7u5O9vf3hcj8hnCRAUINzYP/QyZnZ2eyvr5uGRBoc3OzNDU1WY2hn0Ch1QH5dlJWViZ9fX1SU1Nj0Y2Njcnc3Jy8v78bGIboAUYNqAWULS8vW9QNDQ1CwDQSemRDjVX1t0YcJiUlCcodHR1SWFhoAHt7e1ZcOhIHdBhA1BQgfxykvLzcsigpKbFMVNUCg+Kwvi4j0qOLaNeqqippa2uzDOlAikwNaBBATk5OZGlpSXZ3dyUxMVHa29uls7NTACID8f/Innt8+o+/GQGgqgLvgNbX18vQ0JBFS81mZ2dlfHxcAIWum5sbyc3NldraWqmrqxPYUA0aBHsAAFINzlxGoBItFFFAVbWMiLa1tdWGELqYNejMy8uTwcFByyQtLU1UA7poGHz9LfhzQBQcTjFiMxAVwEQNjfn5+Tb9GOGkoKBAqqurrZ1xTq3wgR3vQ8EH4oBohlAJQFW1gfX3ns0WytBDINCCY4Ra4BSaKDyiGtCFDT4piwNKTU21FsUIUVVbP9SHTXF0dCQEgxEZMGM0A4FwRkcChi1C5gj3BOaAOCACuowoiYSiT0xM2MbI82vCMNIgUHZ5eSm8oxsJAHsEO55xTkeG4A6Il1AGNQDt7OzYkt3Y2BCyYWswL9SssbFREJyyquhGgPEBGDXmSkYI5w6IVQMAxlDCcmWPUfSWlhYbSO4zMjJsc/T09AhZosP22N7eFsBgBRAygWIaBL8OKD09XXjBZ4JVf3h4KEVFRTI8PCz9/f02mBirBoVmONkgDDc0wQABhgEDRmNQP8QBoYxz6sLWZvviiIHEAEPVAAQqVNWy7O3tFTY/y5V6QSUbhCywoRx25QehFixRIsvJyRGogTJamgX6tyF0AAbNZE1WdO319bXtRXzRrWwZaoSty+jg4EAuLi4kOzvbQFhBYVFZpKpBNgTFM3SoBiNQUVEhAwMDUlpaat8v6FNV+8TDBmAOiE8E3xGooKNoTfYZ0ZO+qgoOWFE8A4gD6ko2rCnsYINAYEJVbZsD5oBYjCMjI/bxIxOc8SEjcpxCE/+sEED4jB4SPjMCo6Oj1jzYYYPQRA4I5f9T/j2g/wAAAP//v0excQAAAAZJREFUAwBJiCKsx4qfAgAAAABJRU5ErkJggg==", 0.7);
    if (res && res.value && res.value.found) {
        wda.tap(res.value.x + wda.randomInt(0, res.value.width || 0), res.value.y + wda.randomInt(0, res.value.height || 0));
        wda.sleep(1);
    }

    var res = wda.findImage("iVBORw0KGgoAAAANSUhEUgAAABwAAAAbCAYAAABvCO8sAAADYElEQVR4AbSW107rQBBAZ03vvYsuEIgnXpAQX48EiH8AUUVH9JK+d84otkji6ziX3Chrb53jmZ2Z3UDKv8PDQ1+u/teXAU9OTvzW1pY8PT01HerLv+PjY5MdfH19+d7eXslmszI0NCSlUskGmqFmsVj0Kt9ELS8vy9HRkQ+6u7tdoVCQzs5OG3h/f5eLi4tfQff29vzt7a1/eHgQlS/IPz09lZWVFWcmnZ6edh8fHzYAeGJi4lfQzc1NQUZbW5spcX19LUtLS46GAan09fU5tGtvb6cpAwMDDZt3f38fE3o+ulQqyfDwsJyfn8v8/LzBEBwBaegE9/z8LEEQSH9/vzjnRL/O7+7upjIxmnV1dSFKsJjuoSwsLEQwBiqAdADNZDJUhffU1BTmsHbS4/Pz0zQDgnZvb2/S2tpaAWN9DZBOzHtzcyOYmDb7keRIOAjO4ZyT19dXuby8lNnZ2RoYsmKBDOBIhAsmZvNVAIJqTKsa+Y6ODgsr1gEOHYR2dfkrkIm62AGlroLN834mB2Ka/WbfGCcMtB6rGTIoiUAmqNe6+/t7aWlpETRVc4vuDzGGRzJF0FD3UMbHx511JDzqAlmre2hQ6uoIAnR0dBSnENVSXl5eUsFYnwrIRKC88dy7uzuqotrL4+MjKbGuZrZAH6mBOrcp/9RA1co8lCyi2ho8l8vJyMgIJrUx66zzSAUEpg5hokjExCempI6Xkga1LxW0LlC18MBw+3w+b8lA054bGxtzGjbRRxA+esT5g4ODRHAiULOG//7+NqGExdXVFQk5chCnPwYJCebhRNvb28LxRH9ciQWSrDX2PDlRtRHV0rL+4uJiBAuFKdMB1IC3Lrx4bW1NkGEdVY9Y4Pr6uqjJZHBw0KaTV6uzvg2UHzMzM04zkGBynApH2tjYiNW0AshFCjMS2GVZcnZ2JkmwcJ5CTNOw3dPTIzs7O2EzelcA+SpMyFeSPRQucWaMVldV9E7kWBdqyrBap+I8NSD2Vjf3bDqTKCxUk9bsGWNJBaiGiE3BkSYnJ4ULlHXow4Crq6sWwACZrGdfQ5qpnIo/5lXNzNkY4BDXq4aFS8DhicszQKH+8w5C378UzlMSAtdEksPc3Jxw/w1UZcdeIZR7iG52w2ZkbVwhZMLkoDCuKu4PAAAA///95cwiAAAABklEQVQDAJOnrjjdJkc4AAAAAElFTkSuQmCC", 0.7);
    if (res && res.value && res.value.found) {
        wda.tap(res.value.x + wda.randomInt(0, res.value.width || 0), res.value.y + wda.randomInt(0, res.value.height || 0));
        wda.sleep(1);
    }
    // 左上角返回坐标-黑色箭头-白底
    var res = wda.findImage("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", 0.7);
    if (res && res.value && res.value.found) {
        wda.tap(res.value.x + wda.randomInt(0, res.value.width || 0), res.value.y + wda.randomInt(0, res.value.height || 0));
        wda.sleep(1);
    }

    // 左上角返回坐标-白色箭头-随机底色
    var res = wda.findImage("iVBORw0KGgoAAAANSUhEUgAAABMAAAAgCAYAAADwvkPPAAADE0lEQVR4AaSV+08aQRDHv3uCCAKCAUSq1HfRGEmNMW3S/ta/vTZpWqzRqiCKAhUUOYXjIa/tzIrGBuRhN+zOsLffT+Z2Z+c0/EfT0ydSNg3VGfNq2E0yKl1+PzNUZ+irYKf73+VkIKAgamg0IEbsYmgYg+ZXVxWjnM8rWykWlR0KVs2nJYMquq7EtslJJGMx2DyzgicGhhWzCWmxWNAwDFjdbtaCXy0Yeq9APDEQrFHISrvHAxBMSsk65FIpZZ8PfWGFzJkcIQiaTUAImO12XCeT8L4NPUWEdusJ4zxyeL2Q9TpkraYkJwcH8M2tdoD4ocZDt85585hHwmoF93Q8juXwh64gZnSFHUe+PmwMr+CIWi0cRiKYWQm/COKlHbDo7o5c2diAfnkJUDJidBTxw99Y2/rcE9QBy55G5fzcIs/TwVkA0wiOf+1iaePlV1OL24PWtihdZaQvEECdNhsNCU7IOG12aPNT34geGQp2n89JFsNkgpWOvlmtIpNIDBwR2k2TRkGOOu0oXmfRKhuA2YwWbfj04vrAEbVZ0Gq1KvktUFGCpmnkAxKUoMobbtAskz6RS1/AOUXXxToKiJaCnh/+lBiyqVD4ahSuskraKpdhslgQXA7h6MfOUEAFY8rE9KIo3eSgmU3gfeP79y4cRnxv8Ag1Bj12u29OJOkU+b93dpaMhoW1dVzGYgNF+A+M1AiGNkX8YJ9dOt0yKvlb+GeCSB1F+wI7YEzhjDdy/Mrmh0JI+fdmYRnpo7OewK4wBjr8QVEulsjlJRrloY7Awhzy59cvAnklCbr/xn1+cX9HHwuSO1xUqsm6KYWMVJ68Tk1PGC8f87hERSegmf5RLhs3FYx73Sj9Oe8A9oURArYpp7jL3KJWqlPWMBWwUQXmZ8/7QDAWuIJuUTZ0WJyUhzTRuNMhG7q8Ook8RTgwjPRwz0+JxN43QCvB5LahVSvBuxhE9mJX8vOhYCyY3/4o4hEC8h2mbwPPOV0TbDA0jFVL219E9vSMXA5IYszhoKqTk6+CEQX+pS2qNml2QQWQPqke8RcAAP//6WxE5gAAAAZJREFUAwD0/Su9wdo4RQAAAABJRU5ErkJggg==", 0.7);
    if (res && res.value && res.value.found) {
        wda.tap(res.value.x + wda.randomInt(0, res.value.width || 0), res.value.y + wda.randomInt(0, res.value.height || 0));
        wda.sleep(1);
    }

}

// ================= 主线执行 =================

// 初始化：处理一遍前置弹窗
autoHandleAlert();
wda.airplaneOff();
wda.sleep(3);
wda.home();
wda.sleep(1);

if (!wda.isVPNConnected()) {

    // 启动 TikTok
    wda.launch("com.zhiliaoapp.musically");
    wda.sleep(5);

    // 配置参数（全部使用秒）
    const TARGET_SLEEP_SEC = 60 * 60; // 1小时累计 sleep 时间 = 3600秒
    let totalSleepSec = 0; // 用于累计总 sleep 秒数

    // 🏆 核心需求：点赞 3-20 次，关注并在本视频评论 1~点赞数 次 (被关注的必然被点赞和评论)
    let targetLikeCount = Math.floor(Math.random() * (12 - 3 + 1) + 3);
    let targetFollowCount = Math.floor(Math.random() * targetLikeCount) + 1;

    // 记录已经点赞和关注的次数
    let currentLikeCount = 0;
    let currentFollowCount = 0;

    // 预估 1 小时随机滑屏平均每个视频看 20 秒，大约会刷 180 个视频。
    // 为了让点赞和关注均匀分布在这 180 个视频里，我们设定一个极小的触发概率。
    // 当遇到喜欢的视频（触发概率）且还没达标时，才执行点赞或关注。

    while (true) {
        // 1. 检查累计 sleep 时间是否已达 1 小时，达到则跳出主循环
        if (totalSleepSec >= TARGET_SLEEP_SEC) {
            break;
        }
        //随机暂停秒数
        var rndtime = Math.floor(Math.random() * 2) + 1;
        // 查找是否在tiktok首页
        var homerest = wda.findImage("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", 0.7);
        if (!homerest.value.found) {
            // 通过首页房子判断是否在其他页
            var homerest2 = wda.findImage("iVBORw0KGgoAAAANSUhEUgAAADEAAAAoCAYAAABXRRJPAAAJ9UlEQVR4AaTZ144kxRIG4Pgb7713u3hvBQgjQEI8GtzBCyAkJB4ACXcBQnABEt574b333nSf+qJOsX2me5bDbGliMisrw/wRkZFZ1bP5fL6Yz/89LYZrPp8vfv3118WHH364eOSRRxZ33HHH4uabb17cdNNNi1tvvXVx++23L2655ZbFjTfeuLjtttsWjz766OKDDz5Y/Pbbb61zELH466+/Fr/88kuTezSf/zt7ZrWFa1BUaFBeH330Ub366qv1+uuv1+eff14///xz/fDDD7XXXnvVIYccUvvss0/9/vvv/eydd97peW+99VZ99dVXNQCoJLX77rt3O5/Pt2BN1ZZAJKk///yzvvvuu3rvvffqjTfeqCEaNXi4DjrooDrnnHPqvPPOq7POOqu2b99ehx12WBv3ySef1CuvvFKvvfZaffzxx8UJSWq33XZrEH/88UfLrX95rYDg4clDSVocDzE6SStj7IsvvlgPPPBAPf/88+35PfbYo71+1FFH1fXXX19nnHFGnXjiiXXRRRfVpZdeWieccEIx8rPPPqt33323nn322Y7g999/3+MATTqW9bPHM6SfpG1a/rcCwkOTGa6fpGazWRPjpcELL7zQ3pc+hHvO2+eee25ddtll7XlpJKUOPfTQBnPSSSc1kMMPP7wjRs5zzz1XTzzxRH399de17777dlr99NNPrQsQoNnBQXvuuWc7kG214VoBkaSF8Aqq4UpShH366aedDk8++WSnj7H999+/eP+0006r888/v4477riBY8efVAHk5JNP7udSDJ9xUXjppZcKmG+++aYYCnySjs5QNHrdAGHdAGBsh/SxtwLCMM9i0mLk7aGqdC7Lf94ijCFHH310GweAaEx85KAkvciPOOKIOvXUU+vss8+ubdu29ViSXvTWyUMPPVQWPIMnPn3kHrGFA/SXabZ8M/WTdDSS1I8//lhvvvlm5z4AUkiaMGr7sGhPP/304mWVKEkBB3wtXUmKMVIG6KuvvrqOPfbYrnAMkzoW+jPPPNNrRcFI0kAnWZPxdC+J7u6s/6/5RziPqz5KKC8JuXGCGC//pRHjknTOMjZJSzSX8mUSKSmH95JLLqmDDz64+URV9Xr88cdLKbZO8BGknVLbPGPLtAKCYt6U/4x/+eWX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", 0.7);
            if (!homerest2.value.found) {
                // 启动 TikTok
                wda.launch("com.zhiliaoapp.musically");
                wda.sleep(5);
                totalSleepSec += 5;
            } else {
                wda.tap(homerest2.value.x + wda.randomInt(0, homerest2.value.width || 0), homerest2.value.y + wda.randomInt(0, homerest2.value.height || 0));
            }
        }
        // 常规清理操作
        autoHandleAlert();
        autoCloseAlert();

        // 随机滑动刷视频
        wda.swipe(wda.randomInt(150, 160), wda.randomInt(400, 500),
            wda.randomInt(150, 180), wda.randomInt(250, 300),
            wda.randomInt(80, 250));

        // 2. 只有当前视频命中较小概率（例如 100 捞 15，即 15% 的概率），且点赞次数未满时，才点赞
        if (currentLikeCount < targetLikeCount && wda.randomInt(1, 100) <= 15) {
            let res = wda.findImage("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", 0.7);
            if (res && res.value && res.value.found) {
                wda.tap(res.value.x + wda.randomInt(0, res.value.width || 0), res.value.y + wda.randomInt(0, res.value.height || 0));
                wda.sleep(rndtime);
                totalSleepSec += rndtime;
                currentLikeCount++; // 点赞数 +1

                // 3. 点赞完成后，如果关注次数未满，按剩余比例概率进行关注+评论
                if (currentFollowCount < targetFollowCount) {
                    let remainingLikes = targetLikeCount - currentLikeCount; // 剩下还能点赞的次数
                    let remainingFollows = targetFollowCount - currentFollowCount; // 剩下必须关注的次数
                    let shouldFollow = false;

                    if (remainingFollows > remainingLikes) {
                        shouldFollow = true; // 剩下的赞必须全部触发关注才能达标
                    } else {
                        // 以剩下的比例作为概率触发
                        let p = remainingFollows / (remainingLikes + 1);
                        if (Math.random() <= p) {
                            shouldFollow = true;
                        }
                    }

                    if (shouldFollow) {
                        let res2 = wda.findImage("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", 0.7);
                        if (res2 && res2.value && res2.value.found) {
                            wda.tap(res2.value.x + wda.randomInt(0, res2.value.width || 0), res2.value.y + wda.randomInt(0, res2.value.height || 0));
                            wda.sleep(rndtime);
                            totalSleepSec += rndtime;
                            currentFollowCount++; // 关注数 +1

                        }

                        //自动评论-先点击白色评论按钮
                        let res3 = wda.findImage("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", 0.7);
                        if (res3 && res3.value && res3.value.found) {
                            wda.tap(res3.value.x + wda.randomInt(0, res3.value.width || 0), res3.value.y + wda.randomInt(0, res3.value.height || 0));
                            wda.sleep(rndtime);
                            totalSleepSec += rndtime;
                            //点击评论框
                            wda.tap(wda.randomInt(80, 200), wda.randomInt(620, 650));
                            wda.sleep(1);
                            totalSleepSec += 1;
                            //随机获取评论内容并输入，es-MX (墨西哥) | pt-BR (巴西)de-DE (德国) | en-SG (新加坡)ja-JP (日本) | en-US (美国)es-ES (西班牙) | en-GB (英国)fr-FR (法国) | zh-CN (中文)
                            var cmt = wda.getRandomComment("en-US");
                            wda.input(cmt);
                            wda.sleep(1);
                            totalSleepSec += 1;
                            //点击发送评论按钮
                            var res4 = wda.findImage("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", 0.7);
                            if (res4 && res4.value && res4.value.found) {
                                wda.tap(res4.value.x + wda.randomInt(0, res4.value.width || 0), res4.value.y + wda.randomInt(0, res4.value.height || 0));
                            }
                            wda.sleep(1);
                            totalSleepSec += 1;
                            // 点击关闭评论
                            var res5 = wda.findImage("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", 0.7);
                            if (res5 && res5.value && res5.value.found) {
                                wda.tap(res5.value.x + wda.randomInt(0, res5.value.width || 0), res5.value.y + wda.randomInt(0, res5.value.height || 0));
                            }

                        }

                    } // end shouldFollow
                } // end currentFollowCount < targetFollowCount
            } // end if (res && res.value && res.value.found)
        } // end if (currentLikeCount < targetLikeCount ... )

        // 4. 每个视频的滑屏停留等待时间（3~50秒随机浮动）
        const randomSec = Math.floor(Math.random() * (30 - 3 + 1) + 3);
        wda.sleep(randomSec);
        totalSleepSec += randomSec;

    } // -- ⬆️ While 主循环结束 --

    // ============== 善后操作 ==============
    wda.home();
    wda.sleep(2);
    wda.terminateAll();
    wda.airplaneOn();
}

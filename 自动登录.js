//自动登录
//墨西哥自动登录，因为需要连接vpn
var ok = wda.connectProxy("");
if (ok) {
    wda.log("VPN 重连成功（已恢复上次节点）");
} else {
    wda.log("没有上次VPN连接记录，跳过");
}
wda.sleep(3); // 等待隧道建立
autoHandleAlert();
wda.sleep(3);
wda.home();
wda.sleep(1);

// 启动 TikTok
wda.launch("com.zhiliaoapp.musically");
wda.sleep(10);



//点击‘我的’
wda.tap(wda.randomInt(330, 350), wda.randomInt(630, 660));
wda.sleep(2);

// 点击登陆框登录按钮
var res = wda.findImage("iVBORw0KGgoAAAANSUhEUgAAAB4AAABuCAYAAAAwEqNjAAAEJklEQVR4Aeya607zOhBFvcpFIOD9HxSEuJZzVtxx0rRUduv0x0ctbezYySzvSRzTwmq9Xv+s1+fXKp2p/Pz8pJDIs4FXq1UKAels4DQrF/AsIcsc+pCdPdVCv7+/z/twCV2v10l1c/z19ZV0YnAgwbZeXl6Sen19Te/v7/0cxxr1qRBufUjdHF9dXQ0vCGB4Q+neLKjPz8+hbzqR1fSgV1vHAf74+EhqHrs7WKgPT4DD8WLggAlUHoeczGJgnakpdB8wJtAt1VOgTgXAuKQ8nqoarBsDwhhMRz6xb29vyXHlBOwXAgxPuk98mpVqMGTg9HoBatpX264G+4IwqCCle2VbOdaiJjDkl4NAU6psqxao51aDPRkyWGDcT9uLOhashOhQoLJtn2MtanIcgYWFhKoYq62bwUKUYOtQLTDOK2DvmcEgLxsYa4O7lz4/PyfXrOe5Nq+vr5OyHQFr6wKGDJpfKETwvP/U4wLeF0igWgJ+ECzQJ1ftm9gpfQUMbMURqoSqrcEOBwUcsUxt6CxgGB0LFhpa3DGMcDPgBEIe91RJtQADA2UPdX2q2JnS0WX3wgKeDjmJqaZjvdoFDHnniftqLVwQbN8C+05VAUcggcoHyjrgMd6rLmAYHQtVgnuB5nEK2AHdKaFKsMdwxlQH1AktoS3HAnQYUNv2LaECNrVKiOvW9TuV/T1VwD2D1sS6gGuy1OWcS6q7pLEmSEm1vy/7JUmsZWD4rsqXiC+UmmAt5xRwy0U9zr2Ae2SxKsYl1VVp6nHSJdU9slgV45LqqjT1OOkPp/rh4SHd39+nm5ubYR92D3ZvtnZP7pHeaYx/K9VTZ7+1L45/y0z3/j+camD4fgtIUYChz8/JqXPZSTUwvEAg1/IWf4FAhvmNQAiQ3V07jgWaWgXLQHWxBQbKPRXsJCB//5U6ly2wsYEkVAlOC5UdcHCEKlgm3b+CYRlgMRYNl8xc/k3JPfrx8XE4zf3Zvxf7fxx+lvZvVV4D7ZP81fFAmvwAdtb3ZLi5WQ32fisYJ9BMm1zQBI4nfToBY5lu6xZVg4WGILsWdAzU65rAOg0BXj/oGHg1OIDWMEIH8hE/qsHGhgwEyhNu/zFqAuvW37tvb2+Tcp3bt2iq97mC7Fz4vvFDfU2OIxBkIDDsZouDI6UwAoW6zFJjaXYM2W0AhapGbv3/7IVbAbALBxyqVrPjiAyU+6v71FiOAgPDOm5kbZ1+FNi0z+We/fT0lPycfXd3N3zOjkz4GRvyZIGcqbRggQxzAjFRcbaPcuzFhwQZCGR3qxEj1AyMPen0YlCjAAWoW5cb5MmkTekA3kTaVJABARQ6lf2DNuefXIVbA8Eu3M3FTUU5ke6OBStgK90Cp/BFwJAdpz1lcPv/w7YI2LQfUtd7vMfcwa5FHB8kbgb/Hvg/AAAA//89zNVGAAAABklEQVQDANuzAziDAP7iAAAAAElFTkSuQmCC", 0.8);
if (res && res.value && res.value.found) {
    wda.tap(res.value.x + wda.randomInt(0, res.value.width + 200 || 0), res.value.y + wda.randomInt(0, res.value.height || 0));
}
wda.sleep(2);

//点击通过邮箱登录
var res = wda.findImage("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", 0.8);
if (res && res.value && res.value.found) {
    wda.tap(res.value.x + wda.randomInt(0, res.value.width + 200 || 0), res.value.y + wda.randomInt(0, res.value.height || 0));
}

wda.sleep(2);
// 点击邮箱登录
wda.tap(wda.randomInt(150, 320), wda.randomInt(80, 90));

wda.sleep(2);

// 点击邮箱登陆框
wda.tap(wda.randomInt(50, 250), wda.randomInt(140, 170));

wda.sleep(1);
// [TK主账号] 输入用户名
var acc = wda.getMasterTkAccount();
if (acc && acc.length > 0) {
    wda.input(acc);
}
wda.sleep(2);
//点击登录按钮
wda.tap(wda.randomInt(110, 300), wda.randomInt(350, 380));
wda.sleep(10);
//点击密码输入框
wda.tap(wda.randomInt(60, 250), wda.randomInt(165, 190));
wda.sleep(2);
// [样例参考]: [TK主账号] 输入密码
var pwd = wda.getMasterTkPassword();
if (pwd && pwd.length > 0) {
    wda.input(pwd);
}
wda.sleep(2);
// 点击登录
wda.tap(wda.randomInt(80, 300), wda.randomInt(370, 400));
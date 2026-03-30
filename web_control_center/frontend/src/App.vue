<script setup lang="ts">
import { ref, onMounted, computed, watch, nextTick } from 'vue';

const hostname = window.location.hostname;
// 智能识别 API 地址：如果是公网域名访问，则指向 s.ecmain.site；否则维持本地端口。
const apiBase = hostname.includes('ecmain.site') 
  ? `http://s.ecmain.site:8088/api` 
  : `http://${hostname}:8088/api`;

// ================= 认证系统 =================
const isLoggedIn = ref(false);
const currentUser = ref<any>(null);      // { id, username, role }
const authToken = ref('');
const loginForm = ref({ username: '', password: '' });
const loginError = ref('');
const loginLoading = ref(false);

// 角色判断
const isSuperAdmin = computed(() => currentUser.value?.role === 'super_admin');

// 带认证的 fetch 封装
const authFetch = (url: string, options: any = {}) => {
  if (!options.headers) options.headers = {};
  if (authToken.value) {
    options.headers['Authorization'] = `Bearer ${authToken.value}`;
  }
  if (!options.headers['Content-Type'] && options.body && typeof options.body === 'string') {
    options.headers['Content-Type'] = 'application/json';
  }
  return fetch(url, options);
};

// 登录
const doLogin = async () => {
  loginError.value = '';
  loginLoading.value = true;
  try {
    const res = await fetch(`${apiBase}/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(loginForm.value)
    });
    const data = await res.json();
    if (data.status === 'ok') {
      authToken.value = data.token;
      currentUser.value = data.user;
      isLoggedIn.value = true;
      localStorage.setItem('ec_token', data.token);
      localStorage.setItem('ec_user', JSON.stringify(data.user));
      loginError.value = '';
      // 登录成功后初始化数据
      initAllData();
    } else {
      loginError.value = data.detail || '用户名或密码错误';
    }
  } catch (err) {
    loginError.value = '网络连接失败，请检查服务端';
  } finally {
    loginLoading.value = false;
  }
};

// 登出
const doLogout = () => {
  authToken.value = '';
  currentUser.value = null;
  isLoggedIn.value = false;
  localStorage.removeItem('ec_token');
  localStorage.removeItem('ec_user');
};

// 从 localStorage 恢复登录状态
const restoreSession = async () => {
  const savedToken = localStorage.getItem('ec_token');
  const savedUser = localStorage.getItem('ec_user');
  if (savedToken && savedUser) {
    authToken.value = savedToken;
    currentUser.value = JSON.parse(savedUser);
    isLoggedIn.value = true;
    // 验证 Token 是否仍然有效
    try {
      const res = await fetch(`${apiBase}/auth/me`, {
        headers: { 'Authorization': `Bearer ${savedToken}` }
      });
      if (res.ok) {
        const data = await res.json();
        currentUser.value = data.user;
        localStorage.setItem('ec_user', JSON.stringify(data.user));
      } else {
        doLogout(); // Token 过期，强制登出
      }
    } catch {
      // 网络不可达时保持登录状态
    }
  }
};

// 动态标签页列表（根据角色过滤）
const visibleTabs = computed(() => {
  const all = ['📱 手机列表', '⚡️ 控制台', '📋 任务列表', '⚡ 一次性任务', '⚙️ 配置中心', '💬 评论管理', '🎵 TikTok 账号', '📁 文件管理', '👤 用户管理'];
  if (isSuperAdmin.value) return all;
  // 普通管理员隐藏配置中心、评论管理、用户管理
  return all.filter(t => !['⚙️ 配置中心', '💬 评论管理', '👤 用户管理'].includes(t));
});

// ================= 用户管理 (超管专用) =================
const adminList = ref<any[]>([]);
const showCreateAdminModal = ref(false);
const newAdminForm = ref({ username: '', password: '', role: 'admin' });
const showPasswordModal = ref(false);
const editPasswordForm = ref({ admin_id: 0, username: '', password: '' });
const showAssignDeviceModal = ref(false);
const assigningAdmin = ref<any>(null);

const fetchAdmins = async () => {
  try {
    const res = await authFetch(`${apiBase}/admins`);
    const data = await res.json();
    if (data.status === 'ok') adminList.value = data.data;
  } catch (err) {
    console.error('拉取管理员列表失败', err);
  }
};

const createAdmin = async () => {
  try {
    const res = await authFetch(`${apiBase}/admins`, {
      method: 'POST',
      body: JSON.stringify(newAdminForm.value)
    });
    if (res.ok) {
      showCreateAdminModal.value = false;
      newAdminForm.value = { username: '', password: '', role: 'admin' };
      fetchAdmins();
    } else {
      const d = await res.json();
      alert(d.detail || '创建失败');
    }
  } catch (err) { alert('网络错误'); }
};

const deleteAdmin = async (id: number) => {
  if (!confirm('确定删除该管理员？相关设备分配也会一并清除。')) return;
  try {
    const res = await authFetch(`${apiBase}/admins/${id}`, { method: 'DELETE' });
    if (res.ok) fetchAdmins();
    else { const d = await res.json(); alert(d.detail || '删除失败'); }
  } catch (err) { alert('网络错误'); }
};

const openPasswordModal = (admin: any) => {
  editPasswordForm.value = { admin_id: admin.id, username: admin.username, password: '' };
  showPasswordModal.value = true;
};

const updatePassword = async () => {
  try {
    const res = await authFetch(`${apiBase}/admins/${editPasswordForm.value.admin_id}/password`, {
      method: 'PUT',
      body: JSON.stringify({ password: editPasswordForm.value.password })
    });
    if (res.ok) {
      showPasswordModal.value = false;
      alert('密码修改成功');
    } else {
      const d = await res.json();
      alert(d.detail || '修改失败');
    }
  } catch (err) { alert('网络错误'); }
};

const openAssignDeviceModal = (admin: any) => {
  assigningAdmin.value = { ...admin };
  showAssignDeviceModal.value = true;
};

const assignDevice = async (udid: string) => {
  if (!assigningAdmin.value) return;
  try {
    const res = await authFetch(`${apiBase}/admins/${assigningAdmin.value.id}/devices`, {
      method: 'POST',
      body: JSON.stringify({ device_udid: udid })
    });
    if (res.ok) {
      fetchAdmins();
      // 刷新 assigningAdmin 数据
      const updated = adminList.value.find((a: any) => a.id === assigningAdmin.value.id);
      if (updated) assigningAdmin.value = { ...updated };
    }
  } catch (err) { console.error('分配设备失败', err); }
};

const removeDevice = async (adminId: number, udid: string) => {
  try {
    const res = await authFetch(`${apiBase}/admins/${adminId}/devices/${udid}`, { method: 'DELETE' });
    if (res.ok) {
      fetchAdmins();
      if (assigningAdmin.value?.id === adminId) {
        const updated = adminList.value.find((a: any) => a.id === adminId);
        if (updated) assigningAdmin.value = { ...updated };
      }
    }
  } catch (err) { console.error('取消分配失败', err); }
};

const initAllData = () => {
  fetchDevices();
  fetchScripts();
  fetchCountries();
  fetchGroups();
  fetchExecTimes();
  fetchTiktokAccounts();
  fetchOneshotTasks();
  fetchSharedFiles();
  if (isSuperAdmin.value) fetchAdmins();
};

// ================= 文件管理 =================
const sharedFiles = ref<any[]>([]);
const fileUploading = ref(false);

const fetchSharedFiles = async () => {
  try {
    const res = await authFetch(`${apiBase}/files`);
    if (res.ok) {
      const data = await res.json();
      sharedFiles.value = data.files || [];
    }
  } catch (e) { /* 忽略 */ }
};

const uploadSharedFile = async (event: Event) => {
  const input = event.target as HTMLInputElement;
  if (!input.files || input.files.length === 0) return;
  fileUploading.value = true;
  try {
    const formData = new FormData();
    const file = input.files[0];
    if (file) {
      formData.append('file', file);
    }
    const res = await authFetch(`${apiBase}/files/upload`, {
      method: 'POST',
      body: formData
    });
    if (res.ok) {
      await fetchSharedFiles();
    } else {
      const err = await res.json();
      alert(err.detail || '上传失败');
    }
  } catch (e) {
    alert('上传失败: 网络异常');
  } finally {
    fileUploading.value = false;
    input.value = ''; // 重置 input
  }
};

const deleteSharedFile = async (filename: string) => {
  if (!confirm(`确定要删除文件 "${filename}" 吗？`)) return;
  try {
    const res = await authFetch(`${apiBase}/files/${encodeURIComponent(filename)}`, {
      method: 'DELETE'
    });
    if (res.ok) {
      await fetchSharedFiles();
    }
  } catch (e) { /* 忽略 */ }
};

const copyFileDownloadLink = (filename: string) => {
  const link = `${apiBase}/files/download/${encodeURIComponent(filename)}`;
  navigator.clipboard.writeText(link).then(() => {
    alert('✅ 下载链接已复制到剪切板');
  }).catch(() => {
    prompt('复制下载链接:', link);
  });
};

const formatFileSize = (bytes: number) => {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
};

const showTaskError = (t: any) => {
  if (!t) return;
  alert(`【${t.task_name}】执行失败\n\n最后指令:\n${t.last_command}\n\n错误信息:\n${t.error}`);
};

const devices = ref<any[]>([]);
const isDevicesLoading = ref(false); // [v1739] 矩阵刷新加载状态
const selectedDevice = ref('');
const deviceIp = ref('');
const connectionMode = ref<'usb' | 'lan' | 'ws'>('usb');
const ecmainUrl = computed(() => { return deviceIp.value ? `http://${deviceIp.value}:8089` : ''; });
const logs = ref<string[]>(['[系统] ECWDA Web控制台已就绪。']);
const streamUrl = ref('');
const actionQueue = ref<any[]>([]);
const generatedJs = ref(''); 
const activeTab = ref('📱 手机列表'); // "📱 手机列表" | "⚡️ 控制台" | "🎮 批量控制" | ...
const batchStreams = ref<Record<string, string>>({}); // { [udid]: streamUrl }
const batchImageData = ref<Record<string, string>>({}); // { [udid]: base64_image }
const batchSockets = ref<Record<string, WebSocket>>({}); // { [udid]: WebSocket }
const batchConnectionModes = ref<Record<string, string>>({}); // { [udid]: 'usb'|'lan'|'ws' }
const slaveQuality = ref('low'); // 从机画质：low(模糊) / medium(普通) / high(高清)
// const batchLatencies = ref<Record<string, string>>({}); // { [udid]: latency_ms }
// const batchCanvasRefs = ref<Record<string, HTMLCanvasElement>>({}); // { [udid]: canvas_el }

// ==================== TikTok 账号管理 ====================
const tiktokAccounts = ref<any[]>([]);
const isTkModalOpen = ref(false);
const editingTkAccount = ref<any>({});
const tkFilterForm = ref({
  country: '',
  device_no: '',
  account: '',
  fans_min: null as number | null,
  fans_max: null as number | null,
  is_window_opened: 'all' as 'all' | 'yes' | 'no',
  is_for_sale: 'all' as 'all' | 'yes' | 'no',
  admin: ''
});

const fetchTiktokAccounts = async () => {
  try {
    const res = await authFetch(`${apiBase}/tiktok_accounts`);
    const data = await res.json();
    if (data.status === 'ok') tiktokAccounts.value = data.data;
  } catch (err) {
    console.error('拉取 TikTok 账号列表失败', err);
  }
};

const openTkModal = (tk: any) => {
  editingTkAccount.value = { ...tk };
  isTkModalOpen.value = true;
};

const openAddTkModal = (grp: any) => {
  editingTkAccount.value = {
    device_udid: grp.device_udid,
    device_no: grp.device_no,
    account: '',
    password: '',
    email: '',
    country: grp.country || '',
    fans_count: 0,
    is_window_opened: 0,
    is_for_sale: 0
  };
  isTkModalOpen.value = true;
};

const saveTkAccount = async () => {
  try {
    const body = {
      country: editingTkAccount.value.device_country || '',
      fans_count: parseInt(editingTkAccount.value.fans_count) || 0,
      is_window_opened: editingTkAccount.value.is_window_opened ? 1 : 0,
      is_for_sale: editingTkAccount.value.is_for_sale ? 1 : 0,
      add_time: editingTkAccount.value.add_time || '',
      window_open_time: editingTkAccount.value.window_open_time || '',
      sale_time: editingTkAccount.value.sale_time || '',
      password: editingTkAccount.value.password || '',
      email: editingTkAccount.value.email || ''
    };
    
    let res;
    if (editingTkAccount.value.id) {
      // 存在 ID -> 更新
      res = await authFetch(`${apiBase}/tiktok_accounts/${editingTkAccount.value.id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      });
    } else {
      // 不存在 ID -> 新建
      const postBody = {
        ...body,
        device_udid: editingTkAccount.value.device_udid,
        account: editingTkAccount.value.account,
        password: editingTkAccount.value.password || '',
        email: editingTkAccount.value.email || ''
      };
      res = await authFetch(`${apiBase}/tiktok_accounts`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(postBody)
      });
    }

    if (res.ok) {
      isTkModalOpen.value = false;
      fetchTiktokAccounts();
    }
  } catch (err) {
    console.error('保存 TikTok 账号失败', err);
  }
};

const deleteTkAccount = async (id: number) => {
  if (!confirm('确定要删除该 TikTok 账号记录吗？')) return;
  try {
    const res = await authFetch(`${apiBase}/tiktok_accounts/${id}`, { method: 'DELETE' });
    if (res.ok) fetchTiktokAccounts();
  } catch (err) {
    console.error('删除 TikTok 账号失败', err);
  }
};

const setPrimaryTkAccount = async (tk: any) => {
  if (tk.is_primary) return; 
  try {
    // 乐观更新：立即在本地置顶该账号
    const udid = tk.device_udid;
    tiktokAccounts.value.forEach(a => {
        if (a.device_udid === udid) {
            a.is_primary = (a.id === tk.id ? 1 : 0);
        }
    });

    const res = await authFetch(`${apiBase}/tiktok_accounts/${tk.id}/primary`, {
      method: 'PUT'
    });
    if (res.ok) {
      fetchTiktokAccounts();
    }
  } catch (err) {
    console.error('设置主号失败', err);
    fetchTiktokAccounts();
  }
};

// 按设备分组且带多维度筛选的计算属性
const groupedTiktokAccounts = computed(() => {
  // 1. 预处理数据：将设备所属管理员及国家信息注入到账号数据中，方便后续统一过滤
  const deviceAdminMap = new Map<string, string>();
  const deviceCountryMap = new Map<string, string>();
  for (const d of devices.value) {
    deviceAdminMap.set(d.udid, d.admin_username || '');
    deviceCountryMap.set(d.udid, d.country || '');
  }

  // 2. 执行多维度过滤
  const filtered = tiktokAccounts.value.filter(tk => {
    // 归属国家筛选 (基于关联设备的归属国家)
    const deviceCountry = deviceCountryMap.get(tk.device_udid) || '';
    if (tkFilterForm.value.country && deviceCountry !== tkFilterForm.value.country) return false;
    
    // 设备名筛选 (不区分大小写包含)
    if (tkFilterForm.value.device_no && !tk.device_no?.toLowerCase().includes(tkFilterForm.value.device_no.toLowerCase())) return false;
    
    // 账号名筛选 (不区分大小写包含)
    if (tkFilterForm.value.account && !tk.account?.toLowerCase().includes(tkFilterForm.value.account.toLowerCase())) return false;
    
    // 粉丝区间筛选
    const fans = tk.fans_count || 0;
    if (tkFilterForm.value.fans_min !== null && fans < tkFilterForm.value.fans_min) return false;
    if (tkFilterForm.value.fans_max !== null && fans > tkFilterForm.value.fans_max) return false;
    
    // 是否开窗
    if (tkFilterForm.value.is_window_opened === 'yes' && !tk.is_window_opened) return false;
    if (tkFilterForm.value.is_window_opened === 'no' && tk.is_window_opened) return false;
    
    // 是否出售
    if (tkFilterForm.value.is_for_sale === 'yes' && !tk.is_for_sale) return false;
    if (tkFilterForm.value.is_for_sale === 'no' && tk.is_for_sale) return false;
    
    // 所属管理员
    const owner = deviceAdminMap.get(tk.device_udid) || '';
    if (tkFilterForm.value.admin && owner !== tkFilterForm.value.admin) return false;
    
    return true;
  });

  // 3. 执行分组
  const map = new Map<string, { device_udid: string; device_no: string; country: string; accounts: any[] }>();
  for (const tk of filtered) {
    const udid = tk.device_udid || 'unknown';
    if (!map.has(udid)) {
      const dCountry = deviceCountryMap.get(udid) || '';
      map.set(udid, { device_udid: udid, device_no: tk.device_no || '未知/已删除设备', country: dCountry, accounts: [] });
    }
    map.get(udid)!.accounts.push(tk);
  }
  
  // 对每个分组内的账号按主号标识排序 (主号置顶)
  for (const group of map.values()) {
    group.accounts.sort((a, b) => (b.is_primary ? 1 : 0) - (a.is_primary ? 1 : 0));
  }
  
  return Array.from(map.values());
});

// ==================== 评论管理 ====================
const comments = ref<any[]>([]);
const commentFilterLang = ref('');

const fetchComments = async () => {
  if (!commentFilterLang.value) {
    comments.value = [];
    return;
  }
  try {
    const res = await authFetch(`${apiBase}/comments?language=${commentFilterLang.value}`);
    const data = await res.json();
    if (data.status === 'ok') comments.value = data.data;
  } catch (err) {
    console.error('拉取评论失败', err);
  }
};

const deleteComment = async (id: number) => {
  if (!confirm("确定要删除这条通用评论吗？")) return;
  try {
    const res = await authFetch(`${apiBase}/comments/${id}`, { method: 'DELETE' });
    if (res.ok) fetchComments();
  } catch (err) {
    console.error('删除评论失败', err);
  }
};


// ==================== 自动化脚本任务管理 ====================
const scripts = ref<any[]>([]);
const isScriptModalOpen = ref(false);
const editingScript = ref<any>({ id: 0, name: '', code: '', country: '', group_name: '', exec_time: '' });

const fetchScripts = async () => {
  try {
    const res = await authFetch(`${apiBase}/scripts`);
    const data = await res.json();
    if (data.status === 'ok') scripts.value = data.data;
  } catch (err) {
    console.error('拉取脚本失败', err);
  }
};

const openScriptModal = (script: any = null) => {
  if (script) {
    editingScript.value = { ...script };
  } else {
    editingScript.value = { id: 0, name: '', code: '', country: '', group_name: '', exec_time: '' };
  }
  isScriptModalOpen.value = true;
};

const saveScript = async () => {
  if (!editingScript.value.name || !editingScript.value.code) {
    alert("名称和代码不可为空");
    return;
  }
  try {
    const method = editingScript.value.id ? 'PUT' : 'POST';
    const url = editingScript.value.id ? `${apiBase}/scripts/${editingScript.value.id}` : `${apiBase}/scripts`;
    const res = await authFetch(url, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ 
          name: editingScript.value.name, 
          code: editingScript.value.code,
          country: (editingScript.value as any).country || "",
          group_name: (editingScript.value as any).group_name || "",
          exec_time: (editingScript.value as any).exec_time || ""
      })
    });
    const data = await res.json();
    if (data.status === 'ok') {
      isScriptModalOpen.value = false;
      fetchScripts();
    } else {
      alert("保存失败: " + data.detail);
    }
  } catch (err) {
    alert("网络错误: " + err);
  }
};

const deleteScript = async (id: number) => {
  if (!confirm("确定要删除这个自动任务脚本吗？")) return;
  try {
    await authFetch(`${apiBase}/scripts/${id}`, { method: 'DELETE' });
    fetchScripts();
  } catch (err) {
    console.error('删除脚本失败', err);
  }
};

// ==================== 配置中心及元数据过滤 ====================
const countries = ref<any[]>([]);
const groups = ref<any[]>([]);
const execTimes = ref<any[]>([]);

const newCountryName = ref('');
const newGroupName = ref('');
const newExecTimeName = ref('');

const fetchCountries = async () => {
  try {
    const res = await authFetch(`${apiBase}/countries`);
    const data = await res.json();
    if (data.status === 'ok') countries.value = data.data;
  } catch (err) { console.error(err); }
};

const fetchGroups = async () => {
  try {
    const res = await authFetch(`${apiBase}/groups`);
    const data = await res.json();
    if (data.status === 'ok') groups.value = data.data;
  } catch (err) { console.error(err); }
};

const addCountry = async () => {
  if (!newCountryName.value.trim()) return;
  try {
    const res = await authFetch(`${apiBase}/countries`, {
      method: 'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({name: newCountryName.value.trim()})
    });
    if (res.ok) { newCountryName.value = ''; fetchCountries(); }
    else alert("添加失败，可能该国家已存在");
  } catch (err) { alert(err); }
};

const deleteCountry = async (id: number) => {
  if (!confirm("确定删除选中项吗？")) return;
  try { await authFetch(`${apiBase}/countries/${id}`, {method: 'DELETE'}); fetchCountries(); } catch(err){}
};

const addGroup = async () => {
  if (!newGroupName.value.trim()) return;
  try {
    const res = await authFetch(`${apiBase}/groups`, {
      method: 'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({name: newGroupName.value.trim()})
    });
    if (res.ok) { newGroupName.value = ''; fetchGroups(); }
    else alert("添加失败，可能该分组已存在");
  } catch (err) { alert(err); }
};

const deleteGroup = async (id: number) => {
  if (!confirm("确定删除选中项吗？")) return;
  try { await authFetch(`${apiBase}/groups/${id}`, {method: 'DELETE'}); fetchGroups(); } catch(err){}
};

const fetchExecTimes = async () => {
  try {
    const res = await authFetch(`${apiBase}/exec_times`);
    const data = await res.json();
    if (data.status === 'ok') execTimes.value = data.data;
  } catch (err) { console.error(err); }
};

const addExecTime = async () => {
  if (!newExecTimeName.value.trim()) return;
  try {
    const res = await authFetch(`${apiBase}/exec_times`, {
      method: 'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({name: newExecTimeName.value.trim()})
    });
    if (res.ok) { newExecTimeName.value = ''; fetchExecTimes(); }
    else alert("添加失败，可能该时间已存在");
  } catch (err) { alert(err); }
};

const deleteExecTime = async (id: number) => {
  if (!confirm("确定删除选中时间吗？")) return;
  try { await authFetch(`${apiBase}/exec_times/${id}`, {method: 'DELETE'}); fetchExecTimes(); } catch(err){}
};

onMounted(async () => {
  await restoreSession();
  if (isLoggedIn.value) {
    initAllData();
    setInterval(fetchDevices, 5000); // 统一 5s 轮询
  }
});

const activeRightTab = ref('code'); // 顶部导航状态

// ========== 伪装信息生成器 ==========
// 设备型号预设数据（machineModel → 屏幕参数 + 系统版本建议）
const devicePresets: Record<string, {name: string, screenWidth: string, screenHeight: string, screenScale: string, nativeBounds: string, maxFPS: string, deviceModel: string}> = {
  'iPhone9,1':  {name: 'iPhone 7',         screenWidth: '375', screenHeight: '667', screenScale: '2.0', nativeBounds: '750x1334',   maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone9,3':  {name: 'iPhone 7',         screenWidth: '375', screenHeight: '667', screenScale: '2.0', nativeBounds: '750x1334',   maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone10,1': {name: 'iPhone 8',         screenWidth: '375', screenHeight: '667', screenScale: '2.0', nativeBounds: '750x1334',   maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone10,4': {name: 'iPhone 8',         screenWidth: '375', screenHeight: '667', screenScale: '2.0', nativeBounds: '750x1334',   maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone10,2': {name: 'iPhone 8 Plus',    screenWidth: '414', screenHeight: '736', screenScale: '3.0', nativeBounds: '1242x2208',  maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone10,5': {name: 'iPhone 8 Plus',    screenWidth: '414', screenHeight: '736', screenScale: '3.0', nativeBounds: '1242x2208',  maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone12,1': {name: 'iPhone 11',        screenWidth: '414', screenHeight: '896', screenScale: '2.0', nativeBounds: '828x1792',   maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone13,2': {name: 'iPhone 12',        screenWidth: '390', screenHeight: '844', screenScale: '3.0', nativeBounds: '1170x2532',  maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone14,5': {name: 'iPhone 13',        screenWidth: '390', screenHeight: '844', screenScale: '3.0', nativeBounds: '1170x2532',  maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone14,2': {name: 'iPhone 13 Pro',    screenWidth: '390', screenHeight: '844', screenScale: '3.0', nativeBounds: '1170x2532',  maxFPS: '120', deviceModel: 'iPhone'},
  'iPhone14,3': {name: 'iPhone 13 Pro Max',screenWidth: '428', screenHeight: '926', screenScale: '3.0', nativeBounds: '1284x2778',  maxFPS: '120', deviceModel: 'iPhone'},
  'iPhone14,4': {name: 'iPhone 13 mini',   screenWidth: '375', screenHeight: '812', screenScale: '3.0', nativeBounds: '1125x2436',  maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone15,2': {name: 'iPhone 14 Pro',    screenWidth: '393', screenHeight: '852', screenScale: '3.0', nativeBounds: '1179x2556',  maxFPS: '120', deviceModel: 'iPhone'},
  'iPhone15,3': {name: 'iPhone 14 Pro Max',screenWidth: '430', screenHeight: '932', screenScale: '3.0', nativeBounds: '1290x2796',  maxFPS: '120', deviceModel: 'iPhone'},
  'iPhone15,4': {name: 'iPhone 15',        screenWidth: '393', screenHeight: '852', screenScale: '3.0', nativeBounds: '1179x2556',  maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone15,5': {name: 'iPhone 15 Plus',   screenWidth: '430', screenHeight: '932', screenScale: '3.0', nativeBounds: '1290x2796',  maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone16,1': {name: 'iPhone 15 Pro',    screenWidth: '393', screenHeight: '852', screenScale: '3.0', nativeBounds: '1179x2556',  maxFPS: '120', deviceModel: 'iPhone'},
  'iPhone16,2': {name: 'iPhone 15 Pro Max',screenWidth: '430', screenHeight: '932', screenScale: '3.0', nativeBounds: '1290x2796',  maxFPS: '120', deviceModel: 'iPhone'},
  'iPhone17,1': {name: 'iPhone 16 Pro',    screenWidth: '402', screenHeight: '874', screenScale: '3.0', nativeBounds: '1206x2622',  maxFPS: '120', deviceModel: 'iPhone'},
  'iPhone17,2': {name: 'iPhone 16 Pro Max',screenWidth: '440', screenHeight: '956', screenScale: '3.0', nativeBounds: '1320x2868',  maxFPS: '120', deviceModel: 'iPhone'},
  'iPhone17,3': {name: 'iPhone 16',        screenWidth: '393', screenHeight: '852', screenScale: '3.0', nativeBounds: '1179x2556',  maxFPS: '60',  deviceModel: 'iPhone'},
  'iPhone17,4': {name: 'iPhone 16 Plus',   screenWidth: '430', screenHeight: '932', screenScale: '3.0', nativeBounds: '1290x2796',  maxFPS: '60',  deviceModel: 'iPhone'},
};

// 国家预设数据（与 ECDeviceInfoManager.countryPresets 一致）
const countryPresets: Record<string, {name: string, language: string, timezone: string, currency: string, mcc: string, mnc: string, carrier: string}> = {
  'JP': {name: '日本',      language: 'ja-JP',       timezone: 'Asia/Tokyo',         currency: 'JPY', mcc: '440', mnc: '10',  carrier: 'NTT DoCoMo'},
  'US': {name: '美国',      language: 'en-US',       timezone: 'America/New_York',   currency: 'USD', mcc: '310', mnc: '260', carrier: 'T-Mobile'},
  'KR': {name: '韩国',      language: 'ko-KR',       timezone: 'Asia/Seoul',         currency: 'KRW', mcc: '450', mnc: '05',  carrier: 'SK Telecom'},
  'BR': {name: '巴西',      language: 'pt-BR',       timezone: 'America/Sao_Paulo',  currency: 'BRL', mcc: '724', mnc: '11',  carrier: 'Vivo'},
  'GB': {name: '英国',      language: 'en-GB',       timezone: 'Europe/London',      currency: 'GBP', mcc: '234', mnc: '10',  carrier: 'O2'},
  'DE': {name: '德国',      language: 'de-DE',       timezone: 'Europe/Berlin',      currency: 'EUR', mcc: '262', mnc: '01',  carrier: 'Telekom'},
  'FR': {name: '法国',      language: 'fr-FR',       timezone: 'Europe/Paris',       currency: 'EUR', mcc: '208', mnc: '01',  carrier: 'Orange'},
  'RU': {name: '俄罗斯',    language: 'ru-RU',       timezone: 'Europe/Moscow',      currency: 'RUB', mcc: '250', mnc: '01',  carrier: 'MTS'},
  'IN': {name: '印度',      language: 'hi-IN',       timezone: 'Asia/Kolkata',       currency: 'INR', mcc: '404', mnc: '10',  carrier: 'AirTel'},
  'ID': {name: '印度尼西亚', language: 'id-ID',       timezone: 'Asia/Jakarta',       currency: 'IDR', mcc: '510', mnc: '10',  carrier: 'Telkomsel'},
  'TH': {name: '泰国',      language: 'th-TH',       timezone: 'Asia/Bangkok',       currency: 'THB', mcc: '520', mnc: '01',  carrier: 'AIS'},
  'VN': {name: '越南',      language: 'vi-VN',       timezone: 'Asia/Ho_Chi_Minh',   currency: 'VND', mcc: '452', mnc: '01',  carrier: 'Mobifone'},
  'PH': {name: '菲律宾',    language: 'fil-PH',      timezone: 'Asia/Manila',        currency: 'PHP', mcc: '515', mnc: '02',  carrier: 'Globe'},
  'MY': {name: '马来西亚',  language: 'ms-MY',       timezone: 'Asia/Kuala_Lumpur',  currency: 'MYR', mcc: '502', mnc: '12',  carrier: 'Maxis'},
  'SG': {name: '新加坡',    language: 'en-SG',       timezone: 'Asia/Singapore',     currency: 'SGD', mcc: '525', mnc: '01',  carrier: 'SingTel'},
  'TW': {name: '台湾',      language: 'zh-Hant',     timezone: 'Asia/Taipei',        currency: 'TWD', mcc: '466', mnc: '92',  carrier: 'Chunghwa Telecom'},
  'HK': {name: '香港',      language: 'zh-Hant-HK',  timezone: 'Asia/Hong_Kong',     currency: 'HKD', mcc: '454', mnc: '00',  carrier: 'CSL'},
  'AU': {name: '澳大利亚',  language: 'en-AU',       timezone: 'Australia/Sydney',   currency: 'AUD', mcc: '505', mnc: '01',  carrier: 'Telstra'},
  'MX': {name: '墨西哥',    language: 'es-MX',       timezone: 'America/Mexico_City',currency: 'MXN', mcc: '334', mnc: '020', carrier: 'Telcel'},
  'AR': {name: '阿根廷',    language: 'es-AR',       timezone: 'America/Buenos_Aires',currency:'ARS', mcc: '722', mnc: '310', carrier: 'Claro'},
  'CN': {name: '中国',      language: 'zh-Hans',     timezone: 'Asia/Shanghai',      currency: 'CNY', mcc: '460', mnc: '00',  carrier: '中国移动'},
};

// 系统版本预设数据
const systemVersionPresets: Record<string, {buildVersion: string, kernelVersion: string}> = {
  '15.8.6': {buildVersion: '19H402',  kernelVersion: 'Darwin Kernel Version 21.6.0: Sun Oct 15 00:18:06 PDT 2023; root:xnu-8020.242.18.707.3~1/RELEASE_ARM64_T8010'},
  '16.0':   {buildVersion: '20A362',  kernelVersion: 'Darwin Kernel Version 22.0.0'},
  '16.5':   {buildVersion: '20F66',   kernelVersion: 'Darwin Kernel Version 22.5.0'},
  '16.6':   {buildVersion: '20G75',   kernelVersion: 'Darwin Kernel Version 22.6.0'},
  '16.7':   {buildVersion: '20H19',   kernelVersion: 'Darwin Kernel Version 22.6.0'},
  '17.0':   {buildVersion: '21A329',  kernelVersion: 'Darwin Kernel Version 23.0.0'},
  '17.5':   {buildVersion: '21F79',   kernelVersion: 'Darwin Kernel Version 23.5.0'},
  '18.0':   {buildVersion: '22A3354', kernelVersion: 'Darwin Kernel Version 24.0.0'},
  '18.3':   {buildVersion: '22D63',   kernelVersion: 'Darwin Kernel Version 24.3.0'},
};

// 表单响应式数据
const spoofForm = ref({
  filename: '',
  cloneNumber: '1',
  selectedDevice: 'iPhone9,1',
  selectedCountry: 'JP',
  selectedSystemVersion: '15.8.6',
  deviceName: 'iPhone',
  enableNetworkInterception: true,
  disableQUIC: true,
});

// 根据国家预设派生语言参数
const derivedLangParams = computed(() => {
  const c = countryPresets[spoofForm.value.selectedCountry];
  if (!c) return {languageCode: 'en', preferredLanguage: 'en', localeIdentifier: 'en_US', systemLanguage: 'en', btdCurrentLanguage: 'en'};
  const fullLang = c.language;
  const parts = fullLang.split('-');
  let pureCode: string;
  if (parts.length >= 2 && parts[1]!.length === 4 && parts[1]![0] === parts[1]![0]!.toUpperCase()) {
    pureCode = parts[0] + '-' + parts[1]; // zh-Hans, zh-Hant
  } else {
    pureCode = parts[0]!;
  }
  const cc = spoofForm.value.selectedCountry;
  const localeId = pureCode.includes('-') ? pureCode.replace('-', '_') + '_' + cc : pureCode + '_' + cc;
  return {
    languageCode: pureCode,
    preferredLanguage: fullLang,
    localeIdentifier: localeId,
    systemLanguage: pureCode,
    btdCurrentLanguage: fullLang,
  };
});

// 生成完整安装脚本并写入代码框
const generateSpoofCode = (cloneOnly = false) => {
  const f = spoofForm.value;
  const dev = devicePresets[f.selectedDevice];
  const ctry = countryPresets[f.selectedCountry];
  const sys = systemVersionPresets[f.selectedSystemVersion];
  const lang = derivedLangParams.value;
  if (!dev || !ctry || !sys) return;

  let code = "";
  if (cloneOnly) {
    code = `// 📦 仅克隆安装 (自动生成)
var result = wda.installIPA({
    filename: "${f.filename || 'TikTok'}",
    clone_number: "${f.cloneNumber}"
});
wda.log("安装结果: " + JSON.stringify(result));`;
  } else {
    code = `// 📦 自动化注入安装 (自动生成)
var result = wda.installIPA({
    filename: "${f.filename || 'TikTok'}",
    clone_number: "${f.cloneNumber}",
    spoof_config: {
        // 1. 设备伪装
        machineModel: "${f.selectedDevice}",
        deviceModel: "${dev.deviceModel}",
        deviceName: "${f.deviceName}",
        productName: "${f.selectedDevice}",
        screenWidth: "${dev.screenWidth}",
        screenHeight: "${dev.screenHeight}",
        screenScale: "${dev.screenScale}",
        nativeBounds: "${dev.nativeBounds}",
        maxFPS: "${dev.maxFPS}",
        // 2. 系统版本
        systemVersion: "${f.selectedSystemVersion}",
        systemBuildVersion: "${sys.buildVersion}",
        kernelVersion: "${sys.kernelVersion}",
        systemName: "iOS",
        // 3. 运营商
        carrierName: "${ctry.carrier}",
        mobileCountryCode: "${ctry.mcc}",
        mobileNetworkCode: "${ctry.mnc}",
        carrierCountry: "${f.selectedCountry}",
        // 4. 区域
        localeIdentifier: "${lang.localeIdentifier}",
        timezone: "${ctry.timezone}",
        currencyCode: "${ctry.currency}",
        storeRegion: "${f.selectedCountry}",
        priorityRegion: "${f.selectedCountry}",
        // 5. 语言
        languageCode: "${lang.languageCode}",
        preferredLanguage: "${lang.preferredLanguage}",
        systemLanguage: "${lang.systemLanguage}",
        btdCurrentLanguage: "${lang.btdCurrentLanguage}",
        // 6. 网络拦截
        enableNetworkInterception: ${f.enableNetworkInterception},
        disableQUIC: ${f.disableQUIC},
        networkType: "N/A"
    }
});
wda.log("安装结果: " + JSON.stringify(result));`;
  }

  generatedJs.value = code;
  activeRightTab.value = 'code'; // 切换到代码框查看
};
// ========== 伪装信息生成器 END ==========

const copyText = (text: string) => {
  if (navigator?.clipboard) navigator.clipboard.writeText(text);
};

const isColorPickerMode = ref(false);
const pickedColors = ref<{x: number, y: number, hex: string}[]>([]);
const multiColorJS = computed(() => {
  if (pickedColors.value.length === 0) return '';
  const base = pickedColors.value[0];
  let colorStr = `${base?.x},${base?.y},${base?.hex}`;
  let offsets = [];
  for (let i = 1; i < pickedColors.value.length; i++) {
     const pt = pickedColors.value[i];
     offsets.push(`${pt!.x - base!.x}|${pt!.y - base!.y}|${pt?.hex}`);
  }
  if (offsets.length > 0) {
     colorStr += ',' + offsets.join(',');
  }
  return `var pos = wda.findMultiColor("${colorStr}");\nif(pos && pos.found){\n   wda.tap(pos.x, pos.y);\n}`;
});
const pickedImages = ref<{b64: string, w: number, h: number}[]>([]);

// 扩展功能：文字截获与APP起搏器
const bundleIdInput = ref('com.apple.Preferences');
const ocrTextInput = ref('');
const ocrResult = ref<any>(null);
const isOcrRunning = ref(false);

// 扩展功能：Base64 助手
const base64Input = ref('');
const base64ImagePreview = ref('');

const encodeBase64 = () => {
    if (!base64Input.value) return;
    try {
        base64Input.value = btoa(unescape(encodeURIComponent(base64Input.value)));
    } catch (e) {
        alert("编码失败: " + (e as Error).message);
    }
};

const decodeBase64 = () => {
    if (!base64Input.value) return;
    try {
        base64Input.value = decodeURIComponent(escape(atob(base64Input.value)));
    } catch (e) {
        alert("解码失败，可能是非标准 Base64 或包含二进制数据。");
    }
};

const previewBase64 = () => {
    if (!base64Input.value) {
      base64ImagePreview.value = '';
      return;
    }
    
    // 自动补齐前缀
    let cleanB64 = base64Input.value.replace(/\s/g, '');
    if (!cleanB64.startsWith('data:image')) {
        cleanB64 = 'data:image/png;base64,' + cleanB64;
    }
    base64ImagePreview.value = cleanB64;
};

const copyBase64Result = async () => {
    if (!base64Input.value) return;
    try {
        await navigator.clipboard.writeText(base64Input.value);
        alert("内容已复制！");
    } catch (e) {}
};

const config = ref({
   swipeMin: 50, swipeMax: 200,
   longPressMin: 800, longPressMax: 1500,
   waitMin: 1, waitMax: 3,
   scale: 2.0
});

const sortKey = ref('device_no');
const sortOrder = ref(1);

// ===== 独立配置管理 (静态 IP / VPN) =====
const showConfigModal = ref(false);
const configEditingUdid = ref('');
const configEditingAdmin = ref('');
const configForm = ref({
   ip: '',
   subnet: '',
   gateway: '',
   dns: '',
   vpnJson: '', // 明文 JSON，保存时由内部编解码
   device_no: '',
   country: '',
   group_name: '',
   exec_time: '',
   apple_account: '',
   apple_password: '',
   tiktok_accounts: [] as {email: string, account: string, password: string}[],
   wifi_ssid: '',
   wifi_password: ''
});

const openConfigModal = async (dev: any) => {
    configEditingUdid.value = dev.udid;
    configEditingAdmin.value = dev.admin_username || '';
    configForm.value = { ip: '', subnet: '', gateway: '', dns: '', vpnJson: '', device_no: '', country: '', group_name: '', exec_time: '', apple_account: '', apple_password: '', tiktok_accounts: [], wifi_ssid: '', wifi_password: '' };
    showConfigModal.value = true;
    try {
        const res = await authFetch(`${apiBase}/devices/${dev.udid}/config`);
        const data = await res.json();
        if (data && data.config) {
            if (data.config.config_ip) {
                try {
                    const ipConf = JSON.parse(data.config.config_ip);
                    configForm.value.ip = ipConf.ip || '';
                    configForm.value.subnet = ipConf.subnet || '';
                    configForm.value.gateway = ipConf.gateway || '';
                    configForm.value.dns = ipConf.dns || '';
                } catch(e) {}
            }
            if (data.config.config_vpn && data.config.config_vpn.startsWith('ecnode://')) {
                try {
                    const b64 = data.config.config_vpn.replace('ecnode://', '');
                    configForm.value.vpnJson = decodeURIComponent(escape(atob(b64)));
                } catch(e) {
                    configForm.value.vpnJson = "/* 解码失败，可能含有非标字符 */";
                }
            }
            configForm.value.device_no = data.config.device_no || '';
            configForm.value.country = data.config.country || '';
            configForm.value.group_name = data.config.group_name || '';
            configForm.value.exec_time = data.config.exec_time || '';
            configForm.value.apple_account = data.config.apple_account || '';
            configForm.value.apple_password = data.config.apple_password || '';
            try {
                const tkArr = JSON.parse(data.config.tiktok_accounts || '[]');
                configForm.value.tiktok_accounts = Array.isArray(tkArr) ? tkArr : [];
            } catch(e) {
                configForm.value.tiktok_accounts = [];
            }
            configForm.value.wifi_ssid = data.config.wifi_ssid || '';
            configForm.value.wifi_password = data.config.wifi_password || '';
        }
    } catch (e) {
        console.error("加载配置失败", e);
    }
};

const saveConfig = async () => {
    let finalIpConf = '';
    if (configForm.value.ip || configForm.value.subnet || configForm.value.gateway || configForm.value.dns) {
        finalIpConf = JSON.stringify({
            ip: configForm.value.ip,
            subnet: configForm.value.subnet,
            gateway: configForm.value.gateway,
            dns: configForm.value.dns
        });
    }
    
    let finalVpnConf = '';
    if (configForm.value.vpnJson.trim()) {
        try {
            // 简单校验 JSON 格式
            JSON.parse(configForm.value.vpnJson);
            const b64 = btoa(unescape(encodeURIComponent(configForm.value.vpnJson)));
            finalVpnConf = `ecnode://${b64}`;
        } catch (e) {
            alert("VPN 配置 JSON 格式不合法！请检查：" + (e as Error).message);
            return;
        }
    }
    
    try {
        const res = await authFetch(`${apiBase}/devices/${configEditingUdid.value}/config`, {
            method: 'POST',
            body: JSON.stringify({
                config_ip: finalIpConf,
                config_vpn: finalVpnConf,
                device_no: configForm.value.device_no,
                country: configForm.value.country,
                group_name: configForm.value.group_name,
                exec_time: configForm.value.exec_time,
                apple_account: configForm.value.apple_account,
                apple_password: configForm.value.apple_password,
                tiktok_accounts: JSON.stringify(configForm.value.tiktok_accounts),
                wifi_ssid: configForm.value.wifi_ssid,
                wifi_password: configForm.value.wifi_password
            })
        });
        const ret = await res.json();
        if (ret.status === 'ok') {
            alert("配置已成功存盘入库！设备下次心跳时将自动拉取部署。");
            showConfigModal.value = false;
        } else {
            alert("保存失败: " + ret.detail);
        }
    } catch(e) {
         alert("保存时发生网络异常：" + (e as Error).message);
    }
};

const filterParams = ref({
  device_no: '',
  ip: '',
  country: '',
  group: '',
  exec_time: '',
  status: '',
  admin: ''  // 管理员筛选（仅超级管理员可见）
});

// ===== 批量操作状态与逻辑 =====
const selectedDevices = ref<string[]>([]);
const isAllSelected = computed({
  get: () => {
    return sortedDevices.value.length > 0 && selectedDevices.value.length === sortedDevices.value.length;
  },
  set: (val) => {
    if (val) {
      selectedDevices.value = sortedDevices.value.map(d => d.udid);
    } else {
      selectedDevices.value = [];
    }
  }
});



const showBatchConfigModal = ref(false);
const batchConfigForm = ref({ country: '', group_name: '', exec_time: '', vpnJson: '', wifi_ssid: '', wifi_password: '', enableWifi: false });

const openBatchConfigModal = () => {
  batchConfigForm.value = { country: '', group_name: '', exec_time: '', vpnJson: '', wifi_ssid: '', wifi_password: '', enableWifi: false };
  showBatchConfigModal.value = true;
};

const saveBatchConfig = async () => {
  if (selectedDevices.value.length === 0) return;
  try {
    const payload: any = { udids: selectedDevices.value };
    // 哨兵值 __CLEAR__ 代表「清空该字段」，映射为空字符串发送给后端
    const resolve = (v: string) => v === '__CLEAR__' ? '' : v;
    if (batchConfigForm.value.country.trim() !== '') payload.country = resolve(batchConfigForm.value.country);
    if (batchConfigForm.value.group_name.trim() !== '') payload.group_name = resolve(batchConfigForm.value.group_name);
    if (batchConfigForm.value.exec_time.trim() !== '') payload.exec_time = resolve(batchConfigForm.value.exec_time);
    
    if (batchConfigForm.value.enableWifi && batchConfigForm.value.wifi_ssid.trim() !== '') {
        payload.wifi_ssid = batchConfigForm.value.wifi_ssid.trim();
        payload.wifi_password = batchConfigForm.value.wifi_password || '';
    }
    
    if (batchConfigForm.value.vpnJson.trim() !== '') {
        try {
            JSON.parse(batchConfigForm.value.vpnJson);
            const b64 = btoa(unescape(encodeURIComponent(batchConfigForm.value.vpnJson)));
            payload.config_vpn = `ecnode://${b64}`;
        } catch (e) {
            alert("VPN 配置 JSON 格式不合法！请检查：" + (e as Error).message);
            return;
        }
    }
    
    // 如果全部都没填，则无需保存
    if (Object.keys(payload).length === 1) {
      alert("请至少填写一项需要修改的属性");
      return;
    }
    
    const res = await authFetch(`${apiBase}/devices/batch_update`, {
      method: 'POST',
      body: JSON.stringify(payload)
    });
    const d = await res.json();
    if (d.status === 'ok') {
      alert(d.message);
      showBatchConfigModal.value = false;
      selectedDevices.value = []; // 清空选择
      fetchDevices(); // 重新拉取列表
    } else {
      alert(d.detail || '批量修改失败');
    }
  } catch (err) {
    alert("网络异常");
  }
};

// ================= 一次性任务 =================
const showOneshotModal = ref(false);
const oneshotForm = ref({ name: '', code: '' });
const oneshotTasks = ref<any[]>([]);

const openOneshotModal = () => {
  if (selectedDevices.value.length === 0) {
    alert('请先勾选要执行一次性任务的设备');
    return;
  }
  oneshotForm.value = { name: '', code: '' };
  showOneshotModal.value = true;
};

const submitOneshotTask = async () => {
  if (!oneshotForm.value.name.trim()) {
    alert('请输入任务名称');
    return;
  }
  if (!oneshotForm.value.code.trim()) {
    alert('请输入脚本代码');
    return;
  }
  try {
    const res = await authFetch(`${apiBase}/oneshot_tasks`, {
      method: 'POST',
      body: JSON.stringify({
        udids: selectedDevices.value,
        name: oneshotForm.value.name,
        code: oneshotForm.value.code
      })
    });
    const d = await res.json();
    if (d.status === 'ok') {
      alert(d.message);
      showOneshotModal.value = false;
      selectedDevices.value = [];
      fetchOneshotTasks();
    } else {
      alert(d.detail || '下发失败');
    }
  } catch (err) {
    alert('网络异常');
  }
};

const fetchOneshotTasks = async () => {
  try {
    const res = await authFetch(`${apiBase}/oneshot_tasks`);
    const d = await res.json();
    if (d.status === 'ok') oneshotTasks.value = d.data || [];
  } catch (e) {}
};

const deleteOneshotTask = async (id: number) => {
  try {
    const res = await authFetch(`${apiBase}/oneshot_tasks/${id}`, { method: 'DELETE' });
    const d = await res.json();
    if (d.status === 'ok') fetchOneshotTasks();
  } catch (e) {}
};

const deleteBatchDevices = async () => {
  if (selectedDevices.value.length === 0) return;
  if (!confirm(`正在执行危险操作：彻底删除 ${selectedDevices.value.length} 台设备。删除后设备必须重新刷入重启才能连接控制台。是否真的继续？`)) return;
  
  try {
    const res = await authFetch(`${apiBase}/devices/batch_delete`, {
      method: 'DELETE',
      body: JSON.stringify({ udids: selectedDevices.value })
    });
    const d = await res.json();
    if (d.status === 'ok') {
      selectedDevices.value = [];
      fetchDevices();
    } else {
      alert(d.detail || '批量删除失败');
    }
  } catch (err) {
    alert("网络异常");
  }
};

const sortedDevices = computed(() => {
   let arr = devices.value.filter(d => {
       if (filterParams.value.device_no && !(d.device_no||d.udid).toLowerCase().includes(filterParams.value.device_no.toLowerCase())) return false;
       if (filterParams.value.ip && !(d.ip||d.local_ip||'').toLowerCase().includes(filterParams.value.ip.toLowerCase())) return false;
       if (filterParams.value.country && (d.country||'') !== filterParams.value.country) return false;
       if (filterParams.value.group && (d.group_name||'') !== filterParams.value.group) return false;
       if (filterParams.value.status && (d.status||'') !== filterParams.value.status) return false;
       if (filterParams.value.exec_time && (d.exec_time||'') !== filterParams.value.exec_time) return false;
       if (filterParams.value.admin && (d.admin_username||'').toLowerCase().indexOf(filterParams.value.admin.toLowerCase()) === -1) return false;
       return true;
   });
   // 进行排序
   arr.sort((a,b) => {
      let valA = a[sortKey.value];
      let valB = b[sortKey.value];
      
      if (valA === undefined || valA === null) valA = '';
      if (valB === undefined || valB === null) valB = '';

      if (valA === valB) return 0;
      if (typeof valA === 'string' && typeof valB === 'string') {
         // 使用 numeric 选项进行自然排序，使 '10' 会排在 '2' 后面
         return valA.localeCompare(valB, undefined, { numeric: true }) * sortOrder.value;
      }
      return (valA > valB ? 1 : -1) * sortOrder.value;
   });
   return arr;
});

const sortBy = (key: string) => {
   if (sortKey.value === key) {
      sortOrder.value *= -1;
   } else {
      sortKey.value = key;
      sortOrder.value = -1; // 点击新列时默认采用降序
   }
};

const log = (msg: string) => {
  logs.value.push(`[${new Date().toLocaleTimeString()}] ${msg}`);
  if (logs.value.length > 100) logs.value.shift();
};

const fetchDevices = async () => {
  if (isDevicesLoading.value) return;
  isDevicesLoading.value = true;
  try {
    const res = await authFetch(`${apiBase}/cloud/devices`);
    if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
    }
    const data = await res.json();
    devices.value = data.devices || [];
  } catch (e: any) {
    const errMsg = (e as Error).message;
    if(logs.value.length < 50) log(`获取外置设备失败: ${errMsg}`);
    alert(`刷新矩阵失败: ${errMsg}\n请检查网络连接或尝试重新登录。`);
  } finally {
    isDevicesLoading.value = false;
  }
};

// 日志轮询机制已被同步单程透传机制取代，彻底删除 startLogPolling

const transformCoords = (data: any, scale: number): any => {
    if (typeof data !== 'object' || data === null) return data;
    if (Array.isArray(data)) return data.map(item => transformCoords(item, scale));
    const result: any = {};
    for (const key in data) {
        if (['x', 'y', 'width', 'height', 'centerX', 'centerY', 'x1', 'y1', 'x2', 'y2', 'left', 'top', 'right', 'bottom'].includes(key) && typeof data[key] === 'number') {
            result[key] = parseFloat((data[key] / scale).toFixed(1));
        } else if (typeof data[key] === 'object') {
            result[key] = transformCoords(data[key], scale);
        } else {
            result[key] = data[key];
        }
    }
    return result;
};

const runFindText = async () => {
    if (!selectedDevice.value) return log('❌ 缺失靶标: 未接驳物理外设');
    if (!ocrTextInput.value) {
        log('⚠️ 雷达失效: 请优先在右侧指挥侧面录入需要找寻的锚点文字！');
        return;
    }
    isOcrRunning.value = true;
    ocrResult.value = null;
    log(`🔍 开始全屏搜寻文字: [${ocrTextInput.value}]，底层算绘巨大请死守阵地...`);
    try {
        const res = await authFetch(`${apiBase}/action_proxy`, {
            method: 'POST',
            body: JSON.stringify({
                udid: selectedDevice.value,
                ecmain_url: ecmainUrl.value,
                action_type: 'findText',
                text: ocrTextInput.value,
                connection_mode: connectionMode.value
            })
        });
        const rawText = await res.text();
        let data;
        try {
            data = JSON.parse(rawText);
        } catch (je) {
            throw new Error(`HTTP状态码: ${res.status}, 回执非JSON, 裸流段包: [${rawText.substring(0,80)}]`);
        }
        ocrResult.value = transformCoords(data.detail, config.value.scale);
        if (data.status === 'ok') log(`✅ 扫描回传完毕，矩阵已依 [${config.value.scale}x] 级折损转换成可点射逻辑坐标！`);
        else log(`❌ 动作折返: ${data.msg}`);
    } catch (e: any) {
        log(`❌ 捕雷报错: ${(e as Error).message}`);
    } finally {
        isOcrRunning.value = false;
    }
};

const manageApp = async (actionType: 'launch' | 'terminate') => {
    if (!bundleIdInput.value) {
        log('⚠️ 拦截: 您试图调用的应用身份码 (Bundle ID) 为真空，予以驳回！');
        return;
    }
    log(`🚀 准备向底核投递应用指令: [${bundleIdInput.value}]...`);
    try {
        const res = await authFetch(`${apiBase}/action_proxy`, {
            method: 'POST',
            body: JSON.stringify({
                udid: selectedDevice.value,
                ecmain_url: ecmainUrl.value,
                action_type: actionType,
                text: bundleIdInput.value,
                connection_mode: connectionMode.value
            })
        });
        const data = await res.json();
        if (data.status === 'ok') log(`✅ 轰炸奏效: ${JSON.stringify(data.detail).substring(0, 100)}`);
        else log(`❌ 动作折返: ${data.msg}`);
    } catch (e: any) {
         log(`❌ App 兵工厂通讯雪崩: ${(e as Error).message}`);
    }
};

const connectSmart = async () => {
  // 保存当前用户选中的设备 ID，防止 fetchDevices 刷新后被冲掉
  const lockedUdid = selectedDevice.value;
  const lockedMode = connectionMode.value;
  
  await fetchDevices();
  
  // 恢复用户锁定的设备选择（防止列表刷新导致设备变化）
  if (lockedUdid) {
    selectedDevice.value = lockedUdid;
  }
  
  const dev = devices.value.find(d => d.udid === selectedDevice.value);
  if (!dev) {
     log('✗ 路由终止：未能锁定物理或网络目标');
     return;
  }
  
  // 智能路径选择：
  // 保护机制：如果用户已手动选定了任何模式（USB/LAN/WS），保持不变
  // 只有在首次连接（默认值）时才自动推断最优路径
  if (!lockedMode) {
      // 仅当模式未被外部（如 selectDeviceAndConnect）预设时，才进行自动推断
      if (dev.can_usb || dev.wda_ready) {
          connectionMode.value = 'usb';
          log('✓ 检测到 USB 专线就绪，使用高速通路');
      } else if (dev.status === 'online' || dev.status === 'busy') {
          connectionMode.value = 'ws';
          log('✓ 云控设备，使用 WebSocket 中继通信');
      } else if (dev.ip || dev.local_ip) {
          connectionMode.value = 'lan';
          log('✓ 尝试内网直连通路');
      }
  } else {
      log(`✓ 保持预设的 [${connectionMode.value.toUpperCase()}] 链路，防串台机制生效。`);
  }

  // [v1672.18] 优先级重构：必须先拿回逻辑分辨率，再渲染推流画面，确保坐标系从第一帧起就是对齐的
  if (selectedDevice.value) {
      log('📡 正在同步物理比例尺...');
      await sendDeviceAction('probe_size').catch(() => {});
  }

  // [v1742.7] 连接群控扩展：同步唤醒所有从机矩阵
  if (isGroupControl.value) {
      log('🔗 [群控模式] 正在同步激活从属矩阵画面...');
      batchConnectAll();
  }

  updateStreamUrl();
};

const enterBatchControl = () => {
    if (selectedDevices.value.length === 0) return;
    
    // 如果当前没选主控，或者主控不在已选列表里，自动选第一个作为主控
    if (!selectedDevice.value || !selectedDevices.value.includes(selectedDevice.value)) {
        const firstUdid = selectedDevices.value[0];
        const dev = devices.value.find(d => d.udid === firstUdid);
        if (dev) {
            selectDeviceAndConnect(dev);
        }
    } else {
        activeTab.value = '⚡️ 控制台';
    }
};

const selectDeviceAndConnect = (dev: any, resetPool = false) => {
    selectedDevice.value = dev.udid;
    
    // [v1742] 优化的交互逻辑：保持选中状态的连续性
    // 1. 如果明确要求重置 (resetPool)，则清空池并仅保留当前设备
    // 2. 如果当前点击控制的设备不在已选池中，则清空池并切换到该设备
    // 3. 如果设备已在池中（无论池中有几台），保留当前多选状态，以支持群控/批量执行
    if (resetPool || !selectedDevices.value.includes(dev.udid)) {
        selectedDevices.value = [dev.udid];
    }

    activeTab.value = '⚡️ 控制台';
    
    // 根据设备属性预判连接模式，在 connectSmart 之前就锁定
    if (dev.can_usb || dev.wda_ready) {
        connectionMode.value = 'usb';
        log(`✓ 设备 [${dev.device_no || dev.udid.substring(0,8)}] 检测到 USB 连接，自动切换高速通路`);
    }
    
    connectSmart();
};

const handleMasterChange = () => {
    const dev = devices.value.find(d => d.udid === selectedDevice.value);
    if (dev) {
        selectDeviceAndConnect(dev);
    }
};

const deleteDevice = async (dev: any) => {
    if (!confirm(`确定要彻底删除设备 [${dev.device_no || dev.udid}] 吗？\n操作后该设备将从数据库清理，直到其再次主动上报心跳。`)) return;
    try {
        const res = await authFetch(`${apiBase}/devices/${dev.udid}`, { method: 'DELETE' });
        const data = await res.json();
        if (data.status === 'ok') {
            log(`已彻底删除离线设备: ${dev.device_no || dev.udid}`);
            fetchDevices();
        }
    } catch (err: any) {
        log(`删除设备失败: ${err.message}`);
        alert(`删除失败: ${err.message}`);
    }
};

// [v1720] 自动资源回收：监听选择列表，当设备取消选中时关闭其长连接流
watch(selectedDevices, (newVal) => {
    Object.keys(batchSockets.value).forEach(udid => {
        if (!newVal.includes(udid)) {
            const ws = batchSockets.value[udid];
            if (ws) {
                try { ws.close(); } catch(e) {}
            }
            delete batchSockets.value[udid];
            delete batchImageData.value[udid];
        }
    });
}, { deep: true });

const batchConnect = (dev: any) => {
  const udid = dev.udid;
  
  // 如果已存在连接，先关闭
  if (batchSockets.value[udid]) {
    try { batchSockets.value[udid].close(); } catch(e) {}
  }

  // [v1720.1] 修正：从 apiBase 推导 WS 地址，确保端口跟随后端（8088）而非前端（5173）
  const wsBase = apiBase.replace(/^http/, 'ws');
  const wsUrl = `${wsBase}/ws_stream/${udid}?slave=1&quality=${slaveQuality.value}&token=${authToken.value}`;
  
  const socket = new WebSocket(wsUrl);
  socket.onmessage = (event) => {
    // 收到后端推送的纯 base64 字符串，存入内存
    batchImageData.value[udid] = event.data;
  };
  
  socket.onclose = () => {
    // 自动重连逻辑可以后续加，这里简单置空
    delete batchSockets.value[udid];
  };
  
  socket.onerror = (err) => {
    console.error(`[WS Stream] 连接异常 (${udid}):`, err);
  };

  batchSockets.value[udid] = socket;
  log(`📡 已建立从机 WebSocket 监控链路: ${dev.device_no || udid}`);
};

// 恢复被误杀的批量群控核心队列与连接动作
const batchConnectAll = () => {
    // [v1672.9] 优化：只要是在已选中列表中的设备，均允许尝试唤醒串流，不再被死板的 online 状态位阻塞
    sortedDevices.value.filter(d => selectedDevices.value.includes(d.udid)).forEach(d => {
        batchConnect(d);
    });
};

const batchDisconnectAll = () => {
    Object.values(batchSockets.value).forEach(ws => {
      try { ws.close(); } catch(e) {}
    });
    batchSockets.value = {};
    batchImageData.value = {};
    batchStreams.value = {};
    // [v1740] 响应用户需求：断流后自动切换至日志模式，隐藏空镜像，显示执行详情
    isLogsOnlyMode.value = true;
};

// [v1743] 清晰度切换：断开旧流后自动以新 quality 参数重连，避免画面闪烁或丢失
const onSlaveQualityChange = () => {
    // 先断开所有现有连接（使用旧 quality 的流）
    Object.values(batchSockets.value).forEach(ws => {
      try { ws.close(); } catch(e) {}
    });
    batchSockets.value = {};
    batchImageData.value = {};
    batchStreams.value = {};
    // 短暂延迟后以新 quality 重新连接所有从机
    setTimeout(() => {
        batchConnectAll();
        isLogsOnlyMode.value = false;
        log(`📺 从机画质已切换为 [${slaveQuality.value}]，正在重建视频链路...`);
    }, 300);
};

// [v1743] 清空日志：同时清除主控终端日志和所有从机的 batchLogs
const clearAllLogs = () => {
    logs.value = [];
    batchLogs.value = {};
    log('🗑️ 主控及所有受控机日志已全部清空。');
};

const batchDevices = computed(() => {
    return sortedDevices.value.filter(d => selectedDevices.value.includes(d.udid));
});

const updateStreamUrl = () => {
  if (selectedDevice.value) { // deviceIp.value is no longer directly used for stream URL construction, it's derived from selectedDevice
    const udid = selectedDevice.value;
    const dev = devices.value.find(d => d.udid === udid);
    const ip = dev?.ip || dev?.local_ip || ''; // Get IP from the selected device
    // 将现有的 usb=true/false 扩展为 mode 参数供后续演进，同时保持原有 usb bool 兼容
    const isUsb = connectionMode.value === 'usb';
    // 关键：<img src> 无法附带 Authorization 头，必须通过 query 参数传递 token
    streamUrl.value = `${apiBase}/screen/${udid}?t=${Date.now()}&ip=${ip}&usb=${isUsb}&mode=${connectionMode.value}&token=${authToken.value}`;
    
    // [v1682.1] 极速校准：选择设备后立即尝试并异步获取逻辑分辨率
    const probe = async (retryCount = 0) => {
        if (!selectedDevice.value) return;
        const currentUdid = selectedDevice.value;
        const currentIp = devices.value.find(d => d.udid === currentUdid)?.local_ip || '';
        try {
            const res = await authFetch(`${apiBase}/action_proxy`, {
                method: 'POST',
                body: JSON.stringify({
                    udid: currentUdid,
                    ecmain_url: currentIp ? `http://${currentIp}:8089` : '',
                    action_type: 'WDA_WINDOW_SIZE',
                    connection_mode: connectionMode.value
                })
            });
            const data = await res.json();
            if (data.window_size && data.window_size.width > 0) {
                deviceSizeMap.value[currentUdid] = data.window_size;
                log(`✅ [${currentUdid}] 逻辑分辨率同步成功: ${data.window_size.width}x${data.window_size.height}`);
            } else if (retryCount < 3) {
                setTimeout(() => probe(retryCount + 1), 2000);
            }
        } catch (e) {
            if (retryCount < 3) setTimeout(() => probe(retryCount + 1), 2000);
        }
    };
    setTimeout(() => probe(0), 200);
  } else {
    streamUrl.value = '';
  }
};

const isPickMode = ref(false);
const isFreeDrawMode = ref(false);
const isLassoMode = ref(false);
const isMagicWandMode = ref(false);
const magicWandTolerance = ref(45); // 魔术棒容差阈值 (0-255，曼哈顿距离*3比较)
// 魔术棒累积掩膜：支持多次点击扩展选区
const magicWandMask = ref<Uint8Array | null>(null);
const magicWandMaskSize = ref<{w: number, h: number}>({w: 0, h: 0});
const lassoPoints = ref<{x: number, y: number}[]>([]);
const currentMousePos = ref<{x: number, y: number} | null>(null);

const freeDrawPoints = ref<{x: number, y: number}[]>([]);
const pendingCrop = ref<{b64: string, w: number, h: number} | null>(null);

// ==================== 橡皮擦功能状态 ====================
const isEraserMode = ref(false);
const eraserBrushSize = ref(12); // 橡皮擦默认粗细
const isErasing = ref(false);
const eraserCanvasRef = ref<HTMLCanvasElement | null>(null);

// ==================== 橡皮擦撤销历史与光标 ====================
const eraserHistory = ref<ImageData[]>([]);
const maxHistory = 15;

const saveEraserState = () => {
    if (!eraserCanvasRef.value) return;
    const ctx = eraserCanvasRef.value.getContext('2d');
    if (!ctx) return;
    const imgData = ctx.getImageData(0, 0, eraserCanvasRef.value.width, eraserCanvasRef.value.height);
    eraserHistory.value.push(imgData);
    if (eraserHistory.value.length > maxHistory) {
         eraserHistory.value.shift();
    }
};

const undoEraser = () => {
    if (eraserHistory.value.length === 0 || !eraserCanvasRef.value) return;
    const ctx = eraserCanvasRef.value.getContext('2d');
    if (!ctx) return;
    
    // 弹出上一个状态覆盖
    const lastState = eraserHistory.value.pop();
    if (lastState) {
         ctx.clearRect(0, 0, eraserCanvasRef.value.width, eraserCanvasRef.value.height);
         ctx.putImageData(lastState, 0, 0);
         // 同步回 pendingCrop.b64
         const b64 = eraserCanvasRef.value.toDataURL('image/png').split(',')[1] || '';
         if (pendingCrop.value) pendingCrop.value.b64 = b64;
    }
};

const eraserCursor = computed(() => {
    const size = eraserBrushSize.value;
    const r = size / 2;
    // 渲染圆形 SVG 光标
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}"><circle cx="${r}" cy="${r}" r="${r - 1}" stroke="#818cf8" stroke-width="1.5" fill="none"/></svg>`;
    const encoded = encodeURIComponent(svg);
    return `url("data:image/svg+xml;utf8,${encoded}") ${r} ${r}, crosshair`;
});

const startErase = (e: MouseEvent) => {
    saveEraserState(); // 启动前保存状态
    isErasing.value = true;
    handleErase(e);
};

const handleErase = (e: MouseEvent) => {
    if (!isErasing.value || !eraserCanvasRef.value) return;
    const ctx = eraserCanvasRef.value.getContext('2d');
    if (!ctx) return;

    const rect = eraserCanvasRef.value.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    ctx.save();
    ctx.globalCompositeOperation = 'destination-out';
    ctx.beginPath();
    ctx.arc(x, y, eraserBrushSize.value / 2, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
};

const endErase = () => {
    if (!isErasing.value || !eraserCanvasRef.value || !pendingCrop.value) return;
    isErasing.value = false;

    // 同步回 pendingCrop.value.b64
    const b64 = eraserCanvasRef.value.toDataURL('image/png').split(',')[1] || '';
    pendingCrop.value.b64 = b64;
};

const initEraserCanvas = () => {
    if (!eraserCanvasRef.value || !pendingCrop.value) return;
    const ctx = eraserCanvasRef.value.getContext('2d');
    if (!ctx) return;

    const img = new Image();
    img.onload = () => {
        if (eraserCanvasRef.value && pendingCrop.value) {
            eraserCanvasRef.value.width = pendingCrop.value.w;
            eraserCanvasRef.value.height = pendingCrop.value.h;
            ctx.clearRect(0, 0, eraserCanvasRef.value.width, eraserCanvasRef.value.height);
            ctx.drawImage(img, 0, 0);
        }
    };
    img.src = 'data:image/png;base64,' + pendingCrop.value.b64;
};

watch(isEraserMode, (newVal) => {
    if (newVal) {
        nextTick(() => {
            initEraserCanvas();
        });
    }
});

const confirmCrop = () => {
   if (pendingCrop.value) {
       pickedImages.value.push(pendingCrop.value);
       pendingCrop.value = null;
       isEraserMode.value = false; 
       eraserHistory.value = []; // 清空历史
       magicWandMask.value = null; // 清空累积掩膜
       log('✅ 裁切已成功载入收纳仓');
   }
};

const cancelCrop = () => {
   pendingCrop.value = null;
   isEraserMode.value = false;
   eraserHistory.value = []; // 清空历史
   magicWandMask.value = null; // 清空累积掩膜
   lassoPoints.value = [];
   currentMousePos.value = null;
   log('❌ 裁切已被抹除');
   redrawCanvasForLasso();
};

const toggleDrawMode = (mode: 'rect' | 'free' | 'lasso' | 'magic') => {
  // 检测是否点击了当前已激活的模式 → 退出
  const isCurrentlyActive =
    (mode === 'rect' && isPickMode.value && !isFreeDrawMode.value && !isLassoMode.value && !isMagicWandMode.value) ||
    (mode === 'free' && isFreeDrawMode.value) ||
    (mode === 'lasso' && isLassoMode.value) ||
    (mode === 'magic' && isMagicWandMode.value);

  cancelCrop();
  isPickMode.value = false;
  isFreeDrawMode.value = false;
  isLassoMode.value = false;
  isMagicWandMode.value = false;

  // 如果之前已激活，就不再重新打开（实现退出）
  if (!isCurrentlyActive) {
    if (mode === 'rect') {
      isPickMode.value = true;
    } else if (mode === 'free') {
      isFreeDrawMode.value = true;
      isPickMode.value = true;
    } else if (mode === 'lasso') {
      isLassoMode.value = true;
      isPickMode.value = true;
    } else if (mode === 'magic') {
      isMagicWandMode.value = true;
      isPickMode.value = true;
    }
  }
  
  freeDrawPoints.value = [];
  lassoPoints.value = [];
  currentMousePos.value = null;
  const ctx = canvasRef.value?.getContext('2d');
  if(ctx && canvasRef.value) ctx.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height);
};

const performMagicWand = (startX: number, startY: number) => {
    if (!imageRef.value || !canvasRef.value) return;

    const nw = imageRef.value.naturalWidth;
    const nh = imageRef.value.naturalHeight;
    if (!nw || !nh) return;

    const tempCanvas = document.createElement('canvas');
    tempCanvas.width = nw;
    tempCanvas.height = nh;
    const tCtx = tempCanvas.getContext('2d', { willReadFrequently: true });
    if (!tCtx) return;

    tCtx.drawImage(imageRef.value, 0, 0, nw, nh);
    const imgData = tCtx.getImageData(0, 0, nw, nh);
    const pixels = imgData.data;

    // 初始化或复用累积掩膜
    if (!magicWandMask.value || magicWandMaskSize.value.w !== nw || magicWandMaskSize.value.h !== nh) {
        magicWandMask.value = new Uint8Array(nw * nh);
        magicWandMaskSize.value = { w: nw, h: nh };
    }
    const mask = magicWandMask.value;

    // 如果该像素已经在累积掩膜中，跳过（不重复 flood fill）
    if (mask[startY * nw + startX]) {
        log('⚠️ 该区域已在选区中，请点击其它位置');
        return;
    }

    const targetColor = {
        r: pixels[(startY * nw + startX) * 4],
        g: pixels[(startY * nw + startX) * 4 + 1],
        b: pixels[(startY * nw + startX) * 4 + 2]
    };

    // 本次新增的像素数
    let newCount = 0;
    const visited = new Uint8Array(nw * nh);
    // 已在掩膜中的点也算已访问
    for (let i = 0; i < nw * nh; i++) { if (mask[i]) visited[i] = 1; }

    const queue: number[] = [startX, startY]; // 扁平队列加速

    const colorDistance = (r1: number, g1: number, b1: number, r2: number, g2: number, b2: number) => {
        return Math.abs(r1 - r2) + Math.abs(g1 - g2) + Math.abs(b1 - b2);
    };

    while (queue.length > 0) {
        const qy = queue.pop()!;
        const qx = queue.pop()!;
        const idx = qy * nw + qx;

        if (qx < 0 || qx >= nw || qy < 0 || qy >= nh || visited[idx]) continue;

        const r = pixels[idx * 4] as number;
        const g = pixels[idx * 4 + 1] as number;
        const b = pixels[idx * 4 + 2] as number;

        if (colorDistance(r, g, b, targetColor?.r || 0, targetColor?.g || 0, targetColor?.b || 0) <= magicWandTolerance.value * 3) {
            visited[idx] = 1;
            mask[idx] = 1; // 合并到累积掩膜
            newCount++;

            queue.push(qx + 1, qy);
            queue.push(qx - 1, qy);
            queue.push(qx, qy + 1);
            queue.push(qx, qy - 1);
        }
    }

    if (newCount === 0) {
        log('⚠️ 本次点击未扩展新区域');
        return;
    }

    // 从累积掩膜重新生成合并后的预览图
    const ctx = canvasRef.value.getContext('2d');
    if (!ctx) return;
    ctx.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height);

    const rect = canvasRef.value.getBoundingClientRect();
    const cw = rect.width;
    const ch = rect.height;
    const imageAspect = nw / nh;
    const containerAspect = cw / ch;
    let renderW: number, renderH: number;
    if (imageAspect > containerAspect) {
        renderW = cw;
        renderH = cw / imageAspect;
    } else {
        renderH = ch;
        renderW = ch * imageAspect;
    }
    const realScale = renderW / nw;
    const offsetX = (cw - renderW) / 2;
    const offsetY = (ch - renderH) / 2;

    ctx.fillStyle = 'rgba(0, 255, 255, 0.4)';

    let minX = nw, maxX = 0, minY = nh, maxY = 0;
    let totalSelected = 0;
    for (let y = 0; y < nh; y++) {
        for (let x = 0; x < nw; x++) {
            if (mask[y * nw + x]) {
                ctx.fillRect(x * realScale + offsetX, y * realScale + offsetY, realScale, realScale);
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
                totalSelected++;
            }
        }
    }

    const bw = maxX - minX + 1;
    const bh = maxY - minY + 1;

    if (bw > 0 && bh > 0) {
        const offCanvas = document.createElement('canvas');
        offCanvas.width = bw;
        offCanvas.height = bh;
        const offCtx = offCanvas.getContext('2d');
        if (offCtx) {
            const imgDataTemp = offCtx.createImageData(bw, bh);
            for (let y = minY; y <= maxY; y++) {
                for (let x = minX; x <= maxX; x++) {
                    if (mask[y * nw + x]) {
                        const srcIdx = (y * nw + x) * 4;
                        const destIdx = ((y - minY) * bw + (x - minX)) * 4;
                        imgDataTemp.data[destIdx] = pixels[srcIdx] as number;
                        imgDataTemp.data[destIdx+1] = pixels[srcIdx+1] as number;
                        imgDataTemp.data[destIdx+2] = pixels[srcIdx+2] as number;
                        imgDataTemp.data[destIdx+3] = 255;
                    }
                }
            }
            offCtx.putImageData(imgDataTemp, 0, 0);
            const b64 = offCanvas.toDataURL('image/png').split(',')[1] || '';
            pendingCrop.value = { b64, w: bw, h: bh };
            log(`✨ 魔棒累积选区 (新增${newCount}px, 总计${totalSelected}px, 框${bw}x${bh})，可继续点击或[完成]入库 ⏳`);
        }
    }
};

const isGroupControl = ref(false);

// [v1742.10] 群控状态监听器：开启瞬间自动同步唤醒所有从属矩阵，解决“从机黑屏”痛点
watch(isGroupControl, (newVal) => {
    if (newVal) {
        log('🟢 群控引擎已启动，正在唤醒从属矩阵视频流...');
        batchConnectAll();
    } else {
        log('⚪️ 群控引擎已静默，维持现有监控链路。');
    }
});
const isLogsOnlyMode = ref(false);

// [v1743] 日志模式流量优化：切到日志模式时断开从机视频流，恢复时自动重连
watch(isLogsOnlyMode, (logsOnly) => {
    if (logsOnly) {
        // 断开所有从机视频 WebSocket，节约带宽
        Object.values(batchSockets.value).forEach(ws => {
            try { ws.close(); } catch(e) {}
        });
        batchSockets.value = {};
        batchImageData.value = {};
    } else {
        // 退出日志模式，自动重连从机画面
        batchConnectAll();
    }
});
const batchLogs = ref<Record<string, string[]>>({});

const sendDeviceAction = async (type: string, payload: any = {}) => {
  const _t0 = performance.now();

  // [v1760] 坐标已由前端直接换算为 iOS 逻辑 Points，无需归一化中间层
  if (type === 'click') log(`📡 下发单击: (${payload.x ?? '--'}, ${payload.y ?? '--'})`);
  if (type === 'longPress') log(`⏳ 下发长按: (${payload.x ?? '--'}, ${payload.y ?? '--'})`);
  if (type === 'swipe') log(`📡 下发滑动: (${payload.x1 ?? '--'}, ${payload.y1 ?? '--'}) → (${payload.x2 ?? '--'}, ${payload.y2 ?? '--'})`);

  // [v1760] payload 中的坐标已经是 WDA 可直接消费的逻辑 Points，直接透传
  const normPayload = {
    ...payload
  };

  // [v1672] 矩阵群控：如果开启了群控引擎，即刻无阻塞镜像动作到所有被选从属设备
  if (isGroupControl.value) {
     const slaves = batchDevices.value.filter(d => d.udid !== selectedDevice.value);
     slaves.forEach(dev => {
         // [v1672.10] 救火：如果该设备是本地串联的物理机，严禁将其动作流导向不一定可用的 WS 隧道
         // 恢复原始策略，有 USB 必定走 USB 寻址 WDA Port
         const mode = batchConnectionModes.value[dev.udid] || (dev.can_usb || dev.wda_ready ? 'usb' : 'ws');
         const ip = dev.ip || dev.local_ip || '';
         const ecUrl = ip ? `http://${ip}:8089` : '';
         authFetch(`${apiBase}/action_proxy`, {
            method: 'POST',
            body: JSON.stringify({
               udid: dev.udid,
               ecmain_url: ecUrl,
               action_type: type,
               connection_mode: mode,
               ...normPayload // 使用归一化后的数据
            })
         }).then(res => res.json()).then(data => {
             if (data.logs && Array.isArray(data.logs)) {
                 if(!batchLogs.value[dev.udid]) batchLogs.value[dev.udid] = [];
                 data.logs.forEach((logItem: any) => {
                     batchLogs.value[dev.udid]?.push(`🤖 [同步] ${logItem.log || logItem.message || logItem}`);
                 });
             }
         }).catch(e => console.error(`从机动作异常 (${dev.udid}):`, e));
     });
  }

  try {
    const res = await authFetch(`${apiBase}/action_proxy`, {
      method: 'POST',
      body: JSON.stringify({
        udid: selectedDevice.value,
        ecmain_url: ecmainUrl.value,
        action_type: type,
        connection_mode: connectionMode.value,
        ...normPayload // 使用归一化后的数据
      })
    });
    

    const rawResponse = await res.text();
    let data: any;
    try {
        data = JSON.parse(rawResponse);
    } catch(e) {
        log(`✗ [DEBUG] 原始回执非法 (非JSON): ${rawResponse.substring(0, 100)}`);
        return false;
    }

    // 成功下发动作后，顺便更新当前设备的逻辑分辨率缓存
    if (data.window_size && data.window_size.width > 0) {
        deviceSizeMap.value[selectedDevice.value] = data.window_size;
    }
    
    // 透传日志流
    if (data.logs && Array.isArray(data.logs)) {
      data.logs.forEach((logItem: any) => {
        log(`📱 ${logItem.log || logItem.message || logItem}`);
      });
    }

    if(data.status !== 'ok') {
       log(`✗ 指令下发失败: ${data.detail || data.msg}`);
       return false;
    }
    // [v1668.27] 延迟静默更新到底栏指示器，不再重复打日志
    const _latency = Math.round(performance.now() - _t0);
    wsLatency.value = `${_latency}ms`;
    return true;
  } catch (e: any) {
    log(`✗ 通信异常: ${(e as Error).message}`);
    return false;
  }
};

const testEcmain = async () => {
  log(`📡 全频段探活雷达启动：目标 ${ecmainUrl.value}`);
  
  // [v1742.3] 探测群控扩展：同步探测所有从机
  if (isGroupControl.value) {
      const slaves = batchDevices.value.filter(d => d.udid !== selectedDevice.value);
      slaves.forEach(dev => {
          const ip = dev.ip || dev.local_ip || '';
          if (ip) {
              fetch(`${apiBase}/probe?ip=${encodeURIComponent(`http://${ip}:8089`)}`)
                  .then(res => res.json())
                  .then(data => {
                      if (data.status === 'ok') {
                          log(`[探测报告-Slave] [${dev.device_no || dev.udid.substring(0,8)}] ${data.detail}`);
                      }
                  }).catch(() => {});
          }
      });
  }

  try {
    const res = await fetch(`${apiBase}/probe?ip=${encodeURIComponent(ecmainUrl.value)}`);
    const data = await res.json();
    
    if (data.status === 'ok') {
      log(`[探测报告] ${data.detail}`);
      if (data.port_8089 && data.port_10088) {
        log('✓ 双活链路已全面贯通！');
      } else {
        log('⚠️ 目标锚点存在部分离线阻断，请检查网络或重新【启动EC】。');
      }
    } else {
      log(`✗ 探测后端组件故障: ${data.detail}`);
    }
  } catch (err: any) {
    log(`✗ 探活雷达失联: ${err.message}`);
  }
};

const launchEcwda = async () => {
  if (!selectedDevice.value) {
    log('✗ 未识别到设备游标，请先完成探测接驳。');
    return;
  }
  
  // [v1742.5] 启动EC群控扩展：同步启动所有从机
  if (isGroupControl.value) {
      const slaves = batchDevices.value.filter(d => d.udid !== selectedDevice.value);
      slaves.forEach(dev => {
          if (dev.can_usb) {
              authFetch(`${apiBase}/launch_ecwda`, {
                  method: 'POST',
                  body: JSON.stringify({ udid: dev.udid })
              }).then(res => res.json()).then(data => {
                  if (data.status === 'ok') log(`[从机启动] [${dev.device_no || dev.udid.substring(0,8)}] 启动指令已送达。`);
              }).catch(() => {});
          }
      });
  }

  log(`🚀 正在通过 USB 向主要设备发送启动指令... (目标: ${selectedDevice.value.substring(0,8)})`);
  
  // USB 设备自动切换到 USB 模式
  connectionMode.value = 'usb';
  
  try {
    const res = await authFetch(`${apiBase}/launch_ecwda`, {
      method: 'POST',
      body: JSON.stringify({ udid: selectedDevice.value })
    });
    const result = await res.json();
    if(result.status === 'ok') {
      log('✓ EC 底核引擎已通过 USB 启动，进入挂载倒计时...');
      
      let countdown = 8;
      const timer = setInterval(() => {
        countdown--;
        if (countdown > 0) {
          log(`⏳ 等待 WDA 底层容器初始化... 剩余 ${countdown} 秒`);
        } else {
          clearInterval(timer);
          log('✅ 容器准备就绪！正尝试自动捕获媒体串流...');
          if (!streamUrl.value) {
            connectSmart();
          }
        }
      }, 1000);

    } else {
      log('✗ EC 启动受挫: ' + result.detail);
    }
  } catch (err: any) {
    log('✗ 路由无法通向 EC启动组件：' + err.message);
  }
};

const runActions = async () => {
  log('▶ 下发脚本执行序列到中央并发调度池...');
  try {
    let js_code = '';
    if (actionQueue.value && actionQueue.value.length > 0) {
       js_code += '// ' + JSON.stringify(actionQueue.value) + '\n';
    }
    js_code += generatedJs.value;

    // [v1672] 矩阵群控脚本广播引擎：剥离主控逻辑，并发投递
    if (isGroupControl.value) {
       const slaves = batchDevices.value.filter(d => d.udid !== selectedDevice.value);
       slaves.forEach(dev => {
           if(!batchLogs.value[dev.udid]) batchLogs.value[dev.udid] = [];
           batchLogs.value[dev.udid]?.push('----------------------------------------');
           batchLogs.value[dev.udid]?.push('⚡️ 接收并开始执行主控广播分发的同步群控脚本...');
           
           const mode = batchConnectionModes.value[dev.udid] || (dev.can_usb || dev.wda_ready ? 'usb' : 'ws');
           const ip = dev.ip || dev.local_ip || '';
           const ecUrl = ip ? `http://${ip}:8089` : '';

           authFetch(`${apiBase}/action_proxy`, {
               method: 'POST',
               body: JSON.stringify({
                   udid: dev.udid,
                   ecmain_url: ecUrl,
                   action_type: 'SCRIPT',
                   connection_mode: mode,
                   script_code: js_code
               }),
           }).then(res => res.json()).then(data => {
               if (data.status === 'success' || data.status === 'ok') {
                   batchLogs.value[dev.udid]?.push('✅ 脚本镜像同步成功。');
               } else {
                   batchLogs.value[dev.udid]?.push(`❌ 分发失败: ${data.detail || data.msg}`);
               }
           }).catch(e => {
               batchLogs.value[dev.udid]?.push(`💥 强行中断或网络溶断: ${(e as Error).message}`);
           });
       });
    }

    const res = await authFetch(`${apiBase}/action_proxy`, {
      method: 'POST',
      body: JSON.stringify({
        udid: selectedDevice.value,
        ecmain_url: ecmainUrl.value,
        action_type: 'SCRIPT',
        connection_mode: connectionMode.value,
        script_code: js_code
      }),
    });
    const data = await res.json();
    
    // 透传出日志
    if (data.logs && Array.isArray(data.logs)) {
        data.logs.forEach((logItem: any) => {
            log(`📱 ${logItem.log || logItem.message || logItem}`);
        });
    }

    if (data.status === 'success' || data.status === 'ok' || data.status === 'accepted') {
      log(`✅ 编队战列执行落幕！`);
      if (data.return_value !== undefined && data.return_value !== null) {
         log(`🎁 👉 最终反馈结果 (Return Value): ${JSON.stringify(data.return_value)}`);
      }
    } else {
      log(`❌ 战术指令执行坠毁: ${data.detail || data.message || data.msg || JSON.stringify(data)}`);
    }
  } catch (e: any) {
    log(`❌ 战列连接被后台强行中断超时熔断: ${(e as Error).message} (请检查 iOS 存活或是否陷入 While死循环)`);
  }
};

// ==================== 悬浮窗控制系统 ====================
const deviceWin = ref({
  x: 16,
  y: 16,
  w: 420,
  h: window.innerHeight - 171,
  isDragging: false,
  dragStartX: 0,
  dragStartY: 0,
  initialX: 0,
  initialY: 0,
  isResizing: false,
  initialW: 0,
  initialH: 0
});

const startWinDrag = (e: MouseEvent) => {
  if (e.target && (e.target as HTMLElement).tagName.toLowerCase() === 'input') return;
  deviceWin.value.isDragging = true;
  deviceWin.value.dragStartX = e.clientX;
  deviceWin.value.dragStartY = e.clientY;
  deviceWin.value.initialX = deviceWin.value.x;
  deviceWin.value.initialY = deviceWin.value.y;
  document.addEventListener('mousemove', onWinDrag);
  document.addEventListener('mouseup', endWinDrag);
};

const onWinDrag = (e: MouseEvent) => {
  if (!deviceWin.value.isDragging) return;
  const dx = e.clientX - deviceWin.value.dragStartX;
  const dy = e.clientY - deviceWin.value.dragStartY;
  deviceWin.value.x = deviceWin.value.initialX + dx;
  deviceWin.value.y = deviceWin.value.initialY + dy;
};

const endWinDrag = () => {
  deviceWin.value.isDragging = false;
  document.removeEventListener('mousemove', onWinDrag);
  document.removeEventListener('mouseup', endWinDrag);
};

const startWinResize = (e: MouseEvent) => {
  e.preventDefault();
  e.stopPropagation();
  deviceWin.value.isResizing = true;
  deviceWin.value.dragStartX = e.clientX;
  deviceWin.value.dragStartY = e.clientY;
  deviceWin.value.initialW = deviceWin.value.w;
  deviceWin.value.initialH = deviceWin.value.h;
  document.addEventListener('mousemove', onWinResize);
  document.addEventListener('mouseup', endWinResize);
};

const onWinResize = (e: MouseEvent) => {
  if (!deviceWin.value.isResizing) return;
  const dx = e.clientX - deviceWin.value.dragStartX;
  const dy = e.clientY - deviceWin.value.dragStartY;
  deviceWin.value.w = Math.max(300, deviceWin.value.initialW + dx);
  deviceWin.value.h = Math.max(400, deviceWin.value.initialH + dy);
};

const endWinResize = () => {
  deviceWin.value.isResizing = false;
  document.removeEventListener('mousemove', onWinResize);
  document.removeEventListener('mouseup', endWinResize);
  // syncCanvasSize(); // Assuming this function exists elsewhere and needs to be called
};

const selectedActionDoc = ref<any>(null);

const vpnInputText = ref('');
const parsedVpnNodes = ref<any[]>([]);
const isVpnParsing = ref(false);

const parseVpnInput = async () => {
   if (!vpnInputText.value.trim()) {
       log('⚠️ 请先输入代理节点链接或订阅地址');
       return;
   }
   isVpnParsing.value = true;
   log('📡 请求后端云枢纽解析订阅链...');
   try {
       const res = await fetch(`${apiBase}/parse_proxy`, {
           method: 'POST',
           headers: { 'Content-Type': 'application/json' },
           body: JSON.stringify({ content: vpnInputText.value })
       });
       const data = await res.json();
       if (data.status === 'ok') {
           if (data.nodes && data.nodes.length > 0) {
               parsedVpnNodes.value = data.nodes;
               log(`✅ 智能解析合规完成，共熔断提纯出 ${data.nodes.length} 个节点实体`);
           } else {
               log(`⚠️ 未能在输入碎片中匹配到有效且可组构的节点协议特征`);
           }
       } else {
           log(`❌ 节点集群映射失败: ${data.msg}`);
       }
   } catch (e: any) {
       log(`❌ 无法联通解析矩阵: ${(e as Error).message}`);
   } finally {
       isVpnParsing.value = false;
   }
};

const addVpnNodeToScript = (node: any) => {
   const jsonStr = JSON.stringify(node, null, 4);
   const snippet = `// [载入 VPN 实体]: ${node.name || node.server}\n` +
                   `console.log("Pushing VPN Configuration to ECMAIN...");\n` +
                   `if (typeof wda.connectVPN === 'function') {\n` +
                   `    wda.connectVPN(${jsonStr});\n` +
                   `} else {\n` +
                   `    console.log("Error: wda.connectVPN not found in JSBridge.");\n` +
                   `}`;
                   
   if (generatedJs.value && generatedJs.value.trim() !== '') {
     generatedJs.value += '\n\n' + snippet;
   } else {
     generatedJs.value = snippet;
   }
   
   log(`📦 已将节点 [${node.name || node.server}] 的执行代码写入右侧编辑器。`);
   activeRightTab.value = 'code';
};

/*
const copyVpnNode = (node: any) => {
   if (node.raw_uri) {
       navigator.clipboard.writeText(node.raw_uri).then(() => {
           log(`📋 独立节点 [${node.name || node.server}] 的配置分享链接 (URI) 已复制到剪贴板！`);
       }).catch(err => {
           log(`❌ 剪贴板调用失败: ${err}`);
       });
   } else {
       log(`⚠️ 此节点尚未生成原始溯源 URL，无法导出脱壳独立分享。`);
   }
};
*/

const addAllVpnNodesToScript = () => {
    if (parsedVpnNodes.value.length === 0) return;
    parsedVpnNodes.value.forEach(node => {
        addVpnNodeToScript(node);
    });
    log(`🚀 批处理完毕，${parsedVpnNodes.value.length} 个节点现已全部生成代码推入右框！`);
};

const actionLibrary = [
  { label: '[点击] Tap', type: 'TAP', desc: '模拟触碰屏幕指定的绝对物理坐标点', usage: '点按普通按钮、图标或链接', params: 'x: 决定落点的横向绝对坐标\ny: 纵向绝对坐标', example: 'var r = wda.tap(100, 200);\nif(r) wda.log("点击成功");' },
  { label: '[双击] Double Tap', type: 'DOUBLE_TAP', desc: '在指定点进行极速两次连续点击', usage: '点赞、缩放地图', params: 'x: 横向绝对坐标\ny: 纵向绝对坐标', example: 'wda.doubleTap(100, 200);' },
  { label: '[长按] Long Press', type: 'LONG_PRESS', desc: '在目标坐标持续按下一定时间', usage: '唤出长按菜单、拖拽准备', params: 'x, y: 落点的绝对坐标\nduration: 按压维持时长(毫秒, 推荐1000+)', example: 'wda.longPress(100, 200, 1000);' },
  { label: '[滑动] Swipe', type: 'SWIPE', desc: '模拟手指从起点拖拉摩擦至终点', usage: '翻阅商品、滑动屏幕、拖动滑块', params: 'fromX, fromY: 拖拽起始点坐标\ntoX, toY: 拖拽终点坐标\nduration: 滑动所耗时间(毫秒, 决定滑速)', example: 'wda.swipe(200, 800, 200, 200, 500);' },
  { label: '[随机点击] Random Tap', type: 'RANDOM_TAP', desc: '在一个矩阵框选域内进行带抖动的仿生概率点击', usage: '防风控检测、随机点防检测', params: 'x1, x2: 横向随机落点允许的区间(极小值与极大值)\ny1, y2: 纵向落点允许的区间', example: 'wda.tap(wda.randomInt(10, 50), wda.randomInt(20, 60));' },
  { label: '[随机双击] Random DTap', type: 'RANDOM_DTAP', desc: '在设定限制宽幅内打出的偏移双击', usage: '随机化双击点赞以躲避机器学习检查', params: 'x1, x2: 横区间的下限与上限\ny1, y2: 纵区间的下限与上限', example: 'wda.doubleTap(wda.randomInt(10, 50), wda.randomInt(20, 60));' },
  { label: '[随机长按] Random LPress', type: 'RANDOM_LPRESS', desc: '不但坐标随机且按压时长也在两个极大跨度区间跳跃', usage: '消除高频重复作业的机器化体征', params: 'x1, x2: 横向坐标界限\ny1, y2: 纵向坐标界限\ndMin, dMax: 手指滞留屏幕时间的上下限(毫秒)', example: 'wda.longPress(wda.randomInt(10, 50), wda.randomInt(20, 60), wda.randomInt(1000, 1500));' },
  { label: '[随机滑动] Random Swipe', type: 'RANDOM_SWIPE', desc: '起点终点以及滑动耗时(全5维参量)全维度离散随机化', usage: '极高安全防御级别的核心看播刷视频动作', params: 'fromX1~fromX2: 起点横向区间的起始与结束位\nfromY1~fromY2: 起点纵向界限\ntoX1~toX2: 终点横向随机偏移区\ntoY1~toY2: 终点纵向漂移区\ndurationMin~durationMax: 滑动划过屏幕的随机耗时区间(毫秒)', example: 'wda.swipe(wda.randomInt(150, 160), wda.randomInt(400, 500),\n  wda.randomInt(150, 180), wda.randomInt(250, 300),\n  wda.randomInt(130, 350));' },
  { label: '[等待] Sleep', type: 'SLEEP', desc: '阻塞当前宏脚本与线程上下文的运行时钟', usage: '等待复杂动画加载或网络长请求完毕', params: 'seconds: 静态线程阻塞等待的时间(严格为秒制，支持小数)', example: 'wda.sleep(1.5);' },
  { label: '[随机等待] Random Wait', type: 'RANDOM_WAIT', desc: '调用底层全局时距的防风控动态睡眠', usage: '使批量任务在宏观时间跨度上产生天然分歧散度', params: 'tMin, tMax: 挂起随机范围(秒)', example: 'wda.sleep(wda.random(2.0, 5.0));' },
  { label: '[主屏幕] Home', type: 'HOME', desc: '按压设备底层系统级 Home 锁键', usage: '强行退出当前前台程序退回桌面主屏幕', params: '无传参需求', example: 'var ok = wda.home();\nwda.log("回到桌面: " + ok);' },
  { label: '[启动APP] Launch', type: 'LAUNCH', desc: '透过底层 Springboard 唤死级激活并置顶 APP', usage: '直接靠底参启动目标分析软件，非表面物理点击', params: 'bundleId: 苹果内部识别身份包名(如 com.apple.Preferences)', example: 'var success = wda.launch("com.zhiliaoapp.musically");\nif(!success) wda.log("启动失败");' },
  { label: '[输入文本] Input', type: 'INPUT', desc: '强制为屏幕当前具有焦点(Focus)的元素填充串流', usage: '自动打字、高频灌水回复', params: 'text: 欲键入的字符信息组', example: 'wda.input("Hello Automation");' },
  { label: '[日志] Log', type: 'LOG', desc: '由主控台在后台截取并记录您的探针信号', usage: '用于排查排版复杂多线程宏到底走到了哪一步', params: 'message: 需要暴露并打印的字符/变量', example: 'wda.log("checkpoint checked");' },
  { label: '[OCR点击] OCR Tap', type: 'OCR_TAP', desc: '驱动视觉识别引擎捕获字符串的实际物理映射并实施点击', usage: '攻克找不到绝对坐标的随机出现动态弹窗按钮', params: 'text: 确切期望匹配锁定的锚文本片段', example: 'wda.tapText("同意并继续");' },
  { label: '[找图] Find Image', type: 'FIND_IMAGE', desc: '向终端传递原色块矩阵进行比对识别计算中心坐标', usage: '精确锚点物料匹配、特征全屏扫描', params: 'template: 图片切割切片Base64流\nthreshold: 置信度容限率(浮点0~1, 默认0.8推荐)', example: 'var result = wda.findImage("BASE...64", 0.8);\nif(result && result.value && result.value.found) wda.log("找到位点");' },
  { label: '[找图点击] Find+Tap', type: 'FIND_IMAGE_TAP', desc: '集成了先搜图后抽取结果集中幅位移然后单击的高集宏', usage: '全自动无脑图像化按钮点击全链组件', params: 'template: 图像Base64\nthreshold: 匹配容限比(不填写默认0.8)', example: 'var res = wda.findImage("...", 0.8);\nif(res && res.value && res.value.found){\n   wda.tap(res.value.x + wda.randomInt(0, res.value.width || 0), res.value.y + wda.randomInt(0, res.value.height || 0));\n}' },
  { label: '[取色] Get Color', type: 'GET_COLOR', desc: '提取屏幕指定单像素针尖所在位置的原生特征色(Hex型)', usage: '探知并判断特定UI组件是否正处于高亮选中态', params: 'x, y: 所求像素的绝对位置投射', example: 'var res = wda.getColorAt(100, 200);\nif(res && res.value === "#FF0000") wda.log("红包来了");' },
  { label: '[多点找色点击] MultiColor', type: 'MULTICOLOR', desc: '通过投下网阵式的色彩匹配规避图像特征点反抄袭抓取', usage: '反击针对单点机器取色进行故意污染的极端反爬环境', params: 'colors: 数组形态构建的多维探查阵列矩阵', example: 'var pos = wda.findMultiColor("...");\nif(pos && pos.value && pos.value.found){ wda.tap(pos.value.x, pos.value.y); }' },
  { label: '[截图] Screenshot', type: 'SCREENSHOT', desc: '截捕无损画幅通过中控底基站反向走私推回主控界面', usage: '验证长效宏脚本最终到达状态与存档封存', params: '无', example: 'wda.screenshot();' },
  { label: '[VPN] 全套网关协议', type: 'VPN_HYSTERIA', desc: '包含 Socks5/SS/V2/Hys 等底层路由截断接驳方法簇', usage: '海外宽带质量差补偿、反侦察分化子网调度', params: 'config: 具体协议特征所需口令/混淆参对象', example: '// Configured for Protocol...' },
  { label: '[关闭APP] Terminate', type: 'TERMINATE', desc: '通过私有API直接终止指定应用进程', usage: '关闭目标APP以释放资源或重新初始化', params: 'bundleId: 目标应用的包名标识', example: 'wda.terminate("com.zhiliaoapp.musically");' },
  { label: '[关闭所有应用] Kill All', type: 'TERMINATE_ALL', desc: '清理所有后台运行的应用进程', usage: '批量释放内存、清理后台防止状态残留', params: '无', example: 'wda.terminateAll();' },
  { label: '[抹除APP数据] Wipe Data', type: 'WIPE_APP', desc: '包含清除核心沙盒和底层钥匙串Keychain数据', usage: '解决重装后仍然能被认出旧账号特征的问题', params: 'bundleId: 目标应用的包名', example: 'wda.wipeApp("com.zhiliaoapp.musically");' },
  { label: '[飞行模式开] AirplaneON', type: 'AIRPLANE_ON', desc: '通过SpringBoardServices私有API开启飞行模式', usage: '断网重置IP、切换网络环境', params: '无', example: 'wda.airplaneOn();' },
  { label: '[飞行模式关] AirplaneOFF', type: 'AIRPLANE_OFF', desc: '关闭飞行模式恢复网络连接', usage: '飞行模式重连后自动获取新IP', params: '无', example: 'wda.airplaneOff();' },
  { label: '[设置IP] Static IP', type: 'SET_IP', desc: '通过RootHelper直接修改系统WiFi配置文件设置静态IP', usage: '固定设备IP地址/子网/网关/DNS', params: 'ip: IP地址\nsubnet: 子网掩码\ngateway: 网关\ndns: DNS服务器(逗号分隔)', example: 'wda.setStaticIP("192.168.1.50", "255.255.255.0", "192.168.1.1", "8.8.8.8");\nwda.sleep(0.5);\nwda.airplaneOn();\nwda.sleep(2.0);\nwda.airplaneOff();\nwda.sleep(1.0);' },
  { label: '[设置WiFi] Connect WiFi', type: 'SET_WIFI', desc: '使用NEHotspotConfiguration系统API连接指定WiFi网络', usage: '远程切换设备连接的WiFi热点', params: 'ssid: WiFi名称\npassword: 密码(8位以上,留空表示开放网络)', example: 'wda.setWifi("MyWiFi", "12345678");' },
  { label: '[获取VPN状态] Get VPN Status', type: 'IS_VPN_CONNECTED', desc: '调用底层接口获取当前设备的VPN连接状态', usage: '根据当前网络状态决定下一步宏分支', params: '无', example: 'if(wda.isVPNConnected()) wda.log("OK");' },
  { label: '[弹窗手动交互] Alert Manual', type: 'ALERT_MANUAL', desc: '开放底层的原生 Alert 操作接口，供你自由读取弹窗并点击指定按钮', usage: '适合在明确知道即将出现什么特定弹窗（如某APP内的专属提示）的独立场景下使用', params: 'getAlertText(): 抓取文字\ngetAlertButtons(): 抓取按钮数组\nclickAlertButton(name): 按名字点击\nacceptAlert(): 点击确定/允许\ndismissAlert(): 点击取消/拒绝', example: '// ==========================================\n// 🚨 系统弹窗 (Alert) 手动控制核心 API\n// ==========================================\n\n// 1. 获取当前屏幕最顶层弹窗的【正文内容】\n// 返回值: 字符串(如果存在弹窗)，或 null/未定义(当前无弹窗)\nlet text = wda.getAlertText();\nif (!text) {\n    wda.log("没发现风吹草动，当前没有弹窗。");\n    return true; // 退出脚本或继续执行接下来的代码\n}\nwda.log("抓去了弹窗原文: " + text);\n\n// 2. 获取该弹窗底部的【所有按钮选项】\n// 返回值: 包含各按钮文字的数组，如 ["不允许", "好", "稍后"]\nlet btns = wda.getAlertButtons() || [];\nwda.log("该弹窗提供了这些选项: " + JSON.stringify(btns));\n\n// 3. 【推荐】按标签名精准狙击并点击某个按键（指哪打哪）\n// 参数: 目标按钮的特定文字（建议配合 includes 做个安全判断）\nif (btns.includes("允许完全访问")) {\n    wda.clickAlertButton("允许完全访问");\n    wda.log("已一击命中目标按钮: 允许完全访问");\n    return true;\n}\n\n// 4. 【系统兜底操作】（仅当上面的精准点击失效时才用）\n// wda.acceptAlert();  // ✅ 强制点击自带“肯定/接受/允许”属性的默认确认键\n// wda.dismissAlert(); // ❌ 强制点击自带“否定/拒绝/取消”属性的默认取消键\n\nwda.log("找不到我要的按键，闭着眼点【确认】算了！");\nwda.acceptAlert();\nreturn true;\n' },
  { label: '[系统弹窗自动扫雷] Auto Alert Handling', type: 'CHECK_ALERT', desc: '封装好的多语言系统弹窗自动放行函数（中/英/日/德/法/意/西/葡）', usage: '将其置于脚本顶端，遇到任何点击前调用 autoHandleAlert()', params: '无', example: 'function autoHandleAlert() {\n    let msg = wda.getAlertText();\n    if (!msg) return false;\n    let rawMsg = msg;\n    msg = msg.toLowerCase();\n    let btns = wda.getAlertButtons() || [];\n    wda.log("⚠️ 探测到系统提示: " + rawMsg + " | 按钮: " + JSON.stringify(btns));\n\n    // 全语言否定词集合（用于排除"不允许"类按钮）\n    var deny = ["不允许", "不", "don\\\'t", "nicht", "しない", "ne ", "non ", "no ", "não", "refuser"];\n\n    // 精准点击器（带排除词过滤）\n    function clickBtn(keywords, excludeWords) {\n        if (!excludeWords) excludeWords = [];\n        for (var i = 0; i < btns.length; i++) {\n            var b = btns[i].toLowerCase();\n            var skip = false;\n            for (var e = 0; e < excludeWords.length; e++) {\n                if (b.indexOf(excludeWords[e].toLowerCase()) >= 0) { skip = true; break; }\n            }\n            if (skip) continue;\n            for (var j = 0; j < keywords.length; j++) {\n                if (b.indexOf(keywords[j].toLowerCase()) >= 0) {\n                    wda.clickAlertButton(btns[i]);\n                    wda.log("🎯 已点击: [" + btns[i] + "]");\n                    return true;\n                }\n            }\n        }\n        return false;\n    }\n\n    function has(keywords) {\n        for (var i = 0; i < keywords.length; i++) {\n            if (msg.indexOf(keywords[i].toLowerCase()) >= 0) return true;\n        }\n        return false;\n    }\n\n    // ═══════════ 1. 照片/相册 → 允许完全访问 ═══════════\n    if (has(["photo","照片","相片","相册","写真","foto","フォト"])) {\n        if (clickBtn(["完全","所有","full","すべて","vollen zugriff","accès complet","accesso completo","acceso total","acesso a todas"])) return true;\n        if (clickBtn(["允许","allow","許可","erlauben","autoriser","consenti","permitir","zulassen"], deny)) return true;\n    }\n    // ═══════════ 2. 位置/定位 → 不允许 ═══════════\n    else if (has(["location","位置","定位","standort","localização","ubicación","posizione","position","位置情報"])) {\n        if (clickBtn(["不允许","don\\\'t allow","許可しない","nicht erlauben","nicht zulassen","ne pas autoriser","non consentire","no permitir","não permitir"])) return true;\n    }\n    // ═══════════ 3. 网络/蜂窝数据 → 蜂窝数据 ═══════════\n    else if (has(["wlan","cellular","wi-fi","network","网络","局域网","蜂窝","ネット","netzwerk","rede","red","rete","réseau","モバイルデータ"])) {\n        if (clickBtn(["蜂窝","cellular","モバイルデータ","wlan &","celular","cellulare","cellulaires","mobilfunk"])) return true;\n        if (clickBtn(["允许","allow","ok","好","許可","erlauben","autoriser","consenti","permitir","zulassen"], deny)) return true;\n    }\n    // ═══════════ 4. 日历/备忘录 → 允许完全访问 ═══════════\n    else if (has(["calendar","reminder","日历","备忘录","カレンダー","kalender","erinnerungen","calendário","calendario","promemoria","calendrier","リマインダー"])) {\n        if (clickBtn(["完全","full","フル","vollen","complet","completo","total"])) return true;\n        if (clickBtn(["允许","allow","ok","好","許可","erlauben","autoriser","consenti","permitir","zulassen"], deny)) return true;\n    }\n    // ═══════════ 5. 应用跟踪透明度 (ATT) → 不跟踪 ═══════════\n    else if (has(["track","跟踪","追踪","トラッキング","rastrear","rastreo","tracciamento","suivi","tracking"])) {\n        if (clickBtn(["不跟踪","not to track","トラッキングしないよう","ablehnen","ne pas suivre","non consentire","no permitir","não rastrear","nicht erlauben"])) return true;\n    }\n    // ═══════════ 6. 通讯录 → 不允许 ═══════════\n    else if (has(["contact","通讯录","联系人","連絡先","kontakte","contato","contacto","contatti","contacts"])) {\n        if (clickBtn(["不允许","don\\\'t allow","許可しない","nicht erlauben","nicht zulassen","ne pas autoriser","non consentire","no permitir","não permitir","refuser"])) return true;\n    }\n    // ═══════════ 7. 粘贴板/本地网络/蓝牙/相机/麦克风/通知/VPN → 允许 ═══════════\n    else if (has(["paste","粘贴","剪贴板","local network","本地","ローカル","bluetooth","camera","microphone","蓝牙","相机","摄像头","麦克风","マイク","カメラ","notification","通知","vpn","profile","描述文件","benachrichtigung","notifica"])) {\n        if (clickBtn(["允许","allow","許可","好","ok","erlauben","autoriser","consenti","permitir","zulassen","aceptar"], deny)) return true;\n    }\n\n    // ═══════════ 兜底命中 ═══════════\n    if (clickBtn(["好","ok","是","yes","はい","允许","allow","erlauben","autoriser","consenti","permitir","zulassen","accept","同意","aceptar","ja","sì","oui"], deny)) {\n        return true;\n    }\n\n    wda.acceptAlert();\n    wda.log("⚠️ 触发兜底的 acceptAlert() 点击");\n    return true;\n}\n\n// 在你需要判断的时候可以直接呼叫它\n// autoHandleAlert();' },
  { label: '[💬 抽取双擎评论]', type: 'RANDOM_COMMENT', desc: '首选机内高速抽取。如果本地无储备，将自动从云端（可通过共享配置设定 EC_CLOUD_SERVER_URL）拉取全量备库兜底。', usage: '弹幕或长文输入首选。', params: '★ 常用代号大全:\nes-MX (墨西哥) | pt-BR (巴西)\nde-DE (德国) | en-SG (新加坡)\nja-JP (日本) | en-US (美国)\nes-ES (西班牙) | en-GB (英国)\nfr-FR (法国) | zh-CN (中文)\n(如本地失联，将自动访问 http://web.ecmain.site:8088)', example: 'var cmt = wda.getRandomComment("en-US");\nwda.input(cmt);' },
  { label: '[TK主账号] 输入用户名', type: 'TK_MASTER_ACCOUNT', desc: '从设备配置中读取 TikTok 主账号用户名，自动写入剪切板并通过 WDA 输入到当前焦点文本框', usage: '登录 TikTok 时自动填充用户名', params: '无需手动传参（自动从配置中心已绑定的主账号读取）', example: 'var acc = wda.getMasterTkAccount();\nif(acc && acc.length > 0) {\n    wda.input(acc);\n    wda.log("已输入TK主账号: " + acc);\n} else {\n    wda.log("未找到主账号，请先在配置中心绑定");\n}' },
  { label: '[TK主账号] 输入密码', type: 'TK_MASTER_PASSWORD', desc: '从设备配置中读取 TikTok 主账号密码，自动写入剪切板并通过 WDA 输入到当前焦点文本框', usage: '登录 TikTok 时自动填充密码', params: '无需手动传参（自动从配置中心已绑定的主账号读取）', example: 'var pwd = wda.getMasterTkPassword();\nif(pwd && pwd.length > 0) {\n    wda.input(pwd);\n    wda.log("已输入TK主账号密码");\n} else {\n    wda.log("未找到主账号密码，请先在配置中心设置");\n}' },
  { label: '[TK主账号] 输入邮箱', type: 'TK_MASTER_EMAIL', desc: '从设备配置中读取 TikTok 主账号绑定邮箱，自动写入剪切板并通过 WDA 输入到当前焦点文本框', usage: '登录 TikTok 或验证邮箱时自动填充邮箱地址', params: '无需手动传参（自动从配置中心已绑定的主账号读取）', example: 'var email = wda.getMasterTkEmail();\nif(email && email.length > 0) {\n    wda.input(email);\n    wda.log("已输入TK主账号邮箱: " + email);\n} else {\n    wda.log("未找到主账号邮箱，请先在配置中心设置");\n}' },
  { label: '[🔄 立即更新配置] Sync Config', type: 'SYNC_CONFIG', desc: '立即触发心跳向服务器获取最新的设备配置（包括 TikTok 账号、国家、分组等），无需等待下一次心跳周期', usage: '在修改了配置中心的信息后，脚本中需要立即使用最新数据时调用', params: '无', example: 'wda.syncConfig();\nwda.log("配置已同步到最新");' },
  { label: '[📥 下载IPA文件] Download IPA', type: 'DOWNLOAD_IPA', desc: '通过远程 URL 下载 IPA 文件到 ECMAIN 应用管理的"已下载"目录（Documents/ImportedIPAs/）', usage: '远程部署应用时，先下载 IPA 到设备，再通过应用管理安装', params: 'url: IPA 文件的完整下载链接', example: 'var ok = wda.downloadIPA("https://example.com/app.ipa");\nif(ok) {\n    wda.log("IPA 下载成功，请在应用管理中安装");\n} else {\n    wda.log("IPA 下载失败");\n}' },
  { label: '[📦 注入安装] Inject Install', type: 'INSTALL_IPA', desc: '自动化执行：搜索 IPA → 解压注入 Dylib → 克隆分身 → 设备伪装 → 系统安装（逻辑与 ECMAIN UI 一致）', usage: '实现 IPA 的全自动静默克隆与伪装安装', params: 'filename: IPA文件名(支持模糊匹配)\\nclone_number: 分身编号(1/2/8等,0=原包)\\nspoof_config: 伪装字典(键值同ECDeviceInfoManager)', example: '// 📦 自动化注入安装示例\\nvar result = wda.installIPA({\\n    filename: \"TikTok\",         // IPA文件名\\n    clone_number: \"1\",          // 分身编号(自动处理隔离)\\n    spoof_config: {              // ★ 设备伪装参数\\n        // -- 设备信息 --\\n        machineModel: \"iPhone9,1\",\\n        deviceName: \"iPhone\",\\n        screenWidth: \"375\",\\n        screenHeight: \"667\",\\n        nativeBounds: \"750x1334\",\\n\\n        // -- 系统/区域 --\\n        systemVersion: \"15.8.6\",\\n        timezone: \"Asia/Tokyo\",\\n        localeIdentifier: \"en_JP\",\\n        languageCode: \"en\",\\n        currencyCode: \"JPY\",\\n\\n        // -- 运营商 --\\n        carrierCountry: \"JP\",\\n        mobileCountryCode: \"440\",\\n        mobileNetworkCode: \"10\"\\n    }\\n});\\nwda.log(\"安装结果: \" + JSON.stringify(result));' }
];

// [v1738] 追加动作：VPN 重连 + 全局弹窗
actionLibrary.push(
  { label: '[🔗 重连VPN] Reconnect Last VPN', type: 'RECONNECT_VPN', desc: '自动连接上次使用过的 VPN 节点。如果设备上没有上次的连接记录则返回 false，不做任何操作', usage: '脚本开始前自动恢复 VPN 网络环境，无需手动指定节点', params: '无需传参（自动读取上次连接记录）', example: '// 自动重连上次的 VPN 节点\nvar ok = wda.connectProxy(\"\");\nif(ok) {\n    wda.log(\"VPN 重连成功（已恢复上次节点）\");\n} else {\n    wda.log(\"没有上次VPN连接记录，跳过\");\n}\nwda.sleep(3); // 等待隧道建立' },
  { label: '[📢 全局弹窗] Show Alert', type: 'SHOW_ALERT', desc: '在 iOS 设备上弹出一个系统级 Alert 弹窗（标题 ECMAIN），包含自定义消息和一个 OK 按钮。脚本会暂停执行直到用户点击 OK（最长等待60秒后自动关闭）', usage: '脚本执行到关键节点时暂停提醒用户确认、调试时检查中间状态', params: 'message: 弹窗显示的消息文字', example: '// 在 iOS 设备上弹出提示\nwda.showAlert(\"脚本已执行完毕！请检查结果。\");\n\n// 也可以用于调试暂停\nwda.showAlert(\"即将开始下一轮操作，点击OK继续\");\nwda.log(\"用户已确认，继续执行...\");' }
);

const handleActionClick = (act: any) => {
  selectedActionDoc.value = act;
  const snippet = `// [样例参考]: ${act.label}\n${act.example || '// 当前参数暂无示例宏代码'}`;
  if (generatedJs.value && generatedJs.value.trim() !== '') {
    generatedJs.value += '\n\n' + snippet;
  } else {
    generatedJs.value = snippet;
  }
};

const addActionToQueue = async (act: any) => {
  const newAct = { ...act };
  if(act.type.includes('FIND_IMAGE')) {
     newAct.template = "base64_placeholder_please_crop";
     newAct.threshold = 0.8;
  }

  let snippet = '';
  
  if (act.type === 'RANDOM_COMMENT') {
      const lang = prompt("你要抽取哪个国家的评论？\n可选代号：\nes-MX(墨西哥) | pt-BR(巴西)\nde-DE(德国) | en-SG(新加坡)\nja-JP(日本) | en-US(美国)\nes-ES(西班牙) | en-GB(英国)\nfr-FR(法国) | zh-CN(中文)\n\n请直接输入国家代号(不区分大小写)：");
      if(!lang) return;
      snippet = `// [💬 抽取本地语料 - ${lang}]\nvar txt = wda.getRandomComment("${lang}");\nif(txt && txt.length > 0) {\n    wda.input(txt);\n} else {\n    wda.log("【发评警告】未抽到对应语种词条(已尝试实时同步但依然失败)，跳过打字！");\n}`;
  } else {
      snippet = `// [加入序列]: ${newAct.label}\n// 内部参数: ${JSON.stringify(newAct)}`;
  }

  actionQueue.value.push(newAct);
  
  if (generatedJs.value && generatedJs.value.trim() !== '') {
    generatedJs.value += '\n\n' + snippet;
  } else {
    generatedJs.value = snippet;
  }
}

const clearQueue = () => {
  actionQueue.value = [];
  generatedJs.value = ''; // 轨道清空时仍赋予全盘重置的能力
}

const disconnectDevice = () => {
  if (selectedDevice.value) {
    // 仅清空推流地址和日志流，但保留 selectedDevice 不变 (锁定当前手机)，防止 fetchDevices 轮询导致串台
    streamUrl.value = '';
    
    // [v1742.9] 断开群控扩展：同步释放所有从机流
    if (isGroupControl.value) {
        log('🛑 [群控模式] 正在同步释放从属矩阵资源...');
        batchDisconnectAll();
    }
    
    log('已断开与设备的 USB 同步流，设备锁定状态维持。');
  }
}

// ==================== Canvas & 坐标系统 ====================
const imageRef = ref<HTMLImageElement|null>(null);
const canvasRef = ref<HTMLCanvasElement|null>(null);
const isDrawing = ref(false);
const pressStartTime = ref(0);
const startX = ref(0);
const startY = ref(0);
const currX = ref(0);
const currY = ref(0);
const mouseX = ref('--');
const mouseY = ref('--');
const pntX = ref('--');
const pntY = ref('--');
const pntLabel = ref('(--, --)'); // [v1668.23] 坐标实时回显标签
const wsLatency = ref('--'); // [v1668.23] WS 指令延迟实测 (ms)
const deviceSizeMap = ref<Record<string, {width: number, height: number}>>({}); // [v1672.9] 按 UDID 记录的逻辑点分辨率 Map

const getRealMouseCoord = (e: MouseEvent) => {
  if (!canvasRef.value || !imageRef.value) return null;
  const rect = canvasRef.value.getBoundingClientRect();
  
  // 图像尺寸：优先 naturalWidth，兜底 clientWidth
  let nw = imageRef.value.naturalWidth;
  let nh = imageRef.value.naturalHeight;
  if (!nw || !nh) {
      nw = imageRef.value.clientWidth;
      nh = imageRef.value.clientHeight;
  }
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

  // 如果点在了四周黑边外，则出界
  if (x < 0 || x > renderW || y < 0 || y > renderH) {
    return null; 
  }

  // 返回图像像素坐标（与备份版一致）
  const realScale = nw / renderW;
  return {
    x: Math.floor(x * realScale),
    y: Math.floor(y * realScale),
    rectX: e.clientX - rect.left,
    rectY: e.clientY - rect.top,
  };
};

const redrawCanvasForLasso = () => {
  const ctx = canvasRef.value?.getContext('2d');
  if(!ctx || !canvasRef.value) return;
  ctx.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height);

  if (isLassoMode.value && lassoPoints.value.length > 0) {
    const lp = lassoPoints.value;
    ctx.beginPath();
    ctx.moveTo(lp[0]?.x!, lp[0]?.y!);
    for (let i = 1; i < lp.length; i++) {
       ctx.lineTo(lp[i]?.x!, lp[i]?.y!);
    }
    if (currentMousePos.value) {
       ctx.lineTo(currentMousePos.value.x, currentMousePos.value.y);
    }
    // 闭合吸附提示（靠近起点）
    if (lp.length >= 3 && currentMousePos.value) {
       const dist = Math.hypot(currentMousePos.value.x - lp[0]?.x!, currentMousePos.value.y - lp[0]?.y!);
       if(dist < 15) { ctx.lineTo(lp[0]?.x!, lp[0]?.y!); }
    }
    ctx.strokeStyle = '#a855f7';
    ctx.lineWidth = 1.5;
    ctx.stroke();
    
    // 描点
    for (let i = 0; i < lp.length; i++) {
        ctx.beginPath();
        ctx.arc(lp[i]?.x!, lp[i]?.y!, i===0 ? 4 : 2, 0, Math.PI * 2);
        ctx.fillStyle = i===0 ? '#ef4444' : '#a855f7';
        ctx.fill();
    }
  }
};


const startDraw = (e: MouseEvent) => {
  if (!canvasRef.value) return;
  const coord = getRealMouseCoord(e);
  if (isMagicWandMode.value && coord) {
     performMagicWand(Math.floor(coord.x), Math.floor(coord.y));
     return;
  }

  const rect = canvasRef.value.getBoundingClientRect();
  startX.value = e.clientX - rect.left;
  startY.value = e.clientY - rect.top;
  currX.value = startX.value;
  currY.value = startY.value;

  if (isLassoMode.value) {
     const pushX = startX.value;
     const pushY = startY.value;

     if (lassoPoints.value.length >= 3) {
        const firstPt = lassoPoints.value[0];
        const dist = Math.hypot(pushX - firstPt?.x!, pushY - firstPt?.y!);
        if (dist < 15) {
            completeLasso();
            return;
        }
     }
     
     lassoPoints.value.push({ x: pushX, y: pushY });
     redrawCanvasForLasso();
     return;
  }

  isDrawing.value = true;
  pressStartTime.value = Date.now();
  // 自由画笔模式：初始化路径点
  if (isFreeDrawMode.value) {
    freeDrawPoints.value = [{ x: startX.value, y: startY.value }];
  }
};

const handleMouseMove = (e: MouseEvent) => {
  if (!canvasRef.value) return;
  const rect = canvasRef.value.getBoundingClientRect();
  const mx = e.clientX - rect.left;
  const my = e.clientY - rect.top;

  const coord = getRealMouseCoord(e);
  if (coord) {
       mouseX.value = coord.x.toString();
       mouseY.value = coord.y.toString();
       // coord.x/y 现在是图像像素坐标，除以 scale 得到逻辑 Points
       const curSize = deviceSizeMap.value[selectedDevice.value];
       const nw_img = imageRef.value?.naturalWidth || imageRef.value?.clientWidth || 1;
       const scale = curSize ? (nw_img / curSize.width) : (config.value?.scale || 2);
       pntX.value = Math.floor(coord.x / scale).toString();
       pntY.value = Math.floor(coord.y / scale).toString();
       pntLabel.value = `(${pntX.value}, ${pntY.value})`;
  } else {
     mouseX.value = '--';
     mouseY.value = '--';
     pntX.value = '--';
     pntY.value = '--';
     pntLabel.value = '(--, --)';
  }

  if (isLassoMode.value) {
      currentMousePos.value = { x: mx, y: my };
      redrawCanvasForLasso();
      return;
  }

  if(!isDrawing.value) return;
  
  // 画框框使用相对框体的绝对坐标
  if (coord) {
      currX.value = coord.rectX;
      currY.value = coord.rectY;
  } else {
      currX.value = mx;
      currY.value = my;
  }
  
  const ctx = canvasRef.value.getContext('2d');
  if(!ctx) return;
  ctx.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height);
  
  const w = Math.abs(currX.value - startX.value);
  const h = Math.abs(currY.value - startY.value);
  
  if ((w > 10 || h > 10) && isPickMode.value && !isFreeDrawMode.value) {
      ctx.strokeStyle = '#00ff00';
      ctx.lineWidth = 1;
      ctx.strokeRect(startX.value, startY.value, currX.value - startX.value, currY.value - startY.value);
  }
  
  if (isFreeDrawMode.value && isPickMode.value) {
      freeDrawPoints.value.push({ x: currX.value, y: currY.value });
      ctx.beginPath();
      ctx.strokeStyle = '#00ff88';
      ctx.lineWidth = 2;
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      ctx.globalAlpha = 0.8;
      const pts = freeDrawPoints.value;
      if (pts.length > 0) {
          ctx.moveTo(pts[0]!.x, pts[0]!.y);
          for (let i = 1; i < pts.length; i++) {
              ctx.lineTo(pts[i]!.x, pts[i]!.y);
          }
      }
      ctx.stroke();
      if (pts.length > 2) {
          ctx.setLineDash([4, 4]);
          ctx.strokeStyle = '#00ff8866';
          ctx.beginPath();
          ctx.moveTo(pts[pts.length - 1]!.x, pts[pts.length - 1]!.y);
          ctx.lineTo(pts[0]!.x, pts[0]!.y);
          ctx.stroke();
          ctx.setLineDash([]);
      }
      ctx.globalAlpha = 1;
  }
};

const endDraw = async (e: MouseEvent) => {
  if (isLassoMode.value || isMagicWandMode.value) return;

  if (!isDrawing.value || !canvasRef.value || !imageRef.value) return;
  isDrawing.value = false;
  
  const ctx = canvasRef.value.getContext('2d');
  if(ctx) ctx.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height);

  const rect = canvasRef.value.getBoundingClientRect();
  const w = Math.abs(currX.value - startX.value);
  const h = Math.abs(currY.value - startY.value);

  const coord = getRealMouseCoord(e);
  
  if (!coord) {
      log("✗ 触控出界，动作丢弃");
      return;
  }

  // coord.x / coord.y 现在是图像像素坐标（与备份版一致）
  let nw = imageRef.value.naturalWidth || imageRef.value.clientWidth;
  let nh = imageRef.value.naturalHeight || imageRef.value.clientHeight;
  if (!nw || !nh) {
      log("⚠️ 图像引擎尚未初始化");
      return;
  }

  const cw = rect.width;
  const ch = rect.height;
  const imageAspect = nw / nh;
  const containerAspect = cw / ch;

  let renderW: number, renderH: number;
  if (imageAspect > containerAspect) {
    renderW = cw;
    renderH = cw / imageAspect;
  } else {
    renderH = ch;
    renderW = ch * imageAspect;
  }
  const realScale = nw / renderW;

  // [v1760] 直接计算逻辑 Points（废除 0-1000 归一化中间层）
  const _devSize = deviceSizeMap.value[selectedDevice.value];
  const pixToLogic = _devSize ? (nw / _devSize.width) : (config.value?.scale || 2);
  const finalX = coord.x;  // 截图像素坐标
  const finalY = coord.y;  // 截图像素坐标
  const startCoord = {
      x: Math.floor(((startX.value - (rect.width - renderW)/2) * realScale)),
      y: Math.floor(((startY.value - (rect.height - renderH)/2) * realScale))
  };

  const duration = Date.now() - pressStartTime.value;

  // 分支 1: 画笔裁切跳过点击判定
  if (isFreeDrawMode.value && isPickMode.value && freeDrawPoints.value.length > 5) {
      // 落入下方的画笔裁切逻辑
  } else if (w < 10 && h < 10) {
      // 分支 2: 颜色拾取
      if (isColorPickerMode.value) {
          try {
              const tempCanvas = document.createElement('canvas');
              tempCanvas.width = nw; tempCanvas.height = nh;
              const tCtx = tempCanvas.getContext('2d', { willReadFrequently: true });
              if (tCtx) {
                  tCtx.drawImage(imageRef.value, 0, 0, nw, nh);
                  const pixel = tCtx.getImageData(finalX, finalY, 1, 1).data;
                  const r = pixel[0] || 0, g = pixel[1] || 0, b = pixel[2] || 0;
                  const hex = '#' + ('000000' + ((r << 16) | (g << 8) | b).toString(16)).slice(-6).toUpperCase();
                  pickedColors.value.push({ x: finalX, y: finalY, hex });
              }
          } catch (e) {
              log('⚠️ 颜色拾取被安全策略阻止（跨域流），请切换 USB 模式后重试');
          }
          return;
      }
      // 分支 3: 点击/长按 → 直接下发逻辑 Points
      if (duration > 600) {
          sendDeviceAction('longPress', { x: Math.round(finalX / pixToLogic), y: Math.round(finalY / pixToLogic) });
      } else {
          sendDeviceAction('click', { x: Math.round(finalX / pixToLogic), y: Math.round(finalY / pixToLogic) });
      }
      return;
  }
  
  // 分支 4: 滑动 → 直接下发逻辑 Points
  if (!isPickMode.value) {
      if(startCoord?.x > 0 && startCoord?.y > 0) {
          sendDeviceAction('swipe', { 
              x1: Math.round(startCoord.x / pixToLogic), 
              y1: Math.round(startCoord.y / pixToLogic), 
              x2: Math.round(finalX / pixToLogic), 
              y2: Math.round(finalY / pixToLogic)
          });
      }
      return;
  }

  // ==================== 以下为裁切模式（isPickMode = true） ====================
  const offsetX = (cw - renderW) / 2;
  const offsetY = (ch - renderH) / 2;
  
  // 获取干净的图像源（处理 tainted canvas）
  let cleanImgSource: HTMLImageElement | HTMLCanvasElement = imageRef.value;
  let isTainted = false;
  try {
      const probe = document.createElement('canvas');
      probe.width = 1; probe.height = 1;
      const pCtx = probe.getContext('2d');
      if (pCtx) {
          pCtx.drawImage(imageRef.value, 0, 0, 1, 1);
          probe.toDataURL();
      }
  } catch {
      isTainted = true;
  }

  if (isTainted) {
      log('📡 检测到安全沙箱限制，正通过后端获取截图数据...');
      try {
          const res = await authFetch(`${apiBase}/action_proxy`, {
              method: 'POST',
              body: JSON.stringify({
                  udid: selectedDevice.value,
                  ecmain_url: ecmainUrl.value,
                  action_type: 'WDA_SCREENSHOT',
                  connection_mode: connectionMode.value
              })
          });
          const data = await res.json();
          if (data.screenshot_b64) {
              const tmpImg = new Image();
              await new Promise<void>((resolve, reject) => {
                  tmpImg.onload = () => resolve();
                  tmpImg.onerror = () => reject();
                  tmpImg.src = 'data:image/jpeg;base64,' + data.screenshot_b64;
              });
              cleanImgSource = tmpImg;
              nw = tmpImg.naturalWidth;
              nh = tmpImg.naturalHeight;
          } else {
              log('✗ 后端截图失败，裁切取消');
              freeDrawPoints.value = [];
              return;
          }
      } catch (e) {
          log('✗ 后端截图请求异常，裁切取消');
          freeDrawPoints.value = [];
          return;
      }
  }
  
  // ===== 分支 5: 画笔裁切 (备份版像素坐标逻辑) =====
  if (isFreeDrawMode.value && freeDrawPoints.value.length > 5) {
      const pts = freeDrawPoints.value;
      let minCX = Infinity, minCY = Infinity, maxCX = -Infinity, maxCY = -Infinity;
      for (const p of pts) {
          if (p.x < minCX) minCX = p.x;
          if (p.y < minCY) minCY = p.y;
          if (p.x > maxCX) maxCX = p.x;
          if (p.y > maxCY) maxCY = p.y;
      }
      // pts 存储的是 canvas 物理坐标 (来自 e.clientX - rect.left)
      const rx = (minCX - offsetX) * realScale;
      const ry = (minCY - offsetY) * realScale;
      const realW = (maxCX - minCX) * realScale;
      const realH = (maxCY - minCY) * realScale;
      
      if (rx < 0 || ry < 0 || rx + realW > nw || ry + realH > nh || realW < 5 || realH < 5) {
          freeDrawPoints.value = [];
          return;
      }
      
      const tempCanvas = document.createElement('canvas');
      tempCanvas.width = realW; tempCanvas.height = realH;
      const tCtx = tempCanvas.getContext('2d');
      if (tCtx) {
          tCtx.drawImage(cleanImgSource, rx, ry, realW, realH, 0, 0, realW, realH);
          try {
              const b64 = tempCanvas.toDataURL('image/png').split(',')[1] || '';
              pendingCrop.value = { b64: b64, w: realW|0, h: realH|0 };
              log(`✓ 画笔裁切：${realW|0}x${realH|0}，精粹已落入暂存仓等待确认。`);
          } catch (e) {
              log('✗ 裁切导出失败（Canvas 安全限制）');
          }
      }
      freeDrawPoints.value = [];
      return;
  }
  
  // ===== 分支 6: 矩形裁切 (备份版像素坐标逻辑) =====
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
    tCtx.drawImage(cleanImgSource, rx, ry, realW, realH, 0, 0, realW, realH);
    try {
        const b64 = tempCanvas.toDataURL('image/png').split(',')[1] || '';
        pendingCrop.value = { b64: b64, w: realW|0, h: realH|0 };
        log(`✓ 矩形截切： ${realW|0}x${realH|0}，已截断，请点击完成归入收纳匣。`);
    } catch (e) {
        log('✗ 裁切导出失败（Canvas 安全限制）');
    }
  }
};

const handleDoubleClickLasso = () => {
   if (isLassoMode.value && lassoPoints.value.length >= 3) {
      completeLasso();
   }
};

const completeLasso = () => {
    if (lassoPoints.value.length < 3 || !canvasRef.value || !imageRef.value) {
       lassoPoints.value = [];
       currentMousePos.value = null;
       redrawCanvasForLasso();
       return;
    }
    
    const rect = canvasRef.value.getBoundingClientRect();
    const nw = imageRef.value.naturalWidth || 0;
    const nh = imageRef.value.naturalHeight || 0;
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

    const realPts = lassoPoints.value.map(p => {
        return {
            x: Math.floor((p.x - offsetX) * realScale),
            y: Math.floor((p.y - offsetY) * realScale)
        };
    });

    const xs = realPts.map(p => p.x);
    const ys = realPts.map(p => p.y);
    const startXReal = Math.min(...xs);
    const endXReal = Math.max(...xs);
    const startYReal = Math.min(...ys);
    const endYReal = Math.max(...ys);

    const trueW = endXReal - startXReal;
    const trueH = endYReal - startYReal;

    if (trueW <= 5 || trueH <= 5) {
       log("✗ 套索区域过小，视为无效裁切");
       lassoPoints.value = [];
       currentMousePos.value = null;
       redrawCanvasForLasso();
       return;
    }

    const offCanvas = document.createElement('canvas');
    offCanvas.width = trueW;
    offCanvas.height = trueH;
    const offCtx = offCanvas.getContext('2d');
    if (offCtx) {
        offCtx.beginPath();
        offCtx.moveTo(realPts[0]!.x - startXReal, realPts[0]!.y - startYReal);
        for(let i=1; i<realPts.length; i++) {
            offCtx.lineTo(realPts[i]!.x - startXReal, realPts[i]!.y - startYReal);
        }
        offCtx.closePath();
        offCtx.clip();

        offCtx.drawImage(
            imageRef.value,
            startXReal, startYReal, trueW, trueH,
            0, 0, trueW, trueH
        );

        const b64 = offCanvas.toDataURL('image/png').split(',')[1] || '';
        pendingCrop.value = { b64, w: Math.round(trueW), h: Math.round(trueH) };
        
        log(`✓ 多边形套索切图成功 (底宽: ${Math.round(trueW)}x${Math.round(trueH)})，待确认。`);
    }

    lassoPoints.value = [];
    currentMousePos.value = null;
    redrawCanvasForLasso();
};

const syncCanvasSize = () => {
  if(imageRef.value && canvasRef.value) {
      // [v1682.17] 强制同步 Canvas 物理尺寸与 Image 显示尺寸一致
      // 解决 object-fit: contain 导致的点击点偏移问题
      const w = imageRef.value.clientWidth;
      const h = imageRef.value.clientHeight;
      if (w > 0 && h > 0) {
          canvasRef.value.width = w;
          canvasRef.value.height = h;
          // [v1682.18] 物理像素对齐：确保 Canvas 占据整个可视区，避免 sub-pixel 导致的出界判定
          canvasRef.value.style.width = w + 'px';
          canvasRef.value.style.height = h + 'px';
      }
  }
}

// ==================== 本地图片上传转 Base64 ====================
const fileInputRef = ref<HTMLInputElement | null>(null);

const triggerImageUpload = () => {
    if (fileInputRef.value) {
        fileInputRef.value.click();
    }
};

const handleImageUpload = (event: Event) => {
    const target = event.target as HTMLInputElement;
    const file = target.files?.[0];
    if (!file) return;
    
    // 重置 input，允许重复上传同一张图片
    target.value = '';

    if (!file.type.startsWith('image/')) {
        log('✗ 错误：请选择有效的图片文件！');
        return;
    }

    const reader = new FileReader();
    reader.onload = (e) => {
        const dataUrl = e.target?.result as string;
        if (!dataUrl) return;

        // 提取纯 Base64 负载
        const b64 = dataUrl.split(',')[1] || '';
        
        // 加载图片以获取真实宽高
        const tempImg = new Image();
        tempImg.onload = () => {
            const nw = tempImg.naturalWidth;
            const nh = tempImg.naturalHeight;
            
            // 仅抛入预览收纳仓供代码调试区自主装填
            pickedImages.value.push({ b64: b64, w: nw|0, h: nh|0 });
            
            log(`✓ 外置上传：${nw|0}x${nh|0}，已陈列至取模仓！`);
        };
        tempImg.src = dataUrl;
    };
    reader.onerror = () => {
        log('✗ 本地图片装载失败。');
    };
    reader.readAsDataURL(file);
};

</script>

<template>
    <!-- =============== 登录页面 =============== -->
    <div v-if="!isLoggedIn" class="flex items-center justify-center h-screen w-full bg-gradient-to-br from-gray-950 via-gray-900 to-gray-950 selection:bg-blue-500/30">
      <div class="w-[400px] bg-gray-900/80 border border-gray-700/50 rounded-2xl shadow-2xl backdrop-blur-xl overflow-hidden">
        <div class="p-8 border-b border-gray-800 text-center">
          <h1 class="text-2xl font-bold text-gray-100 tracking-widest">⚡️ ECWDA 战术控制中心</h1>
          <p class="text-xs text-gray-500 mt-2">请输入管理员账号登录系统</p>
        </div>
        <div class="p-8 flex flex-col gap-5">
          <div class="flex flex-col gap-1.5">
            <label class="text-xs text-gray-400 font-bold uppercase tracking-wider">用户名</label>
            <input v-model="loginForm.username" @keyup.enter="doLogin" type="text" placeholder="输入管理员账号" 
                   class="w-full bg-gray-950 border border-gray-700 rounded-lg px-4 py-3 text-gray-200 outline-none focus:border-blue-500 transition-colors font-mono" />
          </div>
          <div class="flex flex-col gap-1.5">
            <label class="text-xs text-gray-400 font-bold uppercase tracking-wider">密码</label>
            <input v-model="loginForm.password" @keyup.enter="doLogin" type="password" placeholder="输入密码" 
                   class="w-full bg-gray-950 border border-gray-700 rounded-lg px-4 py-3 text-gray-200 outline-none focus:border-blue-500 transition-colors font-mono" />
          </div>
          <div v-if="loginError" class="text-red-400 text-xs bg-red-900/20 border border-red-800/50 rounded-lg px-3 py-2 text-center">
            {{ loginError }}
          </div>
          <button @click="doLogin" :disabled="loginLoading" 
                  class="w-full py-3 bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-500 hover:to-indigo-500 text-white font-bold rounded-lg shadow-lg transition-all active:scale-[0.98] disabled:opacity-50 tracking-wider">
            <span v-if="!loginLoading">🔐 登录系统</span>
            <span v-else class="flex items-center justify-center gap-2">
              <svg class="animate-spin h-4 w-4" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path></svg>
              验证中...
            </span>
          </button>
        </div>
      </div>
    </div>

    <!-- =============== 主应用（已登录） =============== -->
    <div v-else class="flex flex-col h-screen w-full bg-gray-900 text-gray-300 font-sans selection:bg-blue-500/30 outline-none overflow-hidden" :class="{'cursor-move': deviceWin.isDragging, 'cursor-se-resize': deviceWin.isResizing}">
    
    <!-- 顶栏：极简沉浸式面板 -->
    <div class="flex justify-between items-center bg-gray-950 border-b border-gray-800 py-3 px-6 text-gray-100 text-sm font-bold shadow-lg relative z-50 tracking-widest">
        <div class="flex items-center">
            <span>ECWDA 战术控制中心</span>
            <span class="ml-2 text-[10px] bg-gradient-to-r from-blue-600 to-indigo-600 text-white px-2 py-0.5 rounded-full shadow-md">PRO</span>
        </div>
        <div class="flex items-center gap-4">
            <span class="text-[11px] text-gray-400 font-normal">
                <span class="text-gray-500">当前用户：</span>
                <span class="text-blue-400 font-bold">{{ currentUser?.username }}</span>
                <span class="ml-1.5 px-1.5 py-0.5 rounded text-[9px] font-bold" 
                      :class="isSuperAdmin ? 'bg-amber-900/40 text-amber-400 border border-amber-700' : 'bg-gray-800 text-gray-400 border border-gray-700'">
                    {{ isSuperAdmin ? '超级管理员' : '管理员' }}
                </span>
            </span>
            <button @click="doLogout" class="text-[11px] text-gray-500 hover:text-red-400 transition-colors font-normal border border-gray-700 hover:border-red-800 px-3 py-1 rounded">
                🚪 登出
            </button>
        </div>
    </div>

    <!-- 顶层主选项卡：标签 -->
    <div class="flex items-end bg-gray-900 border-b border-gray-800 px-6 pt-3 text-xs gap-2 shadow-inner z-40 relative">
      <div v-for="tab in visibleTabs" 
           :key="tab"
           @click="activeTab = tab"
           :class="['px-6 py-2 rounded-t-lg cursor-pointer transition-colors duration-300 border-t border-l border-r', 
                    activeTab === tab ? 'bg-gray-800 text-blue-400 border-gray-700 pb-3 -mb-[1px] font-semibold border-t-2 border-t-blue-500' : 'border-transparent text-gray-500 hover:text-gray-300 hover:bg-gray-800/50 font-medium']">
        {{ tab }}
      </div>
    </div>
 
    <!-- 筛选栏 (仅在特定页面显示) -->
    <div v-show="['📱 手机列表', '⚡️ 控制台'].includes(activeTab)" class="flex items-center flex-wrap bg-gray-900 border-b border-gray-800 px-6 py-2 text-[11px] gap-4 shadow-sm z-30 relative shrink-0">
       <div class="text-gray-400 font-bold mr-2 flex items-center"><span class="mr-1 text-sm">🔍</span> 筛选</div>
       
       <div class="flex items-center gap-2">
         <span class="text-gray-500 font-medium">编号:</span>
         <input v-model="filterParams.device_no" type="text" placeholder="编号" class="bg-gray-950 border border-gray-700 rounded px-2 py-1 text-gray-200 outline-none focus:border-blue-500 focus:bg-gray-800 w-24 transition-colors">
       </div>
       
       <div class="flex items-center gap-2">
         <span class="text-gray-500 font-medium">IP:</span>
         <input v-model="filterParams.ip" type="text" placeholder="IP" class="bg-gray-950 border border-gray-700 rounded px-2 py-1 text-gray-200 outline-none focus:border-blue-500 focus:bg-gray-800 w-28 transition-colors">
       </div>
       
       <div class="flex items-center gap-2">
         <span class="text-gray-500 font-medium">国家:</span>
         <select v-model="filterParams.country" class="bg-gray-950 border border-gray-700 rounded px-2 py-1 text-gray-200 outline-none focus:border-blue-500 focus:bg-gray-800 w-24 transition-colors cursor-pointer">
           <option value="">全部</option>
           <option v-for="c in countries" :key="c.id" :value="c.name">{{ c.name }}</option>
         </select>
       </div>
       
       <div class="flex items-center gap-2">
         <span class="text-gray-500 font-medium">分组:</span>
         <select v-model="filterParams.group" class="bg-gray-950 border border-gray-700 rounded px-2 py-1 text-gray-200 outline-none focus:border-blue-500 focus:bg-gray-800 w-24 transition-colors cursor-pointer">
           <option value="">全部</option>
           <option v-for="g in groups" :key="g.id" :value="g.name">{{ g.name }}</option>
         </select>
       </div>
       
       <div class="flex items-center gap-2">
         <span class="text-gray-500 font-medium">执行时间:</span>
         <select v-model="filterParams.exec_time" class="bg-gray-950 border border-gray-700 rounded px-2 py-1 text-gray-200 outline-none focus:border-blue-500 focus:bg-gray-800 w-24 transition-colors cursor-pointer">
           <option value="">全部</option>
           <option v-for="t in execTimes" :key="t.id" :value="t.name">{{ t.name }}点</option>
         </select>
       </div>
       
       <div class="flex items-center gap-2">
         <span class="text-gray-500 font-medium">在线状态:</span>
         <select v-model="filterParams.status" class="bg-gray-950 border border-gray-700 rounded px-2 py-1 text-gray-200 outline-none focus:border-blue-500 focus:bg-gray-800 w-24 transition-colors cursor-pointer">
           <option value="">全部</option>
           <option value="online">在线</option>
           <option value="offline">离线</option>
         </select>
       </div>
       
       <div v-if="isSuperAdmin" class="flex items-center gap-2">
         <span class="text-gray-500 font-medium">管理员:</span>
         <input v-model="filterParams.admin" type="text" placeholder="管理员账号" class="bg-gray-950 border border-gray-700 rounded px-2 py-1 text-gray-200 outline-none focus:border-blue-500 focus:bg-gray-800 w-28 transition-colors">
       </div>
       
       <!-- 以前有应用按钮，现在由于双向计算属性绑定，可不删且无需绑定事件，也可去除。这里留存 -->
       <button class="ml-auto bg-blue-600 opacity-0 pointer-events-none hover:bg-blue-500 text-white px-4 py-1.5 rounded shadow-md transition-colors font-bold tracking-wider active:scale-[0.98]">应用</button>
    </div>
    
    <!-- 核心内容切换区 -->
    <main class="flex-1 overflow-hidden flex flex-col relative bg-[#0B0F19]">
        <!-- =============== 📋 任务列表 =============== -->
        <div v-if="activeTab === '📋 任务列表'" class="flex flex-1 flex-col overflow-auto p-6">
        <div class="max-w-7xl mx-auto w-full">
            <div class="flex justify-between items-center mb-6">
                <h2 class="text-2xl font-semibold text-gray-100 flex items-center">
                   <span class="mr-2">📋</span>全部自动执行任务
                </h2>
                <button @click="openScriptModal()" class="bg-indigo-600 outline-none hover:bg-indigo-700 text-white px-4 py-2 rounded shadow-md transition-colors font-medium flex items-center">
                    <svg class="w-5 h-5 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"></path></svg>
                    新建动作脚本
                </button>
            </div>
            
            <div class="bg-gray-800 border border-gray-700 rounded-xl shadow-lg overflow-hidden">
                <table class="w-full text-left border-collapse text-sm">
                    <thead class="bg-gray-900 border-b border-gray-700 select-none">
                        <tr>
                            <th class="p-4 text-gray-400 font-bold uppercase tracking-wider w-1/4">脚本名称</th>
                            <th class="p-4 text-gray-400 font-bold uppercase tracking-wider text-center">指派范围</th>
                            <th class="p-4 text-gray-400 font-bold uppercase tracking-wider text-center">定时触发</th>
                            <th class="p-4 text-gray-400 font-bold uppercase tracking-wider text-right">最近更新</th>
                            <th class="p-4 text-gray-400 font-bold uppercase tracking-wider text-center w-28">操作</th>
                        </tr>
                    </thead>
                    <tbody class="divide-y divide-gray-700/50">
                        <!-- 空状态 -->
                        <tr v-if="scripts.length === 0">
                            <td colspan="5" class="py-16 text-center text-gray-500 bg-gray-800/30">
                                <svg class="w-12 h-12 mx-auto mb-3 opacity-50" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"></path></svg>
                                <p class="text-base font-semibold text-gray-400">暂无自动任务动作</p>
                                <p class="text-xs mt-1">点击右上角新建脚本将自动下发到已连接设备中</p>
                            </td>
                        </tr>
                        <!-- 任务列 -->
                        <tr v-for="script in scripts" :key="script.id" class="hover:bg-gray-700/30 transition-colors group">
                            <td class="p-4">
                                <div class="font-semibold text-gray-200 text-base flex items-center gap-2">
                                    <span class="text-indigo-400">📄</span> {{ script.name }}
                                </div>
                                <div class="text-[10px] text-gray-500 font-mono mt-1 opacity-60 hover:opacity-100 transition-opacity" title="脚本唯一标识ID">ID: {{ script.id }}</div>
                            </td>
                            <td class="p-4 text-center">
                                <div class="flex flex-wrap shadow-inner items-center justify-center gap-2 text-xs bg-gray-900/50 p-2 rounded-lg border border-gray-800">
                                    <span v-if="script.country" class="px-2 py-0.5 rounded bg-blue-900/30 text-blue-400 border border-blue-800/50" title="国家">🌍 {{ script.country }}</span>
                                    <span v-if="script.group_name" class="px-2 py-0.5 rounded bg-purple-900/30 text-purple-400 border border-purple-800/50" title="分组">🏷️ {{ script.group_name }}</span>
                                    <span v-if="!script.country && !script.group_name" class="text-gray-500 italic">全局泛滥下发</span>
                                </div>
                            </td>
                            <td class="p-4 text-center">
                                <span v-if="script.exec_time" class="px-2 py-1 rounded bg-amber-900/30 text-amber-500 border border-amber-800/50 shadow-sm text-xs font-bold font-mono">⏱️ {{ script.exec_time }}:00</span>
                                <span v-else class="text-gray-600 text-xs italic px-2 py-1 rounded border border-gray-700/50 bg-gray-800/30">即时/全天候</span>
                            </td>
                            <td class="p-4 text-right text-sm text-gray-400 font-mono tracking-tighter">
                                {{ new Date(script.updated_at * 1000).toLocaleString() }}
                            </td>
                            <td class="p-4 text-center">
                                <div class="flex justify-center space-x-2">
                                    <button @click="openScriptModal(script)" class="p-2 bg-blue-900/30 text-blue-400 hover:bg-blue-600 hover:text-white rounded border border-blue-900/50 hover:border-blue-500 transition-all shadow-sm" title="编辑">
                                        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"></path></svg>
                                    </button>
                                    <button @click="deleteScript(script.id)" class="p-2 bg-red-900/30 text-red-400 hover:bg-red-600 hover:text-white rounded border border-red-900/50 hover:border-red-500 transition-all shadow-sm" title="删除">
                                        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"></path></svg>
                                    </button>
                                </div>
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>

        <!-- 脚本编辑 Modal -->
        <div v-if="isScriptModalOpen" class="fixed inset-0 z-[100] flex items-center justify-center bg-black/70 backdrop-blur-sm">
            <div class="bg-gray-800 border border-gray-700 w-full max-w-4xl rounded-xl shadow-2xl flex flex-col" style="max-height: 90vh;">
                <div class="px-6 py-4 border-b border-gray-700 flex justify-between items-center bg-gray-800/80 rounded-t-xl">
                    <h3 class="text-lg font-bold text-gray-100">{{ editingScript.id ? '编辑任务脚本' : '新建任务脚本' }}</h3>
                    <button @click="isScriptModalOpen=false" class="text-gray-400 hover:text-white outline-none transition-colors">
                        <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path></svg>
                    </button>
                </div>
                <div class="p-6 flex-1 overflow-auto flex flex-col space-y-4">
                    <div>
                        <label class="block text-sm font-medium text-gray-300 mb-1">脚本名称</label>
                        <input v-model="editingScript.name" type="text" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2.5 text-gray-100 outline-none focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 transition-all font-medium" placeholder="名称标识 (例如: 自动点赞)">
                    </div>
                    
                    <div class="grid grid-cols-3 gap-4">
                        <div>
                            <label class="block text-sm font-medium text-gray-300 mb-1">指派国家范围</label>
                            <select v-model="(editingScript as any).country" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2.5 text-gray-100 outline-none focus:border-indigo-500 transition-all font-medium">
                                <option value="">(空值/全量)</option>
                                <option v-for="c in countries" :key="c.id" :value="c.name">{{ c.name }}</option>
                            </select>
                        </div>
                        <div>
                            <label class="block text-sm font-medium text-gray-300 mb-1">指派分组范围</label>
                            <select v-model="(editingScript as any).group_name" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2.5 text-gray-100 outline-none focus:border-indigo-500 transition-all font-medium">
                                <option value="">(空值/全量)</option>
                                <option v-for="g in groups" :key="g.id" :value="g.name">{{ g.name }}</option>
                            </select>
                        </div>
                        <div>
                            <label class="block text-sm font-medium text-gray-300 mb-1">指派定时启动时辰</label>
                            <select v-model="(editingScript as any).exec_time" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2.5 text-gray-100 outline-none focus:border-indigo-500 transition-all font-medium">
                                <option value="">(空值/全量)</option>
                                <option v-for="t in execTimes" :key="t.id" :value="t.name">{{ t.name }} 点整</option>
                            </select>
                        </div>
                    </div>
                    
                    <div class="flex-1 flex flex-col min-h-[400px]">
                        <div class="flex justify-between items-end mb-1">
                            <label class="block text-sm font-medium text-gray-300">JavaScript执行代码</label>
                        </div>
                        <textarea v-model="editingScript.code" class="w-full flex-1 bg-[#1E1E1E] border border-gray-700 rounded-lg p-4 text-gray-300 font-mono text-sm leading-relaxed outline-none focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 transition-all resize-none shadow-inner" placeholder="wda.home(); ..."></textarea>
                    </div>
                </div>
                <div class="px-6 py-4 border-t border-gray-700 flex justify-end space-x-3 bg-gray-800/80 rounded-b-xl">
                    <button @click="isScriptModalOpen=false" class="px-5 py-2 rounded-lg outline-none text-gray-300 hover:bg-gray-700 transition-colors font-medium border border-transparent">取消</button>
                    <button @click="saveScript" class="px-6 py-2 bg-indigo-600 hover:bg-indigo-700 outline-none rounded-lg text-white font-medium shadow-[0_4px_10px_rgba(79,70,229,0.3)] transition-all">保存</button>
                </div>
            </div>
        </div>
    </div>

    <!-- 手机列表真实渲染 -->
        <!-- =============== 📱 手机列表 =============== -->
        <div v-if="activeTab === '📱 手机列表'" class="flex flex-1 flex-col overflow-hidden p-6 gap-4 bg-gray-950">
      <div class="flex items-center justify-between mb-2">
         <div class="flex items-center gap-4">
            <h2 class="text-gray-200 text-lg font-bold tracking-wide flex items-center gap-2">📱 在线雷达设备矩阵</h2>
            <div v-if="selectedDevices.length > 0" class="flex items-center gap-2 bg-indigo-900/40 border border-indigo-500/50 px-3 py-1.5 rounded-lg animate-in fade-in slide-in-from-left-4 duration-300">
               <span class="text-indigo-200 text-xs font-bold">已选 {{ selectedDevices.length }} 台</span>
               <div class="h-4 w-px bg-indigo-500/30 mx-1"></div>
                <button @click="openBatchConfigModal" class="text-indigo-300 hover:text-white text-xs font-bold transition-colors">📝 批量修改</button>
                <button @click="openOneshotModal" class="text-emerald-300 hover:text-white text-xs font-bold transition-colors ml-2">⚡ 下发一次性任务</button>
                <button @click="enterBatchControl" class="text-amber-400 hover:text-white text-xs font-bold transition-colors ml-2">🎛 批量控制</button>
                <button @click="deleteBatchDevices" class="text-red-400 hover:text-red-300 text-xs font-bold transition-colors ml-2">🗑 批量删除</button>
               <button @click="selectedDevices = []" class="text-gray-400 hover:text-white text-xs ml-2">取消</button>
            </div>
         </div>
         <button @click="fetchDevices" :disabled="isDevicesLoading" :class="[isDevicesLoading ? 'opacity-50 cursor-not-allowed' : 'hover:bg-gray-700', 'bg-gray-800 text-gray-300 px-4 py-1.5 rounded shadow border border-gray-700 font-bold transition-all flex items-center gap-2']">
            <span :class="{'animate-spin inline-block': isDevicesLoading}">🔄</span> 
            {{ isDevicesLoading ? '刷新中...' : '刷新矩阵' }}
         </button>
      </div>
      
      <div class="flex-1 overflow-y-auto custom-scrollbar">
         <table class="w-full text-left border-collapse text-xs">
           <thead class="bg-gray-900 border-b border-gray-800 sticky top-0 select-none">
              <tr>
                 <th class="p-3 w-10 text-center select-none border-r border-gray-800 bg-gray-900/50">
                   <input type="checkbox" v-model="isAllSelected" class="w-4 h-4 rounded border-gray-700 bg-gray-950 text-indigo-600 focus:ring-indigo-500 focus:ring-offset-gray-900 transition-all cursor-pointer">
                 </th>
                 <th @click="sortBy('device_no')" class="p-3 text-gray-400 font-bold uppercase tracking-wider w-1/5 cursor-pointer hover:bg-gray-800 transition-colors">设备编号 / UDID <span v-if="sortKey==='device_no'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th @click="sortBy('ip')" class="p-3 text-gray-400 font-bold uppercase tracking-wider cursor-pointer hover:bg-gray-800 transition-colors">局域 IP/归属 <span v-if="sortKey==='ip'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th @click="sortBy('status')" class="p-3 text-gray-400 font-bold uppercase tracking-wider text-center cursor-pointer hover:bg-gray-800 transition-colors">状态 <span v-if="sortKey==='status'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th @click="sortBy('battery')" class="p-3 text-gray-400 font-bold uppercase tracking-wider text-center cursor-pointer hover:bg-gray-800 transition-colors">电量 <span v-if="sortKey==='battery'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th @click="sortBy('app_version')" class="p-3 text-gray-400 font-bold uppercase tracking-wider text-center cursor-pointer hover:bg-gray-800 transition-colors">ECMAIN <span v-if="sortKey==='app_version'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th @click="sortBy('ecwda_version')" class="p-3 text-gray-400 font-bold uppercase tracking-wider text-center cursor-pointer hover:bg-gray-800 transition-colors">ECWDA <span v-if="sortKey==='ecwda_version'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th @click="sortBy('tiktok_version')" class="p-3 text-gray-400 font-bold uppercase tracking-wider text-center cursor-pointer hover:bg-gray-800 transition-colors">TikTok <span v-if="sortKey==='tiktok_version'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th @click="sortBy('vpn_active')" class="p-3 text-gray-400 font-bold uppercase tracking-wider text-center cursor-pointer hover:bg-gray-800 transition-colors">VPN <span v-if="sortKey==='vpn_active'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th @click="sortBy('vpn_node')" class="p-3 text-gray-400 font-bold uppercase tracking-wider text-center cursor-pointer hover:bg-gray-800 transition-colors">VPN 节点 <span v-if="sortKey==='vpn_node'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th @click="sortBy('admin_username')" class="p-3 text-gray-400 font-bold uppercase tracking-wider text-center cursor-pointer hover:bg-gray-800 transition-colors">管理员 <span v-if="sortKey==='admin_username'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th class="p-3 text-gray-400 font-bold uppercase tracking-wider text-center cursor-default">任务状态</th>
                 <th @click="sortBy('last_heartbeat')" class="p-3 text-gray-400 font-bold uppercase tracking-wider text-right cursor-pointer hover:bg-gray-800 transition-colors">最后上线 <span v-if="sortKey==='last_heartbeat'" class="ml-1">{{sortOrder===1?'⬆':'⬇'}}</span></th>
                 <th class="p-3 text-gray-400 font-bold uppercase tracking-wider text-center cursor-default">操作</th>
              </tr>
           </thead>
           <tbody class="divide-y divide-gray-800 select-text">
              <tr v-if="sortedDevices.length === 0">
                 <td colspan="13" class="p-8 text-center text-gray-500 font-medium tracking-wide pointer-events-none">
                   暂无高并发设备从底核发送微波跳变信号...
                 </td>
              </tr>
              <tr v-for="dev in sortedDevices" :key="dev.udid" :class="[selectedDevices.includes(dev.udid) ? 'bg-indigo-900/10 shadow-inner' : '', 'hover:bg-gray-900/50 transition-colors group']">
                 <td class="p-3 text-center border-r border-gray-800/30">
                   <input type="checkbox" :value="dev.udid" v-model="selectedDevices" class="w-4 h-4 rounded border-gray-700 bg-gray-950 text-indigo-600 focus:ring-indigo-500 focus:ring-offset-gray-900 transition-all cursor-pointer">
                 </td>
                 <td class="p-3 text-cyan-400 font-mono tracking-tighter relative">
                   <div class="flex items-center gap-2">
                     <div class="font-bold text-sm">{{ dev.device_no || '未知编号' }}</div>
                     <!-- 信道状态探针阵列 -->
                     <div class="flex items-center gap-1.5">
                       <span v-if="dev.can_usb" :class="[dev.status === 'offline' ? 'grayscale opacity-30 drop-shadow-none' : 'text-green-400 drop-shadow-[0_0_3px_rgba(74,222,128,0.8)]', 'text-[12px] transition-all cursor-help']" title="USB 高速直连">🔌</span>
                       <span v-if="dev.can_lan" :class="[dev.status === 'offline' ? 'grayscale opacity-30 drop-shadow-none' : 'text-amber-400 drop-shadow-[0_0_3px_rgba(251,191,36,0.8)]', 'text-[12px] transition-all cursor-help']" title="LAN 局域网通讯">📡</span>
                       <span v-if="dev.can_ws" :class="[dev.status === 'offline' ? 'grayscale opacity-30 drop-shadow-none' : 'text-indigo-400 drop-shadow-[0_0_3px_rgba(129,140,248,0.8)]', 'text-[12px] transition-all cursor-help']" title="WS 远端穿透长连接">☁️</span>
                     </div>
                   </div>
                   <div class="text-[10px] text-gray-500 mt-0.5">{{ dev.udid }}</div>
                 </td>
                 <td class="p-3 text-gray-300 font-mono">{{ dev.ip || dev.local_ip || '---.---.---.---' }}</td>
                 <td class="p-3 text-center">
                    <span v-if="dev.status === 'online'" class="bg-green-900/30 text-green-400 border border-green-800 px-2 py-0.5 rounded-full text-[10px] font-bold">空闲/在线</span>
                    <span v-else-if="dev.status === 'busy'" class="bg-amber-900/30 text-amber-400 border border-amber-800 px-2 py-0.5 rounded-full text-[10px] font-bold">任务中/繁忙</span>
                    <span v-else-if="dev.status === 'offline'" class="bg-gray-800 text-gray-400 border border-gray-600 px-2 py-0.5 rounded-full text-[10px] font-bold">离线/断联</span>
                    <span v-else class="text-gray-500 font-mono">{{ dev.status || '未知' }}</span>
                 </td>
                 <td class="p-3 text-center">
                    <div class="flex items-center justify-center gap-1">
                      <div class="w-8 bg-gray-800 rounded-sm h-1.5 overflow-hidden border border-gray-700">
                         <div class="bg-green-500 h-full" :style="{ width: (dev.battery || 0) + '%' }"></div>
                      </div>
                      <span class="text-gray-400 text-[10px] w-6 text-right">{{ dev.battery||0 }}%</span>
                    </div>
                 </td>
                 <td class="p-3 text-center">
                    <span class="bg-blue-900/30 text-blue-300 border border-blue-800 px-1.5 py-0.5 rounded text-[10px] font-mono">v{{ dev.app_version || 0 }}</span>
                 </td>
                 <td class="p-3 text-center">
                    <span v-if="dev.ecwda_version > 0" class="bg-purple-900/30 text-purple-300 border border-purple-800 px-1.5 py-0.5 rounded text-[10px] font-mono whitespace-nowrap">
                      v{{ dev.ecwda_version }}
                      <span v-if="dev.ecwda_status === 'offline'" class="ml-1 opacity-80" title="WDA 服务离线">❌</span>
                    </span>
                    <span v-else class="text-gray-600 text-[10px] font-mono">未安装</span>
                 </td>
                 <td class="p-3 text-center">
                    <span v-if="dev.tiktok_version" class="bg-pink-900/30 text-pink-300 border border-pink-800 px-1.5 py-0.5 rounded text-[10px] font-mono whitespace-nowrap">
                      v{{ dev.tiktok_version }}
                    </span>
                    <span v-else class="text-gray-600 text-[10px] font-mono">未安装</span>
                 </td>
                 <td class="p-3 text-center">
                    <span v-if="dev.vpn_active" class="bg-green-900/30 text-green-400 border border-green-800 px-1.5 py-0.5 rounded-full text-[10px] font-bold">✅ 已连接</span>
                    <span v-else class="text-gray-600 text-[10px] font-mono">未连接</span>
                 </td>
                 <td class="p-3 text-center">
                    <span v-if="dev.vpn_node" class="bg-indigo-900/30 text-indigo-300 border border-indigo-800 px-1.5 py-0.5 rounded text-[10px] whitespace-nowrap overflow-hidden text-ellipsis max-w-[150px] inline-block font-mono" :title="dev.vpn_node">{{ dev.vpn_node }}</span>
                 </td>
                 <td class="p-3 text-center">
                    <span v-if="dev.admin_username" class="bg-purple-900/30 text-purple-400 border border-purple-800 px-2 py-0.5 rounded text-[10px] font-bold">{{ dev.admin_username }}</span>
                    <span v-else class="text-gray-600 text-[10px]">--</span>
                 </td>
                 <td class="p-3 text-center">
                    <!-- 脚本执行状态：优先展示执行线程上报的 task_report -->
                    <div class="flex flex-col gap-1 items-center">
                       <!-- 执行线程上报的实时状态 -->
                       <template v-if="dev.task_report">
                          <template v-for="(rpt, ri) in [(() => { try { return JSON.parse(dev.task_report) } catch(e) { return null } })()]" :key="'rpt'+ri">
                             <template v-if="rpt">
                                <div class="flex items-center gap-1 justify-center w-full max-w-[160px]">
                                   <span class="text-[10px] text-gray-200 truncate font-bold" :title="rpt.task_name">{{ rpt.task_name }}</span>
                                </div>
                                <!-- 正在执行：蓝色脉冲 -->
                                <span v-if="rpt.status === '正在执行'" class="text-[9px] bg-blue-900/40 text-blue-400 border border-blue-700 px-1.5 py-0.5 rounded-full animate-pulse font-bold">🔄 正在执行</span>
                                <!-- 执行完成 + 成功 -->
                                <span v-else-if="rpt.status === '执行完成' && rpt.success" class="text-[9px] text-green-400 font-bold">✅ 执行成功</span>
                                <!-- 执行完成 + 失败：可点击查看日志 -->
                                <span v-else-if="rpt.status === '执行完成' && !rpt.success" 
                                      class="text-[9px] bg-red-900/40 text-red-400 border border-red-800 px-1.5 py-0.5 rounded-full cursor-pointer hover:bg-red-700 hover:text-white transition-colors font-bold"
                                      @click="showTaskError(rpt)">❌ 查看错误日志</span>
                                <div class="text-[8px] text-gray-600 font-mono">{{ rpt.time }}</div>
                             </template>
                          </template>
                       </template>
                       <!-- 心跳上报的任务列表（辅助信息） -->
                       <template v-else-if="dev.task_status">
                          <template v-for="(ts, si) in [(() => { try { return JSON.parse(dev.task_status) } catch(e) { return [] } })()]" :key="'ts'+si">
                             <div v-for="(item, idx) in ts" :key="idx" class="flex items-center gap-1 justify-center">
                                <span class="text-[10px] text-gray-400 truncate max-w-[100px]" :title="item.name">{{ item.name }}</span>
                                <span :class="['px-1 py-0 rounded text-[9px] font-mono whitespace-nowrap border', item.time === '等待执行' ? 'bg-blue-900/20 text-blue-400 border-blue-800/50' : 'bg-gray-800 text-gray-500 border-gray-700']">{{ item.time }}</span>
                             </div>
                          </template>
                       </template>
                       <span v-if="!dev.task_report && !dev.task_status" class="text-gray-600 text-[10px]">无任务</span>
                    </div>
                 </td>
                 <td class="p-3 text-gray-400 font-mono text-right text-[10px]">
                    {{ dev.last_heartbeat ? new Date(dev.last_heartbeat * 1000).toLocaleTimeString() : '---' }}
                 </td>
                 <td class="p-3 text-center">
                    <div class="flex items-center justify-center gap-2">
                       <button @click="openConfigModal(dev)" class="bg-teal-700 hover:bg-teal-600 text-white px-3 py-1 rounded shadow transition-colors font-bold text-[10px]">配置</button>
                       <button @click="selectDeviceAndConnect(dev, true)" class="bg-indigo-600 hover:bg-indigo-500 text-white px-3 py-1 rounded shadow transition-colors font-bold text-[10px]">控制</button>
                       <button @click="deleteDevice(dev)" class="bg-red-900/40 hover:bg-red-700 hover:text-white text-red-300 border border-red-800 px-3 py-1 rounded shadow transition-colors font-bold text-[10px]">删除</button>
                    </div>
                 </td>
              </tr>
           </tbody>
         </table>
      </div>
    </div>

    <!-- Removed dead code placeholder -->

    <!-- 中间巨型工作区：控制台(原脚本引擎) -->
        <!-- =============== ⚡️ 控制台 =============== -->
        <div v-if="activeTab === '⚡️ 控制台'" class="relative flex flex-col flex-1 overflow-auto bg-black bg-[radial-gradient(circle_at_center,_var(--tw-gradient-stops))] from-gray-900 via-gray-950 to-black p-0 custom-scrollbar">
      
      <!-- [上半区]: 控制台原主功能区 (精密动态对齐方案) -->
      <div class="relative flex shrink-0 justify-start pl-[460px] pr-4 pb-4" :style="{ height: (deviceWin.h + deviceWin.y) + 'px', paddingTop: deviceWin.y + 'px' }">
        <!-- 左：设备状态与光速屏幕投射及侧边实体按键融合区 (群控悬浮版) -->
        <div class="flex gap-2 shrink-0 absolute z-[100] shadow-2xl rounded-2xl"
             :style="{ left: deviceWin.x + 'px', top: deviceWin.y + 'px', width: deviceWin.w + 'px', height: deviceWin.h + 'px' }">
             
          <div class="flex flex-col flex-1 bg-gray-800 border border-gray-700 rounded-xl shadow-2xl relative z-30 overflow-hidden">
        
        <!-- 连接面板被压缩至单行 (顶端拖动握把) -->
        <div @mousedown="startWinDrag" class="cursor-move p-3 border-b border-gray-700 flex items-center justify-between shrink-0 w-full bg-gray-900/50 text-xs transition-colors hover:bg-gray-900/80 active:bg-gray-800">
           <!-- 动态显示区：根据模式展示不同内容 -->
           <div class="flex items-center gap-2 flex-1 ml-1">
             
             <select v-if="batchDevices?.length > 0" v-model="selectedDevice" @change="handleMasterChange" @mousedown.stop class="bg-gray-950 border border-gray-700 hover:border-gray-500 rounded-md px-2 py-1.5 text-gray-200 shadow-inner font-mono text-[11px] w-[140px] outline-none transition-all cursor-pointer focus:border-indigo-500">
                <option v-for="dev in batchDevices" :key="dev.udid" :value="dev.udid">
                   {{ dev.device_no || dev.udid.substring(0,8) }}
                </option>
             </select>
             <span v-else class="bg-gray-900 border border-gray-700 rounded-md px-2 py-1.5 text-gray-600 shadow-inner font-mono text-[11px] w-[140px] text-center italic">
                未锁定
             </span>
           </div>
           
           <!-- 三态单选按钮组 -->
           <div @mousedown.stop class="flex items-center bg-gray-950 rounded-lg p-0.5 border border-gray-700 shadow-inner overflow-hidden shrink-0 mr-1">
             <label class="cursor-pointer px-3 py-1.5 rounded-md text-[10px] font-bold transition-all flex items-center gap-1"
                    :class="connectionMode === 'usb' ? 'bg-green-600 text-white shadow' : 'text-gray-500 hover:text-gray-300'">
                <input type="radio" value="usb" v-model="connectionMode" class="hidden" @change="updateStreamUrl">🔌 USB
             </label>
             <label class="cursor-pointer px-3 py-1.5 rounded-md text-[10px] font-bold transition-all flex items-center gap-1"
                    :class="connectionMode === 'lan' ? 'bg-amber-600 text-white shadow' : 'text-gray-500 hover:text-gray-300'">
                <input type="radio" value="lan" v-model="connectionMode" class="hidden" @change="updateStreamUrl">📡 内网
             </label>
             <label class="cursor-pointer px-3 py-1.5 rounded-md text-[10px] font-bold transition-all flex items-center gap-1"
                    :class="connectionMode === 'ws' ? 'bg-indigo-600 text-white shadow' : 'text-gray-500 hover:text-gray-300'">
                <input type="radio" value="ws" v-model="connectionMode" class="hidden" @change="updateStreamUrl">☁️ WS
             </label>
           </div>
        </div>

        <!-- 极致纯净的黑色原生屏幕区 -->
        <div class="flex-1 bg-black relative flex justify-center items-center overflow-hidden">
            <div v-if="!streamUrl" class="flex flex-col items-center justify-center opacity-50">
               <span class="text-4xl mb-4 text-gray-600">📴</span>
               <span class="text-gray-500 font-medium tracking-wide text-sm">空闲信道等待推流指令</span>
            </div>
            
            <img ref="imageRef" v-if="streamUrl" :src="streamUrl" @load="syncCanvasSize" class="h-full max-w-full object-contain pointer-events-none absolute" crossorigin="anonymous" />
            
            <!-- 将十字光标恢复为默认指针光标，体验更舒适 -->
            <canvas ref="canvasRef" @mousedown="startDraw" @mousemove="handleMouseMove" @mouseup="endDraw" @mouseleave="endDraw" @dblclick="handleDoubleClickLasso" class="cursor-pointer absolute" style="z-index: 20;"></canvas>
        </div>

        <!-- 底侧分离坐标观测器 -->
        <div class="bg-gray-900 border-t border-gray-700/80 p-2 shrink-0">
            <div class="px-3 py-1.5 bg-black rounded-md text-gray-300 flex justify-between text-[11px] font-mono border border-gray-800 items-center">
              <div class="flex items-center gap-3">
                 <div class="flex items-center gap-1.5">
                      <span class="text-indigo-400 font-bold tracking-wider">
                        {{ pntLabel !== '(--, --)' ? pntLabel : (selectedDevice && deviceSizeMap[selectedDevice] ? `${deviceSizeMap[selectedDevice]?.width || 0} × ${deviceSizeMap[selectedDevice]?.height || 0} pt` : 'READY') }}
                      </span>
                     <!-- v1668.23 实时延迟监控 -->
                     <div class="flex items-center gap-1 px-1.5 py-0.5 rounded-full mr-1" :class="[wsLatency !== '--' && parseInt(wsLatency) < 200 ? 'bg-green-900/30 border border-green-600/40' : wsLatency !== '--' && parseInt(wsLatency) < 500 ? 'bg-yellow-900/30 border border-yellow-600/40' : 'bg-gray-800/60 border border-gray-700/50']" :title="'上次指令往返延迟: ' + wsLatency">
                        <span class="w-1 h-1 rounded-full" :class="[wsLatency !== '--' && parseInt(wsLatency) < 200 ? 'bg-green-400' : wsLatency !== '--' && parseInt(wsLatency) < 500 ? 'bg-yellow-400' : 'bg-gray-500']"></span>
                        <span class="text-[9px] font-mono font-bold tracking-tight whitespace-nowrap" :class="[wsLatency !== '--' && parseInt(wsLatency) < 200 ? 'text-green-400' : wsLatency !== '--' && parseInt(wsLatency) < 500 ? 'text-yellow-400' : 'text-gray-500']">{{ wsLatency }}</span>
                     </div>

                 </div>
                 <div class="w-px h-3 bg-gray-800 mx-1"></div>
                 <div class="flex items-center gap-1.5">
                    <span class="text-gray-500">DEV:</span>
                    <span class="text-green-400 font-bold tracking-tight truncate max-w-[120px]" :title="selectedDevice">
                        {{ devices.find(d => d.udid === selectedDevice)?.device_no || devices.find(d => d.udid === selectedDevice)?.udid || 'N/A' }}
                    </span>
                 </div>
              </div>
            </div>
        </div>
        </div>

        <!-- 侧边实体按键柱 (动态缩放联动) -->
        <div class="flex flex-col gap-2.5 justify-center py-4 bg-gray-900/60 px-2 rounded-r-2xl border-y border-r border-gray-700/80 shadow-2xl backdrop-blur-md self-center relative -ml-3 pl-4 z-20 transition-transform duration-75" :style="{ transform: `scale(${deviceWin.h / 800})`, transformOrigin: 'left center' }">
             
             <!-- 新增：连接/断开 (智能红绿双态) -->
             <button @click="streamUrl ? disconnectDevice() : connectSmart()" :class="['flex flex-col items-center justify-center w-12 h-14 rounded-xl shadow-[0_2px_4px_rgba(0,0,0,0.5)] active:shadow-inner active:translate-y-[1px] transition-all font-bold border', streamUrl ? 'bg-gradient-to-b from-red-700 to-red-900 hover:from-red-600 hover:to-red-800 border-t-red-500 border-x-red-600 border-b-red-800 text-white' : 'bg-gradient-to-b from-green-600 to-green-800 hover:from-green-500 hover:to-green-700 border-t-green-400 border-x-green-500 border-b-green-700 text-white']">
               <span class="text-lg drop-shadow-md">{{ streamUrl ? '⏹' : '🔗' }}</span>
               <span class="text-[9px] mt-0.5 tracking-tighter">{{ streamUrl ? '断开' : '连接' }}</span>
             </button>

             <!-- 新增：探测 -->
             <button @click="testEcmain" class="flex flex-col items-center justify-center w-12 h-14 rounded-xl bg-gradient-to-b from-indigo-700 to-indigo-900 hover:from-indigo-600 hover:to-indigo-800 border border-t-indigo-500 border-x-indigo-600 border-b-indigo-800 shadow-[0_2px_4px_rgba(0,0,0,0.5)] active:shadow-inner active:translate-y-[1px] transition-all text-white font-bold">
               <span class="text-lg drop-shadow-md">📡</span>
               <span class="text-[9px] mt-0.5 tracking-tighter">探测</span>
             </button>

             <!-- 原本的启动EC -->
             <button @click="launchEcwda" class="flex flex-col items-center justify-center w-12 h-14 rounded-xl bg-gradient-to-b from-blue-700 to-blue-900 hover:from-blue-600 hover:to-blue-800 border border-t-blue-500 border-x-blue-600 border-b-blue-800 shadow-[0_2px_4px_rgba(0,0,0,0.5)] active:shadow-inner active:translate-y-[1px] transition-all text-white font-bold">
               <span class="text-lg drop-shadow-md">🚀</span>
               <span class="text-[9px] mt-0.5 tracking-tighter">启动EC</span>
             </button>
             <button @click="sendDeviceAction('volumeUp')" class="flex flex-col items-center justify-center w-12 h-14 rounded-xl bg-gradient-to-b from-gray-700 to-gray-800 hover:from-gray-600 hover:to-gray-700 border border-t-gray-500 border-x-gray-600 border-b-gray-800 shadow-[0_2px_4px_rgba(0,0,0,0.5)] active:shadow-inner active:translate-y-[1px] transition-all text-gray-300">
               <span class="text-xl drop-shadow-md">🔊</span>
               <span class="text-[9px] mt-0.5 font-bold tracking-tighter">音量+</span>
             </button>
             <button @click="sendDeviceAction('volumeDown')" class="flex flex-col items-center justify-center w-12 h-14 rounded-xl bg-gradient-to-b from-gray-700 to-gray-800 hover:from-gray-600 hover:to-gray-700 border border-t-gray-500 border-x-gray-600 border-b-gray-800 shadow-[0_2px_4px_rgba(0,0,0,0.5)] active:shadow-inner active:translate-y-[1px] transition-all text-gray-300">
               <span class="text-xl drop-shadow-md">🔈</span>
               <span class="text-[9px] mt-0.5 font-bold tracking-tighter">音量-</span>
             </button>
             <button @click="sendDeviceAction('home')" class="flex flex-col items-center justify-center w-12 h-14 rounded-xl bg-gradient-to-b from-gray-700 to-gray-800 hover:from-gray-600 hover:to-gray-700 border border-t-gray-500 border-x-gray-600 border-b-gray-800 shadow-[0_2px_4px_rgba(0,0,0,0.5)] active:shadow-inner active:translate-y-[1px] transition-all text-gray-300 mt-2">
               <span class="text-xl drop-shadow-md">🏠</span>
               <span class="text-[10px] mt-0.5 font-bold tracking-tighter">HOME</span>
             </button>
             <button @click="sendDeviceAction('lock')" class="flex flex-col items-center justify-center w-12 h-14 rounded-xl bg-gradient-to-b from-gray-700 to-gray-800 hover:from-gray-600 hover:to-gray-700 border border-t-gray-500 border-x-gray-600 border-b-gray-800 shadow-[0_2px_4px_rgba(0,0,0,0.5)] active:shadow-inner active:translate-y-[1px] transition-all text-gray-300 mt-2">
               <span class="text-xl drop-shadow-md">🔒</span>
               <span class="text-[10px] mt-0.5 font-bold tracking-tighter">锁屏</span>
             </button>

             <!-- 新增：群控与日志控制钩子 -->
             <div class="h-px bg-gray-800 mx-1 mt-2 mb-1"></div>
             <label class="flex flex-col items-center justify-center w-12 h-10 rounded-xl bg-gray-800 border border-gray-700 hover:bg-gray-700 transition-all cursor-pointer group">
               <input type="checkbox" v-model="isGroupControl" class="hidden" />
               <span class="text-sm shadow-md" :class="isGroupControl ? 'text-green-500' : 'text-gray-500 mb-0.5'">{{ isGroupControl ? '🟢' : '⚪️' }}</span>
               <span class="text-[9px] mt-0.5 font-bold tracking-tighter" :class="isGroupControl ? 'text-green-400' : 'text-gray-400'">群控</span>
             </label>
             <label class="flex flex-col items-center justify-center w-12 h-10 rounded-xl bg-gray-800 border border-gray-700 hover:bg-gray-700 transition-all cursor-pointer group mt-1">
               <input type="checkbox" v-model="isLogsOnlyMode" class="hidden" />
               <span class="text-sm shadow-md" :class="isLogsOnlyMode ? 'text-blue-500' : 'text-gray-500 mb-0.5'">{{ isLogsOnlyMode ? '📝' : '📺' }}</span>
               <span class="text-[9px] mt-0.5 font-bold tracking-tighter" :class="isLogsOnlyMode ? 'text-blue-400' : 'text-gray-400'">日志</span>
             </label>
        </div>

        <!-- 全域缩放齿轮手柄 -->
        <div @mousedown.stop.prevent="startWinResize" class="absolute -bottom-2 -right-2 w-7 h-7 cursor-se-resize z-50 flex items-center justify-center rounded-full bg-gray-700 hover:bg-blue-600 shadow-lg border border-gray-500 transition-colors">
           <span class="text-[12px] text-white rotate-45">↔</span>
        </div>

      </div>

      <!-- 右：三列工作流矩阵 -->
      <div class="flex flex-1 gap-4 overflow-x-auto custom-scrollbar pb-2">
        
        <!-- 列1：原语库 -->
        <div class="flex flex-col w-[260px] bg-gray-800 border border-gray-700 rounded-xl shadow-xl overflow-hidden flex-shrink-0">
           <div class="text-[11px] font-bold text-gray-300 p-3 border-b border-gray-700 bg-gray-900/80 flex items-center gap-2 tracking-widest uppercase">
              <span class="text-indigo-400">📦</span> 动作库
           </div>
           
           <div class="flex-1 overflow-y-auto p-2 text-xs bg-gray-900/30 custom-scrollbar flex flex-col gap-1">
             <div v-for="act in actionLibrary" @click="handleActionClick(act)" @dblclick="addActionToQueue(act)" class="px-2 py-1.5 text-gray-300 bg-gray-800 hover:bg-indigo-600 hover:text-white rounded cursor-pointer transition-colors border border-transparent flex items-center" :title="'双击加入队列'">
               <span class="mr-2 text-gray-500 text-[10px]">▶</span> {{ act.label }}
             </div>
           </div>

           <!-- ⬇️ 搬运过来的下截：字典 ⬇️ -->
           <div class="flex flex-col h-[220px] bg-gray-950 border-t border-gray-700 relative" v-if="selectedActionDoc">
              <div class="text-[10px] text-gray-400 p-2 font-bold tracking-widest uppercase border-b border-gray-800 flex justify-between items-center bg-gray-900/80">
                 <span class="flex items-center gap-1.5"><span class="text-blue-400">📖</span> 释义: {{ selectedActionDoc.label.replace(/\[.*?\]\s*/, '') }}</span>
                 <button @click="addActionToQueue(selectedActionDoc)" class="bg-blue-600 hover:bg-blue-500 text-white px-1.5 py-0.5 rounded shadow text-[9px] tracking-wide transition-colors">➕ 入列</button>
              </div>
              <div class="p-3 text-[11px] text-gray-300 flex flex-col gap-2 overflow-y-auto custom-scrollbar flex-1">
                 <div><span class="text-gray-500 font-bold mb-0.5 block">✨ 功能:</span> {{ selectedActionDoc.desc }}</div>
                 <div><span class="text-gray-500 font-bold mb-0.5 block">🛠 场景:</span> {{ selectedActionDoc.usage }}</div>
                 
                 <template v-if="selectedActionDoc.type === 'VPN_HYSTERIA'">
                   <div class="mt-1 p-2 bg-gray-900 border border-indigo-500/30 rounded-lg">
                      <div class="text-indigo-400 font-bold mb-1 flex justify-between items-center text-[10px]">
                        <span>🔗 节点解析池</span>
                      </div>
                      <textarea v-model="vpnInputText" class="w-full h-14 bg-black border border-gray-700 rounded p-1 text-[10px] text-green-400 font-mono focus:border-indigo-500 outline-none resize-none custom-scrollbar" placeholder="粘贴节点 URI 或订阅链"></textarea>
                      <div class="flex gap-1.5 mt-1.5">
                         <button @click="parseVpnInput" :disabled="isVpnParsing" class="flex-1 bg-indigo-600 hover:bg-indigo-500 active:bg-indigo-700 text-white py-1 rounded text-[9px] font-bold shadow transition-colors flex justify-center items-center">
                            <span v-if="isVpnParsing" class="animate-pulse">🔄 折解中..</span>
                            <span v-else>📡 智能提取</span>
                         </button>
                         <button @click="addAllVpnNodesToScript" v-if="parsedVpnNodes.length > 0" class="bg-emerald-700 hover:bg-emerald-600 text-emerald-100 border border-emerald-600 px-2 py-1 rounded text-[9px] shadow transition-colors">写入</button>
                      </div>
                      <!-- 节点展示 -->
                      <div v-if="parsedVpnNodes.length > 0" class="mt-2 flex flex-col gap-1 max-h-24 overflow-y-auto custom-scrollbar pr-1">
                         <div v-for="(node, idx) in parsedVpnNodes" :key="node.id || idx" class="bg-gray-800 border border-gray-700 p-1.5 rounded flex justify-between items-center group">
                            <div class="flex flex-col min-w-0 flex-1">
                               <span class="font-bold text-gray-200 truncate text-[10px]">{{ node.name || node.server }}</span>
                            </div>
                            <button @click="addVpnNodeToScript(node)" class="bg-emerald-600 hover:bg-emerald-500 text-white px-1.5 py-0.5 rounded shadow-sm text-[8px] tracking-wide shrink-0 transition-colors">+ 写入</button>
                         </div>
                      </div>
                   </div>
                 </template>
                 <template v-else>
                   <div><span class="text-gray-500 font-bold mb-0.5 block">🎯 参数:</span>
                      <pre class="text-[10px] text-indigo-300 font-mono bg-gray-900 p-1.5 rounded border border-gray-800 whitespace-pre-wrap">{{ selectedActionDoc.params }}</pre>
                   </div>
                 </template>
              </div>
           </div>
           <div class="flex items-center justify-center h-[160px] bg-gray-950 text-gray-600 text-[11px] font-medium tracking-wide border-t border-gray-800" v-else>
              请单击动作查阅释义
           </div>
        </div>

         <!-- 列3：黑客代码编译器面板 / 扩展功能 Tab -->
          <div class="flex flex-col flex-1 bg-gray-800 border border-gray-700 rounded-xl shadow-xl overflow-hidden relative">
            <div class="flex text-[11px] font-bold text-gray-300 border-b border-gray-700 bg-gray-900/80 tracking-widest uppercase shrink-0">
              <div @click="activeRightTab = 'code'" :class="['px-4 py-3 cursor-pointer transition-colors border-b-2', activeRightTab === 'code' ? 'text-green-400 border-green-500 bg-gray-800' : 'text-gray-500 border-transparent hover:text-gray-300']">
                <span class="mr-1">👨‍💻</span> 代码框
              </div>
              <div @click="activeRightTab = 'extensions'" :class="['px-4 py-3 cursor-pointer transition-colors border-b-2', activeRightTab === 'extensions' ? 'text-blue-400 border-blue-500 bg-gray-800' : 'text-gray-500 border-transparent hover:text-gray-300']">
                <span class="mr-1">🔧</span> 扩展功能
              </div>
              <div @click="activeRightTab = 'spoof'" :class="['px-4 py-3 cursor-pointer transition-colors border-b-2', activeRightTab === 'spoof' ? 'text-purple-400 border-purple-500 bg-gray-800' : 'text-gray-500 border-transparent hover:text-gray-300']">
                <span class="mr-1">🎭</span> 伪装信息
              </div>
            </div>
            
            <!-- Code Tab Content -->
            <div v-show="activeRightTab === 'code'" class="flex flex-col flex-1 min-h-0">
              <div class="flex-1 p-2 bg-gray-950 shadow-inner overflow-hidden">
                <textarea v-model="generatedJs" class="w-full h-full bg-transparent text-green-500 font-mono text-xs p-2 border border-gray-800 rounded focus:outline-none focus:ring-1 focus:ring-green-700 resize-none leading-relaxed custom-scrollbar" placeholder="// AST Build Output..."></textarea>
              </div>
              <div class="p-3 bg-gray-900 border-t border-gray-700 shrink-0 flex gap-2">
                <button @click="clearAllLogs()" class="w-1/4 bg-gray-800 hover:bg-red-900/50 text-gray-400 hover:text-red-400 font-bold py-2.5 text-sm rounded shadow border border-gray-700 flex justify-center items-center gap-2 tracking-wider transition-colors" title="清除主控及所有受控机日志">
                  <span>🗑️ 清空日志</span>
                </button>
                <button @click="runActions" class="flex-1 bg-green-700 hover:bg-green-600 text-white font-bold py-2.5 text-sm rounded shadow border border-green-600 flex justify-center items-center gap-2 tracking-wider transition-colors">
                  <span>▶ 执行脚本</span>
                </button>
                <button @click="clearQueue" class="bg-gray-800 hover:bg-red-900/80 text-gray-400 hover:text-red-300 font-semibold px-3 py-2 text-xs rounded shadow-sm border border-gray-700 transition-colors tracking-widest flex items-center gap-1" title="清空当前的指令序列缓冲区">
                   <span>🗑️ 轨道清空</span>
                </button>
              </div>
            </div>
            
            <!-- Extensions Tab Content -->
            <div v-show="activeRightTab === 'extensions'" class="flex flex-col flex-1 min-h-0 p-3 bg-gray-900/50 overflow-y-auto custom-scrollbar gap-4">
              
              <!-- 1. 多点取色 (Color Picker Module) -->
              <div class="flex flex-col bg-gray-800/80 border border-gray-700 shadow-md rounded-lg overflow-hidden shrink-0">
                <div class="bg-gray-700/60 px-3 py-2 text-[10px] font-bold tracking-widest text-indigo-300 border-b border-gray-700 flex justify-between items-center">
                   <span>🎨 多点阵列取色</span>
                   <span v-if="isColorPickerMode" class="text-green-400 animate-pulse flex items-center gap-1.5"><span class="w-1.5 h-1.5 rounded-full bg-green-500 block"></span>扫描激活中</span>
                </div>
                <div class="p-3 flex flex-col gap-2">
                   <div class="grid grid-cols-2 gap-2">
                     <button @click="isColorPickerMode = !isColorPickerMode" :class="['py-2 text-xs font-bold rounded flex items-center justify-center gap-1.5 transition-colors', isColorPickerMode ? 'bg-indigo-600 hover:bg-indigo-500 text-white shadow-[0_0_10px_rgba(79,70,229,0.5)]' : 'bg-gray-700 hover:bg-gray-600 text-gray-300 border border-gray-600']">
                       <span>{{ isColorPickerMode ? '🔴 停止捕获' : '🟢 开始连续取色' }}</span>
                     </button>
                     <button @click="pickedColors = []" class="py-2 text-xs text-gray-400 bg-gray-900 hover:bg-gray-700 rounded border border-gray-700 transition-colors">
                       清空色板 ({{ pickedColors.length }})
                     </button>
                   </div>
                   
                   <!-- 色值展柜 -->
                   <div class="bg-gray-950 rounded border border-gray-800 min-h-[60px] max-h-[120px] overflow-y-auto custom-scrollbar p-2 mt-1">
                      <div v-if="pickedColors.length === 0" class="text-center text-gray-600 text-[10px] my-4 uppercase tracking-wider">
                         等待点击左侧图传捕获...
                      </div>
                      <div v-else class="flex flex-wrap gap-1.5">
                         <div v-for="(color, idx) in pickedColors" :key="idx" class="flex items-center gap-1 bg-gray-800 pl-1 pr-2 py-1 rounded-sm border border-gray-700 group cursor-pointer hover:border-gray-500 transition-colors" :title="'点击复刻 ' + color.hex" @click="copyText(color.hex)">
                            <div class="w-3 h-3 rounded-full border border-gray-900 shadow-inner" :style="{ backgroundColor: color.hex }"></div>
                            <span class="text-[10px] font-mono text-gray-300 group-hover:text-white">{{ color.hex }}</span>
                            <span class="text-[8px] text-gray-500 ml-1">({{color.x}},{{color.y}})</span>
                         </div>
                      </div>
                   </div>
                   <!-- 聚合宏产出 -->
                   <div v-if="pickedColors.length > 0" class="mt-1 bg-black/40 border border-emerald-900/50 rounded p-1.5">
                       <div class="text-[9px] text-emerald-400/70 mb-0.5 flex justify-between">
                          <span>⚙️ 生成的多点找色宏</span>
                          <span class="cursor-pointer hover:text-emerald-300" @click="copyText(multiColorJS)">[点击拷列]</span>
                       </div>
                       <textarea readonly class="w-full h-[40px] text-[8px] text-emerald-300 font-mono bg-transparent border-none resize-none custom-scrollbar select-text cursor-text focus:outline-none p-0 leading-tight" :value="multiColorJS" @click="copyText(multiColorJS)" title="点击即刻复印此宏"></textarea>
                   </div>
                </div>
               </div>              
              <!-- 2. 图像裁切找图 (Crop & Image Base64) -->
              <div class="flex flex-col bg-gray-800/80 border border-gray-700 shadow-md rounded-lg overflow-hidden shrink-0">
                 <div class="bg-gray-700/60 px-3 py-2 text-[10px] font-bold tracking-widest text-pink-300 border-b border-gray-700 flex justify-between items-center">
                    <span>✂️ 自由裁切阵列 (Base64)</span>
                    <span v-if="isPickMode" class="text-pink-400 animate-pulse flex items-center gap-1.5"><span class="w-1.5 h-1.5 rounded-full bg-pink-500 block"></span>网点侦测中</span>
                 </div>
                 <div class="p-3 flex flex-col gap-2">
                    <input type="file" ref="fileInputRef" accept="image/*" class="hidden" @change="handleImageUpload" />
                    <div class="flex flex-col gap-2 relative">
                      <!-- 第一排：常规工具系 -->
                      <div class="grid grid-cols-4 gap-2">
                        <button @click="toggleDrawMode('rect')" :class="['py-2 text-[11px] font-bold rounded flex items-center justify-center transition-colors', isPickMode && !isFreeDrawMode && !isLassoMode && !isMagicWandMode ? 'bg-pink-600 hover:bg-pink-500 text-white shadow-[0_0_10px_rgba(236,72,153,0.5)]' : 'bg-gray-700 hover:bg-gray-600 text-gray-300 border border-gray-600']">
                          <span>{{ isPickMode && !isFreeDrawMode && !isLassoMode && !isMagicWandMode ? '🔴 矩形' : '🟢 矩形' }}</span>
                        </button>
                        <button @click="toggleDrawMode('free')" :class="['py-2 text-[11px] font-bold rounded flex items-center justify-center transition-colors', isFreeDrawMode ? 'bg-emerald-600 hover:bg-emerald-500 text-white shadow-[0_0_10px_rgba(16,185,129,0.5)]' : 'bg-gray-700 hover:bg-gray-600 text-gray-300 border border-gray-600']">
                          <span>{{ isFreeDrawMode ? '✏️ 画笔' : '✏️ 画笔' }}</span>
                        </button>
                        <button @click="toggleDrawMode('lasso')" :class="['py-2 text-[11px] font-bold rounded flex items-center justify-center transition-colors', isLassoMode ? 'bg-purple-600 hover:bg-purple-500 text-white shadow-[0_0_10px_rgba(147,51,234,0.5)]' : 'bg-gray-700 hover:bg-gray-600 text-gray-300 border border-gray-600']">
                          <span>{{ isLassoMode ? '📐 多边' : '📐 多边' }}</span>
                        </button>
                        <button @click="toggleDrawMode('magic')" :class="['py-2 text-[11px] font-bold rounded flex items-center justify-center transition-colors', isMagicWandMode ? 'bg-indigo-600 hover:bg-indigo-500 text-white shadow-[0_0_10px_rgba(79,70,229,0.5)]' : 'bg-gray-700 hover:bg-gray-600 text-gray-300 border border-gray-600']">
                          <span>{{ isMagicWandMode ? '✨ 魔棒' : '✨ 魔棒' }}</span>
                        </button>
                      </div>
                      <!-- 第二排：确认交互系 -->
                      <div class="grid grid-cols-4 gap-2 relative">
                        <!-- 完成确认按钮 (待命/激活) -->
                        <button @click="confirmCrop" :disabled="!pendingCrop" :class="['py-2 text-[11px] font-bold rounded flex items-center justify-center transition-all', pendingCrop ? 'bg-green-600 hover:bg-green-500 text-white shadow-[0_0_12px_rgba(22,163,74,0.8)] border border-green-500' : 'bg-gray-800 text-gray-600 border border-gray-700 cursor-not-allowed']">
                          <span>✅ 完成确认</span>
                        </button>
                        <!-- 取消按钮 (待命/激活) -->
                        <button @click="cancelCrop" :disabled="!pendingCrop" :class="['py-2 text-[11px] font-bold rounded flex items-center justify-center transition-all', pendingCrop ? 'bg-red-600 hover:bg-red-500 text-white shadow-[0_0_8px_rgba(220,38,38,0.6)] border border-red-500' : 'bg-gray-800 text-gray-600 border border-gray-700 cursor-not-allowed']">
                          <span>❌ 取消</span>
                        </button>
                        
                        <!-- 常驻功能 -->
                        <button @click="pickedImages = []" class="py-2 text-[11px] text-gray-400 bg-gray-900 hover:bg-gray-700 rounded border border-gray-700 transition-colors">
                          清空 ({{ pickedImages.length }})
                        </button>
                        <button @click="triggerImageUpload" class="py-2 text-[11px] font-bold text-gray-300 bg-gray-700 hover:bg-gray-600 rounded flex items-center justify-center border border-gray-600 transition-colors shadow-sm" title="从本地上传图片">
                          <span>📤 上传</span>
                        </button>
                      </div>
                    </div>
                    
                    <!-- 大型图钉与缓冲区视窗 -->
                    <div class="bg-gray-950 rounded border border-gray-800 min-h-[160px] max-h-[300px] overflow-y-auto custom-scrollbar p-2 mt-1 flex flex-col gap-2 relative">
                       <!-- 暂存等待验收的切片 -->
                       <div v-if="pendingCrop" class="border-[1.5px] border-dashed border-green-500/60 bg-green-900/10 rounded overflow-hidden flex flex-col items-center justify-center p-3 w-full shadow-[inset_0_0_20px_rgba(34,197,94,0.15)]">
                          <div class="flex justify-between w-full items-center mb-2 px-1">
                             <span class="text-[10px] text-green-400/80 font-bold tracking-widest">- 待收纳的提取截面 -</span>
                             <!-- 橡皮擦控制条 -->
                             <div class="flex items-center gap-1.5">
                                <button @click="isEraserMode = !isEraserMode" :class="['p-1 rounded text-[10px] flex items-center gap-1 transition-colors', isEraserMode ? 'bg-indigo-600 text-white shadow-sm' : 'bg-gray-800 text-gray-400 hover:text-gray-200 border border-gray-700']" title="开启橡皮擦后，可以在截面上涂抹擦除不平整的边缘或背景。">
                                   <span>🧽 橡皮擦</span>
                                </button>
                                <div v-if="isEraserMode" class="flex items-center gap-1.5">
                                   <span class="text-[9px] text-gray-500 scale-90">粗细:</span>
                                   <input type="range" v-model.number="eraserBrushSize" min="2" max="40" class="w-12 h-1 bg-gray-700 rounded-lg appearance-none cursor-pointer" />
                                   <span class="text-[9px] text-gray-400 w-3 text-center">{{eraserBrushSize}}</span>
                                   
                                   <!-- 撤销操作 -->
                                   <button @click="undoEraser" :disabled="eraserHistory.length === 0" :class="['p-1 px-1.5 rounded text-[9px] border flex items-center gap-0.5 transition-colors', eraserHistory.length > 0 ? 'bg-gray-800 border-gray-600 text-yellow-500 hover:bg-gray-700 hover:text-yellow-400' : 'bg-gray-900/40 border-gray-800/50 text-gray-600 cursor-not-allowed']" title="点击回退上一次橡皮擦涂抹">
                                      <span>↩️ 撤销</span>
                                   </button>
                                </div>
                             </div>
                          </div>

                          <!-- 图片 / 画布 渲染区 -->
                          <div class="relative flex justify-center items-center rounded overflow-hidden">
                             <!-- 增加透明棋盘格底纹以便让透明镂空可见 -->
                             <div class="absolute inset-0 z-0 bg-neutral-900" style="background-image: conic-gradient(#262626 25%, #171717 0 50%, #262626 0 75%, #171717 0); background-size: 12px 12px;"></div>
                             
                             <img v-if="!isEraserMode" :src="'data:image/png;base64,' + pendingCrop.b64" class="max-w-[150px] max-h-[150px] object-contain border border-gray-700 shadow-xl relative z-10" />
                             <canvas v-else ref="eraserCanvasRef" @mousedown="startErase" @mousemove="handleErase" @mouseup="endErase" @mouseleave="endErase" :style="{ cursor: eraserCursor }" class="max-w-[150px] max-h-[150px] object-contain border border-indigo-500/50 shadow-xl relative z-10"></canvas>
                          </div>

                          <span class="text-[9px] text-gray-500 mt-2 font-mono">Size: {{pendingCrop.w}}x{{pendingCrop.h}}</span>
                       </div>
                    
                       <!-- 无数据打底词 -->
                       <div v-if="pickedImages.length === 0 && !pendingCrop" class="text-center text-gray-600 text-[10px] my-10 uppercase tracking-widest">
                          在左图触发采集矩阵...
                       </div>
                       
                       <!-- 已归集的历史切片清单 -->
                       <div v-if="pickedImages.length > 0" class="flex flex-col gap-1.5 mt-1">
                          <div v-for="(img, idx) in pickedImages" :key="idx" class="flex items-center gap-2.5 bg-gray-800/80 p-2 rounded-md border border-gray-700 hover:border-gray-500 group transition-all">
                             <img :src="'data:image/png;base64,' + img.b64" class="w-[42px] h-[42px] object-contain border border-gray-900 shadow-sm bg-black/50 p-0.5" />
                             <div class="flex-1 overflow-hidden">
                                <div class="text-[9.5px] text-gray-400 mb-1 truncate flex justify-between font-mono">
                                  <span>[R]: {{img.w}}x{{img.h}}</span>
                                  <span class="text-gray-500 scale-90">base64</span>
                                </div>
                                <textarea readonly class="w-full h-[30px] text-[8px] text-pink-500 font-mono bg-black/40 border border-gray-700/50 rounded resize-none custom-scrollbar select-text cursor-text focus:outline-none focus:border-pink-500/50 p-1 leading-tight" :value="img.b64" @click="copyText(img.b64)" title="点击拷取通配符"></textarea>
                             </div>
                             <button @click="pickedImages.splice(idx, 1)" class="w-5 h-5 rounded-full bg-red-900/40 text-red-500 hover:bg-red-800 hover:text-white flex items-center justify-center shrink-0 border border-red-900/60 transition-colors text-xs" title="销毁图钉">✖</button>
                          </div>
                       </div>
                    </div>
                 </div>
              </div>
              
              <!-- 3. 文字雷达寻标器 (Find Text) -->
              <div class="flex flex-col bg-gray-800/80 border border-gray-700 shadow-md rounded-lg overflow-hidden shrink-0 mt-4">
                 <div class="bg-gray-700/60 px-3 py-2 text-[10px] font-bold tracking-widest text-emerald-300 border-b border-gray-700">
                    🔤 文字坐标穿透雷达 (Find Text)
                 </div>
                 <div class="p-3 flex flex-col gap-3">
                    <div class="flex flex-col gap-1">
                      <label class="text-[10px] text-gray-400">输入需要靶向瞄准的文本</label>
                      <input v-model="ocrTextInput" @keyup.enter="runFindText" type="text" placeholder="例如: 确定 / 取消" class="w-full bg-gray-950 border border-gray-600 rounded px-2 py-1.5 text-[11px] text-emerald-200 outline-none focus:border-emerald-500 font-mono transition-colors" />
                    </div>
                    <button @click="runFindText" class="w-full py-2 bg-emerald-700 hover:bg-emerald-600 active:bg-emerald-800 text-white text-xs font-bold rounded shadow-md border border-emerald-500 transition-colors flex justify-center items-center gap-2" :disabled="isOcrRunning">
                       <span v-if="!isOcrRunning">🎯 锁定并获取场域坐标</span>
                       <span v-else class="flex items-center gap-2"><svg class="animate-spin h-4 w-4 text-white" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path></svg>光波逆变捕捉中...</span>
                    </button>
                    <!-- 结果展示窗 -->
                    <div class="bg-gray-950 rounded border border-gray-800 min-h-[60px] max-h-[150px] overflow-y-auto custom-scrollbar p-2 mt-1 select-text cursor-text">
                       <div v-if="!ocrResult" class="text-center text-gray-600 text-[10px] my-4 uppercase tracking-wider">
                          待命接收 WDA 脱壳坐标矩阵...
                       </div>
                       <div v-else class="text-[9px] font-mono text-emerald-400 break-all whitespace-pre-wrap leading-tight">
                          {{ JSON.stringify(ocrResult, null, 2) }}
                       </div>
                    </div>
                 </div>
              </div>

              <!-- 4. APP 起搏器 (App Lifecycle) -->
              <div class="flex flex-col bg-gray-800/80 border border-gray-700 shadow-md rounded-lg overflow-hidden shrink-0 mt-4 mb-2">
                 <div class="bg-gray-700/60 px-3 py-2 text-[10px] font-bold tracking-widest text-amber-400 border-b border-gray-700">
                    💀 深渊进程刺客 (Launch & Terminate)
                 </div>
                 <div class="p-3 flex flex-col gap-3">
                    <div class="flex flex-col gap-1">
                      <label class="text-[10px] text-gray-400">Bundle Identifier (身份码)</label>
                      <input v-model="bundleIdInput" type="text" placeholder="com.apple.mobilesafari" class="w-full bg-gray-950 border border-gray-600 rounded px-2 py-1.5 text-[11px] text-amber-200 outline-none focus:border-amber-500 font-mono transition-colors" />
                    </div>
                    <div class="grid grid-cols-2 gap-2">
                      <button @click="manageApp('launch')" class="py-2 bg-gradient-to-br from-amber-600 to-amber-800 hover:from-amber-500 hover:to-amber-700 border border-amber-500 text-white text-xs font-bold rounded shadow transition-all active:scale-[0.98]">
                        🚀 执行起飞拉升
                      </button>
                      <button @click="manageApp('terminate')" class="py-2 bg-gradient-to-br from-red-700 to-red-900 hover:from-red-600 hover:to-red-800 border border-red-600 text-white text-xs font-bold rounded shadow transition-all active:scale-[0.98]">
                        🪦 处决进程生命
                      </button>
                    </div>
                 </div>
              </div>
              <!-- 5. Base64 助手 (Encode & Decode & Image Preview) -->
              <div class="flex flex-col bg-gray-800/80 border border-gray-700 shadow-md rounded-lg overflow-hidden shrink-0 mt-4 mb-2">
                 <div class="bg-gray-700/60 px-3 py-2 text-[10px] font-bold tracking-widest text-sky-400 border-b border-gray-700 flex justify-between items-center">
                    <span>🔣 Base64 万能编解码器与视图探针</span>
                 </div>
                 <div class="p-3 flex flex-col gap-3">
                    <textarea v-model="base64Input" placeholder="在此粘贴 Base64 密串或需编码的明文文本（支持截获图传视图鉴赏）..." class="w-full h-[80px] bg-gray-950 border border-gray-600 rounded px-2 py-2 text-[10px] text-sky-200 outline-none focus:border-sky-500 font-mono resize-none custom-scrollbar transition-colors leading-relaxed"></textarea>
                    
                    <div class="grid grid-cols-4 gap-2">
                      <button @click="encodeBase64" class="py-2 bg-gray-700 hover:bg-gray-600 border border-gray-600 text-gray-300 text-xs font-bold rounded shadow transition-all active:scale-[0.98]">
                        明文转 B64
                      </button>
                      <button @click="decodeBase64" class="py-2 bg-gray-700 hover:bg-gray-600 border border-gray-600 text-gray-300 text-xs font-bold rounded shadow transition-all active:scale-[0.98]">
                        B64 解明文
                      </button>
                      <button @click="previewBase64" class="py-2 bg-sky-700 hover:bg-sky-600 border border-sky-500 text-white text-xs font-bold rounded shadow transition-all active:scale-[0.98] col-span-1">
                        渲染为图片
                      </button>
                      <button @click="copyBase64Result" class="py-2 bg-emerald-700 hover:bg-emerald-600 border border-emerald-500 text-white text-[11px] font-bold rounded shadow transition-all active:scale-[0.98]">
                        拷走结果
                      </button>
                    </div>

                    <div v-if="base64ImagePreview" class="bg-gray-950 rounded border border-gray-800 min-h-[60px] p-2 mt-1 flex justify-center items-center relative group">
                        <button @click="base64ImagePreview = ''" class="absolute top-1 right-1 w-5 h-5 rounded bg-red-900/60 text-red-400 hover:bg-red-800 hover:text-white flex items-center justify-center border border-red-900 shadow transition-colors text-xs hidden group-hover:flex" title="关闭预览">✖</button>
                        <img :src="base64ImagePreview" class="max-w-full max-h-[220px] object-contain border border-gray-700 shadow-xl bg-black/60 rounded" />
                    </div>
                 </div>
              </div>
            </div>

            <!-- Spoof Tab Content (伪装信息生成器) -->
            <div v-show="activeRightTab === 'spoof'" class="flex flex-col flex-1 min-h-0 p-3 bg-gray-900/50 overflow-y-auto custom-scrollbar gap-3">

              <!-- 基础参数 -->
              <div class="flex flex-col bg-gray-800/80 border border-gray-700 shadow-md rounded-lg overflow-hidden shrink-0">
                <div class="bg-gray-700/60 px-3 py-2 text-[10px] font-bold tracking-widest text-purple-300 border-b border-gray-700">
                  📦 安装基础参数
                </div>
                <div class="p-3 flex flex-col gap-2.5">
                  <div class="flex flex-col gap-1">
                    <label class="text-[10px] text-gray-400">IPA 文件名（模糊匹配）</label>
                    <input v-model="spoofForm.filename" type="text" placeholder="如: TikTok / Calculator" class="w-full bg-gray-950 border border-gray-600 rounded px-2 py-1.5 text-[11px] text-purple-200 outline-none focus:border-purple-500 font-mono transition-colors" />
                  </div>
                  <div class="flex flex-col gap-1">
                    <label class="text-[10px] text-gray-400">克隆编号（0 = 原包，1/2/8 = 分身）</label>
                    <input v-model="spoofForm.cloneNumber" type="text" placeholder="1" class="w-full bg-gray-950 border border-gray-600 rounded px-2 py-1.5 text-[11px] text-purple-200 outline-none focus:border-purple-500 font-mono transition-colors" />
                  </div>
                </div>
              </div>

              <!-- 设备型号选择 -->
              <div class="flex flex-col bg-gray-800/80 border border-gray-700 shadow-md rounded-lg overflow-hidden shrink-0">
                <div class="bg-gray-700/60 px-3 py-2 text-[10px] font-bold tracking-widest text-cyan-300 border-b border-gray-700">
                  📱 设备型号
                </div>
                <div class="p-3 flex flex-col gap-2.5">
                  <div class="flex flex-col gap-1">
                    <label class="text-[10px] text-gray-400">选择机型（自动填充屏幕参数）</label>
                    <select v-model="spoofForm.selectedDevice" class="w-full bg-gray-950 border border-gray-600 rounded px-2 py-1.5 text-[11px] text-cyan-200 outline-none focus:border-cyan-500 font-mono transition-colors">
                      <option v-for="(info, model) in devicePresets" :key="model" :value="model">{{ model }} - {{ info.name }}</option>
                    </select>
                  </div>
                  <div class="flex flex-col gap-1">
                    <label class="text-[10px] text-gray-400">设备名称（用户自定义名）</label>
                    <input v-model="spoofForm.deviceName" type="text" placeholder="iPhone" class="w-full bg-gray-950 border border-gray-600 rounded px-2 py-1.5 text-[11px] text-cyan-200 outline-none focus:border-cyan-500 font-mono transition-colors" />
                  </div>
                  <!-- 自动填充预览 -->
                  <div v-if="devicePresets[spoofForm.selectedDevice]" class="bg-gray-950 rounded border border-gray-800 p-2 grid grid-cols-3 gap-1.5 text-[9px] font-mono text-gray-500">
                    <span>宽:{{ devicePresets[spoofForm.selectedDevice]?.screenWidth }}</span>
                    <span>高:{{ devicePresets[spoofForm.selectedDevice]?.screenHeight }}</span>
                    <span>缩放:{{ devicePresets[spoofForm.selectedDevice]?.screenScale }}</span>
                    <span>分辨率:{{ devicePresets[spoofForm.selectedDevice]?.nativeBounds }}</span>
                    <span>刷新率:{{ devicePresets[spoofForm.selectedDevice]?.maxFPS }}Hz</span>
                  </div>
                </div>
              </div>

              <!-- 国家/地区选择 -->
              <div class="flex flex-col bg-gray-800/80 border border-gray-700 shadow-md rounded-lg overflow-hidden shrink-0">
                <div class="bg-gray-700/60 px-3 py-2 text-[10px] font-bold tracking-widest text-amber-300 border-b border-gray-700">
                  🌍 国家/地区（自动填充运营商/区域/语言）
                </div>
                <div class="p-3 flex flex-col gap-2.5">
                  <select v-model="spoofForm.selectedCountry" class="w-full bg-gray-950 border border-gray-600 rounded px-2 py-1.5 text-[11px] text-amber-200 outline-none focus:border-amber-500 font-mono transition-colors">
                    <option v-for="(info, code) in countryPresets" :key="code" :value="code">{{ code }} - {{ info.name }}</option>
                  </select>
                  <!-- 自动填充预览 -->
                  <div v-if="countryPresets[spoofForm.selectedCountry]" class="bg-gray-950 rounded border border-gray-800 p-2 flex flex-col gap-1 text-[9px] font-mono text-gray-500">
                    <div class="grid grid-cols-2 gap-1">
                      <span>运营商: {{ countryPresets[spoofForm.selectedCountry]?.carrier }}</span>
                      <span>MCC/MNC: {{ countryPresets[spoofForm.selectedCountry]?.mcc }}/{{ countryPresets[spoofForm.selectedCountry]?.mnc }}</span>
                    </div>
                    <div class="grid grid-cols-2 gap-1">
                      <span>时区: {{ countryPresets[spoofForm.selectedCountry]?.timezone }}</span>
                      <span>货币: {{ countryPresets[spoofForm.selectedCountry]?.currency }}</span>
                    </div>
                    <div class="grid grid-cols-2 gap-1">
                      <span>语言: {{ derivedLangParams.languageCode }}</span>
                      <span>区域: {{ derivedLangParams.localeIdentifier }}</span>
                    </div>
                  </div>
                </div>
              </div>

              <!-- 系统版本选择 -->
              <div class="flex flex-col bg-gray-800/80 border border-gray-700 shadow-md rounded-lg overflow-hidden shrink-0">
                <div class="bg-gray-700/60 px-3 py-2 text-[10px] font-bold tracking-widest text-green-300 border-b border-gray-700">
                  ⚙️ 系统版本
                </div>
                <div class="p-3 flex flex-col gap-2.5">
                  <select v-model="spoofForm.selectedSystemVersion" class="w-full bg-gray-950 border border-gray-600 rounded px-2 py-1.5 text-[11px] text-green-200 outline-none focus:border-green-500 font-mono transition-colors">
                    <option v-for="(info, ver) in systemVersionPresets" :key="ver" :value="ver">iOS {{ ver }} ({{ info.buildVersion }})</option>
                  </select>
                </div>
              </div>

              <!-- 网络拦截开关 -->
              <div class="flex flex-col bg-gray-800/80 border border-gray-700 shadow-md rounded-lg overflow-hidden shrink-0">
                <div class="bg-gray-700/60 px-3 py-2 text-[10px] font-bold tracking-widest text-red-300 border-b border-gray-700">
                  🛡️ 网络拦截
                </div>
                <div class="p-3 flex flex-col gap-2">
                  <label class="flex items-center gap-2 cursor-pointer">
                    <input type="checkbox" v-model="spoofForm.enableNetworkInterception" class="accent-red-500" />
                    <span class="text-[11px] text-gray-300">网络拦截总开关</span>
                  </label>
                  <label class="flex items-center gap-2 cursor-pointer">
                    <input type="checkbox" v-model="spoofForm.disableQUIC" class="accent-red-500" />
                    <span class="text-[11px] text-gray-300">禁用 QUIC/UDP</span>
                  </label>
                </div>
              </div>

              <!-- 生成代码按钮 -->
              <div class="flex gap-2 shrink-0">
                <button @click="generateSpoofCode(false)" class="flex-1 py-3 bg-gradient-to-r from-purple-600 to-indigo-600 hover:from-purple-500 hover:to-indigo-500 text-white text-xs font-bold rounded-lg shadow-lg border border-purple-500 transition-all active:scale-[0.98] flex justify-center items-center gap-1.5 tracking-wider">
                  <span>🚀 生成完整伪装</span>
                </button>
                <button @click="generateSpoofCode(true)" class="flex-1 py-3 bg-gray-800 hover:bg-gray-700 text-gray-200 text-xs font-bold rounded-lg shadow-lg border border-gray-700 transition-all active:scale-[0.98] flex justify-center items-center gap-1.5 tracking-wider">
                  <span>🛡️ 仅伪装克隆</span>
                </button>
              </div>

            </div>
            
            <!-- Logs section, always visible -->
            <div class="shrink-0 flex flex-col gap-1.5 bg-black p-3 rounded-none border-t border-gray-800 shadow-inner h-[180px] overflow-y-auto custom-scrollbar select-text cursor-text">
               <div v-if="logs.length === 0" class="text-[11px] text-gray-600 font-mono select-none">等待终端输出...</div>
               <div class="flex flex-col gap-1">
                  <div v-for="(log, idx) in logs.slice(-40)" :key="idx" class="text-[11px] text-gray-400 font-mono leading-loose break-all">
                    <span v-if="log.startsWith('[APP]')" class="text-blue-400">⚡️ {{ log }}</span>
                    <span v-else-if="log.startsWith('[WDA]')" class="text-indigo-400">📱 {{ log }}</span>
                    <span v-else-if="log.startsWith('[EC]')" class="text-cyan-400">🔗 {{ log }}</span>
                    <span v-else-if="log.includes('Failed') || log.includes('error')" class="text-red-500">❌ {{ log }}</span>
                    <span v-else-if="log.includes('success') || log.includes('就绪')" class="text-green-500">✓ {{ log }}</span>
                    <span v-else>→ {{ log }}</span>
                  </div>
               </div>
            </div>
          </div> <!-- End Column 3 (3587) -->

          <!-- [右三列]: 从属受控方矩阵 (原底部矩阵) -->
          <div v-if="batchDevices.filter(d => d.udid !== selectedDevice).length > 0" class="flex flex-col w-[580px] bg-gray-800 border border-gray-700 rounded-xl shadow-xl overflow-hidden shrink-0">
             <div class="px-4 py-3 bg-gray-900/80 border-b border-gray-700 flex items-center justify-between shrink-0">
                <h3 class="text-[11px] font-bold text-gray-300 flex items-center gap-2 tracking-widest uppercase">
                    <span class="text-indigo-400">🤖</span> 从属矩阵
                    <span v-if="isGroupControl" class="ml-2 text-[9px] text-green-400 border border-green-500/20 bg-green-900/10 px-1.5 py-0.5 rounded">群控同步</span>
                </h3>
                <div class="flex items-center gap-1.5">
                    <select v-model="slaveQuality" @change="onSlaveQualityChange()" class="bg-gray-800 text-gray-400 border border-gray-700 rounded px-1.5 py-1 text-[10px] font-bold outline-none focus:border-indigo-500 cursor-pointer h-[26px]">
                       <option value="low">🌫️ 模糊</option>
                       <option value="medium">📺 普通</option>
                       <option value="high">🔬 高清</option>
                    </select>
                    <button @click="batchConnectAll" class="bg-indigo-600/30 hover:bg-indigo-500/60 text-indigo-300 px-2 py-1 rounded text-[10px] font-bold border border-indigo-500/30 transition-all active:scale-95" title="一键串流">💫</button>
                    <button @click="batchDisconnectAll" class="bg-gray-800 hover:bg-red-900/50 text-gray-400 hover:text-red-400 px-2 py-1 rounded text-[10px] font-bold border border-gray-700 transition-all active:scale-95" title="断流回路">⏹</button>
                </div>
             </div>
             
             <div class="flex-1 overflow-y-auto p-3 custom-scrollbar bg-gray-950/20">
                 <div class="flex flex-wrap gap-4 justify-center">
                     <div v-for="dev in batchDevices.filter(d => d.udid !== selectedDevice)" :key="dev.udid" 
                          class="w-40 bg-gray-900/60 border border-gray-800 rounded-lg overflow-hidden flex flex-col shadow-lg transition-all hover:border-gray-600 group">
                          <!-- 节点头部 -->
                          <div class="px-2 py-1.5 bg-black/60 border-b border-gray-800 flex items-center justify-between">
                              <div class="flex items-center gap-1.5 min-w-0">
                                  <span :class="['w-1.5 h-1.5 rounded-full shrink-0 shadow-[0_0_2px_currentColor]', dev.status === 'online' ? 'bg-green-500 text-green-500' : 'bg-gray-600 text-transparent']"></span>
                                  <span class="text-[10px] font-bold text-gray-300 tracking-wider truncate" :title="dev.udid">{{ dev.device_no || dev.udid.substring(0,6) }}</span>
                              </div>
                          </div>
 
                          <!-- 内容视窗 -->
                          <div class="aspect-[9/16] bg-black relative flex flex-col overflow-hidden">
                              <template v-if="!isLogsOnlyMode">
                                  <img v-if="batchImageData[dev.udid]" :src="'data:image/jpeg;base64,' + batchImageData[dev.udid]" class="w-full h-full object-contain pointer-events-none" crossorigin="anonymous" />
                                  <div v-else-if="batchSockets[dev.udid]" class="w-full h-full flex flex-col items-center justify-center gap-2 bg-gray-950/40">
                                      <div class="w-4 h-4 border-2 border-indigo-500/30 border-t-indigo-500 rounded-full animate-spin"></div>
                                      <span class="text-[9px] text-indigo-400/60 uppercase tracking-tighter">WS Linking...</span>
                                  </div>
                                  <img v-else-if="batchStreams[dev.udid]" :src="batchStreams[dev.udid]" class="w-full h-full object-contain pointer-events-none opacity-40 grayscale" crossorigin="anonymous" />
                                  <div v-else class="flex-1 flex flex-col items-center justify-center gap-2 opacity-30 select-none">
                                      <span class="text-3xl text-gray-600">📴</span>
                                      <button @click="batchConnect(dev)" class="bg-gray-800 text-gray-400 border border-gray-700 hover:bg-indigo-900/50 hover:text-indigo-300 hover:border-indigo-500 px-2 py-1 rounded text-[9px] transition-colors mt-2">唤醒视频流</button>
                                  </div>
                              </template>
                              <template v-else>
                                  <div class="flex-1 p-2 bg-black overflow-y-auto custom-scrollbar flex flex-col gap-1 select-text cursor-text scroll-smooth" id="clone-logs-container">
                                      <div v-for="(log, lidx) in (batchLogs[dev.udid] || []).slice(-100)" :key="lidx" 
                                           class="text-[9px] text-gray-400 font-mono leading-tight break-all border-l border-indigo-500/20 pl-1 py-0.5 hover:bg-white/5 transition-colors">
                                         {{ log }}
                                      </div>
                                      <!-- 自动锚点：用于保持日志底部显示 -->
                                      <div class="h-0 w-0"></div>
                                  </div>
                              </template>
                          </div>
                     </div>
                 </div>
             </div>
          </div>

        </div> <!-- End Columns Wrapper (3526) -->
      </div> <!-- End Upper Section (3385) -->


    </div> <!-- End Console Tab Root (3382) -->
    <div v-if="activeTab === '⚙️ 配置中心'" class="flex flex-1 flex-col overflow-auto p-6 bg-[#0B0F19]">
        <div class="max-w-6xl mx-auto w-full">
            <h2 class="text-2xl font-semibold text-gray-100 flex items-center mb-8">
               <span class="mr-2">⚙️</span>全局字典与预设配置管理中心
            </h2>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
                <!-- 国家配置 -->
                <div class="bg-gray-800 border border-gray-700 rounded-xl overflow-hidden shadow-lg flex flex-col h-[500px]">
                    <div class="p-6 border-b border-gray-700 bg-gray-800/80">
                         <h3 class="text-xl font-semibold text-gray-100 flex items-center">🌍 国家配置项 (覆盖全网过滤)</h3>
                         <div class="flex gap-2 mt-4">
                             <input v-model="newCountryName" @keyup.enter="addCountry()" type="text" placeholder="输入要新增的国家 (如: US)" class="flex-1 bg-gray-950 border border-gray-700 rounded px-3 py-2 text-gray-200 outline-none focus:border-blue-500 transition-colors">
                             <button @click="addCountry()" class="bg-blue-600 hover:bg-blue-500 text-white px-5 py-2 rounded font-medium transition-colors shadow-md">入库写入</button>
                         </div>
                    </div>
                    <div class="flex-1 p-6 overflow-y-auto custom-scrollbar flex flex-col gap-2">
                        <div v-for="c in countries" :key="c.id" class="flex justify-between items-center bg-gray-900 border border-gray-750 p-3 rounded group hover:border-gray-600 transition-colors">
                            <span class="text-gray-300 font-medium pl-2">{{ c.name }}</span>
                            <button @click="deleteCountry(c.id)" class="text-red-500 hover:text-white px-3 py-1 bg-red-500/10 hover:bg-red-500 rounded text-xs transition-colors">抹除</button>
                        </div>
                        <div v-if="countries.length === 0" class="text-center text-gray-500 mt-10">词典枯竭，还没有任何国家配置。</div>
                    </div>
                </div>

                <!-- 分组配置 -->
                <div class="bg-gray-800 border border-gray-700 rounded-xl overflow-hidden shadow-lg flex flex-col h-[500px]">
                    <div class="p-6 border-b border-gray-700 bg-gray-800/80">
                         <h3 class="text-xl font-semibold text-gray-100 flex items-center">🏷️ 自动化管理群组配置字典</h3>
                         <div class="flex gap-2 mt-4">
                             <input v-model="newGroupName" @keyup.enter="addGroup()" type="text" placeholder="输入分批管控的集群组名" class="flex-1 bg-gray-950 border border-gray-700 rounded px-3 py-2 text-gray-200 outline-none focus:border-blue-500 transition-colors">
                             <button @click="addGroup()" class="bg-indigo-600 hover:bg-indigo-500 text-white px-5 py-2 rounded font-medium transition-colors shadow-md">入库写入</button>
                         </div>
                    </div>
                    <div class="flex-1 p-6 overflow-y-auto custom-scrollbar flex flex-col gap-2">
                        <div v-for="g in groups" :key="g.id" class="flex justify-between items-center bg-gray-900 border border-gray-750 p-3 rounded group hover:border-gray-600 transition-colors">
                            <span class="text-gray-300 font-medium pl-2">{{ g.name }}</span>
                            <button @click="deleteGroup(g.id)" class="text-red-500 hover:text-white px-3 py-1 bg-red-500/10 hover:bg-red-500 rounded text-xs transition-colors">抹除</button>
                        </div>
                        <div v-if="groups.length === 0" class="text-center text-gray-500 mt-10">词典枯竭，查不到任何群组名。</div>
                    </div>
                </div>
                
                <!-- 执行时间配置 -->
                <div class="bg-gray-800 border border-gray-700 rounded-xl overflow-hidden shadow-lg flex flex-col h-[500px]">
                    <div class="p-6 border-b border-gray-700 bg-gray-800/80">
                         <h3 class="text-xl font-semibold text-gray-100 flex items-center">⏱️ 执行时间分组字典</h3>
                         <div class="flex gap-2 mt-4">
                             <input v-model="newExecTimeName" @keyup.enter="addExecTime()" type="text" placeholder="输入0-23区间代表时辰" class="flex-1 bg-gray-950 border border-gray-700 rounded px-3 py-2 text-gray-200 outline-none focus:border-blue-500 transition-colors">
                             <button @click="addExecTime()" class="bg-emerald-600 hover:bg-emerald-500 text-white px-5 py-2 rounded font-medium transition-colors shadow-md">入库写入</button>
                         </div>
                    </div>
                    <div class="flex-1 p-6 overflow-y-auto custom-scrollbar flex flex-col gap-2">
                        <div v-for="t in execTimes" :key="t.id" class="flex justify-between items-center bg-gray-900 border border-gray-750 p-3 rounded group hover:border-gray-600 transition-colors">
                            <span class="text-gray-300 font-medium pl-2">{{ t.name }} 点整</span>
                            <button @click="deleteExecTime(t.id)" class="text-red-500 hover:text-white px-3 py-1 bg-red-500/10 hover:bg-red-500 rounded text-xs transition-colors">抹除</button>
                        </div>
                        <div v-if="execTimes.length === 0" class="text-center text-gray-500 mt-10">词典枯竭，查不到任何时间配额。</div>
                    </div>
                </div>
            </div>
        </div>
    </div>
    
    <!-- 单机独立运行环境配置 (静态网络/穿透节点) Modal -->
    <div v-if="showConfigModal" class="fixed inset-0 bg-black/80 backdrop-blur-sm z-[999] flex items-center justify-center p-4">
      <div class="bg-gray-900 border border-gray-700 rounded-xl shadow-2xl w-[600px] max-w-full overflow-hidden flex flex-col">
          <div class="bg-gray-800 p-4 border-b border-gray-700 flex justify-between items-center">
            <h3 class="text-gray-100 font-bold tracking-widest flex items-center gap-2">
              <span class="text-teal-400">⚙️</span> 网络拓扑参数重构
            </h3>
            <span class="text-xs text-gray-500 font-mono">{{ configEditingUdid }}</span>
            <span v-if="configEditingAdmin" class="text-xs bg-purple-900/30 text-purple-400 border border-purple-800 px-2 py-0.5 rounded font-bold">👤 {{ configEditingAdmin }}</span>
          </div>
          <div class="p-6 flex flex-col gap-5 overflow-y-auto max-h-[70vh] custom-scrollbar">
              
              <!-- 高级业务管理组 -->
              <div>
                  <label class="block text-gray-400 text-xs font-bold mb-3 uppercase tracking-wider">业务属性绑定</label>
                  <div class="grid grid-cols-2 gap-4">
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">自定义设备编号</label>
                          <input v-model="configForm.device_no" type="text" placeholder="作为独立追踪标识" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                      </div>
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">指派国家 (选自字典)</label>
                          <select v-model="configForm.country" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                            <option value="">(空值)</option>
                            <option v-for="c in countries" :key="c.id" :value="c.name">{{ c.name }}</option>
                          </select>
                      </div>
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">指派分组 (选自字典)</label>
                          <select v-model="configForm.group_name" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                            <option value="">(空值)</option>
                            <option v-for="g in groups" :key="g.id" :value="g.name">{{ g.name }}</option>
                          </select>
                      </div>
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">指派定时启动 (字典维护)</label>
                          <select v-model="configForm.exec_time" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                            <option value="">(空值/全天候)</option>
                            <option v-for="t in execTimes" :key="t.id" :value="t.name">{{ t.name }} 点整</option>
                          </select>
                      </div>
                  </div>
              </div>
              
              <!-- Apple 账号管理 -->
              <div>
                  <label class="block text-gray-400 text-xs font-bold mb-3 uppercase tracking-wider">🍎 Apple 账号</label>
                  <div class="grid grid-cols-2 gap-4">
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">Apple ID (邮箱/手机号)</label>
                          <input v-model="configForm.apple_account" type="text" placeholder="example@icloud.com" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                      </div>
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">密码 (明文)</label>
                          <input v-model="configForm.apple_password" type="text" placeholder="明文密码" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                      </div>
                  </div>
              </div>

              <!-- Wi-Fi 配置 -->
              <div>
                  <label class="block text-gray-400 text-xs font-bold mb-3 uppercase tracking-wider">📶 Wi-Fi 配置</label>
                  <div class="grid grid-cols-2 gap-4">
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">Wi-Fi 名称 (SSID)</label>
                          <input v-model="configForm.wifi_ssid" type="text" placeholder="网络名称" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                      </div>
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">Wi-Fi 密码 (明文)</label>
                          <input v-model="configForm.wifi_password" type="text" placeholder="8位以上或留空" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                      </div>
                  </div>
              </div>

              <!-- TikTok 多账号管理 -->
              <div>
                  <div class="flex justify-between items-center mb-3">
                      <label class="block text-gray-400 text-xs font-bold uppercase tracking-wider">🎵 TikTok 账号列表</label>
                      <button @click="configForm.tiktok_accounts.push({email:'', account:'', password:''})" class="text-xs bg-indigo-700 hover:bg-indigo-600 text-white px-3 py-1 rounded transition-colors">+ 添加账号</button>
                  </div>
                  <div v-if="configForm.tiktok_accounts.length === 0" class="text-center text-gray-600 text-xs py-4 border border-dashed border-gray-800 rounded">暂无 TikTok 账号，点击上方按钮添加</div>
                  <div v-for="(tk, idx) in configForm.tiktok_accounts" :key="idx" class="flex gap-3 items-center mb-2">
                      <span class="text-gray-600 text-xs w-6 text-right">#{{ idx + 1 }}</span>
                      <input v-model="tk.account" type="text" placeholder="TikTok 账号" class="flex-1 bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-indigo-500 font-mono transition-colors">
                      <input v-model="tk.password" type="text" placeholder="密码(明文)" class="flex-1 bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-indigo-500 font-mono transition-colors">
                      <input v-model="tk.email" type="text" placeholder="TikTok 邮箱 (选填)" class="flex-1 bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-indigo-500 font-mono transition-colors">
                      <button @click="configForm.tiktok_accounts.splice(idx, 1)" class="text-red-500 hover:text-red-400 text-xs px-2 py-1 border border-red-800 rounded transition-colors">✕</button>
                  </div>
              </div>

              <!-- 静态 IP 组 -->
              <div>
                  <label class="block text-gray-400 text-xs font-bold mb-3 uppercase tracking-wider">底层网卡 (Static IP)</label>
                  <div class="grid grid-cols-2 gap-4">
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">IPv4 地址</label>
                          <input v-model="configForm.ip" type="text" placeholder="留空则保持自动" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                      </div>
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">子网掩码 (netmask)</label>
                          <input v-model="configForm.subnet" type="text" placeholder="例: 255.255.255.0" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                      </div>
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">默认网关 (Gateway)</label>
                          <input v-model="configForm.gateway" type="text" placeholder="例: 192.168.1.1" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                      </div>
                      <div>
                          <label class="block text-gray-500 text-[10px] mb-1">首选 DNS (nameserver)</label>
                          <input v-model="configForm.dns" type="text" placeholder="例: 8.8.8.8" class="w-full bg-gray-950 border border-gray-800 text-gray-300 text-sm px-3 py-2 rounded focus:outline-none focus:border-teal-500 font-mono transition-colors">
                      </div>
                  </div>
              </div>

              <!-- 独立隧道/引流配置组 -->
              <div>
                  <div class="flex justify-between items-end mb-2">
                     <label class="block text-gray-400 text-xs font-bold uppercase tracking-wider">独立隧道配置 (JSON 树)</label>
                     <span class="text-[10px] text-yellow-500/70 border border-yellow-700/50 px-1.5 py-0.5 rounded bg-yellow-900/10">提交后会无感包裹为 ecnode 协议下卷</span>
                  </div>
                  <textarea v-model="configForm.vpnJson" rows="8" placeholder='[{"name":"节点名称", "server":"...", "port":1080, "type":"ShadowsocksR"}]' class="w-full bg-gray-950 border border-gray-800 text-indigo-300 text-xs p-3 rounded focus:outline-none focus:border-indigo-500 font-mono custom-scrollbar transition-colors leading-relaxed"></textarea>
              </div>

          </div>
          <div class="bg-gray-800/50 p-4 border-t border-gray-800 flex justify-end gap-3 items-center">
             <button @click="showConfigModal = false" class="px-5 py-2 text-gray-400 hover:text-white font-medium text-xs transition-colors tracking-widest">丢弃变更</button>
             <button @click="saveConfig" class="bg-teal-700 hover:bg-teal-600 border border-teal-600 text-white px-6 py-2 rounded shadow transition-colors font-bold tracking-widest text-xs flex items-center gap-2">🖨️ 写入主库集群</button>
          </div>
      </div>
    </div>

    <!-- =============== 评论管理 ================= -->
        <!-- =============== 💬 评论管理 =============== -->
        <div v-if="activeTab === '💬 评论管理'" class="flex flex-1 flex-col overflow-auto p-6 bg-[#0B0F19]">
      <div class="max-w-7xl mx-auto w-full space-y-4">
        
        <!-- 头部栏 -->
        <div class="flex flex-col md:flex-row justify-between items-center gap-4 bg-gray-900 p-4 rounded-lg border border-gray-800 shadow-md">
           <div>
             <h2 class="text-xl font-bold text-gray-100 tracking-wide flex items-center gap-2">💬 多国语言通用评论库</h2>
             <p class="text-xs text-gray-500 mt-1">目前云端共有 {{ comments.length }} 条不含敏感话题的高优评论存量。</p>
           </div>
           
           <!-- 过滤筛选 -->
           <div class="flex items-center gap-3">
             <span class="text-xs text-gray-400 shrink-0">按语言过滤:</span>
             <select v-model="commentFilterLang" class="bg-black border border-gray-700 text-gray-200 text-sm px-3 py-2 rounded focus:outline-none focus:border-indigo-500 w-48 transition-colors cursor-pointer">
               <option value="">全球所有语言</option>
               <option value="zh-CN">🇨🇳 简体中文 (zh-CN)</option>
               <option value="es-MX">🇲🇽 西班牙语-墨西哥 (es-MX)</option>
               <option value="pt-BR">🇧🇷 葡萄牙语-巴西 (pt-BR)</option>
               <option value="de-DE">🇩🇪 德语-德国 (de-DE)</option>
               <option value="en-SG">🇸🇬 英语-新加坡 (en-SG)</option>
               <option value="ja-JP">🇯🇵 日语-日本 (ja-JP)</option>
               <option value="en-US">🇺🇸 英语-美国 (en-US)</option>
               <option value="es-ES">🇪🇸 西班牙语-西班牙 (es-ES)</option>
               <option value="en-GB">🇬🇧 英语-英国 (en-GB)</option>
               <option value="fr-FR">🇫🇷 法语-法国 (fr-FR)</option>
             </select>
             <button @click="fetchComments" class="bg-gray-800 hover:bg-gray-700 border border-gray-600 text-gray-200 px-3 py-2 rounded transition-colors flex items-center justify-center pointer-events-auto">
               <svg class="w-4 h-4 text-gray-300" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path></svg>
             </button>
           </div>
        </div>

        <!-- 卡片网格 -->
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4 pb-8">
           <div v-for="c in comments" :key="c.id" 
                class="group bg-gray-900/60 border border-gray-800/80 rounded-lg p-4 hover:border-gray-600 transition-all hover:-translate-y-0.5 relative shadow">
             <div class="flex items-center justify-between mb-3 text-xs">
                <span class="px-2 py-0.5 bg-gray-800 text-indigo-300 font-mono rounded font-semibold tracking-wider">
                  {{ c.language }}
                </span>
                <button @click="deleteComment(c.id)" class="text-gray-600 hover:text-red-400 opacity-0 group-hover:opacity-100 transition-opacity p-0.5">
                   <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"></path></svg>
                </button>
             </div>
             <p class="text-gray-300 text-sm leading-relaxed">{{ c.content }}</p>
           </div>
        </div>

        <div v-if="comments.length === 0" class="text-center text-gray-500 py-16">
           <svg class="w-16 h-16 mx-auto mb-4 text-gray-700" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"></path></svg>
           <p class="text-lg font-medium text-gray-400">请选择一个语言并进行筛选提取</p>
           <p class="text-sm mt-1">目前为避免网络拥塞默认折叠全体数据，选择右上方语言即可见对应词条。</p>
        </div>

      </div>
    </div>

    <!-- =============== TikTok 账号管理 ================= -->
        <!-- =============== 🎵 TikTok 账号 =============== -->
        <div v-if="activeTab === '🎵 TikTok 账号'" class="flex flex-1 flex-col overflow-auto p-6 bg-[#0B0F19]">
        <div class="max-w-7xl mx-auto w-full space-y-4">
            <div class="flex flex-col md:flex-row justify-between items-center gap-4 bg-gray-900 p-4 rounded-lg border border-gray-800 shadow-md">
                <div>
                    <h2 class="text-xl font-bold text-gray-100 tracking-wide flex items-center gap-2">🎵 TikTok 账号资产管理</h2>
                    <p class="text-xs text-gray-500 mt-1">当前系统中共有 {{ tiktokAccounts.length }} 个已录入的 TikTok 账号。</p>
                </div>
                <button @click="fetchTiktokAccounts" class="bg-teal-800 hover:bg-teal-700 border border-teal-600 text-white px-4 py-2 rounded shadow transition-colors text-xs font-bold flex items-center gap-2">
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path></svg>
                    刷新数据
                </button>
            </div>

            <!-- TikTok 资产筛选工具栏 -->
            <div class="bg-gray-900/80 p-5 rounded-lg border border-gray-800 shadow-lg flex flex-wrap items-end gap-x-6 gap-y-4">
                <div class="flex flex-col gap-1.5">
                    <label class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">🌍 归属国家</label>
                    <select v-model="tkFilterForm.country" class="bg-black border border-gray-700 text-gray-200 text-xs px-3 py-2 rounded focus:outline-none focus:border-indigo-500 w-32 transition-all cursor-pointer">
                        <option value="">全部国家</option>
                        <option v-for="c in countries" :key="c.id" :value="c.name">{{ c.name }}</option>
                    </select>
                </div>
                <div class="flex flex-col gap-1.5">
                    <label class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">📱 设备名称</label>
                    <input v-model="tkFilterForm.device_no" type="text" placeholder="搜索设备..." class="bg-black border border-gray-700 text-gray-200 text-xs px-3 py-2 rounded focus:outline-none focus:border-indigo-500 w-32 transition-all font-mono">
                </div>
                <div class="flex flex-col gap-1.5">
                    <label class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">🆔 账号模糊搜索</label>
                    <input v-model="tkFilterForm.account" type="text" placeholder="搜索账号..." class="bg-black border border-gray-700 text-gray-200 text-xs px-3 py-2 rounded focus:outline-none focus:border-indigo-500 w-40 transition-all font-mono">
                </div>
                <div class="flex flex-col gap-1.5">
                    <label class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">👥 粉丝区间</label>
                    <div class="flex items-center gap-2">
                        <input v-model.number="tkFilterForm.fans_min" type="number" placeholder="MIN" class="bg-black border border-gray-700 text-gray-200 text-xs px-2 py-2 rounded focus:outline-none focus:border-indigo-500 w-20 transition-all font-mono">
                        <span class="text-gray-600">-</span>
                        <input v-model.number="tkFilterForm.fans_max" type="number" placeholder="MAX" class="bg-black border border-gray-700 text-gray-200 text-xs px-2 py-2 rounded focus:outline-none focus:border-indigo-500 w-20 transition-all font-mono">
                    </div>
                </div>
                <div class="flex flex-col gap-1.5">
                    <label class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">🪟 开窗状态</label>
                    <select v-model="tkFilterForm.is_window_opened" class="bg-black border border-gray-700 text-gray-200 text-xs px-3 py-2 rounded focus:outline-none focus:border-indigo-500 w-28 transition-all cursor-pointer">
                        <option value="all">不限</option>
                        <option value="yes">已开窗</option>
                        <option value="no">未开窗</option>
                    </select>
                </div>
                <div class="flex flex-col gap-1.5">
                    <label class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">🤝 出售状态</label>
                    <select v-model="tkFilterForm.is_for_sale" class="bg-black border border-gray-700 text-gray-200 text-xs px-3 py-2 rounded focus:outline-none focus:border-indigo-500 w-28 transition-all cursor-pointer">
                        <option value="all">不限</option>
                        <option value="yes">已出售</option>
                        <option value="no">未出售</option>
                    </select>
                </div>
                <div v-if="isSuperAdmin" class="flex flex-col gap-1.5">
                    <label class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">👤 所属管理员</label>
                    <select v-model="tkFilterForm.admin" class="bg-black border border-gray-700 text-gray-200 text-xs px-3 py-2 rounded focus:outline-none focus:border-indigo-500 w-32 transition-all cursor-pointer">
                        <option value="">全部管理员</option>
                        <option v-for="adm in adminList" :key="adm.id" :value="adm.username">{{ adm.username }}</option>
                    </select>
                </div>
                <div class="flex items-center">
                    <button @click="tkFilterForm = { country: '', device_no: '', account: '', fans_min: null, fans_max: null, is_window_opened: 'all', is_for_sale: 'all', admin: '' }" 
                            class="bg-gray-800 hover:bg-gray-700 text-gray-400 hover:text-white px-4 py-2 rounded text-[10px] font-bold border border-gray-700 transition-all uppercase tracking-widest">
                        🧹 重置筛选
                    </button>
                </div>
            </div>

            <div class="overflow-x-auto bg-gray-900/50 border border-gray-800 rounded-lg shadow-xl">
                <table class="min-w-full text-sm">
                    <thead>
                        <tr class="text-gray-400 text-xs uppercase border-b border-gray-800 bg-gray-900">
                            <th class="p-4 text-center">ID</th>
                            <th class="p-4 text-left">所属设备</th>
                            <th class="p-4 text-left">TikTok 账号</th>
                            <th class="p-4 text-center">国家</th>
                            <th class="p-4 text-center">粉丝</th>
                            <th class="p-4 text-center">开窗</th>
                            <th class="p-4 text-center">出售</th>
                            <th class="p-4 text-center">添加时间</th>
                            <th class="p-4 text-center">操作</th>
                        </tr>
                    </thead>
                    <tbody class="divide-y divide-gray-800/60">
                        <tr v-if="tiktokAccounts.length === 0">
                            <td colspan="9" class="p-12 text-center text-gray-500">
                                <p class="text-lg font-bold">📭 暂无 TikTok 账号数据</p>
                                <p class="text-xs mt-1">请先通过手机列表的设置面板添加 TikTok 账号。</p>
                            </td>
                        </tr>
                        <template v-for="(grp, gIdx) in groupedTiktokAccounts" :key="grp.device_udid">
                            <!-- 设备分组头 -->
                            <tr :class="gIdx > 0 ? 'border-t-2 border-teal-900/60' : ''">
                                <td colspan="9" class="px-4 py-2.5 bg-gray-900/80">
                                    <div class="flex items-center gap-3">
                                        <span class="text-teal-400 text-base">📱</span>
                                        <span class="text-teal-300 font-bold text-sm tracking-wide">{{ grp.device_no }}</span>
                                        <span class="text-gray-600 text-[10px] font-mono">{{ grp.device_udid.substring(0,8) }}...</span>
                                        
                                        <button @click="openAddTkModal(grp)" 
                                                class="ml-auto px-2 py-1 bg-green-900/40 text-green-400 border border-green-800/60 hover:bg-green-600 hover:text-white rounded text-[10px] font-bold transition-all flex items-center shadow-sm">
                                            <span class="mr-1">➕</span> 添加账号
                                        </button>
                                        
                                        <span class="text-[10px] text-gray-500 bg-gray-800 px-2 py-0.5 rounded border border-gray-700">{{ grp.accounts.length }} 个账号</span>
                                    </div>
                                </td>
                            </tr>
                            <tr v-for="tk in grp.accounts" :key="tk.id" class="hover:bg-gray-700/30 transition-colors group">
                                <td class="p-4 text-center font-mono text-gray-500">#{{ tk.id }}</td>
                                <td class="p-4 text-green-400/50 text-xs font-mono pl-8">↳ {{ grp.device_no }}</td>
                                <td class="p-4 text-gray-200 font-mono font-semibold">
                                    <span v-if="tk.is_primary" class="text-amber-400 mr-1" title="设备主账号">⭐</span>
                                    {{ tk.account }}
                                </td>
                                <td class="p-4 text-center text-indigo-300 font-medium">{{ grp.country || '未标记' }}</td>
                                <td class="p-4 text-center text-pink-400 font-bold font-mono">{{ tk.fans_count }} <span class="text-[10px] text-gray-500 ml-1">粉丝</span></td>
                                <td class="p-4 text-center">
                                    <span v-if="tk.is_window_opened" class="bg-indigo-900/30 text-indigo-400 border border-indigo-800 px-2 py-1 rounded text-xs font-bold shadow-sm">✅ 已满粉开窗</span>
                                    <span v-else class="text-gray-500 text-xs italic">未开启</span>
                                </td>
                                <td class="p-4 text-center">
                                    <span v-if="tk.is_for_sale" class="bg-red-900/30 text-red-400 border border-red-800 px-2 py-1 rounded text-xs font-bold shadow-sm">🤝 已成功出售</span>
                                    <span v-else class="text-gray-500 text-xs italic">自持运营中</span>
                                </td>
                                <td class="p-4 text-center text-gray-400 font-mono text-xs">
                                    {{ tk.add_time || '---' }}
                                </td>
                                <td class="p-4 text-center">
                                    <div class="flex justify-center space-x-2">
                                        <button @click="setPrimaryTkAccount(tk)" 
                                                title="设为主号"
                                                :class="tk.is_primary ? 'bg-amber-900/40 text-amber-400 border-amber-800/60' : 'bg-gray-800/60 text-gray-400 border-gray-700 hover:bg-amber-700 hover:text-white'"
                                                class="p-2 rounded border transition-all shadow-sm">
                                            <span class="text-xs">⭐</span>
                                        </button>
                                        <button @click="openTkModal(tk)" class="p-2 bg-blue-900/30 text-blue-400 hover:bg-blue-600 hover:text-white rounded border border-blue-900/50 hover:border-blue-500 transition-all shadow-sm" title="深度编辑档案">
                                            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"></path></svg>
                                        </button>
                                        <button @click="deleteTkAccount(tk.id)" class="p-2 bg-red-900/30 text-red-400 hover:bg-red-600 hover:text-white rounded border border-red-900/50 hover:border-red-500 transition-all shadow-sm" title="清除该档案">
                                            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"></path></svg>
                                        </button>
                                    </div>
                                </td>
                            </tr>
                        </template>
                    </tbody>
                </table>
            </div>
        </div>

    </div>
        <!-- TikTok 编辑 Modal -->
        <div v-if="isTkModalOpen" class="fixed inset-0 z-[100] flex items-center justify-center bg-black/70 backdrop-blur-sm">
            <div class="bg-gray-800 border border-gray-700 w-full max-w-2xl rounded-xl shadow-2xl flex flex-col max-h-[90vh]">
                <div class="px-6 py-4 border-b border-gray-700 flex justify-between items-center bg-gray-800/80 rounded-t-xl">
                    <h3 class="text-lg font-bold text-gray-100 flex items-center gap-2">
                       <span class="text-pink-500">🎵</span> 编辑 TikTok 账号深度档案
                    </h3>
                    <button @click="isTkModalOpen=false" class="text-gray-400 hover:text-white outline-none transition-colors">
                        <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path></svg>
                    </button>
                </div>
                <div class="p-6 flex-1 overflow-auto flex flex-col space-y-6">
                    <div class="flex items-center gap-4 bg-gray-900/50 p-4 rounded-lg border border-gray-700/50">
                        <div class="flex-1" v-if="editingTkAccount">
                            <div class="text-xs text-gray-500 font-bold uppercase mb-1">账号字符串</div>
                            <input v-model="editingTkAccount.account" 
                                   class="w-full bg-gray-900 border border-gray-700 rounded-lg px-3 py-2 text-xl font-mono text-gray-200 font-bold outline-none focus:border-indigo-500 transition-all shadow-inner"
                                   placeholder="例如: user_888">
                        </div>
                        <div class="flex-1 text-right" v-if="editingTkAccount">
                            <div class="text-xs text-gray-500 font-bold uppercase mb-1">当前所在设备</div>
                            <div class="text-xl font-mono text-green-400 font-bold">{{ editingTkAccount?.device_no || '未知' }}</div>
                        </div>
                    </div>

                    <div class="grid grid-cols-2 gap-6">
                        <div>
                            <label class="block text-sm font-medium text-gray-300 mb-1">归属地 (CountryCode)</label>
                            <div class="w-full bg-gray-900/50 border border-gray-700/50 rounded-lg px-4 py-2 text-indigo-400 font-bold outline-none flex items-center gap-2">
                                <span>📍</span> {{ editingTkAccount.device_country || '未设置' }}
                                <span class="bg-indigo-500/10 text-indigo-500 text-[10px] px-1.5 py-0.5 rounded ml-auto">同步自设备</span>
                            </div>
                        </div>
                        <div>
                            <label class="block text-sm font-medium text-gray-300 mb-1">实时粉丝数量</label>
                            <input v-model="editingTkAccount.fans_count" type="number" min="0" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 text-gray-100 outline-none focus:border-indigo-500 transition-all font-mono" placeholder="粉丝量级">
                        </div>
                    </div>

                    <div class="grid grid-cols-2 gap-6">
                        <div>
                            <label class="block text-sm font-medium text-gray-300 mb-1">账号密码 (Password)</label>
                            <input v-model="editingTkAccount.password" type="text" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 text-gray-100 outline-none focus:border-indigo-500 transition-all font-mono" placeholder="登录密码">
                        </div>
                        <div>
                            <label class="block text-sm font-medium text-gray-300 mb-1">关联邮箱 (Email)</label>
                            <input v-model="editingTkAccount.email" type="text" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 text-gray-100 outline-none focus:border-indigo-500 transition-all font-mono" placeholder="绑定邮箱地址">
                        </div>
                    </div>

                    <div class="grid grid-cols-2 gap-6 items-center p-4 bg-gray-900/30 border border-gray-700 rounded-lg">
                       <label class="flex items-center gap-3 cursor-pointer group">
                          <div class="relative flex items-center">
                             <input type="checkbox" v-model="editingTkAccount.is_window_opened" class="sr-only">
                             <div class="w-10 h-6 bg-gray-700 rounded-full transition-colors" :class="editingTkAccount.is_window_opened ? 'bg-indigo-600' : ''"></div>
                             <div class="absolute left-1 top-1 w-4 h-4 bg-white rounded-full transition-transform" :class="editingTkAccount.is_window_opened ? 'translate-x-4' : ''"></div>
                          </div>
                          <div class="flex flex-col">
                             <span class="text-gray-200 font-bold text-sm">已达标并开通橱窗</span>
                             <span class="text-[10px] text-gray-500">满粉后开通带货资格</span>
                          </div>
                       </label>
                       
                       <label class="flex items-center gap-3 cursor-pointer group">
                          <div class="relative flex items-center">
                             <input type="checkbox" v-model="editingTkAccount.is_for_sale" class="sr-only">
                             <div class="w-10 h-6 bg-gray-700 rounded-full transition-colors" :class="editingTkAccount.is_for_sale ? 'bg-red-600' : ''"></div>
                             <div class="absolute left-1 top-1 w-4 h-4 bg-white rounded-full transition-transform" :class="editingTkAccount.is_for_sale ? 'translate-x-4' : ''"></div>
                          </div>
                          <div class="flex flex-col">
                             <span class="text-gray-200 font-bold text-sm">已脱手或离线出售</span>
                             <span class="text-[10px] text-gray-500">不再占用自营运营资源</span>
                          </div>
                       </label>
                    </div>
                    
                    <div class="grid grid-cols-1 gap-4">
                        <div>
                            <label class="block text-sm font-medium text-gray-300 mb-1">资产添加时间 (系统生成)</label>
                            <input v-model="editingTkAccount.add_time" type="text" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 text-gray-400 outline-none focus:border-indigo-500 font-mono text-sm transition-all" placeholder="时间格式如: 2026-03-10 12:00:00">
                        </div>
                        <div class="grid grid-cols-2 gap-4">
                            <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1">开通橱窗时间戳</label>
                                <input v-model="editingTkAccount.window_open_time" type="text" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-3 py-2 text-gray-300 outline-none focus:border-indigo-500 font-mono text-sm transition-all" placeholder="留空则不记录">
                            </div>
                            <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1">账号出售交付时间</label>
                                <input v-model="editingTkAccount.sale_time" type="text" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-3 py-2 text-gray-300 outline-none focus:border-indigo-500 font-mono text-sm transition-all" placeholder="留空则不记录">
                            </div>
                        </div>
                    </div>

                </div>
                <div class="px-6 py-4 border-t border-gray-700 flex justify-end space-x-3 bg-gray-800/80 rounded-b-xl">
                    <button @click="isTkModalOpen=false" class="px-5 py-2.5 rounded-lg outline-none text-gray-300 hover:bg-gray-700 transition-colors font-medium border border-transparent">取消修改</button>
                    <button @click="saveTkAccount" class="px-6 py-2.5 bg-indigo-600 hover:bg-indigo-500 outline-none rounded-lg text-white font-medium shadow-[0_4px_10px_rgba(79,70,229,0.3)] transition-all">确认保存</button>
                </div>
            </div>
        </div>

    <!-- =============== 用户管理（超级管理员专用） ================= -->
    <div v-if="activeTab === '👤 用户管理'" class="flex flex-1 flex-col overflow-auto p-6 bg-[#0B0F19]">
        <div class="max-w-5xl mx-auto w-full space-y-4">
            <div class="flex justify-between items-center bg-gray-900 p-4 rounded-lg border border-gray-800 shadow-md">
                <div>
                    <h2 class="text-xl font-bold text-gray-100 tracking-wide flex items-center gap-2">👤 管理员账号管理</h2>
                    <p class="text-xs text-gray-500 mt-1">当前系统中共有 {{ adminList.length }} 个管理员。</p>
                </div>
                <div class="flex gap-2">
                    <button @click="fetchAdmins" class="bg-gray-800 hover:bg-gray-700 border border-gray-600 text-gray-200 px-3 py-2 rounded transition-colors text-xs">🔄 刷新</button>
                    <button @click="showCreateAdminModal = true" class="bg-blue-700 hover:bg-blue-600 border border-blue-500 text-white px-4 py-2 rounded shadow transition-colors text-xs font-bold">+ 创建管理员</button>
                </div>
            </div>

            <div class="overflow-x-auto bg-gray-900/50 border border-gray-800 rounded-lg shadow-xl">
                <table class="min-w-full text-sm">
                    <thead>
                        <tr class="text-gray-400 text-xs uppercase border-b border-gray-800 bg-gray-900">
                            <th class="p-4 text-center">ID</th>
                            <th class="p-4 text-left">用户名</th>
                            <th class="p-4 text-center">角色</th>
                            <th class="p-4 text-center">管辖设备数</th>
                            <th class="p-4 text-center">创建时间</th>
                            <th class="p-4 text-center">操作</th>
                        </tr>
                    </thead>
                    <tbody class="divide-y divide-gray-800/60">
                        <tr v-if="adminList.length === 0">
                            <td colspan="6" class="p-12 text-center text-gray-500">
                                <p class="text-lg font-bold">📭 暂无管理员数据</p>
                            </td>
                        </tr>
                        <tr v-for="admin in adminList" :key="admin.id" class="hover:bg-gray-700/30 transition-colors group">
                            <td class="p-4 text-center font-mono text-gray-500">#{{ admin.id }}</td>
                            <td class="p-4 text-gray-200 font-bold font-mono">{{ admin.username }}</td>
                            <td class="p-4 text-center">
                                <span :class="admin.role === 'super_admin' ? 'bg-amber-900/40 text-amber-400 border-amber-700' : 'bg-blue-900/30 text-blue-400 border-blue-800'" 
                                      class="px-2 py-0.5 rounded text-[10px] font-bold border">
                                    {{ admin.role === 'super_admin' ? '超级管理员' : '管理员' }}
                                </span>
                            </td>
                            <td class="p-4 text-center">
                                <span class="text-indigo-300 font-mono font-bold">{{ (admin.devices || []).length }}</span>
                                <span class="text-gray-500 text-xs ml-1">台</span>
                            </td>
                            <td class="p-4 text-center text-gray-400 font-mono text-xs">
                                {{ admin.created_at ? new Date(admin.created_at * 1000).toLocaleString() : '---' }}
                            </td>
                            <td class="p-4 text-center">
                                <div class="flex justify-center gap-2">
                                    <button @click="openAssignDeviceModal(admin)" class="px-2 py-1 bg-indigo-900/30 text-indigo-400 hover:bg-indigo-600 hover:text-white rounded border border-indigo-900/50 transition-all text-xs font-bold" title="管理设备分配">📱 设备</button>
                                    <button @click="openPasswordModal(admin)" class="px-2 py-1 bg-yellow-900/30 text-yellow-400 hover:bg-yellow-600 hover:text-white rounded border border-yellow-900/50 transition-all text-xs font-bold" title="修改密码">🔑 密码</button>
                                    <button v-if="admin.role !== 'super_admin'" @click="deleteAdmin(admin.id)" class="px-2 py-1 bg-red-900/30 text-red-400 hover:bg-red-600 hover:text-white rounded border border-red-900/50 transition-all text-xs font-bold" title="删除管理员">🗑 删除</button>
                                </div>
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <!-- 创建管理员弹窗 -->
    <div v-if="showCreateAdminModal" class="fixed inset-0 z-[100] flex items-center justify-center bg-black/70 backdrop-blur-sm">
        <div class="bg-gray-800 border border-gray-700 w-full max-w-md rounded-xl shadow-2xl flex flex-col">
            <div class="px-6 py-4 border-b border-gray-700 flex justify-between items-center">
                <h3 class="text-lg font-bold text-gray-100">✨ 创建新管理员</h3>
                <button @click="showCreateAdminModal = false" class="text-gray-400 hover:text-white">✕</button>
            </div>
            <div class="p-6 flex flex-col gap-4">
                <div>
                    <label class="block text-xs text-gray-400 font-bold mb-1">用户名</label>
                    <input v-model="newAdminForm.username" type="text" placeholder="管理员登录名" class="w-full bg-gray-950 border border-gray-700 rounded-lg px-4 py-2.5 text-gray-200 outline-none focus:border-blue-500 font-mono" />
                </div>
                <div>
                    <label class="block text-xs text-gray-400 font-bold mb-1">密码</label>
                    <input v-model="newAdminForm.password" type="text" placeholder="初始密码" class="w-full bg-gray-950 border border-gray-700 rounded-lg px-4 py-2.5 text-gray-200 outline-none focus:border-blue-500 font-mono" />
                </div>
                <div>
                    <label class="block text-xs text-gray-400 font-bold mb-1">角色</label>
                    <select v-model="newAdminForm.role" class="w-full bg-gray-950 border border-gray-700 rounded-lg px-4 py-2.5 text-gray-200 outline-none focus:border-blue-500">
                        <option value="admin">普通管理员</option>
                        <option value="super_admin">超级管理员</option>
                    </select>
                </div>
            </div>
            <div class="px-6 py-4 border-t border-gray-700 flex justify-end gap-3">
                <button @click="showCreateAdminModal = false" class="px-4 py-2 text-gray-400 hover:text-white transition-colors">取消</button>
                <button @click="createAdmin" class="px-5 py-2 bg-blue-600 hover:bg-blue-500 text-white font-bold rounded shadow transition-colors">确认创建</button>
            </div>
        </div>
    </div>

    <!-- 修改密码弹窗 -->
    <div v-if="showPasswordModal" class="fixed inset-0 z-[100] flex items-center justify-center bg-black/70 backdrop-blur-sm">
        <div class="bg-gray-800 border border-gray-700 w-full max-w-md rounded-xl shadow-2xl flex flex-col">
            <div class="px-6 py-4 border-b border-gray-700 flex justify-between items-center">
                <h3 class="text-lg font-bold text-gray-100">🔑 修改密码 - {{ editPasswordForm.username }}</h3>
                <button @click="showPasswordModal = false" class="text-gray-400 hover:text-white">✕</button>
            </div>
            <div class="p-6">
                <label class="block text-xs text-gray-400 font-bold mb-1">新密码</label>
                <input v-model="editPasswordForm.password" type="text" placeholder="输入新密码" class="w-full bg-gray-950 border border-gray-700 rounded-lg px-4 py-2.5 text-gray-200 outline-none focus:border-blue-500 font-mono" />
            </div>
            <div class="px-6 py-4 border-t border-gray-700 flex justify-end gap-3">
                <button @click="showPasswordModal = false" class="px-4 py-2 text-gray-400 hover:text-white transition-colors">取消</button>
                <button @click="updatePassword" class="px-5 py-2 bg-amber-600 hover:bg-amber-500 text-white font-bold rounded shadow transition-colors">确认修改</button>
            </div>
        </div>
    </div>

    <!-- 设备分配弹窗 -->
    <div v-if="showAssignDeviceModal && assigningAdmin" class="fixed inset-0 z-[100] flex items-center justify-center bg-black/70 backdrop-blur-sm">
        <div class="bg-gray-800 border border-gray-700 w-full max-w-2xl rounded-xl shadow-2xl flex flex-col max-h-[80vh]">
            <div class="px-6 py-4 border-b border-gray-700 flex justify-between items-center shrink-0">
                <h3 class="text-lg font-bold text-gray-100">📱 设备分配 - {{ assigningAdmin.username }}</h3>
                <button @click="showAssignDeviceModal = false" class="text-gray-400 hover:text-white">✕</button>
            </div>
            <div class="p-6 flex-1 overflow-auto flex flex-col gap-4">
                <!-- 已分配的设备 -->
                <div>
                    <h4 class="text-xs text-gray-400 font-bold uppercase mb-2">已分配设备 ({{ (assigningAdmin.devices || []).length }} 台)</h4>
                    <div v-if="(assigningAdmin.devices || []).length === 0" class="text-center text-gray-600 text-xs py-4 border border-dashed border-gray-700 rounded">暂未分配任何设备</div>
                    <div v-for="udid in (assigningAdmin.devices || [])" :key="udid" class="flex justify-between items-center bg-gray-900 border border-gray-750 p-2.5 rounded mb-1.5 group hover:border-gray-600 transition-colors">
                        <div class="flex items-center gap-2">
                            <span class="text-green-400 text-xs">📱</span>
                            <span class="text-gray-300 font-mono text-xs">{{ udid.substring(0,20) }}...</span>
                            <span v-if="devices.find(d => d.udid === udid)" class="text-[9px] text-gray-500 bg-gray-800 px-1.5 py-0.5 rounded">{{ devices.find(d => d.udid === udid)?.device_no || '未命名' }}</span>
                        </div>
                        <button @click="removeDevice(assigningAdmin.id, udid)" class="text-red-500 hover:text-white px-2 py-0.5 bg-red-500/10 hover:bg-red-500 rounded text-xs transition-colors">移除</button>
                    </div>
                </div>
                <!-- 可分配的设备 -->
                <div>
                    <h4 class="text-xs text-gray-400 font-bold uppercase mb-2">可分配的设备</h4>
                    <div class="grid grid-cols-1 gap-1.5 max-h-[300px] overflow-y-auto custom-scrollbar">
                        <div v-for="dev in devices.filter(d => !(assigningAdmin.devices || []).includes(d.udid))" :key="dev.udid" 
                             class="flex justify-between items-center bg-gray-950 border border-gray-800 p-2.5 rounded hover:border-gray-600 transition-colors">
                            <div class="flex items-center gap-2">
                                <span class="text-gray-500 text-xs">📱</span>
                                <span class="text-gray-400 font-mono text-xs">{{ dev.device_no || dev.udid.substring(0,16) + '...' }}</span>
                                <span class="text-[9px] text-gray-600">{{ dev.country || '' }}</span>
                            </div>
                            <button @click="assignDevice(dev.udid)" class="text-blue-400 hover:text-white px-2 py-0.5 bg-blue-500/10 hover:bg-blue-500 rounded text-xs transition-colors font-bold">+ 分配</button>
                        </div>
                    </div>
                </div>
            </div>
            <div class="px-6 py-3 border-t border-gray-700 flex justify-end shrink-0">
                <button @click="showAssignDeviceModal = false" class="px-5 py-2 bg-gray-700 hover:bg-gray-600 text-white rounded shadow transition-colors text-xs font-bold">关闭</button>
            </div>
        </div>
    </div>

    <!-- =============== 一次性任务管理 ================= -->
    <div v-if="activeTab === '⚡ 一次性任务'" class="flex flex-1 flex-col overflow-auto p-6 bg-[#0B0F19]">
        <div class="max-w-6xl mx-auto w-full space-y-4">
            <div class="flex justify-between items-center bg-gray-900 p-4 rounded-lg border border-gray-800 shadow-md">
                <div>
                    <h2 class="text-xl font-bold text-gray-100 tracking-wide flex items-center gap-2">⚡ 一次性任务管理</h2>
                    <p class="text-xs text-gray-500 mt-1">当前待执行的一次性任务共 {{ oneshotTasks.length }} 个。任务完成后会自动删除。</p>
                </div>
                <button @click="fetchOneshotTasks" class="bg-gray-800 hover:bg-gray-700 text-gray-300 px-4 py-1.5 rounded shadow border border-gray-700 font-bold text-xs transition-colors">🔄 刷新</button>
            </div>

            <div v-if="oneshotTasks.length === 0" class="text-center py-16 text-gray-600">
                <p class="text-4xl mb-3">✅</p>
                <p class="text-sm">暂无待执行的一次性任务</p>
            </div>

            <div v-else class="overflow-hidden rounded-xl border border-gray-800">
                <table class="w-full text-left text-xs">
                    <thead class="bg-gray-900 border-b border-gray-800">
                        <tr>
                            <th class="px-4 py-3 text-gray-500 font-bold">ID</th>
                            <th class="px-4 py-3 text-gray-500 font-bold">设备编号</th>
                            <th class="px-4 py-3 text-gray-500 font-bold">UDID</th>
                            <th class="px-4 py-3 text-gray-500 font-bold">任务名称</th>
                            <th class="px-4 py-3 text-gray-500 font-bold">状态</th>
                            <th class="px-4 py-3 text-gray-500 font-bold">脚本预览</th>
                            <th class="px-4 py-3 text-gray-500 font-bold">创建时间</th>
                            <th class="px-4 py-3 text-gray-500 font-bold">操作</th>
                        </tr>
                    </thead>
                    <tbody>
                        <tr v-for="task in oneshotTasks" :key="task.id" class="border-b border-gray-800/50 hover:bg-gray-900/50 transition-colors">
                            <td class="px-4 py-3 text-gray-400 font-mono">#{{ task.id }}</td>
                            <td class="px-4 py-3 text-gray-300">{{ task.device_no || '-' }}</td>
                            <td class="px-4 py-3 text-gray-500 font-mono text-[10px]">{{ task.udid?.substring(0, 12) }}...</td>
                            <td class="px-4 py-3 text-emerald-400 font-bold">{{ task.name }}</td>
                            <td class="px-4 py-3">
                                <span v-if="task.status === 'pending'" class="bg-amber-900/30 text-amber-400 border-amber-700 px-2 py-0.5 rounded-full text-[10px] font-bold border">❤️ 待执行</span>
                                <span v-else-if="task.status === 'running'" class="bg-blue-900/30 text-blue-400 border-blue-700 px-2 py-0.5 rounded-full text-[10px] font-bold border animate-pulse">🔄 执行中</span>
                                <span v-else-if="task.status === 'failed'" class="bg-red-900/30 text-red-500 border-red-800 px-2 py-0.5 rounded-full text-[10px] font-bold border hover:bg-red-800 cursor-pointer transition-colors" @click="showTaskError({ task_name: task.name, last_command: JSON.parse(task.result || '{}').last_command || '未知', error: JSON.parse(task.result || '{}').error || task.result || '执行异常' })">❌ 失败 (查看日志)</span>
                                <span v-else class="text-gray-500 text-[10px]">{{ task.status }}</span>
                            </td>
                            <td class="px-4 py-3 text-gray-500 font-mono text-[10px] max-w-[200px] truncate">{{ task.code?.substring(0, 60) }}...</td>
                            <td class="px-4 py-3 text-gray-500 text-[10px]">{{ task.created_at ? new Date(task.created_at * 1000).toLocaleString('zh-CN') : '-' }}</td>
                            <td class="px-4 py-3">
                                <button @click="deleteOneshotTask(task.id)" class="text-red-400 hover:text-red-300 text-[10px] font-bold border border-red-800/50 hover:border-red-600 px-2 py-0.5 rounded transition-colors">🗑 删除</button>
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <!-- ========== 📁 文件管理 Tab ========== -->
    <div v-if="activeTab === '📁 文件管理'" class="flex flex-1 flex-col overflow-auto p-6 bg-[#0B0F19]">
        <div class="max-w-4xl w-full mx-auto">
            <div class="flex items-center justify-between mb-6">
                <h2 class="text-xl font-bold text-gray-100 flex items-center gap-3">
                    <span class="p-2.5 bg-emerald-900/40 rounded-xl text-emerald-400">📁</span>
                    文件管理
                    <span class="text-xs bg-gray-800 text-gray-400 px-2 py-0.5 rounded-full font-normal">{{ sharedFiles.length }} 个文件</span>
                </h2>
                <label v-if="isSuperAdmin" class="cursor-pointer">
                    <input type="file" class="hidden" @change="uploadSharedFile" :disabled="fileUploading" />
                    <span :class="['inline-flex items-center gap-2 px-5 py-2.5 rounded-xl text-sm font-bold transition-all', fileUploading ? 'bg-gray-700 text-gray-500 cursor-wait' : 'bg-emerald-600 hover:bg-emerald-500 text-white shadow-lg shadow-emerald-900/30 hover:shadow-emerald-800/40']">
                        {{ fileUploading ? '⏳ 上传中...' : '📤 上传文件' }}
                    </span>
                </label>
            </div>

            <div v-if="sharedFiles.length === 0" class="text-center py-20 text-gray-600">
                <div class="text-5xl mb-4">📂</div>
                <p class="text-sm">暂无共享文件</p>
                <p v-if="isSuperAdmin" class="text-xs text-gray-700 mt-2">点击右上角「上传文件」添加文件</p>
            </div>

            <div v-else class="bg-gray-900/60 border border-gray-800 rounded-2xl overflow-hidden">
                <table class="w-full text-sm">
                    <thead>
                        <tr class="border-b border-gray-800 bg-gray-900/80">
                            <th class="px-5 py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest">文件名</th>
                            <th class="px-5 py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest">大小</th>
                            <th class="px-5 py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest">上传时间</th>
                            <th class="px-5 py-3 text-right text-[10px] font-bold text-gray-500 uppercase tracking-widest">操作</th>
                        </tr>
                    </thead>
                    <tbody>
                        <tr v-for="file in sharedFiles" :key="file.name" class="border-b border-gray-800/50 hover:bg-gray-800/30 transition-colors">
                            <td class="px-5 py-3">
                                <div class="flex items-center gap-3">
                                    <span class="text-lg">{{ file.name.endsWith('.ipa') ? '📦' : file.name.endsWith('.zip') ? '🗜️' : file.name.endsWith('.tar') || file.name.endsWith('.gz') ? '📚' : '📄' }}</span>
                                    <span class="text-gray-200 font-medium truncate max-w-[300px]" :title="file.name">{{ file.name }}</span>
                                </div>
                            </td>
                            <td class="px-5 py-3 text-gray-400 text-xs font-mono">{{ formatFileSize(file.size) }}</td>
                            <td class="px-5 py-3 text-gray-500 text-xs">{{ new Date(file.upload_time * 1000).toLocaleString('zh-CN') }}</td>
                            <td class="px-5 py-3">
                                <div class="flex items-center justify-end gap-2">
                                    <button @click="copyFileDownloadLink(file.name)" class="px-3 py-1.5 bg-blue-900/30 text-blue-400 hover:bg-blue-600 hover:text-white rounded-lg border border-blue-800/50 transition-all text-[11px] font-bold">📋 复制下载链接</button>
                                    <a :href="`${apiBase}/files/download/${encodeURIComponent(file.name)}`" class="px-3 py-1.5 bg-emerald-900/30 text-emerald-400 hover:bg-emerald-600 hover:text-white rounded-lg border border-emerald-800/50 transition-all text-[11px] font-bold no-underline" download>⬇️ 下载</a>
                                    <button v-if="isSuperAdmin" @click="deleteSharedFile(file.name)" class="px-3 py-1.5 bg-red-900/30 text-red-400 hover:bg-red-600 hover:text-white rounded-lg border border-red-900/50 transition-all text-[11px] font-bold">🗑 删除</button>
                                </div>
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>
    </div>

  <!-- End Main App Container (主容器由模板根元素自动闭合) -->

    <!-- 批量配置 Modal -->
    <div v-if="showBatchConfigModal" class="fixed inset-0 bg-black/80 backdrop-blur-sm z-[999] flex items-center justify-center p-4">
        <div class="bg-gray-900 border border-gray-800 w-full max-w-md rounded-2xl shadow-2xl overflow-hidden animate-in zoom-in duration-200">
            <div class="p-6 border-b border-gray-800 bg-gray-900/50 flex justify-between items-center">
                <h3 class="text-lg font-bold text-gray-100 flex items-center gap-3">
                    <span class="p-2 bg-indigo-900/50 rounded-lg text-indigo-400">📝</span>
                    批量修改配置 ({{ selectedDevices.length }} 台)
                </h3>
                <button @click="showBatchConfigModal = false" class="text-gray-500 hover:text-white transition-colors">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path></svg>
                </button>
            </div>
            
            <div class="p-6 space-y-5">
                <p class="text-xs text-gray-500 bg-indigo-900/10 p-3 rounded-lg border border-indigo-900/30">
                    💡 提示：仅修改您填写的字段，留空的字段将保持各手机原有配置。
                </p>

                <!-- 批量修改选项 -->
                <div class="space-y-4">
                    <div>
                        <label class="block text-xs font-bold text-gray-500 uppercase tracking-widest mb-2">所属国家</label>
                        <select v-model="batchConfigForm.country" class="w-full bg-black border border-gray-800 rounded-xl px-4 py-3 text-sm text-gray-300 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 outline-none transition-all">
                            <option value="">(不修改)</option>
                            <option value="__CLEAR__" class="text-red-400">🗑️ (清空国家)</option>
                            <option v-for="c in countries" :key="c.id" :value="c.name">{{ c.name }}</option>
                        </select>
                    </div>
                    
                    <div>
                        <label class="block text-xs font-bold text-gray-500 uppercase tracking-widest mb-2">设备分组</label>
                        <select v-model="batchConfigForm.group_name" class="w-full bg-black border border-gray-800 rounded-xl px-4 py-3 text-sm text-gray-300 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 outline-none transition-all">
                            <option value="">(不修改)</option>
                            <option value="__CLEAR__" class="text-red-400">🗑️ (清空分组)</option>
                            <option v-for="g in groups" :key="g.id" :value="g.name">{{ g.name }}</option>
                        </select>
                    </div>

                    <div>
                        <label class="block text-xs font-bold text-gray-500 uppercase tracking-widest mb-2 flex items-center gap-2 cursor-pointer w-max" @click="batchConfigForm.enableWifi = !batchConfigForm.enableWifi">
                           <input type="checkbox" v-model="batchConfigForm.enableWifi" class="accent-indigo-500 rounded bg-gray-900 border-gray-700 w-4 h-4 cursor-pointer" @click.stop>
                           <span>统一配置 Wi-Fi</span>
                        </label>
                        <div v-if="batchConfigForm.enableWifi" class="grid grid-cols-2 gap-3 mt-3">
                            <input v-model="batchConfigForm.wifi_ssid" type="text" placeholder="网络名称 (SSID)" class="w-full bg-black border border-gray-800 rounded-xl px-4 py-3 text-sm text-gray-300 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 outline-none transition-all">
                            <input v-model="batchConfigForm.wifi_password" type="text" placeholder="明文密码" class="w-full bg-black border border-gray-800 rounded-xl px-4 py-3 text-sm text-gray-300 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 outline-none transition-all">
                        </div>
                    </div>

                    <div>
                        <label class="block text-xs font-bold text-gray-500 uppercase tracking-widest mb-2">自动执行时辰</label>
                        <select v-model="batchConfigForm.exec_time" class="w-full bg-black border border-gray-800 rounded-xl px-4 py-3 text-sm text-gray-300 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 outline-none transition-all">
                            <option value="">(不修改)</option>
                            <option value="__CLEAR__" class="text-red-400">🗑️ (清空时辰)</option>
                            <option v-for="t in execTimes" :key="t.id" :value="t.name">{{ t.name }} 点整</option>
                        </select>
                    </div>

                    <div>
                        <label class="block text-xs font-bold text-gray-500 uppercase tracking-widest flex justify-between items-center mb-2">
                           <span>VPN Node JSON</span>
                           <span class="text-[10px] text-gray-600 font-normal normal-case">V2ray/Xray/Clash 等节点结构</span>
                        </label>
                        <textarea v-model="batchConfigForm.vpnJson" rows="4" placeholder="填入新的 VPN JSON。留空表示保持原有节点不替换。" class="w-full font-mono text-xs bg-black/50 border border-gray-800 rounded-xl px-4 py-3 text-emerald-400 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 outline-none leading-relaxed transition-all placeholder:text-gray-700 custom-scrollbar"></textarea>
                    </div>
                </div>
            </div>

            <div class="p-6 bg-gray-900/80 border-t border-gray-800 flex justify-end gap-3 px-8 pb-8">
                <button @click="showBatchConfigModal = false" class="px-5 py-2 text-gray-400 hover:text-white font-medium text-xs transition-colors tracking-widest">取消</button>
                <button @click="saveBatchConfig" class="bg-indigo-600 hover:bg-indigo-500 text-white px-8 py-2.5 rounded-xl shadow-lg shadow-indigo-500/20 transition-all font-bold text-xs tracking-widest">
                    同步配置至雷达矩阵
                </button>
            </div>
        </div>
    </div>

    <!-- 一次性任务下发弹窗 -->
    <div v-if="showOneshotModal" class="fixed inset-0 bg-black/80 backdrop-blur-sm z-[999] flex items-center justify-center p-4">
        <div class="bg-gray-900 border border-gray-800 w-full max-w-lg rounded-2xl shadow-2xl overflow-hidden animate-in zoom-in duration-200">
            <div class="p-6 border-b border-gray-800 bg-gray-900/50 flex justify-between items-center">
                <h3 class="text-lg font-bold text-gray-100 flex items-center gap-3">
                    <span class="p-2 bg-emerald-900/50 rounded-lg text-emerald-400">⚡</span>
                    下发一次性任务 ({{ selectedDevices.length }} 台)
                </h3>
                <button @click="showOneshotModal = false" class="text-gray-500 hover:text-white transition-colors">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path></svg>
                </button>
            </div>

            <div class="p-6 space-y-5">
                <p class="text-xs text-gray-500 bg-emerald-900/10 p-3 rounded-lg border border-emerald-900/30">
                    ⚡ 一次性任务拥有最高优先级，客户端会在 30 秒内自动拉取并执行。执行期间常规任务和在线升级都会暂停。完成后自动删除。
                </p>

                <div>
                    <label class="block text-xs font-bold text-gray-500 uppercase tracking-widest mb-2">任务名称</label>
                    <input v-model="oneshotForm.name" type="text" placeholder="例如：紧急更新VPN、重启应用..." class="w-full bg-black border border-gray-800 rounded-xl px-4 py-3 text-sm text-gray-300 focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500 outline-none transition-all" />
                </div>

                <div>
                    <label class="block text-xs font-bold text-gray-500 uppercase tracking-widest mb-2">脚本代码</label>
                    <textarea v-model="oneshotForm.code" rows="10" placeholder="输入要执行的 JavaScript 脚本代码..." class="w-full font-mono text-xs bg-black/50 border border-gray-800 rounded-xl px-4 py-3 text-emerald-400 focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500 outline-none leading-relaxed transition-all placeholder:text-gray-700 custom-scrollbar"></textarea>
                </div>
            </div>

            <div class="p-6 bg-gray-900/80 border-t border-gray-800 flex justify-end gap-3 px-8 pb-8">
                <button @click="showOneshotModal = false" class="px-5 py-2 text-gray-400 hover:text-white font-medium text-xs transition-colors tracking-widest">取消</button>
                <button @click="submitOneshotTask" class="bg-emerald-600 hover:bg-emerald-500 text-white px-8 py-2.5 rounded-xl shadow-lg shadow-emerald-500/20 transition-all font-bold text-xs tracking-widest">
                </button>
            </div>
        </div>
    </div>
  </main>
</div>
</template>


<style>
.custom-scrollbar::-webkit-scrollbar {
  width: 6px;
  height: 6px;
}
.custom-scrollbar::-webkit-scrollbar-track {
  background: transparent; 
}
.custom-scrollbar::-webkit-scrollbar-thumb {
  background: #4b5563; 
  border-radius: 10px;
}
.custom-scrollbar::-webkit-scrollbar-thumb:hover {
  background: #6b7280; 
}
::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}
::-webkit-scrollbar-track {
  background: #111827; 
}
::-webkit-scrollbar-thumb {
  background: #374151; 
  border-radius: 4px;
}
::-webkit-scrollbar-thumb:hover {
  background: #4b5563; 
}
</style>

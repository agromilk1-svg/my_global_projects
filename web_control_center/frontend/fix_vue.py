import os

file_path = '/Users/hh/Desktop/my/web_control_center/frontend/src/App.vue'

with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
    lines = f.readlines()

# 截断乱码产生的起始代码位置 (即 2785 行之后全抛弃，用正确的文本追加)
# 这一段是 tbody 结束和编辑 Modal 开始
valid_lines = lines[:2788]

correct_suffix = """
                        <template v-for="(grp, gIdx) in groupedTiktokAccounts" :key="grp.device_udid">
                            <!-- 设备分组头 -->
                            <tr :class="gIdx > 0 ? 'border-t-2 border-teal-900/60' : ''">
                                <td colspan="9" class="px-4 py-2.5 bg-gray-900/80">
                                    <div class="flex items-center gap-3">
                                        <span class="text-teal-400 text-base">📱</span>
                                        <span class="text-teal-300 font-bold text-sm tracking-wide">{{ grp.device_no }}</span>
                                        <span class="text-gray-600 text-[10px] font-mono">{{ grp.device_udid.substring(0,8) }}...</span>
                                        <span class="ml-auto text-[10px] text-gray-500 bg-gray-800 px-2 py-0.5 rounded border border-gray-700">{{ grp.accounts.length }} 个账号</span>
                                    </div>
                                </td>
                            </tr>
                            <tr v-for="tk in grp.accounts" :key="tk.id" class="hover:bg-gray-700/30 transition-colors group">
                                <td class="p-4 text-center font-mono text-gray-500">#{{ tk.id }}</td>
                                <td class="p-4 text-green-400/50 text-xs font-mono pl-8">↳ {{ grp.device_no }}</td>
                                <td class="p-4 text-gray-200 font-mono font-semibold">{{ tk.account }}</td>
                                <td class="p-4 text-center text-indigo-300 font-medium">{{ tk.country || '未标记' }}</td>
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
                           <div class="flex-1">
                               <div class="text-xs text-gray-500 font-bold uppercase mb-1">账号字符串</div>
                               <div class="text-xl font-mono text-gray-200 font-bold">{{ editingTkAccount.account }}</div>
                           </div>
                           <div class="flex-1 text-right">
                               <div class="text-xs text-gray-500 font-bold uppercase mb-1">当前所在设备</div>
                               <div class="text-xl font-mono text-green-400 font-bold">{{ editingTkAccount.device_no || '未知' }}</div>
                           </div>
                        </div>

                        <div class="grid grid-cols-2 gap-6">
                            <div>
                                <label class="block text-sm font-medium text-gray-300 mb-1">归属地 (CountryCode)</label>
                                <select v-model="editingTkAccount.country" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 text-gray-100 outline-none focus:border-indigo-500 transition-all">
                                    <option value="">(未设置)</option>
                                    <option v-for="c in countries" :key="c.id" :value="c.name">{{ c.name }}</option>
                                </select>
                            </div>
                            <div>
                                <label class="block text-sm font-medium text-gray-300 mb-1">实时粉丝数量</label>
                                <input v-model="editingTkAccount.fans_count" type="number" min="0" class="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 text-gray-100 outline-none focus:border-indigo-500 transition-all font-mono" placeholder="粉丝量级">
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

        </div>
    </div>
</template>
"""

with open(file_path, 'w', encoding='utf-8') as f:
    f.writelines(valid_lines)
    f.write(correct_suffix)
    
print("✨ App.vue 乱码截断并且重新追加尾部标签块成功！")

--[[
lua_hook_template.lua — CE Auto Assembler 模板插件

功能：
  在 Memory Viewer 里按 Ctrl+Alt+L（或 AA 编辑器 Template 菜单选 "Lua Hook
  (Ctx → Callback)"），生成一份完整的 inline hook 脚本：hook 触发时保存
  全部 GPR/RFLAGS（可选 XMM），通过 luaclient 回调用户在 {$lua} 块里写的
  Lua 函数；回调可读写 ctx.rax/.../.rflags、用 ctx.rsp 访问栈、返回 false
  跳过原指令。

回调签名（按目标位数自动选）：
  function(ctx)
    -- x64: ctx.rax/.rcx/.../.r15 (16 GPR R/W qword)，
    --      ctx.rflags / ctx.rip (rip 只读)，ctx.xmm[0..15] (XMM 开启)
    -- x86: ctx.eax/.ecx/.../.edi (8 GPR R/W dword)，
    --      ctx.eflags / ctx.eip (eip 只读)，ctx.xmm[0..7] (XMM 开启)
    -- ctx.rsp/.esp 改了自负后果
    --
    -- 返回值控制 hook 后跳转：
    --   return 0 / nil / 非数  → 默认（执行原指令并继续，跳到 newmem 内的 hook_original）
    --   return <地址>          → 直接跳到该地址（不执行原指令）
    --                              典型用法 return ctx.rip + N 跳过 N 字节原指令
  end

模式：
  - 同步（默认）：注入代码线程阻塞等回调返回；写 ctx 生效；return false 生效。
  - ASYNC：回调在 CE server 线程跑，注入代码立即继续；写 ctx 不生效；
    return false 不生效。仅在高频 hook（每秒上千次）必须不卡游戏时使用。

依赖：
  luaclient-x86_64.dll（CE 自带），由模板的 [ENABLE] 头部 loadlibrary 装入。

设计文档：
  docs/superpowers/specs/2026-04-21-ce-aa-lua-hook-plugin-design.md

注意事项：
  - 不要在回调里调模态 UI（messageDialog/ShowModal 等）。同步模式下
    回调跑在 CE 主 GUI 线程，模态会泵消息让其它 hook 重入；目标进程
    多线程命中同一 hook 时也会通过 luaclient pipe 串行排队。短小回调
    最安全。
  - 改 ctx.rsp / ctx.rip 后果自负——前者会破栈，后者本插件不实现跳转
    （改了也无效）。
]]

if ce_lua_hook ~= nil then
  -- 已加载过（autorun 重载），先清理旧注册项
  if ce_lua_hook._template_id then unregisterAutoAssemblerTemplate(ce_lua_hook._template_id) end
  if ce_lua_hook._command_registered then unregisterAutoAssemblerCommand('luahookpoint') end
end

ce_lua_hook = {}

-- ===== 上下文布局（单一事实源，ASM 展开器和 trampoline 都引用）=====

-- x64 布局：16 GPR (8 字节) + RFLAGS + RIP + 16 XMM (16 字节)
ce_lua_hook.LAYOUT_X64 = {
  rax = 0x00, rcx = 0x08, rdx = 0x10, rbx = 0x18,
  rsp = 0x20, rbp = 0x28, rsi = 0x30, rdi = 0x38,
  r8  = 0x40, r9  = 0x48, r10 = 0x50, r11 = 0x58,
  r12 = 0x60, r13 = 0x68, r14 = 0x70, r15 = 0x78,
  rflags = 0x80,
  rip    = 0x88,
  xmm0_off = 0xA0,
  size_no_xmm = 0xA0,
  size_with_xmm = 0x1A0,    -- 0xA0 + 16*16
  ptr_size = 8,             -- qword
}

-- x86 布局：8 GPR (4 字节) + EFLAGS + EIP + 8 XMM (16 字节，对齐到 0x30)
ce_lua_hook.LAYOUT_X86 = {
  eax = 0x00, ecx = 0x04, edx = 0x08, ebx = 0x0C,
  esp = 0x10, ebp = 0x14, esi = 0x18, edi = 0x1C,
  eflags = 0x20,
  eip    = 0x24,
  -- 0x28-0x2F 保留对齐到 16
  xmm0_off = 0x30,
  size_no_xmm = 0x30,
  size_with_xmm = 0xB0,     -- 0x30 + 8*16
  ptr_size = 4,             -- dword
}

-- GPR 字段顺序（trampoline diff 回写按这个顺序遍历）
ce_lua_hook.GPR_FIELDS_X64 = {
  'rax','rcx','rdx','rbx','rsp','rbp','rsi','rdi',
  'r8','r9','r10','r11','r12','r13','r14','r15',
}
ce_lua_hook.GPR_FIELDS_X86 = {
  'eax','ecx','edx','ebx','esp','ebp','esi','edi',
}

-- 兼容旧引用（保留 X64 视图作为默认 LAYOUT/GPR_FIELDS，便于历史代码不破）
ce_lua_hook.LAYOUT = ce_lua_hook.LAYOUT_X64
ce_lua_hook.GPR_FIELDS = ce_lua_hook.GPR_FIELDS_X64

-- 选择器
function ce_lua_hook.layout_for(bits)
  return (bits == 32) and ce_lua_hook.LAYOUT_X86 or ce_lua_hook.LAYOUT_X64
end
function ce_lua_hook.gpr_fields_for(bits)
  return (bits == 32) and ce_lua_hook.GPR_FIELDS_X86 or ce_lua_hook.GPR_FIELDS_X64
end

-- 当前 attach 进程位数（template 生成期用）
function ce_lua_hook.target_bits()
  return targetIs64Bit() and 64 or 32
end

-- 内部状态
ce_lua_hook._registry = {}        -- id → {fn, xmm, async}
ce_lua_hook._trampoline_ref = nil -- 启动时填
ce_lua_hook._template_id = nil
ce_lua_hook._command_registered = false

-- ===== 公共 API =====

function ce_lua_hook.setup(id, bits, xmm, async, fn)
  assert(type(id) == 'string' and #id > 0, 'ce_lua_hook.setup: id must be non-empty string')
  assert(bits == 32 or bits == 64, 'ce_lua_hook.setup: bits must be 32 or 64')
  assert(type(fn) == 'function', 'ce_lua_hook.setup: fn must be function')
  -- 幂等：先清理同 id 的旧条目（spec §4.2）
  ce_lua_hook.cleanup(id)
  ce_lua_hook._registry[id] = {
    fn = fn,
    bits = bits,
    xmm = xmm and true or false,
    async = async and true or false,
  }
  print(string.format('[lua_hook] setup id=%s bits=%d xmm=%s async=%s',
    id, bits, tostring(xmm), tostring(async)))
end

function ce_lua_hook.cleanup(id)
  if ce_lua_hook._registry[id] ~= nil then
    ce_lua_hook._registry[id] = nil
    print('[lua_hook] cleanup id='..id)
  end
end

-- expander 查询接口（避免 expander 直接读 _registry，便于将来加锁）
function ce_lua_hook.is_xmm(id) local e = ce_lua_hook._registry[id]; return e and e.xmm or false end
function ce_lua_hook.is_async(id) local e = ce_lua_hook._registry[id]; return e and e.async or false end
function ce_lua_hook.bits_of(id) local e = ce_lua_hook._registry[id]; return e and e.bits or 64 end

-- ===== 注入代码调用的全局入口 =====
-- 由注入代码通过 CELUA_ExecuteFunctionByReference 调用。
-- 参数: ctxptr (qword), hookidptr (qword 指向 0 结尾 ASCII 字符串)
-- 返回: 0 = 执行原指令; 1 = 跳过原指令

function __ce_lua_hook_trampoline(ctxptr, hookidptr)
  if ctxptr == 0 or hookidptr == 0 then return 0 end

  -- readString 自动遇 0 终止；第 3 参数 widechar=false
  local id = readString(hookidptr, 63, false)
  if not id or #id == 0 then return 0 end

  local entry = ce_lua_hook._registry[id]
  if not entry then return 0 end  -- DISABLE 竞态，安全

  local bits = entry.bits
  local L = ce_lua_hook.layout_for(bits)
  local fields = ce_lua_hook.gpr_fields_for(bits)
  local size = entry.xmm and L.size_with_xmm or L.size_no_xmm
  local raw = readBytes(ctxptr, size, true)
  if not raw then return 0 end  -- 目标已死

  -- 把 raw byte 数组按 ptr_size 字节小端拼回 qword/dword
  local function rd_word(off)
    local v = 0
    for i = L.ptr_size - 1, 0, -1 do v = v * 256 + raw[off + 1 + i] end
    return v
  end

  -- 构建 ctx 表
  local ctx = {}
  for _, name in ipairs(fields) do
    ctx[name] = rd_word(L[name])
  end
  local flags_field = (bits == 64) and 'rflags' or 'eflags'
  local ip_field    = (bits == 64) and 'rip'    or 'eip'
  ctx[flags_field] = rd_word(L[flags_field])
  ctx[ip_field]    = rd_word(L[ip_field])
  -- x64 16 个 XMM、x86 8 个
  local xmm_count = (bits == 64) and 16 or 8
  if entry.xmm then
    ctx.xmm = {}
    for i = 0, xmm_count - 1 do
      ctx.xmm[i] = readBytes(ctxptr + L.xmm0_off + i * 16, 16, true)
    end
  end

  -- 快照 GPR + flags 用于回写时 diff（避免无谓 write）。xmm 不快照——见下方写回处的说明。
  local snap = {}
  for _, name in ipairs(fields) do snap[name] = ctx[name] end
  snap[flags_field] = ctx[flags_field]

  -- 调用用户回调
  local ok, retval = pcall(entry.fn, ctx)
  if not ok then
    print(string.format('[lua_hook %s] ERROR: %s\n%s', id, tostring(retval), debug.traceback()))
    return 0
  end

  -- async 模式跳过 diff 回写（spec §4.3）
  if not entry.async then
    local writer = (bits == 64) and writeQword or writeInteger
    for _, name in ipairs(fields) do
      if ctx[name] ~= snap[name] then writer(ctxptr + L[name], ctx[name]) end
    end
    if ctx[flags_field] ~= snap[flags_field] then writer(ctxptr + L[flags_field], ctx[flags_field]) end
    -- rip/eip 不回写（用户改也不实现跳转，spec §4.3）
    -- xmm 写回：启用 XMM 时无条件回写全部槽位（不做 byte-wise diff，
    -- 因为深拷贝快照对每次 hook 命中都是无谓开销；高频 hook 应改用
    -- ASYNC 模式整段跳过回写）。
    if entry.xmm and ctx.xmm then
      for i = 0, xmm_count - 1 do
        if ctx.xmm[i] ~= nil then writeBytes(ctxptr + L.xmm0_off + i * 16, ctx.xmm[i]) end
      end
    end
  end

  -- 返回 = jmp 目标地址；0 / nil / 非数 → 默认（执行原指令 = jmp hook_original）
  if type(retval) == 'number' then return retval end
  return 0
end

-- ===== AA 自定义命令: luahookpoint(<id>) =====

-- 生成 hook 点的 ASM 字符串。id 用作所有内部标号的前缀，避免多 hook 符号冲突。
-- bits: 32 / 64。xmm: 是否保存 XMM。async: 异步模式。
-- 返回值约定：trampoline 返回 0 时执行原指令（默认）；返回非零地址时跳到该地址。
local function build_hook_asm(id, bits, xmm, async, trampoline_refid)
  local async_flag = async and 1 or 0
  local lbl = {
    save        = 'lh_'..id..'_save',
    have_target = 'lh_'..id..'_have_target',
    params      = 'lh_'..id..'_params',
    saved_sp    = 'lh_'..id..'_saved_sp',
    jmp_addr    = 'lh_'..id..'_jmp_addr',
  }
  local lines = {}
  local function emit(s) table.insert(lines, s) end

  -- 共用：所有 label 前置声明（位置由冒号-label 在 newmem 内固定）
  emit('label('..lbl.save..')')
  emit('label('..lbl.have_target..')')
  emit('label('..lbl.params..')')
  emit('label('..lbl.saved_sp..')')
  emit('label('..lbl.jmp_addr..')')

  if bits == 64 then
    -- =========================================================
    -- x64 路径
    -- =========================================================
    local L = ce_lua_hook.LAYOUT_X64
    local FIELDS = ce_lua_hook.GPR_FIELDS_X64

    -- 保存 GPR（先 rax，然后 rax 当 scratch）
    emit(lbl.save..':')
    emit('  mov [ctxbuf+'..string.format('0x%X', L.rax)..'], rax')
    emit('  mov rax, ctxbuf')
    for _, r in ipairs(FIELDS) do
      if r ~= 'rax' then emit(string.format('  mov [rax+0x%X], %s', L[r], r)) end
    end
    emit('  pushfq')
    emit('  pop qword ptr [rax+'..string.format('0x%X', L.rflags)..']')
    emit('  lea rcx, [hook_original]')
    emit('  mov [rax+'..string.format('0x%X', L.rip)..'], rcx')
    if xmm then
      for i = 0, 15 do
        emit(string.format('  movdqu [rax+0x%X], xmm%d', L.xmm0_off + i*16, i))
      end
    end

    -- 调 luaclient (MS x64 ABI: rcx,rdx,r8,r9 + 0x20 shadow + 16B 对齐)
    emit('  mov ['..lbl.saved_sp..'], rsp')
    emit('  and rsp, FFFFFFFFFFFFFFF0')
    emit('  sub rsp, 0x20')
    emit('  mov ecx, '..string.format('0x%X', trampoline_refid))
    emit('  mov edx, 2')
    emit('  lea r8, ['..lbl.params..']')
    emit('  mov r9d, '..async_flag)
    emit('  call CELUA_ExecuteFunctionByReference')
    emit('  mov rsp, ['..lbl.saved_sp..']')

    -- rax = lua 返回（0 = 默认；非 0 = 跳到该地址）。先把 rax 落到 jmp_addr 槽。
    emit('  mov ['..lbl.jmp_addr..'], rax')
    emit('  test rax, rax')
    emit('  jnz '..lbl.have_target)
    emit('  lea rax, [hook_original]')              -- 默认：跳回 newmem 末尾的原指令
    emit('  mov ['..lbl.jmp_addr..'], rax')

    -- 单一恢复路径
    emit(lbl.have_target..':')
    if xmm then
      for i = 0, 15 do
        emit(string.format('  movdqu xmm%d, [ctxbuf+0x%X]', i, L.xmm0_off + i*16))
      end
    end
    emit('  push qword ptr [ctxbuf+'..string.format('0x%X', L.rflags)..']')
    emit('  popfq')
    for _, r in ipairs(FIELDS) do
      if r ~= 'rax' then emit(string.format('  mov %s, [ctxbuf+0x%X]', r, L[r])) end
    end
    emit('  mov rax, [ctxbuf+'..string.format('0x%X', L.rax)..']')
    emit('  jmp qword ptr ['..lbl.jmp_addr..']')   -- indirect jmp 到目标

    -- 数据块（newmem 末尾，永不执行）
    emit(lbl.params..':')
    emit('  dq ctxbuf')
    emit('  dq hookid_str')
    emit(lbl.saved_sp..':')
    emit('  dq 0')
    emit(lbl.jmp_addr..':')
    emit('  dq 0')

  else
    -- =========================================================
    -- x86 路径（stdcall: 右-左 push，callee 清栈）
    -- =========================================================
    local L = ce_lua_hook.LAYOUT_X86
    local FIELDS = ce_lua_hook.GPR_FIELDS_X86

    emit(lbl.save..':')
    emit('  mov [ctxbuf+'..string.format('0x%X', L.eax)..'], eax')
    emit('  mov eax, ctxbuf')
    for _, r in ipairs(FIELDS) do
      if r ~= 'eax' then emit(string.format('  mov [eax+0x%X], %s', L[r], r)) end
    end
    emit('  pushfd')
    emit('  pop dword ptr [eax+'..string.format('0x%X', L.eflags)..']')
    emit('  lea ecx, [hook_original]')
    emit('  mov [eax+'..string.format('0x%X', L.eip)..'], ecx')
    if xmm then
      for i = 0, 7 do
        emit(string.format('  movdqu [eax+0x%X], xmm%d', L.xmm0_off + i*16, i))
      end
    end

    -- 调 luaclient (stdcall)
    emit('  mov ['..lbl.saved_sp..'], esp')
    emit('  and esp, FFFFFFF0')
    emit('  push '..async_flag)
    emit('  push '..lbl.params)
    emit('  push 2')
    emit('  push '..string.format('0x%X', trampoline_refid))
    emit('  call CELUA_ExecuteFunctionByReference')
    emit('  mov esp, ['..lbl.saved_sp..']')

    -- eax = lua 返回；落到 jmp_addr 槽
    emit('  mov ['..lbl.jmp_addr..'], eax')
    emit('  test eax, eax')
    emit('  jnz '..lbl.have_target)
    emit('  lea eax, [hook_original]')
    emit('  mov ['..lbl.jmp_addr..'], eax')

    -- 单一恢复路径
    emit(lbl.have_target..':')
    if xmm then
      for i = 0, 7 do
        emit(string.format('  movdqu xmm%d, [ctxbuf+0x%X]', i, L.xmm0_off + i*16))
      end
    end
    emit('  push dword ptr [ctxbuf+'..string.format('0x%X', L.eflags)..']')
    emit('  popfd')
    for _, r in ipairs(FIELDS) do
      if r ~= 'eax' then emit(string.format('  mov %s, [ctxbuf+0x%X]', r, L[r])) end
    end
    emit('  mov eax, [ctxbuf+'..string.format('0x%X', L.eax)..']')
    emit('  jmp dword ptr ['..lbl.jmp_addr..']')

    -- 数据块
    emit(lbl.params..':')
    emit('  dd ctxbuf')
    emit('  dd hookid_str')
    emit(lbl.saved_sp..':')
    emit('  dd 0')
    emit(lbl.jmp_addr..':')
    emit('  dd 0')
  end

  return table.concat(lines, '\n')
end

local function luahookpoint_expander(params, syntaxcheck)
  -- params 是括号里的内容：去除空白
  local id = (params or ''):gsub('^%s+', ''):gsub('%s+$', '')

  -- 校验 ID 字符
  if #id == 0 or #id > 63 or id:find('[^%w_]') then
    return nil, '[luahookpoint] invalid id: '..tostring(id)..' (need [A-Za-z0-9_], length 1-63)'
  end

  if syntaxcheck == 1 then
    return ''  -- phase 1 不生成代码，只校验
  end

  -- phase 2: 生成汇编
  if ce_lua_hook._trampoline_ref == nil then
    return nil, '[luahookpoint] trampoline not registered yet (CE startup incomplete?). Restart CE.'
  end

  local bits  = ce_lua_hook.bits_of(id)
  local xmm   = ce_lua_hook.is_xmm(id)
  local async = ce_lua_hook.is_async(id)
  return build_hook_asm(id, bits, xmm, async, ce_lua_hook._trampoline_ref)
end

-- 注册（顶层执行，autorun 时立即注册）
if not ce_lua_hook._command_registered then
  registerAutoAssemblerCommand('luahookpoint', luahookpoint_expander)
  ce_lua_hook._command_registered = true
end

-- ===== 反汇编 / AOB 辅助 =====

-- 返回从 addr 起、覆盖至少 5 字节所需的指令总长度，以及原字节表（整数数组）。
function ce_lua_hook.compute_orig_len(addr)
  local total = 0
  local cur = addr
  while total < 5 do
    local sz = getInstructionSize(cur)
    if not sz or sz <= 0 then
      error(string.format('compute_orig_len: cannot disassemble at %X', cur))
    end
    total = total + sz
    cur = cur + sz
    if total > 32 then  -- 极端兜底，防死循环
      error('compute_orig_len: instruction stream pathological')
    end
  end
  local bytes = readBytes(addr, total, true)
  if not bytes then error(string.format('compute_orig_len: cannot read bytes at %X', addr)) end
  return total, bytes
end

-- 把字节数组转成 AA 风格 hex 串："48 8B 41 08"
function ce_lua_hook.bytes_to_hex(bytes)
  local out = {}
  for _, b in ipairs(bytes) do table.insert(out, string.format('%02X', b)) end
  return table.concat(out, ' ')
end

-- 从 addr 起读 length 字节生成 AOB 特征。把疑似 RIP-relative 偏移 / 立即数 imm32 通配为 ??。
-- 简化策略：扫到任一 disp32 / imm32（出现在 mov reg,imm32; call rel32; jmp rel32; lea rax,[rip+disp]）
-- 处都把那 4 字节通配。识别靠每条指令 size 减去 opcode 前缀长度做粗判，准确性"够用"。
-- 用法：在 hook 点附近选 length 字节生成签名，CE 的 aobscanmodule 会忠实匹配 + 通配位置。
function ce_lua_hook.extract_aob_pattern(addr, length)
  local raw = readBytes(addr, length, true)
  if not raw then error(string.format('extract_aob_pattern: cannot read at %X', addr)) end
  local mask = {}  -- true = 通配
  for i = 1, length do mask[i] = false end

  -- 走指令边界，把每条指令的最后 4 字节（如果指令长度 ≥ 5）当作可能的 disp32/imm32 通配。
  -- 这是粗略启发式，对 RIP-relative call/jmp/lea/mov reg,imm32 都能命中；对 mov reg,reg 等短指令不动。
  local cur = addr
  while cur < addr + length do
    local sz = getInstructionSize(cur)
    if not sz or sz <= 0 then break end
    if sz >= 5 then
      local rel_start = cur - addr  -- 0-based
      for i = 0, 3 do
        local idx = rel_start + sz - 4 + i + 1  -- 1-based mask index
        if idx >= 1 and idx <= length then mask[idx] = true end
      end
    end
    cur = cur + sz
  end

  local out = {}
  for i = 1, length do
    if mask[i] then table.insert(out, '??')
    else table.insert(out, string.format('%02X', raw[i])) end
  end
  return table.concat(out, ' ')
end

-- ===== 模板脚本生成 =====

-- config = {
--   id = string,
--   addr = integer,
--   strategy = 'hardcode' | 'module' | 'aob',
--   aob_length = integer,                 -- 仅 strategy='aob'
--   xmm = bool, async = bool,
--   module_name = string, module_offset = integer,  -- strategy='module' 时填
-- }

local function build_address_block(config, orig_len, orig_bytes)
  local lines = {}
  local function add(s) table.insert(lines, s) end

  if config.strategy == 'hardcode' then
    add(string.format('define(INJECT, %X)', config.addr))
  elseif config.strategy == 'module' then
    add(string.format('define(INJECT, "%s"+%X)', config.module_name, config.module_offset))
  elseif config.strategy == 'aob' then
    local pattern = ce_lua_hook.extract_aob_pattern(config.addr, config.aob_length)
    -- module_name 在对话框校验阶段保证非空（AOB 策略必填）
    add(string.format('aobscanmodule(INJECT, %s, %s)', config.module_name, pattern))
  else
    error('unknown strategy: '..tostring(config.strategy))
  end
  return table.concat(lines, '\n')
end

function ce_lua_hook.build_enable_script(config)
  local orig_len, orig_bytes = ce_lua_hook.compute_orig_len(config.addr)
  local addr_block = build_address_block(config, orig_len, orig_bytes)
  local hex = ce_lua_hook.bytes_to_hex(orig_bytes)
  local nop_pad = orig_len - 5
  local nop_line = (nop_pad > 0) and string.rep('  nop\n', nop_pad):gsub('\n$', '') or ''
  local xmm_flag = config.xmm and 'true' or 'false'
  local async_flag = config.async and 'true' or 'false'

  -- 按目标位数选 DLL、ctxbuf 大小、回调示例代码
  local bits = config.bits or ce_lua_hook.target_bits()
  local dll, ctxbuf_size, sample_cb
  if bits == 64 then
    dll = 'luaclient-x86_64.dll'
    ctxbuf_size = '$200'
    sample_cb = "  -- 例: print(string.format('rax=%%X rip=%%X', ctx.rax, ctx.rip))\n"
              .."  -- 修改 ctx.rax / ctx.rcx ... 会在 hook 返回时写回真实寄存器\n"
              .."  -- 用 readBytes(ctx.rsp + N, ...) 读栈\n"
              .."  -- return 0 / nil  → 默认（执行原指令并继续）\n"
              .."  -- return <addr>   → 跳到该地址（绕过原指令；常见用法\n"
              ..[[  --                    return ctx.rip + 5  -- 跳过 5 字节原指令]]
  else
    dll = 'luaclient-i386.dll'
    ctxbuf_size = '$100'
    sample_cb = "  -- 例: print(string.format('eax=%%X eip=%%X', ctx.eax, ctx.eip))\n"
              .."  -- 修改 ctx.eax / ctx.ecx ... 会在 hook 返回时写回真实寄存器\n"
              .."  -- 用 readBytes(ctx.esp + N, ...) 读栈\n"
              .."  -- return 0 / nil  → 默认（执行原指令并继续）\n"
              .."  -- return <addr>   → 跳到该地址（绕过原指令；常见用法\n"
              ..[[  --                    return ctx.eip + 5  -- 跳过 5 字节原指令]]
  end

  return string.format([[
[ENABLE]
loadlibrary(%s)
%s
alloc(newmem,$1000,INJECT)
alloc(ctxbuf,%s)
alloc(hookid_str,64)
alloc(_lh_celua_init_unused,64)
label(hook_return)
label(hook_original)
registersymbol(INJECT)

// 触发 CE 自动 spawn server CELUASERVER<pid> + 写 CELUA_ServerName
// 全局到目标进程的 luaclient dll，否则 CELUA_ExecuteFunctionByReference
// 静默失败（pipe 连不上）。这个 {$LUACODE} 块不被执行（落在未引用的
// _lh_celua_init_unused alloc 区），CE 只取它的副作用。
_lh_celua_init_unused:
{$LUACODE}
{$ASM}
ret

hookid_str:
db '%s',0

newmem:
luahookpoint(%s)
hook_original:
db %s
jmp hook_return

INJECT:
jmp newmem
%s
hook_return:

{$lua}
if syntaxcheck then return end
ce_lua_hook.setup('%s', %d, %s, %s, function(ctx)
  -- TODO: 你的回调逻辑
%s
  -- 返回 false 跳过原指令（仅同步模式有效）
end)
{$asm}

[DISABLE]
INJECT:
db %s
unregistersymbol(INJECT)
//sleep 50ms 让 in-flight 线程走出 newmem（按需启用，DISABLE 后偶发崩溃时取消注释）
//  注：不要用 pause/unpause——pause 会暂停 newmem 内的线程，dealloc 后 unpause 就崩。
//  只需 INJECT 字节恢复（上面已做）+ sleep 即可。
//sleep(50)
dealloc(newmem)
dealloc(ctxbuf)
dealloc(hookid_str)
{$lua}
ce_lua_hook.cleanup('%s')
{$asm}
]],
  dll,
  addr_block,
  ctxbuf_size,
  config.id,
  config.id,
  hex,
  nop_line,
  config.id, bits, xmm_flag, async_flag,
  sample_cb,
  hex,
  config.id
  )
end

-- ===== 配置对话框 =====

-- 返回 config 表或 nil（取消）
function ce_lua_hook.show_config_dialog(default_addr, default_module)
  local form = createForm(false)
  form.Caption = 'Lua Hook Template'
  form.Width = 460
  form.Height = 380
  form.Position = 'poScreenCenter'
  form.BorderStyle = 'bsDialog'

  local function lbl(y, text)
    local l = createLabel(form); l.Top = y; l.Left = 12; l.Caption = text; return l
  end

  -- 目标位数（自动检测）
  local bits = ce_lua_hook.target_bits()
  local lblBits = createLabel(form); lblBits.Top = 12; lblBits.Left = 320
  lblBits.Caption = string.format('Target: %s', (bits == 64) and 'x64 (16 GPR)' or 'x86 (8 GPR)')

  -- ID
  lbl(12, 'Hook ID (唯一标识，用于符号前缀):')
  local edId = createEdit(form); edId.Top = 32; edId.Left = 12; edId.Width = 420
  edId.Text = string.format('hook_%06X', default_addr or 0)

  -- 策略
  lbl(64, '地址策略:')
  local rgStrategy = createRadioGroup(form)
  rgStrategy.Top = 84; rgStrategy.Left = 12; rgStrategy.Width = 300; rgStrategy.Height = 80
  rgStrategy.Items.add('硬编码 (define INJECT, addr)')
  rgStrategy.Items.add('模块偏移 ("game.exe"+offset)')
  rgStrategy.Items.add('AOB 签名 (aobscanmodule)')
  rgStrategy.ItemIndex = 0  -- 默认硬编码

  -- AOB 长度
  lbl(170, 'AOB 长度 (字节, 仅 AOB 策略):')
  local edAobLen = createEdit(form); edAobLen.Top = 190; edAobLen.Left = 12; edAobLen.Width = 80
  edAobLen.Text = '32'

  -- 模块名
  lbl(170, '                                          模块名 (模块偏移/AOB):')
  local edMod = createEdit(form); edMod.Top = 190; edMod.Left = 240; edMod.Width = 192
  edMod.Text = default_module or ''

  -- 选项
  local cbXmm = createCheckBox(form); cbXmm.Top = 230; cbXmm.Left = 12
  cbXmm.Caption = (bits == 64) and '保存 XMM (xmm0..xmm15)' or '保存 XMM (xmm0..xmm7)'
  local cbAsync = createCheckBox(form); cbAsync.Top = 252; cbAsync.Left = 12
  cbAsync.Caption = 'ASYNC (回调退化为只读、return false 不跳过原指令)'

  local lblWarn = createLabel(form); lblWarn.Top = 274; lblWarn.Left = 12
  lblWarn.Caption = ''
  cbAsync.OnChange = function() lblWarn.Caption = cbAsync.Checked
    and '⚠ 异步模式：写 ctx.rax 等不生效；return false 不再跳过原指令。' or '' end

  -- OK / Cancel
  local btnOk = createButton(form); btnOk.Top = 310; btnOk.Left = 280; btnOk.Width = 70
  btnOk.Caption = 'OK'; btnOk.ModalResult = 1  -- mrOk
  local btnCancel = createButton(form); btnCancel.Top = 310; btnCancel.Left = 360; btnCancel.Width = 70
  btnCancel.Caption = 'Cancel'; btnCancel.ModalResult = 2  -- mrCancel

  local mr = form.ShowModal()
  local config = nil
  if mr == 1 then
    -- 校验
    local id = edId.Text:gsub('^%s+', ''):gsub('%s+$', '')
    if #id == 0 or id:find('[^%w_]') then
      messageDialog('Hook ID 非法（需 [A-Za-z0-9_]，长度 1-63）', 0, 1)
    elseif ce_lua_hook._registry[id] ~= nil then
      messageDialog('Hook ID 已被占用：'..id, 0, 1)
    else
      config = {
        id = id,
        addr = default_addr,
        bits = bits,
        strategy = ({ [0]='hardcode', [1]='module', [2]='aob' })[rgStrategy.ItemIndex],
        aob_length = tonumber(edAobLen.Text) or 32,
        xmm = cbXmm.Checked,
        async = cbAsync.Checked,
        module_name = edMod.Text ~= '' and edMod.Text or nil,
      }
      if config.strategy == 'aob' and (config.module_name == nil or config.module_name == '') then
          messageDialog('AOB 策略需要填写模块名', 0, 1)
          config = nil
        end
        if config and config.strategy == 'module' then
          local base = getAddress(config.module_name)
          if not base or base == 0 then
            messageDialog('模块未找到: '..tostring(config.module_name), 0, 1)
            config = nil
          else
            config.module_offset = config.addr - base
            if config.module_offset < 0 then
              messageDialog('地址 '..string.format('%X', config.addr)..' 不在模块 '..config.module_name..' 内', 0, 1)
              config = nil
            end
          end
        end
    end
  end
  form.destroy()
  return config
end

-- ===== 启动注册 =====

-- CELUA_GetFunctionReferenceFromName 在 CE 主进程是 createRef 的同义包装。
-- __ce_lua_hook_trampoline 已是全局，createRef 拿到它的引用 id。
ce_lua_hook._trampoline_ref = createRef(__ce_lua_hook_trampoline)
print(string.format('[lua_hook_template] trampoline ref = %d', ce_lua_hook._trampoline_ref))

-- ===== AA 模板 handler =====

local function template_handler(script, sender)
  -- script 是 TStrings；sender 是 TFrmAutoInject
  -- 取当前 Memory Viewer 的光标地址作为默认 INJECT 地址
  local mv = getMemoryViewForm()
  local addr = mv and mv.DisassemblerView.SelectedAddress or 0
  -- 模块名猜测
  local mod = nil
  if addr > 0 then
    local ok, modname = pcall(getNameFromAddress, addr)
    if ok and type(modname) == 'string' then
      mod = modname:match('^([^%.]+%.[^+]+)') or modname  -- 截 "kernel32.dll" 部分
    end
  end

  local config = ce_lua_hook.show_config_dialog(addr, mod)
  if not config then return end

  local ok, scriptText = pcall(ce_lua_hook.build_enable_script, config)
  if not ok then
    messageDialog('生成脚本失败: '..tostring(scriptText), 0, 1)
    return
  end

  -- 直接覆盖编辑器内容（CE 模板的标准做法）
  script.Text = scriptText
end

if ce_lua_hook._template_id == nil then
  ce_lua_hook._template_id = registerAutoAssemblerTemplate(
    'Lua Hook (Ctx → Callback)', template_handler, 'Ctrl+Alt+L')
  print(string.format('[lua_hook_template] template registered, id=%d', ce_lua_hook._template_id))
end

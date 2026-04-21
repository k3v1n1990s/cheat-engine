-- lua_hook_template.lua
-- CE Auto Assembler 模板插件：在任意代码点生成 inline hook，保存上下文并回调 Lua。
-- Spec: docs/superpowers/specs/2026-04-21-ce-aa-lua-hook-plugin-design.md
-- Loaded automatically from bin/autorun/ on CE startup.

if ce_lua_hook ~= nil then
  -- 已加载过（autorun 重载），先清理旧注册项
  if ce_lua_hook._template_id then unregisterAutoAssemblerTemplate(ce_lua_hook._template_id) end
  if ce_lua_hook._command_registered then unregisterAutoAssemblerCommand('luahookpoint') end
end

ce_lua_hook = {}

-- ===== 上下文布局（单一事实源，ASM 展开器和 trampoline 都引用此表）=====
ce_lua_hook.LAYOUT = {
  -- GPR：16 个 8 字节整数寄存器
  rax = 0x00, rcx = 0x08, rdx = 0x10, rbx = 0x18,
  rsp = 0x20, rbp = 0x28, rsi = 0x30, rdi = 0x38,
  r8  = 0x40, r9  = 0x48, r10 = 0x50, r11 = 0x58,
  r12 = 0x60, r13 = 0x68, r14 = 0x70, r15 = 0x78,
  -- 控制
  rflags = 0x80,
  rip    = 0x88,  -- = hook_original 的地址，只读
  -- 0x90, 0x98 保留对齐
  -- XMM 区起点
  xmm0_off = 0xA0,
  -- 总大小
  size_no_xmm = 0xA0,
  size_with_xmm = 0x1A0,
}

-- GPR 字段顺序，trampoline diff 回写时按这个顺序遍历
ce_lua_hook.GPR_FIELDS = {
  'rax','rcx','rdx','rbx','rsp','rbp','rsi','rdi',
  'r8','r9','r10','r11','r12','r13','r14','r15',
}

-- 内部状态
ce_lua_hook._registry = {}        -- id → {fn, xmm, async}
ce_lua_hook._trampoline_ref = nil -- 启动时填
ce_lua_hook._template_id = nil
ce_lua_hook._command_registered = false

-- ===== 公共 API =====

function ce_lua_hook.setup(id, xmm, async, fn)
  assert(type(id) == 'string' and #id > 0, 'ce_lua_hook.setup: id must be non-empty string')
  assert(type(fn) == 'function', 'ce_lua_hook.setup: fn must be function')
  -- 幂等：先清理同 id 的旧条目（spec §4.2）
  ce_lua_hook.cleanup(id)
  ce_lua_hook._registry[id] = {
    fn = fn,
    xmm = xmm and true or false,
    async = async and true or false,
  }
  print(string.format('[lua_hook] setup id=%s xmm=%s async=%s', id, tostring(xmm), tostring(async)))
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

  local L = ce_lua_hook.LAYOUT
  local size = entry.xmm and L.size_with_xmm or L.size_no_xmm
  local raw = readBytes(ctxptr, size, true)
  if not raw then return 0 end  -- 目标已死

  -- 把 raw byte 数组按 8 字节小端拼回 qword
  local function rd_qword(off)
    local v = 0
    for i = 7, 0, -1 do v = v * 256 + raw[off + 1 + i] end
    return v
  end

  -- 构建 ctx 表
  local ctx = {}
  for _, name in ipairs(ce_lua_hook.GPR_FIELDS) do
    ctx[name] = rd_qword(L[name])
  end
  ctx.rflags = rd_qword(L.rflags)
  ctx.rip    = rd_qword(L.rip)
  if entry.xmm then
    ctx.xmm = {}
    for i = 0, 15 do
      ctx.xmm[i] = readBytes(ctxptr + L.xmm0_off + i * 16, 16, true)
    end
  end

  -- 快照 GPR + rflags 用于回写时 diff（避免无谓 writeQword）。xmm 不快照——见下方写回处的说明。
  local snap = {}
  for _, name in ipairs(ce_lua_hook.GPR_FIELDS) do snap[name] = ctx[name] end
  snap.rflags = ctx.rflags

  -- 调用用户回调
  local ok, skip = pcall(entry.fn, ctx)
  if not ok then
    print(string.format('[lua_hook %s] ERROR: %s\n%s', id, tostring(skip), debug.traceback()))
    return 0
  end

  -- async 模式跳过 diff 回写（spec §4.3）
  if not entry.async then
    for _, name in ipairs(ce_lua_hook.GPR_FIELDS) do
      if ctx[name] ~= snap[name] then writeQword(ctxptr + L[name], ctx[name]) end
    end
    if ctx.rflags ~= snap.rflags then writeQword(ctxptr + L.rflags, ctx.rflags) end
    -- rip 不回写（用户改 rip 我们也不实现跳转，spec §4.3）
    -- xmm 写回：启用 XMM 时无条件回写全部 16 个槽位（不做 byte-wise diff，
    -- 因为深拷贝 16×16 字节快照对每次 hook 命中都是无谓开销；高频 hook 应改用
    -- ASYNC 模式整段跳过回写）。
    if entry.xmm and ctx.xmm then
      for i = 0, 15 do
        if ctx.xmm[i] ~= nil then writeBytes(ctxptr + L.xmm0_off + i * 16, ctx.xmm[i]) end
      end
    end
  end

  return (skip == false) and 1 or 0
end

-- ===== AA 自定义命令: luahookpoint(<id>) =====

-- 生成 hook 点的 ASM 字符串。id 用作所有内部标号的前缀，避免多 hook 符号冲突。
-- xmm: 是否保存 XMM。async: 异步模式（trampoline 调用的 5th 参数）。
local function build_hook_asm(id, xmm, async, trampoline_refid)
  local L = ce_lua_hook.LAYOUT
  local async_flag = async and 1 or 0

  -- 各 hook 内部标号，全部以 id 为前缀
  local lbl = {
    save     = 'lh_'..id..'_save',
    restore  = 'lh_'..id..'_restore_exec',
    skip     = 'lh_'..id..'_skip',
    params   = 'lh_'..id..'_params',
    saved_rsp= 'lh_'..id..'_saved_rsp',  -- 给 r11 用的内存槽（若不用栈保存）
  }

  local lines = {}
  local function emit(s) table.insert(lines, s) end

  -- 预先 alloc params 数组（[ctxbuf, hookid_str]）和 saved_rsp 槽
  emit('alloc('..lbl.params..',16)')
  emit('alloc('..lbl.saved_rsp..',8)')
  emit(lbl.params..':')
  emit('  dq ctxbuf')
  emit('  dq hookid_str')
  emit('')

  -- ===== 保存 GPR =====
  emit(lbl.save..':')
  emit('  mov [ctxbuf+'..string.format('0x%X', L.rax)..'], rax')   -- 先保 rax
  emit('  mov rax, ctxbuf')                                         -- rax 变 scratch
  for _, r in ipairs(ce_lua_hook.GPR_FIELDS) do
    if r ~= 'rax' then
      emit(string.format('  mov [rax+0x%X], %s', L[r], r))
    end
  end
  -- rsp 此时和 hook 点一致（jmp 不改 rsp）
  -- 保存 rflags
  emit('  pushfq')
  emit('  pop qword ptr [rax+'..string.format('0x%X', L.rflags)..']')
  -- 保存 rip = hook_original
  emit('  lea rcx, [hook_original]')
  emit('  mov [rax+'..string.format('0x%X', L.rip)..'], rcx')

  if xmm then
    for i = 0, 15 do
      emit(string.format('  movdqu [rax+0x%X], xmm%d', L.xmm0_off + i*16, i))
    end
  end

  -- ===== 调 luaclient =====
  -- MS x64 ABI: rcx, rdx, r8, r9 是前 4 参数。需要 16 字节栈对齐 + 0x20 shadow。
  -- 用 r11 保存原 rsp，对齐 rsp，调完恢复。r11 是 volatile 已无用。
  emit('  mov ['..lbl.saved_rsp..'], rsp')
  emit('  and rsp, FFFFFFFFFFFFFFF0')
  emit('  sub rsp, 0x20')
  emit('  mov ecx, '..string.format('0x%X', trampoline_refid))
  emit('  mov edx, 2')
  emit('  lea r8, ['..lbl.params..']')
  emit('  mov r9d, '..async_flag)
  emit('  call CELUA_ExecuteFunctionByReference')
  emit('  mov rsp, ['..lbl.saved_rsp..']')

  -- rax = skip flag (0/1)
  -- 把 skip 暂存到 rflags 的"未用位"做条件? 不——更简单：直接根据 rax 跳转，
  -- 然后两条恢复路径分别恢复寄存器。
  emit('  test rax, rax')
  emit('  jnz '..lbl.skip)

  -- ===== 恢复并执行原指令 =====
  emit(lbl.restore..':')
  if xmm then
    for i = 0, 15 do
      emit(string.format('  movdqu xmm%d, [ctxbuf+0x%X]', i, L.xmm0_off + i*16))
    end
  end
  emit('  push qword ptr [ctxbuf+'..string.format('0x%X', L.rflags)..']')
  emit('  popfq')
  for _, r in ipairs(ce_lua_hook.GPR_FIELDS) do
    if r ~= 'rax' then
      emit(string.format('  mov %s, [ctxbuf+0x%X]', r, L[r]))
    end
  end
  emit('  mov rax, [ctxbuf+'..string.format('0x%X', L.rax)..']')   -- rax 最后恢复
  emit('  jmp hook_original')

  -- ===== 跳过原指令 =====
  emit(lbl.skip..':')
  if xmm then
    for i = 0, 15 do
      emit(string.format('  movdqu xmm%d, [ctxbuf+0x%X]', i, L.xmm0_off + i*16))
    end
  end
  emit('  push qword ptr [ctxbuf+'..string.format('0x%X', L.rflags)..']')
  emit('  popfq')
  for _, r in ipairs(ce_lua_hook.GPR_FIELDS) do
    if r ~= 'rax' then
      emit(string.format('  mov %s, [ctxbuf+0x%X]', r, L[r]))
    end
  end
  emit('  mov rax, [ctxbuf+'..string.format('0x%X', L.rax)..']')   -- rax 最后恢复
  emit('  jmp hook_return')

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

  local xmm   = ce_lua_hook.is_xmm(id)
  local async = ce_lua_hook.is_async(id)
  return build_hook_asm(id, xmm, async, ce_lua_hook._trampoline_ref)
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

-- ===== 启动注册 =====

-- CELUA_GetFunctionReferenceFromName 在 CE 主进程是 createRef 的同义包装。
-- __ce_lua_hook_trampoline 已是全局，createRef 拿到它的引用 id。
ce_lua_hook._trampoline_ref = createRef(__ce_lua_hook_trampoline)
print(string.format('[lua_hook_template] trampoline ref = %d', ce_lua_hook._trampoline_ref))

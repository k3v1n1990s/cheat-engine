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

  -- 快照（GPR + rflags；xmm 是 byte 表，diff 直接比 table identity 不可靠，下面用 element-wise 比较）
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
    if entry.xmm and ctx.xmm then
      for i = 0, 15 do
        if ctx.xmm[i] ~= nil then writeBytes(ctxptr + L.xmm0_off + i * 16, ctx.xmm[i]) end
      end
    end
  end

  return (skip == false) and 1 or 0
end

print('[lua_hook_template] loaded (skeleton)')

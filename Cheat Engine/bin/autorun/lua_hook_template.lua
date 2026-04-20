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

print('[lua_hook_template] loaded (skeleton)')

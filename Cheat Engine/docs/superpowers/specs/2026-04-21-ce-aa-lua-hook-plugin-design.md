# CE AA Lua Hook 模板插件 — 设计文档

**日期**：2026-04-21
**目标**：给 CE 加一个 Auto Assembler 模板插件，让用户在任意代码点生成一份 inline hook 脚本，hook 触发时**保存完整 CPU 上下文**（GPR/RFLAGS + 可选 XMM）并**回调用户定义的 Lua 函数**，回调可以读/写上下文、通过 RSP 自由访问栈，并可选择跳过原指令。

**交付物**：单个 Lua autorun 脚本 `bin/autorun/lua_hook_template.lua`，放入 CE 的 autorun 目录即装即用。不依赖 native DLL，不改动 CE 源码。

---

## 1. 架构

插件在 CE 启动时注册三项东西：

1. **AA 模板** — 通过 `registerAutoAssemblerTemplate("Lua Hook (Ctx → Callback)", handler, "Ctrl+Alt+L")`，在 Memory Viewer 的 Auto Assembler 里多一个菜单项。点击后弹对话框收集配置，往当前 AA 脚本里写入完整的 `[ENABLE]`/`[DISABLE]` 模板（一次模板 = 一个 hook 点，符合 CT 表习惯）。
2. **AA 自定义命令 `luahookpoint`** — 通过 `registerAutoAssemblerCommand("luahookpoint", expander)`。生成的模板里只有 `luahookpoint(<HookID>)` 一行，CE 在 AA parse 阶段调用 expander 把它展开成 60+ 行汇编（保存上下文、调 `CELUA_ExecuteFunctionByReference`、恢复、跳回）。
3. **全局 Lua 模块 `ce_lua_hook`** — 运行时注册表 + trampoline 函数，供注入代码通过 luaclient 回调。

### 1.1 生命周期

| 时机 | 动作 |
|---|---|
| CE 启动（autorun 加载）| 注册 template + command + 全局 trampoline 函数 |
| 用户 `Ctrl+Alt+L` | 弹对话框 → 写 AA 脚本文本（不激活）|
| `[ENABLE]` 执行 | AOB 扫 → alloc → `luahookpoint` 展开汇编 → `{$lua}` 块调 `ce_lua_hook.setup` 注册回调 → codecave 跳转写入 INJECT 地址 |
| 目标命中 hook | jmp newmem → 保存上下文 → 调 luaclient → trampoline 派发到用户回调 → diff 回写 → 恢复 → jmp 原指令或跳过 |
| `[DISABLE]` 执行 | 恢复原字节 → dealloc → `{$lua}` 清理注册表 |
| CE 关闭 | CE 自动反注册 template/command/模块 |

---

## 2. 组件

### 2.1 对话框 `show_config_dialog(addr) → config | nil`
Memory Viewer 当前地址预填。5 个字段：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| Hook ID | string | `hook_<hex6>` | 唯一标识，用于脚本内符号前缀和 Lua 回调表 key |
| 地址策略 | radio | AOB | `硬编码` / `模块偏移` / `AOB` |
| AOB 长度 | slider 20-64 | 32 | 仅 AOB 模式可见 |
| Save XMM | checkbox | off | 勾选则保存 xmm0..xmm15（ctxbuf 从 `$A0` 扩到 `$1A0`）|
| ASYNC | checkbox | off | 勾选则 `CELUA_ExecuteFunctionByReference` 的 async=1；下方显示警告"callback 退化为只读，`return false` 不再跳过原指令" |

取消返回 `nil`，模板不生成。

### 2.2 模板生成器 `generate_script(config, tstrings)`
往 CE 传进来的 `TStrings` 里追加完整脚本。结构示意：

```
[ENABLE]
{aobscanmodule/alloc/define 视策略不同}
alloc(newmem,$1000,INJECT)
alloc(ctxbuf,$200)                    // XMM 开/关都 $200，避免判分支
alloc(hookid_str,64)
label(hook_return)
label(hook_original)
registersymbol(INJECT)

hookid_str:
db '<HookID>',0

newmem:
luahookpoint(<HookID>)                // ← 自定义命令展开点
hook_original:
<原 N 字节指令>
jmp hook_return

INJECT:
jmp newmem
{nop 补齐到 N 字节}
hook_return:

{$lua}
if syntaxcheck then return end
ce_lua_hook.setup('<HookID>', <XMM_flag>, <ASYNC_flag>, function(ctx)
  -- TODO: 你的回调逻辑
  -- 例: print(string.format('rax=%X rip=%X', ctx.rax, ctx.rip))
  -- 返回 false 跳过原指令（仅同步模式有效）
end)
{$asm}

[DISABLE]
INJECT:
db <原 N 字节>
unregistersymbol(INJECT)
//sleep 50ms 让线程走出 newmem
dealloc(newmem)
dealloc(ctxbuf)
dealloc(hookid_str)
{$lua}
ce_lua_hook.cleanup('<HookID>')
{$asm}
```

**原指令长度**：从 INJECT 地址起连续 `disassemble` 直到累计 ≥ 5 字节（x64 `jmp rel32` 最短）。多出的字节用 `nop` 填充。

### 2.3 AA 命令展开器 `luahookpoint_expander(params, syntaxcheck)`
`params` 是 `'<HookID>'`。
- `syntaxcheck == 1`：校验 ID 字符集合法（`[A-Za-z0-9_]+`，长度 1-63），不生成代码。错误返回 `nil, "[luahookpoint] invalid id: <id>"`。
- `syntaxcheck == 2`：查 `ce_lua_hook._xmm_enabled[id]` 和 `ce_lua_hook._async[id]` 决定分支；返回多行字符串，内容为 2.5 的汇编。

### 2.4 Lua 运行时模块 `ce_lua_hook`

**模块状态**（CE 主进程内）：

```lua
ce_lua_hook._registry    = {}   -- id → {fn=function, xmm=bool, async=bool}
ce_lua_hook._xmm_enabled = {}   -- expander 查
ce_lua_hook._async       = {}   -- expander 查
ce_lua_hook._trampoline_ref = nil  -- CELUA_GetFunctionReferenceFromName 查好的 id
```

**对外 API**：

- `setup(id, xmm, async, fn)` — 注册回调。先 `cleanup(id)` 保证幂等（§4.2），再写三张表。`assert(type(fn) == 'function')`。
- `cleanup(id)` — 从三张表删除；`_registry[id]` 不存在时静默无操作。
- `__ce_lua_hook_trampoline(ctxptr, hookidptr)` — **全局 Lua 函数**（一次注册，全局复用）。注入代码实际调的就是它。逻辑见 §3.3。

### 2.5 上下文布局 `ce_lua_hook.LAYOUT` — 单一事实源
ASM 展开器和 trampoline 都只查这张表。

| offset | 字段 | 大小 | 备注 |
|---|---|---|---|
| 0x00 | rax | 8 | |
| 0x08 | rcx | 8 | |
| 0x10 | rdx | 8 | |
| 0x18 | rbx | 8 | |
| 0x20 | rsp | 8 | hook 触发点的 rsp（进入 newmem 前、push 前的值）|
| 0x28 | rbp | 8 | |
| 0x30 | rsi | 8 | |
| 0x38 | rdi | 8 | |
| 0x40..0x78 | r8..r15 | 8×8 | |
| 0x80 | rflags | 8 | `pushfq; pop [ctxbuf+0x80]` |
| 0x88 | rip | 8 | = `hook_original` 的地址（Lua 可读，不可改）|
| 0x90 | reserved | 8 | 对齐 |
| 0x98 | reserved | 8 | 对齐 |
| 0xA0..0x19F | xmm0..xmm15 | 16×16 | 仅 XMM 开启时有效，`movdqa` 需 16 字节对齐 |

总大小：XMM 关 `0xA0`，XMM 开 `0x1A0`。ctxbuf 恒 `alloc($200)`。

---

## 3. 数据流

### 3.1 模板生成（设计期，CE GUI 线程）
```
Ctrl+Alt+L
  ↓
handler 从 Memory Viewer 取光标地址
  ↓
show_config_dialog → config
  ↓
(AOB 策略) 读 INJECT 邻域字节 → 生成特征码（自动把 RIP-relative disp32、立即数 imm32 通配为 ??）
  ↓
(原指令长度) 连续 disassemble → 计 origLen + origBytes
  ↓
generate_script → 追加到 TStrings
```
此阶段只做文本生成，不碰目标进程。

### 3.2 ENABLE（目标进程已附加）
CE 的 AA 执行器走 4 phase：`aaInitialize / aaPhase1 / aaPhase2 / aaFinalize`（见 `cepluginsdk.pas:21`）。

```
aaInitialize
  ↓ 分配 newmem/ctxbuf/hookid_str
aaPhase1  ← luahookpoint expander 语法检查（syntaxcheck=1）
  ↓ AOB 扫描定位 INJECT
aaPhase2  ← luahookpoint expander 生成汇编（syntaxcheck=2）
  ↓ {$lua} 调 ce_lua_hook.setup 注册回调到 _registry
  ↓ CE 汇编 newmem 内容
  ↓ INJECT 处写 jmp newmem + nop 填充
aaFinalize
```
任何一步失败 CE 回滚整脚本，ctxbuf/newmem 由 AA 引擎回收。

### 3.3 运行时命中 hook — 核心流程

**目标进程侧（汇编骨架）**：

```
; INJECT 处被写成 jmp newmem
; ---- newmem ----
mov [ctxbuf+0x00], rax        ; 优先保 rax，后续用作 scratch
mov rax, ctxbuf
mov [rax+0x08], rcx
mov [rax+0x10], rdx
... (rbx, rsp-需修正因 jmp 不改栈, rbp, rsi, rdi, r8..r15)
pushfq
pop qword [rax+0x80]
lea rcx, [hook_original]
mov [rax+0x88], rcx
{XMM 开启:}
  movdqa [rax+0xA0], xmm0
  ... (xmm1..xmm15)

; 调 luaclient trampoline
sub rsp, 0x28                 ; shadow space + 16 字节对齐
mov ecx, <trampoline_refid>   ; 展开期嵌入常量；autorun 启动时 CELUA_GetFunctionReferenceFromName('__ce_lua_hook_trampoline') 查好
mov edx, 2                    ; paramcount
lea r8, [params_array]        ; params_array = [ctxbuf, hookid_str]（qword×2，可 alloc 在 newmem 尾部）
mov r9d, <async_flag>         ; 0/1
call CELUA_ExecuteFunctionByReference
add rsp, 0x28

; rax = skip flag（0=执行原指令，1=跳过）
test rax, rax
mov rax, [ctxbuf+0x00]        ; 提前恢复 rax 用作对比？不——先判断后恢复
...                           ; 实际顺序：先保留 rax 的 skip 返回值到临时位，再恢复所有寄存器
jnz _skip_original

_restore_and_exec_original:
{XMM 开启:}
  movdqa xmm0, [ctxbuf+0xA0]
  ... (xmm1..xmm15)
push qword [ctxbuf+0x80]
popfq
mov rcx, [ctxbuf+0x08]
... (所有 16 GPR 恢复，rax 最后)
mov rax, [ctxbuf+0x00]
jmp hook_original

_skip_original:
{同样恢复 XMM / flags / GPR}
jmp hook_return

hook_original:
<原 N 字节指令>
jmp hook_return
```

**注意**：保存/恢复的精确寄存器顺序、rsp 补偿、skip 返回值的临时落位需要实现阶段细化。关键约束是调 `call CELUA_ExecuteFunctionByReference` 前 **rsp 16 字节对齐**，且 Microsoft x64 calling convention 要 shadow space。

**CE 主进程侧（trampoline 伪代码）**：

```lua
function __ce_lua_hook_trampoline(ctxptr, hookidptr)
  local id = readString(hookidptr, 63)
  local entry = ce_lua_hook._registry[id]
  if not entry then return 0 end                    -- DISABLE 竞态，安全返回

  local L = ce_lua_hook.LAYOUT
  local size = entry.xmm and 0x1A0 or 0xA0
  local raw = readBytes(ctxptr, size, true)
  if not raw then return 0 end                      -- 目标进程已死

  local ctx = {}
  for field, off in pairs(L.FIELDS) do
    ctx[field] = qword_from_bytes(raw, off)
  end
  if entry.xmm then
    ctx.xmm = {}
    for i = 0, 15 do
      ctx.xmm[i] = readBytes(ctxptr + 0xA0 + i * 16, 16, true)
    end
  end
  local snapshot = shallow_copy(ctx)

  local ok, skip = pcall(entry.fn, ctx)
  if not ok then
    print(string.format('[hook %s] ERROR: %s\n%s', id, tostring(skip), debug.traceback()))
    return 0
  end

  if not entry.async then                            -- async 模式跳过回写
    for field, off in pairs(L.FIELDS) do
      if field ~= 'rip' and ctx[field] ~= snapshot[field] then
        writeQword(ctxptr + off, ctx[field])
      end
    end
    if entry.xmm and ctx.xmm then
      for i = 0, 15 do
        if ctx.xmm[i] ~= snapshot.xmm[i] then
          writeBytes(ctxptr + 0xA0 + i * 16, ctx.xmm[i])
        end
      end
    end
  end

  return (skip == false) and 1 or 0
end
```

### 3.4 DISABLE
```
[DISABLE] 执行
  ↓ INJECT 写回原字节
  ↓ unregistersymbol / sleep 50ms 建议保留 / dealloc
  ↓ {$lua} → ce_lua_hook.cleanup(id)
```
DISABLE 竞态（线程仍在 newmem 内）由 `sleep` 缓解；trampoline 在 `_registry[id]` 为空时返回 0 不影响目标行为。

### 3.5 关键不变量
- **LAYOUT 是单一事实源**，展开器和 trampoline 只引用它。
- **注入代码永远不直接 call Lua 函数**，只 call `CELUA_ExecuteFunctionByReference` + 固定 trampoline refid。
- **DISABLE 顺序**：先恢复字节 → sleep → dealloc，避免线程在 newmem 里被 dealloc 掉。

---

## 4. 错误处理

### 4.1 设计期（对话框/生成器）

| 场景 | 处理 |
|---|---|
| Hook ID 冲突（`_registry` 已存在）| 对话框红字实时校验，不允许确定 |
| 地址不可读 | `readBytes` 试读失败 → 提示 `地址不可访问` |
| 原地址非合法指令边界 | 连续 `disassemble` 全返回非法 opcode → 提示并取消 |
| AOB 特征码全通配字节过多 | 自动把长度 +8 重扫；仍失败则降级为"模块偏移"策略 |

### 4.2 ENABLE 时（AA 执行器）
CE 的 AA 是事务性的——任一行失败全脚本回滚。我们不吞错误：

| 场景 | 处理 |
|---|---|
| `luahookpoint` phase=1 ID 非法 | 返回 `nil, msg`，CE 弹错 |
| AOB 零/多匹配 | CE 原生报错，不捕获 |
| luaclient dll 加载失败 | ENABLE 开头 `loadlibrary(luaclient-x86_64.dll)`，失败 CE 报错 |
| `{$lua}` 里 `setup()` 抛错 | `assert(type(fn)=='function')` 等前置校验，AA 引擎传出 |

**幂等保证**：`setup(id,...)` 内部先调 `cleanup(id)` 再写表，避免脚本被中断重跑时残留旧回调。

### 4.3 运行时（hook 命中）
ASM 层不做错误处理（没法做），全部边界在 Lua trampoline：

| 场景 | 处理 |
|---|---|
| `_registry[id]` 不存在（DISABLE 竞态）| 返回 0 |
| 用户 fn 抛 Lua 错误 | `pcall` 捕获，`print` 带 traceback。**不弹框不 assert**（高频 hook 弹框会卡死 GUI）|
| fn 返回非 bool | 只有 `false` 当 skip，其他一律不跳过 |
| fn 修改 `ctx.rsp` | 允许；文档警告用户自负 |
| ASYNC 模式下写 ctx | diff 回写阶段整段跳过，写不生效但不报错（对话框已警告）|
| 目标进程中途终止 | `readBytes` 返回 nil → 记日志 → 返回 0 |

### 4.4 DISABLE 时

| 场景 | 处理 |
|---|---|
| 原字节已被外部改过 | CE 标准行为，文档提醒"DISABLE 强制恢复" |
| 线程仍在 newmem | 模板里留注释 `//sleep 50ms` 供用户按需启用。硬解（suspend 全线程）不做 |
| `cleanup(id)` 时已不存在 | 幂等无操作 |

### 4.5 原则总结
1. 设计期严格校验（容易改）；
2. ENABLE 让 CE 原生错误冒泡（事务性）；
3. 运行时绝不抛、绝不弹框、绝不杀进程——Lua 错误只打 log；
4. DISABLE 的线程赛跑用 sleep 缓解、不硬解。

---

## 5. 开放问题（实现阶段再定）

- 汇编里保存 rax 的精确顺序（rax 既是 scratch 又要保存的老问题），以及 rsp 值是否需要修正补偿 `jmp newmem` 本身的 rsp 变化（答：`jmp` 不改 rsp，所以直接存就是 hook 点的 rsp）。
- **rsp 16 字节对齐**：调 `CELUA_ExecuteFunctionByReference` 前需满足 MS x64 ABI 对齐（call 指令执行时 `rsp mod 16 == 0`）。hook 点的 rsp 对齐状态未知——函数 prologue 前通常不对齐（因 call 刚压了 8 字节返回地址），prologue 后对齐。方案：先 `mov r11, rsp; and rsp, -0x10; sub rsp, 0x20`（shadow space），call 之后 `mov rsp, r11`。r11 选择因 MS x64 ABI 视为 volatile 且此时已入 ctxbuf 保存。
- `trampoline_refid` 在 autorun 加载完成前如果有脚本被激活怎么办——answer：模板 ENABLE 头部加一行 `assert_trampoline_ready()` 检查 `ce_lua_hook._trampoline_ref ~= nil`，未就绪则失败，要求用户重启 CE。
- `params_array` 的生命周期：放 newmem 末尾（随 newmem 一起 dealloc），还是单独 alloc。倾向前者，少一个 alloc 调用。
- XMM 场景下 `ctxbuf` 的 16 字节对齐如何保证：CE 的 `alloc` 对 $1000+ 的段自然页对齐，但 ctxbuf 只 $200。办法：alloc 时要 `alloc(ctxbuf, $200, newmem)`（近 newmem 的 $1000 段内部对齐到 16），或直接 `alloc($300)` 留足 padding。

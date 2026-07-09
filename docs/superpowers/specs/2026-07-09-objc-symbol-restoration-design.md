# ObjC 符号还原（Symbol Restoration）设计

- **日期**: 2026-07-09
- **状态**: 已批准，待写实现计划
- **目标**: 从被逆向的解密 IPA 中提取可用符号，烤回 App 主二进制，使 Xcode/LLDB 调试时栈帧显示 Objective-C 类名/方法名，而非裸地址或 `___lldb_unnamed_symbol$$0x...`。

## 背景与动机

砸壳 IPA 的主二进制通常被 `strip` 过，但 **Objective-C 运行时元数据永远保留**（`__objc_classname` / `__objc_methname` / `__objc_classlist` 等 section，动态派发所需）。这些数据可被解析并写回 Mach-O 的 `LC_SYMTAB`，从而让所有读取符号表的工具（LLDB 栈帧、Instruments、`atos`、`nm`）显示真实名字。

`restore-symbol`（tobefuturer 及其 fork）正是做这件事的成熟工具：解析 ObjC 元数据 → 生成 `nlist` 符号项 → 重写符号表。

### 基线认知（重要）
- LLDB 挂上**活进程**时，其 ObjC language runtime plugin 已能从进程内元数据解析出 `-[Class method]`，很多 ObjC 栈帧本就不难看。
- 本方案的增量价值：把符号**持久化进二进制**，让 Instruments、崩溃符号化、离线 `atos`、以及运行时解析失败的场景也能显示名字；并为后续 C/Swift 符号还原（Ghidra→dSYM）铺好架构。
- **本方案不覆盖** C/C++/Swift 静态函数——那些名字被 strip，只能靠反汇编器分析恢复，留作扩展点。

## 范围（v1）

**做**：
- 仅 Objective-C 符号还原，通过内置预编译 `restore-symbol`。
- 只处理 App 主可执行文件（`Payload/<App>.app/<CFBundleExecutable>`）。
- 在 IPA→项目流程中**一次性**执行，把符号烤进 Payload 主二进制。
- 可插拔的 provider 架构，为将来加 C/Swift（Ghidra→dSYM）留扩展点。
- 默认开启，可关闭；失败非致命。

**不做（YAGNI，留作扩展点）**：
- 不处理内嵌 `Frameworks/`（App 私有 framework 里也有 ObjC 类，但会显著拉长耗时；主二进制已覆盖大部分栈帧）。
- 不做 C/C++/Swift 静态函数还原（需 Ghidra/IDA headless 分析生成 dSYM）。
- 不做 Swift demangle 展示层处理。

## 架构

### 集成点

在 `fakeapp.sh` 的 `main()` 中新增一步 `restore_symbols()`：

```
main()
  ├─> extract_ipa()
  ├─> prepare_packed_files()
  ├─> replace_files()
  ├─> copy_app_to_payload()     # .app 已进 Payload/，扩展已删
  ├─> update_info_plist()
  ├─> restore_symbols()   ← 新增：对 Payload 主二进制烤 ObjC 符号
  └─> migrate_target()
```

放在 `copy_app_to_payload()` 之后（二进制已就位、PlugIns/Watch/Extensions 已删），`migrate_target()` 之前。相对 `update_info_plist()` 的顺序不敏感（后者不碰二进制），置于其后以求流程清晰。

### 为什么这个时机可行（签名）

restore-symbol 修改 Mach-O 会使原有代码签名失效——但这无所谓：
- Payload 二进制不由本工具签名；Xcode 构建时 `replace_app.sh` 把它拷到构建产物、删除 `embedded.mobileprovision`，末尾由 Xcode CodeSign 阶段重新签名。
- 因此一个签名失效的 Payload 二进制在下一次构建时会被重签，完全自洽。

### 可插拔 provider 结构

`restore_symbols()` 作为 dispatcher，v1 只注册一个 provider：

```
restore_symbols()
  └─> symbolize_objc "$main_binary"   # 调用内置 restore-symbol
```

将来扩展（非本次范围）：新增 `symbolize_native "$main_binary"`（Ghidra headless → dSYM）并在 dispatcher 中注册，主流程与既有 provider 不变。不引入过度抽象——就是一个边界清晰的函数 + 一处文档化扩展位。

### 引擎打包

- 预编译的 `restore-symbol`（universal：arm64 + x86_64，兼容 Apple Silicon 与 Intel Mac）放入 `fakesample/scripts/restore-symbol`，`chmod +x`。
- 随 `fakesample/` 被 `build.sh` 打包（`tar czvf ... fakesample` → base64 → 嵌入 `fakesample_package` 变量）进 `bin/fakeapp`，与 `arm64-to-sim`、`optool` 同一机制。
- 运行时 `prepare_packed_files()` 把模板解包到临时目录，引擎路径为 `<temp>/fakesample/scripts/restore-symbol`。
- **选型约束**：优先选择维护活跃、明确支持 **arm64e + chained fixups（iOS 15+）** 的 restore-symbol fork 来构建二进制。

## 行为规格

### 开关
- **默认开启**，用户无感。
- `--no-symbols` 命令行参数显式关闭。
- `FAKEAPP_NO_SYMBOLS=1` 环境变量兜底关闭。
- 两者任一为「关」即跳过 `restore_symbols()`。

### 失败降级（非致命）
- 符号还原是锦上添花，**绝不能中断转项目主流程**。
- `symbolize_objc` 任何错误（引擎缺失、二进制不支持、写入失败）只 `echo` 警告并 `return 0`，`main()` 继续。
- 结束时打印一行结果，例如：
  - 成功：`[symbols] restored 4213 ObjC symbols into WeChat`
  - 跳过：`[symbols] skipped (unsupported binary / arm64e chained fixups)`
  - 关闭：`[symbols] disabled (--no-symbols)`

### arm64e 降级
- 若选定 fork 无法处理某二进制的 arm64e/chained fixups，自动 skip 该二进制并提示，其余流程正常——仍是净增益（不会让老格式二进制失去符号，也不会让 arm64e 报错中断）。

## 关键风险与验证（硬性）

**风险**：现代 App Store 应用（如微信）是 arm64e、iOS 15+ chained fixups。经典 restore-symbol 对该格式历史上会崩溃或写坏符号表。

**验证任务（不过则方案不算落地）**：
1. 取一个**真·解密的 arm64e 二进制**（仓库内 `WeChat.app` 是空壳加密态，不可用；需另找）。
2. 跑 `restore-symbol` → 用 `nm` 确认 `t/T` 函数符号数量显著增加、含 ObjC 方法名。
3. 生成完整 fakeapp 项目 → Xcode 构建运行 → 在 LLDB / Xcode 栈帧中确认显示 `-[Class method]` 而非 `unnamed_symbol`。
4. 若选定 fork 也搞不定 arm64e，落实「arm64e 自动 skip + 提示」的降级路径并验证其不中断主流程。

## 受影响文件

- `fakeapp.sh`：新增 `restore_symbols()` + `symbolize_objc()`；`main()` 插入调用；参数解析支持 `--no-symbols`；`FAKEAPP_NO_SYMBOLS` 处理。
- `fakesample/scripts/restore-symbol`：新增预编译二进制（universal）。
- `build.sh`：无需改动（`fakesample/` 整体打包，二进制自动包含）——需确认打包后可执行位保留。
- `CLAUDE.md`：在 `main()` 函数流、脚本说明中记录新步骤与开关。
- `README.md`：文档化符号还原特性与 `--no-symbols`。

## 未来扩展点（非本次范围）

- **C/Swift 静态函数**：新增 `symbolize_native` provider，用 Ghidra headless 分析恢复函数边界/名字 → 生成按 `LC_UUID` 匹配的 symbol-only dSYM，随项目输出；做成 `--symbolicate-native` 开关（耗时数分钟，不默认开）。
- **私有 Frameworks**：把 `symbolize_objc` 扩展到遍历 `Payload/<App>.app/Frameworks/*.framework` 与 `*.dylib`。
- **Swift demangle 展示**：还原出的 mangled 名过一遍 `swift-demangle`。

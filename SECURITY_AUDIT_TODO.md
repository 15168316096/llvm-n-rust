# llvm-n-rust 安全审计 TODO

> 版本: v1.1 | 最后更新: 2026-03-02 | 状态: 已完成（含 CKB RFCs 交叉审计）

## 项目概况
- 语言: Dockerfile
- 类型: CKB 智能合约可复现构建环境（Docker 镜像）
- 依赖数: 3（buildpack-deps:bookworm, LLVM 19.1.7, Rust 1.85.1）
- 源文件数: 1（bookworm-18.dockerfile）
- 现有测试数: 0
- **CKB 特殊说明**: 本项目为 CKB 智能合约构建工具链，CKB VM (RISC-V) 原生支持非对齐内存访问，因此**内存对齐相关问题不在本次审计范围内**。
- **CKB RFCs 交叉审计**: 已完成与 [nervosnetwork/rfcs](https://github.com/nervosnetwork/rfcs/tree/master/rfcs) 的规范一致性比对。

## 审计进度
- 总 TODO 项: 15
- ✅ 已完成: 15 | ❌ 发现问题: 10 | ⏳ 待审计: 0

---

## 第 1 章: DIM-DEPS — 供应链与依赖安全

- [!] 🔴 **AUDIT-DEPS-001**: LLVM Tarball 下载后未验证完整性
  - **关联代码**: bookworm-18.dockerfile:8,13
  - **审计内容**:
    - curl 下载 LLVM 源码是否验证了 SHA256/签名
    - sha256sum 结果是否与已知正确值比对
  - **现有覆盖**: 无测试
  - **发现记录**: ❌ `sha256sum` 仅保存到文件，从未与已知哈希比对验证。攻击者可通过 DNS 劫持/CDN 投毒/MITM 替换 tarball，植入编译器后门（Trusting Trust Attack），影响所有下游 CKB 智能合约。

- [!] 🔴 **AUDIT-DEPS-002**: Rustup 通过 Pipe-to-Shell 安装
  - **关联代码**: bookworm-18.dockerfile:38-39
  - **审计内容**:
    - 远程脚本是否先下载后验证再执行
    - TLS 配置是否足够（已用 --proto '=https' --tlsv1.2）
  - **现有覆盖**: 无测试
  - **发现记录**: ❌ `curl | sh` 直接管道执行远程脚本，无完整性校验。虽使用 HTTPS+TLS1.2 缓解了部分风险，但仍无法防御 rustup.rs 服务器被入侵的场景。以 root 权限执行。

- [!] 🟠 **AUDIT-DEPS-003**: 基础镜像未锁定 Digest
  - **关联代码**: bookworm-18.dockerfile:1,28
  - **审计内容**:
    - FROM 指令是否使用 @sha256: digest 锁定
    - 标签是否可变（可被 Docker Hub 重新指向）
  - **现有覆盖**: 无测试
  - **发现记录**: ❌ 使用 `buildpack-deps:bookworm` 标签而非 digest。Docker tag 是可变的，不同时间 pull 可能获取不同镜像层，破坏可复现性，且存在 tag 劫持风险。

- [x] 🟡 **AUDIT-DEPS-004**: apt 包未锁定版本
  - **关联代码**: bookworm-18.dockerfile:4,31
  - **审计内容**:
    - apt-get install 的包是否锁定了具体版本
    - cmake 版本是否可能引入不兼容变更
  - **现有覆盖**: 无测试
  - **发现记录**: ⚠️ `apt-get install -y cmake` 未指定版本号。不同时间构建可能安装不同版本的 cmake，影响可复现性。风险较低，因 cmake 向后兼容性良好。

---

## 第 2 章: DIM-LOGIC — 业务逻辑

- [!] 🟠 **AUDIT-LOGIC-001**: 版本命名不匹配 (LLVM 19 → `-18` 后缀)
  - **关联代码**: bookworm-18.dockerfile:34
  - **审计内容**:
    - 符号链接后缀 `-18` 是否与实际 LLVM 版本 19.1.7 匹配
    - 下游脚本依赖 `clang-18` 时实际调用的是否是正确版本
  - **现有覆盖**: 无测试
  - **发现记录**: ❌ `find /llvm/bin -not -type d -exec ln -s {} {}-18 \;` 为所有 LLVM 二进制创建 `-18` 后缀的符号链接，但安装的是 LLVM **19**.1.7。这导致 `clang-18` 实际指向 clang 19，可能导致依赖版本检测的构建脚本失败或产生意外行为。**疑似为版本升级时未同步更新的遗留 Bug**。

- [x] 🟢 **AUDIT-LOGIC-002**: 硬编码构建并行度
  - **关联代码**: bookworm-18.dockerfile:24-25
  - **审计内容**:
    - `make -j2` vs 注释掉的 `make -j$(nproc)` 的影响
  - **现有覆盖**: 无测试
  - **发现记录**: ⚠️ 注释掉了 `make -j$(nproc)` 替换为 `make -j2`。可能是为了控制内存使用（LLVM 编译内存消耗大），但在大型机器上效率低下。非安全问题，但影响构建体验。

---

## 第 3 章: DIM-CONTAINER — 容器安全

- [!] 🟠 **AUDIT-CONTAINER-001**: 容器以 root 权限运行
  - **关联代码**: bookworm-18.dockerfile (全文)
  - **审计内容**:
    - 是否有 USER 指令切换到非 root 用户
    - Rust 安装到 /root/.cargo/bin 是否必须 root
  - **现有覆盖**: 无测试
  - **发现记录**: ❌ 无 `USER` 指令，默认 root 运行。Rust 工具链安装在 `/root/.cargo/bin`，绑定了 root 用户。如果容器内执行了不受信任的代码，攻击者将获得 root 权限。对于构建环境，此风险需评估。

- [!] 🟡 **AUDIT-CONTAINER-002**: apt 缓存未清理，安装了推荐包
  - **关联代码**: bookworm-18.dockerfile:4,31
  - **审计内容**:
    - 是否使用 `--no-install-recommends`
    - 是否清理 `/var/lib/apt/lists/*`
  - **现有覆盖**: 无测试
  - **发现记录**: ❌ 未使用 `--no-install-recommends`，未清理 apt 缓存。增大镜像体积，安装了不必要的推荐包，扩大攻击面。

- [x] 🟡 **AUDIT-CONTAINER-003**: 使用已弃用的 MAINTAINER 指令
  - **关联代码**: bookworm-18.dockerfile:2,29
  - **审计内容**:
    - MAINTAINER 是否已弃用
  - **现有覆盖**: N/A
  - **发现记录**: ⚠️ `MAINTAINER` 在 Docker 1.13+ 已弃用，应使用 `LABEL maintainer=`。未来 Docker 版本可能移除支持。

- [x] 🟢 **AUDIT-CONTAINER-004**: Dockerfile 层数优化
  - **关联代码**: bookworm-18.dockerfile:6,12-14,16,25-26,42
  - **审计内容**:
    - 多个 RUN 指令是否可合并以减少层数
  - **现有覆盖**: N/A
  - **发现记录**: ⚠️ 存在多个可合并的 RUN 层（如 mkdir + sha256sum + tar, make + make install）。非安全问题，但增大镜像体积。

---

## 第 4 章: DIM-ERRINFO — 错误处理

- [x] 🟡 **AUDIT-ERRINFO-001**: 下载失败无显式错误处理
  - **关联代码**: bookworm-18.dockerfile:8,38
  - **审计内容**:
    - curl 下载失败时 Docker 构建是否会终止
    - 是否使用了 `-f` (fail) 选项
  - **现有覆盖**: 无测试
  - **发现记录**: ⚠️ 第8行的 `curl -LO` 未使用 `-f` (fail on HTTP errors)。如果服务器返回 404 但状态码被重定向页面替代，curl 可能下载一个 HTML 错误页面而非 tarball，后续 `tar xzf` 会失败。第38行的 curl 使用了 `-f` 隐含在 `-sSf` 中，处理较好。Docker RUN 指令默认在命令返回非零时失败，提供了基础保障。

---

## 第 5 章: DIM-MEMORY — 内存与资源安全

> **CKB 审计特别说明**: CKB VM 基于 RISC-V 架构，原生支持非对齐内存访问（unaligned memory access），因此本章**排除内存对齐相关问题**。此决策基于 CKB VM 的实现特性，不影响其他维度的审计。

- [x] 🟢 **AUDIT-MEMORY-001**: 构建环境资源消耗
  - **关联代码**: bookworm-18.dockerfile:25
  - **审计内容**:
    - LLVM 编译的内存/磁盘消耗是否可控
    - 是否存在 OOM 风险
  - **现有覆盖**: N/A
  - **发现记录**: ✅ `make -j2` 限制了并行度，有效控制了内存消耗。LLVM 编译每个并行任务可消耗 2-4GB 内存，`-j2` 是合理的资源控制。无安全问题。

---

## 第 6 章: DIM-SPEC — CKB RFCs 规范一致性

> **审计方法**: 将 Dockerfile 中的工具链配置与 [CKB RFCs](https://github.com/nervosnetwork/rfcs/tree/master/rfcs) 规范进行交叉比对，检查 ISA 扩展、VM 版本兼容性、cycle 优化等方面的一致性。

- [!] 🟠 **AUDIT-SPEC-001**: Rust Target 包含 "A" 原子扩展，限制 CKB VM 兼容性
  - **关联代码**: bookworm-18.dockerfile:39
  - **关联 RFCs**: [RFC 0003 (CKB-VM)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0003-ckb-vm/0003-ckb-vm.md), [RFC 0051 (CKB2023)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0051-ckb2023/0051-ckb2023.md)
  - **审计内容**:
    - Rust target `riscv64imac` 的 "A" (Atomic) 扩展是否与 CKB VM 版本兼容
    - 编译产物是否可能包含不受支持的原子指令
  - **现有覆盖**: 无测试
  - **发现记录**: ❌ RFC 0003 定义 CKB VM v0 使用 `rv64imc`（不含 "A" 扩展），RFC 0051 (CKB2023) 在 VM v2 中才新增 "A" 原子扩展支持。当前 Rust target `riscv64imac-unknown-none-elf` 包含 "A" 扩展，编译产物可能包含 `lr.d`、`sc.d` 等原子指令，这些指令在 CKB VM v0/v1 上会导致非法指令异常。使用此镜像编译的合约**仅兼容 CKB VM v2+**（需使用 `hash_type: "type"` 或 `"data2"`）。

- [x] 🟢 **AUDIT-SPEC-002**: Rust Target 未启用 "B" 位操作扩展
  - **关联代码**: bookworm-18.dockerfile:39
  - **关联 RFCs**: [RFC 0033 (CKB VM Version 1)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0033-ckb-vm-version-1/0033-ckb-vm-version-1.md), [RFC 0014 (VM Cycle Limits)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0014-vm-cycle-limits/0014-vm-cycle-limits.md)
  - **审计内容**:
    - CKB VM v1+ 支持的 B 扩展是否被编译器利用
    - 未启用 B 扩展对 cycle 消耗的影响
  - **现有覆盖**: N/A
  - **发现记录**: ⚠️ CKB VM v1+ 支持 RISC-V B 扩展（位操作指令，每条 1 cycle），但 Rust target `riscv64imac` 不包含 "B" 扩展，编译器不会生成 B 扩展指令。这意味着位操作密集的代码（如密码学运算）无法利用 VM 级别的优化，可能消耗更多 cycles。非安全问题，但影响合约性能。

- [!] 🟡 **AUDIT-SPEC-003**: 未记录目标 CKB VM 版本兼容性
  - **关联代码**: README.md
  - **关联 RFCs**: [RFC 0032 (CKB VM Version Selection)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0032-ckb-vm-version-selection/0032-ckb-vm-version-selection.md), [RFC 0051 (CKB2023)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0051-ckb2023/0051-ckb2023.md)
  - **审计内容**:
    - README 是否说明编译产物兼容的 CKB VM 版本
    - 是否说明所需的 `hash_type` 配置
  - **现有覆盖**: N/A
  - **发现记录**: ❌ README 仅声明 "reproducible build for CKB smart contracts"，未说明编译产物兼容哪些 CKB VM 版本。根据 RFC 0032，开发者需要通过 `hash_type` 选择 VM 版本。考虑到当前 Rust target 包含 "A" 扩展（AUDIT-SPEC-001），合约仅兼容 VM v2+，但这一关键信息缺失。

---

## 附录 A: 审计执行日志
| 日期 | 审计项 | 发现摘要 | 状态 |
|------|--------|---------|------|
| 2026-03-02 | AUDIT-DEPS-001 | LLVM tarball 未验证完整性 | ❌ 发现问题 |
| 2026-03-02 | AUDIT-DEPS-002 | Rustup pipe-to-shell 安装 | ❌ 发现问题 |
| 2026-03-02 | AUDIT-DEPS-003 | 基础镜像未锁定 digest | ❌ 发现问题 |
| 2026-03-02 | AUDIT-DEPS-004 | apt 包未锁定版本 | ⚠️ 建议改进 |
| 2026-03-02 | AUDIT-LOGIC-001 | LLVM 19 → -18 后缀不匹配 | ❌ 发现问题 |
| 2026-03-02 | AUDIT-LOGIC-002 | 硬编码构建并行度 | ⚠️ 建议改进 |
| 2026-03-02 | AUDIT-CONTAINER-001 | 容器以 root 运行 | ❌ 发现问题 |
| 2026-03-02 | AUDIT-CONTAINER-002 | apt 缓存未清理 | ❌ 发现问题 |
| 2026-03-02 | AUDIT-CONTAINER-003 | MAINTAINER 已弃用 | ⚠️ 建议改进 |
| 2026-03-02 | AUDIT-CONTAINER-004 | Docker 层数可优化 | ⚠️ 建议改进 |
| 2026-03-02 | AUDIT-ERRINFO-001 | 下载失败处理不完善 | ⚠️ 建议改进 |
| 2026-03-02 | AUDIT-MEMORY-001 | 构建资源消耗可控 | ✅ 通过 |
| 2026-03-02 | AUDIT-SPEC-001 | Rust target "A" 扩展限制 VM 兼容性 (RFC 0003, RFC 0051) | ❌ 发现问题 |
| 2026-03-02 | AUDIT-SPEC-002 | Rust target 未启用 "B" 扩展 (RFC 0033) | ⚠️ 建议改进 |
| 2026-03-02 | AUDIT-SPEC-003 | 未记录目标 CKB VM 版本兼容性 (RFC 0032) | ❌ 发现问题 |

## 附录 B: 新增项跟踪
| 日期 | 新增项 ID | 来源 | 描述 |
|------|----------|------|------|
| 2026-03-02 | AUDIT-LOGIC-001 | AUDIT-DEPS-001 审计中发现 | 版本升级后符号链接后缀未同步更新 |
| 2026-03-02 | AUDIT-SPEC-001 | CKB RFCs 交叉审计 (RFC 0003, RFC 0051) | Rust target "A" 扩展与 CKB VM v0/v1 不兼容 |
| 2026-03-02 | AUDIT-SPEC-002 | CKB RFCs 交叉审计 (RFC 0033, RFC 0014) | 未启用 B 扩展，错过 cycle 优化机会 |
| 2026-03-02 | AUDIT-SPEC-003 | CKB RFCs 交叉审计 (RFC 0032) | README 缺少 CKB VM 版本兼容性文档 |

## 附录 C: 修复建议
| 审计项 | 严重级别 | 建议方案 | 修复状态 |
|--------|---------|---------|---------|
| AUDIT-DEPS-001 | 🔴 Critical | 添加 `echo "<known_sha256>  file" \| sha256sum -c -` 验证 | ⏳ 待修复 |
| AUDIT-DEPS-002 | 🔴 Critical | 先下载到文件，验证签名/哈希后再执行 | ⏳ 待修复 |
| AUDIT-DEPS-003 | 🟠 High | 使用 `FROM image@sha256:<digest>` 锁定 | ⏳ 待修复 |
| AUDIT-LOGIC-001 | 🟠 High | 将 `-18` 改为 `-19` 或移除版本后缀 | ⏳ 待确认 |
| AUDIT-CONTAINER-001 | 🟠 High | 添加非 root 用户运行 | ⏳ 待评估 |
| AUDIT-CONTAINER-002 | 🟡 Medium | 添加 `--no-install-recommends` 和 `rm -rf /var/lib/apt/lists/*` | ⏳ 待修复 |
| AUDIT-ERRINFO-001 | 🟡 Medium | 第8行 curl 添加 `-f` 选项 | ⏳ 待修复 |
| AUDIT-CONTAINER-003 | 🟡 Medium | 替换为 `LABEL maintainer=` | ⏳ 待修复 |
| AUDIT-DEPS-004 | 🟢 Low | 指定 cmake 版本号 | ⏳ 可选 |
| AUDIT-LOGIC-002 | 🟢 Low | 考虑恢复 `make -j$(nproc)` 或提供 ARG 参数化 | ⏳ 可选 |
| AUDIT-CONTAINER-004 | 🟢 Low | 合并 RUN 层 | ⏳ 可选 |
| AUDIT-SPEC-001 | 🟠 High | 确认目标 VM 版本，或改用 `riscv64imc` target | ⏳ 待确认 |
| AUDIT-SPEC-002 | 🟢 Low | 评估启用 B 扩展 target feature | ⏳ 可选 |
| AUDIT-SPEC-003 | 🟡 Medium | 在 README 中补充 CKB VM 版本兼容性说明 | ⏳ 待修复 |

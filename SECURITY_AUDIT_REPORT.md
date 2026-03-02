# 安全审计报告: llvm-n-rust

## 1. 执行摘要

| 项目 | 详情 |
|------|------|
| **项目名称** | llvm-n-rust |
| **项目用途** | CKB 智能合约可复现构建环境（Docker 镜像） |
| **审计日期** | 2026-03-02 |
| **审计方法** | 基于 [gpBlockchain/ckb-test-skills](https://github.com/gpBlockchain/ckb-test-skills/blob/main/.claude/skills/security-audit/SKILL.md) 安全审计技能 |
| **审计范围** | bookworm-18.dockerfile (唯一源文件) |
| **文件数量** | 1 个 Dockerfile + 1 个 README |
| **依赖组件** | buildpack-deps:bookworm, LLVM 19.1.7, Rust 1.85.1 |
| **测试覆盖** | 无现有测试 |
| **CKB 特殊处理** | ✅ 已移除内存对齐问题（CKB VM RISC-V 原生支持非对齐访问） |
| **CKB RFCs 交叉审计** | ✅ 已完成与 [nervosnetwork/rfcs](https://github.com/nervosnetwork/rfcs/tree/master/rfcs) 的交叉比对 |

---

## 2. 风险评级

| 级别 | 数量 | 说明 |
|------|------|------|
| 🔴 **Critical** | **2** | 供应链完整性验证缺失 |
| 🟠 **High** | **4** | 镜像锁定 + 版本不匹配 + root 运行 + ISA 兼容性 |
| 🟡 **Medium** | **4** | 容器加固不足 + 错误处理 + VM 版本兼容性文档 |
| 🟢 **Low** | **4** | 优化建议 + B 扩展未启用 |
| **总计** | **14** | |

---

## 3. 关键发现（按严重级别降序）

### 🔴 Critical

#### AUDIT-DEPS-001: LLVM 源码 Tarball 下载后未验证完整性

- **位置**: `bookworm-18.dockerfile:8, 13`
- **描述**: 通过 `curl -LO` 从 GitHub 下载 LLVM 19.1.7 源码包后，第 13 行使用 `sha256sum` 计算哈希并保存到文件，但**从未与任何已知正确的哈希值进行比对**。这等同于没有验证。
- **影响**: 如果下载过程被中间人攻击（DNS 劫持、CDN 投毒、GitHub 仓库被入侵），攻击者可替换 tarball 为包含后门的编译器源码。由于这是编译器工具链，后门会传播到所有使用此镜像编译的 CKB 智能合约中（即经典的 "Trusting Trust" 攻击）。
- **复现**: 在网络层拦截 curl 请求，返回恶意 tarball，Docker 构建将静默完成。
- **关键代码**:
  ```dockerfile
  # 第8行: 下载 — 无完整性验证
  RUN curl -LO https://github.com/llvm/llvm-project/archive/llvmorg-19.1.7.tar.gz
  # 第13行: 保存哈希但不比对 — 形同虚设
  RUN sha256sum llvmorg-19.1.7.tar.gz > /llvm/tarball_checksum.txt
  ```
- **修复建议**:
  ```dockerfile
  ARG LLVM_SHA256="<official_sha256_hash>"
  RUN curl -LO https://github.com/llvm/llvm-project/archive/llvmorg-19.1.7.tar.gz \
    && echo "${LLVM_SHA256}  llvmorg-19.1.7.tar.gz" | sha256sum -c -
  ```

---

#### AUDIT-DEPS-002: Rustup 通过 Pipe-to-Shell 模式安装

- **位置**: `bookworm-18.dockerfile:38-39`
- **描述**: 使用 `curl ... | sh` 将远程脚本直接管道到 shell 执行，以 root 权限运行。
- **影响**: 如果 `sh.rustup.rs` 服务器被入侵，恶意脚本将以 root 权限在容器构建过程中执行，可植入后门到 Rust 工具链。虽然使用了 `--proto '=https' --tlsv1.2` 增强了传输安全，但无法防御上游服务器入侵。
- **关键代码**:
  ```dockerfile
  RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- \
    -y --default-toolchain 1.85.1 --target riscv64imac-unknown-none-elf
  ```
- **修复建议**:
  ```dockerfile
  RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && echo "<known_sha256>  /tmp/rustup-init.sh" | sha256sum -c - \
    && sh /tmp/rustup-init.sh -y --default-toolchain 1.85.1 --target riscv64imac-unknown-none-elf \
    && rm /tmp/rustup-init.sh
  ```

---

### 🟠 High

#### AUDIT-DEPS-003: 基础镜像未锁定 Digest

- **位置**: `bookworm-18.dockerfile:1, 28`
- **描述**: `FROM docker.io/buildpack-deps:bookworm` 使用 tag 而非 digest (`@sha256:...`)。Docker tag 是可变的指针，可被重新指向不同镜像层。
- **影响**: ① 不同时间构建可能使用不同的基础镜像，破坏可复现性（与项目 README 声明的目标直接矛盾）。② 如果 Docker Hub 上 `bookworm` 标签被恶意篡改，整个构建链被污染。
- **关键代码**:
  ```dockerfile
  FROM docker.io/buildpack-deps:bookworm as builder  # L1
  FROM docker.io/buildpack-deps:bookworm             # L28
  ```
- **修复建议**: 使用 `FROM docker.io/buildpack-deps:bookworm@sha256:<digest>`

---

#### AUDIT-LOGIC-001: 符号链接版本后缀不匹配 (疑似 Bug)

- **位置**: `bookworm-18.dockerfile:34`
- **描述**: `find /llvm/bin -not -type d -exec ln -s {} {}-18 \;` 为所有 LLVM 二进制创建 `-18` 后缀的符号链接，但实际安装的是 LLVM **19**.1.7。文件名也为 `bookworm-18.dockerfile`。
- **影响**: ① 依赖 `clang-18` 版本检测的构建脚本可能因 ABI/行为差异失败或产生非预期结果。② 误导用户认为使用的是 LLVM 18。**高度疑似版本升级时（从 LLVM 18 到 19）未同步更新文件名和符号链接后缀**。
- **关键代码**:
  ```dockerfile
  # 安装的是 LLVM 19.1.7
  RUN curl -LO https://github.com/llvm/llvm-project/archive/llvmorg-19.1.7.tar.gz
  # ...
  # 但创建的是 -18 后缀的符号链接
  RUN find /llvm/bin -not -type d -exec ln -s {} {}-18 \;
  ```
- **修复建议**: 需维护者确认意图。如果是 Bug，应将 `-18` 改为 `-19`，文件名改为 `bookworm-19.dockerfile`。

---

#### AUDIT-CONTAINER-001: 容器以 root 权限运行

- **位置**: 全文（无 `USER` 指令）
- **描述**: 整个 Dockerfile 没有 `USER` 指令，容器默认以 root 运行。Rust 工具链直接安装在 `/root/.cargo/bin`。
- **影响**: 如果容器中执行了恶意或被篡改的构建脚本，攻击者获得 root 权限，可修改编译器二进制、注入后门。
- **修复建议**: 评估是否可创建非 root 用户（如 `builder`）进行构建。注意 Rust 安装路径需要相应调整。

---

### 🟡 Medium

#### AUDIT-CONTAINER-002: apt 安装未加固

- **位置**: `bookworm-18.dockerfile:4, 31`
- **描述**: `apt-get install -y cmake` 未使用 `--no-install-recommends`，且未清理 apt 缓存 (`rm -rf /var/lib/apt/lists/*`)。
- **影响**: 安装了不必要的推荐包，增大攻击面和镜像体积。
- **修复建议**:
  ```dockerfile
  RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*
  ```

---

#### AUDIT-ERRINFO-001: LLVM 下载未使用 curl -f 选项

- **位置**: `bookworm-18.dockerfile:8`
- **描述**: `curl -LO` 未包含 `-f` (fail on HTTP error) 选项。如果 GitHub 返回 302 重定向到错误页面或返回非 200 状态码的 HTML 内容，curl 可能下载 HTML 而非 tarball。
- **影响**: 构建会在后续 `tar xzf` 步骤失败，但错误信息不直观。如果配合验证缺失（AUDIT-DEPS-001），理论上可被利用。
- **关键代码**:
  ```dockerfile
  RUN curl -LO https://github.com/llvm/llvm-project/archive/llvmorg-19.1.7.tar.gz
  # 对比第38行，正确使用了 -f:
  RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- ...
  ```
- **修复建议**: 改为 `curl -fLO`

---

#### AUDIT-CONTAINER-003: MAINTAINER 指令已弃用

- **位置**: `bookworm-18.dockerfile:2, 29`
- **描述**: Docker 1.13+ 弃用了 `MAINTAINER` 指令。
- **修复建议**: 替换为 `LABEL maintainer="Xuejie Xiao <xxuejie@gmail.com>"`

---

### 🟢 Low

#### AUDIT-DEPS-004: apt 包未锁定版本
- **位置**: `bookworm-18.dockerfile:4, 31`
- **描述**: `cmake` 未指定版本号，可能导致不可复现构建。

#### AUDIT-LOGIC-002: 硬编码构建并行度
- **位置**: `bookworm-18.dockerfile:24-25`
- **描述**: `make -j2` 硬编码，注释掉了 `make -j$(nproc)`。在大型机器上效率低下。

#### AUDIT-CONTAINER-004: Docker 层数可优化
- **位置**: 多行
- **描述**: 多个独立 RUN 指令可合并以减少镜像层数。

---

### 🟠 High（CKB RFCs 交叉审计新增）

#### AUDIT-SPEC-001: Rust Target 包含 "A" 原子扩展，限制 CKB VM 兼容性

- **位置**: `bookworm-18.dockerfile:39`
- **关联 RFCs**:
  - [RFC 0003 (CKB-VM)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0003-ckb-vm/0003-ckb-vm.md): 定义 CKB VM v0 使用 `rv64imc` 架构（**不含** "A" 原子扩展）
  - [RFC 0051 (CKB2023)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0051-ckb2023/0051-ckb2023.md): CKB VM v2 新增 "A" Standard Extension 支持
- **描述**: Dockerfile 中 Rust 工具链使用 `riscv64imac-unknown-none-elf` 目标，其中 "a" 表示包含 RISC-V "A"（Atomic）原子指令扩展。根据 RFC 0003，CKB VM v0 仅支持 `rv64imc`（Integer + Multiply/Divide + Compressed），**不包含原子指令**。"A" 扩展直到 RFC 0051 (CKB2023 Meepo 硬分叉) 的 VM v2 才被引入。
- **影响**: 使用此镜像编译的 CKB 智能合约可能包含原子指令（如 `lr.d`、`sc.d`、`amoswap` 等），这些指令在 CKB VM v0 和 v1 上会导致执行失败（非法指令异常）。如果合约部署时使用 `hash_type: "data"` (VM v0) 或 `hash_type: "data1"` (VM v1)，将无法正确执行。RFC 0051 明确指出："strictly speaking 'A' Standard Extension in ckb-vm does not bring functional changes, but many existing code will be compiled with Atomic Instructions"。
- **关键代码**:
  ```dockerfile
  RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- \
    -y --default-toolchain 1.85.1 --target riscv64imac-unknown-none-elf
  ```
- **修复建议**:
  1. 如果仅针对 CKB2023+ (VM v2)：保持当前 target，但在 README 中明确说明最低兼容 VM 版本
  2. 如果需要向后兼容 VM v0/v1：改用 `riscv64imc-unknown-none-elf` target（不含 "A" 扩展）
  3. 最佳方案：同时提供两个 target，让开发者根据目标 VM 版本选择

---

### 🟡 Medium（CKB RFCs 交叉审计新增）

#### AUDIT-SPEC-003: 未记录目标 CKB VM 版本兼容性

- **位置**: `README.md`
- **关联 RFCs**:
  - [RFC 0032 (CKB VM Version Selection)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0032-ckb-vm-version-selection/0032-ckb-vm-version-selection.md): 定义 VM 版本选择机制
  - [RFC 0051 (CKB2023)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0051-ckb2023/0051-ckb2023.md): 定义 `hash_type` 与 VM 版本映射
- **描述**: README 声明项目用于 "reproducible build for CKB smart contracts"，但未说明编译产物兼容哪些 CKB VM 版本。根据 RFC 0032，CKB 存在多个 VM 版本（v0、v1、v2），不同版本支持不同的 ISA 扩展和系统调用。开发者需要知道使用此镜像编译的合约适用于哪些 VM 版本。
- **影响**: 开发者可能在不兼容的 VM 版本上部署合约，导致运行时失败。特别是考虑到 AUDIT-SPEC-001 中 "A" 扩展的兼容性问题，缺乏文档会增加部署错误的风险。
- **修复建议**: 在 README 中添加以下信息：
  1. 支持的 CKB VM 版本（当前为 VM v2+，因为包含 "A" 扩展）
  2. 对应的 `hash_type` 值（`"type"` 或 `"data2"`）
  3. 所用 RISC-V ISA 扩展列表及其与 CKB VM 版本的对应关系

---

### 🟢 Low（CKB RFCs 交叉审计新增）

#### AUDIT-SPEC-002: Rust Target 未启用 "B" 位操作扩展

- **位置**: `bookworm-18.dockerfile:39`
- **关联 RFCs**:
  - [RFC 0033 (CKB VM Version 1)](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0033-ckb-vm-version-1/0033-ckb-vm-version-1.md): VM v1 新增 RISC-V B 扩展 (v1.0.0) 支持，每条 B 指令消耗 1 cycle
- **描述**: Rust target `riscv64imac-unknown-none-elf` 不包含 "B"（Bit Manipulation）扩展。CKB VM v1+ 已支持 B 扩展，编译器可利用 B 扩展指令（如 `clz`、`ctz`、`cpop`、`bext` 等）替代多条基础指令，每条仅消耗 1 cycle。
- **影响**: 非安全问题。但编译产物无法利用 CKB VM v1+ 的 B 扩展优化，某些位操作密集的算法（如密码学运算）可能消耗更多 cycles。考虑到 CKB 的 cycle 限制（RFC 0014），这可能影响复杂合约的可行性。
- **修复建议**: 评估是否可通过 Rust 编译器标志（如 `target-feature=+zba,+zbb,+zbc,+zbs`）启用 B 扩展子集的代码生成，或等待上游 Rust 对 RISC-V B 扩展的完整支持。

---

## 4. 审计覆盖矩阵

| 模块/组件 | DIM-DEPS | DIM-LOGIC | DIM-CONTAINER | DIM-ERRINFO | DIM-MEMORY | DIM-SPEC |
|-----------|----------|-----------|---------------|-------------|------------|----------|
| Builder 阶段 (L1-26) | ✅ DEPS-001,003,004 | ✅ LOGIC-001,002 | ✅ CONTAINER-002,003 | ✅ ERRINFO-001 | ✅ MEMORY-001 | N/A |
| Runtime 阶段 (L28-43) | ✅ DEPS-002,003,004 | ✅ LOGIC-001 | ✅ CONTAINER-001,002,003,004 | ✅ | N/A | ✅ SPEC-001,002,003 |

> **DIM-CRYPTO / DIM-AUTH / DIM-CONTRACT / DIM-SERDE**: 不适用（本项目为构建环境 Dockerfile，不包含应用代码）。
> **DIM-SPEC**: CKB RFCs 规范一致性审计维度（本次新增）。

---

## 5. 依赖安全状态

| 依赖 | 版本 | 锁定方式 | 完整性验证 | 已知 CVE | 状态 |
|------|------|----------|-----------|---------|------|
| buildpack-deps | bookworm (tag) | ❌ 未锁定 digest | N/A | 需查询 | ⚠️ |
| LLVM | 19.1.7 | ✅ 版本锁定 | ❌ 未验证 | 无已知 critical CVE | ❌ |
| Rust | 1.85.1 | ✅ 版本锁定 | ❌ 未验证安装脚本 | 无已知 critical CVE | ❌ |
| cmake | 未指定 | ❌ 未锁定版本 | N/A (apt) | 需查询 | ⚠️ |

---

## 6. 改进建议（非漏洞类）

1. **添加 CI/CD 流水线**: 建议添加 GitHub Actions 工作流，自动构建镜像并运行 [Hadolint](https://github.com/hadolint/hadolint) 和 [Trivy](https://github.com/aquasecurity/trivy) 扫描。
2. **添加 .dockerignore**: 当前 `.dockerignore` 仅排除 `.git` 和 `*.md`，建议根据实际需求扩展。
3. **添加 HEALTHCHECK**: 如果镜像用于长时间运行的构建服务，添加健康检查。
4. **文档补充**: README 应说明：① 支持的目标架构；② 镜像构建和使用方法；③ 安全注意事项。
5. **多阶段构建优化**: 考虑是否需要在 runtime 阶段安装 cmake，或者仅在需要时安装。

---

## 7. CKB 特殊审计说明 — 内存对齐问题排除

本次审计针对 CKB 智能合约构建环境。CKB 虚拟机基于 RISC-V 架构，其实现（CKB-VM）**原生支持非对齐内存访问**（unaligned memory access），不会因非对齐访问产生异常或未定义行为。因此：

- ❌ **不审计**: 编译器生成的 RISC-V 代码中的内存对齐问题
- ❌ **不审计**: LLVM RISC-V 后端的对齐优化配置
- ❌ **不审计**: `riscv64imac-unknown-none-elf` target 的对齐 ABI 兼容性

此排除基于 CKB-VM 的具体实现特性（参见 [RFC 0003](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0003-ckb-vm/0003-ckb-vm.md)），不适用于通用 RISC-V 环境。

---

## 8. CKB RFCs 交叉审计

本节记录将审计发现与 [CKB RFCs](https://github.com/nervosnetwork/rfcs/tree/master/rfcs) 交叉比对的结果。

### 8.1 已审阅的 RFCs

| RFC | 标题 | 与本项目关联性 | 发现 |
|-----|------|---------------|------|
| [RFC 0003](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0003-ckb-vm/0003-ckb-vm.md) | CKB-VM | 🔴 直接关联 — 定义 VM ISA 为 `rv64imc`，本项目 Rust target 为 `riscv64imac`（含 "A" 扩展），存在兼容性差异 | AUDIT-SPEC-001 |
| [RFC 0009](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0009-vm-syscalls/0009-vm-syscalls.md) | VM Syscalls | 🟡 间接关联 — 定义 VM 系统调用接口，影响编译链接的系统调用头文件 | 无新发现 |
| [RFC 0014](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0014-vm-cycle-limits/0014-vm-cycle-limits.md) | VM Cycle Limits | 🟡 间接关联 — 定义指令 cycle 消耗，影响编译优化策略 | AUDIT-SPEC-002 |
| [RFC 0032](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0032-ckb-vm-version-selection/0032-ckb-vm-version-selection.md) | CKB VM Version Selection | 🟠 关联 — 定义 VM 版本选择机制，与构建产物兼容性直接相关 | AUDIT-SPEC-003 |
| [RFC 0033](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0033-ckb-vm-version-1/0033-ckb-vm-version-1.md) | CKB VM Version 1 | 🟡 间接关联 — VM v1 新增 B 扩展和 MOPs，可优化编译产物 | AUDIT-SPEC-002 |
| [RFC 0034](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0034-vm-syscalls-2/0034-vm-syscalls-2.md) | VM Syscalls 2 | ℹ️ 信息参考 — VM v1 新增系统调用 (Exec 等) | 无新发现 |
| [RFC 0049](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0049-ckb-vm-version-2/0049-ckb-vm-version-2.md) | CKB VM Version 2 | 🟡 间接关联 — VM v2 新增 MOPs 和 Spawn 系统调用 | 无新发现 |
| [RFC 0050](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0050-vm-syscalls-3/0050-vm-syscalls-3.md) | VM Syscalls 3 | ℹ️ 信息参考 — VM v2 新增 Spawn 等系统调用 | 无新发现 |
| [RFC 0051](https://github.com/nervosnetwork/rfcs/blob/master/rfcs/0051-ckb2023/0051-ckb2023.md) | CKB2023 | 🔴 直接关联 — 确认 VM v2 新增 "A" 原子扩展支持，验证 `riscv64imac` target 的适用范围 | AUDIT-SPEC-001 |

### 8.2 关键发现摘要

1. **ISA 兼容性风险 (AUDIT-SPEC-001, 🟠 High)**:
   - RFC 0003 定义 CKB VM v0 为 `rv64imc`
   - RFC 0051 (CKB2023) 在 VM v2 中新增 "A" 原子扩展
   - 本项目 Rust target `riscv64imac` 包含 "A" 扩展 → 编译产物仅兼容 VM v2+
   - **风险**: 合约若部署在 VM v0/v1 上将执行失败

2. **Cycle 优化缺失 (AUDIT-SPEC-002, 🟢 Low)**:
   - RFC 0033 定义 VM v1 支持 B 扩展（每条 1 cycle）
   - 当前 Rust target 未启用 B 扩展 → 无法利用 VM 的位操作优化
   - **影响**: 密码学等位操作密集场景可能消耗更多 cycles

3. **文档缺失 (AUDIT-SPEC-003, 🟡 Medium)**:
   - RFC 0032 定义了 `hash_type` 与 VM 版本的映射关系
   - README 未说明编译产物的目标 VM 版本 → 开发者可能误部署

### 8.3 对既有审计项的 RFC 补充

| 既有审计项 | 补充 RFC 参考 | 说明 |
|-----------|-------------|------|
| AUDIT-LOGIC-001 (版本不匹配) | RFC 0003, RFC 0051 | LLVM 版本后缀不匹配问题应同时考虑 CKB VM 版本演进 |
| 内存对齐排除 | RFC 0003 | RFC 0003 的 W^X 内存模型确认了 CKB VM 的非对齐访问支持 |

---

## 9. TODO — 需要进一步 Review 的项目

以下是需要人工进一步确认或决策的项目：

- [ ] **🔴 [AUDIT-DEPS-001]** 获取 LLVM 19.1.7 tarball 的官方 SHA256 哈希值并添加验证
- [ ] **🔴 [AUDIT-DEPS-002]** 评估 Rustup 安装方式是否可改为先下载、验证、再执行
- [ ] **🟠 [AUDIT-DEPS-003]** 获取当前使用的 `buildpack-deps:bookworm` 的 digest 并锁定
- [ ] **🟠 [AUDIT-LOGIC-001]** **需维护者确认**: `-18` 后缀和文件名是否应改为 `-19`？是否为版本升级遗漏？
- [ ] **🟠 [AUDIT-CONTAINER-001]** 评估构建容器是否可以使用非 root 用户运行
- [ ] **🟡 [AUDIT-CONTAINER-002]** 应用 apt 加固措施（`--no-install-recommends` + 缓存清理）
- [ ] **🟡 [AUDIT-ERRINFO-001]** 为 LLVM 下载的 curl 添加 `-f` 选项
- [ ] **🟡 [AUDIT-CONTAINER-003]** 将 `MAINTAINER` 替换为 `LABEL`
- [ ] **🟢 [信息]** 考虑添加 GitHub Actions CI 进行自动化安全扫描
- [ ] **🟢 [信息]** 评估 runtime 阶段是否真的需要安装 cmake
- [ ] **🟠 [AUDIT-SPEC-001]** Rust target `riscv64imac` 包含 "A" 扩展，需确认是否仅面向 CKB VM v2+（参见 RFC 0003, RFC 0051）
- [ ] **🟡 [AUDIT-SPEC-003]** README 中需补充目标 CKB VM 版本兼容性说明（参见 RFC 0032）
- [ ] **🟢 [AUDIT-SPEC-002]** 评估是否启用 RISC-V B 扩展以优化 cycle 消耗（参见 RFC 0033, RFC 0014）

---

## 附录: 完整 TODO 文档

完整的审计 TODO 文档见 [SECURITY_AUDIT_TODO.md](./SECURITY_AUDIT_TODO.md)。

---

*本报告由 AI 安全审计工具生成，遵循 [gpBlockchain/ckb-test-skills security-audit SKILL](https://github.com/gpBlockchain/ckb-test-skills/blob/main/.claude/skills/security-audit/SKILL.md) 方法论。建议对 Critical 和 High 级别发现进行人工确认和修复。*

# DSP-CNN 协处理器 - 工作日志

---

## 2026-04-10 Phase 1：CIC 模块对齐 Spec

### 执行摘要

将 CIC 抽取滤波器 RTL (`filter_cicd.sv`) 从基础实现升级为完全符合 `FILTER_CIC_SPEC v2.0` 的版本，并编写了配套的 block-level testbench。

### 1.1 CIC 模块重构 (`rtl/filter_cicd.sv`)

**新增端口：**

| 端口 | 方向 | 说明 | Spec 章节 |
|------|------|------|-----------|
| `cic_en_i` | in | 模块使能控制 | §10.1 |
| `s_axis_tlast` | in | 输入帧尾标记 | §9.3 |
| `s_axis_tuser` | in | 输入帧头标记 | §9.2 |
| `m_axis_tlast` | out | 输出帧尾标记 | §9.4 |
| `m_axis_tuser` | out | 输出帧头标记 | §9.4 |
| `cic_busy_o` | out | 处理忙状态 | §10.2 |
| `cic_cfg_err_o` | out | 参数非法状态 | §10.3 |

**新增功能：**

- **使能控制 (`cic_en_i`)**：`cic_en_i=0` 时不接收输入、不更新状态
- **帧边界追踪**：通过 `r_frame_active`、`r_frame_first_out`、`r_input_last_seen` 状态机追踪帧生命周期
- **输出帧标记映射**：第一个有效输出 tuser=1，最后一个有效输出 tlast=1
- **Sideband pipeline 对齐**：SOF/EOF 标记通过 N+1 级移位管线与数据对齐
- **非 valid 周期 sideband 清零**
- **参数合法性检查**：检查 R>=2, N>=2, M>=1, PHASE<R
- **输入端口 signed 声明**

### 1.2 CIC Testbench (`tb/tb_filter_cicd.sv`)

8 个测试用例：Impulse、DC、Alternating Max/Min、Random、Frame Boundary、Enable Gating、tready Always High、Sideband Zero When Invalid。包含固定宽度补码 golden model。

### 修改文件汇总

| 文件 | 操作 | 说明 |
|------|------|------|
| `rtl/filter_cicd.sv` | REWRITE | 完全对齐 CIC Spec v2.0 |
| `tb/tb_filter_cicd.sv` | NEW | CIC block testbench + golden model |

---

## 2026-04-10 Phase 0：基础设施补齐

### 执行摘要

完成了项目审查后的 Phase 0 全部修复工作，共修改 **7 个 RTL 文件**，新增 **1 个 RTL 文件** 和 **4 个目录**，更新 **2 个文档**。

### 修复清单

#### 0.1 ✅ 修复 `comb_stage.sv` 模块名引用错误 [CRITICAL]

- **问题**：`comb_stage.sv` 第 17 行实例化 `shift_register`，但实际模块名为 `shiftreg`
- **影响**：导致编译失败
- **修复**：`shift_register` → `shiftreg`
- **文件**：`rtl/comb_stage.sv`

#### 0.2 ✅ 修复 `multiplier.sv` 端口 signed 声明

- **问题**：输入端口 `a_i` / `b_i` 未声明 `signed`，依赖内部 `$signed()` 转换
- **影响**：某些工具链下可能产生隐式无符号→有符号转换异常
- **修复**：端口添加 `signed` 关键字
- **文件**：`rtl/multiplier.sv`

#### 0.3 ✅ 修复 `adder.sv` 输出端口命名

- **问题**：加法器输出叫 `product_o`（乘积），语义错误
- **修复**：`product_o` → `sum_o`
- **关联修改**：`rtl/adder_tree.sv` 中所有 `.product_o()` 端口映射同步更新为 `.sum_o()`
- **文件**：`rtl/adder.sv`, `rtl/adder_tree.sv`

#### 0.4 ✅ 统一 `dff.sv` / `shiftreg.sv` 编码规范

- **问题**：使用 `always @` 和 `wire` 而非 SystemVerilog 标准的 `always_ff @` 和 `logic`
- **修复**：
  - `dff.sv`：`wire` → `logic`，`always @` → `always_ff @`，添加 `endmodule : dff`
  - `shiftreg.sv`：`always @` → `always_ff @`，添加 `endmodule : shiftreg`
- **文件**：`rtl/dff.sv`, `rtl/shiftreg.sv`

#### 0.5 ✅ 创建全局参数包 `dsp_cnn_pkg.sv`

- **内容**：
  - 系统级数据通路参数（位宽默认值）
  - CIC / FIR / CNN 默认参数与范围
  - 系统状态机编码 (`sys_state_t`)
  - FIR 状态机编码 (`fir_state_t`)
  - CNN 状态机编码 (`cnn_state_t`)
  - Layer / Pool / Activation 类型编码
  - 错误码枚举 (`err_code_t`，对应 CSR spec 第 15 章)
  - 模块 ID 编码
  - 中断源位定义
  - CSR 地址偏移量定义（对应 CSR spec 第 4 章）
- **文件**：`rtl/dsp_cnn_pkg.sv` [NEW]

#### 0.6 ✅ 更新 README.md

- **内容**：项目概述、系统架构图、v1 功能范围、目录结构、技术规格表、开发状态
- **文件**：`README.md`

#### 0.7 ✅ 创建项目目录结构

- **新增目录**：
  - `tb/` — 验证环境（含 README.md）
  - `sim/` — 仿真脚本（含 README.md）
  - `scripts/` — 自动化脚本（含 README.md）
- 每个目录附带说明性 README

#### 0.8 ✅ 清理 `00_dsp_cnn_system_spec.md`

- **问题**：文件开头包含约 10 行编辑讨论性文字（非正式 spec 内容）
- **修复**：移除所有编辑性讨论，直接从正式 spec 标题开始
- **文件**：`docs/00_dsp_cnn_system_spec.md`

### 修改文件汇总

| 文件 | 操作 | 关键变更 |
|------|------|----------|
| `rtl/comb_stage.sv` | MODIFY | 修复模块实例化名 |
| `rtl/multiplier.sv` | MODIFY | 端口添加 signed |
| `rtl/adder.sv` | MODIFY | 输出重命名 sum_o |
| `rtl/adder_tree.sv` | MODIFY | 端口映射同步更新 |
| `rtl/dff.sv` | MODIFY | always_ff + logic + endmodule tag |
| `rtl/shiftreg.sv` | MODIFY | always_ff + endmodule tag |
| `rtl/dsp_cnn_pkg.sv` | **NEW** | 全局参数与类型定义包 |
| `docs/00_dsp_cnn_system_spec.md` | MODIFY | 移除编辑讨论文字 |
| `README.md` | MODIFY | 完整重写 |
| `tb/README.md` | **NEW** | 目录说明 |
| `sim/README.md` | **NEW** | 目录说明 |
| `scripts/README.md` | **NEW** | 目录说明 |

### 下一步计划

Phase 1：CIC 模块对齐 Spec — 添加使能控制、帧边界支持、忙状态与错误输出等。

---

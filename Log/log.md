# DSP-CNN 协处理器 - 工作日志

---

## 2026-04-10 Phase 6 补充：CNN 数据通路深化

### 执行摘要

将 `cnn_inference_engine.sv` 从 v1 结构骨架升级到 v2 完整数据通路，替换所有占位信号。

### 新增/深化内容

| 组件 | v1 状态 | v2 实现 |
|------|---------|---------|
| Weight Buffer | ❌ 占位 | ✅ `r_wbuf[]` + 流式加载 + `r_wbuf_loaded` |
| Bias Buffer | ❌ 占位 | ✅ `r_bias_buf[]` + 按输出通道索引 |
| CBUF 读地址生成 | ❌ 占位 | ✅ `seq_pos * stride + kernel_cnt` 滑窗计算 |
| 权重读地址 | ❌ 占位 | ✅ `out_ch * in_ch * ks + in_ch * ks + k` |
| 计算调度器 | ❌ 占位 | ✅ 4 级嵌套循环：kernel→seq→in_ch→out_ch |
| PE 数据分发 | ❌ `act_in='0` | ✅ CBUF 读数据 → PE activation input |
| PE 权重加载 | ❌ `wt_data='0` | ✅ WBUF → PE weight vector |
| Bias 注入 | ❌ 未连接 | ✅ `r_bias_buf[out_ch_idx]` → post-processor |
| 输入→CBUF0 | ❌ 未连接 | ✅ `input_buf → r_cbuf0` 在第一层 CHECK_CFG 时拷贝 |
| 后处理写回 | ❌ 未连接 | ✅ `w_pp_data_out → CBUF_WR[cbuf_wr_ptr]` |
| PE 独立控制 | ❌ 共享信号 | ✅ 每 PE 独立 en/clr_acc/wt_load/bias_en |

---

## 2026-04-10 Phase 6：验证深化与仿真自动化

### 执行摘要

补齐验证基础设施：新增 3 个 block testbench、4 组 SVA assertion sets、QuestaSim 仿真脚本（.do + .bat）。

### 6.1 新增 Testbench

| 文件 | 测试数 | 覆盖模块 |
|------|--------|----------|
| `tb/tb_csr_controller.sv` | 8 | CSR/IRQ：reset defaults, RW, SC, W1C, busy-protect, first-error, IRQ, perf counters |
| `tb/tb_cnn_pe.sv` | 6 | CNN PE：weight load, TDL shift, MAC, acc clear, kernel mask, bias |
| `tb/tb_dsp_cnn_top.sv` | 4 | 系统 Top：CSR loopback, IDLE status, CIC streaming, error/IRQ |

### 6.2 SVA Assertion Sets

| 文件 | Assertion 数 | 覆盖模块 |
|------|-------------|----------|
| `rtl/sva/sva_filter_cicd.sv` | 5 | CIC：tready=1, sideband, disable, busy, cfg_err |
| `rtl/sva/sva_filter_fir.sv` | 5 | FIR：tready state, sideband, error sticky, busy |
| `rtl/sva/sva_csr_controller.sv` | 5 | CSR：SC self-clear, IRQ mask, err hold, sticky, reset |
| `rtl/sva/sva_cnn_engine.sv` | 5 | CNN：error sticky, done state, busy, err state |

### 6.3 QuestaSim 仿真脚本

| 文件 | 说明 |
|------|------|
| `scripts/filelist_rtl.f` | RTL 依赖排序文件列表 |
| `scripts/sim.do` | QuestaSim .do 脚本（支持 TB_TOP 变量选择） |
| `scripts/sim.bat` | Windows batch 脚本（cic/fir/csr/pe/top/all + gui 模式） |

**使用方法：**
```
cd scripts
sim.bat cic          # 单跑 CIC
sim.bat all          # 全回归
sim.bat fir gui      # FIR GUI 模式
```

### 修改文件汇总

| 文件 | 操作 |
|------|------|
| `tb/tb_csr_controller.sv` | NEW |
| `tb/tb_cnn_pe.sv` | NEW |
| `tb/tb_dsp_cnn_top.sv` | NEW |
| `rtl/sva/sva_filter_cicd.sv` | NEW |
| `rtl/sva/sva_filter_fir.sv` | NEW |
| `rtl/sva/sva_csr_controller.sv` | NEW |
| `rtl/sva/sva_cnn_engine.sv` | NEW |
| `scripts/filelist_rtl.f` | NEW |
| `scripts/sim.do` | NEW |
| `scripts/sim.bat` | NEW |

### 验证覆盖统计

| 模块 | Directed Tests | SVA | 状态 |
|------|---------------|-----|------|
| CIC | 8 | 5 | ✅ Block Signoff Ready |
| FIR | 7 | 5 | ✅ Block Signoff Ready |
| CSR | 8 | 5 | ✅ Block Signoff Ready |
| CNN PE | 6 | 5 | ✅ Unit Level |
| Top | 4 | - | 🟡 Smoke Level |
| **Total** | **33** | **20** | - |

---

## 2026-04-10 Phase 5：系统顶层集成

### 执行摘要

创建系统顶层模块 `dsp_cnn_top.sv`，集成 CSR 控制器 + CIC + FIR + CNN 引擎 + 全局 FSM，实现完整的 Input→CIC→FIR→CNN→Result 端到端数据通路。

### 5.1 `rtl/dsp_cnn_top.sv` [NEW]

| 组件 | 实例 | 说明 |
|------|------|------|
| CSR Controller | `u_csr` | AXI-Lite 寄存器接口 |
| CIC Decimator | `u_cic` | 抽取滤波器 |
| FIR Compensator | `u_fir` | 补偿滤波器 |
| CNN Engine | `u_cnn` | 推理引擎 |
| Global FSM | `r_gfsm` | IDLE→STREAMING_DSP→CNN_COMPUTE→RESULT_DRAIN→DONE→ERROR |
| Error Aggregation | | CIC/FIR/CNN 错误码聚合 + 模块 ID |
| Interrupt Routing | | CSR irq_o 输出 |

**数据通路：**

```
s_axis → CIC → FIR → CNN → m_axis
           ↑      ↑     ↑
        cic_en  fir_en  cnn_en  ← CSR Controller ← AXI-Lite
```

### 修改文件汇总

| 文件 | 操作 | 说明 |
|------|------|------|
| `rtl/dsp_cnn_top.sv` | NEW | 系统顶层集成 |

---

## 2026-04-10 Phase 4：CSR / 中断控制器

### 执行摘要

实现了 AXI-Lite CSR 与中断控制器 (`csr_controller.sv`)，对齐 `CSR_INTERRUPT_SPEC v1.0` 全部寄存器映射。

### 4.1 `rtl/csr_controller.sv` [NEW]

| 功能 | 实现 | Spec 章节 |
|------|------|-----------|
| AXI-Lite Slave | 12-bit addr, 32-bit data, AW/W/B + AR/R channels | §3.1 |
| SYS_CTRL | START/STOP/SOFT_RST (SC), CLR_DONE/CLR_ERR (W1C) | §5.1 |
| SYS_STATUS | IDLE, BUSY, DONE/ERR (sticky), module active flags | §5.2 |
| SYS_ERR_CODE | First-error capture + sub-info | §5.3 |
| ERR_SUMMARY | Bitmap of all errors | §5.4 |
| IRQ controller | mask/raw/status (W1C), combined irq_o output | §6 |
| CIC CFG0/CFG1 | DECIM_R, ORDER_N, DIFF_M, PHASE, CIC_EN | §8 |
| FIR CFG0 | TAP_N, SHIFT, FIR_EN | §9 |
| CNN GLOBAL CFG | NUM_LAYERS, CNN_EN | §10 |
| Frame Config | FRAME_LEN | §7 |
| Perf Counters | CYCLE_CNT, FRAME_CNT, PERF_CTRL | §11 |
| Busy-write protection | Config regs locked during BUSY | §2.2 |

### 修改文件汇总

| 文件 | 操作 | 说明 |
|------|------|------|
| `rtl/csr_controller.sv` | NEW | AXI-Lite CSR + 中断控制器 |

---

## 2026-04-10 Phase 3：CNN 核心推理引擎（v1 结构骨架）

### 执行摘要

实现了 1D-CNN 推理引擎的 v1 结构骨架，包含 PE 单元、后处理流水线和顶层引擎模块。3 个新 RTL 模块全部从零实现，对齐 `CORE_CNN_SPEC v2.0`。

### 3.1 CNN PE 单元 (`rtl/cnn_pe.sv`) [NEW]

v1 Processing Element 实现：

| 子模块 | 功能 | Spec 章节 |
|--------|------|-----------|
| TDL | 抽头延迟线 (GP_PE_MAC_NUM 级) | §9.2.3 |
| 乘法器阵列 | GP_PE_MAC_NUM 路并行有符号乘法 | §9.2.1 |
| 本地加法树 | 归约为单个 partial sum | §9.2.1 |
| 双权重寄存器 | w_active / w_shadow 两级流水 | §8.3 |
| 累加器 | 支持 clear + fold 累加 + bias 注入 | §9.3 |
| Kernel size 掩码 | 运行时动态配置有效 tap 数 | §9.2.2 |

### 3.2 后处理单元 (`rtl/cnn_post_processor.sv`) [NEW]

3 级流水线：

| 级 | 功能 | Spec 章节 |
|----|------|-----------|
| Stage 1 | ReLU (符号位判断) | §11.1 |
| Stage 2 | Max/Avg Pooling (滑窗比较/累加) | §11.2 |
| Stage 3 | Re-Quantization (Round-Half-Up + shift + saturate) | §11.3 |

### 3.3 CNN 推理引擎顶层 (`rtl/cnn_inference_engine.sv`) [NEW]

| 组件 | 说明 |
|------|------|
| Global FSM | 11 状态：IDLE→LOAD_INPUT→CHECK_CFG→LOAD_WEIGHT→COMPUTE→POST_PROCESS→WRITE_BACK→NEXT_LAYER→RESULT_OUT→DONE→ERROR |
| PE Cluster | GP_PE_CLUSTER_NUM 个 PE 实例 |
| Ping-Pong CBUF | CBUF0/CBUF1 + 逐层翻转 |
| Input Staging | 帧缓冲 + 写指针 |
| Layer Config | 支持配置 layer_type, in_ch, out_ch, seq_len, kernel_size, stride, padding, act_type, pool_type, quant_shift |
| Result Output | AXI-Stream 输出 + SOF/EOF 标记 |

> **注意**：v1 结构骨架中，数据分发网络和权重装载路径使用占位信号连接。完整的数据流调度将在后续迭代中细化。

### 修改文件汇总

| 文件 | 操作 | 说明 |
|------|------|------|
| `rtl/cnn_pe.sv` | NEW | PE 单元 |
| `rtl/cnn_post_processor.sv` | NEW | 后处理流水线 |
| `rtl/cnn_inference_engine.sv` | NEW | CNN 顶层引擎 |

---

## 2026-04-10 Phase 2：FIR 模块对齐 Spec

### 执行摘要

将 FIR 补偿滤波器 RTL (`filter_fir.sv`) 从基础实现完全重写为符合 `FILTER_FIR_SPEC v2.0` 的版本。同时修复了 CIC testbench 的 lint 问题。

### 2.0 CIC Testbench 修复

- **问题**：`$random` 是不推荐的系统函数
- **修复**：`$random` → `$urandom`
- **文件**：`tb/tb_filter_cicd.sv`

### 2.1 FIR 模块重构 (`rtl/filter_fir.sv`)

**架构变更：**

| 旧实现 | 新实现 |
|--------|--------|
| 使用 `axi_stream_if` 接口 | 展平端口（与 Spec §6.1 一致） |
| 系数从 ROM 加载（硬编码） | 系数流式装载协议（§8） |
| 简单 flush 计数器 | 完整 7 状态 FSM（§13） |
| 无使能/忙/错误信号 | 全部控制/状态信号（§14） |
| 实例化 conv + multiplier 子模块 | 内联乘法器阵列（支持不同系数/输入位宽） |

**状态机（Spec §13）：**

```
IDLE → COEF_LOAD → HEAD_FLUSH → RUN → TAIL_FLUSH → DONE → (loop)
  ↓         ↓                                               
ERROR ←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←
```

**新增端口（对比旧版）：**

| 端口 | 方向 | 说明 |
|------|------|------|
| `fir_en_i` | in | 模块使能 |
| `s_axis_tlast/tuser` | in | 帧边界输入 |
| `m_axis_tlast/tuser` | out | 帧边界输出 |
| `coef_load_start_i` | in | 开始系数装载 |
| `coef_load_valid_i` | in | 系数数据有效 |
| `coef_data_i` | in | 系数数据 |
| `coef_load_done_i` | in | 装载完成 |
| `fir_busy_o` | out | 忙状态 |
| `coef_ready_o` | out | 系数就绪 |
| `fir_cfg_err_o` | out | 参数错误 |
| `coef_load_err_o` | out | 系数装载错误 |

### 2.2 FIR Testbench (`tb/tb_filter_fir.sv`)

7 个测试用例：

| # | 测试名 | 覆盖目标 |
|---|--------|----------|
| 1 | Coef Loading | 系数装载协议 + 状态机 |
| 2 | Impulse Response | 功能正确性 |
| 3 | DC Input | 稳态响应 |
| 4 | Frame Boundary | SOF/EOF sideband |
| 5 | tready Behavior | 状态门控 |
| 6 | Sideband Zero | 非 valid 语义 |
| 7 | Random Data | 通用正确性 |

Golden model 实现 Round-Half-Up + arithmetic shift + saturation。

### 修改文件汇总

| 文件 | 操作 | 说明 |
|------|------|------|
| `rtl/filter_fir.sv` | REWRITE | 完全对齐 FIR Spec v2.0 |
| `tb/tb_filter_cicd.sv` | FIX | $random → $urandom |
| `tb/tb_filter_fir.sv` | NEW | FIR block testbench + golden model |

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

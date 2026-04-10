# DSP-CNN 协处理器项目审查报告与执行计划

## 一、项目现状总览

### 文档体系（6 份，完整度高）

| 序号 | 文档 | 状态 |
|------|------|------|
| 00 | [系统主 spec](file:///e:/Git_Repository/dsp_cnn_coprocessor/docs/00_dsp_cnn_system_spec.md) | ✅ 完整 |
| 01 | [CSR/中断 spec](file:///e:/Git_Repository/dsp_cnn_coprocessor/docs/01_csr_interrupt_spec.md) | ✅ 完整 |
| 02 | [CIC 抽取滤波器 spec](file:///e:/Git_Repository/dsp_cnn_coprocessor/docs/02_filter_cic_spec.md) | ✅ 完整 |
| 03 | [FIR 补偿滤波器 spec](file:///e:/Git_Repository/dsp_cnn_coprocessor/docs/03_filter_fir_spec.md) | ✅ 完整 |
| 04 | [1D-CNN 核心 spec](file:///e:/Git_Repository/dsp_cnn_coprocessor/docs/04_core_cnn_spec.md) | ✅ 完整 |
| 05 | [验证计划](file:///e:/Git_Repository/dsp_cnn_coprocessor/docs/05_verification_plan.md) | ✅ 完整 |

### RTL 代码（11 个文件，仅覆盖 CIC + FIR 基础模块）

| 文件 | 对应 Spec 模块 | 实现程度 |
|------|----------------|----------|
| [filter_cicd.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/filter_cicd.sv) | CIC 抽取滤波器 | ⚠️ 基本实现，有差距 |
| [filter_fir.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/filter_fir.sv) | FIR 补偿滤波器 | ⚠️ 基本实现，有差距 |
| [conv.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/conv.sv) | FIR 内部卷积子模块 | ⚠️ 基本可用 |
| [adder_tree.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/adder_tree.sv) | FIR 内部加法树 | ✅ 较完整 |
| [accumulator.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/accumulator.sv) | CIC 积分器 | ✅ 可用 |
| [comb_stage.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/comb_stage.sv) | CIC 梳状器 | ✅ 可用 |
| [shiftreg.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/shiftreg.sv) | 通用移位寄存器 | ✅ 可用 |
| [multiplier.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/multiplier.sv) | 通用乘法器 | ⚠️ 有问题 |
| [dff.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/dff.sv) | 通用 D 触发器 | ✅ 可用 |
| [adder.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/adder.sv) | 通用加法器 | ✅ 可用 |
| [axi_stream_if.sv](file:///e:/Git_Repository/dsp_cnn_coprocessor/rtl/axi_stream_if.sv) | AXI-Stream 接口 | ⚠️ 有差距 |

---

## 二、发现的问题

### A 类：RTL 代码问题（需要修复）

#### A1. 模块命名不一致 [HIGH]

| 项目 | Spec 命名 | RTL 实际命名 |
|------|-----------|-------------|
| CIC 模块 | `filter_cic_decimator` | `filter_cicd` |
| FIR 模块 | `filter_fir_compensator` | `filter_fir` |
| 移位寄存器 | - | `shiftreg` / `shift_register`（两处引用名不一致） |

> [!WARNING]
> `comb_stage.sv` 第 17 行实例化 `shift_register`，但实际模块名叫 `shiftreg`，**可能导致编译失败**。

#### A2. `multiplier.sv` 端口缺失 `signed` 声明 [MEDIUM]

```diff
- input  logic [  GP_DATA_WIDTH-1:0] a_i,
- input  logic [  GP_DATA_WIDTH-1:0] b_i,
+ input  logic signed [  GP_DATA_WIDTH-1:0] a_i,
+ input  logic signed [  GP_DATA_WIDTH-1:0] b_i,
```

虽然内部用了 `$signed()` 转换，但端口声明为 `unsigned` 时，上层实例化传入 `signed` 信号可能会发生隐式类型转换，在某些工具链下行为不一致。建议端口显式声明 `signed`。

#### A3. `adder.sv` 输出命名语义错误 [LOW]

```systemverilog
output logic signed [GP_DATA_WIDTH-1:0] product_o   // 加法器输出不应叫 product_o
```

`adder` 模块输出叫 `product_o`（乘积）有误导性，应该叫 `sum_o`。

#### A4. `filter_fir.sv` 缺少关键接口 [HIGH]

对比 Spec 定义的 `filter_fir_compensator` 端口，当前 RTL 存在以下缺失：

| Spec 要求 | RTL 现状 |
|-----------|----------|
| `cic_en_i` / `fir_en_i` 使能信号 | ❌ 缺失 |
| `s_axis_tlast` 帧尾 | ❌ 使用但未通过顶层接口暴露（用 `axi_stream_if`） |
| `s_axis_tuser` 帧头 | ❌ 使用但映射不清晰 |
| `m_axis_tlast` / `m_axis_tuser` 输出边带 | ❌ 缺失 |
| `coef_load_start_i/done_i` 系数装载协议端口 | ❌ 缺失（当前硬编码 ROM 方式） |
| `fir_busy_o` / `coef_ready_o` / 错误输出 | ❌ 缺失 |
| Rounding 逻辑 | ❌ 缺失（仅有 shift + saturate） |
| 独立 Head/Tail Flush 状态机 | ⚠️ 有基础 flush 但不符合 Spec 定义 |

#### A5. `filter_cicd.sv` 缺少关键接口 [HIGH]

| Spec 要求 | RTL 现状 |
|-----------|----------|
| `cic_en_i` CIC 使能 | ❌ 缺失 |
| `s_axis_tlast` / `s_axis_tuser` 帧边界 | ❌ 缺失 |
| `m_axis_tlast` / `m_axis_tuser` 帧边界输出 | ❌ 缺失 |
| `cic_busy_o` 忙状态 | ❌ 缺失 |
| `cic_cfg_err_o` 错误输出 | ❌ 缺失 |
| 参数合法性检查 | ❌ 缺失 |

#### A6. `filter_fir.sv` 使用接口模式但 Spec 定义的是展平端口 [MEDIUM]

RTL 使用 `axi_stream_if.slave` / `axi_stream_if.master`，而 Spec 定义的是展平的 `s_axis_tvalid / tready / tdata / tlast / tuser` 端口。需要统一风格。

#### A7. 系数 ROM 未实例化 [MEDIUM]

`filter_fir.sv` 第 157-158 行有注释 `// coe rom 模块实例化`，但实际未实例化任何系数存储模块。系数来源未落实。

#### A8. `dff.sv` / `shiftreg.sv` 使用 `always` 而非 `always_ff` [LOW]

部分基础模块的时序逻辑未使用 `always_ff`，虽然功能不受影响，但不符合 SystemVerilog 编码规范。

---

### B 类：文档问题（非阻塞性）

#### B1. `00_dsp_cnn_system_spec.md` 开头有编辑性说明文字 [LOW]

第 1-10 行包含"我建议你不要在原来那版上小修小补"等编辑讨论性内容，应在正式版本中移除。

#### B2. 文档中数学公式未使用标准 LaTeX 语法 [LOW]

多处数学公式使用 `[...]` 包裹而非 `$$...$$` 或 `$...$`，导致在 Markdown 渲染器中无法正确显示。

#### B3. README.md 极其简略 [MEDIUM]

仅一行描述，缺少项目结构说明、构建方法、仿真方法、文档索引等关键信息。

---

### C 类：Spec 与 RTL 重大差距（非 Bug，是未实现）

| 差距项 | 严重程度 | 说明 |
|--------|----------|------|
| CNN 推理引擎 `cnn_inference_engine` | 🔴 未实现 | 整个 CNN Core 包括 CBUF、PE Cluster、后处理等均无 RTL |
| CSR/中断控制器 `csr_interrupt_controller` | 🔴 未实现 | AXI-Lite Slave + 寄存器映射 + 中断逻辑均无 RTL |
| 系统顶层 `dsp_cnn_top` | 🔴 未实现 | 顶层集成、全局 FSM、错误收集均无 RTL |
| 输入帧适配器 | 🔴 未实现 | 帧边界识别、帧长校验均无 RTL |
| 结果输出 FIFO/寄存器 | 🔴 未实现 | 结果缓存与输出逻辑均无 RTL |
| 验证环境 (UVM/SV TB) | 🔴 未实现 | 无任何 testbench、golden model 或仿真脚本 |
| FIR Head/Tail Flush 状态机 | 🟡 基础实现 | 不符合 Spec 中定义的完整状态机 |
| CIC 帧边界管理 | 🟡 未实现 | CIC RTL 无帧边界概念 |

---

## 三、执行计划

> [!IMPORTANT]
> 当前项目文档体系非常完善，但 RTL 实现仅完成约 **20%**（DSP 前端基础模块），CNN Core、CSR、顶层集成和验证环境完全空白。以下执行计划基于 Spec 定义，按依赖关系组织为 7 个阶段。

### Phase 0：基础设施补齐（1 周）

| 任务 | 工作内容 | 交付物 |
|------|----------|--------|
| 0.1 | 修复 `comb_stage` 中 `shift_register` → `shiftreg` 命名错误 | 修复后 RTL |
| 0.2 | 统一模块命名：`filter_cicd` → `filter_cic_decimator`，`filter_fir` → `filter_fir_compensator` | 重命名后 RTL |
| 0.3 | 修复 `multiplier.sv` 端口 signed 声明 | 修复后 RTL |
| 0.4 | 修复 `adder.sv` 输出命名 `product_o` → `sum_o` | 修复后 RTL |
| 0.5 | 统一 `dff.sv`/`shiftreg.sv` 使用 `always_ff` | 修复后 RTL |
| 0.6 | 创建通用参数包 `dsp_cnn_pkg.sv` | 新文件 |
| 0.7 | 补充 README.md | 更新后 README |
| 0.8 | 创建项目目录结构（`tb/`, `sim/`, `scripts/`） | 目录 |
| 0.9 | 清理 `00_dsp_cnn_system_spec.md` 开头编辑讨论文字 | 更新后文档 |

---

### Phase 1：CIC 模块对齐 Spec（1-2 周）

| 任务 | 工作内容 | 依赖 |
|------|----------|------|
| 1.1 | 添加 `cic_en_i` 使能控制 | Phase 0 |
| 1.2 | 添加 `s_axis_tlast/tuser` 输入帧边界支持 | Phase 0 |
| 1.3 | 添加 `m_axis_tlast/tuser` 输出帧边界映射 | 1.2 |
| 1.4 | 添加 `cic_busy_o` 忙状态输出 | 1.2 |
| 1.5 | 添加 `cic_cfg_err_o` 参数合法性检查 | Phase 0 |
| 1.6 | 编写 CIC block-level testbench（`cic_tb`） | 1.1-1.5 |
| 1.7 | 实现 CIC 定点 golden model（SV/Python） | 独立 |
| 1.8 | 运行 CIC directed tests 并验证 golden 对齐 | 1.6, 1.7 |

---

### Phase 2：FIR 模块对齐 Spec（2-3 周）

| 任务 | 工作内容 | 依赖 |
|------|----------|------|
| 2.1 | 重构 FIR 顶层端口为展平 AXIS + 控制信号（移除 `axi_stream_if`） | Phase 0 |
| 2.2 | 添加 `fir_en_i` 使能控制 | 2.1 |
| 2.3 | 实现系数装载协议（`coef_load_start/valid/done`） | 2.1 |
| 2.4 | 实现完整 FIR 状态机（IDLE→COEF_LOAD→HEAD_FLUSH→RUN→TAIL_FLUSH→DONE→ERROR） | 2.3 |
| 2.5 | 实现独立的 Head Flush 控制 | 2.4 |
| 2.6 | 实现独立的 Tail Flush 控制 | 2.4 |
| 2.7 | 添加 Rounding 逻辑 | 2.1 |
| 2.8 | 添加 `fir_busy_o / coef_ready_o / fir_cfg_err_o / coef_load_err_o` | 2.4 |
| 2.9 | 添加 sideband（`valid/user/last`）pipeline 对齐 | 2.6 |
| 2.10 | 编写 FIR block-level testbench（`fir_tb`） | 2.1-2.9 |
| 2.11 | 实现 FIR 定点 golden model | 独立 |
| 2.12 | 运行 FIR directed tests | 2.10, 2.11 |

---

### Phase 3：CNN 核心推理引擎（4-6 周）

| 任务 | 工作内容 | 依赖 |
|------|----------|------|
| 3.1 | 设计 CNN 参数包与接口定义 | Phase 0 |
| 3.2 | 实现 Input Staging Buffer | 3.1 |
| 3.3 | 实现 Ping-Pong CBUF（`cbuf_controller`） | 3.1 |
| 3.4 | 实现 Weight Buffer + Bias Buffer | 3.1 |
| 3.5 | 实现 PE 单元（TDL + MAC array + 双权重寄存器） | 3.1 |
| 3.6 | 实现 PE Cluster Array | 3.5 |
| 3.7 | 实现 Data Distribution Network（Conv/DWConv 读模式） | 3.3, 3.6 |
| 3.8 | 实现跨通道累加器 + Psum 路径 | 3.6 |
| 3.9 | 实现 Post-Processing：ReLU | 3.8 |
| 3.10 | 实现 Post-Processing：Max/Avg Pooling | 3.8 |
| 3.11 | 实现 Post-Processing：Re-Quantization | 3.8 |
| 3.12 | 实现 Folding Controller | 3.6 |
| 3.13 | 实现 Layer FSM + Global FSM | 3.2-3.12 |
| 3.14 | 实现结果输出逻辑 | 3.13 |
| 3.15 | 集成为 `cnn_inference_engine` 顶层 | 3.2-3.14 |
| 3.16 | 编写 CNN block-level testbench（`cnn_core_tb`） | 3.15 |
| 3.17 | 实现 CNN 逐层 golden model | 独立 |
| 3.18 | 运行 CNN directed tests（单层 Conv/DWConv/Pool/FC） | 3.16, 3.17 |

---

### Phase 4：CSR / 中断控制器（2-3 周）

| 任务 | 工作内容 | 依赖 |
|------|----------|------|
| 4.1 | 实现 AXI-Lite Slave 接口 | Phase 0 |
| 4.2 | 实现 CSR 寄存器文件（RO/RW/SC/W1C/WARL） | 4.1 |
| 4.3 | 实现 Busy 写保护逻辑 | 4.2 |
| 4.4 | 实现中断控制器（mask/raw/status/clear） | 4.2 |
| 4.5 | 实现错误码收集器（首错保持） | 4.2 |
| 4.6 | 实现性能计数器 | 4.2 |
| 4.7 | 实现 FIR 系数窗口寄存器 | 4.2 |
| 4.8 | 实现 CNN Layer 配置窗口 | 4.2 |
| 4.9 | 编写 CSR/IRQ testbench（`csr_irq_tb`） | 4.1-4.8 |
| 4.10 | 运行 CSR directed tests | 4.9 |

---

### Phase 5：系统顶层集成（2-3 周）

| 任务 | 工作内容 | 依赖 |
|------|----------|------|
| 5.1 | 设计系统顶层模块 `dsp_cnn_top` | Phase 1-4 |
| 5.2 | 实现全局 FSM（RESET→IDLE→CONFIG→…→DONE→ERROR） | 5.1 |
| 5.3 | 实现输入帧适配器 | 5.1 |
| 5.4 | 集成 CIC + FIR + CNN Core | 5.1 |
| 5.5 | 集成 CSR Controller | 5.4 |
| 5.6 | 实现 FIR→CNN 中间 buffer | 5.4 |
| 5.7 | 实现结果输出 FIFO/寄存器 | 5.4 |
| 5.8 | 实现系统中断输出（`irq_done`, `irq_err`） | 5.5 |
| 5.9 | 编写顶层 testbench（`top_tb`） | 5.1-5.8 |
| 5.10 | 运行端到端 directed tests | 5.9 |

---

### Phase 6：验证收敛与 Signoff（3-4 周）

| 任务 | 工作内容 | 依赖 |
|------|----------|------|
| 6.1 | 实现 block-level CRV (constrained-random) 测试 | Phase 1-4 |
| 6.2 | 实现 Error Injection 测试 | Phase 5 |
| 6.3 | 添加 SVA assertion sets | Phase 5 |
| 6.4 | 实现 Functional Coverage collectors | Phase 5 |
| 6.5 | 搭建 regression 框架 | 6.1-6.4 |
| 6.6 | 运行 regression 并收敛覆盖率 | 6.5 |
| 6.7 | Bug 修复与 waiver | 6.6 |
| 6.8 | 编写 signoff report | 6.7 |

---

## 四、优先级建议

> [!TIP]
> **推荐立即执行的工作**：Phase 0（1 周内可完成）和 Phase 1（CIC 对齐）。这两个阶段修复的都是实际存在的代码问题，完成后 CIC 模块可以独立验证通过。

### 短期目标（1-2 周）
- 完成 Phase 0 所有基础设施修复
- 完成 Phase 1 的 CIC 端口补全 + 简单 TB

### 中期目标（1-2 月）
- 完成 Phase 2（FIR 对齐）
- 完成 Phase 3（CNN 核心，工作量最大）

### 长期目标（2-3 月）
- 完成 Phase 4-6（系统集成 + 验证收敛）

---

## 五、资源估算

| 阶段 | 预估工时 | 风险等级 |
|------|----------|----------|
| Phase 0 | 1 周 | 🟢 低 |
| Phase 1 | 1-2 周 | 🟢 低 |
| Phase 2 | 2-3 周 | 🟡 中 |
| Phase 3 | 4-6 周 | 🔴 高（工作量最大、复杂度最高） |
| Phase 4 | 2-3 周 | 🟡 中 |
| Phase 5 | 2-3 周 | 🟡 中 |
| Phase 6 | 3-4 周 | 🟡 中 |
| **总计** | **~3-5 月** | - |

## Open Questions

> [!IMPORTANT]
> 1. **Phase 0 是否立即执行？** 其中的命名修复（`shift_register` → `shiftreg`）是实际编译错误，需要优先修复。
> 2. **是否需要我先执行 Phase 0 的修复工作？** 包括修复 `comb_stage` 中的模块名引用、`multiplier` 端口 signed 声明等。
> 3. **Phase 3 (CNN Core) 的实现优先级如何考虑？** 可以先做一个最小可行版本（仅支持单层 Conv1D + ReLU），再逐步扩展。
> 4. **验证环境偏好**：使用 UVM 还是轻量级 SV testbench？

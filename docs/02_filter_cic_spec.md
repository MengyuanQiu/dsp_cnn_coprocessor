# `02_filter_cic_spec.md`

# DSP-CNN 协处理器

# CIC 抽取滤波器规格书

**Document ID:** `FILTER_CIC_SPEC`
**Version:** `v2.0`
**Applies To:** `DSP_CNN_SYSTEM_SPEC v2.x`, `CSR_INTERRUPT_SPEC v1.x`

---

## 1. 文档目的

本文档定义 DSP-CNN 协处理器中 **CIC（Cascaded Integrator-Comb）抽取滤波器**模块的功能、接口、参数、数值规则、控制时序、异常处理和验证要求，作为 CIC 模块 RTL 设计、子模块验证、系统集成和软件配置的依据。

本文档覆盖：

* CIC 模块功能职责
* 接口与时序契约
* 参数与寄存器映射关系
* 位宽增长与补码运算规则
* 连续流与无反压语义
* 输出有效脉冲生成机制
* 运行时限制与错误行为
* 验证场景与 golden 行为定义

本文档不覆盖：

* FIR 补偿滤波器行为
* CNN 输入量化行为
* 顶层系统中断协议细节
* 外部输入 FIFO/CDC 的具体实现

---

## 2. 模块功能概述

### 2.1 模块名称

`filter_cic_decimator`

### 2.2 核心职责

CIC 模块位于系统前端，负责对高速输入采样流执行：

1. **大倍率抽取（Decimation）**
2. **粗抗混叠滤波**
3. **前后端数据速率适配**
4. **为 FIR 模块提供低速全精度中间结果**

现有 system spec 已明确：CIC 属于前端 DSP 子系统，工作在“前端连续流岛”，不应依赖下游 ready 进行运行。

### 2.3 设计哲学

本模块遵循以下设计原则：

* **Zero-DSP / 无乘法器实现**：仅使用加法器、减法器、寄存器和计数器完成滤波。
* **Continuous Streaming / 连续流输入**：输入端默认视为不可回压数据源。
* **Full-Precision Internal Path / 内部全精度路径**：中间级联过程不做截断。
* **Two’s Complement Natural Wrap-around / 补码自然溢出**：允许积分器溢出，禁止插入 saturation。
* **Clock-Enable Based Decimation / 基于使能的逻辑降频**：不创建派生时钟，使用 CE 脉冲驱动 comb 级。

---

## 3. 算法与拓扑结构

## 3.1 结构形式

本模块采用经典 **Hogenauer CIC** 结构，由三部分串联组成：

1. **N 级积分器链（Integrator Chain）**
2. **抽取器（Down-sampler / Rate Counter）**
3. **N 级梳状器链（Comb Chain）**

这与现有 CIC 文档中的定义保持一致。

## 3.2 数学形式

设输入序列为 `x[n]`，抽取率为 `R`，阶数为 `N`，差分延迟为 `M`。

### 3.2.1 积分器

每级积分器满足：

[
y_i[n] = y_i[n-1] + x_i[n]
]

其中第一级输入为原始输入，后级输入为前一级输出。

### 3.2.2 抽取

每接收 `R` 个有效输入样本，抽取器产生一个使能脉冲，将当前积分器末级输出采样送入 comb 链。

### 3.2.3 梳状器

每级梳状器满足：

[
c_i[k] = d_i[k] - d_i[k-M]
]

其中 `k` 为降速后的输出采样索引。

---

## 4. 系统位置与上下游关系

## 4.1 上游接口关系

CIC 接收来自输入适配层或 ADC/前端下变频模块的采样流。

输入特性假设：

* 输入可为持续有效流
* 输入速率高于 FIR / CNN 路径
* 输入端通常不允许因后端拥堵而停流

## 4.2 下游接口关系

CIC 输出送入 FIR 补偿滤波器。

系统级要求：

* CIC 输出是**全精度中间结果**
* FIR 负责后续通带补偿、位宽压缩与量化。

## 4.3 Backpressure 边界

CIC 所处数据岛属于 system spec 中定义的 **前端连续流岛**。其核心规则是：

* 输入侧不能依赖下游 backpressure
* 输出侧即使暴露 `tready`，也不允许将其作为停止积分器接收输入的条件
* 若系统需要标准 AXI-Stream 兼容，必须在 CIC 外围通过 FIFO / wrapper 适配。

---

## 5. 参数定义

为保证模块通用性，以下参数必须为 SystemVerilog `parameter` 或由上层包配置生成。

| 参数名称            |     默认值 |     范围 | 说明      |
| --------------- | ------: | -----: | ------- |
| `GP_IN_WIDTH`   |       8 |   4~32 | 输入数据位宽  |
| `GP_CICD_R`     |      64 | 2~4096 | 抽取率 R   |
| `GP_CICD_N`     |       5 |    2~8 | 阶数 N    |
| `GP_CICD_M`     |       1 |    1~2 | 差分延迟 M  |
| `GP_CICD_PHASE` |       0 |  0~R-1 | 输出相位    |
| `GP_OUT_WIDTH`  | derived |      - | 输出全精度位宽 |

### 5.1 输出位宽公式

[
GP_OUT_WIDTH = GP_IN_WIDTH + GP_CICD_N \cdot \lceil \log_2(GP_CICD_R \cdot GP_CICD_M) \rceil
]

说明：

* RTL 实现中允许使用 `$clog2(R*M)` 近似表达
* 该公式与现有 CIC spec 中的位宽增长公式一致。

### 5.2 参数合法性约束

以下参数非法：

* `GP_CICD_R < 2`
* `GP_CICD_N < 2`
* `GP_CICD_M < 1`
* `GP_CICD_PHASE >= GP_CICD_R`

若通过 CSR 动态配置得到非法参数，则必须拒绝启动，并上报 `ERR_CIC_PARAM_ILLEGAL`。该错误码已在 CSR spec 中定义。

---

## 6. 接口定义

## 6.1 顶层端口

```systemverilog
module filter_cic_decimator #(
    parameter int GP_IN_WIDTH   = 8,
    parameter int GP_CICD_R     = 64,
    parameter int GP_CICD_N     = 5,
    parameter int GP_CICD_M     = 1,
    parameter int GP_CICD_PHASE = 0,
    parameter int GP_OUT_WIDTH  = GP_IN_WIDTH + GP_CICD_N * $clog2(GP_CICD_R * GP_CICD_M)
) (
    input  logic                       clk_i,
    input  logic                       rst_ni,

    input  logic                       cic_en_i,

    input  logic                       s_axis_tvalid,
    output logic                       s_axis_tready,
    input  logic signed [GP_IN_WIDTH-1:0]  s_axis_tdata,
    input  logic                       s_axis_tlast,
    input  logic [0:0]                 s_axis_tuser,

    output logic                       m_axis_tvalid,
    input  logic                       m_axis_tready,
    output logic signed [GP_OUT_WIDTH-1:0] m_axis_tdata,
    output logic                       m_axis_tlast,
    output logic [0:0]                 m_axis_tuser,

    output logic                       cic_busy_o,
    output logic                       cic_cfg_err_o
);
```

## 6.2 输入接口语义

| 信号                | 方向  | 说明             |
| ----------------- | --- | -------------- |
| `s_axis_tvalid`   | in  | 输入样本有效         |
| `s_axis_tready`   | out | 输入可接受；v1 固定为 1 |
| `s_axis_tdata`    | in  | 输入样本数据         |
| `s_axis_tlast`    | in  | 输入帧尾           |
| `s_axis_tuser[0]` | in  | 输入帧头           |

### 6.2.1 输入接收规则

* 当 `cic_en_i=1` 且 `s_axis_tvalid=1` 时，CIC 接收一个新样本
* `s_axis_tready` 在 v1 中必须恒为 `1'b1`
* 模块不得利用 `m_axis_tready` 反向阻止输入接收

这与原始 CIC spec 的“Continuous Streaming”定义一致。

## 6.3 输出接口语义

| 信号                | 方向  | 说明                       |
| ----------------- | --- | ------------------------ |
| `m_axis_tvalid`   | out | 输出样本有效脉冲                 |
| `m_axis_tready`   | in  | 下游 ready，仅作 wrapper 兼容保留 |
| `m_axis_tdata`    | out | 全精度降采样输出                 |
| `m_axis_tlast`    | out | 输出帧尾                     |
| `m_axis_tuser[0]` | out | 输出帧头                     |

### 6.3.1 输出握手规则

v1 冻结以下语义：

* `m_axis_tvalid` 由内部抽取相位计数器决定
* 只在输出样本实际生成的周期拉高
* `m_axis_tready` **不参与** CIC 内部积分与抽取流程控制
* 若系统需要真正可回压输出，必须由外围 FIFO 吸收 `m_axis_tvalid` 脉冲流

### 6.3.2 非 valid 周期的数据语义

当 `m_axis_tvalid=0` 时：

* `m_axis_tdata` 可保持上一个输出值
* `m_axis_tlast` 必须为 0
* `m_axis_tuser` 必须为 0

> 这样能避免“don't care”造成仿真和形式检查分歧。

---

## 7. 内部微架构要求

## 7.1 积分器链

* 共 `N` 级
* 每级寄存器位宽固定为 `GP_OUT_WIDTH`
* 每个有效输入样本推动积分器链前进一次
* 不允许中间级截断

## 7.2 抽取器

抽取器由相位计数器实现：

* 每收到一个有效输入样本，计数器加一
* 当计数器达到配置相位时，产生 `w_sclk`
* `w_sclk` 的周期为 `R`
* 抽取计数器必须仅在 `s_axis_tvalid=1` 的周期推进

## 7.3 梳状器链

* 共 `N` 级
* 每级使用延迟深度 `M`
* 仅在 `w_sclk=1` 时更新
* 逻辑时钟仍为 `clk_i`，禁止创建派生时钟

## 7.4 逻辑降频原则

comb 链必须采用 **clock enable** 而不是新时钟域。
这是为了避免派生时钟带来的 STA 和 CDC 复杂性，也与原始文档“受控于 `w_sclk` 的 enable”思路一致。

---

## 8. 位宽与数值规则

## 8.1 输入扩展规则

输入 `s_axis_tdata` 在进入第一级积分器前，必须做**有符号扩展**到 `GP_OUT_WIDTH`。

## 8.2 内部统一位宽

所有积分器寄存器和梳状器寄存器统一使用 `GP_OUT_WIDTH`，不得在级联中途截断。

## 8.3 补码运算规则

模块内部全部采用二进制补码有符号运算。

## 8.4 自然溢出规则

积分器允许自然 wrap-around overflow，不得实现：

* saturation
* clipping
* overflow exception trap

原因是 CIC 数学结构保证只要全链路保持补码一致性，积分器溢出将在 comb 链中抵消。该规则已在现有 CIC 文档中明确提出。

## 8.5 输出缩放规则

v1 中 CIC **不做最终缩放**。
输出保持 full precision，由 FIR 负责后续量化和增益管理。

---

## 9. 帧边界与控制流

## 9.1 输入帧语义

CIC 允许按帧观察输入流，但其滤波本质仍是连续状态机。
因此帧边界在 v1 的主要作用是：

* 向系统级状态机报告 frame start / frame end
* 辅助生成输出侧边带标志
* 不改变 CIC 的基本运算公式

## 9.2 帧头处理

当检测到 `s_axis_tvalid=1 && s_axis_tuser[0]=1` 时：

* 置位内部 `frame_active`
* 若系统要求“每帧独立处理”，则可由上层在启动前完成 `SOFT_RST`
* CIC 本身不强制在帧头清积分器状态，除非顶层明确要求单帧完全独立

### 9.2.1 v1 约束

为与当前系统主 spec 保持简洁一致，v1 建议：

* 一次 `START` 对应一帧输入
* 在 `START` 前由系统控制器保证 CIC 状态处于干净态

## 9.3 帧尾处理

当检测到 `s_axis_tvalid=1 && s_axis_tlast=1` 时：

* 记录当前输入帧结束
* 输出侧最后一个 `m_axis_tlast` 应对应**该帧最后一个被抽取出的有效样本**
* 不引入额外 flush 周期

说明：
这点和 FIR 不同。FIR 有明确 tail flush 需求；CIC 没有基于零填充释放尾能量的机制。

## 9.4 输出帧头/帧尾映射

建议固定如下：

* 第一笔有效抽取输出：`m_axis_tuser[0]=1`
* 最后一笔有效抽取输出：`m_axis_tlast=1`

中间输出：

* `m_axis_tuser[0]=0`
* `m_axis_tlast=0`

---

## 10. 状态与控制信号

## 10.1 `cic_en_i`

* `0`：模块不接收新输入，不更新内部状态
* `1`：模块工作

## 10.2 `cic_busy_o`

当任一条件成立时置高：

* 已接收 frame start 尚未完成 frame end 对应输出
* 内部处于活动输入接收期

## 10.3 `cic_cfg_err_o`

当发现参数非法时置高，并由上层映射到 `CIC_STATUS.CIC_CFG_ERR` 与系统错误码。CSR spec 已定义对应状态位。

---

## 11. CSR 映射关系

本模块运行参数由 CSR 侧提供，映射如下：

| CSR                      | 对应模块参数/控制       |
| ------------------------ | --------------- |
| `CIC_CFG0.DECIM_R`       | `R`             |
| `CIC_CFG0.ORDER_N`       | `N`             |
| `CIC_CFG0.DIFF_M`        | `M`             |
| `CIC_CFG1.PHASE`         | `PHASE`         |
| `CIC_CFG1.CIC_EN`        | `cic_en_i`      |
| `CIC_STATUS.CIC_BUSY`    | `cic_busy_o`    |
| `CIC_STATUS.CIC_CFG_ERR` | `cic_cfg_err_o` |

这些字段已经在上一份 `CSR_INTERRUPT_SPEC` 中冻结。与原始 CIC spec 中参数定义一致。

---

## 12. 运行时约束与非法行为

## 12.1 Busy 时禁止重配

当系统处于 `BUSY` 状态时，不允许修改：

* `R`
* `N`
* `M`
* `PHASE`

否则：

* 保持旧值
* 置系统错误 `ERR_CFG_WRITE_WHILE_BUSY`
* 触发 `IRQ_ERR`

原因：CIC 是有状态滤波器，运行时改变参数会破坏数学正确性。这个约束在 system/csr spec 中也已确立。

## 12.2 非法相位

若 `PHASE >= R`：

* 拒绝 `START`
* 置 `CIC_CFG_ERR`
* 上报 `ERR_CIC_PARAM_ILLEGAL`

## 12.3 输入无效周期

当 `s_axis_tvalid=0`：

* 积分器不前进
* 抽取计数器不前进
* comb 不更新
* 不产生输出

## 12.4 `m_axis_tready=0`

v1 固定行为：

* 不阻止 CIC 内部生成输出样本
* 若外围没有缓存而下游不 ready，可能丢样；这属于集成错误，不属于 CIC 算法错误
* 系统集成必须保证输出侧存在足够缓冲或“永远 ready”约束

这点必须在 spec 中写死，避免后续集成误用。

---

## 13. 性能与实现约束

## 13.1 吞吐能力

在 `s_axis_tvalid` 连续有效时：

* 输入侧吞吐 = 1 sample / cycle
* 输出侧平均吞吐 = 1 sample / R cycles

## 13.2 延迟

CIC 模块从输入到输出的理论延迟取决于：

* 积分器寄存器级数
* 抽取相位
* comb 级实现方式

v1 规定：

* 实现必须在 RTL 文档或参数包中给出固定 `LATENCY_CIC`
* 验证环境必须以该固定延迟进行对齐检查

## 13.3 资源约束

实现应优先满足：

* 无 DSP 使用
* 有界 LUT/FF 增长
* 不创建额外时钟树
* 所有状态逻辑单时钟域实现

---

## 14. 复位行为

## 14.1 硬复位

当 `rst_ni=0` 时，必须：

* 清空所有积分器寄存器
* 清空所有 comb 延迟寄存器
* 清空相位计数器
* 清空帧活动状态
* 清空输出 valid/user/last 状态

## 14.2 软复位

由系统控制器发起软复位时，模块必须恢复到与硬复位等价的逻辑初始态，至少包括：

* 清空内部数值状态
* 清空计数器
* 清空帧边界跟踪状态

这与 system spec 对 CIC 的 reset 要求一致。

---

## 15. 错误模型

CIC 模块自身不负责复杂错误恢复，但必须识别并上报以下错误类别：

### 15.1 配置错误

* `R` 非法
* `N` 非法
* `M` 非法
* `PHASE` 非法

### 15.2 接口使用错误

* busy 期间参数修改
* 在禁用状态下错误启动

### 15.3 超时错误

超时通常由顶层控制器判断，但 CIC 应暴露 busy 状态，供系统计算：

* 预期输入周期数
* 预期输出完成时限

---

## 16. 验证要求

## 16.1 功能正确性

至少覆盖以下 stimulus：

1. **Impulse input**
2. **DC constant input**
3. **满幅正弦输入**
4. **交替正负最大值输入**
5. **随机噪声输入**

## 16.2 参数遍历

至少覆盖：

* `R = 2, 4, 8, 64, max`
* `N = 2, 3, 5, max`
* `M = 1, 2`
* `PHASE = 0, middle, R-1`

## 16.3 数值验证重点

必须验证：

* 位宽增长公式正确
* sign extension 正确
* wrap-around overflow 后最终 comb 输出与 golden 一致
* 输出脉冲周期严格为 `R`
* `PHASE` 对输出首样位置影响正确

## 16.4 帧边界验证

必须验证：

* SOF 到首个输出 `tuser` 的映射
* EOF 到最后一个输出 `tlast` 的映射
* 非 valid 周期下边带保持为 0

## 16.5 接口鲁棒性

必须验证：

* `s_axis_tvalid` 断续输入
* busy 时 CSR 非法写
* `m_axis_tready=0` 时 wrapper 集成行为
* reset 插入运行中

---

## 17. Golden Model 建议

DV 环境建议使用软件参考模型：

1. 对输入做补码扩展
2. 按 `N` 级积分器递推
3. 每 `R` 个有效输入样本按 `PHASE` 采样
4. 再按 `N` 级 comb 和 `M` 延迟做差分
5. 全过程使用与 RTL 相同位宽的补码 wrap-around 模型

关键点：

* golden 不得用无限精度再最后裁剪
* 必须逐级模拟固定宽度补码溢出行为

否则会与 RTL 不一致。

---

## 18. 与其他规格书的边界

## 18.1 对 system spec

本模块必须服从 system spec 的：

* 前端连续流岛语义
* start/stop/reset 生命周期
* 配置先于启动
* busy 状态可观测

## 18.2 对 CSR spec

本模块必须服从 CSR spec 的：

* `CIC_CFG0/1`
* `CIC_STATUS`
* busy 写保护
* 错误码上报机制

## 18.3 对 FIR spec

本模块输出必须满足 FIR 输入要求：

* 全精度有符号数据
* 降速有效脉冲
* 明确帧边界映射

---

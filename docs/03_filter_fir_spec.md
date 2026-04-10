# `03_filter_fir_spec.md`

# DSP-CNN 协处理器

# FIR 补偿滤波器规格书

**Document ID:** `FILTER_FIR_SPEC`
**Version:** `v2.0`
**Applies To:** `DSP_CNN_SYSTEM_SPEC v2.x`, `CSR_INTERRUPT_SPEC v1.x`

---

## 1. 文档目的

本文档定义 DSP-CNN 协处理器中 **FIR（Finite Impulse Response）补偿滤波器**模块的功能、接口、参数、数值规则、系数装载协议、边界冲刷机制、异常处理和验证要求，作为 FIR 模块 RTL 设计、DV 验证、驱动编写和系统集成的依据。

本文档覆盖：

* FIR 模块功能职责
* 输入/输出接口与时序契约
* 系数加载协议
* 数据延迟线与并行乘加树微架构约束
* Head Flush / Tail Flush 行为
* 量化与饱和规则
* 帧边界与 sideband 对齐
* 配置、状态、异常和验证要求

本文档不覆盖：

* CIC 抽取滤波器算法细节
* CNN Core 微架构
* 顶层 AXI-Lite 总线实现
* v2 及以后版本的自适应滤波、对称系数优化等扩展特性

---

## 2. 模块功能概述

### 2.1 模块名称

`filter_fir_compensator`

### 2.2 核心职责

FIR 模块位于 CIC 模块之后，CNN 模块之前，负责：

1. **通带补偿（Droop Compensation）**
   对 CIC 引入的通带下垂进行幅频补偿。

2. **抗混叠低通滤波（Anti-alias Filtering）**
   抑制抽取后折叠到基带的带外噪声。

3. **位宽桥接（Bit-width Bridging）**
   将 CIC 的高位宽全精度输出转换为 CNN 可接受的低位宽激活格式。

4. **边界冲刷（Boundary Flush）**
   通过头部/尾部零填充机制，避免帧间脏数据污染和尾样本丢失。

### 2.3 设计哲学

本模块遵循以下原则：

* **全并行乘加树实现**：基于数据移位寄存器、并行乘法器、流水线加法树构建。
* **显式边界管理**：通过硬件 flush 而不是依赖全数据路径 reset。
* **统一定点算术**：中间运算保持高精度，末级统一 round + saturate。
* **frame-aware streaming**：输入按帧管理，输出保持 sideband 对齐
* **配置先于运行**：tap 数、shift、系数必须在启动前完成配置

---

## 3. 系统位置与上下游关系

## 3.1 上游关系

FIR 模块接收来自 CIC 的降速输出流。

上游输入特性：

* 数据为**全精度补码有符号数**
* 有效样本为脉冲式 `valid`
* 可能包含 `SOF/EOF` 边界信息
* 数据速率低于原始输入采样速率。

## 3.2 下游关系

FIR 模块输出到 CNN 输入 staging / input buffer。

下游要求：

* 输出为 CNN 可直接接收的低位宽定点激活
* 输出需携带对齐后的 `valid / user / last`
* 输出侧若存在 backpressure，必须由系统 buffer 吸收，不能破坏 FIR 的 flush 机制。

## 3.3 数据岛位置

根据 system spec，FIR 位于 **前端连续流岛** 与 **后端缓冲突发岛** 的交界处：

* 输入侧继承 DSP 链路的流式性质
* 输出侧必须与 CNN 的 burst compute 解耦
* 因此 FIR 输出侧原则上应接 buffer/FIFO，而不是直接暴露给不可预测的 backpressure 源。

---

## 4. 功能定义

## 4.1 FIR 滤波功能

设输入序列为 `x[n]`，系数为 `h[k]`，tap 数为 `T`，则 FIR 输出为：

[
y[n] = \sum_{k=0}^{T-1} h[k] \cdot x[n-k]
]

其中：

* `x[n-k]` 由输入移位延迟线提供
* `h[k]` 由运行前加载的系数存储体提供
* `y[n]` 为内部全精度结果，经量化后输出到下游

## 4.2 frame 边界处理功能

FIR 与 CIC 不同，它必须显式处理帧边界。原因在于：

* FIR 是有限长度卷积器
* 前一帧残留在延迟线中的数据会污染下一帧
* 最后一笔有效输入样本需要经过尾部若干拍传播后，才能对输出产生完整贡献。

因此，本模块必须支持：

* **Head Flush**：帧头清洗脏数据
* **Tail Flush**：帧尾释放残余卷积能量

---

## 5. 参数定义

| 参数名称            | 默认值 |    范围 | 说明               |
| --------------- | --: | ----: | ---------------- |
| `GP_IN_WIDTH`   |  24 |  8~32 | 输入数据位宽，承接 CIC 输出 |
| `GP_OUT_WIDTH`  |   8 |  4~16 | 输出数据位宽，送往 CNN    |
| `GP_COEF_WIDTH` |  16 |  8~24 | FIR 系数位宽         |
| `GP_FIR_N`      |  64 | 4~256 | tap 数            |
| `GP_SHIFT`      |  18 |  0~63 | 输出算术右移位数         |
| `GP_ROUND_EN`   |   1 |   0/1 | 是否启用 rounding    |
| `GP_SAT_EN`     |   1 |   0/1 | 是否启用 saturation  |

这些参数与原始 FIR spec 中的 tap 数、shift、输入输出位宽定义方向一致。

## 5.1 中间位宽建议

内部乘法结果位宽：

[
W_{mul} = GP_IN_WIDTH + GP_COEF_WIDTH
]

加法树输出建议位宽：

[
W_{acc} = W_{mul} + \lceil \log_2(GP_FIR_N) \rceil
]

实现可以更保守，但不得低于该推荐值，否则可能产生未定义溢出风险。

---

## 6. 顶层接口定义

## 6.1 顶层端口

```systemverilog id="5cdf9r"
module filter_fir_compensator #(
    parameter int GP_IN_WIDTH   = 24,
    parameter int GP_OUT_WIDTH  = 8,
    parameter int GP_COEF_WIDTH = 16,
    parameter int GP_FIR_N      = 64,
    parameter int GP_SHIFT      = 18
) (
    input  logic                           clk_i,
    input  logic                           rst_ni,

    input  logic                           fir_en_i,

    input  logic                           s_axis_tvalid,
    output logic                           s_axis_tready,
    input  logic signed [GP_IN_WIDTH-1:0]  s_axis_tdata,
    input  logic                           s_axis_tlast,
    input  logic [0:0]                     s_axis_tuser,

    output logic                           m_axis_tvalid,
    input  logic                           m_axis_tready,
    output logic signed [GP_OUT_WIDTH-1:0] m_axis_tdata,
    output logic                           m_axis_tlast,
    output logic [0:0]                     m_axis_tuser,

    input  logic                           coef_load_start_i,
    input  logic                           coef_load_valid_i,
    input  logic signed [GP_COEF_WIDTH-1:0] coef_data_i,
    input  logic                           coef_load_done_i,

    output logic                           fir_busy_o,
    output logic                           coef_ready_o,
    output logic                           fir_cfg_err_o,
    output logic                           coef_load_err_o
);
```

---

## 7. 输入输出接口语义

## 7.1 输入接口

| 信号                | 方向  | 说明        |
| ----------------- | --- | --------- |
| `s_axis_tvalid`   | in  | 输入样本有效    |
| `s_axis_tready`   | out | FIR 可接收输入 |
| `s_axis_tdata`    | in  | 输入数据      |
| `s_axis_tlast`    | in  | 输入帧尾      |
| `s_axis_tuser[0]` | in  | 输入帧头      |

### 7.1.1 输入接收条件

当以下条件同时成立时，FIR 接收一个输入样本：

* `fir_en_i = 1`
* `s_axis_tvalid = 1`
* 当前不在 “系数装载专用锁定期” 或者该实现允许并行输入

### 7.1.2 `s_axis_tready` 语义

v1 建议固定：

* 正常运行态：`s_axis_tready = 1`
* 若模块正在进行强制 head flush 初始化，且设计不允许同时吃输入，则可暂时拉低
* 若系统采用严格的“先装系数，后开流”方式，则运行期内 `s_axis_tready` 可恒为 1

---

## 7.2 输出接口

| 信号                | 方向  | 说明          |
| ----------------- | --- | ----------- |
| `m_axis_tvalid`   | out | 输出样本有效      |
| `m_axis_tready`   | in  | 下游 ready    |
| `m_axis_tdata`    | out | 量化后的 FIR 输出 |
| `m_axis_tlast`    | out | 输出帧尾        |
| `m_axis_tuser[0]` | out | 输出帧头        |

### 7.2.1 输出握手原则

FIR 输出有效样本必须满足：

* `m_axis_tvalid` 仅在最终量化输出有效时拉高
* `m_axis_tdata / tuser / tlast` 必须与该拍输出严格对齐
* 若下游存在不可预测 backpressure，则必须由输出 FIFO / staging buffer 解耦，避免破坏 tail flush 连续性。

### 7.2.2 非 valid 周期

当 `m_axis_tvalid=0` 时：

* `m_axis_tlast=0`
* `m_axis_tuser=0`
* `m_axis_tdata` 可保持上值

---

## 8. 系数加载协议

这是 FIR v1 spec 必须冻结的一部分。

## 8.1 系数来源

结合 CSR spec，v1 系数最终来源为软件通过 memory-mapped port 装载到内部系数存储，再映射到 `coef_*` 本地接口。你前一版 CSR spec 已经把 `FIR_COEF_PORT / FIR_COEF_CTRL / FIR_COEF_COUNT` 固定下来了。
这与原 FIR 文档中的“动态重配系数”设计思想一致，只是把喂入方式统一成软件协议。

## 8.2 装载顺序

系数顺序固定为：

[
h[0] \rightarrow h[1] \rightarrow \cdots \rightarrow h[GP_FIR_N - 1]
]

不得使用反向顺序，避免软件和 RTL 语义不一致。

## 8.3 装载时序

推荐协议：

1. `coef_load_start_i=1`：开始新一轮系数装载
2. `coef_load_valid_i=1` 时，每拍装入一个系数
3. 共接收 `GP_FIR_N` 个系数
4. `coef_load_done_i=1`：声明装载完成
5. `coef_ready_o=1`：模块接受该组系数为当前有效系数

## 8.4 装载错误

以下情形必须报错：

* 系数数量不足
* 多装
* 未 `start` 就写入
* busy 状态下非法重装
* 装载完成前启动 FIR 运行

发生时：

* `coef_load_err_o=1`
* 上报 `ERR_FIR_COEF_INCOMPLETE` 或 `ERR_FIR_COEF_LOAD`
* `coef_ready_o=0`

---

## 9. 微架构要求

## 9.1 数据延迟线

* 使用长度为 `GP_FIR_N` 的同步移位寄存器链 `r_x[]`
* 每接收一个有效输入样本，整体移位一次
* `r_x[0]` 接收最新输入

## 9.2 系数存储体

* 使用长度为 `GP_FIR_N` 的系数寄存器阵列或小型 RAM
* 正常运行期间系数必须稳定不变
* busy 时不允许更新当前活动系数集

## 9.3 并行乘法器阵列

* 共 `GP_FIR_N` 个乘法通路
* 每拍对当前延迟线窗与全部系数做并行乘法
* 输出进入流水线加法树

## 9.4 流水线加法树

* 采用二叉树或等价并行累加结构
* 每级后可插入寄存器
* 潜伏期推荐为：

[
LAT_{adder} = \lceil \log_2(GP_FIR_N) \rceil
]

这与原始 FIR 文档“基于二叉树结构、每级插入流水线寄存器”的方向一致。

## 9.5 量化与输出级

加法树末级后串接：

1. rounding
2. arithmetic shift right
3. saturation clamp
4. output sideband alignment

---

## 10. Head Flush / Tail Flush 机制

这是该模块最关键的系统行为。

## 10.1 Head Flush 目的

在新帧开始前，用 0 值清洗输入延迟线，避免上一帧残留数据污染当前帧。
这一思想在你原始 FIR spec 中已经明确提出。

## 10.2 Head Flush 触发

当检测到以下条件之一时触发：

* 新一帧开始且 `AUTO_HEAD_FLUSH_EN=1`
* 系数重配完成后第一次运行
* soft reset 后首次运行

## 10.3 Head Flush 行为

Head Flush 期间：

* 连续向数据延迟线灌入 `0`
* flush 拍数固定为 `GP_FIR_N`
* 若设计要求与系数重装绑定，则允许“装系数 + 灌 0”并行进行。这个与原文档描述一致。

## 10.4 Tail Flush 目的

让帧尾最后一笔输入样本对卷积输出的残余贡献全部释放出来，避免尾样本信息丢失。

## 10.5 Tail Flush 触发

当接收到：

* `s_axis_tvalid=1`
* `s_axis_tlast=1`

后，模块在该拍接收最后一笔有效样本，并进入 tail flush。

## 10.6 Tail Flush 行为

Tail Flush 期间：

* 连续向数据延迟线注入 `0`
* 继续推动乘法器阵列和加法树运行
* flush 拍数固定为 `GP_FIR_N - 1`

这与原始文档中的定义保持一致。

---

## 11. 帧边界与 sideband 对齐规则

## 11.1 输入帧头

输入帧头定义为：

* `s_axis_tvalid=1`
* `s_axis_tuser[0]=1`

## 11.2 输入帧尾

输入帧尾定义为：

* `s_axis_tvalid=1`
* `s_axis_tlast=1`

## 11.3 输出帧头定义

输出首个有效输出样本对应：

* 当前帧经过 head flush、卷积和流水线对齐后的**第一笔有效结果**
* 该拍拉高 `m_axis_tuser[0]=1`

## 11.4 输出帧尾定义

输出最后一个有效输出样本对应：

* 当前帧最后一笔有效输入经 tail flush 完全释放后的**最后一笔有效卷积输出**
* 该拍拉高 `m_axis_tlast=1`

## 11.5 `valid/user/last` 延迟对齐

所有 sideband 信号必须与数据沿相同 pipeline 延迟前推。
若总数据路径延迟为：

[
LAT_{fir} = LAT_{mul} + LAT_{adder} + LAT_{quant}
]

则 `valid/user/last` 必须经过相同长度的 shift pipeline 对齐。

原始 FIR 文档已明确提到用移位寄存器对齐 `tvalid/tlast`，这里将其系统化冻结。

---

## 12. 量化与数值规则

## 12.1 内部算术

* 所有乘法与加法均使用 `signed` 补码有符号运算
* 中间路径不得提前截断
* 系数和输入均按各自位宽做符号扩展

## 12.2 输出右移

末级全精度结果按 `GP_SHIFT` 做算术右移。

## 12.3 rounding 规则

当 `ROUND_EN=1` 时，采用 **Round Half Up**：

[
rounded = acc + 2^{(GP_SHIFT-1)}
]

然后再做算术右移。
这个规则和你之前 DSP_CNN_SPEC 里写的再量化逻辑是一致的。

## 12.4 saturation 规则

当右移结果超出 `GP_OUT_WIDTH` 可表示范围时：

* 正溢出：输出最大正值
* 负溢出：输出最小负值

例如当 `GP_OUT_WIDTH=8` 时：

* 正饱和：`8'h7F`
* 负饱和：`8'h80`

这一点与你原始 DSP_CNN_SPEC 中对 Q-format 截断与饱和的定义一致。

## 12.5 禁止行为

本模块不得：

* 在乘法器阵列前裁剪输入
* 在加法树中途截断
* 在最终饱和前使用无符号比较

---

## 13. 状态机定义

## 13.1 建议状态

模块内部建议至少包含以下状态：

1. `IDLE`
2. `COEF_LOAD`
3. `HEAD_FLUSH`
4. `RUN`
5. `TAIL_FLUSH`
6. `DONE`
7. `ERROR`

## 13.2 状态语义

### `IDLE`

* 等待配置与系数就绪
* `fir_busy_o=0`

### `COEF_LOAD`

* 接收系数
* `coef_ready_o=0`

### `HEAD_FLUSH`

* 输入延迟线灌 0
* 可选与系数装载并行

### `RUN`

* 正常接收输入样本
* 输出有效卷积结果

### `TAIL_FLUSH`

* 帧尾灌 0
* 释放尾部卷积贡献

### `DONE`

* 本帧处理完成
* 等待系统侧清理或再次启动

### `ERROR`

* 参数非法或协议错误
* 等待清错或软复位

---

## 14. 控制与状态信号

## 14.1 `fir_en_i`

* `0`：模块不接受新输入
* `1`：模块允许运行

## 14.2 `fir_busy_o`

以下任一条件成立时置高：

* 系数装载中
* head flush 中
* 正常运行中
* tail flush 中
* 尚有输出 pipeline 未排空

## 14.3 `coef_ready_o`

仅当：

* 系数数量正确
* `coef_load_done_i` 完成
* 未检测到装载错误

时拉高。

## 14.4 `fir_cfg_err_o`

参数非法时置高，例如：

* `GP_FIR_N = 0`
* `GP_SHIFT` 越界
* 运行期非法重配

## 14.5 `coef_load_err_o`

系数协议错误时置高。

---

## 15. CSR 映射关系

本模块与 CSR spec 对应关系如下：

| CSR                            | 含义                    |
| ------------------------------ | --------------------- |
| `FIR_CFG0.TAP_NUM`             | `GP_FIR_N` / 当前 tap 数 |
| `FIR_CFG0.SHIFT`               | `GP_SHIFT`            |
| `FIR_CFG0.FIR_EN`              | `fir_en_i`            |
| `FIR_CFG1.COEF_RELOAD_EN`      | 每帧重装模式                |
| `FIR_CFG1.AUTO_HEAD_FLUSH_EN`  | 头部自动 flush            |
| `FIR_CFG1.AUTO_TAIL_FLUSH_EN`  | 尾部自动 flush            |
| `FIR_CFG1.ROUND_EN`            | rounding 使能           |
| `FIR_CFG1.SAT_EN`              | saturation 使能         |
| `FIR_STATUS.FIR_BUSY`          | `fir_busy_o`          |
| `FIR_STATUS.COEF_READY`        | `coef_ready_o`        |
| `FIR_STATUS.HEAD_FLUSH_ACTIVE` | 头部 flush 活动           |
| `FIR_STATUS.TAIL_FLUSH_ACTIVE` | 尾部 flush 活动           |
| `FIR_STATUS.FIR_CFG_ERR`       | `fir_cfg_err_o`       |
| `FIR_STATUS.COEF_LOAD_ERR`     | `coef_load_err_o`     |

这与前一版 CSR spec 已经保持一致。也继承了原始 FIR 文档的 tap、shift、flush 和动态系数装载思路。

---

## 16. 运行时约束与非法行为

## 16.1 Busy 时禁止重配

当 `fir_busy_o=1` 或系统 `BUSY=1` 时，不允许修改：

* `TAP_NUM`
* `SHIFT`
* `ROUND_EN`
* `SAT_EN`
* 活动系数集

非法写入时：

* 原值保持不变
* 上报 `ERR_CFG_WRITE_WHILE_BUSY`
* 触发 `IRQ_ERR`

## 16.2 系数未就绪禁止启动

若 `coef_ready_o=0` 且尝试启动运行：

* 拒绝进入 `RUN`
* 报 `ERR_FIR_COEF_INCOMPLETE`

## 16.3 输入帧异常

以下情况必须视为错误或拒绝运行：

* 帧头缺失
* 帧尾缺失且系统配置要求 frame mode
* 新帧在 tail flush 未结束前到来
* frame 长度为 0

## 16.4 输出 backpressure 约束

v1 固定要求：

* FIR 算法本身不应因下游偶发不 ready 而中断 flush 语义
* 若系统集成存在 backpressure，必须在 FIR 输出后加 FIFO/staging buffer
* 直接将 `m_axis_tready` 用作停机条件是**不允许**的，除非 wrapper 层吸收该复杂度

---

## 17. 复位行为

## 17.1 硬复位

当 `rst_ni=0` 时，必须：

* 清控制状态机
* 清输入延迟线
* 清 sideband pipeline
* 清 active frame 状态
* 清系数 ready 状态或将其置为实现定义的安全缺省

## 17.2 软复位

软复位至少必须：

* 终止当前 head/tail flush
* 清 busy
* 清协议错误状态
* 使模块返回 `IDLE`

### 17.2.1 关于数据路径 reset

原始 FIR spec 采用“控制复位 + 用 flush 洗净数据路径”的思路。这里仍允许这样实现，但系统可见行为必须等价于：

* 复位后不会输出上一帧污染数据
* 下一个合法 frame 必须在 fresh state 上运行。

---

## 18. 错误模型

本模块至少要识别以下错误：

### 18.1 配置错误

* tap 数非法
* shift 非法
* 参数写保护违例

### 18.2 系数错误

* 未装满
* 过量装载
* 顺序错乱
* busy 时重装

### 18.3 运行时协议错误

* frame mode 下 frame 边界异常
* tail flush 未结束时新帧到达
* 输出结果被覆盖（若无 FIFO 保护）

### 18.4 数值错误

通常不对正常算术溢出报错，因为最终由 saturation 处理。
但若实现检测到内部位宽配置不足，可在 build-time 或 elaboration-time 报错，不建议做 runtime 检测。

---

## 19. 性能与延迟要求

## 19.1 输入吞吐

在正常 `RUN` 态，FIR 至少应支持：

* 1 valid sample / cycle 的输入推进能力

## 19.2 延迟定义

总延迟建议定义为：

[
LAT_{fir} = LAT_{mul} + \lceil \log_2(GP_FIR_N) \rceil + LAT_{quant}
]

实现必须在 RTL 包中冻结：

* `LAT_mul`
* `LAT_quant`
* `LAT_fir_total`

## 19.3 flush 成本

* head flush 成本：`GP_FIR_N`
* tail flush 成本：`GP_FIR_N - 1`

这两个值必须被 system/DV 作为可预期周期使用。

---

## 20. 验证要求

## 20.1 功能正确性

至少覆盖：

1. impulse input
2. step input
3. sinusoid input
4. random input
5. full-scale positive/negative edge case

## 20.2 系数协议验证

必须覆盖：

* 正常装载 `N` 个系数
* 少装
* 多装
* busy 重装
* 未 `coef_load_done` 就启动
* `coef_ready` 与计数一致性

## 20.3 边界冲刷验证

必须覆盖：

* frame start + head flush
* frame end + tail flush
* 连续两帧输入
* 帧长小于 tap 数
* 空帧 / 单样本帧
* reset 插在 flush 中

## 20.4 数值验证

必须验证：

* signed 乘法正确
* adder tree 与 golden 一致
* rounding 正确
* saturation 正确
* 量化输出与软件模型对齐

## 20.5 sideband 对齐

必须验证：

* `valid` 对齐
* `user[0]` 仅在首个有效输出拉高
* `last` 仅在最后一个有效输出拉高
* 非 valid 周期 sideband 为 0

---

## 21. Golden Model 建议

DV 建议使用软件参考模型执行以下步骤：

1. 初始化输入延迟线为 0
2. 装载系数 `h[0..N-1]`
3. 帧头时执行 head flush（按实现定义）
4. 每个输入样本更新延迟线并做卷积
5. 帧尾时执行 tail flush `N-1` 拍
6. 对每拍全精度结果执行：

   * optional rounding
   * arithmetic shift
   * saturation
7. 同时生成与数据对齐的 `valid/user/last`

Golden 必须使用补码定点行为，而不是浮点近似后再统一裁剪。

---

## 22. 与其他规格书的边界

## 22.1 对 system spec

必须服从：

* frame-based lifecycle
* front-end / back-end 解耦规则
* 结果不得污染下一模块
* busy / err / done 可观测要求

## 22.2 对 CSR spec

必须服从：

* `FIR_CFG0/1`
* `FIR_STATUS`
* `FIR_COEF_PORT / CTRL / COUNT`
* busy 写保护
* 错误码上报

## 22.3 对 CIC spec

必须正确接收来自 CIC 的：

* 全精度补码数据
* 低速 valid 脉冲
* 输入 frame 边界

## 22.4 对 CNN spec

必须输出：

* CNN 接受的低位宽激活
* 对齐 sideband
* 无跨帧污染的数据流

---

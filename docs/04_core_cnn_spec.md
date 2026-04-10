# `04_core_cnn_spec.md`

# DSP-CNN 协处理器

# 1D-CNN 核心推理引擎规格书

**Document ID:** `CORE_CNN_SPEC`
**Version:** `v2.0`
**Applies To:** `DSP_CNN_SYSTEM_SPEC v2.x`, `CSR_INTERRUPT_SPEC v1.x`

---

## 1. 文档目的

本文档定义 DSP-CNN 协处理器中 **1D-CNN 核心推理引擎**的功能范围、模块边界、存储架构、计算阵列、后处理流水、配置寄存器语义、异常行为和验证要求，作为 CNN Core RTL、DV、驱动和系统集成的依据。

本文档覆盖：

* v1 支持的 layer/算子范围
* Ping-Pong CBUF 架构
* Weight Buffer / Bias Buffer / PE Cluster / Post-Processing Array
* layer 配置语义
* Temporal Folding 行为
* quant / activation / pooling 规则
* busy / done / error / debug 状态
* 验证准则与 golden 参考要求

本文档不覆盖：

* Transformer / MHSA / LW-CT 硬件执行单元
* 指令流型 network deployment engine
* DDR spilling / off-chip feature map paging
* 多 batch 并行调度
* v2 之后的复杂 residual graph 调度

---

## 2. v1 范围与模块定位

## 2.1 模块名称

`cnn_inference_engine`

## 2.2 v1 功能范围

本模块在 **v1** 中仅负责 **1D-CNN 推理子集**，包括：

* Conv1D
* Depthwise Conv1D
* 可选 Pointwise Conv1D（若 `KERNEL_SIZE=1` 以 Conv1D 形式实现）
* ReLU
* Max Pooling
* Average Pooling
* Re-Quantization
* 可选 FC 末层输出

这些能力与你当前 core spec 中的 `LAYER_TYPE = Conv / DW-Conv / FC`、ReLU、动态池化池、再量化方向一致。

## 2.3 v1 明确不支持

以下能力不纳入本 spec 的 v1 必交付范围：

* MHSA / Transformer / LW-CT
* Softmax
* GELU / Sigmoid / Tanh
* 任意图结构的 residual routing
* 动态 shape 推断
* runtime arbitrary operator fusion

这样做是为了让 spec 与当前已成型的 CNN 核心结构对齐，而不是被论文中的完整 CNN-Transformer 架构带偏 scope。论文确实包含 MHSA / FC 等扩展模块，但当前你已有的核心文档主体还是围绕 CBUF、Conv、WS、PE Cluster、MPA 展开的。

## 2.4 系统中的角色

CNN Core 位于 FIR 之后、结果输出之前，负责对已量化的一维基带特征流执行 burst-style 推理。system spec 中已明确：

* FIR 把基带序列送入 CNN 的 `CBUF0`
* 当积攒够一帧数据后，Global FSM 唤醒 CNN 阵列进行突发计算。

---

## 3. 设计哲学

本模块遵循以下设计原则：

### 3.1 Memory-Driven Architecture

通过两组可重构的 `CBUF0/CBUF1` 实现跨层特征图复用和读写角色翻转，减轻内存墙压力。

### 3.2 Weight Stationary Dataflow

权重优先驻留在 Weight Buffer 和 PE 内部双寄存器中，输入激活流经 PE 阵列，降低权重搬运开销。

### 3.3 Temporal Folding + Spatial Unrolling

物理实现固定数量的 PE Cluster；当 `IN_CH` 或 `OUT_CH` 超出物理并行度时，由 FSM 做多轮时分折叠累加。

### 3.4 Full Fixed-Point Pipeline

v1 统一采用定点计算链：

* 输入激活：8-bit
* 权重：8-bit
* 中间累加：32-bit
* 输出：8-bit

这与你现有 core/spec 草案中的建议值一致。

---

## 4. 顶层架构

本模块由四个子系统组成：

1. **存储子系统**

   * Input Staging Buffer
   * Ping-Pong CBUF
   * Weight Buffer
   * Bias Buffer

2. **计算子系统**

   * Data Distribution Network
   * PE Cluster Array
   * Channel Accumulation / Psum Path

3. **后处理子系统**

   * Activation Unit
   * Pooling Unit
   * Re-Quantization Unit

4. **控制与监控子系统**

   * Global FSM / Layer FSM
   * Folding Controller
   * Address Generator
   * Status / Debug / Performance Counter

---

## 5. 支持矩阵（Support Matrix）

这一章必须冻结，避免后续 scope 漂移。

| Operator / Feature | v1 Support                  | 说明                          |
| ------------------ | --------------------------- | --------------------------- |
| Conv1D             | Yes                         | 主路径                         |
| Depthwise Conv1D   | Yes                         | 通过 CBUF 特定读模式实现             |
| Pointwise Conv1D   | Yes, constrained            | 作为 `KERNEL_SIZE=1` 的 Conv1D |
| FC                 | Optional                    | 仅末层、受资源约束                   |
| BN                 | Folded only                 | 不作为独立硬件算子                   |
| ReLU               | Yes                         | 符号位判断实现                     |
| 1/L * ReLU         | Optional                    | v1 可保留编码位，但默认不启用            |
| Max Pooling        | Yes                         | 基于滑动窗口 / 比较器树               |
| Avg Pooling        | Yes                         | 基于累加器                       |
| Softmax            | No                          | 留给软件或后续版本                   |
| Transformer / MHSA | No                          | 不在 v1 范围                    |
| Residual Add       | No, unless explicitly fused | v1 不作为通用图算子                 |
| Padding            | Yes, constrained            | 由输入/流水机制支持，见第 10 章          |

---

## 6. 参数定义

| 参数名称                |          默认值 |    范围 | 说明                     |
| ------------------- | -----------: | ----: | ---------------------- |
| `GP_DATA_WIDTH`     |            8 |  4~16 | 激活位宽                   |
| `GP_WEIGHT_WIDTH`   |            8 |  4~16 | 权重位宽                   |
| `GP_ACC_WIDTH`      |           32 | 16~40 | 累加器位宽                  |
| `GP_PE_MAC_NUM`     |            3 |  1~15 | 单 PE 支持的最大 kernel size |
| `GP_PE_CLUSTER_NUM` |           64 | 8~256 | 物理并行 PE 数              |
| `GP_CBUF_BANK_NUM`  | impl-defined |   >=2 | CBUF bank 数            |
| `GP_CBUF_DEPTH`     | impl-defined |    >0 | 单 bank 深度              |
| `GP_MAX_LAYER_NUM`  | impl-defined |    >0 | 最大层数                   |
| `GP_MAX_SEQ_LEN`    | impl-defined |    >0 | 最大支持序列长度               |
| `GP_MAX_IN_CH`      | impl-defined |    >0 | 最大支持输入通道               |
| `GP_MAX_OUT_CH`     | impl-defined |    >0 | 最大支持输出通道               |

你原始文档中已经明确了几个核心默认值：`GP_PE_MAC_NUM=3`、`GP_PE_CLUSTER_NUM=64`、`GP_DATA_WIDTH=8`、`GP_ACC_WIDTH=32`、`GP_WEIGHT_WIDTH=8`。这里直接保留并系统化。

---

## 7. 顶层接口定义

## 7.1 顶层端口

```systemverilog id="h8j1si"
module cnn_inference_engine #(
    parameter int GP_DATA_WIDTH       = 8,
    parameter int GP_WEIGHT_WIDTH     = 8,
    parameter int GP_ACC_WIDTH        = 32,
    parameter int GP_PE_MAC_NUM       = 3,
    parameter int GP_PE_CLUSTER_NUM   = 64
) (
    input  logic                            clk_i,
    input  logic                            rst_ni,

    input  logic                            cnn_en_i,
    input  logic                            start_i,
    input  logic                            soft_rst_i,

    input  logic                            s_axis_tvalid,
    output logic                            s_axis_tready,
    input  logic signed [GP_DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                            s_axis_tlast,
    input  logic [0:0]                      s_axis_tuser,

    output logic                            m_axis_tvalid,
    input  logic                            m_axis_tready,
    output logic signed [GP_DATA_WIDTH-1:0] m_axis_tdata,
    output logic                            m_axis_tlast,
    output logic [0:0]                      m_axis_tuser,

    output logic                            cnn_busy_o,
    output logic                            cnn_done_o,
    output logic                            cnn_err_o
);
```

## 7.2 输入接口语义

CNN Core 输入来自 FIR 或输入 staging buffer。system spec 已经定义：FIR 过滤后的基带序列送入 CNN 的 `CBUF0`，当积累到一帧后开始计算。

v1 接口语义固定为：

* `s_axis_tvalid`：输入激活样本有效
* `s_axis_tdata`：按配置格式写入输入 feature map
* `s_axis_tuser[0]`：输入帧头
* `s_axis_tlast`：输入帧尾
* `s_axis_tready`：当 input staging / CBUF 写入口可接收时为 1

### 7.2.1 输入模式

v1 采用 **frame-based input fill** 模式：

* 在 `IDLE/LOAD_INPUT` 状态接收一整帧输入
* 当前帧写入 `CBUF0` 或 input staging 区
* 达到 `SEQ_LEN * IN_CH` 预期样本数后，切换到 `COMPUTE`

## 7.3 输出接口语义

* 分类模式下：`m_axis_tdata` 输出 `class_id` 或 score 向量
* 向量模式下：输出最后一层 feature / FC 结果
* `m_axis_tuser[0]`：结果起始
* `m_axis_tlast`：结果结束

`m_axis_tready` 允许参与结果口 backpressure，但不得反向影响已经开始的层内运算；若需要，必须通过 result FIFO 或 result register 解耦。这个约束与前面 system/FIR 里对后端 buffered burst island 的定义一致。

---

## 8. 存储子系统

## 8.1 Input Staging

输入 staging 区负责从 FIR 侧接收一帧输入，并按 CBUF 写格式整理数据。
v1 要求：

* 至少能容纳一整帧原始输入
* 能把单通道或多通道输入重排为 CBUF 可读格式

## 8.2 Ping-Pong CBUF

这是本模块的核心存储结构。你当前文档中已经明确：

* 由 `CBUF0` 和 `CBUF1` 两组 BRAM/URAM 组成
* 计算层 `L` 时从一组读、向另一组写
* 层 `L+1` 时读写角色翻转
* 支持普通卷积和 DWConv 的不同读模式。

### 8.2.1 结构要求

* `CBUF0` / `CBUF1` 必须逻辑独立
* 每组至少支持：

  * 1 路写入
  * 1 路读取
  * banked / channel-wise 并行访问

### 8.2.2 操作模式

* 当前层读取 `CBUF_RD_SEL`
* 当前层写回 `CBUF_WR_SEL`
* 层完成后自动 flip

### 8.2.3 CBUF 容量约束

对于每层，必须满足：

[
FeatureMapSize_{in} \le CBUF_{read_capacity}
]
[
FeatureMapSize_{out} \le CBUF_{write_capacity}
]

若不满足，必须在 `START` 前拒绝运行并上报 `ERR_CNN_PARAM_ILLEGAL` 或 `ERR_CBUF_OVERFLOW`。这一点是你原文档里没有写死、但系统级必须补上的。

## 8.3 Weight Buffer

论文参考和你的草案都提到了 Weight Buffer / 双寄存器预取机制：

* 权重先进入 Weight Buffer
* 再在一个时钟周期送入 PE 内部权重寄存器
* 每个 PE 配两套权重寄存器，形成两级流水掩盖访存。

v1 固定要求：

* Weight Buffer 必须支持当前 fold 与下一 fold 的权重切换
* busy 时禁止覆盖当前活动权重集
* Weight Buffer 地址由 layer config 提供

## 8.4 Bias Buffer

Bias Buffer 用于缓存当前层输出通道的 bias 参数。论文参考明确存在 `Bias_Buf`。
v1 要求：

* 每个输出通道可取到一个 bias
* bias 注入点固定在跨通道累加完成之后、激活之前

---

## 9. 计算子系统

## 9.1 Data Distribution Network

该网络负责把 CBUF 中的 feature map 数据分发到各个 PE。你在早期草案中已写到“将 FM_BUF 中的多通道数据广播给各个 PE”。

v1 要求：

* Conv1D 模式：支持按时间维滑窗、按输出通道展开
* DWConv 模式：支持逐通道独立读取与计算
* Pointwise 模式：等价于 `KERNEL_SIZE=1` 的 Conv1D

## 9.2 PE Cluster Array

### 9.2.1 结构

每个 PE 包含：

* 输入抽头延迟线 `TDL`
* `GP_PE_MAC_NUM` 个乘法路径
* 本地加法树 / MAC 树
* 双权重寄存器 `w0 / w1`

这些都与你现有 core spec 和草案保持一致。

### 9.2.2 kernel size 支持

* 单 PE 支持的最大 `KERNEL_SIZE` 为 `GP_PE_MAC_NUM`
* 若配置的 `KERNEL_SIZE > GP_PE_MAC_NUM`，v1 直接视为非法配置
* 不在 v1 中支持 kernel 方向再折叠

### 9.2.3 TDL 行为

* 每拍移入一个新样本
* 同时并行输出当前窗口中的 `KERNEL_SIZE` 个点
* 在 Conv1D 模式下，TDL 承担滑窗展开
* 在 pointwise 模式下，仅使用第 1 个 tap

### 9.2.4 zero padding 语义

原始文档和论文参考都提到，流水/寄存器链可以在不显式构造大块 zero-padded feature map 的情况下处理边界。
v1 统一规定：

* `PADDING=0`：不补零
* `PADDING>0`：由地址发生器/输入边界逻辑在窗口越界处提供 0 值
* 不能把“自动补零”写成模糊行为，必须与 `PADDING` 配置绑定

## 9.3 跨通道累加与 Psum Path

对于标准 Conv1D：

* 先做单输入通道卷积
* 再在多个 `IN_CH` 上做跨通道累加
* 最后加 bias 得到一个输出通道结果

这与你论文参考里“先计算所有卷积核的单通道结果，再循环加总所有通道并加 bias”的顺序一致。

v1 要求：

* 对于 `IN_CH > GP_PE_CLUSTER_NUM` 的情况，必须通过 folding 多轮累加
* 中间 partial sum 必须保存在 `GP_ACC_WIDTH` 位宽路径中
* 不允许中途 requant

---

## 10. 支持的 layer 语义

## 10.1 Conv1D

输入 shape：

[
[L, C_{in}]
]

输出 shape：

[
[L_{out}, C_{out}]
]

其中：

[
L_{out} = \left\lfloor \frac{L + 2P - K}{S} \right\rfloor + 1
]

* `K` = `KERNEL_SIZE`
* `S` = `STRIDE`
* `P` = `PADDING`

## 10.2 Depthwise Conv1D

DWConv 模式要求：

* `OUT_CH = IN_CH`
* 每个输入通道独立卷积
* CBUF 采用 channel-wise 读模式

你的原文档已经提到 DWConv 是通过不同的 CBUF 读法实现的。

## 10.3 Pointwise Conv1D

当：

* `LAYER_TYPE = Conv1D`
* `KERNEL_SIZE = 1`

时，按 pointwise 处理。论文参考也提到 point convolution 可以通过 PE 参数配置支持。

## 10.4 Pooling

支持：

* MaxPool
* AvgPool

输出长度：

[
L_{out,pool} = \left\lfloor \frac{L_{in} - PoolSize}{PoolStride} \right\rfloor + 1
]

默认 v1 不支持 ceil mode。

## 10.5 FC

FC 仅作为末层可选算子：

* 输入视为一维向量
* 输出长度由 `OUT_CH` 给出
* 若启用 FC，CBUF 可配置为简单的读/写分区模式。论文参考中 FC 也走 Ping-Pong CBUF 的并行读写模式。

---

## 11. 后处理子系统

## 11.1 Activation Unit

当前文档里已经明确使用硬件 ReLU：

* 仅检查 32-bit 累加结果符号位
* 负数输出 0
* 正数透传。

v1 冻结：

* `ACT_TYPE=0`：None
* `ACT_TYPE=1`：ReLU
* `ACT_TYPE=2`：保留给 `1/L * ReLU`，默认不在 v1 打开

## 11.2 Pooling Unit

支持：

* `POOL_TYPE=0`：None
* `POOL_TYPE=1`：Max
* `POOL_TYPE=2`：Avg

实现要求：

* MaxPool：比较器树或滑窗最大值寄存器
* AvgPool：窗口累加后做常数除法/移位近似，若 pool size 非 2 的幂，则具体实现须在 RTL 包中冻结

## 11.3 Re-Quantization Unit

现有文档已经明确了 32-bit 到 8-bit 的右移 + round + saturate 逻辑。
v1 统一规定：

1. `rounded_val = acc_out + (1 << (shift-1))`
2. arithmetic right shift by `QUANT_SHIFT`
3. saturate 到输出位宽范围

当 `GP_DATA_WIDTH=8` 时：

* 正饱和：`8'h7F`
* 负饱和：`8'h80`

---

## 12. 控制与状态机

## 12.1 建议状态

1. `IDLE`
2. `LOAD_INPUT`
3. `CHECK_CFG`
4. `LOAD_WEIGHT`
5. `COMPUTE`
6. `POST_PROCESS`
7. `WRITE_BACK`
8. `DONE`
9. `ERROR`

你之前的系统草案已经有类似 `IDLE -> LOAD_WEIGHT -> COMPUTE -> WRITE_BACK` 的思路，这里把输入装载和配置检查补全。

## 12.2 状态语义

### `IDLE`

等待 `start_i` 和合法配置。

### `LOAD_INPUT`

接收来自 FIR/上游的整帧输入，并写入输入区或 `CBUF0`。

### `CHECK_CFG`

检查所有 layer 参数和 CBUF 容量是否合法。

### `LOAD_WEIGHT`

装载当前 layer / 当前 fold 的权重和 bias。

### `COMPUTE`

驱动 PE Cluster 执行卷积或 FC。

### `POST_PROCESS`

执行 ReLU / Pool / Re-Quant。

### `WRITE_BACK`

把当前层输出写入写侧 CBUF。

### `DONE`

一帧网络推理完成。

### `ERROR`

发生非法配置或运行时错误，等待清错或 soft reset。

---

## 13. Folding 与吞吐语义

## 13.1 Folding 触发条件

当任一条件满足时触发 folding：

* `IN_CH > GP_PE_CLUSTER_NUM`
* `OUT_CH > GP_PE_CLUSTER_NUM`
* 当前层资源映射无法一次性完全展开

## 13.2 Folding 规则

* 每个 fold 处理一部分通道
* 同一输出元素的 partial sums 必须在多个 fold 之间累加
* fold 完成后方可进入 bias / activation / pooling

## 13.3 性能公式

实现必须在 RTL 文档中固定至少以下两个统计量：

* 单层总 cycles
* folding 次数 `fold_cnt`

论文参考中已经给出 convolution throughput 的分析，并指出两级流水能掩盖权重加载带来的时延。你可以把它作为性能背景，但 v1 spec 更重要的是把硬件可观测计数器冻结下来。

---

## 14. 数据布局与地址规则

这一部分是原 spec 最缺的地方。

## 14.1 输入 feature map layout

v1 统一规定 CBUF 中的 feature map 逻辑布局为：

[
[C][L]
]

即：

* 通道优先
* 每个通道下按时间序列连续存放

这样更容易兼容 DWConv 的 channel-wise 读取模式。

## 14.2 Conv1D 读取模式

* 读取某个输入通道的一段连续序列
* 送入 TDL 滑窗
* 跨通道累加形成输出通道结果

## 14.3 DWConv 读取模式

* 每个输入通道独立读取
* 不做跨通道卷积混合
* 输出通道与输入通道一一对应

## 14.4 写回布局

输出 feature map 继续按 `[C][L]` 布局写入写侧 CBUF。

---

## 15. CSR 映射关系

CNN Core 受你上一版 CSR spec 约束。与当前模块直接对应的寄存器包括：

* `CNN_GLOBAL_CFG`
* `CNN_CTRL`
* `CNN_STATUS`
* `LAYERn_CFG0`
* `LAYERn_CFG1`
* `LAYERn_CFG2`
* `LAYERn_CFG3`

你原始 core spec 也给出了类似 `LAYER_TYPE / CH_CFG / SPATIAL_CFG / STRIDE_PAD / POST_ACT / QUANT_SCALE` 的入口。这里统一收敛到前面已经定下来的 layer 窗口。

### 15.1 关键字段语义

* `LAYER_TYPE`：0=Conv1D, 1=DWConv1D, 2=Pool, 3=FC
* `IN_CH` / `OUT_CH`
* `SEQ_LEN`
* `KERNEL_SIZE`
* `STRIDE`
* `PADDING`
* `POOL_SIZE`
* `POOL_TYPE`
* `ACT_TYPE`
* `QUANT_SHIFT`
* `WBUF_ADDR`
* `BIAS_ADDR`

---

## 16. 合法性检查与异常行为

这一章必须写死，否则后面 RTL 和 DV 会来回扯。

## 16.1 启动前必须检查

以下情况必须拒绝启动：

* `LAYER_NUM = 0`
* 任意层 `IN_CH = 0`
* 任意层 `OUT_CH = 0`（Pool 层除外）
* 任意层 `SEQ_LEN = 0`
* `KERNEL_SIZE = 0`
* `KERNEL_SIZE > GP_PE_MAC_NUM`
* `POOL_TYPE != None` 但 `POOL_SIZE = 0`
* DWConv 层 `OUT_CH != IN_CH`
* layer 所需输入/输出 feature map 超过 CBUF 容量
* 权重或 bias 地址越界

## 16.2 Busy 写保护

当 `cnn_busy_o=1` 或系统 `BUSY=1` 时，禁止修改：

* `CNN_GLOBAL_CFG`
* `LAYERn_CFGx`
* 当前活动权重和 bias 地址映射

违反时：

* 原值保持
* 置 `cnn_err_o`
* 上报 `ERR_CFG_WRITE_WHILE_BUSY` 或 `ERR_CNN_PARAM_ILLEGAL`

## 16.3 运行时错误

必须至少识别：

* `ERR_CBUF_OVERFLOW`
* `ERR_CBUF_UNDERFLOW`
* `ERR_RESULT_OVERRUN`
* `ERR_TIMEOUT_CNN`
* `ERR_CNN_PARAM_ILLEGAL`

这些错误码在上一版 CSR spec 里已经冻结。这里核心是把触发条件和 CNN block 的行为绑定起来。

---

## 17. 复位行为

## 17.1 硬复位

当 `rst_ni=0` 时，必须：

* 清 Global FSM / layer FSM
* 清 CBUF valid / active selector
* 清 partial sum 状态
* 清当前 layer index / fold index
* 清 done / error / result valid

## 17.2 软复位

软复位至少必须：

* 终止当前计算
* 丢弃未提交的 partial sum
* 清当前活动 layer 状态
* 返回 `IDLE`

### 17.2.1 权重与系数是否保留

v1 建议：

* 配置寄存器保留
* 运行态缓存（active CBUF valid、psums、fold state）清除
* weight/bias memory 是否保留可实现定义，但系统可见行为必须保证：soft reset 后需要重新 `START`，且不会输出脏结果

---

## 18. 结果输出语义

## 18.1 分类模式

* `RESULT_CLASS_MODE=1`
* 输出 `class_id`
* 可选在 `RESULT1` 输出 confidence / score

## 18.2 向量模式

* 顺序输出最后一层向量
* `m_axis_tuser[0]` 标记首元素
* `m_axis_tlast` 标记末元素

## 18.3 完成条件

只有当以下条件同时满足时，才置 `cnn_done_o=1`：

* 所有层计算完成
* 最后一层输出已写入结果口或结果寄存器
* 当前 frame 的 result valid 已置位

---

## 19. 可测性与调试支持

你前面 system/csr 已经规划了 `ACTIVE_LAYER_IDX`、`ACTIVE_FOLD_IDX` 等状态位，这里 block spec 也要收口。

必须提供：

* 当前活动层号
* 当前 fold index
* 当前读 CBUF / 写 CBUF 选择
* 当前 FSM 状态
* 当前层累计 cycle count
* 当前层 stall count（若实现支持）

---

## 20. 性能计数建议

至少暴露：

* `cnn_busy_cycles`
* `cnn_layer_cycles`
* `fold_count`
* `output_elem_count`

这样以后你做性能归因时，就不是口头说“folding 变慢了”，而是寄存器里能直接量出来。

---

## 21. 验证要求

## 21.1 功能正确性

至少覆盖：

1. 单层 Conv1D
2. 单层 DWConv1D
3. Conv + ReLU
4. Conv + Pool
5. 多层级联 Conv
6. Conv + FC

## 21.2 shape 与边界

必须覆盖：

* 最小 `SEQ_LEN`
* 最大 `SEQ_LEN`
* `KERNEL_SIZE = 1`
* `KERNEL_SIZE = GP_PE_MAC_NUM`
* `STRIDE = 1`
* 带 `PADDING`
* pool size 边界
* DWConv `IN_CH = OUT_CH`

## 21.3 folding

必须覆盖：

* `IN_CH <= GP_PE_CLUSTER_NUM`
* `IN_CH > GP_PE_CLUSTER_NUM`
* `OUT_CH > GP_PE_CLUSTER_NUM`
* 多轮 fold 的 partial sum 正确性

## 21.4 数值正确性

必须验证：

* MAC 树输出正确
* bias 注入正确
* ReLU 正确
* pooling 正确
* requant 正确
* saturation 正确

## 21.5 错误路径

必须覆盖：

* 非法 layer config
* busy 写保护
* CBUF 容量超界
* weight/bias 地址越界
* reset 插入运行中
* result overrun

---

## 22. Golden Model 建议

DV 建议建立软件黄金模型，按以下顺序执行：

1. 从 `[C][L]` 布局解析输入 feature map
2. 按 layer config 执行 Conv1D / DWConv / Pool / FC
3. 对标准 Conv 做跨通道累加和 bias 注入
4. 执行 ReLU
5. 执行 Pool
6. 执行 requant（round + shift + saturate）
7. 生成与硬件一致的 `[C][L]` 或 result vector 输出

关键要求：

* 必须使用与 RTL 一致的定点位宽行为
* 不能只用浮点卷积再最后统一裁剪
* folding 仅影响时序，不影响 golden 数值结果

---

## 23. 与其他规格书的边界

## 23.1 对 system spec

必须服从：

* frame-based lifecycle
* FIR -> CNN burst execution 交接方式
* start/done/error 体系
* buffered burst island 约束

## 23.2 对 CSR spec

必须服从：

* `CNN_GLOBAL_CFG`
* `CNN_CTRL`
* `CNN_STATUS`
* `LAYERn_CFGx`
* 错误码和 busy 写保护规则

## 23.3 对 FIR spec

必须正确接收：

* 8-bit 定点激活流
* 对齐的 frame 边界
* 一帧完整输入

## 23.4 对论文参考的关系

本 spec 借用了论文参考中的几个关键硬件思想：

* Ping-Pong CBUF
* Weight Stationary
* 双权重寄存器两级流水
* Conv / DWConv 的不同读模式
* MPA 风格后处理思路。

但 **v1 不直接实现论文中的 MHSA / 完整 CNN-Transformer 加速器**。这一点在 scope 上已经明确切断。

---


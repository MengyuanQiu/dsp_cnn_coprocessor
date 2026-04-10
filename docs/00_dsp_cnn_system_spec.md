---

# DSP-CNN 边缘智能协处理器主系统规格书

**Document ID:** `DSP_CNN_SYSTEM_SPEC`
**Version:** `v2.0`
**Scope:** `System-Level Specification`
**Applies To:** `CIC Decimator + FIR Compensation + 1D-CNN Inference Core + AXI Control Wrapper`

---

## 1. 文档目的

本文档定义 DSP-CNN 边缘智能协处理器的**系统级功能、接口契约、时钟与复位策略、配置模型、数据流生命周期、错误处理机制、性能约束与模块边界**，作为后续子模块规格书、RTL 设计、验证计划、驱动开发和系统集成的顶层依据。

本文档是以下子规格书的上位约束文档：

* `filter_cic_decimator_spec`
* `filter_fir_compensator_spec`
* `core_cnn_spec`
* `csr_interrupt_spec`
* `system_verification_plan`

---

## 2. 设计目标与范围

### 2.1 设计目标

本协处理器面向**雷达/通信一维序列信号**的低功耗边缘推理场景，目标是在单颗 FPGA/SoC 内实现从高速采样流到分类结果输出的端到端硬件处理链。系统级目标包括：

1. **端到端流式处理**
   从输入采样流进入系统开始，中间数据尽可能在片内自动流转，避免 CPU 干预搬运。该目标与现有 system spec 的 “End-to-End Hardwired” 设计方向保持一致。

2. **前后端速率解耦**
   前端 DSP 链处理连续、高吞吐、不可回压的数据流；后端 CNN 链处理突发、可多周期复用的计算任务；两者通过缓冲与状态机解耦。该目标与原 system spec 中的 “Multi-rate Streaming” 一致。

3. **软件定义、硬件执行**
   系统拓扑参数、滤波参数、CNN 层参数通过 AXI-Lite 配置；配置完成后由硬件状态机自动完成数据搬运与计算。该点与 CNN spec 的 “software-defined configuration, hardware-driven execution” 一致。

4. **统一定点计算链路**
   建立从 DSP 前端到 CNN 后端的一致数据格式和量化约定，避免模块间数据类型歧义。现有文档已分别指出 CIC 输出全精度、FIR 负责量化压缩、CNN 使用 8-bit 激活与 32-bit 累加。

### 2.2 v1 实现范围

本系统 **v1** 只覆盖以下功能：

* 输入采样流接收
* CIC 抽取降频
* FIR 通带补偿与量化
* 1D-CNN 推理
* 分类结果输出
* AXI-Lite 控制与状态采集
* 中断与错误上报

**不在 v1 范围内：**

* Transformer / MHSA / LW-CT 硬件执行单元
* 动态模型下载与指令流执行
* 多 batch 并发调度
* DDR 外部 feature map spilling
* 多输入通道复杂路由（如 MIMO 阵列）

> 说明：论文参考文档确实包含 1D-CNN-Transformer 与指令式 accelerator 架构，但当前你已有的 `core_cnn_spec` 实际落地内容主要是 1D-CNN 侧的 CBUF、PE Cluster、WS 数据流与 pooling/activation，因此系统主 spec 应与现阶段交付范围对齐。

---

## 3. 顶层系统架构

### 3.1 顶层模块划分

系统由以下五个子系统组成：

1. **AXI 接口与控制子系统**

   * AXI-Lite Slave：配置寄存器与状态寄存器
   * 中断输出
   * 可选 AXI-Stream 结果口

2. **前端数据接入子系统**

   * 采样流输入适配
   * 输入帧边界识别
   * 输入节拍统计

3. **DSP 预处理子系统**

   * CIC Decimation Filter
   * FIR Compensation Filter

4. **CNN 推理子系统**

   * Input staging buffer
   * Ping-Pong CBUF
   * Weight Buffer
   * PE Cluster / MAC Array
   * Psum accumulation / activation / pooling

5. **系统控制与监控子系统**

   * Global FSM
   * 子模块控制器
   * 性能计数器
   * 错误收集器

### 3.2 顶层数据流

系统数据流固定为：

`Input Stream -> CIC -> FIR -> CNN Input Buffer -> CBUF/PE Array -> Post-Process -> Result Output`

其中：

* **CIC** 负责大倍率抽取与初步抗混叠，采用无乘法器 Hogenauer 结构。
* **FIR** 负责通带补偿、低通整形、位宽压缩与输出量化。
* **CNN Core** 负责卷积、激活、池化及可选全连接。其采用 Ping-Pong CBUF 与 Weight Stationary 数据流。

### 3.3 系统控制流

配置与运行生命周期定义为：

1. `RESET`
2. `IDLE`
3. `CONFIG`
4. `ARMED`
5. `STREAMING_DSP`
6. `CNN_COMPUTE`
7. `RESULT_DRAIN`
8. `DONE`
9. `ERROR`

说明：

* `IDLE -> CONFIG`：CPU 通过 AXI-Lite 写入参数
* `CONFIG -> ARMED`：所有必要参数检查通过
* `ARMED -> STREAMING_DSP`：收到启动命令
* `STREAMING_DSP`：CIC/FIR 接收并处理输入流
* `CNN_COMPUTE`：当一帧 FIR 输出满足 CNN 输入要求时，启动后端推理
* `RESULT_DRAIN`：输出结果并置位完成状态
* 任意阶段发生不可恢复错误时进入 `ERROR`

---

## 4. 模块边界与职责

### 4.1 CIC 子模块职责

CIC 子模块负责：

* 高速输入流的连续接收
* 配置倍率抽取
* 固定位宽增长管理
* 周期性有效输出生成

CIC 子模块必须满足以下系统级约束：

* 输入侧为**连续流，不接受 backpressure**
* `s_axis_tready` 恒为 1
* 内部使用统一补码扩展
* 积分器链与梳状器链全程允许自然溢出，不得添加饱和钳位
* 输出数据为**全精度中间结果**，不得在 CIC 内部做最终量化。以上均与现有 CIC spec 一致。

### 4.2 FIR 子模块职责

FIR 子模块负责：

* 补偿 CIC 通带下垂
* 提供附加低通滤波与抗混叠
* 实现帧边界零填充冲刷
* 输出对齐后的低位宽 CNN 输入格式

FIR 子模块必须满足以下系统级约束：

* 接收 CIC 的降频输出流
* 支持按帧装载或重载系数
* 支持帧头 flush 和帧尾 flush
* 对输出进行 round + saturate
* 输出数据宽度必须匹配 CNN 输入接口要求。

### 4.3 CNN 子模块职责

CNN 子模块负责：

* 从 FIR 输出接收量化后的一维特征序列
* 管理输入 staging 与跨层 Ping-Pong CBUF
* 执行 Conv1D / DW-Conv / Pool / ReLU / FC（如启用）
* 输出分类结果或特征向量

CNN 子模块必须满足以下系统级约束：

* 采用 Weight Stationary 数据流
* 支持物理 PE 数不足时的时分折叠
* 支持跨层 CBUF 读写角色翻转
* 支持 post-processing 单元对卷积结果做激活和池化。

---

## 5. 系统接口定义

## 5.1 时钟与复位

系统至少定义以下时钟/复位：

* `clk_sys`：控制与主数据通路时钟
* `clk_in`：可选输入高速采样时钟
* `rst_n`：全局异步复位、同步释放

### 5.1.1 复位策略

* 所有控制状态机、计数器、寄存器映射逻辑必须受 `rst_n` 控制
* 数据路径中是否全清零由各子模块定义，但系统级要求如下：

  * CIC：复位清空 integrator / comb 状态
  * FIR：复位只保证控制状态复位，数据路径可依赖后续 flush 洗净
  * CNN：复位清空 CBUF valid 状态、Psum 状态、层级状态机

> FIR 当前 spec 中明确提出“reset 不进入数据路径，依靠 flush 洗净脏数据”的哲学；这个可保留，但系统级必须规定 soft reset 对控制器的作用范围。

## 5.2 输入数据接口

### 5.2.1 输入流接口

```systemverilog
input  logic               s_axis_in_tvalid;
output logic               s_axis_in_tready;
input  logic [IN_W-1:0]    s_axis_in_tdata;
input  logic               s_axis_in_tlast;
input  logic [USER_W-1:0]  s_axis_in_tuser;
```

系统级语义定义：

* `s_axis_in_tdata`：原始输入采样
* `s_axis_in_tvalid`：输入有效
* `s_axis_in_tlast`：帧尾
* `s_axis_in_tuser[0]`：帧头
* `s_axis_in_tready`：

  * 对外暴露为 ready
  * 但在 v1 约束中，系统整体假设输入侧**不可长期回压**
  * 若前端采样源不可暂停，则必须由输入适配 FIFO 吸收瞬态抖动

### 5.2.2 输入帧约束

* 一帧输入必须对应一次完整的 DSP + CNN 推理流程
* 帧长度 `FRAME_LEN_IN` 必须在配置范围内
* 若系统配置为固定长度模式，则输入帧长不匹配应触发错误

## 5.3 AXI-Lite 控制接口

系统必须提供标准 AXI-Lite Slave 接口用于：

* 模式配置
* 启停控制
* 状态读取
* 错误读取
* 性能计数器读取

## 5.4 结果输出接口

```systemverilog
output logic               m_axis_out_tvalid;
input  logic               m_axis_out_tready;
output logic [OUT_W-1:0]   m_axis_out_tdata;
output logic               m_axis_out_tlast;
output logic [USER_W-1:0]  m_axis_out_tuser;
```

系统级语义：

* `m_axis_out_tdata`：分类 ID / logits / 特征向量
* `m_axis_out_tlast`：本次推理结果最后一个 beat
* `m_axis_out_tuser[0]`：结果有效起始
* 结果口允许 backpressure
* 若下游阻塞，系统必须通过结果 FIFO 或寄存保持结果，禁止直接丢失

## 5.5 中断接口

```systemverilog
output logic irq_done;
output logic irq_err;
```

可选扩展：

```systemverilog
output logic irq_buf;
output logic irq_cfg;
```

---

## 6. 数据格式与量化约定

这是旧版 system spec 最缺的一章，我建议固定下来。

### 6.1 统一数据类型约定

| 阶段        | 数据格式                        | 说明        |
| --------- | --------------------------- | --------- |
| 输入采样      | `signed IN_W`               | ADC/前端输入  |
| CIC 内部/输出 | `signed CIC_W`              | 全精度增长，不截断 |
| FIR 系数    | `signed FIR_COEF_W`         | 可配置定点     |
| FIR 输出    | `signed CNN_ACT_W`          | CNN 输入激活  |
| CNN 权重    | `signed WGT_W`              | 离线量化加载    |
| CNN 累加    | `signed ACC_W`              | 卷积累加中间值   |
| CNN 输出    | `signed CNN_ACT_W` 或 分类结果格式 | 依层而定      |

### 6.2 推荐默认值

结合你现有 spec，v1 建议默认：

* `IN_W = 8`
* `CNN_ACT_W = 8`
* `WGT_W = 8`
* `ACC_W = 32`

这与你现有 CNN spec 中 8-bit activation / 8-bit weight / 32-bit accumulator 的约定一致。

### 6.3 量化责任边界

* CIC：不负责最终量化
* FIR：负责从高位宽中间结果转换为 CNN 输入位宽
* CNN：负责层内 accumulation 与层间 requant
* 最终结果输出格式由 classifier 配置决定

---

## 7. Backpressure 与缓冲策略

这是系统级必须明确的一章。

### 7.1 数据岛划分

系统按 backpressure 能力分成两个“数据岛”：

1. **前端连续流岛**

   * Input Adapter
   * CIC
   * FIR 输入侧

2. **后端缓冲突发岛**

   * FIR 输出缓存
   * CNN CBUF
   * Result FIFO

### 7.2 系统规则

* 前端连续流岛默认**不允许依赖下游 ready 才运行**
* 后端缓冲突发岛允许通过 FIFO / buffer 吸收速率不匹配
* FIR 输出到 CNN 输入之间必须存在足够深度的 buffer 或者 frame-level staging
* 若后端无法在约束时间内消费 FIR 输出，系统应上报 `BUF_OVERFLOW_ERR`

### 7.3 集成要求

* 纯 AXIS 语义不能直接套到 CIC 输出侧，必须以“AXIS-like valid source”理解，或在 wrapper 中转成真正可回压接口
* 系统集成时必须验证最坏情况下前端连续流不会因 CNN 阻塞而丢数

> 这条是从 CIC spec 的“m_axis_tready 不响应”与 FIR/CNN 后端缓冲需求统一出来的。

---

## 8. 配置寄存器模型

这里只先定义系统级寄存器框架，具体 bitfield 你后面可以单开 `csr_interrupt_spec`。

## 8.1 必需寄存器组

### 8.1.1 系统控制组

* `SYS_CTRL`
* `SYS_STATUS`
* `SYS_ERR_CODE`
* `IRQ_MASK`
* `IRQ_STATUS`

### 8.1.2 输入与帧配置组

* `FRAME_LEN_CFG`
* `INPUT_MODE_CFG`

### 8.1.3 CIC 配置组

* `CIC_CFG0`：R, N, M
* `CIC_CFG1`：phase, enable

### 8.1.4 FIR 配置组

* `FIR_CFG0`：tap number, shift
* `FIR_CFG1`：coeff load mode
* `FIR_STATUS`

### 8.1.5 CNN 配置组

* `CNN_GLOBAL_CFG`
* `CNN_LAYERn_CFG0/1/2/...`
* `CNN_START_ADDR`
* `CNN_RESULT_CFG`

### 8.1.6 性能计数组

* `CYCLE_CNT`
* `FRAME_CNT`
* `STALL_CNT`
* `CNN_BUSY_CNT`

## 8.2 系统控制语义

`SYS_CTRL` 至少包括：

* `bit[0] START`
* `bit[1] STOP`
* `bit[2] SOFT_RST`
* `bit[3] CLR_DONE`
* `bit[4] CLR_ERR`

`SYS_STATUS` 至少包括：

* `bit[0] IDLE`
* `bit[1] BUSY`
* `bit[2] DONE`
* `bit[3] ERR`
* `bit[4] FIR_ACTIVE`
* `bit[5] CNN_ACTIVE`

---

## 9. 错误处理与异常行为

旧版 system spec 最大缺项之一就是这里。下面必须固定。

### 9.1 错误分类

#### A. 配置错误

* 非法 CIC 参数
* 非法 FIR tap/shift 参数
* 非法 CNN 层参数
* 帧长与网络输入长度不匹配

#### B. 运行时错误

* 输入帧格式错误
* FIR 系数加载不完整
* CNN buffer overflow / underflow
* 结果 FIFO overflow
* 状态机超时

#### C. 接口错误

* Busy 状态下重复 start
* 运行中修改只允许静态配置的寄存器
* 非法停止时序

### 9.2 错误行为定义

* 可恢复错误：置位错误寄存器，允许软件清除后重新开始
* 不可恢复错误：进入 `ERROR` 状态，需要 `SOFT_RST`
* `irq_err` 在错误首次出现时拉高
* `SYS_ERR_CODE` 记录首个错误码，`SYS_ERR_INFO` 可选记录附加信息

### 9.3 非法配置处理原则

对于以下配置，硬件必须拒绝启动：

* `FRAME_LEN_IN == 0`
* `CIC_R < 2`
* `FIR_TAP_NUM == 0`
* `KERNEL_SIZE > GP_PE_MAC_NUM`
* CNN 所需 buffer 容量超出硬件上限

---

## 10. 时序与状态机约束

## 10.1 启动约束

系统启动必须满足：

* 所有必需配置寄存器写入完成
* FIR 系数区准备就绪
* CNN 层配置完整
* 错误标志清零
* 当前状态为 `IDLE` 或 `ARMED`

## 10.2 运行约束

* `START` 只在 idle/armed 态被采样
* busy 期间写保护寄存器不得修改
* `STOP` 触发后系统进入受控 drain/flush，而非直接切断数据流
* `SOFT_RST` 可异步请求，但实际模块复位应在时钟边界同步执行

## 10.3 完成条件

当满足以下条件时置位 `DONE`：

* 当前帧输入已全部接收
* FIR flush 完成
* CNN 全层计算完成
* 结果已写入结果寄存器或结果 FIFO

---

## 11. 性能与容量约束

## 11.1 性能指标类型

系统必须至少报告和约束以下性能指标：

* 输入采样吞吐
* 抽取后输出速率
* 每帧 FIR 延迟
* 每帧 CNN 推理周期数
* 系统总帧延迟
* 结果输出延迟

## 11.2 Buffer 容量要求

系统必须在规格阶段给出以下上限：

* FIR 输出 staging buffer 深度
* CBUF 单 bank 深度
* 最大支持输入序列长度
* 最大支持中间 feature map 大小
* 最大支持层数

## 11.3 吞吐约束说明

* DSP 前端吞吐由输入时钟、CIC 抽取率、FIR 周期能力决定
* CNN 吞吐由 PE 并行度、kernel size、folding 次数、pooling 及层数共同决定
* 系统吞吐以下游 CNN 能否及时消费 FIR 输出为最终瓶颈

---

## 12. 可测性与调试支持

系统必须提供如下 debug 能力：

### 12.1 状态可观测性

* 当前系统状态
* 当前 active frame ID
* 当前模块 busy 标志
* 当前 CNN 层号
* 当前 fold index

### 12.2 计数器

* 输入样本计数
* 输出样本计数
* FIR flush 周期计数
* CNN compute 周期计数
* stall 计数
* error 计数

### 12.3 可选调试口

* 原始 FIR 输出观测口
* CNN 第一层输出观测口
* 最终分类结果寄存器镜像

---

## 13. 验证准则

系统级验证至少覆盖以下场景：

### 13.1 正常路径

* 单帧正常输入 → 正常分类输出
* 多帧连续输入
* 不同 CIC/FIR/CNN 配置组合

### 13.2 边界路径

* 最小帧长
* 最大帧长
* 最小/最大抽取率
* 最小/最大 tap 数
* CNN 通道数与 folding 边界

### 13.3 异常路径

* 非法配置启动
* Busy 期间重配
* FIR 系数未装满
* 输出 FIFO 满
* soft reset 插入运行中
* 输入帧长不匹配

### 13.4 数值正确性

* CIC：补码自然溢出正确性
* FIR：round + saturate 正确性
* CNN：卷积、激活、池化与 golden model 对齐

---

## 14. 与子规格书的约束关系

本 system spec 作为上位文档，对子 spec 的约束如下：

### 14.1 对 CIC spec

* 必须遵守无反压连续流语义
* 必须输出全精度数据
* 必须支持系统级 reset / start / stop 协议

### 14.2 对 FIR spec

* 必须支持 frame-based flush 机制
* 必须输出 CNN 兼容位宽
* 必须将 frame 边界与 valid 对齐

### 14.3 对 CNN spec

* 必须支持 system-level start/done/error 协议
* 必须暴露 busy/done/error 状态
* 必须支持 buffer 容量检查与非法配置拒绝

---

## 15. v1 未决项（Open Issues）

当前版本仍保留以下待定项，后续需在子 spec 中关闭：

1. 输入时钟域与系统时钟域是否分离
2. FIR 系数装载采用 sideband stream 还是 CSR RAM
3. CNN 层配置一次性预载还是逐层寄存器写入
4. 结果输出采用 AXIS 还是 memory-mapped result register
5. 是否支持 residual add / depthwise + pointwise 全覆盖
6. 是否预留 v2 Transformer 扩展接口

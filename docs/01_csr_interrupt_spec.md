# `01_csr_interrupt_spec.md`

# DSP-CNN 协处理器

# CSR 与中断规格书

**Document ID:** `CSR_INTERRUPT_SPEC`
**Version:** `v1.0`
**Applies To:** `DSP_CNN_SYSTEM_SPEC v2.x`

---

## 1. 文档目的

本文档定义 DSP-CNN 协处理器的 **控制/状态寄存器（CSR）映射、中断机制、错误码模型、寄存器访问约束以及软件驱动可见行为**，作为软件驱动、RTL 寄存器实现、验证环境和系统联调的统一依据。

本文档覆盖以下内容：

* 系统级控制寄存器
* 状态与错误寄存器
* 中断屏蔽与中断状态寄存器
* 输入帧配置寄存器
* CIC/FIR/CNN 配置寄存器
* 性能计数器寄存器
* 软件访问时序约束
* 中断触发与清除语义

本文档 **不覆盖**：

* 各 CNN layer 内部微架构细节
* FIR 系数存储体内部实现细节
* 性能模型公式推导
* future version 扩展字段的具体功能定义

---

## 2. 设计原则

本 CSR 体系遵循以下原则：

### 2.1 软件定义，硬件执行

软件通过 AXI-Lite 写寄存器完成一次任务的配置；硬件在 `START` 后自动完成整帧处理。该原则与 system spec 的生命周期定义一致。

### 2.2 配置与运行隔离

处于 `BUSY` 状态时，绝大多数配置寄存器禁止修改。该限制是为了避免破坏 CIC 连续流处理、FIR flush 和 CNN 层级状态机的一致性。

### 2.3 错误优先于完成

若一次任务运行过程中出现不可恢复错误，则 `ERR` 优先于 `DONE`，且系统进入错误状态，等待软件清除或软复位。

### 2.4 Sticky 状态显式清除

`DONE`、`ERR`、`IRQ_STATUS`、部分错误码寄存器采用 sticky 语义，必须由软件显式清除，防止事件丢失。

### 2.5 只冻结 v1 必需字段

本版本仅定义 v1 必需寄存器与 bitfield；未定义位默认保留，读为 0，写忽略。

---

## 3. 总线与访问约定

## 3.1 总线接口

CSR 通过 **AXI-Lite Slave** 暴露给 CPU/MCU 访问。system spec 已将 AXI-Lite 作为统一配置入口。

* 地址宽度：实现相关，推荐至少 12 bit
* 数据宽度：32 bit
* 对齐要求：32-bit word aligned
* 字节序：little-endian

## 3.2 访问类型定义

本文档使用以下访问属性：

* `RO`：Read Only
* `RW`：Read / Write
* `WO`：Write Only
* `W1C`：Write 1 to Clear
* `WARL`：Write Any, Read Legal
* `SC`：Self Clear，自清位

## 3.3 保留位约定

* 未定义位均为 `RESERVED`
* 软件写 `RESERVED` 位必须写 0
* 硬件读取 `RESERVED` 位返回 0
* 后续版本可复用保留位，不保证软件兼容乱写行为

---

## 4. 寄存器空间总览

建议采用以下地址布局：

| Base Offset |                    寄存器组 | 说明            |
| ----------- | ----------------------: | ------------- |
| `0x000`     | System Control / Status | 系统控制、状态、错误、中断 |
| `0x040`     |    Frame / Input Config | 帧长、输入模式       |
| `0x080`     |              CIC Config | CIC 参数配置与状态   |
| `0x0C0`     |              FIR Config | FIR 参数配置与状态   |
| `0x100`     |       CNN Global Config | CNN 全局配置      |
| `0x140`     |        CNN Layer Config | CNN 层配置窗口     |
| `0x200`     |          Result / Debug | 结果寄存器、调试观测    |
| `0x240`     |    Performance Counters | 性能计数器         |
| `0x300`     |        FIR Coeff Window | FIR 系数装载窗口    |
| `0x400+`    |                Reserved | 保留            |

---

## 5. 系统控制与状态寄存器

## 5.1 `SYS_CTRL`

**Offset:** `0x000`
**Access:** `RW`

| Bit  | Name       | Access | Reset | Description             |
| ---- | ---------- | ------ | ----: | ----------------------- |
| 0    | `START`    | `SC`   |     0 | 启动一次任务                  |
| 1    | `STOP`     | `SC`   |     0 | 请求受控停止                  |
| 2    | `SOFT_RST` | `SC`   |     0 | 软件复位请求                  |
| 3    | `CLR_DONE` | `W1C`  |     0 | 清除 `DONE` sticky 状态     |
| 4    | `CLR_ERR`  | `W1C`  |     0 | 清除 `ERR` sticky 状态与可清错误 |
| 5    | `IRQ_ACK`  | `SC`   |     0 | 对中断控制器进行统一应答            |
| 31:6 | `RESERVED` | -      |     0 | 保留                      |

### 5.1.1 `START` 语义

* 仅当系统处于 `IDLE` 或 `ARMED` 时有效
* 写 1 后硬件采样并自动清零
* 若在 `BUSY` 状态写 `START`，触发 `ERR_BUSY_START`

### 5.1.2 `STOP` 语义

* `STOP` 表示请求系统执行**受控 drain / flush**
* 不允许把正在处理的数据路径硬切断
* 该定义与 system spec 中 “STOP 进入受控 drain/flush，而非直接切断数据流” 一致。

### 5.1.3 `SOFT_RST` 语义

* 对控制状态机、buffer valid 状态、错误 sticky 位生效
* 不要求所有数据路径寄存器逐位清零
* FIR 可继续采用“控制复位 + flush 洗净数据路径”的实现哲学。

---

## 5.2 `SYS_STATUS`

**Offset:** `0x004`
**Access:** `RO`

| Bit   | Name           | Reset | Description      |
| ----- | -------------- | ----: | ---------------- |
| 0     | `IDLE`         |     1 | 系统空闲             |
| 1     | `BUSY`         |     0 | 系统忙              |
| 2     | `DONE`         |     0 | 一次任务完成，sticky    |
| 3     | `ERR`          |     0 | 存在未清除错误，sticky   |
| 4     | `CFG_DONE`     |     0 | 必需配置已写入完成        |
| 5     | `INPUT_ACTIVE` |     0 | 输入流接收中           |
| 6     | `CIC_ACTIVE`   |     0 | CIC 工作中          |
| 7     | `FIR_ACTIVE`   |     0 | FIR 工作中          |
| 8     | `CNN_ACTIVE`   |     0 | CNN 工作中          |
| 9     | `RESULT_VALID` |     0 | 结果寄存器/结果 FIFO 有效 |
| 10    | `IRQ_PENDING`  |     0 | 有未屏蔽中断待处理        |
| 31:11 | `RESERVED`     |     0 | 保留               |

说明：

* `DONE` 与 `ERR` 为 sticky 位
* `DONE` 由 `SYS_CTRL.CLR_DONE=1` 清除
* `ERR` 由 `SYS_CTRL.CLR_ERR=1` 或 `SOFT_RST` 清除

---

## 5.3 `SYS_ERR_CODE`

**Offset:** `0x008`
**Access:** `RO`

| Bit   | Name          | Description                     |
| ----- | ------------- | ------------------------------- |
| 15:0  | `ERR_CODE`    | 首个错误码                           |
| 31:16 | `ERR_SUBINFO` | 附加子信息，如 layer index / module id |

说明：

* 记录本次任务中**第一个**被捕获的错误
* 后续错误可累计到 `ERR_SUMMARY`，但不覆盖 `ERR_CODE`
* 该机制便于软件快速定位第一故障点

---

## 5.4 `ERR_SUMMARY`

**Offset:** `0x00C`
**Access:** `RO`

| Bit  | Name          | Description |
| ---- | ------------- | ----------- |
| 0    | `ERR_CFG`     | 配置错误汇总      |
| 1    | `ERR_RUNTIME` | 运行时错误汇总     |
| 2    | `ERR_IF`      | 接口协议错误汇总    |
| 3    | `ERR_TIMEOUT` | 超时错误汇总      |
| 4    | `ERR_BUF`     | 缓冲区错误汇总     |
| 5    | `ERR_NUMERIC` | 数值/量化类错误汇总  |
| 31:6 | `RESERVED`    | 保留          |

---

## 6. 中断控制寄存器

## 6.1 中断源定义

v1 固定定义以下中断源：

| IRQ Bit | 名称               | 类型           | 说明          |
| ------- | ---------------- | ------------ | ----------- |
| 0       | `IRQ_DONE`       | level sticky | 一次任务完成      |
| 1       | `IRQ_ERR`        | level sticky | 发生错误        |
| 2       | `IRQ_RESULT_RDY` | level sticky | 结果有效可读      |
| 3       | `IRQ_BUF_WARN`   | level sticky | buffer 接近阈值 |
| 4       | `IRQ_CFG_REJECT` | level sticky | 启动前配置被拒绝    |
| 5       | `IRQ_TIMEOUT`    | level sticky | 模块运行超时      |
| 31:6    | `RESERVED`       | -            | 保留          |

### 6.1.1 设计建议

实际对外物理 pin 可以只导出：

* `irq_done`
* `irq_err`

其余中断源通过 `IRQ_STATUS` 细分。
这与前面 system spec 中 “物理中断线可少、内部状态细分寄存器多” 的设计是一致的。

---

## 6.2 `IRQ_MASK`

**Offset:** `0x010`
**Access:** `RW`

| Bit  | Name              | Reset | Description           |
| ---- | ----------------- | ----: | --------------------- |
| 0    | `DONE_MASK`       |     0 | 1=屏蔽 `IRQ_DONE`       |
| 1    | `ERR_MASK`        |     0 | 1=屏蔽 `IRQ_ERR`        |
| 2    | `RESULT_RDY_MASK` |     0 | 1=屏蔽 `IRQ_RESULT_RDY` |
| 3    | `BUF_WARN_MASK`   |     1 | 1=屏蔽 `IRQ_BUF_WARN`   |
| 4    | `CFG_REJECT_MASK` |     0 | 1=屏蔽 `IRQ_CFG_REJECT` |
| 5    | `TIMEOUT_MASK`    |     0 | 1=屏蔽 `IRQ_TIMEOUT`    |
| 31:6 | `RESERVED`        |     0 | 保留                    |

---

## 6.3 `IRQ_STATUS`

**Offset:** `0x014`
**Access:** `W1C`

| Bit  | Name              | Reset | Description    |
| ---- | ----------------- | ----: | -------------- |
| 0    | `DONE_PEND`       |     0 | 完成中断待处理        |
| 1    | `ERR_PEND`        |     0 | 错误中断待处理        |
| 2    | `RESULT_RDY_PEND` |     0 | 结果就绪中断待处理      |
| 3    | `BUF_WARN_PEND`   |     0 | buffer 警告中断待处理 |
| 4    | `CFG_REJECT_PEND` |     0 | 配置拒绝中断待处理      |
| 5    | `TIMEOUT_PEND`    |     0 | 超时中断待处理        |
| 31:6 | `RESERVED`        |     0 | 保留             |

说明：

* `IRQ_STATUS` 为 sticky pending 位
* 对应位写 1 清除
* 若事件源仍然保持有效，清除后可再次置位

---

## 6.4 `IRQ_RAW_STATUS`

**Offset:** `0x018`
**Access:** `RO`

返回未经过 mask 的原始事件状态，便于调试。

---

## 7. 输入与帧配置寄存器

## 7.1 `FRAME_LEN_CFG`

**Offset:** `0x040`
**Access:** `RW`

| Bit   | Name                | Reset | Description     |
| ----- | ------------------- | ----: | --------------- |
| 15:0  | `FRAME_LEN_IN`      |     0 | 输入帧长度（sample 数） |
| 31:16 | `FRAME_LEN_OUT_EXP` |     0 | 预期输出长度/保留字段     |

说明：

* `FRAME_LEN_IN` 为 v1 必填配置
* 若固定长度输入流与配置不匹配，应触发 `ERR_FRAME_LEN_MISMATCH`

## 7.2 `INPUT_MODE_CFG`

**Offset:** `0x044`
**Access:** `RW`

| Bit  | Name                 | Reset | Description          |
| ---- | -------------------- | ----: | -------------------- |
| 0    | `FRAME_MODE_EN`      |     1 | 1=按帧处理               |
| 1    | `USE_TLAST`          |     1 | 1=使用 `tlast` 判定帧尾    |
| 2    | `USE_TUSER_SOF`      |     1 | 1=使用 `tuser[0]` 判定帧头 |
| 3    | `FIXED_FRAME_LEN_EN` |     1 | 1=强制帧长匹配             |
| 31:4 | `RESERVED`           |     0 | 保留                   |

---

## 8. CIC 配置寄存器

CIC spec 已明确 `R / N / M / PHASE` 是关键参数，且内部位宽增长由公式约束。

## 8.1 `CIC_CFG0`

**Offset:** `0x080`
**Access:** `RW`

| Bit   | Name       | Reset | Description |
| ----- | ---------- | ----: | ----------- |
| 11:0  | `DECIM_R`  |    64 | 抽取率 R       |
| 15:12 | `ORDER_N`  |     5 | 阶数 N        |
| 19:16 | `DIFF_M`   |     1 | 差分延迟 M      |
| 31:20 | `RESERVED` |     0 | 保留          |

## 8.2 `CIC_CFG1`

**Offset:** `0x084`
**Access:** `RW`

| Bit   | Name       | Reset | Description |
| ----- | ---------- | ----: | ----------- |
| 11:0  | `PHASE`    |     0 | 相位配置        |
| 12    | `CIC_EN`   |     1 | 使能 CIC      |
| 31:13 | `RESERVED` |     0 | 保留          |

## 8.3 `CIC_STATUS`

**Offset:** `0x088`
**Access:** `RO`

| Bit  | Name               | Description |
| ---- | ------------------ | ----------- |
| 0    | `CIC_BUSY`         | CIC 工作中     |
| 1    | `CIC_FRAME_ACTIVE` | 正在处理当前帧     |
| 2    | `CIC_CFG_ERR`      | CIC 配置非法    |
| 3    | `CIC_PHASE_ERR`    | phase 非法    |
| 31:4 | `RESERVED`         | 保留          |

### 8.3.1 写保护规则

当 `SYS_STATUS.BUSY=1` 时，写 `CIC_CFG0/1` 必须被拒绝，并触发 `ERR_CFG_WRITE_WHILE_BUSY`。
这是因为 CIC 具有历史状态和连续流属性，运行时重配会破坏正确性。

---

## 9. FIR 配置寄存器

FIR spec 已定义 tap 数、shift、frame start / tail flush、系数动态装载等需求。

## 9.1 `FIR_CFG0`

**Offset:** `0x0C0`
**Access:** `RW`

| Bit   | Name       | Reset | Description |
| ----- | ---------- | ----: | ----------- |
| 15:0  | `TAP_NUM`  |    64 | FIR tap 数   |
| 23:16 | `SHIFT`    |    18 | 输出算术右移位数    |
| 24    | `FIR_EN`   |     1 | 使能 FIR      |
| 31:25 | `RESERVED` |     0 | 保留          |

## 9.2 `FIR_CFG1`

**Offset:** `0x0C4`
**Access:** `RW`

| Bit  | Name                 | Reset | Description   |
| ---- | -------------------- | ----: | ------------- |
| 0    | `COEF_RELOAD_EN`     |     1 | 每帧重载系数        |
| 1    | `AUTO_HEAD_FLUSH_EN` |     1 | 帧头自动 flush    |
| 2    | `AUTO_TAIL_FLUSH_EN` |     1 | 帧尾自动 flush    |
| 3    | `ROUND_EN`           |     1 | 启用 rounding   |
| 4    | `SAT_EN`             |     1 | 启用 saturation |
| 31:5 | `RESERVED`           |     0 | 保留            |

## 9.3 `FIR_STATUS`

**Offset:** `0x0C8`
**Access:** `RO`

| Bit  | Name                | Description |
| ---- | ------------------- | ----------- |
| 0    | `FIR_BUSY`          | FIR 工作中     |
| 1    | `COEF_READY`        | 系数已装载完成     |
| 2    | `HEAD_FLUSH_ACTIVE` | 帧头冲刷中       |
| 3    | `TAIL_FLUSH_ACTIVE` | 帧尾冲刷中       |
| 4    | `FIR_CFG_ERR`       | 参数非法        |
| 5    | `COEF_LOAD_ERR`     | 系数装载异常      |
| 31:6 | `RESERVED`          | 保留          |

---

## 10. FIR 系数窗口寄存器

## 10.1 `FIR_COEF_PORT`

**Offset:** `0x300`
**Access:** `WO`

说明：

* 软件通过重复写 `FIR_COEF_PORT` 装载 FIR 系数
* 写入顺序固定为 `h[0] -> h[1] -> ... -> h[TAP_NUM-1]`
* 若 `COEF_RELOAD_EN=1`，则每帧启动前必须重新装载
* 若装载计数与 `TAP_NUM` 不一致，触发 `ERR_FIR_COEF_INCOMPLETE`

## 10.2 `FIR_COEF_CTRL`

**Offset:** `0x304`
**Access:** `RW`

| Bit  | Name              | Reset | Description |
| ---- | ----------------- | ----: | ----------- |
| 0    | `COEF_LOAD_START` |     0 | 启动系数装载，SC   |
| 1    | `COEF_LOAD_DONE`  |     0 | 软件声明装载完成，SC |
| 2    | `COEF_CLR`        |     0 | 清空系数缓存，SC   |
| 31:3 | `RESERVED`        |     0 | 保留          |

## 10.3 `FIR_COEF_COUNT`

**Offset:** `0x308`
**Access:** `RO`

返回当前已装载系数数量。

> 说明：你原 FIR spec 里是 sideband `s_axis_tcoef` 风格。为了让 v1 驱动更简单，我这里在 CSR spec 里先冻结成 **memory-mapped coeff port**。这不改变 FIR 算法与状态机本质，只是把“如何喂系数”统一成可实现的软件协议。原 spec 的动态装载思想仍然保留。

---

## 11. CNN 全局配置寄存器

CNN spec 已定义核心全局参数包括 layer type、channel、kernel、stride、pool 和 quant scale 等。

## 11.1 `CNN_GLOBAL_CFG`

**Offset:** `0x100`
**Access:** `RW`

| Bit   | Name          | Reset | Description |
| ----- | ------------- | ----: | ----------- |
| 7:0   | `LAYER_NUM`   |     0 | 网络层数        |
| 15:8  | `INPUT_ACT_W` |     8 | 输入激活位宽      |
| 23:16 | `WEIGHT_W`    |     8 | 权重位宽        |
| 31:24 | `ACC_W`       |    32 | 累加位宽编码      |

## 11.2 `CNN_CTRL`

**Offset:** `0x104`
**Access:** `RW`

| Bit  | Name                | Reset | Description      |
| ---- | ------------------- | ----: | ---------------- |
| 0    | `CNN_EN`            |     1 | CNN 模块使能         |
| 1    | `RESULT_CLASS_MODE` |     1 | 1=输出分类 ID；0=输出向量 |
| 2    | `PER_LAYER_IRQ_EN`  |     0 | 每层完成中断使能         |
| 31:3 | `RESERVED`          |     0 | 保留               |

## 11.3 `CNN_STATUS`

**Offset:** `0x108`
**Access:** `RO`

| Bit   | Name               | Description   |
| ----- | ------------------ | ------------- |
| 0     | `CNN_BUSY`         | CNN 正在工作      |
| 1     | `CNN_CFG_ERR`      | CNN 配置错误      |
| 2     | `CBUF_OVERFLOW`    | CBUF 溢出       |
| 3     | `CBUF_UNDERFLOW`   | CBUF 下溢       |
| 4     | `RESULT_READY`     | CNN 结果可读      |
| 7:5   | `RESERVED`         | 保留            |
| 15:8  | `ACTIVE_LAYER_IDX` | 当前层号          |
| 23:16 | `ACTIVE_FOLD_IDX`  | 当前 fold index |
| 31:24 | `RESERVED`         | 保留            |

---

## 12. CNN Layer 配置窗口

考虑 v1 先做简单稳定实现，建议采用 **单层 4-word 配置窗口**，每层占 16 Bytes。

## 12.1 层配置基地址

* `LAYER0_CFG_BASE = 0x140`
* `LAYER_STRIDE = 0x10`

第 `n` 层配置地址：

* `0x140 + n * 0x10 + 0x0` -> `LAYERn_CFG0`
* `0x140 + n * 0x10 + 0x4` -> `LAYERn_CFG1`
* `0x140 + n * 0x10 + 0x8` -> `LAYERn_CFG2`
* `0x140 + n * 0x10 + 0xC` -> `LAYERn_CFG3`

---

## 12.2 `LAYERn_CFG0`

| Bit   | Name          | Description                        |
| ----- | ------------- | ---------------------------------- |
| 2:0   | `LAYER_TYPE`  | 0=Conv1D, 1=DWConv1D, 2=Pool, 3=FC |
| 7:3   | `KERNEL_SIZE` | 卷积核大小                              |
| 12:8  | `STRIDE`      | 步长                                 |
| 17:13 | `PADDING`     | padding                            |
| 23:18 | `POOL_SIZE`   | pool size                          |
| 26:24 | `POOL_TYPE`   | 0=None, 1=Max, 2=Avg               |
| 31:27 | `RESERVED`    | 保留                                 |

## 12.3 `LAYERn_CFG1`

| Bit   | Name      | Description |
| ----- | --------- | ----------- |
| 11:0  | `IN_CH`   | 输入通道数       |
| 23:12 | `OUT_CH`  | 输出通道数       |
| 31:24 | `SEQ_LEN` | 输入长度或编码值    |

## 12.4 `LAYERn_CFG2`

| Bit   | Name          | Description                |
| ----- | ------------- | -------------------------- |
| 7:0   | `ACT_TYPE`    | 0=None, 1=ReLU             |
| 15:8  | `QUANT_SHIFT` | requant shift              |
| 23:16 | `QUANT_SCALE` | requant scale/mult 编码      |
| 31:24 | `FLAGS`       | 保留给 residual/bias 等 v1 子功能 |

## 12.5 `LAYERn_CFG3`

| Bit   | Name        | Description |
| ----- | ----------- | ----------- |
| 15:0  | `WBUF_ADDR` | 权重地址索引      |
| 31:16 | `BIAS_ADDR` | bias 地址索引   |

### 12.5.1 v1 合法性检查

以下情况必须在 `START` 前被检查，不合法则拒绝启动：

* `IN_CH == 0`
* `OUT_CH == 0`
* `SEQ_LEN == 0`
* `KERNEL_SIZE == 0`
* `KERNEL_SIZE > GP_PE_MAC_NUM` 时若硬件不支持该折叠模式则报错
* `POOL_SIZE == 0` 且 `POOL_TYPE != None`
* 地址越界

这些约束来自你现有 CNN spec 中对 PE 并发度、kernel 大小和层配置的物理限制。

---

## 13. 结果与调试寄存器

## 13.1 `RESULT0`

**Offset:** `0x200`
**Access:** `RO`

* 分类模式下：低位保存 `class_id`
* 向量模式下：保存第一个输出元素

## 13.2 `RESULT1`

**Offset:** `0x204`
**Access:** `RO`

* 分类模式下：可保存 confidence / score
* 向量模式下：保存第二个输出元素

## 13.3 `RESULT_STATUS`

**Offset:** `0x208`
**Access:** `RO`

| Bit   | Name              | Description |
| ----- | ----------------- | ----------- |
| 0     | `RESULT_VALID`    | 结果有效        |
| 1     | `RESULT_OVERRUN`  | 上次结果未读被覆盖   |
| 7:2   | `RESERVED`        | 保留          |
| 15:8  | `RESULT_WORD_NUM` | 结果字数        |
| 31:16 | `RESERVED`        | 保留          |

## 13.4 `DEBUG_STATUS0`

**Offset:** `0x20C`
**Access:** `RO`

建议返回：

* 当前系统状态
* 当前活动模块
* 当前 frame id 低位

---

## 14. 性能计数器寄存器

## 14.1 `CYCLE_CNT`

**Offset:** `0x240`
**Access:** `RO`

总运行周期数。

## 14.2 `FRAME_CNT`

**Offset:** `0x244`
**Access:** `RO`

成功完成帧计数。

## 14.3 `STALL_CNT`

**Offset:** `0x248`
**Access:** `RO`

后端等待、buffer 阻塞等 stall 周期累计。

## 14.4 `CNN_BUSY_CNT`

**Offset:** `0x24C`
**Access:** `RO`

CNN 活跃周期累计。

## 14.5 `PERF_CTRL`

**Offset:** `0x250`
**Access:** `RW`

| Bit  | Name          | Reset | Description |
| ---- | ------------- | ----: | ----------- |
| 0    | `PERF_CLR`    |     0 | 清零性能计数器，SC  |
| 1    | `PERF_FREEZE` |     0 | 冻结计数器       |
| 31:2 | `RESERVED`    |     0 | 保留          |

---

## 15. 错误码定义

建议固定如下错误码：

|     Code | Name                           | Description     |
| -------: | ------------------------------ | --------------- |
| `0x0001` | `ERR_BUSY_START`               | busy 时再次启动      |
| `0x0002` | `ERR_CFG_WRITE_WHILE_BUSY`     | busy 时写受保护配置寄存器 |
| `0x0003` | `ERR_CFG_INCOMPLETE`           | 必需配置不完整         |
| `0x0004` | `ERR_FRAME_LEN_MISMATCH`       | 输入帧长不匹配         |
| `0x0005` | `ERR_CIC_PARAM_ILLEGAL`        | CIC 参数非法        |
| `0x0006` | `ERR_FIR_PARAM_ILLEGAL`        | FIR 参数非法        |
| `0x0007` | `ERR_FIR_COEF_INCOMPLETE`      | FIR 系数未装满       |
| `0x0008` | `ERR_FIR_COEF_LOAD`            | FIR 系数装载错误      |
| `0x0009` | `ERR_CNN_PARAM_ILLEGAL`        | CNN 层参数非法       |
| `0x000A` | `ERR_CBUF_OVERFLOW`            | CNN CBUF 溢出     |
| `0x000B` | `ERR_CBUF_UNDERFLOW`           | CNN CBUF 下溢     |
| `0x000C` | `ERR_RESULT_OVERRUN`           | 结果未读被覆盖         |
| `0x000D` | `ERR_TIMEOUT_CIC`              | CIC 超时          |
| `0x000E` | `ERR_TIMEOUT_FIR`              | FIR 超时          |
| `0x000F` | `ERR_TIMEOUT_CNN`              | CNN 超时          |
| `0x0010` | `ERR_STOP_WHILE_ILLEGAL_STATE` | STOP 时状态非法      |

### 15.1 `ERR_SUBINFO` 编码建议

* `[3:0]` module id
* `[11:4]` layer index
* `[15:12]` reserved

模块 id 建议：

* `1` = SYS
* `2` = CIC
* `3` = FIR
* `4` = CNN
* `5` = RESULT

---

## 16. 软件访问时序要求

## 16.1 标准启动顺序

软件必须按如下顺序操作：

1. 等待 `SYS_STATUS.IDLE=1`
2. 写入 `FRAME_LEN_CFG / INPUT_MODE_CFG`
3. 写入 `CIC_CFG0/1`
4. 写入 `FIR_CFG0/1`
5. 装载 FIR 系数
6. 写入 `CNN_GLOBAL_CFG / LAYERn_CFGx`
7. 配置 `IRQ_MASK`
8. 写 `SYS_CTRL.START=1`
9. 等待 `IRQ_DONE` 或轮询 `SYS_STATUS.DONE`

## 16.2 结果读取顺序

1. 检查 `RESULT_STATUS.RESULT_VALID`
2. 读取 `RESULT0/1/...`
3. 如采用 sticky 结果状态，则清中断/清 done
4. 必要时执行下一帧配置或再次 `START`

## 16.3 错误恢复顺序

1. 读取 `SYS_ERR_CODE`
2. 读取 `ERR_SUMMARY`
3. 清 `IRQ_STATUS`
4. 写 `SYS_CTRL.CLR_ERR=1`
5. 若硬件未恢复到 `IDLE`，执行 `SOFT_RST`

---

## 17. 写保护与合法性规则

## 17.1 Busy 写保护寄存器

当 `SYS_STATUS.BUSY=1` 时，下列寄存器写入必须被拒绝：

* `FRAME_LEN_CFG`
* `INPUT_MODE_CFG`
* `CIC_CFG0/1`
* `FIR_CFG0/1`
* `CNN_GLOBAL_CFG`
* `LAYERn_CFG0..3`

## 17.2 Busy 下允许写入的寄存器

运行期间允许写：

* `IRQ_MASK`
* `SYS_CTRL.STOP`
* `SYS_CTRL.SOFT_RST`
* `PERF_CTRL`
* 中断清除寄存器

## 17.3 拒绝写入行为

对受保护寄存器的非法写：

* 原值保持不变
* 置位 `ERR`
* 记录 `ERR_CFG_WRITE_WHILE_BUSY`
* 触发 `IRQ_ERR`

---

## 18. 中断行为定义

## 18.1 `IRQ_DONE`

触发条件：

* 一次任务满足完成条件
* 结果已写入结果寄存器或结果 FIFO
* `SYS_STATUS.DONE` 置位

清除条件：

* 写 `IRQ_STATUS.DONE_PEND=1`
* 若实现要求 done 同步清除，可再写 `SYS_CTRL.CLR_DONE=1`

## 18.2 `IRQ_ERR`

触发条件：

* 首个错误被捕获
* `SYS_STATUS.ERR=1`

清除条件：

* 写 `IRQ_STATUS.ERR_PEND=1`
* 再写 `SYS_CTRL.CLR_ERR=1`

## 18.3 `IRQ_RESULT_RDY`

触发条件：

* 结果寄存器/结果 FIFO 中出现新结果

## 18.4 `IRQ_TIMEOUT`

触发条件：

* 某模块运行周期超过实现定义阈值

---

## 19. 验证关注点

CSR/DV 至少覆盖：

* reset 后默认值检查
* 所有 `SC/W1C/RO/RW` 访问属性检查
* busy 写保护检查
* start/stop/soft_rst 时序检查
* IRQ mask / raw / status 联动检查
* 首错保持检查
* done 与 error 优先级检查
* FIR 系数窗口计数正确性检查
* layer 配置窗口地址与合法性检查

---

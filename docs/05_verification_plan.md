# `05_verification_plan.md`

# DSP-CNN 协处理器

# 验证计划书

**Document ID:** `VERIFICATION_PLAN`
**Version:** `v1.0`
**Applies To:**

* `DSP_CNN_SYSTEM_SPEC v2.x`
* `CSR_INTERRUPT_SPEC v1.x`
* `FILTER_CIC_SPEC v2.x`
* `FILTER_FIR_SPEC v2.x`
* `CORE_CNN_SPEC v2.x`

---

## 1. 文档目的

本文档定义 DSP-CNN 协处理器 **v1** 的验证目标、验证范围、验证架构、激励策略、参考模型、检查机制、覆盖率目标、阶段性交付物与签核准则，用于指导 block-level 与 system-level 验证工作。

本文档覆盖：

* System-level verification strategy
* CSR / interrupt verification
* CIC block verification
* FIR block verification
* CNN core verification
* Cross-block integration verification
* Functional coverage / code coverage / bug closure
* Regression planning and signoff criteria

本文档不覆盖：

* DFT / scan / MBIST 专项验证
* 功耗仿真与 UPF 验证
* STA / CDC / RDC signoff 细则
* FPGA 板级 bring-up 测试细则
* v2 及以后版本的新功能验证

---

## 2. 验证目标

v1 验证的总目标是：
**证明该协处理器在受支持配置范围内，能够正确完成从输入帧采样流到最终推理结果输出的端到端处理，并在非法配置、异常时序和边界数值场景下表现出与 spec 一致的可预期行为。**

验证目标可拆分为五类：

### 2.1 功能正确性

验证各模块在合法配置下的输出与黄金模型一致，包括：

* CIC 抽取与补码自然溢出正确性
* FIR 卷积、flush、round、saturate 正确性
* CNN Conv / DWConv / Pool / ReLU / requant 正确性
* 结果输出与软件参考模型一致。

### 2.2 协议正确性

验证系统接口、CSR 协议、中断与状态转换符合规范，包括：

* AXI-Lite CSR 访问属性
* start/stop/soft_rst 行为
* busy 写保护
* done / err / irq sticky 语义。

### 2.3 边界与异常正确性

验证配置非法、容量超界、边界帧、reset 插入、结果覆盖等异常路径。

### 2.4 可观测性与可调试性

验证状态寄存器、性能计数器、active layer / fold index 等 debug 信息可靠可读。

### 2.5 集成一致性

验证 block-level 正确行为在 system integration 后仍保持一致，重点关注：

* 前端连续流岛与后端 burst island 的解耦
* FIR -> CNN 输入帧衔接
* buffer / cbuf / result path 的系统级稳定性。

---

## 3. 验证范围

## 3.1 In Scope

### 3.1.1 System

* 顶层控制状态机
* 输入帧生命周期
* DSP -> CNN -> result 主链路
* 系统错误码与中断
* 顶层 reset / start / stop / done / error

### 3.1.2 CSR / Interrupt

* 所有 v1 定义的 CSR
* RO / RW / SC / W1C 属性
* IRQ mask / raw / status / clear
* busy 写保护
* 错误码上报

### 3.1.3 CIC

* 参数合法性
* decimation / phase
* wrap-around overflow
* frame sideband 映射
* no-backpressure contract

### 3.1.4 FIR

* 系数装载
* head flush / tail flush
* signed MAC tree
* round + saturate
* valid/user/last 对齐

### 3.1.5 CNN Core

* Conv1D
* Depthwise Conv1D
* pointwise (`K=1`)
* ReLU
* Max / Avg pool
* Requant
* FC 末层（若启用）
* CBUF flip / fold / weight load / result output

## 3.2 Out of Scope

* Transformer / MHSA / LW-CT
* 多 batch pipeline
* off-chip feature spilling
* 任意 residual graph
* Softmax / GELU / Sigmoid
* 板级外设验证

这些能力在 v1 spec 中本来就不在交付范围内，因此也不进入 v1 signoff。

---

## 4. 验证策略总览

v1 验证采用 **自底向上（bottom-up）+ 自顶向下（top-down）** 的混合策略：

### 4.1 Block-first

先完成以下 block-level 验证环境：

* `cic_tb`
* `fir_tb`
* `cnn_core_tb`
* `csr_irq_tb`

每个 block 环境先完成：

* directed smoke
* constrained-random
* reference model comparison
* assertion checking
* block functional coverage

### 4.2 Integration-next

在 block 稳定后，逐步做集成：

* `cic + fir`
* `fir + cnn`
* `csr + top control`
* full top

### 4.3 System-last

最终在 top-level 环境中验证：

* 完整帧路径
* 多配置回归
* 异常路径回归
* 系统级覆盖率收敛

---

## 5. 验证架构

## 5.1 推荐验证方法学

推荐采用 UVM 或等价分层验证架构，至少包含：

* sequencer / sequence
* driver
* monitor
* scoreboard
* checker/assertion layer
* coverage collector
* test library

如果当前项目希望轻量化，也可以 block-level 使用自定义 SV testbench，但 **top-level 和 CSR 环境仍建议采用事务级组织**，否则后续场景扩展会很痛苦。

## 5.2 统一验证组件

建议统一抽象以下 transaction：

* `input_frame_tr`
* `cic_cfg_tr`
* `fir_cfg_tr`
* `fir_coef_tr`
* `cnn_cfg_tr`
* `csr_access_tr`
* `result_tr`
* `irq_event_tr`

## 5.3 统一 reference path

建议建立三层 golden / checker：

1. **寄存器层 checker**

   * 检查 CSR、IRQ、状态机

2. **block 数值模型**

   * CIC software model
   * FIR software model
   * CNN layer software model

3. **system end-to-end model**

   * 输入 frame -> DSP -> CNN -> 输出结果

---

## 6. 验证环境分解

## 6.1 `csr_irq_tb`

目标：

* 验证寄存器 reset 值
* 访问属性
* start/stop/soft_rst
* irq raw/mask/status/clear
* busy 写保护
* error code 首错保持

检查点来自 `CSR_INTERRUPT_SPEC`。

### 6.1.1 关键组件

* AXI-Lite driver
* CSR mirror model
* interrupt monitor
* protocol assertion set

---

## 6.2 `cic_tb`

目标：

* 验证 CIC 数学行为、相位、位宽增长与边界行为

检查点来自 `FILTER_CIC_SPEC`：

* Hogenauer 结构
* `R/N/M/PHASE`
* sign extension
* wrap-around overflow
* 输出 valid 周期性
* 不依赖 `m_axis_tready`。

### 6.2.1 关键组件

* streaming input driver
* CIC fixed-width reference model
* output monitor
* phase/period checker

---

## 6.3 `fir_tb`

目标：

* 验证 FIR 系数装载、卷积、flush、量化、边带对齐

检查点来自 `FILTER_FIR_SPEC`：

* coef load protocol
* head flush / tail flush
* signed multiply / adder tree
* rounding / shift / saturation
* output valid/user/last 对齐。

### 6.3.1 关键组件

* coef loader agent
* frame input driver
* FIR fixed-point reference model
* sideband alignment checker

---

## 6.4 `cnn_core_tb`

目标：

* 验证 CNN core 支持矩阵内所有 layer
* CBUF/WBUF/folding/post-process 行为
* 结果口与状态寄存器

检查点来自 `CORE_CNN_SPEC`：

* Conv1D / DWConv / Pool / FC
* Weight Stationary
* Ping-Pong CBUF
* folding
* ReLU / pool / requant
* illegal config 拒绝。

### 6.4.1 关键组件

* layer config generator
* input feature map driver
* software CNN reference model
* CBUF state checker
* fold / layer progress checker

---

## 6.5 `top_tb`

目标：

* 验证系统级 frame lifecycle
* 验证输入流到结果输出的完整链路
* 验证异常注入后的系统表现

检查点来自 `DSP_CNN_SYSTEM_SPEC` 和各 block spec。

### 6.5.1 关键组件

* input frame source
* AXI-Lite config agent
* top-level scoreboard
* global state monitor
* result/interrupt monitor

---

## 7. Golden Reference 策略

## 7.1 CIC Golden

必须使用**固定宽度补码模型**，逐级模拟：

* sign extension
* integrator accumulation
* phase-based decimation
* comb subtraction
* wrap-around overflow

不能用无限精度最后统一裁剪，否则会与 RTL 不一致。这个要求来自 CIC spec 本身。

## 7.2 FIR Golden

必须使用定点 FIR 软件模型，逐拍模拟：

* 系数加载
* 输入延迟线
* head flush / tail flush
* signed MAC
* round + shift + saturate
* sideband 对齐

这与 FIR spec 的定义一致。

## 7.3 CNN Golden

必须使用 layer-by-layer 软件模型，逐层执行：

* Conv1D / DWConv / Pool / FC
* bias add
* ReLU
* requant
* output shape 计算

要求：

* 与 RTL 使用相同定点位宽
* folding 只影响时序，不影响数值
* buffer/CBUF 只是存储机制，不应改变 golden 结果。

## 7.4 Top Golden

top-level end-to-end golden 由三个子模型串接：

[
Input \rightarrow CIC_golden \rightarrow FIR_golden \rightarrow CNN_golden \rightarrow Result
]

---

## 8. 检查机制（Checkers）

验证环境至少应包含以下 checker：

## 8.1 协议类 checker

* AXI-Lite CSR 协议 checker
* 输入 frame 边界 checker
* 输出 result 边界 checker
* IRQ pending/mask/clear checker

## 8.2 状态机 checker

* system FSM 合法跳转
* FIR flush 状态转移
* CNN layer / fold 状态转移
* busy/done/err 互斥与优先级检查

## 8.3 数值类 checker

* CIC 输出与 golden 对齐
* FIR 输出与 golden 对齐
* CNN 每层输出与 golden 对齐
* 最终结果与 golden 对齐

## 8.4 约束类 checker

* busy 时禁止改配置
* illegal config 必须拒绝启动
* capacity overrun 必须报错
* result overrun 必须置位状态

---

## 9. Assertion 规划

建议在 RTL 或 bind 侧布置 SVA，至少包含以下几类。

## 9.1 Reset Assertions

* reset 后状态回到 idle
* sticky 位清零或符合 reset 缺省值
* active FSM/state/index 清零

## 9.2 CSR Assertions

* RO 寄存器不可被写改变
* SC 位单拍自清
* W1C 位仅在写 1 时清除
* busy 写保护生效

## 9.3 CIC Assertions

* `s_axis_tready == 1`（v1 contract）
* `m_axis_tvalid` 周期符合 decimation 规律
* 非 valid 周期 `tlast/user=0`

## 9.4 FIR Assertions

* head flush / tail flush 周期数正确
* `coef_ready` 仅在合法装载后拉高
* 输出 sideband 与 data 同步

## 9.5 CNN Assertions

* layer index 单调推进
* fold index 在合法范围
* `KERNEL_SIZE > GP_PE_MAC_NUM` 不得进入 compute
* CBUF read/write 选择切换合法
* done 仅在最后一层完成后拉高

## 9.6 Top Assertions

* done 与 err 优先级关系
* stop 不得直接硬切数据流
* result_valid 与 irq_done 关系正确

---

## 10. Directed Test 计划

## 10.1 CSR / IRQ Directed Tests

至少包括：

1. reset default value
2. RO/RW/W1C/SC access
3. start in idle
4. start in busy
5. soft reset during run
6. irq mask / unmask
7. irq clear
8. first-error hold

## 10.2 CIC Directed Tests

至少包括：

1. impulse
2. DC input
3. sinusoid
4. alternating max/min
5. phase = 0
6. phase = R-1
7. invalid parameter reject
8. `m_axis_tready=0` contract observation

## 10.3 FIR Directed Tests

至少包括：

1. normal coef load
2. incomplete coef load
3. over coef load
4. head flush only
5. tail flush only
6. short frame
7. single-sample frame
8. round/sat corner cases

## 10.4 CNN Directed Tests

至少包括：

1. single Conv1D layer
2. Conv + ReLU
3. DWConv
4. Conv + MaxPool
5. Conv + AvgPool
6. pointwise Conv (`K=1`)
7. FC output mode
8. illegal layer config reject
9. CBUF capacity reject
10. fold-required case

## 10.5 Top Directed Tests

至少包括：

1. single frame end-to-end
2. multi-frame end-to-end
3. start/stop/restart
4. FIR -> CNN handoff
5. irq-driven completion
6. result overrun
7. error injection path
8. soft reset in compute

---

## 11. Constrained-Random 计划

## 11.1 Randomization 目标

通过 CRV 扩大以下维度组合覆盖：

* frame length
* CIC `R/N/M/PHASE`
* FIR tap/shift/coefs
* CNN layer count
* `IN_CH / OUT_CH / SEQ_LEN`
* `KERNEL_SIZE / STRIDE / PADDING`
* pool type/size
* interrupt mask setting
* backpressure insertion points

## 11.2 Randomization 约束

CRV 需分成两类：

### 合法配置随机

* 只产生 spec 支持的合法组合
* 用于数值与功能覆盖收敛

### 非法配置随机

* 有目的地产生非法值
* 用于验证拒绝启动、错误码与中断路径

## 11.3 随机化分层

建议采用：

* block-local random
* system config random
* traffic timing random
* error injection random

---

## 12. Coverage 计划

## 12.1 Functional Coverage 目标

### 12.1.1 CSR 覆盖

* 每个寄存器都被读写
* 每个 bitfield 的合法/非法值
* 每种访问属性
* 每种 irq source
* 每种 err code

### 12.1.2 CIC 覆盖

Coverpoints：

* `R`
* `N`
* `M`
* `PHASE`
* 输入模式（连续 / 断续）
* output pulse spacing
* reset during active

Cross：

* `R x PHASE`
* `N x M`
* input pattern x phase

### 12.1.3 FIR 覆盖

Coverpoints：

* tap 数
* shift 值
* round on/off
* sat on/off
* frame 长度
* head flush
* tail flush
* coef load outcome

Cross：

* tap x frame_len
* round x sat
* short_frame x tail_flush

### 12.1.4 CNN 覆盖

Coverpoints：

* layer type
* kernel size
* stride
* padding
* pool type
* in/out channel bucket
* fold required yes/no
* requant shift
* result mode

Cross：

* layer type x kernel size
* layer type x fold required
* pool type x seq len
* in_ch x out_ch x fold

### 12.1.5 Top 覆盖

Coverpoints：

* frame lifecycle path
* start/stop/reset sequence
* done/err/irq combinations
* top error source
* result path mode

Cross：

* system state x irq source
* error source x recovery action
* frame_len x cnn_layer_num

## 12.2 Code Coverage 目标

建议 signoff 前达到：

* statement coverage ≥ 95%
* branch coverage ≥ 90%
* expression/toggle coverage ≥ 90%

对于 unreachable / reserved / implementation-specific dead code，必须有 waiver。

## 12.3 Assertion Coverage

* 关键 assertions 需有正向触发和负向不触发记录
* 对未触发 assertion 要分析是否为死逻辑或场景缺失

---

## 13. Error Injection 计划

必须显式做 fault/error injection，而不是只靠自然随机碰撞。

至少包括：

1. busy 时写受保护寄存器
2. CIC 非法参数
3. FIR 系数未装满
4. FIR tail flush 未完成时新 frame 到来
5. CNN illegal kernel size
6. CBUF capacity overflow 配置
7. result 未读覆盖
8. soft reset 插在运行中
9. timeout 模拟（通过拉住 done path 或 mock stall）

每种错误都必须检查：

* `ERR` sticky
* `ERR_CODE`
* `ERR_SUMMARY`
* `IRQ_ERR`
* 恢复流程

这些行为都来自你前面的 CSR/system 设计。

---

## 14. 性能相关验证

v1 不要求严格做性能 signoff，但至少需要做 **性能一致性验证**：

## 14.1 Counter Correctness

验证：

* `CYCLE_CNT`
* `FRAME_CNT`
* `STALL_CNT`
* `CNN_BUSY_CNT`

与真实事件一致。

## 14.2 Folding 计数正确

验证 `ACTIVE_FOLD_IDX` / fold_count 与实际 layer 映射一致。

## 14.3 Latency Sanity

对若干固定配置，检查：

* CIC latency
* FIR latency
* CNN per-layer latency
* top frame latency

是否落在 spec 预期范围内。这里不是做 timing signoff，而是防止状态机或 buffer 逻辑导致异常多拍。

---

## 15. 回归计划（Regression Plan）

## 15.1 Regression 层级

### Smoke Regression

每次提交必跑，覆盖：

* CSR basic
* CIC smoke
* FIR smoke
* CNN smoke
* Top smoke

### Nightly Regression

每天至少跑：

* directed full set
* constrained-random medium set
* assertions on
* coverage dump on

### Weekly Full Regression

每周全量：

* all directed
* all CRV seeds
* error injection
* reset stress
* long-run multi-frame tests
* coverage merge

## 15.2 Seed 策略

* smoke：固定 seed
* nightly：少量 rotating seeds
* weekly：大批量随机 seed + failure triage

---

## 16. Bug 管理与收敛要求

## 16.1 Bug 分类

* `P0`：数据错误 / 协议错误 / 死锁 / spec 违背
* `P1`：边界场景错误 / 恢复错误 / 中断错误
* `P2`：低概率场景 / debug 信息错误
* `P3`：日志、观测性、小问题

## 16.2 收敛标准

signoff 前要求：

* `P0 = 0`
* `P1 = 0`
* `P2` 有明确 waiver 或修复计划
* `P3` 不阻塞 signoff

---

## 17. Block-Level Signoff Criteria

## 17.1 CSR / IRQ Signoff

* 寄存器访问属性全部通过
* irq 路径全部通过
* first-error / busy-protect / sticky-clear 通过
* CSR functional coverage ≥ 95%

## 17.2 CIC Signoff

* 所有 directed 通过
* CRV 覆盖主要参数空间
* fixed-width golden 对齐
* CIC functional coverage ≥ 95%

## 17.3 FIR Signoff

* coef / flush / quant 全部通过
* sideband 对齐全部通过
* 短帧/异常帧通过
* FIR functional coverage ≥ 95%

## 17.4 CNN Signoff

* 所有支持 layer 通过
* folding 场景通过
* illegal config 全覆盖
* CNN functional coverage ≥ 95%

---

## 18. Top-Level Signoff Criteria

Top signoff 前必须满足：

1. end-to-end directed 全通过
2. top constrained-random 稳定
3. 所有关键 error injection 路径通过
4. 顶层 functional coverage ≥ 90%
5. 顶层 code coverage 达标
6. 关键 assertions 全 green
7. 无 P0/P1 bug
8. 结果与 end-to-end golden 对齐
9. reset / stop / restart / irq recovery 全通过

---

## 19. 交付物（Deliverables）

验证阶段应交付：

* verification environment source
* test list
* testplan-to-test mapping
* functional coverage report
* code coverage report
* assertion report
* regression summary
* open bug list
* waiver list
* signoff report

---

## 20. 测试映射建议（Testplan Mapping）

建议维护一张独立表，把 spec 条目映射到 test case：

| Spec Item             | Test Name               | Level  | Status |
| --------------------- | ----------------------- | ------ | ------ |
| CSR busy protect      | `csr_busy_protect_test` | block  | TBD    |
| CIC phase behavior    | `cic_phase_sweep_test`  | block  | TBD    |
| FIR head flush        | `fir_head_flush_test`   | block  | TBD    |
| CNN fold accumulation | `cnn_fold_accum_test`   | block  | TBD    |
| Top irq recovery      | `top_irq_recovery_test` | system | TBD    |

这张表后面很重要，因为评审最喜欢问：
**“你 spec 里这个要求，对应哪条测试？”**

---

## 21. 风险项与验证重点

当前 v1 最需要重点盯的高风险项有 5 个：

### 21.1 CIC 无反压契约

如果系统集成错误地把它当成标准可回压 AXIS，容易丢数或死锁。

### 21.2 FIR flush 边界

head/tail flush 是最容易出 off-by-one、脏数据污染、尾样本丢失的地方。

### 21.3 CNN folding

folding 既影响时序，又影响 partial sum 生命周期，是 CNN core 最容易错的路径。

### 21.4 CBUF flip 与地址生成

读写 buffer 翻转、DWConv 读模式、输出 shape 写回地址，很容易在多层网络下出错。

### 21.5 CSR / IRQ / Error Recovery

系统“能算对”还不够，**算错时能不能准确定错、能不能恢复** 同样是 signoff 重点。

---



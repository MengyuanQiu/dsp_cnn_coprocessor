# DSP-CNN 边缘智能协处理器

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## 项目概述

DSP-CNN 协处理器面向雷达/通信一维序列信号的低功耗边缘推理场景，在单颗 FPGA/SoC 内实现从高速采样流到分类结果输出的端到端硬件处理链。

### 系统架构

```
Input Stream → CIC Decimator → FIR Compensator → CNN Inference Engine → Result Output
                                                                    ↑
                                              AXI-Lite CSR Controller
```

### v1 功能范围

- **CIC 抽取滤波器**：大倍率抽取、粗抗混叠、无乘法器 Hogenauer 结构
- **FIR 补偿滤波器**：通带补偿、抗混叠低通、round + saturate 量化
- **1D-CNN 推理引擎**：Conv1D / DWConv / Pool / ReLU / FC、Ping-Pong CBUF、Weight Stationary
- **AXI-Lite CSR 控制器**：寄存器配置、中断管理、错误收集、性能计数
- **系统集成**：全局 FSM、帧生命周期管理、多模块协调

## 目录结构

```
dsp_cnn_coprocessor/
├── docs/                    # 规格文档
│   ├── 00_dsp_cnn_system_spec.md    # 系统主规格书
│   ├── 01_csr_interrupt_spec.md     # CSR 与中断规格书
│   ├── 02_filter_cic_spec.md        # CIC 抽取滤波器规格书
│   ├── 03_filter_fir_spec.md        # FIR 补偿滤波器规格书
│   ├── 04_core_cnn_spec.md          # 1D-CNN 核心规格书
│   └── 05_verification_plan.md      # 验证计划书
├── rtl/                     # RTL 源码
│   ├── dsp_cnn_pkg.sv               # 全局参数与类型定义包
│   ├── filter_cicd.sv               # CIC 抽取滤波器
│   ├── filter_fir.sv                # FIR 补偿滤波器
│   ├── conv.sv                      # FIR 卷积子模块
│   ├── adder_tree.sv                # 流水线加法树
│   ├── accumulator.sv               # 累加器
│   ├── comb_stage.sv                # CIC 梳状器级
│   ├── shiftreg.sv                  # 移位寄存器
│   ├── multiplier.sv                # 乘法器
│   ├── dff.sv                       # D 触发器
│   ├── adder.sv                     # 加法器
│   └── axi_stream_if.sv            # AXI-Stream 接口定义
├── tb/                      # 验证环境 (Testbench)
├── sim/                     # 仿真脚本与配置
├── scripts/                 # 自动化脚本
├── Log/                     # 工作日志
├── LICENSE
└── README.md
```

## 技术规格

| 参数 | 默认值 | 范围 |
|------|--------|------|
| 输入数据位宽 | 8-bit | 4~32 |
| CNN 激活位宽 | 8-bit | 4~16 |
| CNN 权重位宽 | 8-bit | 4~16 |
| CNN 累加器位宽 | 32-bit | 16~40 |
| CIC 抽取率 | 64 | 2~4096 |
| CIC 阶数 | 5 | 2~8 |
| FIR Tap 数 | 64 | 4~256 |
| PE 并行数 | 64 | 8~256 |

## 开发状态

- [x] 文档规格体系（System / CSR / CIC / FIR / CNN / Verification Plan）
- [x] CIC 抽取滤波器基础 RTL
- [x] FIR 补偿滤波器基础 RTL
- [x] 通用基础模块（加法器、乘法器、移位寄存器、DFF）
- [ ] CIC 模块 Spec 对齐（帧边界、使能、错误上报）
- [ ] FIR 模块 Spec 对齐（状态机、系数协议、Flush）
- [ ] CNN 推理引擎 RTL
- [ ] CSR / 中断控制器 RTL
- [ ] 系统顶层集成
- [ ] 验证环境搭建

## 许可证

本项目采用 [MIT License](LICENSE)。

// =============================================================================
// DSP-CNN 协处理器 - 全局参数与类型定义包
// =============================================================================
// Document ID : DSP_CNN_PKG
// Description : 系统级通用参数、数据类型、错误码和常量定义。
//               所有子模块应 import 此包获取统一的参数和类型。
// Applies To  : DSP_CNN_SYSTEM_SPEC v2.x
// =============================================================================

package dsp_cnn_pkg;

    // =========================================================================
    // 1. 系统级数据通路参数
    // =========================================================================
    // 输入采样位宽
    parameter int GP_SYS_IN_WIDTH       = 8;
    // CNN 激活位宽 (FIR 输出 = CNN 输入)
    parameter int GP_SYS_ACT_WIDTH      = 8;
    // CNN 权重位宽
    parameter int GP_SYS_WEIGHT_WIDTH   = 8;
    // CNN 累加器位宽
    parameter int GP_SYS_ACC_WIDTH      = 32;

    // =========================================================================
    // 2. CIC 默认参数
    // =========================================================================
    parameter int GP_CIC_R_DEFAULT      = 64;   // 默认抽取率
    parameter int GP_CIC_N_DEFAULT      = 5;    // 默认阶数
    parameter int GP_CIC_M_DEFAULT      = 1;    // 默认差分延迟
    parameter int GP_CIC_PHASE_DEFAULT  = 0;    // 默认相位

    // CIC 参数范围
    parameter int GP_CIC_R_MIN          = 2;
    parameter int GP_CIC_R_MAX          = 4096;
    parameter int GP_CIC_N_MIN          = 2;
    parameter int GP_CIC_N_MAX          = 8;
    parameter int GP_CIC_M_MIN          = 1;
    parameter int GP_CIC_M_MAX          = 2;

    // =========================================================================
    // 3. FIR 默认参数
    // =========================================================================
    parameter int GP_FIR_N_DEFAULT      = 64;   // 默认 tap 数
    parameter int GP_FIR_SHIFT_DEFAULT  = 18;   // 默认右移位数
    parameter int GP_FIR_COEF_W_DEFAULT = 16;   // 默认系数位宽

    // FIR 参数范围
    parameter int GP_FIR_N_MIN          = 4;
    parameter int GP_FIR_N_MAX          = 256;
    parameter int GP_FIR_SHIFT_MIN      = 0;
    parameter int GP_FIR_SHIFT_MAX      = 63;

    // =========================================================================
    // 4. CNN 默认参数
    // =========================================================================
    parameter int GP_CNN_PE_MAC_NUM     = 3;    // 单 PE 最大 kernel size
    parameter int GP_CNN_PE_CLUSTER_NUM = 64;   // 物理并行 PE 数
    parameter int GP_CNN_MAX_LAYER_NUM  = 16;   // 最大支持层数

    // =========================================================================
    // 5. 系统状态机编码
    // =========================================================================
    typedef enum logic [3:0] {
        SYS_ST_RESET         = 4'd0,
        SYS_ST_IDLE          = 4'd1,
        SYS_ST_CONFIG        = 4'd2,
        SYS_ST_ARMED         = 4'd3,
        SYS_ST_STREAMING_DSP = 4'd4,
        SYS_ST_CNN_COMPUTE   = 4'd5,
        SYS_ST_RESULT_DRAIN  = 4'd6,
        SYS_ST_DONE          = 4'd7,
        SYS_ST_ERROR         = 4'd8
    } sys_state_t;

    // =========================================================================
    // 6. FIR 状态机编码
    // =========================================================================
    typedef enum logic [2:0] {
        FIR_ST_IDLE       = 3'd0,
        FIR_ST_COEF_LOAD  = 3'd1,
        FIR_ST_HEAD_FLUSH = 3'd2,
        FIR_ST_RUN        = 3'd3,
        FIR_ST_TAIL_FLUSH = 3'd4,
        FIR_ST_DONE       = 3'd5,
        FIR_ST_ERROR      = 3'd6
    } fir_state_t;

    // =========================================================================
    // 7. CNN 状态机编码
    // =========================================================================
    typedef enum logic [3:0] {
        CNN_ST_IDLE         = 4'd0,
        CNN_ST_LOAD_INPUT   = 4'd1,
        CNN_ST_CHECK_CFG    = 4'd2,
        CNN_ST_LOAD_WEIGHT  = 4'd3,
        CNN_ST_COMPUTE      = 4'd4,
        CNN_ST_POST_PROCESS = 4'd5,
        CNN_ST_WRITE_BACK   = 4'd6,
        CNN_ST_DONE         = 4'd7,
        CNN_ST_ERROR        = 4'd8
    } cnn_state_t;

    // =========================================================================
    // 8. CNN Layer 类型编码
    // =========================================================================
    typedef enum logic [2:0] {
        LAYER_CONV1D   = 3'd0,
        LAYER_DWCONV1D = 3'd1,
        LAYER_POOL     = 3'd2,
        LAYER_FC       = 3'd3
    } layer_type_t;

    // =========================================================================
    // 9. Pooling 类型编码
    // =========================================================================
    typedef enum logic [2:0] {
        POOL_NONE = 3'd0,
        POOL_MAX  = 3'd1,
        POOL_AVG  = 3'd2
    } pool_type_t;

    // =========================================================================
    // 10. Activation 类型编码
    // =========================================================================
    typedef enum logic [1:0] {
        ACT_NONE = 2'd0,
        ACT_RELU = 2'd1
    } act_type_t;

    // =========================================================================
    // 11. 错误码定义 (对应 CSR_INTERRUPT_SPEC 第 15 章)
    // =========================================================================
    typedef enum logic [15:0] {
        ERR_NONE                      = 16'h0000,
        ERR_BUSY_START                = 16'h0001,
        ERR_CFG_WRITE_WHILE_BUSY      = 16'h0002,
        ERR_CFG_INCOMPLETE            = 16'h0003,
        ERR_FRAME_LEN_MISMATCH        = 16'h0004,
        ERR_CIC_PARAM_ILLEGAL         = 16'h0005,
        ERR_FIR_PARAM_ILLEGAL         = 16'h0006,
        ERR_FIR_COEF_INCOMPLETE       = 16'h0007,
        ERR_FIR_COEF_LOAD             = 16'h0008,
        ERR_CNN_PARAM_ILLEGAL         = 16'h0009,
        ERR_CBUF_OVERFLOW             = 16'h000A,
        ERR_CBUF_UNDERFLOW            = 16'h000B,
        ERR_RESULT_OVERRUN            = 16'h000C,
        ERR_TIMEOUT_CIC               = 16'h000D,
        ERR_TIMEOUT_FIR               = 16'h000E,
        ERR_TIMEOUT_CNN               = 16'h000F,
        ERR_STOP_WHILE_ILLEGAL_STATE  = 16'h0010
    } err_code_t;

    // =========================================================================
    // 12. 模块 ID 编码 (用于 ERR_SUBINFO)
    // =========================================================================
    typedef enum logic [3:0] {
        MOD_ID_SYS    = 4'd1,
        MOD_ID_CIC    = 4'd2,
        MOD_ID_FIR    = 4'd3,
        MOD_ID_CNN    = 4'd4,
        MOD_ID_RESULT = 4'd5
    } module_id_t;

    // =========================================================================
    // 13. 中断源位定义
    // =========================================================================
    parameter int IRQ_BIT_DONE       = 0;
    parameter int IRQ_BIT_ERR        = 1;
    parameter int IRQ_BIT_RESULT_RDY = 2;
    parameter int IRQ_BIT_BUF_WARN   = 3;
    parameter int IRQ_BIT_CFG_REJECT = 4;
    parameter int IRQ_BIT_TIMEOUT    = 5;

    // =========================================================================
    // 14. CSR 地址偏移量定义
    // =========================================================================
    // System Control / Status
    parameter logic [11:0] CSR_SYS_CTRL       = 12'h000;
    parameter logic [11:0] CSR_SYS_STATUS     = 12'h004;
    parameter logic [11:0] CSR_SYS_ERR_CODE   = 12'h008;
    parameter logic [11:0] CSR_ERR_SUMMARY     = 12'h00C;
    parameter logic [11:0] CSR_IRQ_MASK        = 12'h010;
    parameter logic [11:0] CSR_IRQ_STATUS      = 12'h014;
    parameter logic [11:0] CSR_IRQ_RAW_STATUS  = 12'h018;

    // Frame / Input Config
    parameter logic [11:0] CSR_FRAME_LEN_CFG   = 12'h040;
    parameter logic [11:0] CSR_INPUT_MODE_CFG  = 12'h044;

    // CIC Config
    parameter logic [11:0] CSR_CIC_CFG0        = 12'h080;
    parameter logic [11:0] CSR_CIC_CFG1        = 12'h084;
    parameter logic [11:0] CSR_CIC_STATUS      = 12'h088;

    // FIR Config
    parameter logic [11:0] CSR_FIR_CFG0        = 12'h0C0;
    parameter logic [11:0] CSR_FIR_CFG1        = 12'h0C4;
    parameter logic [11:0] CSR_FIR_STATUS      = 12'h0C8;

    // CNN Config
    parameter logic [11:0] CSR_CNN_GLOBAL_CFG  = 12'h100;
    parameter logic [11:0] CSR_CNN_CTRL        = 12'h104;
    parameter logic [11:0] CSR_CNN_STATUS      = 12'h108;

    // CNN Layer Config Base
    parameter logic [11:0] CSR_LAYER0_CFG_BASE = 12'h140;
    parameter logic [11:0] CSR_LAYER_STRIDE    = 12'h010;

    // Result / Debug
    parameter logic [11:0] CSR_RESULT0         = 12'h200;
    parameter logic [11:0] CSR_RESULT1         = 12'h204;
    parameter logic [11:0] CSR_RESULT_STATUS   = 12'h208;
    parameter logic [11:0] CSR_DEBUG_STATUS0   = 12'h20C;

    // Performance Counters
    parameter logic [11:0] CSR_CYCLE_CNT       = 12'h240;
    parameter logic [11:0] CSR_FRAME_CNT       = 12'h244;
    parameter logic [11:0] CSR_STALL_CNT       = 12'h248;
    parameter logic [11:0] CSR_CNN_BUSY_CNT    = 12'h24C;
    parameter logic [11:0] CSR_PERF_CTRL       = 12'h250;

    // FIR Coeff Window
    parameter logic [11:0] CSR_FIR_COEF_PORT   = 12'h300;
    parameter logic [11:0] CSR_FIR_COEF_CTRL   = 12'h304;
    parameter logic [11:0] CSR_FIR_COEF_COUNT  = 12'h308;

endpackage : dsp_cnn_pkg

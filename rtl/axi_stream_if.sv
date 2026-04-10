interface axi_stream_if #(
    parameter int DATA_WIDTH = 32,
    parameter int USER_WIDTH = 1
) (
    input logic clk,
    input logic rst_n
);
    // 定义总线信号
    logic                      tvalid;
    logic                      tready;
    logic [    DATA_WIDTH-1:0] tdata;
    logic [(DATA_WIDTH/8)-1:0] tkeep;
    logic                      tlast;
    logic [    USER_WIDTH-1:0] tuser;

    // Modport 定义方向视角
    // 发送端 (Master) 视角：自己输出 valid 和数据，接收 ready
    modport master(input clk, rst_n, tready, output tvalid, tdata, tkeep, tlast, tuser);

    // 接收端 (Slave) 视角：自己输出 ready，接收 valid 和数据
    modport slave(input clk, rst_n, tvalid, tdata, tkeep, tlast, tuser, output tready);
endinterface : axi_stream_if

//
// PCILeech FPGA.
//
// 多功能控制器模块 - 处理VMD和NVMe端点配置空间
//
// (c) Ulf Frisk, 2021-2024
// Author: Ulf Frisk, pcileech@frizk.net
// Modified: <项目维护者>
//

`timescale 1ns / 1ps

`include "pcileech_header.svh"

module pcileech_tlps128_multifunc_controller(
    input                   rst,
    input                   clk_pcie,
    input                   clk_sys,
    IfAXIS128.sink_lite     tlps_in,      // PCIe TLP输入
    input [15:0]            pcie_id,      // PCIe ID
    IfAXIS128.source        tlps_cfg_rsp, // PCIe配置空间响应
    
    // 设备配置参数
    input  [7:0]            function_count,     // 功能数量配置 (1-8)
    input  [7:0]            device_class,       // 设备类别代码
    input  [7:0]            device_subclass,    // 设备子类别代码
    input  [7:0]            device_interface,   // 设备接口代码
    input  [15:0]           device_id,          // 设备ID
    input  [15:0]           vendor_id,          // 厂商ID
    
    // BAR空间地址配置
    input  [31:0]           bar0_base_addr,
    input  [31:0]           bar1_base_addr,
    input  [31:0]           bar2_base_addr,
    
    // 来自PCIe核心的配置数据
    input  [7:0]            pcie_bus_number,
    input  [4:0]            pcie_device_number,
    input  [2:0]            pcie_function_number,
    
    // 调试和状态输出
    output [31:0]           debug_status,
    
    // 与其他模块的接口
    IfShadow2Fifo.shadow    dshadow2fifo
);

    // 多功能配置相关寄存器
    reg [2:0]  current_function;        // 当前活动的功能ID
    reg [7:0]  active_function_mask;    // 活动功能掩码
    reg [31:0] access_counter;          // 访问计数器
    reg [31:0] function_access_stats [0:7]; // 各功能访问统计
    
    // 初始化多功能配置
    initial begin
        current_function = 3'h0;  // 默认为功能0 (VMD控制器)
        active_function_mask = 8'h01;  // 默认只激活功能0
        
        // 根据配置参数设置功能掩码
        if (function_count > 1) begin
            active_function_mask = (8'h01 << function_count) - 1;
        end
        
        access_counter = 32'h0;
        for (int i = 0; i < 8; i++) begin
            function_access_stats[i] = 32'h0;
        end
    end
    
    // 从TLP提取的请求信息
    wire                pcie_rx_valid   = tlps_in.tvalid && tlps_in.tuser[0];
    wire                pcie_rx_rden    = pcie_rx_valid && (tlps_in.tdata[31:25] == 7'b0000010);  // CfgRd
    wire                pcie_rx_wren    = pcie_rx_valid && (tlps_in.tdata[31:25] == 7'b0100010);  // CfgWr
    wire [9:0]          pcie_rx_addr    = tlps_in.tdata[75:66];
    wire [2:0]          pcie_rx_func    = tlps_in.tdata[78:76];  // 目标功能号
    wire [7:0]          pcie_rx_tag     = tlps_in.tdata[47:40];
    wire [15:0]         pcie_rx_reqid   = tlps_in.tdata[63:48];
    wire [31:0]         pcie_rx_data    = tlps_in.tdata[127:96];
    
    // 使用正确的方式从第一个字节提取字节使能信号
    reg [3:0]          pcie_rx_be;
    always @(*) begin
        pcie_rx_be[0] = tlps_in.tdata[32];
        pcie_rx_be[1] = tlps_in.tdata[33];
        pcie_rx_be[2] = tlps_in.tdata[34];
        pcie_rx_be[3] = tlps_in.tdata[35];
    end
    
    // 地址有效性检查
    wire                pcie_rx_addr_valid = (pcie_rx_addr < 10'h400) && (pcie_rx_addr[1:0] == 2'b00);
    
    // 功能有效性检查
    wire                pcie_rx_func_valid = (active_function_mask & (8'h01 << pcie_rx_func)) != 8'h00;
    
    // 完整的请求有效性
    wire                pcie_rx_req_valid = pcie_rx_valid && pcie_rx_addr_valid && pcie_rx_func_valid;
    
    // 动态更新当前功能号
    always @(posedge clk_pcie) begin
        if (rst) begin
            current_function <= 3'h0;
            access_counter <= 32'h0;
        end else if (pcie_rx_req_valid) begin
            // 更新当前活动功能
            current_function <= pcie_rx_func;
            
            // 更新访问统计
            access_counter <= access_counter + 1;
            function_access_stats[pcie_rx_func] <= function_access_stats[pcie_rx_func] + 1;
            
            // 记录访问模式用于系统驱动加载检测
            if ((pcie_rx_func == 3'h0) && (pcie_rx_addr[9:2] == 8'h01) && pcie_rx_wren) begin
                // VMD控制器Command寄存器写入 - 驱动初始化特征
            end
        end
    end

    // 使用多功能内存包装器实例 - 负责所有配置空间存储和功能控制
    pcileech_mem_wrap_multi i_pcileech_mem_wrap_multi(
        .clk_pcie           ( clk_pcie                 ),
        .clk_sys            ( clk_sys                  ),
        
        // 设备和功能配置
        .function_id        ( current_function         ),
        .function_count     ( function_count           ),
        .device_class       ( device_class             ),
        .device_subclass    ( device_subclass          ),
        .device_interface   ( device_interface         ),
        .device_id          ( device_id                ),
        .vendor_id          ( vendor_id                ),
        
        // 共用读写地址
        .rdwr_addr          ( pcie_rx_addr             ),
        
        // 写入配置空间
        .wr_be              ( pcie_rx_wren ? pcie_rx_be : 4'b0000 ),
        .wr_data            ( pcie_rx_data             ),
           
        // 读取配置空间请求
        .rdreq_tag          ( pcie_rx_tag              ),
        .rdreq_tp           ( {1'b0, pcie_rx_rden}     ),
        .rdreq_reqid        ( pcie_rx_reqid            ),
        .rdreq_tlpwr        ( pcie_rx_wren             ),
        
        // BAR空间基地址配置
        .bar0_base_addr     ( bar0_base_addr           ),
        .bar1_base_addr     ( bar1_base_addr           ),
        .bar2_base_addr     ( bar2_base_addr           ),
        
        // 设备树信息
        .pcie_bus_number    ( pcie_bus_number          ),
        .pcie_device_number ( pcie_device_number       ),
        .pcie_function_number ( pcie_function_number   ),
        
        // 调试输出
        .debug_status       ( debug_status             )
    );
    
    // 将读取结果传递给PCIe配置空间回复模块
    wire [31:0] mem_rd_data;  // 内存读取数据
    wire [9:0]  mem_rd_addr;  // 内存读取地址
    wire [7:0]  mem_rd_tag;   // 内存读取标记
    wire [1:0]  mem_rd_tp;    // 内存读取类型
    wire [15:0] mem_rd_reqid; // 内存读取请求ID
    wire        mem_rd_tlpwr; // 内存读取TLP写标志
    
    assign mem_rd_data = i_pcileech_mem_wrap_multi.rd_data;
    
    // 计算请求状态位
    wire [2:0] pcie_rx_status = {~pcie_rx_valid, ~pcie_rx_addr_valid | ~pcie_rx_func_valid, 1'b0};
    
    // PCIe TLP配置响应模块
    pcileech_cfgspace_pcie_tx i_pcileech_cfgspace_pcie_tx(
        .rst                ( rst                       ),
        .clk_pcie           ( clk_pcie                  ),
        .pcie_id            ( pcie_id                   ),
        .pcie_rx_status     ( pcie_rx_status            ),
        .tlps_cfg_rsp       ( tlps_cfg_rsp              ),
        .cfg_wren           ( pcie_rx_req_valid && (mem_rd_tp[0] || mem_rd_tlpwr) ),
        .cfg_tlpwr          ( mem_rd_tlpwr              ),
        .cfg_tag            ( mem_rd_tag                ),
        .cfg_data           ( mem_rd_data               ),
        .cfg_reqid          ( mem_rd_reqid              )
    );
    
    // USB读写接口 - 通过shadow2fifo接口处理
    assign dshadow2fifo.cfgtlp_en = 1'b1;
    assign dshadow2fifo.cfgtlp_wren = 1'b1;
    assign dshadow2fifo.cfgtlp_zero = 1'b0;
    
    // 调试信息输出 - 可以观察每个功能的访问情况
    assign debug_status = function_access_stats[current_function];

endmodule 
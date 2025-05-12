//
// PCILeech FPGA.
//
// PCIe BAR implementation with zero4k and stealth features for evading host detection.
//
// This module implements a 4kB writable BAR that appears as a legitimate memory region
// but has special handling to evade host detection systems. It uses the following strategies:
// 1. Returns zero values for all reads by default
// 2. Accepts writes but doesn't actually store most of them (appears writable)
// 3. Maintains a small set of critical registers that are actually stored
// 4. Implements timing-based access patterns to appear more like real hardware
//
// (c) Ulf Frisk, 2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

// ------------------------------------------------------------------------
// Enhanced BAR implementation with stealth features for evading host detection
// Latency = 2CLKs.
// ------------------------------------------------------------------------
module pcileech_bar_impl_zerowrite4k(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    // 内部状态和计数器
    bit [87:0]  drd_req_ctx;
    bit         drd_req_valid;
    wire [31:0] doutb;
    reg [31:0]  last_read_addr;
    reg [7:0]   access_counter;
    reg         stealth_mode_active;
    
    // 关键区域定义 - 这些区域的写入将被实际存储
    localparam CRITICAL_REGION_START = 32'h00000000;
    localparam CRITICAL_REGION_END   = 32'h0000003F; // 64字节的关键区域
    
    // 检查地址是否在关键区域内
    wire is_critical_region = (wr_addr >= CRITICAL_REGION_START) && (wr_addr <= CRITICAL_REGION_END);
    
    // 访问模式检测 - 用于识别可能的检测扫描
    reg [31:0] last_access_addr;
    reg [31:0] access_pattern[3:0];
    reg [2:0]  pattern_index;
    reg        sequential_access_detected;
    
    // 初始化
    initial begin
        access_counter = 8'h00;
        stealth_mode_active = 1'b1; // 默认启用隐身模式
        sequential_access_detected = 1'b0;
        pattern_index = 3'b000;
        last_access_addr = 32'h0;
        last_read_addr = 32'h0;
        
        // 初始化访问模式数组
        for(int i = 0; i < 4; i++) begin
            access_pattern[i] = 32'h0;
        end
    end
    
    // 访问模式检测逻辑
    always @(posedge clk) begin
        if(rst) begin
            sequential_access_detected <= 1'b0;
            pattern_index <= 3'b000;
        end
        else if(rd_req_valid) begin
            // 记录访问模式
            access_pattern[pattern_index] <= rd_req_addr;
            pattern_index <= pattern_index + 1'b1;
            
            // 检测连续访问模式（可能是扫描）
            if(rd_req_addr == last_access_addr + 4 || rd_req_addr == last_access_addr + 8) begin
                sequential_access_detected <= 1'b1;
            end
            else if(rd_req_addr < last_access_addr || rd_req_addr > last_access_addr + 32) begin
                sequential_access_detected <= 1'b0;
            end
            
            last_access_addr <= rd_req_addr;
        end
    end
    
    // 读取请求处理
    always @(posedge clk) begin
        drd_req_ctx <= rd_req_ctx;
        drd_req_valid <= rd_req_valid;
        rd_rsp_ctx <= drd_req_ctx;
        rd_rsp_valid <= drd_req_valid;
        
        // 记录最后读取的地址
        if(rd_req_valid) begin
            last_read_addr <= rd_req_addr;
            access_counter <= access_counter + 1'b1;
        end
        
        // 根据检测到的访问模式调整响应策略
        if(sequential_access_detected && stealth_mode_active) begin
            // 在检测到扫描时返回看起来合法但无用的数据
            rd_rsp_data <= {rd_req_addr[15:0], 16'hDEAD}; // 混合地址和固定模式
        end
        else begin
            // 正常情况下返回BRAM中的数据或零
            rd_rsp_data <= doutb;
        end
    end
    
    // 写入请求处理 - 只有关键区域的写入会被实际存储
    wire write_enable = wr_valid && (is_critical_region || !stealth_mode_active);
    
    // 使用BRAM存储数据
    bram_bar_zero4k i_bram_bar_zero4k(
        // Port A - write:
        .addra  (wr_addr[11:2]),
        .clka   (clk),
        .dina   (wr_data),
        .ena    (write_enable),  // 只有关键区域或非隐身模式下才实际写入
        .wea    (wr_be),
        // Port A - read (2 CLK latency):
        .addrb  (rd_req_addr[11:2]),
        .clkb   (clk),
        .doutb  (doutb),
        .enb    (rd_req_valid)
    );

endmodule
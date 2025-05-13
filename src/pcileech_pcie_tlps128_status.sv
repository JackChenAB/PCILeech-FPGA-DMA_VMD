//
// PCILeech FPGA.
//
// PCIe TLP 设备状态寄存器模块
// 使用RW1C寄存器实现VMD设备的标准状态寄存器
//
// (c) Ulf Frisk, 2019-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_pcie_tlps128_status(
    input                   rst,
    input                   clk,
    
    // PCIe配置空间状态寄存器
    output [15:0]           pcie_status,     // 配置空间状态寄存器
    
    // PCIe写入控制
    input                   cfg_wr_en,       // 配置写使能
    input  [15:0]           cfg_wr_data,     // 配置写数据
    input  [15:0]           cfg_wr_mask,     // 配置写掩码
    input                   cfg_rw1c_as_rw,  // PCIe核心的cfg_mgmt_wr_rw1c_as_rw信号
    
    // TLP处理引擎状态
    input                   tlp_err_cor,     // 可纠正错误
    input                   tlp_err_fatal,   // 致命错误
    input                   tlp_err_ur,      // 不支持的请求
    input                   tlp_master_abort, // 主控终止
    
    // 诊断输出
    output [7:0]            status_access_count, // 状态寄存器访问计数器
    output                  status_alert_detected // 检测到异常探测行为
);

    // PCIe状态寄存器各位定义
    // 15    Reserved
    // 14    Detected Parity Error (RW1C)
    // 13    Signaled System Error (RW1C)
    // 12    Received Master Abort (RW1C)
    // 11    Received Target Abort (RW1C)
    // 10    Signaled Target Abort (RW1C)
    // 9:8   DEVSEL Timing (RO)
    // 7     Master Data Parity Error (RW1C)
    // 6     Fast Back-to-Back Capable (RO)
    // 5     66 MHz Capable (RO)
    // 4     Capabilities List (RO)
    // 3     Interrupt Status (RO)
    // 2:0   Reserved (RO)

    // 内部信号
    wire [15:0] status_reg_value;    // 状态寄存器当前值
    reg         status_reg_alert;    // 状态寄存器警告标志
    
    // 硬件事件信号
    reg         hw_set_en;           // 硬件设置使能
    reg [15:0]  hw_set_data;         // 硬件设置数据
    reg [15:0]  hw_set_mask;         // 硬件设置掩码
    
    // 使用RW1C寄存器模块处理状态寄存器
    // 默认值: 0x0010 (Capabilities List位设置为1)
    pcileech_rw1c_register #(
        .WIDTH(16),
        .DEFAULT_VALUE(16'h0010)
    ) status_register (
        .clk(clk),
        .rst(rst),
        
        // 写入控制
        .wr_en(cfg_wr_en),
        .wr_data(cfg_wr_data),
        .wr_mask(cfg_wr_mask),
        
        // 特殊控制
        .force_rw_mode(cfg_rw1c_as_rw),
        
        // 硬件事件设置
        .hw_set_en(hw_set_en),
        .hw_set_data(hw_set_data),
        .hw_set_mask(hw_set_mask),
        
        // 读取接口
        .rd_data(pcie_status),
        
        // 状态和诊断输出
        .reg_value(status_reg_value),
        .access_count(status_access_count),
        .is_zero()
    );
    
    // 硬件事件处理逻辑
    always @(posedge clk) begin
        if (rst) begin
            hw_set_en <= 0;
            hw_set_data <= 0;
            hw_set_mask <= 0;
            status_reg_alert <= 0;
        end else begin
            // 默认不设置
            hw_set_en <= 0;
            
            // 检测TLP错误事件
            if (tlp_err_cor) begin
                // 可纠正错误设置对应位 (位13 - Signaled System Error)
                hw_set_en <= 1;
                hw_set_data <= 16'h2000; // 位13
                hw_set_mask <= 16'h2000;
            end else if (tlp_err_fatal) begin
                // 致命错误设置对应位 (位13 - Signaled System Error和位14 - Detected Parity Error)
                hw_set_en <= 1;
                hw_set_data <= 16'h6000; // 位13和14
                hw_set_mask <= 16'h6000;
            end else if (tlp_err_ur) begin
                // 不支持的请求设置对应位 (位11 - Received Target Abort)
                hw_set_en <= 1;
                hw_set_data <= 16'h0800; // 位11
                hw_set_mask <= 16'h0800;
            end else if (tlp_master_abort) begin
                // 主控终止设置对应位 (位12 - Received Master Abort)
                hw_set_en <= 1;
                hw_set_data <= 16'h1000; // 位12
                hw_set_mask <= 16'h1000;
            end
            
            // 检测状态寄存器异常访问
            if (status_access_count > 8'h20) begin
                status_reg_alert <= 1;
            end else begin
                status_reg_alert <= 0;
            end
        end
    end
    
    // 输出异常警告信号
    assign status_alert_detected = status_reg_alert;

endmodule 
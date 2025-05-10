//
// PCILeech FPGA.
//
// PCIe BAR implementation with MSI-X and PCIe capability support for VMD simulation.
//
// This module implements a BAR with MSI-X interrupt capability and complete PCIe
// capability structures including PCI Express Capability, MSI/MSI-X Capability,
// Power Management Capability, and Vendor-Specific Capability.
//
// (c) 2024
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

// ------------------------------------------------------------------------
// BAR implementation with MSI-X and PCIe capability support for VMD simulation
// Latency = 2CLKs.
// ------------------------------------------------------------------------
module pcileech_bar_impl_vmd_msix(
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
    output bit          rd_rsp_valid,
    // MSI-X中断输出信号 - 连接到TLP引擎:
    output reg          msix_interrupt_valid,    // 中断有效信号
    output reg [63:0]   msix_interrupt_addr,     // 中断目标地址
    output reg [31:0]   msix_interrupt_data,     // 中断数据
    output reg          msix_interrupt_error     // 中断错误指示
);

    // 寄存器定义
    localparam MSIX_TABLE_OFFSET = 32'h00001000;  // MSI-X表偏移地址
    localparam MSIX_PBA_OFFSET = 32'h00002000;    // MSI-X PBA偏移地址
    
    // MSI-X控制寄存器
    reg [31:0] msix_control;      // MSI-X控制寄存器
    reg msix_enabled;             // MSI-X使能标志
    reg msix_masked;              // MSI-X全局屏蔽标志
    reg msix_error_detected;      // MSI-X错误检测标志
    reg [7:0] msix_error_counter; // MSI-X错误计数器
    
    // 初始化MSI-X错误检测相关寄存器 - 增强版
    initial begin
        // 错误检测相关寄存器初始化
        msix_error_detected = 1'b0;
        msix_error_counter = 8'h00;
        msix_interrupt_error = 1'b0;
        
        // 中断状态寄存器初始化
        msix_interrupt_valid = 1'b0;
        msix_interrupt_addr = 64'h0;
        msix_interrupt_data = 32'h0;
    end
    
    // MSI-X错误检测和恢复逻辑 - 增强版
    always @(posedge clk) begin
        if (rst) begin
            msix_error_detected <= 1'b0;
            msix_error_counter <= 8'h00;
            msix_interrupt_error <= 1'b0;
        end else begin
            // 检测中断处理异常 - 增加更多异常检测条件
            if ((msix_interrupt_valid && !msix_enabled) || 
                (msix_interrupt_valid && msix_masked) || 
                (|msix_error_vectors)) begin  // 任何向量错误也会触发
                msix_error_detected <= 1'b1;
                msix_error_counter <= msix_error_counter + 1'b1;
                msix_interrupt_error <= 1'b1;
            end
            
            // 错误恢复逻辑 - 改进恢复机制
            if (msix_error_detected && (msix_error_counter > 8'h10)) begin
                msix_error_detected <= 1'b0;
                msix_error_counter <= 8'h00;
                msix_interrupt_error <= 1'b0;
                // 清除所有错误向量
                msix_error_vectors <= 16'h0000;
                msix_error_cnt <= 4'h0;
                msix_error_overflow <= 1'b0;
            end
        end
    end
    
    // MSI-X表项 (支持16个中断向量)
    reg [31:0] msix_table[63:0];  // 16个表项，每个表项4个DWORD (地址低32位，地址高32位，数据，控制)
    reg [31:0] msix_pba;          // Pending Bit Array
    
    // PCIe能力结构寄存器
    reg [31:0] pcie_cap_regs[16:0];  // PCIe能力寄存器
    reg [31:0] pm_cap_regs[2:0];     // 电源管理能力寄存器
    reg [31:0] vendor_cap_regs[4:0];  // 厂商特定能力寄存器
    
    // 请求延迟处理
    bit [87:0]      rd_req_ctx_1;
    bit [31:0]      rd_req_addr_1;
    bit             rd_req_valid_1;
    
    // 初始化PCIe能力结构
    initial begin
        // PCI Express Capability (ID: 0x10) - 位于偏移0x000
        // 链接到MSI-X能力 (Next Pointer = 0x01)
        pcie_cap_regs[0] = 32'h10010142;  // Capability ID, Next Pointer, Version, Type (Root Complex Integrated Endpoint)
        pcie_cap_regs[1] = 32'h02810001;  // Device Capabilities (Max Payload Size 256 bytes, Extended Tag Field)
        pcie_cap_regs[2] = 32'h00100007;  // Device Control and Status (Enable Relaxed Ordering, Max Read Request Size 512 bytes)
        pcie_cap_regs[3] = 32'h0211A000;  // Link Capabilities (Port Number 1, ASPM L0s/L1, Data Link Layer Active Reporting)
        pcie_cap_regs[4] = 32'h00130001;  // Link Control and Status (ASPM L0s/L1 Enabled)
        pcie_cap_regs[5] = 32'h00000002;  // Device Capabilities 2 (支持TLP处理提示)
        pcie_cap_regs[6] = 32'h00000000;  // Device Control and Status 2
        pcie_cap_regs[7] = 32'h00000000;  // Link Capabilities 2
        pcie_cap_regs[8] = 32'h00000000;  // Link Control and Status 2
        
        // Power Management Capability (ID: 0x01) - 位于偏移0x100
        // 链接到MSI-X能力 (Next Pointer = 0x11)
        pm_cap_regs[0] = 32'h01110003;    // Capability ID, Next Pointer, Version, PME Support (D0-D3)
        pm_cap_regs[1] = 32'h00000008;    // Control/Status Register (No Soft Reset)
        pm_cap_regs[2] = 32'h00000000;    // Bridge Extensions
        
        // MSI-X Capability (ID: 0x11) - 位于偏移0x110
        // 链接到厂商特定能力 (Next Pointer = 0x09)
        msix_control = 32'h11090010;      // Capability ID, Next Pointer, Message Control (16 vectors)
        msix_enabled = 0;
        msix_masked = 1;
        
        // Vendor-Specific Capability (ID: 0x09) - 位于偏移0x120
        // 无后续能力 (Next Pointer = 0x00)
        vendor_cap_regs[0] = 32'h09000000;  // Capability ID, Next Pointer
        vendor_cap_regs[1] = 32'h201D8086;  // Intel VMD Controller Device ID (201D) and Vendor ID (8086)
        vendor_cap_regs[2] = 32'h00010800;  // Class Code (010800 - NVMe RAID Controller)
        vendor_cap_regs[3] = 32'h00000001;  // VMD特定配置
        vendor_cap_regs[4] = 32'h00000000;  // 保留
        
        // 初始化MSI-X表和PBA
        for (int i = 0; i < 64; i++) begin
            msix_table[i] = 32'h00000000;
        end
        msix_pba = 32'h00000000;
        
        // 初始化MSI-X中断状态监控寄存器 - 确保所有状态变量正确初始化
        msix_active_vectors = 16'h0000;
        msix_error_vectors = 16'h0000;
        msix_error_cnt = 4'h0;
        msix_error_overflow = 1'b0;
        
        // 确保MSI-X控制寄存器初始状态正确
        msix_enabled = 1'b0;
        msix_masked = 1'b1;  // 默认屏蔽所有中断
    end
    
    // 处理写请求
    always @(posedge clk) begin
        if (rst) begin
            msix_enabled <= 0;
            msix_masked <= 1;
            msix_pba <= 32'h00000000;
        end else if (wr_valid) begin
            // MSI-X控制寄存器写入 (位于偏移0x110)
            if ((wr_addr & 32'hFFFFFF00) == 32'h00000110) begin
                if (wr_be[0]) msix_control[7:0] <= wr_data[7:0] & 8'hFF;
                if (wr_be[1]) begin
                    msix_control[15:8] <= wr_data[15:8] & 8'hC0;  // 只允许修改Function Mask和MSI-X Enable位
                    msix_enabled <= wr_data[15];
                    msix_masked <= wr_data[14];
                end
                if (wr_be[2]) msix_control[23:16] <= wr_data[23:16] & 8'h00;  // 保留位
                if (wr_be[3]) msix_control[31:24] <= wr_data[31:24] & 8'h00;  // 保留位
            end
            // MSI-X表写入
            else if ((wr_addr & 32'hFFFFF000) == MSIX_TABLE_OFFSET) begin
                int index = (wr_addr[11:2]);
                if (index < 64) begin  // 16个表项 * 4 DWORD = 64
                    case (index[1:0])
                        2'b00: begin  // 地址低32位
                            if (wr_be[0]) msix_table[index][7:0] <= wr_data[7:0];
                            if (wr_be[1]) msix_table[index][15:8] <= wr_data[15:8];
                            if (wr_be[2]) msix_table[index][23:16] <= wr_data[23:16];
                            if (wr_be[3]) msix_table[index][31:24] <= wr_data[31:24];
                        end
                        2'b01: begin  // 地址高32位
                            if (wr_be[0]) msix_table[index][7:0] <= wr_data[7:0];
                            if (wr_be[1]) msix_table[index][15:8] <= wr_data[15:8];
                            if (wr_be[2]) msix_table[index][23:16] <= wr_data[23:16];
                            if (wr_be[3]) msix_table[index][31:24] <= wr_data[31:24];
                        end
                        2'b10: begin  // 数据
                            if (wr_be[0]) msix_table[index][7:0] <= wr_data[7:0];
                            if (wr_be[1]) msix_table[index][15:8] <= wr_data[15:8];
                            if (wr_be[2]) msix_table[index][23:16] <= wr_data[23:16];
                            if (wr_be[3]) msix_table[index][31:24] <= wr_data[31:24];
                        end
                        2'b11: begin  // 控制
                            if (wr_be[0]) msix_table[index][7:0] <= wr_data[7:0] & 8'h01;  // 只允许修改Vector Mask位
                            if (wr_be[1]) msix_table[index][15:8] <= wr_data[15:8] & 8'h00;  // 保留位
                            if (wr_be[2]) msix_table[index][23:16] <= wr_data[23:16] & 8'h00; // 保留位
                            if (wr_be[3]) msix_table[index][31:24] <= wr_data[31:24] & 8'h00; // 保留位
                        end
                    endcase
                end
            end
            // MSI-X PBA写入
            else if ((wr_addr & 32'hFFFFF000) == MSIX_PBA_OFFSET) begin
                // PBA是只读的，写入操作被忽略
            end
            // PCIe能力结构写入
            else if ((wr_addr & 32'hFFFFFF00) == 32'h00000000) begin
                int index = wr_addr[7:2];
                if (index < 17) begin
                    case (index)
                        0: begin  // Capability Header - 只读
                        end
                        2: begin  // Device Control
                            if (wr_be[0]) pcie_cap_regs[index][7:0] <= wr_data[7:0] & 8'hFF;
                            if (wr_be[1]) pcie_cap_regs[index][15:8] <= wr_data[15:8] & 8'hFF;
                            if (wr_be[2]) pcie_cap_regs[index][23:16] <= wr_data[23:16] & 8'h0F; // Status位
                            if (wr_be[3]) pcie_cap_regs[index][31:24] <= wr_data[31:24] & 8'h00; // 保留位
                        end
                        4: begin  // Link Control
                            if (wr_be[0]) pcie_cap_regs[index][7:0] <= wr_data[7:0] & 8'hFC;
                            if (wr_be[1]) pcie_cap_regs[index][15:8] <= wr_data[15:8] & 8'h00; // Status位
                            if (wr_be[2]) pcie_cap_regs[index][23:16] <= wr_data[23:16] & 8'h00;
                            if (wr_be[3]) pcie_cap_regs[index][31:24] <= wr_data[31:24] & 8'h00;
                        end
                        6: begin  // Device Control 2
                            if (wr_be[0]) pcie_cap_regs[index][7:0] <= wr_data[7:0] & 8'h0F;
                            if (wr_be[1]) pcie_cap_regs[index][15:8] <= wr_data[15:8] & 8'h00; // Status位
                            if (wr_be[2]) pcie_cap_regs[index][23:16] <= wr_data[23:16] & 8'h00;
                            if (wr_be[3]) pcie_cap_regs[index][31:24] <= wr_data[31:24] & 8'h00;
                        end
                        default: begin  // 其他寄存器只读
                        end
                    endcase
                end
            end
            // 电源管理能力写入
            else if ((wr_addr & 32'hFFFFFF00) == 32'h00000200) begin
                int index = wr_addr[7:2];
                if (index < 3) begin
                    case (index)
                        1: begin  // Power Management Control/Status
                            if (wr_be[0]) pm_cap_regs[index][7:0] <= wr_data[7:0] & 8'h03;  // PowerState
                            if (wr_be[1]) pm_cap_regs[index][15:8] <= wr_data[15:8] & 8'h00;  // 保留位
                            if (wr_be[2]) pm_cap_regs[index][23:16] <= wr_data[23:16] & 8'h00; // 保留位
                            if (wr_be[3]) pm_cap_regs[index][31:24] <= wr_data[31:24] & 8'h00; // 保留位
                        end
                        default: begin  // 其他寄存器只读
                        end
                    endcase
                end
            end
            // 厂商特定能力写入
            else if ((wr_addr & 32'hFFFFFF00) == 32'h00000300) begin
                int index = wr_addr[7:2];
                if (index < 5) begin
                    case (index)
                        3: begin  // VMD特定配置
                            if (wr_be[0]) vendor_cap_regs[index][7:0] <= wr_data[7:0];
                            if (wr_be[1]) vendor_cap_regs[index][15:8] <= wr_data[15:8];
                            if (wr_be[2]) vendor_cap_regs[index][23:16] <= wr_data[23:16];
                            if (wr_be[3]) vendor_cap_regs[index][31:24] <= wr_data[31:24];
                        end
                        default: begin  // 其他寄存器只读
                        end
                    endcase
                end
            end
        end
    end
    
    // 处理读请求
    always @(posedge clk) begin
        rd_req_ctx_1 <= rd_req_ctx;
        rd_req_addr_1 <= rd_req_addr;
        rd_req_valid_1 <= rd_req_valid;
        rd_rsp_ctx <= rd_req_ctx_1;
        rd_rsp_valid <= rd_req_valid_1;
        
        // 根据地址返回不同的数据
        if (rd_req_valid_1) begin
            // MSI-X控制寄存器读取 (位于偏移0x110)
            if ((rd_req_addr_1 & 32'hFFFFFF00) == 32'h00000110) begin
                rd_rsp_data <= msix_control;
            end
            // MSI-X表读取
            else if ((rd_req_addr_1 & 32'hFFFFF000) == MSIX_TABLE_OFFSET) begin
                int index = (rd_req_addr_1[11:2]);
                if (index < 64) begin
                    rd_rsp_data <= msix_table[index];
                end else begin
                    rd_rsp_data <= 32'h00000000;
                end
            end
            // MSI-X PBA读取
            else if ((rd_req_addr_1 & 32'hFFFFF000) == MSIX_PBA_OFFSET) begin
                rd_rsp_data <= msix_pba;
            end
            // PCIe能力结构读取
            else if ((rd_req_addr_1 & 32'hFFFFFF00) == 32'h00000000) begin
                int index = rd_req_addr_1[7:2];
                if (index < 17) begin
                    rd_rsp_data <= pcie_cap_regs[index];
                end else begin
                    rd_rsp_data <= 32'h00000000;
                end
            end
            // 电源管理能力读取
            else if ((rd_req_addr_1 & 32'hFFFFFF00) == 32'h00000200) begin
                int index = rd_req_addr_1[7:2];
                if (index < 3) begin
                    rd_rsp_data <= pm_cap_regs[index];
                end else begin
                    rd_rsp_data <= 32'h00000000;
                end
            end
            // 厂商特定能力读取
            else if ((rd_req_addr_1 & 32'hFFFFFF00) == 32'h00000300) begin
                int index = rd_req_addr_1[7:2];
                if (index < 5) begin
                    rd_rsp_data <= vendor_cap_regs[index];
                end else begin
                    rd_rsp_data <= 32'h00000000;
                end
            end
            else begin
                rd_rsp_data <= 32'h00000000;
            end
        end else begin
            rd_rsp_data <= 32'h00000000;
        end
    end

    // MSI-X中断状态监控寄存器已在前面初始化，此处不再重复
    
    // MSI-X中断状态监控
    reg [15:0] msix_active_vectors;  // 当前活动的中断向量
    reg [15:0] msix_error_vectors;   // 发生错误的中断向量
    reg [3:0]  msix_error_cnt;       // 中断错误计数器
    reg        msix_error_overflow;   // 中断溢出错误标志
    
    // 触发MSI-X中断的任务 (可以在其他模块中调用) - 增强版
    task trigger_msix_interrupt;
        input [3:0] vector_num;
        reg [63:0] addr;
        reg [31:0] data;
        begin
            // 首先检查MSI-X是否全局启用
            if (msix_enabled && !msix_masked) begin
                // 检查中断向量是否有效
                if (vector_num < 16) begin
                    // 检查中断向量是否已经激活 - 防止重复触发
                    if (msix_active_vectors[vector_num]) begin
                        // 记录错误状态 - 向量重复触发
                        msix_error_vectors[vector_num] <= 1'b1;
                        msix_error_cnt <= (msix_error_cnt == 4'hf) ? msix_error_cnt : (msix_error_cnt + 1);
                        msix_error_overflow <= 1'b1;
                        // 不清除活动状态，让错误处理逻辑来处理
                    end else begin
                        // 设置pending bit和活动向量
                        msix_pba[vector_num] <= 1'b1;
                        msix_active_vectors[vector_num] <= 1'b1;
                        
                        // 检查向量是否被屏蔽
                        if (!(msix_table[vector_num*4+3] & 32'h00000001)) begin
                            // 从MSI-X表中获取中断地址和数据
                            addr[31:0] = msix_table[vector_num*4];
                            addr[63:32] = msix_table[vector_num*4+1];
                            data = msix_table[vector_num*4+2];
                            
                            // 验证地址有效性
                            if (addr != 64'h0) begin
                                // 发送中断消息到PCIe接口
                                msix_interrupt_valid <= 1'b1;
                                msix_interrupt_addr <= addr;
                                msix_interrupt_data <= data;
                                
                                // 状态清理将由时钟同步逻辑处理
                                // 不在这里使用#1延迟，改为在always块中处理
                            end else begin
                                // 地址无效，记录错误
                                msix_error_vectors[vector_num] <= 1'b1;
                                msix_error_cnt <= (msix_error_cnt == 4'hf) ? msix_error_cnt : (msix_error_cnt + 1);
                            end
                        end else begin
                            // 向量被屏蔽，只设置pending bit，不发送中断
                            // pending bit已经在上面设置
                        end
                    end
                end
            end else begin
                // MSI-X未启用或全局屏蔽，记录尝试触发的向量
                if (vector_num < 16) begin
                    msix_pba[vector_num] <= 1'b1;  // 仍然设置pending bit
                end
            end
        end
    endtask
    
    // 重置中断错误状态和管理中断状态清理
    always @(posedge clk) begin
        if (rst) begin
            // 重置所有错误状态
            msix_error_vectors <= 16'h0000;
            msix_error_cnt <= 4'h0;
            msix_error_overflow <= 1'b0;
            msix_active_vectors <= 16'h0000;
            msix_pba <= 32'h00000000;
        end else begin
            // 中断完成后清理状态
            if (msix_interrupt_valid) begin
                // 找出当前活动的中断向量并清除其状态
                for (int i = 0; i < 16; i++) begin
                    if (msix_active_vectors[i]) begin
                        // 清除pending bit和活动向量
                        msix_pba[i] <= 1'b0;
                        msix_active_vectors[i] <= 1'b0;
                    end
                end
            end
            
            // 定期检查并清理长时间未处理的中断向量
            for (int i = 0; i < 16; i++) begin
                if (msix_active_vectors[i] && msix_pba[i] && !msix_interrupt_valid) begin
                    // 如果向量长时间处于活动状态但未被处理，可能是出现了问题
                    // 这里可以添加计数器逻辑来检测超时
                    // 简化起见，我们直接清除这些向量
                    if (msix_error_counter > 8'h08) begin
                        msix_active_vectors[i] <= 1'b0;
                        msix_pba[i] <= 1'b0;
                    end
                end
            end
        end
    end
    
    // 测试中断触发 - 当写入特定地址时触发中断
    // 写入地址0x3000 + vector_num*4 将触发对应向量的中断
    localparam MSIX_TRIGGER_OFFSET = 32'h00003000;  // 中断触发地址偏移
    
    always @(posedge clk) begin
        if (wr_valid && (wr_addr & 32'hFFFFF000) == MSIX_TRIGGER_OFFSET) begin
            // 提取向量号 (0-15)
            int vector_num = (wr_addr[7:2]) & 4'hF;
            
            // 触发对应向量的中断
            trigger_msix_interrupt(vector_num);
        end
    end
    
    // 中断有效信号管理 - 改进版
    always @(posedge clk) begin
        if (rst) begin
            msix_interrupt_valid <= 1'b0;
        end else begin
            if (msix_interrupt_valid) begin
                // 一个时钟周期后自动清除中断有效信号
                msix_interrupt_valid <= 1'b0;
            end
        end
    end

endmodule
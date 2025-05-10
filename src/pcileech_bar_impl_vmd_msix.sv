//
// PCILeech FPGA.
//
// PCIe BAR implementation with MSI-X and PCIe capability support for Intel RST VMD controller simulation.
//
// This module implements a BAR with MSI-X interrupt capability and complete PCIe
// capability structures including PCI Express Capability, MSI/MSI-X Capability,
// Power Management Capability, and Vendor-Specific Capability for Intel RST VMD controller.
//
// (c) Ulf Frisk, 2019-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

// ------------------------------------------------------------------------
// BAR implementation with MSI-X and PCIe capability support for NVMe controller simulation
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
    localparam VMD_REG_OFFSET = 32'h00004000;    // VMD控制器寄存器偏移地址
    localparam NVME_REG_OFFSET = VMD_REG_OFFSET;  // NVMe寄存器与VMD寄存器共用同一偏移地址
    
    // VMD控制器寄存器
    reg [31:0] vmd_regs[64:0];  // VMD控制器寄存器空间
    reg [31:0] vmd_admin_sq_base;  // 管理提交队列基地址
    reg [31:0] vmd_admin_cq_base;  // 管理完成队列基地址
    reg [15:0] vmd_admin_sq_size;  // 管理提交队列大小
    reg [15:0] vmd_admin_cq_size;  // 管理完成队列大小
    reg        vmd_controller_ready; // 控制器就绪状态
    
    // NVMe寄存器 - 与VMD寄存器共用
    `define nvme_regs vmd_regs
    reg        nvme_controller_ready; // NVMe控制器就绪状态 - 与VMD控制器就绪状态共用
    
    // MSI-X控制寄存器
    reg [31:0] msix_control;      // MSI-X控制寄存器
    reg msix_enabled;             // MSI-X使能标志
    reg msix_masked;              // MSI-X全局屏蔽标志
    reg msix_error_detected;      // MSI-X错误检测标志
    reg [7:0] msix_error_counter; // MSI-X错误计数器
    
    // 初始化MSI-X错误检测相关寄存器 - 全面增强版
    initial begin
        // 错误检测相关寄存器初始化
        msix_error_detected = 1'b0;
        msix_error_counter = 8'h00;
        msix_interrupt_error = 1'b0;
        
        // 中断状态寄存器初始化
        msix_interrupt_valid = 1'b0;
        msix_interrupt_addr = 64'h0;
        msix_interrupt_data = 32'h0;
        
        // 确保计数器初始化为0
        interrupt_valid_counter = 3'b000;
        error_recovery_counter = 8'h00;
        
        // 初始化MSI-X控制寄存器状态
        msix_enabled = 1'b0;
        msix_masked = 1'b1;  // 默认屏蔽所有中断
    end
    
    // MSI-X错误检测和恢复逻辑 - 增强版
    reg [2:0] interrupt_valid_counter; // 中断有效信号持续时间计数器
    reg [7:0] error_recovery_counter;  // 错误恢复计数器
    
    // 初始化计数器
    initial begin
        interrupt_valid_counter = 3'b000;
        error_recovery_counter = 8'h00;
    end
    
    always @(posedge clk) begin
        if (rst) begin
            msix_error_detected <= 1'b0;
            msix_error_counter <= 8'h00;
            msix_interrupt_error <= 1'b0;
            msix_interrupt_valid <= 1'b0;
            interrupt_valid_counter <= 3'b000;
            error_recovery_counter <= 8'h00;
        end else begin
            // 错误检测逻辑 - 增强版
            if ((msix_interrupt_valid && !msix_enabled) || 
                (msix_interrupt_valid && msix_masked) || 
                (|msix_error_vectors)) begin  // 任何向量错误也会触发
                msix_error_detected <= 1'b1;
                msix_error_counter <= msix_error_counter + 1'b1;
                msix_interrupt_error <= 1'b1;
                
                // 记录错误时增加恢复计数器
                error_recovery_counter <= error_recovery_counter + 1'b1;
            end
            
            // 中断有效信号自动清除 - 优化版
            // 使用计数器确保中断信号保持足够的时钟周期但不会过长
            if (msix_interrupt_valid) begin
                // 使用计数器延迟清除中断有效信号，确保TLP引擎有足够时间捕获
                interrupt_valid_counter <= interrupt_valid_counter + 1'b1;
                
                // 计数器达到预设值后清除中断有效信号 - 增加可配置性
                if (interrupt_valid_counter >= 3'b101) begin // 增加持续时间
                    msix_interrupt_valid <= 1'b0;
                    interrupt_valid_counter <= 3'b000;
                    
                    // 清除中断地址和数据，防止残留
                    msix_interrupt_addr <= 64'h0;
                    msix_interrupt_data <= 32'h0;
                end
            end else begin
                // 重置计数器
                interrupt_valid_counter <= 3'b000;
            end
            
            // 错误恢复逻辑 - 改进恢复机制
            if (msix_error_detected) begin
                // 使用独立计数器控制错误恢复时机
                if (error_recovery_counter >= 8'h20) begin // 增加恢复延迟
                    msix_error_detected <= 1'b0;
                    msix_error_counter <= 8'h00;
                    msix_interrupt_error <= 1'b0;
                    error_recovery_counter <= 8'h00;
                    
                    // 清除所有错误向量
                    msix_error_vectors <= 16'h0000;
                    msix_error_cnt <= 4'h0;
                    msix_error_overflow <= 1'b0;
                end
            end else begin
                // 无错误时重置恢复计数器
                error_recovery_counter <= 8'h00;
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
        vendor_cap_regs[1] = 32'h9A0B8086;  // Intel RST VMD Controller Device ID (9A0B) and Vendor ID (8086)
        vendor_cap_regs[2] = 32'h00060400;  // Class Code (060400 - PCI Bridge)
        vendor_cap_regs[3] = 32'h00010001;  // VMD特定配置 - 修正为Intel RST VMD控制器规范
        vendor_cap_regs[4] = 32'h9A0B8086;  // 重复设备ID和厂商ID - 增强兼容性
        
        // 初始化MSI-X表和PBA
        for (int i = 0; i < 64; i++) begin
            msix_table[i] = 32'h00000000;
        end
        msix_pba = 32'h00000000;
        
        // 初始化VMD控制器寄存器
        for (int i = 0; i < 64; i++) begin
            vmd_regs[i] = 32'h00000000;
        end
        
        // 设置VMD控制器标识寄存器
        vmd_regs[0] = 32'h9A0B8086;  // Controller ID (CAP) - Intel RST VMD (9A0B)
        vmd_regs[1] = 32'h00010001;  // Version (VS)
        vmd_regs[2] = 32'h00000000;  // Interrupt Mask Set (INTMS)
        vmd_regs[3] = 32'h00000000;  // Interrupt Mask Clear (INTMC)
        vmd_regs[4] = 32'h00000000;  // Controller Configuration (CC)
        vmd_regs[5] = 32'h00000001;  // Controller Status (CSTS) - Ready
        vmd_regs[6] = 32'h00000000;  // VMD Subsystem Reset (NSSR)
        vmd_regs[7] = 32'h00000000;  // Admin Queue Attributes (AQA)
        vmd_regs[8] = 32'h00000000;  // Admin Submission Queue Base Address (ASQ)
        vmd_regs[9] = 32'h00000000;  // Admin Completion Queue Base Address (ACQ)
        
        // 设置控制器就绪状态
        vmd_controller_ready = 1'b1;
        nvme_controller_ready = vmd_controller_ready;  // 确保NVMe控制器状态与VMD控制器状态一致
        
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
                        3: begin  // NVMe特定配置
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
            // NVMe控制器寄存器写入
            else if ((wr_addr & 32'hFFFFF000) == NVME_REG_OFFSET) begin
                int index = (wr_addr[9:2]);
                if (index < 64) begin
                    case (index)
                        4: begin  // Controller Configuration (CC)
                            if (wr_be[0]) `nvme_regs[index][7:0] <= wr_data[7:0];
                            if (wr_be[1]) `nvme_regs[index][15:8] <= wr_data[15:8];
                            if (wr_be[2]) `nvme_regs[index][23:16] <= wr_data[23:16];
                            if (wr_be[3]) `nvme_regs[index][31:24] <= wr_data[31:24];
                            
                            // 检查控制器使能位
                            if (wr_data[0]) begin
                                nvme_controller_ready <= 1'b1;
                                vmd_controller_ready <= nvme_controller_ready;
                                `nvme_regs[5] <= 32'h00000001;  // 设置CSTS.RDY位
                            end else begin
                                nvme_controller_ready <= 1'b0;
                                vmd_controller_ready <= nvme_controller_ready;
                                `nvme_regs[5] <= 32'h00000000;  // 清除CSTS.RDY位
                            end
                        end
                        7: begin  // Admin Queue Attributes (AQA)
                            if (wr_be[0]) `nvme_regs[index][7:0] <= wr_data[7:0];
                            if (wr_be[1]) `nvme_regs[index][15:8] <= wr_data[15:8];
                            if (wr_be[2]) `nvme_regs[index][23:16] <= wr_data[23:16];
                            if (wr_be[3]) `nvme_regs[index][31:24] <= wr_data[31:24];
                            
                            // 更新队列大小
                            nvme_admin_sq_size <= wr_data[7:0] + 1;
                            nvme_admin_cq_size <= wr_data[23:16] + 1;
                        end
                        8: begin  // Admin Submission Queue Base Address (ASQ)
                            if (wr_be[0]) `nvme_regs[index][7:0] <= wr_data[7:0];
                            if (wr_be[1]) `nvme_regs[index][15:8] <= wr_data[15:8];
                            if (wr_be[2]) `nvme_regs[index][23:16] <= wr_data[23:16];
                            if (wr_be[3]) `nvme_regs[index][31:24] <= wr_data[31:24];
                            
                            // 更新管理提交队列基地址
                            nvme_admin_sq_base <= wr_data;
                        end
                        9: begin  // Admin Completion Queue Base Address (ACQ)
                            if (wr_be[0]) `nvme_regs[index][7:0] <= wr_data[7:0];
                            if (wr_be[1]) `nvme_regs[index][15:8] <= wr_data[15:8];
                            if (wr_be[2]) `nvme_regs[index][23:16] <= wr_data[23:16];
                            if (wr_be[3]) `nvme_regs[index][31:24] <= wr_data[31:24];
                            
                            // 更新管理完成队列基地址
                            nvme_admin_cq_base <= wr_data;
                        end
                        default: begin
                            // 其他寄存器处理
                            if (wr_be[0]) `nvme_regs[index][7:0] <= wr_data[7:0];
                            if (wr_be[1]) `nvme_regs[index][15:8] <= wr_data[15:8];
                            if (wr_be[2]) `nvme_regs[index][23:16] <= wr_data[23:16];
                            if (wr_be[3]) `nvme_regs[index][31:24] <= wr_data[31:24];
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
            // NVMe控制器寄存器读取
            else if ((rd_req_addr_1 & 32'hFFFFF000) == NVME_REG_OFFSET) begin
                int index = (rd_req_addr_1[9:2]);
                if (index < 64) begin
                    rd_rsp_data <= `nvme_regs[index];
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
    
    // 触发MSI-X中断的任务 (可以在其他模块中调用) - 增强优化版
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
                            // 检查是否有其他中断正在处理
                            if (!msix_interrupt_valid) begin
                                // 从MSI-X表中获取中断地址和数据
                                addr[31:0] = msix_table[vector_num*4];
                                addr[63:32] = msix_table[vector_num*4+1];
                                data = msix_table[vector_num*4+2];
                                
                                // 验证地址有效性 - 增强验证
                                if ((addr != 64'h0) && (addr[1:0] == 2'b00)) begin // 确保地址4字节对齐
                                    // 发送中断消息到PCIe接口
                                    msix_interrupt_valid <= 1'b1;
                                    msix_interrupt_addr <= addr;
                                    msix_interrupt_data <= data;
                                    msix_interrupt_error <= 1'b0; // 清除错误标志
                                    
                                    // 重置中断有效信号计数器，确保新中断有足够的持续时间
                                    interrupt_valid_counter <= 3'b000;
                                    
                                    // 状态清理将由时钟同步逻辑处理
                                end else begin
                                    // 地址无效，记录错误
                                    msix_error_vectors[vector_num] <= 1'b1;
                                    msix_error_cnt <= (msix_error_cnt == 4'hf) ? msix_error_cnt : (msix_error_cnt + 1);
                                    // 清除活动状态，防止卡在错误状态
                                    msix_active_vectors[vector_num] <= 1'b0;
                                    msix_pba[vector_num] <= 1'b0;
                                end
                            end
                            // 如果有其他中断正在处理，保持pending状态，等待下一次机会
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
    
    // 声明向量超时计数器
    reg [7:0] vector_timeout[15:0];
    
    // 初始化向量超时计数器
    initial begin
        for (int i = 0; i < 16; i++) begin
            vector_timeout[i] = 8'h0;
        end
    end
    
    // 重置中断错误状态和管理中断状态清理 - 增强优化版
    always @(posedge clk) begin
        if (rst) begin
            // 重置所有错误状态
            msix_error_vectors <= 16'h0000;
            msix_error_cnt <= 4'h0;
            msix_error_overflow <= 1'b0;
            msix_active_vectors <= 16'h0000;
            msix_pba <= 32'h00000000;
            // 重置所有向量超时计数器
            for (int i = 0; i < 16; i++) begin
                vector_timeout[i] <= 8'h0;
            end
        end else begin
            // 中断完成后清理状态 - 增强版
            if (msix_interrupt_valid) begin
                // 找出当前活动的中断向量并清除其状态
                for (int i = 0; i < 16; i++) begin
                    if (msix_active_vectors[i]) begin
                        // 检查这个向量是否对应当前正在发送的中断
                        if ((msix_interrupt_addr[31:0] == msix_table[i*4]) && 
                            (msix_interrupt_addr[63:32] == msix_table[i*4+1]) && 
                            (msix_interrupt_data == msix_table[i*4+2])) begin
                            // 清除pending bit和活动向量
                            msix_pba[i] <= 1'b0;
                            msix_active_vectors[i] <= 1'b0;
                            vector_timeout[i] <= 8'h0; // 重置超时计数器
                        end
                    end
                end
            end
            
            // 中断完成后的额外清理 - 当中断有效信号被清除时
            if (!msix_interrupt_valid && interrupt_valid_counter == 3'b000) begin
                // 检查是否有任何向量与最后发送的中断匹配
                for (int i = 0; i < 16; i++) begin
                    if (msix_active_vectors[i]) begin
                        // 如果中断已经发送完成，但向量仍然处于活动状态，可能是状态未正确清除
                        // 增加超时计数
                        vector_timeout[i] <= vector_timeout[i] + 1;
                        
                        // 如果超时时间较短，尝试再次清除状态
                        if (vector_timeout[i] > 8'h08) begin
                            msix_active_vectors[i] <= 1'b0;
                            msix_pba[i] <= 1'b0;
                            vector_timeout[i] <= 8'h0;
                        end
                    end
                end
            end
            
            // 定期检查并清理长时间未处理的中断向量 - 增强版
            for (int i = 0; i < 16; i++) begin
                if (msix_active_vectors[i] && msix_pba[i] && !msix_interrupt_valid) begin
                    // 增加超时计数
                    vector_timeout[i] <= vector_timeout[i] + 1;
                    
                    // 如果超时，清除向量状态 - 增加超时阈值
                    if (vector_timeout[i] > 8'h30) begin // 增加超时阈值
                        msix_active_vectors[i] <= 1'b0;
                        msix_pba[i] <= 1'b0;
                        vector_timeout[i] <= 8'h0;
                        // 记录错误
                        msix_error_vectors[i] <= 1'b1;
                        msix_error_cnt <= (msix_error_cnt == 4'hf) ? msix_error_cnt : (msix_error_cnt + 1);
                        msix_error_overflow <= 1'b1;
                    end
                end else if (msix_active_vectors[i] || msix_pba[i]) begin
                    // 如果向量状态不一致，增加超时计数
                    vector_timeout[i] <= vector_timeout[i] + 1;
                    
                    // 如果超时，强制同步状态 - 增加超时阈值
                    if (vector_timeout[i] > 8'h18) begin // 增加超时阈值
                        msix_active_vectors[i] <= 1'b0;
                        msix_pba[i] <= 1'b0;
                        vector_timeout[i] <= 8'h0;
                    end
                end else begin
                    // 重置超时计数器
                    vector_timeout[i] <= 8'h0;
                end
            end
        end
    end
    
    // NVMe命令处理逻辑
    // NVMe命令结构定义
    typedef struct packed {
        logic [63:0] prp1;           // 物理区域页1
        logic [63:0] prp2;           // 物理区域页2
        logic [31:0] command_dword10; // 命令特定参数
        logic [31:0] command_dword11; // 命令特定参数
        logic [31:0] command_dword12; // 命令特定参数
        logic [31:0] command_dword13; // 命令特定参数
        logic [31:0] command_dword14; // 命令特定参数
        logic [31:0] command_dword15; // 命令特定参数
        logic [15:0] command_id;     // 命令ID
        logic [7:0]  opcode;         // 操作码
        logic [7:0]  flags;          // 命令标志
    } nvme_command_t;
    
    // NVMe完成项结构定义
    typedef struct packed {
        logic [31:0] dword0;         // 命令特定结果
        logic [31:0] dword1;         // 保留
        logic [15:0] sq_head;        // 提交队列头指针
        logic [15:0] sq_id;          // 提交队列ID
        logic [15:0] command_id;     // 命令ID
        logic [15:0] status;         // 完成状态
    } nvme_completion_t;
    
    // NVMe命令处理状态
    reg [7:0] nvme_cmd_processing_state;
    reg [15:0] nvme_admin_sq_head;
    reg [15:0] nvme_admin_sq_tail;
    reg [15:0] nvme_admin_cq_head;
    reg [15:0] nvme_admin_cq_tail;
    
    // NVMe命令处理初始化
    initial begin
        nvme_cmd_processing_state = 8'h00;
        nvme_admin_sq_head = 16'h0000;
        nvme_admin_sq_tail = 16'h0000;
        nvme_admin_cq_head = 16'h0000;
        nvme_admin_cq_tail = 16'h0000;
    end
    
    // NVMe命令处理任务
    task process_nvme_command;
        input [7:0] opcode;
        input [15:0] command_id;
        begin
            // 根据操作码处理不同的命令
            case (opcode)
                8'h01: begin // 获取日志页
                    // 创建完成项
                    nvme_completion_t completion;
                    completion.dword0 = 32'h00000000;
                    completion.dword1 = 32'h00000000;
                    completion.sq_head = nvme_admin_sq_head;
                    completion.sq_id = 16'h0000; // 管理队列ID为0
                    completion.command_id = command_id;
                    completion.status = 16'h0000; // 成功完成
                    
                    // 更新队列指针
                    nvme_admin_sq_head = (nvme_admin_sq_head + 1) % nvme_admin_sq_size;
                    nvme_admin_cq_tail = (nvme_admin_cq_tail + 1) % nvme_admin_cq_size;
                    
                    // 触发中断
                    trigger_msix_interrupt(0); // 使用向量0表示管理队列完成
                end
                
                8'h02: begin // 获取特性
                    // 创建完成项
                    nvme_completion_t completion;
                    completion.dword0 = 32'h00000001; // 返回一些特性值
                    completion.dword1 = 32'h00000000;
                    completion.sq_head = nvme_admin_sq_head;
                    completion.sq_id = 16'h0000; // 管理队列ID为0
                    completion.command_id = command_id;
                    completion.status = 16'h0000; // 成功完成
                    
                    // 更新队列指针
                    nvme_admin_sq_head = (nvme_admin_sq_head + 1) % nvme_admin_sq_size;
                    nvme_admin_cq_tail = (nvme_admin_cq_tail + 1) % nvme_admin_cq_size;
                    
                    // 触发中断
                    trigger_msix_interrupt(0); // 使用向量0表示管理队列完成
                end
                
                8'h06: begin // 识别
                    // 创建完成项
                    nvme_completion_t completion;
                    completion.dword0 = 32'h00000000;
                    completion.dword1 = 32'h00000000;
                    completion.sq_head = nvme_admin_sq_head;
                    completion.sq_id = 16'h0000; // 管理队列ID为0
                    completion.command_id = command_id;
                    completion.status = 16'h0000; // 成功完成
                    
                    // 更新队列指针
                    nvme_admin_sq_head = (nvme_admin_sq_head + 1) % nvme_admin_sq_size;
                    nvme_admin_cq_tail = (nvme_admin_cq_tail + 1) % nvme_admin_cq_size;
                    
                    // 触发中断
                    trigger_msix_interrupt(0); // 使用向量0表示管理队列完成
                end
                
                default: begin // 未知命令
                    // 创建完成项，表示不支持的命令
                    nvme_completion_t completion;
                    completion.dword0 = 32'h00000000;
                    completion.dword1 = 32'h00000000;
                    completion.sq_head = nvme_admin_sq_head;
                    completion.sq_id = 16'h0000; // 管理队列ID为0
                    completion.command_id = command_id;
                    completion.status = 16'h0001; // 命令不支持
                    
                    // 更新队列指针
                    nvme_admin_sq_head = (nvme_admin_sq_head + 1) % nvme_admin_sq_size;
                    nvme_admin_cq_tail = (nvme_admin_cq_tail + 1) % nvme_admin_cq_size;
                    
                    // 触发中断
                    trigger_msix_interrupt(0); // 使用向量0表示管理队列完成
                end
            endcase
        end
    endtask
    
    // 测试中断触发 - 当写入特定地址时触发中断
    // 写入地址0x3000 + vector_num*4 将触发对应向量的中断
    localparam MSIX_TRIGGER_OFFSET = 32'h00003000;  // 中断触发地址偏移
    localparam NVME_DOORBELL_OFFSET = 32'h00005000; // NVMe门铃寄存器偏移
    
    always @(posedge clk) begin
        if (wr_valid && (wr_addr & 32'hFFFFF000) == MSIX_TRIGGER_OFFSET) begin
            // 提取向量号 (0-15)
            int vector_num = (wr_addr[7:2]) & 4'hF;
            
            // 触发对应向量的中断
            trigger_msix_interrupt(vector_num);
        end
        else if (wr_valid && (wr_addr & 32'hFFFFF000) == NVME_DOORBELL_OFFSET) begin
            // NVMe门铃寄存器写入
            int doorbell_index = (wr_addr[7:3]);
            if (doorbell_index == 0) begin
                // 管理提交队列门铃
                nvme_admin_sq_tail = wr_data[15:0];
                
                // 检查是否有新命令需要处理
                if (nvme_admin_sq_head != nvme_admin_sq_tail && nvme_controller_ready) begin
                    // 模拟处理命令 - 在实际实现中，这里应该读取命令并处理
                    // 简化起见，我们假设命令是获取特性命令
                    process_nvme_command(8'h02, 16'h0001);
                end
            end
            else if (doorbell_index == 1) begin
                // 管理完成队列门铃
                nvme_admin_cq_head = wr_data[15:0];
            end
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
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
    
    // VMD特定寄存器 - 增强VMD功能
    reg [31:0] vmd_capabilities;     // VMD能力寄存器
    reg [31:0] vmd_control;          // VMD控制寄存器
    reg [31:0] vmd_status;           // VMD状态寄存器
    reg [31:0] vmd_endpoint_count;   // VMD端点计数寄存器
    reg [31:0] vmd_port_mapping[4:0]; // VMD端口映射寄存器
    reg [31:0] vmd_error_status;     // VMD错误状态寄存器
    reg [31:0] vmd_error_mask;       // VMD错误掩码寄存器
    
    // NVMe寄存器 - 与VMD寄存器共用
    `define nvme_regs vmd_regs
    reg        nvme_controller_ready; // NVMe控制器就绪状态 - 与VMD控制器就绪状态共用
    
    // MSI-X控制寄存器
    reg [31:0] msix_control;      // MSI-X控制寄存器
    reg msix_enabled;             // MSI-X使能标志
    reg msix_masked;              // MSI-X全局屏蔽标志
    reg msix_error_detected;      // MSI-X错误检测标志
    reg [7:0] msix_error_counter; // MSI-X错误计数器
    
    // RW1C寄存器控制信号 - PCIe状态寄存器
    reg         pcie_status_wr_en;     // 状态寄存器写使能
    reg [15:0]  pcie_status_wr_data;   // 状态寄存器写数据
    reg [15:0]  pcie_status_wr_mask;   // 状态寄存器写掩码
    wire [15:0] pcie_status;           // 状态寄存器当前值
    reg         pcie_force_rw1c_as_rw; // 强制RW1C作为RW
    
    // 硬件事件信号
    reg         hw_status_set_en;      // 硬件设置使能
    reg [15:0]  hw_status_set_data;    // 硬件设置数据
    reg [15:0]  hw_status_set_mask;    // 硬件设置掩码
    
    // 状态寄存器监控
    wire [7:0]  status_access_count;   // 状态寄存器访问计数
    wire        status_alert;          // 状态寄存器警告标志
    
    // 使用RW1C寄存器模块处理PCIe设备状态寄存器
    // 默认值: 0x0010 (Capabilities List位设置为1)
    pcileech_rw1c_register #(
        .WIDTH(16),
        .DEFAULT_VALUE(16'h0010)
    ) pcie_status_reg (
        .clk(clk),
        .rst(rst),
        
        // 写入控制
        .wr_en(pcie_status_wr_en),
        .wr_data(pcie_status_wr_data),
        .wr_mask(pcie_status_wr_mask),
        
        // 特殊控制
        .force_rw_mode(pcie_force_rw1c_as_rw),
        
        // 硬件事件设置
        .hw_set_en(hw_status_set_en),
        .hw_set_data(hw_status_set_data),
        .hw_set_mask(hw_status_set_mask),
        
        // 读取接口
        .rd_data(pcie_status),
        
        // 状态和诊断输出
        .reg_value(),
        .access_count(status_access_count),
        .is_zero()
    );
    
    // MSI-X错误检测和恢复逻辑 - 增强版
    reg [2:0] interrupt_valid_counter; // 中断有效信号持续时间计数器
    reg [7:0] error_recovery_counter;  // 错误恢复计数器
    reg [15:0] msix_active_vectors;    // 活动中断向量状态
    reg [15:0] msix_error_vectors;     // 错误中断向量状态
    reg [3:0]  msix_error_cnt;         // 错误计数器
    reg        msix_error_overflow;     // 错误溢出标志
    
    // MSI-X中断触发逻辑 - 主要用于VMD控制器状态变化时触发中断
    reg [7:0] msix_trigger_counter;  // 中断触发计数器
    reg [3:0] msix_vector_index;     // 中断向量索引
    reg       msix_pending_trigger;  // 挂起的中断触发请求
    reg [1:0] msix_trigger_state;    // 触发状态机状态
    
    // 状态机状态定义
    localparam MSIX_IDLE = 2'b00;       // 空闲状态
    localparam MSIX_PREPARE = 2'b01;    // 准备触发状态
    localparam MSIX_TRIGGER = 2'b10;    // 触发中断状态
    localparam MSIX_WAIT = 2'b11;       // 等待完成状态
    
    // 初始化计数器和状态寄存器
    initial begin
        interrupt_valid_counter = 3'b000;
        error_recovery_counter = 8'h00;
        msix_active_vectors = 16'h0000;
        msix_error_vectors = 16'h0000;
        msix_error_cnt = 4'h0;
        msix_error_overflow = 1'b0;
        
        // 初始化RW1C控制信号
        pcie_status_wr_en = 0;
        pcie_status_wr_data = 0;
        pcie_status_wr_mask = 0;
        pcie_force_rw1c_as_rw = 0;
        hw_status_set_en = 0;
        hw_status_set_data = 0;
        hw_status_set_mask = 0;
        
        // 初始化MSI-X错误检测相关寄存器 - 全面增强版
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
        
        // 初始化VMD控制器寄存器
        vmd_capabilities = 32'h00010001;    // 支持1个端点，版本1
        vmd_control = 32'h00000000;         // 默认关闭
        vmd_status = 32'h00000001;          // 就绪状态
        vmd_endpoint_count = 32'h00000001;  // 1个端点
        for(int i=0; i<5; i++) begin
            vmd_port_mapping[i] = 32'h00000000; // 清空端口映射
        end
        vmd_error_status = 32'h00000000;    // 无错误
        vmd_error_mask = 32'h00000000;      // 无掩码
        
        // NVMe相关寄存器初始化
        `nvme_regs[0] = 32'h00010001;       // 控制器能力寄存器低32位
        `nvme_regs[1] = 32'h00000000;       // 控制器能力寄存器高32位
        `nvme_regs[2] = 32'h00000000;       // 版本寄存器
        `nvme_regs[3] = 32'h00000001;       // 中断掩码设置寄存器
        
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
        
        msix_trigger_counter = 8'h00;
        msix_vector_index = 4'h0;
        msix_pending_trigger = 1'b0;
        msix_trigger_state = MSIX_IDLE;
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
                    // 修复：确保正确处理MSI-X功能位
                    // msix_control[15:8]中的bits[1:0]分别为MSI-X Enable和Function Mask
                    // 这里我们只允许修改这两个位，并且确保正确地更新msix_enabled和msix_masked
                    msix_control[15:8] <= (msix_control[15:8] & 8'h3F) | (wr_data[15:8] & 8'hC0);
                    msix_enabled <= wr_data[15];     // Bit15是MSI-X Enable位
                    msix_masked <= wr_data[14];      // Bit14是Function Mask位
                end
                if (wr_be[2]) msix_control[23:16] <= (msix_control[23:16] & 8'hF0) | (wr_data[23:16] & 8'h0F);
                if (wr_be[3]) msix_control[31:24] <= (msix_control[31:24] & 8'h00) | (wr_data[31:24] & 8'h00);
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
                        2: begin  // Device Control and Status
                            // 只处理Control部分，Status由RW1C寄存器处理
                            if (wr_be[0]) pcie_cap_regs[index][7:0] <= wr_data[7:0] & 8'hFF;
                            if (wr_be[1]) pcie_cap_regs[index][15:8] <= wr_data[15:8] & 8'hFF;
                            
                            // 对状态寄存器部分 (高16位) 使用RW1C寄存器
                            if (wr_be[2] || wr_be[3]) begin
                                pcie_status_wr_en <= 1'b1;
                                pcie_status_wr_data <= wr_data[31:16];
                                pcie_status_wr_mask <= {wr_be[3] ? 8'hFF : 8'h00, wr_be[2] ? 8'hFF : 8'h00};
                                
                                // 传递RW1C特殊标志
                                pcie_force_rw1c_as_rw <= 0;  // 使用标准RW1C行为
                            end else begin
                                pcie_status_wr_en <= 1'b0;
                            end
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
            // VMD控制器寄存器写入
            else if ((wr_addr & 32'hFFFFF000) == VMD_REG_OFFSET) begin
                int index = (wr_addr - VMD_REG_OFFSET) >> 2;
                if (index >= 0 && index < 64) begin
                    case (index)
                        0, 1: begin
                            // 控制器ID和版本寄存器为只读
                        end
                        2: begin // INTMS - 中断屏蔽集合寄存器
                            if (wr_be[0]) vmd_regs[index][7:0] <= vmd_regs[index][7:0] | (wr_data[7:0] & 8'hFF);
                            if (wr_be[1]) vmd_regs[index][15:8] <= vmd_regs[index][15:8] | (wr_data[15:8] & 8'hFF);
                            if (wr_be[2]) vmd_regs[index][23:16] <= vmd_regs[index][23:16] | (wr_data[23:16] & 8'hFF);
                            if (wr_be[3]) vmd_regs[index][31:24] <= vmd_regs[index][31:24] | (wr_data[31:24] & 8'hFF);
                        end
                        3: begin // INTMC - 中断屏蔽清除寄存器
                            if (wr_be[0]) vmd_regs[2][7:0] <= vmd_regs[2][7:0] & ~(wr_data[7:0] & 8'hFF);
                            if (wr_be[1]) vmd_regs[2][15:8] <= vmd_regs[2][15:8] & ~(wr_data[15:8] & 8'hFF);
                            if (wr_be[2]) vmd_regs[2][23:16] <= vmd_regs[2][23:16] & ~(wr_data[23:16] & 8'hFF);
                            if (wr_be[3]) vmd_regs[2][31:24] <= vmd_regs[2][31:24] & ~(wr_data[31:24] & 8'hFF);
                        end
                        4: begin // CC - 控制器配置寄存器
                            if (wr_be[0]) vmd_regs[index][7:0] <= wr_data[7:0] & 8'hFF;
                            if (wr_be[1]) vmd_regs[index][15:8] <= wr_data[15:8] & 8'hFF;
                            if (wr_be[2]) vmd_regs[index][23:16] <= wr_data[23:16] & 8'hFF;
                            if (wr_be[3]) vmd_regs[index][31:24] <= wr_data[31:24] & 8'hFF;
                            
                            // 更新VMD控制寄存器
                            vmd_control <= (vmd_regs[index] & 32'hFFFFFF) | (vmd_control & 32'hFF000000);
                            
                            // 当控制器复位位被设置时
                            if (wr_data[0]) begin
                                // 执行软复位逻辑
                                vmd_regs[5] <= vmd_regs[5] & 32'hFFFFFFFE; // 清除就绪位
                                vmd_controller_ready <= 0;
                                vmd_regs[5] <= vmd_regs[5] | 32'h00000001; // 置位就绪位
                                vmd_controller_ready <= 1;
                            end
                        end
                        5: begin // CSTS - 控制器状态寄存器 (主要为只读)
                            // 只允许修改特定位
                            if (wr_be[0]) vmd_regs[index][7:0] <= (vmd_regs[index][7:0] & 8'hFE) | (wr_data[7:0] & 8'h01);
                        end
                        6: begin // NSSR - 重置寄存器 (写入时触发复位)
                            if ((wr_be[0] && wr_data[0]) || (wr_be[1] && wr_data[8]) || 
                                (wr_be[2] && wr_data[16]) || (wr_be[3] && wr_data[24])) begin
                                // 执行VMD控制器重置
                                for (int i = 2; i < 64; i++) begin
                                    vmd_regs[i] <= 32'h00000000;
                                end
                                vmd_regs[5] <= 32'h00000001; // 重新设置就绪状态
                                vmd_controller_ready <= 1;
                            end
                        end
                        7: begin // AQA - 管理队列属性
                            if (wr_be[0]) vmd_regs[index][7:0] <= wr_data[7:0] & 8'hFF;
                            if (wr_be[1]) vmd_regs[index][15:8] <= wr_data[15:8] & 8'hFF;
                            if (wr_be[2]) vmd_regs[index][23:16] <= wr_data[23:16] & 8'hFF;
                            if (wr_be[3]) vmd_regs[index][31:24] <= wr_data[31:24] & 8'hFF;
                            
                            // 更新队列大小
                            vmd_admin_sq_size <= vmd_regs[index][11:0];  // 12位队列大小
                            vmd_admin_cq_size <= vmd_regs[index][27:16]; // 12位队列大小
                        end
                        8: begin // ASQ - 管理提交队列基地址
                            if (wr_be[0]) vmd_regs[index][7:0] <= wr_data[7:0] & 8'hF0; // 必须4KB对齐
                            if (wr_be[1]) vmd_regs[index][15:8] <= wr_data[15:8] & 8'hFF;
                            if (wr_be[2]) vmd_regs[index][23:16] <= wr_data[23:16] & 8'hFF;
                            if (wr_be[3]) vmd_regs[index][31:24] <= wr_data[31:24] & 8'hFF;
                            
                            // 更新基地址
                            vmd_admin_sq_base <= {vmd_regs[index][31:4], 4'b0000}; // 4KB对齐
                        end
                        9: begin // ACQ - 管理完成队列基地址
                            if (wr_be[0]) vmd_regs[index][7:0] <= wr_data[7:0] & 8'hF0; // 必须4KB对齐
                            if (wr_be[1]) vmd_regs[index][15:8] <= wr_data[15:8] & 8'hFF;
                            if (wr_be[2]) vmd_regs[index][23:16] <= wr_data[23:16] & 8'hFF;
                            if (wr_be[3]) vmd_regs[index][31:24] <= wr_data[31:24] & 8'hFF;
                            
                            // 更新基地址
                            vmd_admin_cq_base <= {vmd_regs[index][31:4], 4'b0000}; // 4KB对齐
                        end
                        10: begin // VMD能力寄存器
                            // 只读
                        end
                        11: begin // VMD控制寄存器
                            if (wr_be[0]) vmd_capabilities[7:0] <= wr_data[7:0] & 8'hFF;
                            if (wr_be[1]) vmd_capabilities[15:8] <= wr_data[15:8] & 8'hFF;
                            if (wr_be[2]) vmd_capabilities[23:16] <= wr_data[23:16] & 8'hFF;
                            if (wr_be[3]) vmd_capabilities[31:24] <= wr_data[31:24] & 8'hFF;
                        end
                        12: begin // VMD状态寄存器 - 部分为RW1C
                            if (wr_be[0]) vmd_status[7:0] <= vmd_status[7:0] & ~(wr_data[7:0] & 8'h0F);  // 低4位为RW1C
                            if (wr_be[1]) vmd_status[15:8] <= (vmd_status[15:8] & 8'hF0) | (wr_data[15:8] & 8'h0F);
                            if (wr_be[2]) vmd_status[23:16] <= (vmd_status[23:16] & 8'hF0) | (wr_data[23:16] & 8'h0F);
                            if (wr_be[3]) vmd_status[31:24] <= (vmd_status[31:24] & 8'hF0) | (wr_data[31:24] & 8'h0F);
                        end
                        13: begin // VMD端点计数寄存器
                            // 只读
                        end
                        14, 15, 16, 17, 18: begin // VMD端口映射寄存器
                            int map_index = index - 14;
                            if (map_index >= 0 && map_index < 5) begin
                                if (wr_be[0]) vmd_port_mapping[map_index][7:0] <= wr_data[7:0] & 8'hFF;
                                if (wr_be[1]) vmd_port_mapping[map_index][15:8] <= wr_data[15:8] & 8'hFF;
                                if (wr_be[2]) vmd_port_mapping[map_index][23:16] <= wr_data[23:16] & 8'hFF;
                                if (wr_be[3]) vmd_port_mapping[map_index][31:24] <= wr_data[31:24] & 8'hFF;
                            end
                        end
                        19: begin // VMD错误状态寄存器 - RW1C
                            if (wr_be[0]) vmd_error_status[7:0] <= vmd_error_status[7:0] & ~(wr_data[7:0] & 8'hFF);
                            if (wr_be[1]) vmd_error_status[15:8] <= vmd_error_status[15:8] & ~(wr_data[15:8] & 8'hFF);
                            if (wr_be[2]) vmd_error_status[23:16] <= vmd_error_status[23:16] & ~(wr_data[23:16] & 8'hFF);
                            if (wr_be[3]) vmd_error_status[31:24] <= vmd_error_status[31:24] & ~(wr_data[31:24] & 8'hFF);
                        end
                        20: begin // VMD错误掩码寄存器
                            if (wr_be[0]) vmd_error_mask[7:0] <= wr_data[7:0] & 8'hFF;
                            if (wr_be[1]) vmd_error_mask[15:8] <= wr_data[15:8] & 8'hFF;
                            if (wr_be[2]) vmd_error_mask[23:16] <= wr_data[23:16] & 8'hFF;
                            if (wr_be[3]) vmd_error_mask[31:24] <= wr_data[31:24] & 8'hFF;
                        end
                        default: begin
                            // 其它寄存器
                            if (wr_be[0]) vmd_regs[index][7:0] <= wr_data[7:0] & 8'hFF;
                            if (wr_be[1]) vmd_regs[index][15:8] <= wr_data[15:8] & 8'hFF;
                            if (wr_be[2]) vmd_regs[index][23:16] <= wr_data[23:16] & 8'hFF;
                            if (wr_be[3]) vmd_regs[index][31:24] <= wr_data[31:24] & 8'hFF;
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
            // 默认返回全0
            rd_rsp_data <= 32'h00000000;
            
            // MSI-X控制寄存器读取 (位于偏移0x110)
            if ((rd_req_addr_1 & 32'hFFFFFF00) == 32'h00000110) begin
                rd_rsp_data <= msix_control;
            end
            // MSI-X表读取
            else if ((rd_req_addr_1 & 32'hFFFFF000) == MSIX_TABLE_OFFSET) begin
                int index = (rd_req_addr_1[11:2]);
                if (index < 64) begin  // 16个表项 * 4 DWORD = 64
                    rd_rsp_data <= msix_table[index];
                end
            end
            // MSI-X PBA读取
            else if ((rd_req_addr_1 & 32'hFFFFF000) == MSIX_PBA_OFFSET) begin
                int index = (rd_req_addr_1[11:2]);
                if (index == 0) begin
                    rd_rsp_data <= msix_pba;
                end
            end
            // PCIe能力结构读取
            else if ((rd_req_addr_1 & 32'hFFFFFF00) == 32'h00000000) begin
                int index = rd_req_addr_1[7:2];
                if (index < 17) begin
                    // 对于设备状态寄存器，使用RW1C寄存器的当前值
                    if (index == 2) begin
                        rd_rsp_data <= {pcie_status, pcie_cap_regs[index][15:0]};
                    end else begin
                        rd_rsp_data <= pcie_cap_regs[index];
                    end
                end
            end
            // 电源管理能力读取
            else if ((rd_req_addr_1 & 32'hFFFFFF00) == 32'h00000100) begin
                int index = rd_req_addr_1[7:2];
                if (index < 3) begin
                    rd_rsp_data <= pm_cap_regs[index];
                end
            end
            // 厂商特定能力读取
            else if ((rd_req_addr_1 & 32'hFFFFFF00) == 32'h00000120) begin
                int index = rd_req_addr_1[7:2];
                if (index < 5) begin
                    rd_rsp_data <= vendor_cap_regs[index];
                end
            end
            // VMD控制器寄存器读取
            else if ((rd_req_addr_1 & 32'hFFFFF000) == VMD_REG_OFFSET) begin
                int index = (rd_req_addr_1 - VMD_REG_OFFSET) >> 2;
                if (index >= 0 && index < 64) begin
                    case (index)
                        0, 1: begin
                            // 控制器ID和版本寄存器 (只读)
                            rd_rsp_data <= vmd_regs[index];
                        end
                        2, 3: begin
                            // 中断相关寄存器
                            rd_rsp_data <= vmd_regs[2]; // 两个寄存器读取同一个值
                        end
                        4: begin
                            // 控制器配置寄存器
                            rd_rsp_data <= vmd_regs[index];
                        end
                        5: begin
                            // 控制器状态寄存器
                            rd_rsp_data <= vmd_regs[index];
                            
                            // 如果有必要，更新状态 - 指示就绪状态
                            if (vmd_controller_ready && (vmd_regs[index] & 32'h00000001) == 0) begin
                                vmd_regs[index] <= vmd_regs[index] | 32'h00000001;
                            end
                        end
                        6: begin
                            // 重置寄存器 - 总是返回0
                            rd_rsp_data <= 32'h00000000;
                        end
                        7, 8, 9: begin
                            // 队列相关寄存器
                            rd_rsp_data <= vmd_regs[index];
                        end
                        10: begin
                            // VMD能力寄存器
                            rd_rsp_data <= vmd_capabilities;
                        end
                        11: begin
                            // VMD控制寄存器
                            rd_rsp_data <= vmd_control;
                        end
                        12: begin
                            // VMD状态寄存器
                            rd_rsp_data <= vmd_status;
                        end
                        13: begin
                            // VMD端点计数寄存器
                            rd_rsp_data <= vmd_endpoint_count;
                        end
                        14, 15, 16, 17, 18: begin
                            // VMD端口映射寄存器
                            int map_index = index - 14;
                            if (map_index >= 0 && map_index < 5) begin
                                rd_rsp_data <= vmd_port_mapping[map_index];
                            end
                        end
                        19: begin
                            // VMD错误状态寄存器
                            rd_rsp_data <= vmd_error_status;
                        end
                        20: begin
                            // VMD错误掩码寄存器
                            rd_rsp_data <= vmd_error_mask;
                        end
                        default: begin
                            // 其它寄存器
                            rd_rsp_data <= vmd_regs[index];
                        end
                    endcase
                end
            end
            // NVMe控制器寄存器读取 (与VMD共用同一空间)
            else if ((rd_req_addr_1 & 32'hFFFFF000) == NVME_REG_OFFSET) begin
                int index = (rd_req_addr_1 - NVME_REG_OFFSET) >> 2;
                if (index >= 0 && index < 64) begin
                    rd_rsp_data <= vmd_regs[index];
                end
            end
            // 其他BAR区域的读取 - 返回0
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
                    
                    // 触发中断，包含错误处理
                    if (!trigger_msix_interrupt(0)) begin // 使用向量0表示管理队列完成
                        // 中断触发失败，可能是MSI-X被禁用或屏蔽
                        // 设置状态标志或尝试备用通知机制
                        msix_pba[0] <= 1'b1; // 设置pending bit，等待MSI-X使能后处理
                    end
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
                    
                    // 触发中断，包含错误处理
                    if (!trigger_msix_interrupt(0)) begin
                        msix_pba[0] <= 1'b1;
                    end
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
                    
                    // 触发中断，包含错误处理
                    if (!trigger_msix_interrupt(0)) begin
                        msix_pba[0] <= 1'b1;
                    end
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
                    
                    // 触发中断，包含错误处理
                    if (!trigger_msix_interrupt(0)) begin
                        msix_pba[0] <= 1'b1;
                    end
                end
            endcase
        end
    endtask
    
    // 增强的MSI-X中断触发函数，包含错误处理和返回值
    function bit trigger_msix_interrupt;
        input [3:0] vector_id;  // 中断向量ID
        begin
            trigger_msix_interrupt = 0;  // 默认返回失败
            
            // 检查MSI-X是否启用且未被屏蔽
            if (!msix_enabled || msix_masked) begin
                msix_pba[vector_id] <= 1'b1;  // 设置pending bit
                return 0;  // 中断被禁用，返回失败
            end
            
            // 检查指定向量是否被屏蔽
            if (msix_table[vector_id*4+3][0]) begin
                msix_pba[vector_id] <= 1'b1;  // 设置pending bit
                return 0;  // 向量被屏蔽，返回失败
            end
            
            // 检查是否已经有中断正在进行
            if (msix_interrupt_valid) begin
                msix_pba[vector_id] <= 1'b1;  // 设置pending bit
                msix_active_vectors[vector_id] <= 1'b1;  // 标记此向量为活动状态
                return 0;  // 当前有中断正在处理，返回失败
            end
            
            // 所有检查通过，可以触发中断
            msix_interrupt_addr <= {msix_table[vector_id*4+1], msix_table[vector_id*4]};
            msix_interrupt_data <= msix_table[vector_id*4+2];
            msix_interrupt_valid <= 1'b1;
            msix_pba[vector_id] <= 1'b1;  // 设置pending bit
            msix_active_vectors[vector_id] <= 1'b1;  // 标记此向量为活动状态
            
            trigger_msix_interrupt = 1;  // 返回成功
        end
    endfunction
    
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

    // 中断触发状态机
    always @(posedge clk) begin
        if (rst) begin
            msix_interrupt_valid <= 1'b0;
            msix_trigger_counter <= 8'h00;
            msix_vector_index <= 4'h0;
            msix_pending_trigger <= 1'b0;
            msix_trigger_state <= MSIX_IDLE;
            msix_pba <= 32'h00000000;
        end else begin
            // 中断触发计数器，周期性地检查是否需要触发中断
            msix_trigger_counter <= msix_trigger_counter + 1'b1;
            
            // 状态机处理
            case (msix_trigger_state)
                MSIX_IDLE: begin
                    // 检查是否有条件触发中断
                    if (msix_enabled && !msix_masked) begin
                        // 周期性中断触发检查 - 约每256个时钟周期
                        if (msix_trigger_counter == 8'hFF) begin
                            // 检查VMD状态是否有变化需要触发中断
                            if ((vmd_status & 32'h0000000F) != 0 || 
                                (vmd_error_status & ~vmd_error_mask) != 0) begin
                                msix_pending_trigger <= 1'b1;
                                msix_trigger_state <= MSIX_PREPARE;
                                
                                // 选择合适的中断向量 - 默认使用0号向量
                                msix_vector_index <= 4'h0;
                            end
                        end
                    end
                end
                
                MSIX_PREPARE: begin
                    // 准备中断数据 - 读取MSI-X表项
                    if (!msix_interrupt_valid && msix_pending_trigger) begin
                        // 检查此向量是否被屏蔽 (表项控制字的bit 0)
                        if ((msix_table[msix_vector_index*4 + 3] & 32'h00000001) == 0) begin
                            // 向量未被屏蔽，可以触发中断
                            msix_trigger_state <= MSIX_TRIGGER;
                        end else begin
                            // 向量被屏蔽，设置Pending位并返回空闲状态
                            msix_pba <= msix_pba | (1 << msix_vector_index);
                            msix_pending_trigger <= 1'b0;
                            msix_trigger_state <= MSIX_IDLE;
                        end
                    end
                end
                
                MSIX_TRIGGER: begin
                    // 触发中断 - 设置中断地址和数据
                    msix_interrupt_addr <= {msix_table[msix_vector_index*4 + 1], msix_table[msix_vector_index*4]};
                    msix_interrupt_data <= msix_table[msix_vector_index*4 + 2];
                    msix_interrupt_valid <= 1'b1;
                    
                    // 清除Pending位
                    msix_pba <= msix_pba & ~(1 << msix_vector_index);
                    
                    // 转到等待状态
                    msix_trigger_state <= MSIX_WAIT;
                end
                
                MSIX_WAIT: begin
                    // 等待中断完成 - 中断信号在处理过程中会自动清除
                    // 当中断有效信号被清除后，返回空闲状态
                    if (!msix_interrupt_valid) begin
                        msix_pending_trigger <= 1'b0;
                        msix_trigger_state <= MSIX_IDLE;
                    end
                end
            endcase
            
            // 自动清除中断有效信号的处理 - 在另一个always块中由计数器控制
        end
    end

    // MSI-X状态机增强
    localparam MSIX_STATE_IDLE      = 2'b00;  // 空闲状态
    localparam MSIX_STATE_PENDING   = 2'b01;  // 中断挂起状态
    localparam MSIX_STATE_ACTIVE    = 2'b10;  // 中断激活状态
    localparam MSIX_STATE_RECOVERY  = 2'b11;  // 中断恢复状态

    // 增强的MSI-X中断控制
    reg [1:0]  msix_state[15:0];          // 每个中断向量的状态机
    reg [7:0]  msix_active_counter[15:0]; // 中断活跃计数器 - 每个向量
    reg [31:0] msix_last_data[15:0];      // 每个向量的上次数据
    reg [63:0] msix_last_addr[15:0];      // 每个向量的上次地址
    reg [15:0] msix_pending_mask;         // 挂起中断掩码
    reg [15:0] msix_vector_enable;        // 向量使能掩码 - 对应MSI-X表
    reg [15:0] msix_access_count;         // 向量访问计数 - 用于检测访问模式
    reg        msix_table_access_flag;    // MSI-X表访问标志

    // MSI-X 高级特性控制
    reg        msix_advanced_mode;        // 高级模式使能
    reg [7:0]  msix_throttle_counter;     // 中断限流计数器
    reg [7:0]  msix_throttle_threshold;   // 中断限流阈值
    reg [31:0] msix_vector_stats[15:0];   // 每个向量的使用统计

    // MSI-X表优化访问和错误恢复
    reg [15:0] msix_table_access_history; // 表访问历史记录
    reg [7:0]  msix_sequential_access;    // 连续访问计数
    reg [31:0] msix_table_read_addr;      // 表读取地址
    reg [31:0] msix_table_write_addr;     // 表写入地址
    reg        msix_pba_access_detected;  // PBA访问检测标志

    // 挂起位数组 (PBA)模拟 - 更完整的MSI-X实现
    reg [63:0] msix_pba_bits;             // 挂起位数组

    // 初始化MSI-X增强部分
    initial begin
        // 初始化状态机和计数器
        for (int i = 0; i < 16; i++) begin
            msix_state[i] = MSIX_STATE_IDLE;
            msix_active_counter[i] = 8'h00;
            msix_last_data[i] = 32'h00000000;
            msix_last_addr[i] = 64'h0000000000000000;
            msix_vector_stats[i] = 32'h00000000;
        end
        
        // 初始化控制寄存器
        msix_pending_mask = 16'h0000;
        msix_vector_enable = 16'h0000;
        msix_access_count = 16'h0000;
        msix_table_access_flag = 1'b0;
        
        // 高级特性初始化
        msix_advanced_mode = 1'b0;
        msix_throttle_counter = 8'h00;
        msix_throttle_threshold = 8'h08; // 默认限流阈值
        
        // 访问跟踪初始化
        msix_table_access_history = 16'h0000;
        msix_sequential_access = 8'h00;
        msix_table_read_addr = 32'h00000000;
        msix_table_write_addr = 32'h00000000;
        msix_pba_access_detected = 1'b0;
        
        // PBA模拟初始化
        msix_pba_bits = 64'h0000000000000000;
    end

    // MSI-X表访问监控 - 在BAR写入和读取处理中增加代码
    // 在wr_valid处理部分添加 - 约在250行左右
    // 仅作为示例，具体位置根据实际代码调整
    always @(posedge clk) begin
        if (rst) begin
            msix_table_access_flag <= 1'b0;
            msix_table_access_history <= 16'h0000;
            msix_sequential_access <= 8'h00;
            msix_pba_access_detected <= 1'b0;
        end else begin
            // 监控MSI-X表区域访问
            if (wr_valid) begin 
                if ((wr_addr >= MSIX_TABLE_OFFSET) && (wr_addr < MSIX_TABLE_OFFSET + 32'h00001000)) begin
                    // MSI-X表写入访问
                    msix_table_access_flag <= 1'b1;
                    msix_table_access_history <= {msix_table_access_history[14:0], 1'b1};
                    msix_table_write_addr <= wr_addr;
                    
                    // 检测MSI-X表项修改
                    if (((wr_addr & 32'h0000000F) == 32'h00000008) || ((wr_addr & 32'h0000000F) == 32'h0000000C)) begin
                        // 控制寄存器访问 - 表项中的高地址或数据字段
                        msix_vector_enable[wr_addr[7:4]] <= ~wr_be[3] || ~wr_data[31]; // 检查MSI-X表项控制位
                    end
                    
                    // 跟踪连续访问
                    if (msix_table_write_addr + 4 == wr_addr) begin
                        if (msix_sequential_access < 8'hFF) begin
                            msix_sequential_access <= msix_sequential_access + 1'b1;
                        end
                    end else begin
                        msix_sequential_access <= 8'h00;
                    end
                end else if ((wr_addr >= MSIX_PBA_OFFSET) && (wr_addr < MSIX_PBA_OFFSET + 32'h00001000)) begin
                    // MSI-X PBA访问
                    msix_pba_access_detected <= 1'b1;
                    msix_table_access_history <= {msix_table_access_history[14:0], 1'b0};
                end else begin
                    // 非MSI-X表区域访问
                    msix_table_access_flag <= 1'b0;
                end
            end
            
            // 读取访问也要跟踪
            if (rd_req_valid) begin
                if ((rd_req_addr >= MSIX_TABLE_OFFSET) && (rd_req_addr < MSIX_TABLE_OFFSET + 32'h00001000)) begin
                    msix_table_access_flag <= 1'b1;
                    msix_table_read_addr <= rd_req_addr;
                    msix_table_access_history <= {msix_table_access_history[14:0], 1'b1};
                    
                    // 更新访问计数
                    msix_access_count <= msix_access_count + 1'b1;
                    
                    // 跟踪连续访问
                    if (msix_table_read_addr + 4 == rd_req_addr) begin
                        if (msix_sequential_access < 8'hFF) begin
                            msix_sequential_access <= msix_sequential_access + 1'b1;
                        end
                    end else begin
                        msix_sequential_access <= 8'h00;
                    end
                end else if ((rd_req_addr >= MSIX_PBA_OFFSET) && (rd_req_addr < MSIX_PBA_OFFSET + 32'h00001000)) begin
                    // PBA读取访问
                    msix_pba_access_detected <= 1'b1;
                    msix_table_access_history <= {msix_table_access_history[14:0], 1'b0};
                end
            end
            
            // 复位检测标志 - 延迟清除以允许状态机响应
            if (msix_pba_access_detected && (msix_table_access_history == 16'h0000)) begin
                msix_pba_access_detected <= 1'b0;
            end
        end
    end

    // 中断向量管理和状态机 - 添加在现有代码后
    // 中断向量状态机 - 管理每个中断向量的生命周期
    // 添加在700行左右，根据具体实现位置调整
    always @(posedge clk) begin
        if (rst) begin
            // 重置所有向量状态
            for (int i = 0; i < 16; i++) begin
                msix_state[i] <= MSIX_STATE_IDLE;
                msix_active_counter[i] <= 8'h00;
            end
            
            // 重置PBA位和控制标志
            msix_pba_bits <= 64'h0000000000000000;
            msix_pending_mask <= 16'h0000;
            msix_interrupt_valid <= 1'b0;
            msix_interrupt_error <= 1'b0;
            msix_throttle_counter <= 8'h00;
        end else begin
            // 中断限流计数器处理
            if (msix_throttle_counter > 0) begin
                msix_throttle_counter <= msix_throttle_counter - 1'b1;
            end
            
            // 处理每个中断向量的状态
            for (int i = 0; i < 16; i++) begin
                case (msix_state[i])
                    MSIX_STATE_IDLE: begin
                        // 空闲状态 - 检查是否需要触发中断
                        if (msix_pending_mask[i] && msix_vector_enable[i] && msix_enabled && !msix_masked) begin
                            // 有挂起中断且向量已启用，转换到挂起状态
                            msix_state[i] <= MSIX_STATE_PENDING;
                            msix_active_counter[i] <= 8'h01; // 初始化活跃计数器
                            
                            // 设置PBA位
                            msix_pba_bits[i] <= 1'b1;
                        end else begin
                            // 保持空闲状态
                            msix_active_counter[i] <= 8'h00;
                            msix_pba_bits[i] <= 1'b0;
                        end
                    end
                    
                    MSIX_STATE_PENDING: begin
                        // 挂起状态 - 准备发送中断
                        if (!msix_interrupt_valid && (msix_throttle_counter == 0)) begin
                            // 中断总线空闲，可以发送中断
                            msix_state[i] <= MSIX_STATE_ACTIVE;
                            msix_interrupt_valid <= 1'b1;
                            msix_interrupt_addr <= msix_last_addr[i];
                            msix_interrupt_data <= msix_last_data[i];
                            msix_throttle_counter <= msix_throttle_threshold; // 设置限流计数器
                            
                            // 更新统计信息
                            msix_vector_stats[i] <= msix_vector_stats[i] + 1'b1;
                        end else begin
                            // 继续等待中断总线空闲
                            msix_active_counter[i] <= msix_active_counter[i] + 1'b1;
                            
                            // 超时检测 - 如果等待太久，进入恢复状态
                            if (msix_active_counter[i] >= 8'hF0) begin
                                msix_state[i] <= MSIX_STATE_RECOVERY;
                                msix_interrupt_error <= 1'b1; // 指示中断错误
                            end
                        end
                    end
                    
                    MSIX_STATE_ACTIVE: begin
                        // 活跃状态 - 中断正在发送
                        msix_interrupt_valid <= 1'b0; // 复位中断有效信号
                        msix_pending_mask[i] <= 1'b0; // 清除挂起标志
                        msix_state[i] <= MSIX_STATE_IDLE; // 返回空闲状态
                        
                        // 清除PBA位 - 中断已被发送
                        msix_pba_bits[i] <= 1'b0;
                    end
                    
                    MSIX_STATE_RECOVERY: begin
                        // 恢复状态 - 处理中断错误
                        msix_interrupt_error <= 1'b0; // 清除错误标志
                        msix_pending_mask[i] <= 1'b0; // 清除挂起标志
                        msix_pba_bits[i] <= 1'b0;     // 清除PBA位
                        msix_active_counter[i] <= 8'h00; // 重置计数器
                        msix_state[i] <= MSIX_STATE_IDLE; // 返回空闲状态
                    end
                endcase
            end
            
            // 处理PBA访问 - 当软件读取PBA寄存器时可能会清除挂起位
            if (msix_pba_access_detected) begin
                // 在高级模式下，读取PBA会影响挂起位状态
                if (msix_advanced_mode) begin
                    // 对于已读取的PBA位，检查并可能清除挂起状态
                    for (int i = 0; i < 16; i++) begin
                        if (msix_pba_bits[i] && (msix_state[i] == MSIX_STATE_PENDING)) begin
                            // 将PBA位延迟一个周期清除 - 仿真实际硬件行为
                            msix_pba_bits[i] <= 1'b0;
                        end
                    end
                end
            end
        end
    end

    // 扩展的MSI-X处理功能
    // 在中断触发函数或模块中添加
    task trigger_msix_interrupt;
        input [3:0] vector;
        begin
            // 设置中断挂起标志
            msix_pending_mask[vector] <= 1'b1;
        end
    endtask

    // 处理传入的PCIe事件，生成适当的MSI-X中断
    task process_pcie_event;
        input [7:0] event_type;
        input [7:0] event_data;
        begin
            case (event_type)
                8'h01: begin // 配置空间访问事件
                    trigger_msix_interrupt(4'h0); // 使用向量0
                end
                
                8'h02: begin // 错误事件
                    trigger_msix_interrupt(4'h1); // 使用向量1
                    
                    // 更新错误状态寄存器
                    vmd_error_status <= vmd_error_status | (32'h00000001 << event_data[3:0]);
                end
                
                8'h03: begin // DMA完成事件
                    trigger_msix_interrupt(4'h2); // 使用向量2
                end
                
                8'h04: begin // 控制器状态变化
                    if (event_data[0]) begin // 就绪状态变化
                        trigger_msix_interrupt(4'h3); // 使用向量3
                    end
                end
                
                default: begin
                    // 未知事件类型 - 可以记录或忽略
                end
            endcase
        end
    endtask

endmodule
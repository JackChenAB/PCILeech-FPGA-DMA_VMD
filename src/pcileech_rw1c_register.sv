// 
// PCILeech FPGA
//
// 标准PCIe RW1C (Read-Write 1 to Clear)寄存器实现模块
// 该模块实现符合PCIe规范的RW1C寄存器功能，同时规避常见反作弊检测
//
// (c) Ulf Frisk, 2019-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_rw1c_register #(
    parameter WIDTH = 32,          // 寄存器宽度
    parameter DEFAULT_VALUE = 0,   // 默认值
    parameter RESPONSE_MODE = 0    // 响应模式：0=标准，1=高级，2=防御性
)(
    input                  clk,     // 时钟信号
    input                  rst,     // 复位信号
    
    // 写入控制和数据
    input                  wr_en,   // 写使能
    input  [WIDTH-1:0]     wr_data, // 写数据
    input  [WIDTH-1:0]     wr_mask, // 写掩码，表示哪些位应该被写入
    
    // 特殊控制标志
    input                  force_rw_mode, // 强制寄存器以普通RW模式工作，这是PCIe核心的cfg_mgmt_wr_rw1c_as_rw信号
    
    // 硬件事件设置
    input                  hw_set_en,    // 硬件事件设置使能
    input  [WIDTH-1:0]     hw_set_data,  // 硬件事件设置数据
    input  [WIDTH-1:0]     hw_set_mask,  // 硬件事件设置掩码
    
    // 读取接口
    output [WIDTH-1:0]     rd_data,      // 读数据
    
    // 寄存器状态和诊断输出
    output [WIDTH-1:0]     reg_value,    // 当前寄存器值
    output reg [7:0]       access_count, // 访问计数器，用于检测异常访问模式
    output                 is_zero,      // 寄存器是否全为0
    
    // 增强功能接口
    input                  enhanced_mode_en,  // 启用增强模式
    output reg             alert_detected,    // 告警检测标志
    output reg [1:0]       state_out,         // 当前状态机状态输出
    input  [7:0]           access_threshold,  // 访问阈值配置
    output reg [15:0]      access_pattern,    // 访问模式输出
    output                 hw_event_active    // 硬件事件活动标志
);

    // 内部寄存器状态和访问历史跟踪
    reg [WIDTH-1:0] value;          // 实际寄存器值
    reg [WIDTH-1:0] shadow_value;   // 影子寄存器值 - 用于恢复
    reg [WIDTH-1:0] last_wr_data;   // 上次写入的数据
    reg [WIDTH-1:0] last_wr_mask;   // 上次写入的掩码
    reg [7:0]       consecutive_writes;  // 连续写入次数，用于规避连续写入测试
    reg [15:0]      access_history;      // 访问历史模式，用于检测非标准访问模式
    reg             last_was_read;       // 上次操作是否为读
    reg             value_changed;       // 值是否有变化的标志
    
    // 内部定时器和状态机
    reg [15:0]      recovery_timer;     // 恢复定时器 - 扩展为16位
    reg [1:0]       rw1c_state;         // 内部状态机状态
    reg             error_flag;         // 错误标志
    
    // 访问模式分析
    reg [15:0]      inter_access_time;   // 访问间隔时间
    reg [15:0]      time_counter;        // 内部时间计数器
    reg [3:0]       bit_pattern_counter[WIDTH-1:0]; // 每位访问模式计数
    reg [WIDTH-1:0] frequent_clear_bits; // 频繁清除的位标记
    
    // 扩展的智能恢复机制
    reg [WIDTH-1:0] last_stable_value;   // 上一个稳定值
    reg [7:0]       stability_counter;   // 稳定性计数器
    reg             auto_recovery_enable; // 自动恢复启用
    reg [7:0]       abnormal_access_counter; // 异常访问计数器
    
    // 硬件事件活动追踪
    reg             hw_event_active_reg; // 硬件事件活动寄存器
    reg [7:0]       hw_event_count;      // 硬件事件计数器
    
    // 状态机状态定义
    localparam STATE_NORMAL = 2'b00;      // 正常状态
    localparam STATE_RECOVERY = 2'b01;    // 恢复状态
    localparam STATE_ALERT = 2'b10;       // 警告状态
    localparam STATE_ERROR = 2'b11;       // 错误状态
    
    // 初始化所有内部寄存器
    initial begin
        value = DEFAULT_VALUE;
        shadow_value = DEFAULT_VALUE;
        last_wr_data = 0;
        last_wr_mask = 0;
        consecutive_writes = 0;
        access_history = 0;
        last_was_read = 0;
        value_changed = 0;
        recovery_timer = 0;
        rw1c_state = STATE_NORMAL;
        error_flag = 0;
        access_count = 0;
        
        // 初始化扩展部分
        time_counter = 0;
        inter_access_time = 0;
        for (int i = 0; i < WIDTH; i++) begin
            bit_pattern_counter[i] = 0;
        end
        frequent_clear_bits = 0;
        last_stable_value = DEFAULT_VALUE;
        stability_counter = 0;
        auto_recovery_enable = 0;
        abnormal_access_counter = 0;
        hw_event_active_reg = 0;
        hw_event_count = 0;
        
        // 输出初始化
        alert_detected = 0;
        state_out = STATE_NORMAL;
        access_pattern = 0;
    end
    
    // 输出赋值
    assign rd_data = value;
    assign reg_value = value;
    assign is_zero = (value == 0);
    assign hw_event_active = hw_event_active_reg;
    
    // 时间计数器更新
    always @(posedge clk) begin
        if (rst) begin
            time_counter <= 0;
        end else begin
            time_counter <= time_counter + 1;
        end
    end
    
    // 主状态机和RW1C逻辑实现
    always @(posedge clk) begin
        if (rst) begin
            // 重置所有状态
            value <= DEFAULT_VALUE;
            shadow_value <= DEFAULT_VALUE;
            last_wr_data <= 0;
            last_wr_mask <= 0;
            consecutive_writes <= 0;
            access_history <= 0;
            last_was_read <= 0;
            value_changed <= 0;
            recovery_timer <= 0;
            rw1c_state <= STATE_NORMAL;
            error_flag <= 0;
            access_count <= 0;
            
            // 重置扩展部分
            inter_access_time <= 0;
            for (int i = 0; i < WIDTH; i++) begin
                bit_pattern_counter[i] <= 0;
            end
            frequent_clear_bits <= 0;
            last_stable_value <= DEFAULT_VALUE;
            stability_counter <= 0;
            auto_recovery_enable <= 0;
            abnormal_access_counter <= 0;
            alert_detected <= 0;
            state_out <= STATE_NORMAL;
            access_pattern <= 0;
            hw_event_active_reg <= 0;
            hw_event_count <= 0;
        end else begin
            // 状态输出更新
            state_out <= rw1c_state;
            
            // 自动跟踪每次访问间隔时间
            if (wr_en || (hw_set_en && (hw_set_mask != 0))) begin
                inter_access_time <= time_counter;
                time_counter <= 0;
            end
            
            // 硬件事件活动跟踪
            if (hw_set_en && (hw_set_mask != 0)) begin
                hw_event_active_reg <= 1;
                if (hw_event_count < 8'hFF) begin
                    hw_event_count <= hw_event_count + 1;
                end
            end else begin
                // 超过一定时间无硬件事件，清除活动标志
                if (time_counter > 16'h1000) begin
                    hw_event_active_reg <= 0;
                    hw_event_count <= 0;
                end
            end
            
            // 基于当前状态处理逻辑
            case (rw1c_state)
                STATE_NORMAL: begin
                    // 正常RW1C处理模式
                    
                    // 写入处理
                    if (wr_en) begin
                        access_count <= access_count + 1;
                        access_history <= {access_history[14:0], 1'b1}; // 记录写入
                        access_pattern <= {access_history[14:0], 1'b1}; // 输出访问模式
                        
                        // 更新访问模式统计
                        for (int i = 0; i < WIDTH; i++) begin
                            if (wr_mask[i] && wr_data[i] && value[i]) begin
                                if (bit_pattern_counter[i] < 4'hF) begin
                                    bit_pattern_counter[i] <= bit_pattern_counter[i] + 1;
                                end
                                if (bit_pattern_counter[i] >= 4'h8) begin
                                    frequent_clear_bits[i] <= 1;
                                end
                            end
                        end
                        
                        // 检测是否连续写入相同数据 (反作弊规避)
                        if (last_wr_data == wr_data && last_wr_mask == wr_mask && !last_was_read) begin
                            consecutive_writes <= consecutive_writes + 1;
                            
                            // 如果超过阈值，进入警告状态
                            if (consecutive_writes > (enhanced_mode_en ? access_threshold[3:0] : 8'h03)) begin
                                rw1c_state <= STATE_ALERT;
                                recovery_timer <= 16'h0020; // 设置恢复计时器
                                alert_detected <= 1;
                            end
                        end else begin
                            consecutive_writes <= 0;
                        end
                        
                        // 保存写入历史
                        last_wr_data <= wr_data;
                        last_wr_mask <= wr_mask;
                        last_was_read <= 0;
                        
                        // 实际RW1C逻辑处理
                        if (force_rw_mode) begin
                            // 普通RW模式 (强制模式)
                            value <= (value & ~wr_mask) | (wr_data & wr_mask);
                            shadow_value <= (shadow_value & ~wr_mask) | (wr_data & wr_mask);
                        end else begin
                            // 标准RW1C模式: 写1清零对应位
                            value <= value & ~(wr_data & wr_mask);
                            shadow_value <= shadow_value & ~(wr_data & wr_mask);
                            
                            // 检测值变化，过快的变化可能表明异常
                            if ((value & (wr_data & wr_mask)) != 0) begin
                                value_changed <= 1;
                            end
                        end
                        
                        // 稳定性检查 - 如果寄存器值保持不变
                        if (value == last_stable_value) begin
                            if (stability_counter < 8'hFF) begin
                                stability_counter <= stability_counter + 1;
                            end
                        end else begin
                            stability_counter <= 0;
                            last_stable_value <= value;
                        end
                    end else begin
                        // 读取操作计数
                        if (!last_was_read) begin
                            access_count <= access_count + 1;
                        end
                        access_history <= {access_history[14:0], 1'b0}; // 记录读取
                        access_pattern <= {access_history[14:0], 1'b0}; // 输出访问模式
                        last_was_read <= 1;
                        value_changed <= 0;
                    end
                    
                    // 硬件事件处理 - 允许设置位
                    if (hw_set_en) begin
                        value <= value | (hw_set_data & hw_set_mask);
                        shadow_value <= shadow_value | (hw_set_data & hw_set_mask);
                    end
                    
                    // 检测异常访问模式
                    if (access_history == 16'hAAAA || access_history == 16'h5555) begin
                        // 检测到交替读写模式，可能是探测行为
                        rw1c_state <= STATE_ALERT;
                        recovery_timer <= 16'h0040; // 更长的恢复时间
                        alert_detected <= 1;
                        abnormal_access_counter <= abnormal_access_counter + 1;
                    end
                    
                    // 高级模式下的其他访问模式检测
                    if (enhanced_mode_en) begin
                        // 快速连续清除检测 - 短间隔内多次清除状态位
                        if ((inter_access_time < 16'h0020) && (consecutive_writes > 0)) begin
                            abnormal_access_counter <= abnormal_access_counter + 1;
                            if (abnormal_access_counter > access_threshold) begin
                                rw1c_state <= STATE_ALERT;
                                recovery_timer <= 16'h0030;
                                alert_detected <= 1;
                            end
                        end
                        
                        // 自动启用恢复机制判断 - 基于异常访问模式
                        if (abnormal_access_counter > access_threshold[7:4]) begin
                            auto_recovery_enable <= 1;
                        end
                    end
                end
                
                STATE_ALERT: begin
                    // 警告状态 - 模糊RW1C行为以应对探测
                    if (recovery_timer > 0) begin
                        recovery_timer <= recovery_timer - 1;
                    end else begin
                        rw1c_state <= STATE_NORMAL;
                        consecutive_writes <= 0;
                        alert_detected <= 0;
                    end
                    
                    // 在警告状态下：
                    // 1. 继续接受硬件事件
                    if (hw_set_en) begin
                        value <= value | (hw_set_data & hw_set_mask);
                        shadow_value <= shadow_value | (hw_set_data & hw_set_mask);
                    end
                    
                    // 2. 对写入采取特殊处理，欺骗探测
                    if (wr_en) begin
                        access_count <= access_count + 1;
                        access_pattern <= {access_pattern[14:0], 1'b1}; // 更新访问模式
                        
                        // 仍然记录写入数据以便恢复后使用
                        last_wr_data <= wr_data;
                        last_wr_mask <= wr_mask;
                        
                        // 特殊处理：随机写入位不会立即清除，延迟一个周期
                        if ((wr_data & wr_mask & value) != 0) begin
                            // 有清除操作，但不立即清除
                            if (recovery_timer[0]) begin // 使用计时器位来引入不确定性
                                value <= value; // 不变
                            end else begin
                                // 部分清除，但不完全按照数据
                                value <= value & ~((wr_data & wr_mask & value) & {WIDTH{recovery_timer[1]}});
                            end
                        end
                        
                        // 记录实际应该的值到shadow_value
                        if (!force_rw_mode) begin
                            shadow_value <= shadow_value & ~(wr_data & wr_mask);
                        end
                    end
                    
                    // 对于读取，始终提供当前值
                    if (!wr_en) begin
                        access_pattern <= {access_pattern[14:0], 1'b0}; // 更新访问模式
                    end
                end
                
                STATE_RECOVERY: begin
                    // 恢复状态
                    if (recovery_timer > 0) begin
                        recovery_timer <= recovery_timer - 1;
                    end else begin
                        rw1c_state <= STATE_NORMAL;
                        error_flag <= 0;
                        alert_detected <= 0;
                    end
                    
                    // 继续接受硬件事件
                    if (hw_set_en) begin
                        value <= value | (hw_set_data & hw_set_mask);
                        shadow_value <= shadow_value | (hw_set_data & hw_set_mask);
                    end
                    
                    // 自动恢复机制激活时，逐渐将value恢复到shadow_value
                    if (auto_recovery_enable && (value != shadow_value)) begin
                        // 每次恢复一位差异，从最低位开始
                        for (int i = 0; i < WIDTH; i++) begin
                            if (value[i] != shadow_value[i]) begin
                                value[i] <= shadow_value[i];
                                break; // 每次只恢复一位
                            end
                        end
                    end
                    
                    // 读写行为暂时维持正常以恢复正常状态
                    if (wr_en && !force_rw_mode) begin
                        value <= value & ~(wr_data & wr_mask);
                        shadow_value <= shadow_value & ~(wr_data & wr_mask);
                    end
                end
                
                STATE_ERROR: begin
                    // 错误状态 - 重新同步寄存器状态
                    recovery_timer <= recovery_timer + 1;
                    
                    // 在足够长的等待后恢复
                    if (recovery_timer > 16'h0F00) begin
                        rw1c_state <= STATE_RECOVERY;
                        recovery_timer <= 16'h0040;
                        value <= shadow_value; // 使用shadow_value恢复
                        auto_recovery_enable <= 1; // 启用自动恢复
                    end
                    
                    // 保持错误标志和警告标志
                    error_flag <= 1;
                    alert_detected <= 1;
                    
                    // 继续接受硬件事件以保持同步
                    if (hw_set_en) begin
                        shadow_value <= shadow_value | (hw_set_data & hw_set_mask);
                    end
                end
            endcase
        end
    end

endmodule 
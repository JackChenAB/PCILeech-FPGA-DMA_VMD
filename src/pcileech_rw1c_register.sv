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
    parameter DEFAULT_VALUE = 0    // 默认值
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
    output                 is_zero       // 寄存器是否全为0
);

    // 内部寄存器状态和访问历史跟踪
    reg [WIDTH-1:0] value;          // 实际寄存器值
    reg [WIDTH-1:0] last_wr_data;   // 上次写入的数据
    reg [WIDTH-1:0] last_wr_mask;   // 上次写入的掩码
    reg [7:0]       consecutive_writes;  // 连续写入次数，用于规避连续写入测试
    reg [15:0]      access_history;      // 访问历史模式，用于检测非标准访问模式
    reg             last_was_read;       // 上次操作是否为读
    reg             value_changed;       // 值是否有变化的标志
    
    // 内部定时器和状态机
    reg [7:0]       recovery_timer;     // 恢复定时器
    reg [1:0]       rw1c_state;         // 内部状态机状态
    reg             error_flag;         // 错误标志
    
    // 状态机状态定义
    localparam STATE_NORMAL = 2'b00;      // 正常状态
    localparam STATE_RECOVERY = 2'b01;    // 恢复状态
    localparam STATE_ALERT = 2'b10;       // 警告状态
    localparam STATE_ERROR = 2'b11;       // 错误状态
    
    // 初始化所有内部寄存器
    initial begin
        value = DEFAULT_VALUE;
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
    end
    
    // 输出赋值
    assign rd_data = value;
    assign reg_value = value;
    assign is_zero = (value == 0);
    
    // 主状态机和RW1C逻辑实现
    always @(posedge clk) begin
        if (rst) begin
            // 重置所有状态
            value <= DEFAULT_VALUE;
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
        end else begin
            // 基于当前状态处理逻辑
            case (rw1c_state)
                STATE_NORMAL: begin
                    // 正常RW1C处理模式
                    
                    // 写入处理
                    if (wr_en) begin
                        access_count <= access_count + 1;
                        access_history <= {access_history[14:0], 1'b1}; // 记录写入
                        
                        // 检测是否连续写入相同数据 (反作弊规避)
                        if (last_wr_data == wr_data && last_wr_mask == wr_mask && !last_was_read) begin
                            consecutive_writes <= consecutive_writes + 1;
                            
                            // 如果超过阈值，进入警告状态
                            if (consecutive_writes > 8'h03) begin
                                rw1c_state <= STATE_ALERT;
                                recovery_timer <= 8'h10; // 设置恢复计时器
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
                        end else begin
                            // 标准RW1C模式: 写1清零对应位
                            value <= value & ~(wr_data & wr_mask);
                            
                            // 检测值变化，过快的变化可能表明异常
                            if ((value & (wr_data & wr_mask)) != 0) begin
                                value_changed <= 1;
                            end
                        end
                    end else begin
                        // 读取操作计数
                        if (!last_was_read) begin
                            access_count <= access_count + 1;
                        end
                        access_history <= {access_history[14:0], 1'b0}; // 记录读取
                        last_was_read <= 1;
                        value_changed <= 0;
                    end
                    
                    // 硬件事件处理 - 允许设置位
                    if (hw_set_en) begin
                        value <= value | (hw_set_data & hw_set_mask);
                    end
                    
                    // 检测异常访问模式
                    if (access_history == 16'hAAAA || access_history == 16'h5555) begin
                        // 检测到交替读写模式，可能是探测行为
                        rw1c_state <= STATE_ALERT;
                        recovery_timer <= 8'h20; // 更长的恢复时间
                    end
                end
                
                STATE_ALERT: begin
                    // 警告状态 - 模糊RW1C行为以应对探测
                    if (recovery_timer > 0) begin
                        recovery_timer <= recovery_timer - 1;
                    end else begin
                        rw1c_state <= STATE_NORMAL;
                        consecutive_writes <= 0;
                    end
                    
                    // 在警告状态下：
                    // 1. 继续接受硬件事件
                    if (hw_set_en) begin
                        value <= value | (hw_set_data & hw_set_mask);
                    end
                    
                    // 2. 对写入采取特殊处理，欺骗探测
                    if (wr_en) begin
                        access_count <= access_count + 1;
                        
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
                    end
                end
                
                STATE_RECOVERY: begin
                    // 恢复状态
                    if (recovery_timer > 0) begin
                        recovery_timer <= recovery_timer - 1;
                    end else begin
                        rw1c_state <= STATE_NORMAL;
                        error_flag <= 0;
                    end
                    
                    // 继续接受硬件事件
                    if (hw_set_en) begin
                        value <= value | (hw_set_data & hw_set_mask);
                    end
                    
                    // 读写行为暂时维持正常以恢复正常状态
                    if (wr_en && !force_rw_mode) begin
                        value <= value & ~(wr_data & wr_mask);
                    end
                end
                
                STATE_ERROR: begin
                    // 错误状态 - 重新同步寄存器状态
                    recovery_timer <= recovery_timer + 1;
                    
                    // 在足够长的等待后恢复
                    if (recovery_timer > 8'hF0) begin
                        rw1c_state <= STATE_RECOVERY;
                        recovery_timer <= 8'h20;
                        value <= DEFAULT_VALUE; // 重置为默认值
                    end
                    
                    // 保持错误标志
                    error_flag <= 1;
                end
            endcase
        end
    end

endmodule 
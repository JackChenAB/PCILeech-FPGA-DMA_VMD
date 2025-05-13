//
// PCILeech FPGA.
//
// PCIe TLP 访问监控模块
// 
// 本模块实现了针对PCIe寄存器的访问模式监控技术，能够识别异常访问模式
// 并提供适当的稳定性保障机制
//
// (c) Ulf Frisk, 2019-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_tlps128_monitor(
    input                   rst,
    input                   clk,
    
    // PCIe TLP监控接口
    input                   tlp_valid,       // TLP有效标志
    input [31:0]            tlp_addr,        // TLP地址
    input [3:0]             tlp_type,        // TLP类型 (0=MRd, 1=MWr, 2=CfgRd, 3=CfgWr)
    input [3:0]             tlp_be,          // TLP字节使能
    input [31:0]            tlp_data,        // TLP数据
    
    // 寄存器访问监控
    input [7:0]             access_count[3:0], // 最多4个寄存器的访问计数
    
    // 检测结果输出
    output reg              abnormal_detected,  // 检测到异常访问标志
    output reg [3:0]        abnormal_type,      // 异常类型 (0=无, 1=监控, 2=重复, 3=模式分析, 4=快速交替)
    output reg [31:0]       abnormal_addr,      // 发现异常行为的地址
    
    // 稳定性控制
    output reg              stability_active,   // 稳定性保障机制激活标志
    output reg [1:0]        stability_level,    // 稳定性级别 (0=无, 1=低, 2=中, 3=高)
    
    // 配置接口
    input                   cfg_enable,        // 启用访问监控
    input [1:0]             cfg_sensitivity,   // 监控灵敏度 (0=低, 1=中, 2=高, 3=极高)
    input [1:0]             cfg_response       // 响应模式 (0=仅记录, 1=低保障, 2=中保障, 3=高保障)
);

    // 内部状态和计数器
    reg [31:0]  access_history[15:0];     // 访问历史记录 (最近16次访问)
    reg [3:0]   history_ptr;              // 历史记录指针
    reg [31:0]  repeat_pattern[3:0];      // 检测到的重复模式
    reg [3:0]   pattern_length;           // 重复模式长度
    
    // 交替模式检测
    reg [15:0]  alternating_pattern;      // 读写交替模式检测位
    reg [7:0]   rapid_access_counter;     // 快速访问计数器
    reg [31:0]  timer_counter;            // 计时器
    
    // 特定访问模式的检测
    reg [31:0]  last_read_addr;           // 上次读取的地址
    reg [31:0]  last_write_addr;          // 上次写入的地址
    reg [31:0]  last_read_data;           // 上次读取的数据
    reg [31:0]  last_write_data;          // 上次写入的数据
    
    // 稳定性状态控制
    reg [7:0]   stability_timer;          // 稳定性计时器
    reg         stability_escalating;     // 稳定性升级标志
    
    // 访问模式类型定义
    localparam NORMAL_ACCESS = 4'h0;            // 正常访问
    localparam REGISTER_TEST = 4'h1;            // 寄存器功能测试
    localparam RAPID_TOGGLE = 4'h2;             // 快速读写切换
    localparam WRITE_ZERO = 4'h3;               // 写0行为
    localparam CONSTANT_READ = 4'h4;            // 恒定读取
    localparam PATTERN_ANALYSIS = 4'h5;         // 模式分析
    
    // 初始化所有内部寄存器
    initial begin
        abnormal_detected = 0;
        abnormal_type = 0;
        abnormal_addr = 0;
        stability_active = 0;
        stability_level = 0;
        history_ptr = 0;
        pattern_length = 0;
        alternating_pattern = 0;
        rapid_access_counter = 0;
        timer_counter = 0;
        last_read_addr = 0;
        last_write_addr = 0;
        last_read_data = 0;
        last_write_data = 0;
        stability_timer = 0;
        stability_escalating = 0;
        
        for (int i = 0; i < 16; i = i + 1) begin
            access_history[i] = 0;
        end
        
        for (int i = 0; i < 4; i = i + 1) begin
            repeat_pattern[i] = 0;
        end
    end
    
    // 生成随机延迟的线性反馈移位寄存器
    reg [15:0] lfsr;
    wire [15:0] lfsr_next = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    
    always @(posedge clk) begin
        if (rst) begin
            lfsr <= 16'h1234;  // 初始种子值
        end else begin
            lfsr <= lfsr_next;
        end
    end
    
    // 主要监控逻辑
    always @(posedge clk) begin
        if (rst) begin
            abnormal_detected <= 0;
            abnormal_type <= 0;
            abnormal_addr <= 0;
            stability_active <= 0;
            stability_level <= 0;
            history_ptr <= 0;
            pattern_length <= 0;
            alternating_pattern <= 0;
            rapid_access_counter <= 0;
            timer_counter <= 0;
            last_read_addr <= 0;
            last_write_addr <= 0;
            last_read_data <= 0;
            last_write_data <= 0;
            stability_timer <= 0;
            stability_escalating <= 0;
        end else begin
            // 递增计时器
            timer_counter <= timer_counter + 1;
            
            // 检测前提：启用访问监控
            if (cfg_enable) begin
                // 处理TLP访问
                if (tlp_valid) begin
                    // 记录访问历史
                    access_history[history_ptr] <= {tlp_type, tlp_be, tlp_addr[15:0], tlp_data[7:0]};
                    history_ptr <= history_ptr + 1;
                    
                    // 更新最近访问信息
                    if (tlp_type == 4'h0 || tlp_type == 4'h2) begin // 读操作
                        last_read_addr <= tlp_addr;
                        last_read_data <= tlp_data;
                    end else if (tlp_type == 4'h1 || tlp_type == 4'h3) begin // 写操作
                        last_write_addr <= tlp_addr;
                        last_write_data <= tlp_data;
                        
                        // 检测写0行为 - 写0到特殊寄存器
                        if (tlp_data == 32'h00000000 && 
                            (tlp_addr == 32'h00000004 || // 状态寄存器地址
                             tlp_addr == 32'h00000110)   // 控制寄存器地址
                           ) begin
                            if (cfg_sensitivity >= 2'h1) begin // 中或更高灵敏度
                                abnormal_detected <= 1;
                                abnormal_type <= WRITE_ZERO;
                                abnormal_addr <= tlp_addr;
                                stability_active <= (cfg_response != 2'h0); // 启用稳定性保障
                                stability_level <= cfg_response;
                            end
                        end
                    end
                    
                    // 更新读/写交替模式
                    alternating_pattern <= {alternating_pattern[14:0], 
                                          (tlp_type == 4'h0 || tlp_type == 4'h2) ? 1'b0 : 1'b1};
                    
                    // 检测快速读写交替模式 (0101...)
                    if (alternating_pattern == 16'h5555 || alternating_pattern == 16'hAAAA) begin
                        abnormal_detected <= 1;
                        abnormal_type <= RAPID_TOGGLE;
                        abnormal_addr <= tlp_addr;
                        stability_active <= (cfg_response != 2'h0); // 启用稳定性保障
                        stability_level <= cfg_response;
                    end
                    
                    // 检测快速访问行为
                    if ((last_read_addr == tlp_addr || last_write_addr == tlp_addr) && 
                        (timer_counter - rapid_access_counter < 32'h00000100)) begin
                        rapid_access_counter <= rapid_access_counter + 1;
                        
                        // 如果快速访问次数超过阈值
                        if (rapid_access_counter > 8'h10) begin
                            abnormal_detected <= 1;
                            abnormal_type <= CONSTANT_READ;
                            abnormal_addr <= tlp_addr;
                            stability_active <= (cfg_response >= 2'h2); // 中或高保障
                            stability_level <= cfg_response;
                        end
                    end else begin
                        rapid_access_counter <= 0;
                    end
                end
                
                // 检查寄存器访问计数
                for (int i = 0; i < 4; i = i + 1) begin
                    if (access_count[i] > 8'h20) begin
                        // 超过阈值，触发稳定性保障
                        abnormal_detected <= 1;
                        abnormal_type <= REGISTER_TEST;
                        stability_active <= (cfg_response != 2'h0);
                        stability_level <= cfg_response;
                    end
                end
                
                // 模式分析 - 检测重复模式
                if (history_ptr > 4'h8) begin
                    reg pattern_detected;
                    pattern_detected = 1;
                    
                    // 检查是否有4个连续的相同访问模式
                    for (int i = 0; i < 4; i = i + 1) begin
                        if (access_history[history_ptr-i-1] != access_history[history_ptr-i-5]) begin
                            pattern_detected = 0;
                        end
                    end
                    
                    if (pattern_detected && cfg_sensitivity >= 2'h2) begin // 高或极高灵敏度
                        abnormal_detected <= 1;
                        abnormal_type <= PATTERN_ANALYSIS;
                        stability_active <= (cfg_response >= 2'h1); // 低或更高保障
                        stability_level <= cfg_response;
                    end
                end
                
                // 稳定性计时器和保障级别控制
                if (stability_active) begin
                    if (stability_timer > 0) begin
                        stability_timer <= stability_timer - 1;
                    end else begin
                        // 稳定性保障超时，根据升级标志决定下一步
                        if (stability_escalating && stability_level < 2'h3) begin
                            stability_level <= stability_level + 1;
                            stability_timer <= 8'hFF;  // 延长稳定性保障时间
                        end else if (!abnormal_detected) begin
                            // 如果没有新的检测，则降低稳定性保障级别
                            stability_level <= (stability_level > 0) ? stability_level - 1 : 0;
                            stability_active <= (stability_level > 0);
                        end
                    end
                    
                    // 如果持续检测到异常，升级稳定性保障
                    if (abnormal_detected) begin
                        stability_timer <= 8'hFF;
                        stability_escalating <= 1;
                    end
                end else begin
                    stability_timer <= 0;
                    stability_escalating <= 0;
                    stability_level <= 0;
                end
                
                // 在无异常情况下，定期重置检测状态
                if (timer_counter % 32'h00010000 == 0 && !abnormal_detected) begin
                    abnormal_type <= NORMAL_ACCESS;
                    stability_escalating <= 0;
                end
            end else begin
                // 监控功能未启用
                abnormal_detected <= 0;
                stability_active <= 0;
                stability_level <= 0;
            end
        end
    end

endmodule 
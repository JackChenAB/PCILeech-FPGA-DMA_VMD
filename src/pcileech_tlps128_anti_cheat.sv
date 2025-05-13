//
// PCILeech FPGA.
//
// 反作弊检测模块 - 专用于检测和防范探测行为
// 
// 本模块实现了针对RW1C寄存器的反探测技术，能够识别常见的RW1C寄存器探测模式
// 并提供适当的防御机制以规避检测
//
// (c) Ulf Frisk, 2019-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_tlps128_anti_cheat(
    input                   rst,
    input                   clk,
    
    // PCIe TLP监控接口
    input                   tlp_valid,       // TLP有效标志
    input [31:0]            tlp_addr,        // TLP地址
    input [3:0]             tlp_type,        // TLP类型 (0=MRd, 1=MWr, 2=CfgRd, 3=CfgWr)
    input [3:0]             tlp_be,          // TLP字节使能
    input [31:0]            tlp_data,        // TLP数据
    
    // RW1C寄存器访问监控
    input [7:0]             rw1c_access_count[3:0], // 最多4个RW1C寄存器的访问计数
    
    // 检测结果输出
    output reg              cheat_detected,  // 检测到作弊工具标志
    output reg [3:0]        cheat_type,      // 作弊类型 (0=无, 1=探测, 2=回放, 3=模式分析, 4=快速交替)
    output reg [31:0]       cheat_addr,      // 发现作弊行为的地址
    
    // 防御控制
    output reg              defense_active,  // 防御机制激活标志
    output reg [1:0]        defense_level,   // 防御级别 (0=无, 1=低, 2=中, 3=高)
    
    // 配置接口
    input                   cfg_enable,      // 启用反作弊检测
    input [1:0]             cfg_sensitivity, // 检测灵敏度 (0=低, 1=中, 2=高, 3=极高)
    input [1:0]             cfg_response     // 响应模式 (0=仅记录, 1=低防御, 2=中防御, 3=高防御)
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
    
    // 特定探测模式的检测
    reg [31:0]  last_read_addr;           // 上次读取的地址
    reg [31:0]  last_write_addr;          // 上次写入的地址
    reg [31:0]  last_read_data;           // 上次读取的数据
    reg [31:0]  last_write_data;          // 上次写入的数据
    
    // 防御状态控制
    reg [7:0]   defense_timer;            // 防御计时器
    reg         defense_escalating;       // 防御升级标志
    
    // 探测模式定义
    localparam PROBE_NONE = 4'h0;             // 无探测
    localparam PROBE_RW1C_TEST = 4'h1;        // RW1C功能探测
    localparam PROBE_RAPID_TOGGLE = 4'h2;     // 快速读写切换
    localparam PROBE_WRITE_ZERO = 4'h3;       // 写0检测
    localparam PROBE_CONSTANT_READ = 4'h4;    // 恒定读取
    localparam PROBE_PATTERN_ANALYSIS = 4'h5; // 模式分析
    
    // 初始化所有内部寄存器
    initial begin
        cheat_detected = 0;
        cheat_type = 0;
        cheat_addr = 0;
        defense_active = 0;
        defense_level = 0;
        history_ptr = 0;
        pattern_length = 0;
        alternating_pattern = 0;
        rapid_access_counter = 0;
        timer_counter = 0;
        last_read_addr = 0;
        last_write_addr = 0;
        last_read_data = 0;
        last_write_data = 0;
        defense_timer = 0;
        defense_escalating = 0;
        
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
    
    // 主要检测逻辑
    always @(posedge clk) begin
        if (rst) begin
            cheat_detected <= 0;
            cheat_type <= 0;
            cheat_addr <= 0;
            defense_active <= 0;
            defense_level <= 0;
            history_ptr <= 0;
            pattern_length <= 0;
            alternating_pattern <= 0;
            rapid_access_counter <= 0;
            timer_counter <= 0;
            last_read_addr <= 0;
            last_write_addr <= 0;
            last_read_data <= 0;
            last_write_data <= 0;
            defense_timer <= 0;
            defense_escalating <= 0;
        end else begin
            // 递增计时器
            timer_counter <= timer_counter + 1;
            
            // 检测前提：启用反作弊检测
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
                        
                        // 检测写0行为 - 写0到RW1C寄存器
                        if (tlp_data == 32'h00000000 && 
                            (tlp_addr == 32'h00000004 || // 状态寄存器地址
                             tlp_addr == 32'h00000110)   // MSI-X控制寄存器地址
                           ) begin
                            if (cfg_sensitivity >= 2'h1) begin // 中或更高灵敏度
                                cheat_detected <= 1;
                                cheat_type <= PROBE_WRITE_ZERO;
                                cheat_addr <= tlp_addr;
                                defense_active <= (cfg_response != 2'h0); // 启用防御
                                defense_level <= cfg_response;
                            end
                        end
                    end
                    
                    // 更新读/写交替模式
                    alternating_pattern <= {alternating_pattern[14:0], 
                                          (tlp_type == 4'h0 || tlp_type == 4'h2) ? 1'b0 : 1'b1};
                    
                    // 检测快速读写交替模式 (0101...)
                    if (alternating_pattern == 16'h5555 || alternating_pattern == 16'hAAAA) begin
                        cheat_detected <= 1;
                        cheat_type <= PROBE_RAPID_TOGGLE;
                        cheat_addr <= tlp_addr;
                        defense_active <= (cfg_response != 2'h0); // 启用防御
                        defense_level <= cfg_response;
                    end
                    
                    // 检测快速访问行为
                    if ((last_read_addr == tlp_addr || last_write_addr == tlp_addr) && 
                        (timer_counter - rapid_access_counter < 32'h00000100)) begin
                        rapid_access_counter <= rapid_access_counter + 1;
                        
                        // 如果快速访问次数超过阈值
                        if (rapid_access_counter > 8'h10) begin
                            cheat_detected <= 1;
                            cheat_type <= PROBE_CONSTANT_READ;
                            cheat_addr <= tlp_addr;
                            defense_active <= (cfg_response >= 2'h2); // 中或高防御
                            defense_level <= cfg_response;
                        end
                    end else begin
                        rapid_access_counter <= 0;
                    end
                end
                
                // 检查RW1C寄存器访问计数
                for (int i = 0; i < 4; i = i + 1) begin
                    if (rw1c_access_count[i] > 8'h20) begin
                        // 超过阈值，触发防御
                        cheat_detected <= 1;
                        cheat_type <= PROBE_RW1C_TEST;
                        defense_active <= (cfg_response != 2'h0);
                        defense_level <= cfg_response;
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
                        cheat_detected <= 1;
                        cheat_type <= PROBE_PATTERN_ANALYSIS;
                        defense_active <= (cfg_response >= 2'h1); // 低或更高防御
                        defense_level <= cfg_response;
                    end
                end
                
                // 防御计时器和防御级别控制
                if (defense_active) begin
                    if (defense_timer > 0) begin
                        defense_timer <= defense_timer - 1;
                    end else begin
                        // 防御超时，根据升级标志决定下一步
                        if (defense_escalating && defense_level < 2'h3) begin
                            defense_level <= defense_level + 1;
                            defense_timer <= 8'hFF;  // 延长防御时间
                        end else if (!cheat_detected) begin
                            // 如果没有新的检测，则降低防御级别
                            defense_level <= (defense_level > 0) ? defense_level - 1 : 0;
                            defense_active <= (defense_level > 0);
                        end
                    end
                    
                    // 如果持续检测到威胁，升级防御
                    if (cheat_detected) begin
                        defense_timer <= 8'hFF;
                        defense_escalating <= 1;
                    end
                end else begin
                    defense_timer <= 0;
                    defense_escalating <= 0;
                    defense_level <= 0;
                }
                
                // 在无威胁情况下，定期重置检测状态
                if (timer_counter % 32'h00010000 == 0 && !cheat_detected) begin
                    cheat_type <= PROBE_NONE;
                    defense_escalating <= 0;
                end
            end else begin
                // 检测功能未启用
                cheat_detected <= 0;
                defense_active <= 0;
                defense_level <= 0;
            end
        end
    end

endmodule 
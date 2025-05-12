//
// PCILeech FPGA.
//
// PCIe BAR implementation with zero4k and stealth features for evading host detection.
//
// This module implements a 4kB writable BAR that appears as a legitimate memory region
// but has special handling to evade host detection systems. It uses the following strategies:
// 1. Returns non-zero values for reads to appear as legitimate hardware
// 2. Accepts writes but doesn't actually store most of them (appears writable)
// 3. Maintains a small set of critical registers that are actually stored
// 4. Implements timing-based access patterns to appear more like real hardware
// 5. Detects scanning behavior and dynamically adjusts response strategy
// 6. Implements intelligent pattern recognition for host detection avoidance
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
    reg [31:0]  dynamic_response_value;
    
    // 关键区域定义 - 这些区域的写入将被实际存储
    localparam CRITICAL_REGION_START = 32'h00000000;
    localparam CRITICAL_REGION_END   = 32'h0000003F; // 64字节的关键区域
    
    // 检查地址是否在关键区域内
    wire is_critical_region = (wr_addr >= CRITICAL_REGION_START) && (wr_addr <= CRITICAL_REGION_END);
    
    // 高级访问模式检测 - 用于识别可能的驱动扫描
    reg [31:0] last_access_addr;
    reg [31:0] access_pattern[15:0];  // 扩展模式记录数组 - 增加到16个元素以捕获更长的模式
    reg [3:0]  pattern_index;         // 增加位宽以匹配扩展的数组大小
    reg        sequential_access_detected;
    reg        scan_pattern_detected;
    reg        stride_pattern_detected;  // 新增：检测固定步长访问模式
    reg        random_probe_detected;    // 新增：检测随机探测模式
    reg [3:0]  consecutive_reads;
    reg [15:0] read_interval_timer;
    reg [3:0]  detection_confidence;     // 增加检测置信度位宽
    reg [31:0] pattern_frequency[4:0];   // 新增：记录常见访问模式的频率
    reg [31:0] pattern_stride;           // 新增：记录检测到的步长
    reg [7:0]  access_timing[7:0];       // 新增：记录访问时间间隔模式
    reg [2:0]  timing_index;             // 新增：时间模式索引
    reg [7:0]  timing_variance;          // 新增：时间间隔方差估计
    reg [31:0] last_access_time;         // 新增：上次访问时间戳
    reg [31:0] current_time;             // 新增：当前时间计数器
    
    // 增强的动态响应策略状态
    typedef enum {
        NORMAL,           // 正常响应模式
        CAMOUFLAGE,       // 伪装模式 - 返回看似合法的数据
        INTELLIGENT,      // 智能模式 - 根据访问模式动态调整响应
        ADAPTIVE,         // 新增：自适应模式 - 基于历史模式学习最佳响应
        DECEPTIVE,        // 新增：欺骗模式 - 主动误导扫描行为
        CHAMELEON         // 新增：变色龙模式 - 动态模拟不同设备特征
    } response_mode_t;
    
    response_mode_t current_response_mode;
    response_mode_t previous_response_mode; // 新增：记录上一个响应模式
    
    // 设备模拟类型 - 用于变色龙模式
    typedef enum {
        GENERIC_DEVICE,   // 通用设备
        NETWORK_CARD,     // 网络卡
        STORAGE_CTRL,     // 存储控制器
        GRAPHICS_CARD,    // 图形卡
        USB_CONTROLLER    // USB控制器
    } device_type_t;
    
    device_type_t current_device_type; // 当前模拟的设备类型
    reg [31:0] device_signatures[4:0]; // 设备特征签名
    
    // 初始化
    initial begin
        access_counter = 8'h00;
        stealth_mode_active = 1'b1; // 默认启用隐身模式
        sequential_access_detected = 1'b0;
        scan_pattern_detected = 1'b0;
        stride_pattern_detected = 1'b0;
        random_probe_detected = 1'b0;
        pattern_index = 4'b0000;
        timing_index = 3'b000;
        last_access_addr = 32'h0;
        last_read_addr = 32'h0;
        consecutive_reads = 4'h0;
        read_interval_timer = 16'h0;
        detection_confidence = 4'h0;
        current_response_mode = INTELLIGENT; // 默认使用智能响应模式
        previous_response_mode = INTELLIGENT;
        dynamic_response_value = 32'h12345678; // 初始动态响应值
        current_time = 32'h0;
        last_access_time = 32'h0;
        timing_variance = 8'h0;
        pattern_stride = 32'h0;
        current_device_type = GENERIC_DEVICE;
        
        // 初始化访问模式数组
        for(int i = 0; i < 16; i++) begin
            access_pattern[i] = 32'h0;
        end
        
        // 初始化访问时间间隔数组
        for(int i = 0; i < 8; i++) begin
            access_timing[i] = 8'h0;
        end
        
        // 初始化模式频率数组
        for(int i = 0; i < 5; i++) begin
            pattern_frequency[i] = 32'h0;
        end
        
        // 初始化设备签名
        device_signatures[0] = 32'h8086_1000; // 通用设备
        device_signatures[1] = 32'h8086_1502; // 网络卡
        device_signatures[2] = 32'h8086_2822; // 存储控制器
        device_signatures[3] = 32'h10DE_1180; // 图形卡
        device_signatures[4] = 32'h8086_1E31; // USB控制器
    end
    
    // 高级访问模式检测逻辑 - 机器学习启发的模式识别
    always @(posedge clk) begin
        if(rst) begin
            sequential_access_detected <= 1'b0;
            scan_pattern_detected <= 1'b0;
            stride_pattern_detected <= 1'b0;
            random_probe_detected <= 1'b0;
            pattern_index <= 4'b0000;
            timing_index <= 3'b000;
            consecutive_reads <= 4'h0;
            detection_confidence <= 4'h0;
            current_response_mode <= INTELLIGENT;
            previous_response_mode <= INTELLIGENT;
            current_time <= 32'h0;
            pattern_stride <= 32'h0;
        end
        else begin
            // 时间计数器更新
            current_time <= current_time + 1'b1;
            
            // 计时器逻辑 - 用于检测访问频率
            if(read_interval_timer > 0)
                read_interval_timer <= read_interval_timer - 1'b1;
                
            if(rd_req_valid) begin
                // 记录访问模式和时间间隔
                access_pattern[pattern_index] <= rd_req_addr;
                pattern_index <= pattern_index + 1'b1;
                
                // 计算并记录访问时间间隔
                if(last_access_time > 0) begin
                    access_timing[timing_index] <= (current_time - last_access_time)[7:0];
                    timing_index <= timing_index + 1'b1;
                    
                    // 计算时间间隔方差 - 简化版
                    if(timing_index > 1) begin
                        reg [7:0] avg_timing = (access_timing[timing_index-1] + access_timing[timing_index-2]) >> 1;
                        reg [7:0] diff = (access_timing[timing_index-1] > avg_timing) ? 
                                         (access_timing[timing_index-1] - avg_timing) : 
                                         (avg_timing - access_timing[timing_index-1]);
                        timing_variance <= (timing_variance + diff) >> 1; // 简单平滑
                    end
                end
                last_access_time <= current_time;
                
                // 更新读取计数器和计时器
                if(read_interval_timer > 0) begin
                    consecutive_reads <= consecutive_reads + 1'b1;
                end else begin
                    consecutive_reads <= 4'h1; // 重置连续读取计数
                end
                read_interval_timer <= 16'd1000; // 设置超时窗口
                
                // 高级模式检测 - 步长分析
                if(pattern_index > 1) begin
                    reg [31:0] current_stride = rd_req_addr - last_access_addr;
                    
                    // 检测固定步长模式
                    if(pattern_stride == 0) begin
                        pattern_stride <= current_stride; // 初始化步长
                    end else if(current_stride == pattern_stride) begin
                        // 连续相同步长 - 可能是扫描
                        stride_pattern_detected <= 1'b1;
                        if(detection_confidence < 15)
                            detection_confidence <= detection_confidence + 1'b1;
                            
                        // 更新模式频率计数
                        if(current_stride == 4)
                            pattern_frequency[0] <= pattern_frequency[0] + 1'b1; // 4字节步长
                        else if(current_stride == 8)
                            pattern_frequency[1] <= pattern_frequency[1] + 1'b1; // 8字节步长
                        else if(current_stride == 16)
                            pattern_frequency[2] <= pattern_frequency[2] + 1'b1; // 16字节步长
                        else if(current_stride == 32)
                            pattern_frequency[3] <= pattern_frequency[3] + 1'b1; // 32字节步长
                        else
                            pattern_frequency[4] <= pattern_frequency[4] + 1'b1; // 其他步长
                    end else begin
                        // 步长变化 - 可能是随机访问或不同的扫描模式
                        if(detection_confidence > 0)
                            detection_confidence <= detection_confidence - 1'b1;
                            
                        // 检测随机探测模式 - 大跳跃且无规律
                        if(current_stride > 256 && timing_variance < 10) begin
                            random_probe_detected <= 1'b1;
                        end
                        
                        // 更新步长
                        pattern_stride <= current_stride;
                    end
                }
                
                // 检测连续访问模式（可能是扫描）
                if(rd_req_addr == last_access_addr + 4 || rd_req_addr == last_access_addr + 8) begin
                    sequential_access_detected <= 1'b1;
                    if(detection_confidence < 15)
                        detection_confidence <= detection_confidence + 1'b1;
                end
                else if(rd_req_addr < last_access_addr || rd_req_addr > last_access_addr + 64) begin
                    if(detection_confidence > 0)
                        detection_confidence <= detection_confidence - 1'b1;
                    else
                        sequential_access_detected <= 1'b0;
                end
                
                // 检测特定的扫描模式 - 例如4KB页面扫描
                if(consecutive_reads >= 8) begin
                    scan_pattern_detected <= 1'b1;
                end
                
                // 自适应响应模式选择 - 基于多种检测结果和置信度
                previous_response_mode <= current_response_mode; // 保存上一个模式
                
                if(scan_pattern_detected && random_probe_detected) begin
                    // 检测到高级扫描 - 使用欺骗模式
                    current_response_mode <= DECEPTIVE;
                end
                else if(scan_pattern_detected || (sequential_access_detected && detection_confidence >= 8)) begin
                    // 检测到常规扫描 - 使用伪装模式
                    current_response_mode <= CAMOUFLAGE;
                }
                else if(stride_pattern_detected && detection_confidence >= 5) begin
                    // 检测到固定步长访问 - 使用变色龙模式
                    current_response_mode <= CHAMELEON;
                    
                    // 根据访问模式动态选择设备类型
                    if(pattern_frequency[1] > pattern_frequency[0] && 
                       pattern_frequency[1] > pattern_frequency[2]) begin
                        // 8字节步长访问最多 - 模拟存储控制器
                        current_device_type <= STORAGE_CTRL;
                    end
                    else if(pattern_frequency[2] > pattern_frequency[0] && 
                            pattern_frequency[2] > pattern_frequency[1]) begin
                        // 16字节步长访问最多 - 模拟网络卡
                        current_device_type <= NETWORK_CARD;
                    end
                    else if(pattern_frequency[3] > pattern_frequency[0]) begin
                        // 32字节步长访问较多 - 模拟图形卡
                        current_device_type <= GRAPHICS_CARD;
                    end
                    else begin
                        // 其他模式 - 模拟USB控制器
                        current_device_type <= USB_CONTROLLER;
                    end
                }
                else if(detection_confidence >= 3) begin
                    // 中等置信度 - 使用自适应模式
                    current_response_mode <= ADAPTIVE;
                }
                else if(detection_confidence > 0) begin
                    // 低置信度 - 使用智能模式
                    current_response_mode <= INTELLIGENT;
                }
                else begin
                    // 无检测 - 使用正常模式
                    current_response_mode <= NORMAL;
                }
                
                last_access_addr <= rd_req_addr;
                
                // 增强的动态响应值生成 - 基于多种因素
                dynamic_response_value <= {rd_req_addr[7:0], rd_req_addr[15:8], 8'hA5, 8'h5A} ^ 
                                         (access_counter << 8) ^ 
                                         {8'h00, timing_variance, 8'h00, detection_confidence[3:0], 4'h0};
            end else if(read_interval_timer == 0 && consecutive_reads > 0) begin
                // 超时后重置连续读取计数
                consecutive_reads <= 4'h0;
                if(scan_pattern_detected) begin
                    scan_pattern_detected <= 1'b0;
                    // 扫描结束后保持一段时间的伪装模式
                    if(detection_confidence > 2)
                        detection_confidence <= detection_confidence - 1'b1;
                end
                
                // 超时后逐渐降低其他检测标志
                if(stride_pattern_detected && current_time[10]) begin // 周期性检查
                    stride_pattern_detected <= 1'b0;
                end
                
                if(random_probe_detected && current_time[11]) begin // 周期性检查
                    random_probe_detected <= 1'b0;
                end
            end
        end
    end
    
    // 高级读取请求处理 - 多层次防御响应策略
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
        
        // 根据当前响应模式和检测到的访问模式调整响应策略
        case(current_response_mode)
            NORMAL: begin
                // 正常模式 - 返回BRAM中的数据
                // 对于非关键区域，返回非零但看似合法的数据
                if(rd_req_addr >= CRITICAL_REGION_START && rd_req_addr <= CRITICAL_REGION_END) begin
                    rd_rsp_data <= doutb; // 关键区域返回实际存储的数据
                end else begin
                    // 生成看似合法的设备寄存器值
                    rd_rsp_data <= 32'h01000200 ^ {rd_req_addr[7:0], 8'h00, rd_req_addr[15:8], 8'h00};
                end
            end
            
            CAMOUFLAGE: begin
                // 伪装模式 - 返回看起来合法但实际上是伪造的数据
                // 这种模式专门用于应对扫描检测
                if(rd_req_addr[11:8] == 4'h0) begin
                    // 配置空间样式的响应
                    rd_rsp_data <= 32'h82571000 ^ {rd_req_addr[7:0], rd_req_addr[15:8], 16'h0000};
                end else begin
                    // 内存映射IO样式的响应
                    rd_rsp_data <= dynamic_response_value ^ {16'h0000, rd_req_addr[7:0], rd_req_addr[15:8]};
                end
            end
            
            INTELLIGENT: begin
                // 智能模式 - 根据访问模式和地址动态调整响应
                if(rd_req_addr >= CRITICAL_REGION_START && rd_req_addr <= CRITICAL_REGION_END) begin
                    rd_rsp_data <= doutb; // 关键区域返回实际数据
                end else if(sequential_access_detected) begin
                    // 对于连续访问，返回看似相关但不完全可预测的值
                    rd_rsp_data <= {rd_req_addr[15:0], access_counter, 8'hA5};
                end else begin
                    // 对于随机访问，返回看似合法的设备寄存器值
                    rd_rsp_data <= dynamic_response_value;
                end
            end
            
            ADAPTIVE: begin
                // 自适应模式 - 基于历史模式学习最佳响应
                // 分析历史访问模式，动态选择最佳响应策略
                if(rd_req_addr >= CRITICAL_REGION_START && rd_req_addr <= CRITICAL_REGION_END) begin
                    rd_rsp_data <= doutb; // 关键区域返回实际数据
                end
                else if(pattern_index >= 8) begin
                    // 有足够的历史数据进行模式分析
                    reg [31:0] predicted_value;
                    reg [31:0] pattern_sum = 0;
                    reg [2:0] i;
                    
                    // 简单的模式预测 - 基于历史访问的平均值和趋势
                    for(i = 0; i < 4; i = i + 1) begin
                        pattern_sum = pattern_sum + access_pattern[pattern_index-1-i];
                    end
                    
                    // 生成预测值 - 看起来像是合理的后续值
                    predicted_value = (pattern_sum >> 2) + (rd_req_addr & 32'h000000FF);
                    
                    // 返回看似符合预期的值，但实际上是动态生成的
                    rd_rsp_data <= predicted_value ^ (dynamic_response_value & 32'hFFFF0000);
                end
                else begin
                    // 历史数据不足，使用智能模式的策略
                    if(sequential_access_detected) begin
                        rd_rsp_data <= {rd_req_addr[15:0], access_counter, 8'hA5};
                    end else begin
                        rd_rsp_data <= dynamic_response_value;
                    end
                end
            end
            
            DECEPTIVE: begin
                // 欺骗模式 - 主动误导扫描行为
                // 这种模式返回看似有问题或不一致的数据，以误导扫描工具
                if(rd_req_addr >= CRITICAL_REGION_START && rd_req_addr <= CRITICAL_REGION_END) begin
                    rd_rsp_data <= doutb; // 关键区域返回实际数据
                end
                else if(rd_req_addr[1:0] == 2'b00) begin
                    // 对齐的地址返回看似正常的值
                    rd_rsp_data <= 32'hA5A5A5A5;
                end
                else if(rd_req_addr[1:0] == 2'b01) begin
                    // 未对齐地址返回全0（看似未初始化）
                    rd_rsp_data <= 32'h00000000;
                end
                else if(rd_req_addr[1:0] == 2'b10) begin
                    // 未对齐地址返回全1（看似无效）
                    rd_rsp_data <= 32'hFFFFFFFF;
                end
                else begin
                    // 其他地址返回看似错误的值
                    rd_rsp_data <= 32'hDEADC0DE;
                end
            end
            
            CHAMELEON: begin
                // 变色龙模式 - 动态模拟不同设备特征
                // 根据当前选择的设备类型返回特定的设备特征数据
                if(rd_req_addr >= CRITICAL_REGION_START && rd_req_addr <= CRITICAL_REGION_END) begin
                    rd_rsp_data <= doutb; // 关键区域返回实际数据
                end
                else begin
                    case(current_device_type)
                        GENERIC_DEVICE: begin
                            // 通用设备特征
                            if(rd_req_addr[11:8] == 4'h0) begin
                                // 配置空间区域
                                rd_rsp_data <= device_signatures[0] ^ {rd_req_addr[7:0], rd_req_addr[15:8], 16'h0000};
                            end else begin
                                // 其他区域
                                rd_rsp_data <= 32'h01020304 ^ {rd_req_addr[7:0], 8'h00, rd_req_addr[15:8], 8'h00};
                            end
                        end
                        
                        NETWORK_CARD: begin
                            // 网络卡特征
                            if(rd_req_addr[11:8] == 4'h0) begin
                                // 配置空间区域
                                rd_rsp_data <= device_signatures[1] ^ {rd_req_addr[7:0], rd_req_addr[15:8], 16'h0000};
                            end
                            else if(rd_req_addr[7:0] == 8'h00) begin
                                // 控制寄存器区域
                                rd_rsp_data <= 32'h00450000 | (access_counter & 32'h000000FF);
                            end
                            else if(rd_req_addr[7:0] == 8'h08) begin
                                // 状态寄存器区域
                                rd_rsp_data <= 32'h80000080;
                            end
                            else begin
                                // 其他区域
                                rd_rsp_data <= 32'h00000000;
                            end
                        end
                        
                        STORAGE_CTRL: begin
                            // 存储控制器特征
                            if(rd_req_addr[11:8] == 4'h0) begin
                                // 配置空间区域
                                rd_rsp_data <= device_signatures[2] ^ {rd_req_addr[7:0], rd_req_addr[15:8], 16'h0000};
                            end
                            else if(rd_req_addr[7:0] < 8'h20) begin
                                // 控制寄存器区域
                                rd_rsp_data <= 32'h01000000 | (rd_req_addr[7:0] << 16);
                            end
                            else begin
                                // 数据区域
                                rd_rsp_data <= dynamic_response_value;
                            end
                        end
                        
                        GRAPHICS_CARD: begin
                            // 图形卡特征
                            if(rd_req_addr[11:8] == 4'h0) begin
                                // 配置空间区域
                                rd_rsp_data <= device_signatures[3] ^ {rd_req_addr[7:0], rd_req_addr[15:8], 16'h0000};
                            end
                            else if(rd_req_addr[10:8] == 3'b000) begin
                                // 显存区域
                                rd_rsp_data <= 32'hCCCCCCCC;
                            end
                            else begin
                                // 寄存器区域
                                rd_rsp_data <= 32'h10DE0000 | (rd_req_addr[7:0] << 8);
                            end
                        end
                        
                        USB_CONTROLLER: begin
                            // USB控制器特征
                            if(rd_req_addr[11:8] == 4'h0) begin
                                // 配置空间区域
                                rd_rsp_data <= device_signatures[4] ^ {rd_req_addr[7:0], rd_req_addr[15:8], 16'h0000};
                            end
                            else if(rd_req_addr[7:4] == 4'h0) begin
                                // 操作寄存器区域
                                rd_rsp_data <= 32'h00010000 | (access_counter & 32'h0000FFFF);
                            end
                            else begin
                                // 其他区域
                                rd_rsp_data <= 32'h00000000;
                            end
                        end
                        
                        default: begin
                            // 默认为通用设备
                            rd_rsp_data <= device_signatures[0] ^ {rd_req_addr[7:0], rd_req_addr[15:8], 16'h0000};
                        end
                    endcase
                end
            end
            
            default: begin
                // 默认情况下返回BRAM中的数据
                rd_rsp_data <= doutb;
            end
        endcase
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
//
// PCILeech FPGA.
//
// PCIe BDF (Bus-Device-Function) 路由器模块
// 实现高级路由策略，支持多功能设备和虚拟功能
//
// (c) Ulf Frisk, 2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_bdf_router(
    input                   rst,
    input                   clk_pcie,
    
    // 输入 TLP 流
    IfAXIS128.sink          tlps_in,
    IfAXIS128.source        tlps_out,
    
    // BDF配置接口
    input [7:0]             pcie_bus_number,     // 当前PCIe总线号
    input [4:0]             pcie_device_number,  // 当前PCIe设备号
    input [2:0]             primary_function,    // 主功能号
    input [7:0]             function_mask,       // 功能掩码 - 表示哪些功能是活动的
    input [7:0]             function_count,      // 功能计数
    
    // 路由策略接口
    input [1:0]             routing_policy,      // 路由策略：0=直通，1=轮询，2=负载均衡，3=自适应
    input                   routing_enabled,     // 路由使能
    
    // 负载监控接口
    output [7:0]            func_load[0:7],      // 每个功能的负载统计
    output [2:0]            active_function,     // 当前活动功能
    
    // 虚拟功能接口
    input                   vf_enabled,          // 虚拟功能使能
    input [4:0]             vf_count,            // 虚拟功能数量
    input [15:0]            vf_offset,           // 虚拟功能偏移
    
    // 状态和调试接口
    output [31:0]           access_stats[0:7],   // 每个功能的访问统计
    output [1:0]            routing_state        // 路由状态：0=正常，1=切换中，2=故障，3=恢复
);

    // BDF路由表和状态寄存器
    reg [7:0]  bdf_routing_table[0:255];       // 完整BDF路由表
    reg [2:0]  function_table[0:7];            // 功能映射表
    reg [7:0]  function_access_counter[0:7];   // 功能访问计数器
    reg [31:0] function_total_access[0:7];     // 功能总访问计数
    reg [7:0]  load_distribution[0:7];         // 负载分布表
    reg [2:0]  current_function;               // 当前路由功能
    reg [1:0]  router_state;                   // 路由器状态
    
    // 路由控制寄存器
    reg [7:0]  route_timeout_counter;          // 路由超时计数器
    reg [7:0]  function_availability;          // 功能可用性表
    reg [7:0]  function_health[0:7];           // 功能健康状态
    reg [7:0]  active_func_mask;               // 活动功能掩码
    
    // 高级路由功能
    reg [15:0] traffic_pattern_history;        // 流量模式历史
    reg [7:0]  traffic_intensity;              // 流量强度指标
    reg [15:0] error_counter;                  // 错误计数器
    reg [2:0]  last_routed_function;           // 上次路由的功能
    reg        function_switch_in_progress;    // 功能切换进行中
    
    // TLP解析变量
    wire [6:0]  tlp_fmt_type = tlps_in.tdata[30:24];
    wire [2:0]  tlp_func     = tlps_in.tdata[78:76];
    wire [4:0]  tlp_dev      = tlps_in.tdata[83:79];
    wire [7:0]  tlp_bus      = tlps_in.tdata[91:84];
    wire        tlp_is_cfg   = (tlp_fmt_type[6:3] == 4'b0001); // 配置请求
    wire        tlp_is_valid = tlps_in.tvalid && tlps_in.tuser[0];
    
    // 输出赋值
    assign active_function = current_function;
    assign routing_state = router_state;
    
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : gen_func_output
            assign func_load[i] = load_distribution[i];
            assign access_stats[i] = function_total_access[i];
        end
    endgenerate
    
    // 初始化路由表和状态寄存器
    integer j;
    initial begin
        // 初始化路由表
        for (j = 0; j < 256; j = j + 1) begin
            bdf_routing_table[j] = j[7:0];
        end
        
        // 初始化功能映射表
        for (j = 0; j < 8; j = j + 1) begin
            function_table[j] = j[2:0];
            function_access_counter[j] = 8'h00;
            function_total_access[j] = 32'h00000000;
            load_distribution[j] = 8'h00;
            function_health[j] = 8'hFF; // 初始为满健康状态
        end
        
        // 初始化路由控制
        current_function = 3'h0;
        router_state = 2'b00;
        route_timeout_counter = 8'h00;
        function_availability = function_mask;
        active_func_mask = function_mask;
        last_routed_function = 3'h0;
        
        // 初始化高级路由功能
        traffic_pattern_history = 16'h0000;
        traffic_intensity = 8'h00;
        error_counter = 16'h0000;
        function_switch_in_progress = 1'b0;
    end
    
    // 负载监控 - 计算每个功能的负载百分比
    always @(posedge clk_pcie) begin
        if (rst) begin
            for (int i = 0; i < 8; i = i + 1) begin
                load_distribution[i] <= 8'h00;
            end
            traffic_intensity <= 8'h00;
        end else begin
            // 计算总访问次数
            reg [31:0] total_accesses = 0;
            for (int i = 0; i < 8; i = i + 1) begin
                if (function_availability[i]) begin
                    total_accesses = total_accesses + function_access_counter[i];
                end
            end
            
            // 更新负载分布
            for (int i = 0; i < 8; i = i + 1) begin
                if (total_accesses > 0 && function_availability[i]) begin
                    // 计算百分比 (简化为0-100)
                    load_distribution[i] <= (function_access_counter[i] * 100) / total_accesses;
                end else begin
                    load_distribution[i] <= 8'h00;
                end
            end
            
            // 更新流量强度指标
            if (tlp_is_valid) begin
                if (traffic_intensity < 8'hFF) begin
                    traffic_intensity <= traffic_intensity + 1'b1;
                end
            end else if (traffic_intensity > 0) begin
                traffic_intensity <= traffic_intensity - 1'b1;
            end
        end
    end
    
    // BDF路由逻辑 - 基于不同策略决定路由目标
    always @(posedge clk_pcie) begin
        if (rst) begin
            current_function <= primary_function;
            router_state <= 2'b00;
            route_timeout_counter <= 8'h00;
            function_switch_in_progress <= 1'b0;
            function_availability <= function_mask;
            active_func_mask <= function_mask;
            last_routed_function <= primary_function;
            
            // 重置访问计数器
            for (int i = 0; i < 8; i = i + 1) begin
                function_access_counter[i] <= 8'h00;
            end
        end else begin
            // 处理路由超时
            if (route_timeout_counter > 0) begin
                route_timeout_counter <= route_timeout_counter - 1'b1;
            end
            
            // 功能切换处理
            if (function_switch_in_progress) begin
                if (route_timeout_counter == 0) begin
                    function_switch_in_progress <= 1'b0;
                    router_state <= 2'b00; // 恢复正常状态
                end
            end
            
            // 基于流量更新功能健康状态
            if (tlp_is_valid && tlp_is_cfg) begin
                // 只跟踪配置请求的功能健康
                reg [2:0] target_func = tlp_func;
                
                // 更新访问计数器
                if (function_access_counter[target_func] < 8'hFF) begin
                    function_access_counter[target_func] <= function_access_counter[target_func] + 1'b1;
                end
                
                // 更新总访问统计
                function_total_access[target_func] <= function_total_access[target_func] + 1'b1;
                
                // 记录访问历史
                traffic_pattern_history <= {traffic_pattern_history[14:0], 1'b1};
                
                // 访问提升健康度
                if (function_health[target_func] < 8'hFF) begin
                    function_health[target_func] <= function_health[target_func] + 1'b1;
                end
            end else begin
                traffic_pattern_history <= {traffic_pattern_history[14:0], 1'b0};
            end
            
            // 周期性重置访问计数器以防溢出
            if (&traffic_pattern_history) begin
                for (int i = 0; i < 8; i = i + 1) begin
                    function_access_counter[i] <= 8'h00;
                end
            end
            
            // 根据路由策略更新当前功能
            if (routing_enabled && !function_switch_in_progress) begin
                case (routing_policy)
                    2'b00: begin // 直通路由 - 使用主功能
                        current_function <= primary_function;
                    end
                    
                    2'b01: begin // 轮询路由
                        if (tlp_is_valid && route_timeout_counter == 0) begin
                            // 寻找下一个可用功能
                            reg [2:0] next_func = current_function;
                            reg found_next = 0;
                            
                            for (int i = 1; i <= function_count; i = i + 1) begin
                                reg [2:0] try_func = (current_function + i) % function_count;
                                if (function_availability[try_func]) begin
                                    next_func = try_func;
                                    found_next = 1;
                                    break;
                                end
                            end
                            
                            if (found_next) begin
                                last_routed_function <= current_function;
                                current_function <= next_func;
                                function_switch_in_progress <= 1'b1;
                                route_timeout_counter <= 8'h10; // 设置切换冷却时间
                                router_state <= 2'b01; // 切换状态
                            end
                        end
                    end
                    
                    2'b10: begin // 负载均衡路由
                        if ((traffic_intensity > 8'h80) && (route_timeout_counter == 0)) begin
                            // 高流量时触发负载均衡
                            reg [7:0] min_load = 8'hFF;
                            reg [2:0] min_load_func = current_function;
                            reg found_better = 0;
                            
                            for (int i = 0; i < function_count; i = i + 1) begin
                                if (function_availability[i] && (load_distribution[i] < min_load)) begin
                                    min_load = load_distribution[i];
                                    min_load_func = i[2:0];
                                    found_better = 1;
                                end
                            end
                            
                            if (found_better && (min_load_func != current_function)) begin
                                last_routed_function <= current_function;
                                current_function <= min_load_func;
                                function_switch_in_progress <= 1'b1;
                                route_timeout_counter <= 8'h20; // 较长的冷却时间
                                router_state <= 2'b01; // 切换状态
                            end
                        end
                    end
                    
                    2'b11: begin // 自适应路由
                        // 根据功能健康状态动态调整
                        if ((function_health[current_function] < 8'h80) && (route_timeout_counter == 0)) begin
                            // 当前功能健康度低，尝试切换
                            reg [7:0] max_health = function_health[current_function];
                            reg [2:0] max_health_func = current_function;
                            reg found_healthier = 0;
                            
                            for (int i = 0; i < function_count; i = i + 1) begin
                                if (function_availability[i] && (function_health[i] > max_health)) begin
                                    max_health = function_health[i];
                                    max_health_func = i[2:0];
                                    found_healthier = 1;
                                end
                            end
                            
                            if (found_healthier && (max_health_func != current_function)) begin
                                last_routed_function <= current_function;
                                current_function <= max_health_func;
                                function_switch_in_progress <= 1'b1;
                                route_timeout_counter <= 8'h30; // 更长的冷却时间
                                router_state <= 2'b01; // 切换状态
                            end
                        end
                    end
                endcase
            end
        end
    end
    
    // TLP路由 - 修改TLP报文中的BDF信息
    reg  [127:0] tlp_data_out;
    reg  [15:0]  tlp_keep_out;
    reg          tlp_valid_out;
    reg          tlp_last_out;
    reg  [31:0]  tlp_user_out;
    
    always @(posedge clk_pcie) begin
        if (rst) begin
            tlp_data_out <= 128'h0;
            tlp_keep_out <= 16'h0;
            tlp_valid_out <= 1'b0;
            tlp_last_out <= 1'b0;
            tlp_user_out <= 32'h0;
        end else begin
            tlp_keep_out <= tlps_in.tkeep;
            tlp_last_out <= tlps_in.tlast;
            tlp_user_out <= tlps_in.tuser;
            
            if (tlps_in.tvalid) begin
                tlp_valid_out <= 1'b1;
                
                // 对配置请求进行处理 - 修改BDF字段
                if (tlp_is_cfg && routing_enabled) begin
                    // 修改目标功能号为当前路由功能
                    tlp_data_out <= {
                        tlps_in.tdata[127:79],  // 保留高位
                        current_function,       // 替换功能号
                        tlps_in.tdata[75:0]     // 保留低位
                    };
                end else begin
                    // 非配置请求或路由禁用时直接传递
                    tlp_data_out <= tlps_in.tdata;
                end
            end else begin
                tlp_valid_out <= 1'b0;
            end
        end
    end
    
    // 输出连接
    assign tlps_out.tdata  = tlp_data_out;
    assign tlps_out.tkeep  = tlp_keep_out;
    assign tlps_out.tvalid = tlp_valid_out;
    assign tlps_out.tlast  = tlp_last_out;
    assign tlps_out.tuser  = tlp_user_out;
    assign tlps_in.tready  = tlps_out.tready;  // 直接传递反压信号

endmodule 
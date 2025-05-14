//
// PCILeech FPGA.
//
// 多功能控制器模块 - 处理VMD和NVMe端点配置空间
//
// (c) Ulf Frisk, 2021-2024
// Author: Ulf Frisk, pcileech@frizk.net
// Modified: <项目维护者>
//

`timescale 1ns / 1ps

`include "pcileech_header.svh"

module pcileech_tlps128_multifunc_controller(
    input                   rst,
    input                   clk_pcie,
    input                   clk_sys,
    IfAXIS128.sink_lite     tlps_in,      // PCIe TLP输入
    input [15:0]            pcie_id,      // PCIe ID
    IfAXIS128.source        tlps_cfg_rsp, // PCIe配置空间响应
    
    // 设备配置参数
    input  [7:0]            function_count,     // 功能数量配置 (1-8)
    input  [7:0]            device_class,       // 设备类别代码
    input  [7:0]            device_subclass,    // 设备子类别代码
    input  [7:0]            device_interface,   // 设备接口代码
    input  [15:0]           device_id,          // 设备ID
    input  [15:0]           vendor_id,          // 厂商ID
    
    // BAR空间地址配置
    input  [31:0]           bar0_base_addr,
    input  [31:0]           bar1_base_addr,
    input  [31:0]           bar2_base_addr,
    
    // 来自PCIe核心的配置数据
    input  [7:0]            pcie_bus_number,
    input  [4:0]            pcie_device_number,
    input  [2:0]            pcie_function_number,
    
    // BDF路由控制接口
    input  [7:0]           max_functions,       // 最大支持的功能数
    input  [2:0]           active_function_id,  // 当前活跃功能ID
    output [2:0]           current_function_out, // 输出当前功能ID
    
    // 多功能路由状态接口
    output [7:0]           function_status,     // 功能状态输出
    output reg             function_change_pending, // 功能切换挂起
    
    // 中断路由接口
    input                  msix_valid_in,      // MSI-X中断有效输入
    input  [63:0]          msix_addr_in,       // MSI-X中断地址输入
    input  [31:0]          msix_data_in,       // MSI-X中断数据输入
    output                 msix_valid_out,     // MSI-X中断有效输出
    output [63:0]          msix_addr_out,      // MSI-X中断地址输出
    output [31:0]          msix_data_out,      // MSI-X中断数据输出
    output [2:0]           msix_source_func,   // 中断源功能ID
    
    // 调试和状态输出
    output [31:0]           debug_status,
    
    // 与其他模块的接口
    IfShadow2Fifo.shadow    dshadow2fifo
);

    // 多功能配置相关寄存器
    reg [2:0]  current_function;        // 当前活动的功能ID
    reg [7:0]  active_function_mask;    // 活动功能掩码
    reg [31:0] access_counter;          // 访问计数器
    reg [31:0] function_access_stats [0:7]; // 各功能访问统计
    
    // BDF路由相关寄存器
    reg [7:0]  routing_table[0:7]; // 路由表 - 存储目标功能映射
    reg [7:0]  function_access_mask;  // 功能访问控制掩码
    reg [7:0]  function_enable_status; // 功能启用状态
    reg [7:0]  function_ready_status;  // 功能就绪状态
    reg [2:0]  function_route_target;  // 当前路由目标功能
    
    // 功能状态转换追踪
    reg [2:0]  previous_function;     // 上一个活动功能
    reg [7:0]  function_switch_counter; // 功能切换计数器
    reg        function_switch_in_progress; // 功能切换进行中标志
    
    // BDF路由策略控制
    reg [1:0]  routing_policy;        // 路由策略： 0=固定, 1=轮询, 2=负载均衡, 3=主/备
    reg [7:0]  load_balance_counter;  // 负载均衡计数器
    reg [2:0]  primary_function_id;   // 主功能ID (用于主/备模式)
    reg [2:0]  backup_function_id;    // 备份功能ID (用于主/备模式)
    reg        use_backup_function;   // 使用备份功能标志
    
    // 中断路由控制
    reg        interrupt_routing_enable; // 中断路由使能
    reg [7:0]  interrupt_route_mask;    // 中断路由掩码
    reg [2:0]  last_interrupt_function; // 上次中断功能ID
    
    // 功能优先级
    reg [2:0]  function_priority[0:7]; // 每个功能的优先级
    
    // 初始化多功能配置
    initial begin
        current_function = 3'h0;  // 默认为功能0 (VMD控制器)
        active_function_mask = 8'h01;  // 默认只激活功能0
        
        // 根据配置参数设置功能掩码
        if (function_count > 1) begin
            active_function_mask = (8'h01 << function_count) - 1;
        end
        
        access_counter = 32'h0;
        for (int i = 0; i < 8; i++) begin
            function_access_stats[i] = 32'h0;
        end
        
        // BDF路由相关寄存器初始化
        for (int i = 0; i < 8; i++) begin
            routing_table[i] = i;    // 默认直通路由
            function_priority[i] = 3'h7 - i; // 默认优先级
        end
        function_access_mask = 8'hFF;  // 默认允许访问所有功能
        function_enable_status = 8'h01; // 默认只启用功能0
        function_ready_status = 8'h01;  // 默认只有功能0就绪
        function_route_target = 3'h0;   // 默认路由到功能0
        
        // 功能状态转换追踪初始化
        previous_function = 3'h0;
        function_switch_counter = 8'h00;
        function_switch_in_progress = 1'b0;
        function_change_pending = 1'b0;
        
        // BDF路由策略控制初始化
        routing_policy = 2'b00;        // 默认使用固定路由
        load_balance_counter = 8'h00;
        primary_function_id = 3'h0;    // 功能0为主功能
        backup_function_id = 3'h1;     // 功能1为备份功能
        use_backup_function = 1'b0;    // 默认使用主功能
        
        // 中断路由控制初始化
        interrupt_routing_enable = 1'b0; // 默认禁用中断路由
        interrupt_route_mask = 8'h01;    // 默认只路由功能0中断
        last_interrupt_function = 3'h0;  // 初始化上次中断功能
    end
    
    // 从TLP提取的请求信息
    wire                pcie_rx_valid   = tlps_in.tvalid && tlps_in.tuser[0];
    wire                pcie_rx_rden    = pcie_rx_valid && (tlps_in.tdata[31:25] == 7'b0000010);  // CfgRd
    wire                pcie_rx_wren    = pcie_rx_valid && (tlps_in.tdata[31:25] == 7'b0100010);  // CfgWr
    wire [9:0]          pcie_rx_addr    = tlps_in.tdata[75:66];
    wire [2:0]          pcie_rx_func    = tlps_in.tdata[78:76];  // 目标功能号
    wire [7:0]          pcie_rx_tag     = tlps_in.tdata[47:40];
    wire [15:0]         pcie_rx_reqid   = tlps_in.tdata[63:48];
    wire [31:0]         pcie_rx_data    = tlps_in.tdata[127:96];
    
    // 使用正确的方式从第一个字节提取字节使能信号
    reg [3:0]          pcie_rx_be;
    always @(*) begin
        pcie_rx_be[0] = tlps_in.tdata[32];
        pcie_rx_be[1] = tlps_in.tdata[33];
        pcie_rx_be[2] = tlps_in.tdata[34];
        pcie_rx_be[3] = tlps_in.tdata[35];
    end
    
    // 地址有效性检查
    wire                pcie_rx_addr_valid = (pcie_rx_addr < 10'h400) && (pcie_rx_addr[1:0] == 2'b00);
    
    // 功能有效性检查
    wire                pcie_rx_func_valid = (active_function_mask & (8'h01 << pcie_rx_func)) != 8'h00;
    
    // 完整的请求有效性
    wire                pcie_rx_req_valid = pcie_rx_valid && pcie_rx_addr_valid && pcie_rx_func_valid;
    
    // 动态更新当前功能号
    always @(posedge clk_pcie) begin
        if (rst) begin
            current_function <= 3'h0;
            access_counter <= 32'h0;
        end else if (pcie_rx_req_valid) begin
            // 更新当前活动功能
            current_function <= pcie_rx_func;
            
            // 更新访问统计
            access_counter <= access_counter + 1;
            function_access_stats[pcie_rx_func] <= function_access_stats[pcie_rx_func] + 1;
            
            // 记录访问模式用于系统驱动加载检测
            if ((pcie_rx_func == 3'h0) && (pcie_rx_addr[9:2] == 8'h01) && pcie_rx_wren) begin
                // VMD控制器Command寄存器写入 - 驱动初始化特征
            end
        end
    end

    // 使用多功能内存包装器实例 - 负责所有配置空间存储和功能控制
    pcileech_mem_wrap_multi i_pcileech_mem_wrap_multi(
        .clk_pcie           ( clk_pcie                 ),
        .clk_sys            ( clk_sys                  ),
        
        // 设备和功能配置
        .function_id        ( current_function         ),
        .function_count     ( function_count           ),
        .device_class       ( device_class             ),
        .device_subclass    ( device_subclass          ),
        .device_interface   ( device_interface         ),
        .device_id          ( device_id                ),
        .vendor_id          ( vendor_id                ),
        
        // 共用读写地址
        .rdwr_addr          ( pcie_rx_addr             ),
        
        // 写入配置空间
        .wr_be              ( pcie_rx_wren ? pcie_rx_be : 4'b0000 ),
        .wr_data            ( pcie_rx_data             ),
           
        // 读取配置空间请求
        .rdreq_tag          ( pcie_rx_tag              ),
        .rdreq_tp           ( {1'b0, pcie_rx_rden}     ),
        .rdreq_reqid        ( pcie_rx_reqid            ),
        .rdreq_tlpwr        ( pcie_rx_wren             ),
        
        // BAR空间基地址配置
        .bar0_base_addr     ( bar0_base_addr           ),
        .bar1_base_addr     ( bar1_base_addr           ),
        .bar2_base_addr     ( bar2_base_addr           ),
        
        // 设备树信息
        .pcie_bus_number    ( pcie_bus_number          ),
        .pcie_device_number ( pcie_device_number       ),
        .pcie_function_number ( pcie_function_number   ),
        
        // 调试输出
        .debug_status       ( debug_status             )
    );
    
    // 将读取结果传递给PCIe配置空间回复模块
    wire [31:0] mem_rd_data;  // 内存读取数据
    wire [9:0]  mem_rd_addr;  // 内存读取地址
    wire [7:0]  mem_rd_tag;   // 内存读取标记
    wire [1:0]  mem_rd_tp;    // 内存读取类型
    wire [15:0] mem_rd_reqid; // 内存读取请求ID
    wire        mem_rd_tlpwr; // 内存读取TLP写标志
    
    assign mem_rd_data = i_pcileech_mem_wrap_multi.rd_data;
    assign mem_rd_tag = i_pcileech_mem_wrap_multi.rd_tag;
    assign mem_rd_tp = i_pcileech_mem_wrap_multi.rd_tp;
    assign mem_rd_reqid = i_pcileech_mem_wrap_multi.rd_reqid;
    assign mem_rd_tlpwr = i_pcileech_mem_wrap_multi.rd_tlpwr;
    assign mem_rd_addr = i_pcileech_mem_wrap_multi.rd_addr;
    
    // 计算请求状态位
    wire [2:0] pcie_rx_status = {~pcie_rx_valid, ~pcie_rx_addr_valid | ~pcie_rx_func_valid, 1'b0};
    
    // PCIe TLP配置响应模块
    pcileech_cfgspace_pcie_tx i_pcileech_cfgspace_pcie_tx(
        .rst                ( rst                       ),
        .clk_pcie           ( clk_pcie                  ),
        .pcie_id            ( pcie_id                   ),
        .pcie_rx_status     ( pcie_rx_status            ),
        .tlps_cfg_rsp       ( tlps_cfg_rsp              ),
        .cfg_wren           ( pcie_rx_req_valid && (mem_rd_tp[0] || mem_rd_tlpwr) ),
        .cfg_tlpwr          ( mem_rd_tlpwr              ),
        .cfg_tag            ( mem_rd_tag                ),
        .cfg_data           ( mem_rd_data               ),
        .cfg_reqid          ( mem_rd_reqid              )
    );
    
    // USB读写接口 - 通过shadow2fifo接口处理
    assign dshadow2fifo.cfgtlp_en = 1'b1;
    assign dshadow2fifo.cfgtlp_wren = 1'b1;
    assign dshadow2fifo.cfgtlp_zero = 1'b0;
    
    // 调试信息输出 - 可以观察每个功能的访问情况
    assign debug_status = function_access_stats[current_function];

    // 输出赋值
    assign current_function_out = current_function;
    assign function_status = function_ready_status;
    assign msix_valid_out = msix_valid_in && interrupt_routing_enable;
    assign msix_addr_out = msix_addr_in;
    assign msix_data_out = msix_data_in;
    assign msix_source_func = last_interrupt_function;

    // 在功能切换检测逻辑之后添加
    // BDF路由和功能状态管理
    always @(posedge clk_pcie) begin
        if (rst) begin
            // 重置所有路由和状态控制
            current_function <= 3'h0;
            function_route_target <= 3'h0;
            function_change_pending <= 1'b0;
            function_switch_in_progress <= 1'b0;
            function_switch_counter <= 8'h00;
            previous_function <= 3'h0;
            
            // 重置功能状态
            function_enable_status <= 8'h01; // 只启用功能0
            function_ready_status <= 8'h01;  // 只有功能0就绪
            
            // 重置中断路由
            last_interrupt_function <= 3'h0;
            
            // 重置路由策略控制
            routing_policy <= 2'b00;
            load_balance_counter <= 8'h00;
            use_backup_function <= 1'b0;
        end else begin
            // 功能切换处理
            if (current_function != active_function_id) begin
                // 检测功能ID变化
                if (!function_switch_in_progress) begin
                    // 开始功能切换过程
                    function_switch_in_progress <= 1'b1;
                    function_change_pending <= 1'b1;
                    previous_function <= current_function;
                    function_switch_counter <= 8'h00;
                end else begin
                    // 切换过程中
                    function_switch_counter <= function_switch_counter + 1'b1;
                    
                    // 在足够的延迟后完成切换
                    if (function_switch_counter >= 8'h10) begin
                        current_function <= active_function_id;
                        function_switch_in_progress <= 1'b0;
                        function_change_pending <= 1'b0;
                        
                        // 更新路由表
                        routing_table[previous_function] <= {5'h00, active_function_id};
                    end
                end
            end
            
            // 基于当前路由策略更新路由目标
            case (routing_policy)
                2'b00: begin // 固定路由
                    // 保持当前路由目标不变
                    function_route_target <= current_function;
                end
                
                2'b01: begin // 轮询路由
                    // 在每次访问后轮换到下一个启用的功能
                    if (pcie_rx_req_valid) begin
                        // 查找下一个启用的功能
                        for (int i = 1; i <= max_functions; i++) begin
                            // 计算下一个功能索引 (循环)
                            reg [2:0] next_func = (function_route_target + i) % max_functions;
                            
                            // 检查该功能是否启用
                            if (function_enable_status[next_func]) begin
                                function_route_target <= next_func;
                                break;
                            end
                        end
                    end
                end
                
                2'b10: begin // 负载均衡路由
                    // 基于访问计数进行负载均衡
                    load_balance_counter <= load_balance_counter + 1'b1;
                    
                    if (load_balance_counter == 8'hFF) begin
                        // 找到访问次数最少的功能
                        reg [31:0] min_access_count = 32'hFFFFFFFF;
                        reg [2:0]  min_access_func = 3'h0;
                        
                        for (int i = 0; i < max_functions; i++) begin
                            if (function_enable_status[i] && function_access_stats[i] < min_access_count) begin
                                min_access_count = function_access_stats[i];
                                min_access_func = i[2:0];
                            end
                        end
                        
                        // 更新路由目标
                        function_route_target <= min_access_func;
                        load_balance_counter <= 8'h00;
                    end
                end
                
                2'b11: begin // 主/备路由
                    if (use_backup_function) begin
                        function_route_target <= backup_function_id;
                    end else begin
                        function_route_target <= primary_function_id;
                    end
                    
                    // 自动检测主功能是否仍然有效
                    if (!function_ready_status[primary_function_id] && !use_backup_function) begin
                        use_backup_function <= 1'b1; // 切换到备份功能
                    end else if (function_ready_status[primary_function_id] && use_backup_function) begin
                        // 主功能恢复，但继续使用备份直到明确切换回来
                    end
                end
            endcase
            
            // 中断路由处理
            if (msix_valid_in && interrupt_routing_enable) begin
                last_interrupt_function <= current_function;
            end
            
            // 功能状态更新 - 根据访问和错误状态动态更新
            // 这里简化为基于访问统计的可用性评估
            for (int i = 0; i < max_functions; i++) begin
                // 只有启用的功能才能处于就绪状态
                if (function_enable_status[i]) begin
                    // 简单的就绪状态评估
                    if (function_access_stats[i] > 0) begin
                        function_ready_status[i] <= 1'b1;
                    end
                end else begin
                    function_ready_status[i] <= 1'b0;
                end
            end
        end
    end

    // 路由表更新 - 当接收到配置写入时
    // 在pcie_rx_req_valid处理部分增加
    always @(posedge clk_pcie) begin
        if (pcie_rx_req_valid && pcie_rx_wren) begin
            // 检测特殊路由配置访问
            if (pcie_rx_addr[9:2] == 8'hF8 && pcie_rx_func == 3'h0) begin
                // 路由策略配置寄存器 (假设定义在偏移0x3E0)
                routing_policy <= pcie_rx_data[1:0];
                interrupt_routing_enable <= pcie_rx_data[8];
            end
            
            // 功能启用控制寄存器 (假设定义在偏移0x3E4)
            if (pcie_rx_addr[9:2] == 8'hF9 && pcie_rx_func == 3'h0) begin
                // 限制只能启用最大数量的功能
                function_enable_status <= pcie_rx_data[7:0] & ((1 << max_functions) - 1);
            end
            
            // 主/备功能配置寄存器 (假设定义在偏移0x3E8)
            if (pcie_rx_addr[9:2] == 8'hFA && pcie_rx_func == 3'h0) begin
                primary_function_id <= pcie_rx_data[2:0];
                backup_function_id <= pcie_rx_data[10:8];
                use_backup_function <= pcie_rx_data[16];
            end
        end
    end

    // 功能ID转换 - 将外部BDF转换为内部功能ID
    // 在pcileech_mem_wrap_multi的function_id接口前添加
    wire [2:0] internal_function_id;
    assign internal_function_id = (pcie_rx_addr[9:2] >= 8'hF8) ? 
                                current_function : 
                                (routing_policy == 2'b00) ?
                                    current_function :
                                    function_route_target;

endmodule 
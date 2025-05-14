//
// PCILeech FPGA.
//
// 多功能集成模块 - 集成RW1C寄存器、MSI-X中断和BDF路由
//
// (c) Ulf Frisk, 2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_multifunc_integration(
    input               rst,
    input               clk_pcie,
    input               clk_sys,
    
    // PCIe TLP接口
    IfAXIS128.sink      tlps_in,
    IfAXIS128.source    tlps_out,
    
    // 设备配置接口
    input [7:0]         max_functions,       // 最大功能数量 (1-8)
    input [15:0]        pcie_id,             // PCIe标识符
    input [7:0]         device_class,        // 设备类别
    input [7:0]         device_subclass,     // 设备子类别
    input [7:0]         device_interface,    // 设备接口
    input [15:0]        device_id,           // 设备ID
    input [15:0]        vendor_id,           // 厂商ID
    
    // PCIe配置信息
    input [7:0]         pcie_bus_number,      // PCIe总线号
    input [4:0]         pcie_device_number,   // PCIe设备号
    input [2:0]         pcie_function_number, // PCIe功能号
    
    // BAR访问接口
    IfTlp128MemWrRd.mp_req bar_request,       // BAR请求接口
    
    // 中断接口
    output              msix_valid,           // MSI-X中断有效
    output [63:0]       msix_addr,            // MSI-X中断地址
    output [31:0]       msix_data,            // MSI-X中断数据
    
    // 状态和诊断接口
    output [31:0]       debug_status,         // 调试状态
    output [15:0]       function_stats[0:7],  // 功能统计
    
    // 系统接口
    IfShadow2Fifo.shadow dshadow2fifo,        // Shadow2Fifo接口
    
    // 总线管理接口
    input [7:0]         bus_master_enable,    // 总线主设备使能
    input [7:0]         memory_space_enable   // 内存空间使能
);

    // 内部接口和信号
    IfAXIS128            routed_tlps();        // 路由后的TLP流
    IfTlp128MemWrRd      bar_access[0:7]();    // 每个功能的BAR访问接口
    
    // 路由状态和控制信号
    wire [2:0]           active_function;      // 当前活动功能
    wire [1:0]           routing_state;        // 路由状态
    wire [7:0]           function_load[0:7];   // 功能负载统计
    wire [31:0]          access_stats[0:7];    // 访问统计
    
    // MSI-X中断控制信号
    wire                 msix_valid_internal[0:7]; // 每个功能的中断有效
    wire [63:0]          msix_addr_internal[0:7];  // 每个功能的中断地址
    wire [31:0]          msix_data_internal[0:7];  // 每个功能的中断数据
    wire                 msix_routed_valid;        // 路由后的中断有效
    wire [63:0]          msix_routed_addr;         // 路由后的中断地址
    wire [31:0]          msix_routed_data;         // 路由后的中断数据
    wire [2:0]           msix_source_func;         // 中断源功能
    
    // RW1C寄存器状态信号
    wire                 enhanced_rw1c_mode;       // 增强RW1C模式使能
    wire [7:0]           access_threshold;         // 访问阈值
    wire                 hw_event_active[0:7];     // 硬件事件活动
    
    // 功能状态和控制
    reg [7:0]           function_ready_mask;      // 功能就绪掩码
    reg [7:0]           function_active_mask;     // 功能活动掩码
    reg [1:0]           routing_policy;           // 路由策略
    reg                 routing_enabled;          // 路由使能
    reg [2:0]           primary_function;         // 主功能
    
    // MSI-X配置寄存器
    reg                 msix_enabled[0:7];        // 每个功能的MSI-X使能
    reg                 msix_masked[0:7];         // 每个功能的MSI-X掩码
    
    // 初始化模块状态
    initial begin
        function_ready_mask = 8'h01; // 默认只有功能0就绪
        function_active_mask = 8'h01; // 默认只有功能0活动
        routing_policy = 2'b00;      // 默认直通路由
        routing_enabled = 1'b0;      // 默认禁用路由
        primary_function = 3'h0;     // 功能0为主功能
        
        // 初始化MSI-X配置
        for (int i = 0; i < 8; i = i + 1) begin
            msix_enabled[i] = 1'b0;  // 默认禁用
            msix_masked[i] = 1'b1;   // 默认屏蔽
        end
    end
    
    // 实例化BDF路由器
    pcileech_bdf_router i_pcileech_bdf_router(
        .rst                ( rst                   ),
        .clk_pcie           ( clk_pcie              ),
        .tlps_in            ( tlps_in               ),
        .tlps_out           ( routed_tlps           ),
        
        .pcie_bus_number    ( pcie_bus_number       ),
        .pcie_device_number ( pcie_device_number    ),
        .primary_function   ( primary_function      ),
        .function_mask      ( function_active_mask  ),
        .function_count     ( max_functions         ),
        
        .routing_policy     ( routing_policy        ),
        .routing_enabled    ( routing_enabled       ),
        
        .func_load          ( function_load         ),
        .active_function    ( active_function       ),
        
        .vf_enabled         ( 1'b0                  ), // 不启用虚拟功能
        .vf_count           ( 5'h0                  ),
        .vf_offset          ( 16'h0                 ),
        
        .access_stats       ( access_stats          ),
        .routing_state      ( routing_state         )
    );
    
    // 多功能控制器 - 处理每个功能的配置空间
    pcileech_tlps128_multifunc_controller i_pcileech_tlps128_multifunc_controller(
        .rst                ( rst                   ),
        .clk_pcie           ( clk_pcie              ),
        .clk_sys            ( clk_sys               ),
        .tlps_in            ( routed_tlps           ),
        .pcie_id            ( pcie_id               ),
        .tlps_cfg_rsp       ( tlps_out              ),
        
        .function_count     ( max_functions         ),
        .device_class       ( device_class          ),
        .device_subclass    ( device_subclass       ),
        .device_interface   ( device_interface      ),
        .device_id          ( device_id             ),
        .vendor_id          ( vendor_id             ),
        
        .bar0_base_addr     ( 32'h00000000          ),
        .bar1_base_addr     ( 32'h00000000          ),
        .bar2_base_addr     ( 32'h00000000          ),
        
        .pcie_bus_number    ( pcie_bus_number       ),
        .pcie_device_number ( pcie_device_number    ),
        .pcie_function_number(pcie_function_number  ),
        
        .max_functions      ( max_functions         ),
        .active_function_id ( primary_function      ),
        .current_function_out( ), // 不使用此输出
        
        .function_status    (                       ),
        .function_change_pending(                  ),
        
        .msix_valid_in      ( msix_valid_internal[active_function] ),
        .msix_addr_in       ( msix_addr_internal[active_function]  ),
        .msix_data_in       ( msix_data_internal[active_function]  ),
        .msix_valid_out     ( msix_routed_valid    ),
        .msix_addr_out      ( msix_routed_addr     ),
        .msix_data_out      ( msix_routed_data     ),
        .msix_source_func   ( msix_source_func     ),
        
        .debug_status       ( debug_status          ),
        .dshadow2fifo       ( dshadow2fifo          )
    );
    
    // 生成多个功能实例
    genvar func_i;
    generate
        for (func_i = 0; func_i < 8; func_i = func_i + 1) begin : gen_function
            // 每个功能的BAR实现
            if (func_i == 0) begin : gen_vmd_function
                // 功能0 - VMD控制器
                pcileech_bar_impl_vmd_msix i_pcileech_bar_impl_vmd_msix(
                    .rst                ( rst                   ),
                    .clk                ( clk_pcie              ),
                    
                    // 写入接口
                    .wr_addr            ( bar_access[func_i].wr_addr   ),
                    .wr_be              ( bar_access[func_i].wr_be     ),
                    .wr_data            ( bar_access[func_i].wr_data   ),
                    .wr_valid           ( bar_access[func_i].wr_valid  ),
                    
                    // 读取接口
                    .rd_req_ctx         ( bar_access[func_i].rd_req_ctx ),
                    .rd_req_addr        ( bar_access[func_i].rd_req_addr ),
                    .rd_req_valid       ( bar_access[func_i].rd_req_valid ),
                    
                    .rd_rsp_ctx         ( bar_access[func_i].rd_rsp_ctx ),
                    .rd_rsp_data        ( bar_access[func_i].rd_rsp_data ),
                    .rd_rsp_valid       ( bar_access[func_i].rd_rsp_valid ),
                    
                    // MSI-X中断输出
                    .msix_interrupt_valid ( msix_valid_internal[func_i] ),
                    .msix_interrupt_addr  ( msix_addr_internal[func_i]  ),
                    .msix_interrupt_data  ( msix_data_internal[func_i]  ),
                    .msix_interrupt_error (                             )
                );
            end else if (func_i < max_functions) begin : gen_nvme_function
                // 功能1-7 - NVMe控制器或其他ZeroWrite4K设备
                pcileech_bar_impl_zerowrite4k i_pcileech_bar_impl_zerowrite4k(
                    .rst                ( rst                   ),
                    .clk                ( clk_pcie              ),
                    
                    // 写入接口
                    .wr_addr            ( bar_access[func_i].wr_addr   ),
                    .wr_be              ( bar_access[func_i].wr_be     ),
                    .wr_data            ( bar_access[func_i].wr_data   ),
                    .wr_valid           ( bar_access[func_i].wr_valid  ),
                    
                    // 读取接口
                    .rd_req_ctx         ( bar_access[func_i].rd_req_ctx ),
                    .rd_req_addr        ( bar_access[func_i].rd_req_addr ),
                    .rd_req_valid       ( bar_access[func_i].rd_req_valid ),
                    
                    .rd_rsp_ctx         ( bar_access[func_i].rd_rsp_ctx ),
                    .rd_rsp_data        ( bar_access[func_i].rd_rsp_data ),
                    .rd_rsp_valid       ( bar_access[func_i].rd_rsp_valid )
                );
                
                // 为每个辅助功能添加一个简单的MSI-X实现
                assign msix_valid_internal[func_i] = 1'b0; // 禁用辅助功能的MSI-X
                assign msix_addr_internal[func_i] = 64'h0;
                assign msix_data_internal[func_i] = 32'h0;
            end else begin : gen_dummy_function
                // 未使用的功能槽 - 空实现
                assign bar_access[func_i].rd_rsp_ctx = bar_access[func_i].rd_req_ctx;
                assign bar_access[func_i].rd_rsp_data = 32'h00000000;
                assign bar_access[func_i].rd_rsp_valid = bar_access[func_i].rd_req_valid;
                
                assign msix_valid_internal[func_i] = 1'b0;
                assign msix_addr_internal[func_i] = 64'h0;
                assign msix_data_internal[func_i] = 32'h0;
            end
            
            // 每个功能的状态统计
            assign function_stats[func_i] = {8'h00, function_load[func_i]};
        end
    endgenerate
    
    // BAR多路复用器 - 将统一BAR请求分派到相应的功能
    always @(posedge clk_pcie) begin
        // 默认断开所有功能的连接
        for (int i = 0; i < 8; i = i + 1) begin
            bar_access[i].wr_valid = 1'b0;
            bar_access[i].rd_req_valid = 1'b0;
        end
        
        // 根据请求的功能ID路由访问
        if (bar_request.wr_valid) begin
            // 获取功能ID - 假设它嵌入在高地址位
            reg [2:0] func_id = bar_request.wr_addr[31:29];
            
            // 检查功能ID是否有效
            if (func_id < max_functions && function_active_mask[func_id]) begin
                // 连接写请求到对应功能
                bar_access[func_id].wr_addr = bar_request.wr_addr[28:0]; // 移除功能ID位
                bar_access[func_id].wr_be = bar_request.wr_be;
                bar_access[func_id].wr_data = bar_request.wr_data;
                bar_access[func_id].wr_valid = 1'b1;
            end
        end
        
        if (bar_request.rd_req_valid) begin
            // 获取功能ID
            reg [2:0] func_id = bar_request.rd_req_addr[31:29];
            
            // 检查功能ID是否有效
            if (func_id < max_functions && function_active_mask[func_id]) begin
                // 连接读请求到对应功能
                bar_access[func_id].rd_req_ctx = bar_request.rd_req_ctx;
                bar_access[func_id].rd_req_addr = bar_request.rd_req_addr[28:0]; // 移除功能ID位
                bar_access[func_id].rd_req_valid = 1'b1;
            end
        end
    end
    
    // 合并来自所有功能的读取响应
    always @(posedge clk_pcie) begin
        // 默认无响应
        bar_request.rd_rsp_valid = 1'b0;
        bar_request.rd_rsp_ctx = 88'h0;
        bar_request.rd_rsp_data = 32'h0;
        
        // 检查每个功能是否有响应
        for (int i = 0; i < 8; i = i + 1) begin
            if (bar_access[i].rd_rsp_valid) begin
                // 输出第一个有效响应
                bar_request.rd_rsp_valid = 1'b1;
                bar_request.rd_rsp_ctx = bar_access[i].rd_rsp_ctx;
                bar_request.rd_rsp_data = bar_access[i].rd_rsp_data;
                break; // 只取第一个响应
            end
        end
    end
    
    // 中断路由 - 将多个功能的中断合并到单一输出
    assign msix_valid = msix_routed_valid;
    assign msix_addr = msix_routed_addr;
    assign msix_data = msix_routed_data;
    
    // 配置更新 - 处理对路由配置的更新
    always @(posedge clk_pcie) begin
        if (rst) begin
            function_active_mask <= 8'h01;
            routing_policy <= 2'b00;
            routing_enabled <= 1'b0;
            primary_function <= 3'h0;
        end else begin
            // 根据总线主控和内存空间使能更新功能活动掩码
            function_active_mask <= bus_master_enable & memory_space_enable & ((1 << max_functions) - 1);
            
            // 此处可以添加从配置寄存器更新路由策略的代码
            // 简化实现为根据访问统计动态调整
            
            // 动态路由策略调整 - 基于访问模式
            if (access_stats[0] > 32'h00001000) begin
                // 高访问量时激活负载均衡路由
                routing_policy <= 2'b10; // 负载均衡
                routing_enabled <= 1'b1;
            end else if (routing_state == 2'b10) begin
                // 故障状态下切换到自适应模式
                routing_policy <= 2'b11; // 自适应
            end
        end
    end

endmodule

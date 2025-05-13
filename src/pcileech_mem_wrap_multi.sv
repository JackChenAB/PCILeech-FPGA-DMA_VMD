//
// PCILeech FPGA.
//
// 多功能内存包装器 - 支持多个NVMe设备和VMD功能的配置空间
//
// (c) Ulf Frisk, 2021-2024
// Author: Ulf Frisk, pcileech@frizk.net
// Modified: <项目维护者>
//

`timescale 1ns / 1ps

module pcileech_mem_wrap_multi(
    input                clk_pcie,
    input                clk_sys,
    
    // 设备和功能配置
    input  [2:0]         function_id,        // 当前功能ID (0-7)
    input  [7:0]         function_count,     // 功能总数 (1-8)
    input  [7:0]         device_class,       // 设备类别代码
    input  [7:0]         device_subclass,    // 设备子类别代码
    input  [7:0]         device_interface,   // 设备接口代码
    input  [15:0]        device_id,          // 设备ID
    input  [15:0]        vendor_id,          // 厂商ID
    
    // 地址共用于读/写：
    input   [9:0]        rdwr_addr,
    
    // 写入配置空间:
    input   [3:0]        wr_be,
    input   [31:0]       wr_data,
       
    // 读取配置空间请求:
    input   [7:0]        rdreq_tag,
    input   [1:0]        rdreq_tp,
    input   [15:0]       rdreq_reqid,
    input                rdreq_tlpwr,
    
    // 读取配置空间结果:
    output reg  [9:0]    rd_addr,
    output      [31:0]   rd_data,
    output reg  [7:0]    rd_tag,
    output reg  [1:0]    rd_tp,
    output reg  [15:0]   rd_reqid,
    output reg           rd_tlpwr,
    
    // BAR空间基地址配置 (用于支持多个功能)
    input   [31:0]       bar0_base_addr,
    input   [31:0]       bar1_base_addr,
    input   [31:0]       bar2_base_addr,
    
    // 设备树信息
    input   [7:0]        pcie_bus_number,
    input   [4:0]        pcie_device_number,
    input   [2:0]        pcie_function_number,
    
    // 调试输出
    output reg  [31:0]   debug_status
);

    // 每个功能的配置空间内存
    reg [31:0] function_cfgspace [0:7][0:255];  // 8个功能，每个1KB配置空间
    
    // 共享寄存器 - 用于多功能设备/NVMe配置
    reg [31:0] shared_regs [0:63];
    
    // Class Code计算和共享
    wire [31:0] class_code = {8'h00, device_interface, device_subclass, device_class};
    
    // 当前读取的是哪个功能配置空间
    wire [2:0] current_function = (rdwr_addr[9:8] == 2'b00) ? function_id : rdwr_addr[9:7];
    
    // 延迟写入和状态跟踪
    reg [3:0]  wr_be_d;
    reg [31:0] wr_data_d;
    reg [9:0]  addr_d;
    reg [31:0] last_write_data;
    reg [9:0]  last_write_addr;
    reg        write_valid;
    
    // NVMe设备模拟相关存储
    reg [31:0] nvme_ns_data [0:7][0:15];     // NVMe命名空间数据 
    reg [31:0] nvme_id_data [0:7][0:31];     // NVMe控制器识别数据
    
    // VMD与系统驱动交互状态
    reg [7:0]  driver_loaded_state;          // 记录驱动加载状态
    reg [31:0] last_access_timestamp;        // 最后访问时间戳
    reg [15:0] access_pattern_counter;       // 访问模式计数器
    
    // 生成设备树一致性和关联关系
    reg [31:0] device_relation_map [0:7];    // 设备关系映射
    reg [31:0] acpi_path_data [0:7][0:3];    // ACPI路径数据
    
    // 传递寄存器
    always @(posedge clk_pcie) begin
        wr_be_d     <= wr_be;
        wr_data_d   <= wr_data;
        addr_d      <= rdwr_addr;
        rd_addr     <= rdwr_addr;
        rd_tag      <= rdreq_tag;
        rd_tp       <= rdreq_tp;
        rd_reqid    <= rdreq_reqid;
        rd_tlpwr    <= rdreq_tlpwr;
        
        if (wr_be != 4'b0000) begin
            last_write_data <= wr_data;
            last_write_addr <= rdwr_addr;
            write_valid <= 1'b1;
        end else begin
            write_valid <= 1'b0;
        end
    end

    // 初始化配置空间
    integer i, j;
    initial begin
        // 初始化所有功能的配置空间
        for (i = 0; i < 8; i = i + 1) begin
            // 每个功能的基本配置
            function_cfgspace[i][0] = {device_id, vendor_id};            // 0x00: Device/Vendor ID
            function_cfgspace[i][1] = 32'h02000006;                      // 0x04: Status/Command 
            function_cfgspace[i][2] = class_code;                        // 0x08: Class Code
            function_cfgspace[i][3] = 32'h00010000;                      // 0x0C: BIST/Header/Lat Timer/Cache Line
            
            // 不同设备类型的特定配置 (VMD控制器为08h, NVMe控制器为01h)
            case (i)
                0: begin  // VMD控制器 - 功能0
                    function_cfgspace[i][2] = 32'h06040000;              // Class=0x06(桥接设备),SubClass=0x04(PCI-PCI桥接器)
                    function_cfgspace[i][4] = bar0_base_addr;            // 0x10: BAR0 - VMD主寄存器
                    function_cfgspace[i][5] = 32'h00000000;              // 0x14: BAR1 (未使用)
                    function_cfgspace[i][6] = 32'h00000000;              // 0x18: BAR2 (未使用)
                end
                
                default: begin  // NVMe控制器 - 功能1-7
                    function_cfgspace[i][2] = 32'h01080000;              // Class=0x01(存储控制器),SubClass=0x08(NVMe)
                    function_cfgspace[i][4] = bar0_base_addr + (i << 16); // 0x10: BAR0 - 每个NVMe控制器自己的BAR
                    function_cfgspace[i][5] = 32'h00000000;              // 0x14: BAR1 (未使用)
                    function_cfgspace[i][6] = 32'h00000000;              // 0x18: BAR2 (未使用)
                end
            endcase
            
            // 其他配置空间通用寄存器
            function_cfgspace[i][11] = 32'h00000000;                     // 0x2C: Subsystem Vendor/Device ID
            function_cfgspace[i][13] = 32'h00000001;                     // 0x34: Capabilities Pointer
            function_cfgspace[i][15] = 32'h00000000;                     // 0x3C: Interrupt information
            
            // MSI-X能力结构 (位于偏移0x40)
            function_cfgspace[i][16] = 32'h00000011;                     // 0x40: MSI-X Capability
            function_cfgspace[i][17] = 32'h00002000;                     // 0x44: MSI-X Table & PBA Offset
            
            // 建立设备关系映射
            device_relation_map[i] = (i == 0) ? 32'h0000007F : (1 << (i-1));
            
            // 创建ACPI路径 - 格式为PCI0.GPxx.VMDy或PCI0.GPxx.NPMy
            acpi_path_data[i][0] = 32'h50434930;  // "PCI0"
            acpi_path_data[i][1] = 32'h2e475030 | ((pcie_device_number & 0x1F) << 8);  // ".GP0x"
            acpi_path_data[i][2] = (i == 0) ? 32'h2e564d44 : 32'h2e4e504d;  // ".VMD"或".NPM"
            acpi_path_data[i][3] = 32'h00000000 | (i & 0x7);  // 序号0-7
            
            // 初始化NVMe相关数据结构
            for (j = 0; j < 16; j = j + 1) begin
                nvme_ns_data[i][j] = 32'h00000000;
            end
            for (j = 0; j < 32; j = j + 1) begin
                nvme_id_data[i][j] = 32'h00000000; 
            end
            
            // 设置NVMe识别信息 (控制器ID和命名空间数据)
            if (i > 0) begin
                // 控制器ID数据
                nvme_id_data[i][0] = 32'h10001;           // NVMe修订版本
                nvme_id_data[i][1] = 32'h00000001;        // 支持1个命名空间
                nvme_id_data[i][2] = {device_id, vendor_id}; // 设备和厂商ID
                
                // 命名空间数据
                nvme_ns_data[i][0] = 32'h00000001;        // 命名空间大小低32位
                nvme_ns_data[i][1] = 32'h00000000;        // 命名空间大小高32位
                nvme_ns_data[i][2] = 32'h00000001;        // 命名空间容量低32位
                nvme_ns_data[i][3] = 32'h00000000;        // 命名空间容量高32位 
            end
        end
        
        // 初始化共享寄存器
        for (i = 0; i < 64; i = i + 1) begin
            shared_regs[i] = 32'h00000000;
        end
        
        // 设置初始调试状态
        debug_status = 32'h00000000;
        driver_loaded_state = 8'h00;
        last_access_timestamp = 32'h00000000;
        access_pattern_counter = 16'h0000;
    end
    
    // 配置空间读取逻辑
    reg [31:0] read_data_reg;
    
    always @(*) begin
        // 默认读取配置空间
        if (addr_d[9:8] == 2'b00) begin
            // 标准配置空间 (低256字节)
            read_data_reg = function_cfgspace[function_id][addr_d[7:2]];
        end else begin
            // 如果是扩展区域，需要根据功能ID和地址确定读取哪些区域
            case (addr_d[9:7])
                3'b010: begin  // 共享配置区域
                    read_data_reg = shared_regs[addr_d[6:2]];
                end
                3'b011: begin  // ACPI路径和设备树数据区域
                    if (addr_d[6:5] == 2'b00) begin
                        // ACPI路径
                        read_data_reg = acpi_path_data[addr_d[4:2]][addr_d[1:0]];
                    end else begin
                        // 设备关系映射
                        read_data_reg = device_relation_map[addr_d[4:2]];
                    end
                end
                3'b100: begin  // NVMe命名空间和身份数据
                    if (addr_d[6] == 1'b0) begin
                        // NVMe命名空间数据
                        read_data_reg = nvme_ns_data[addr_d[5:3]][addr_d[2:0]];
                    end else begin
                        // NVMe控制器身份数据
                        read_data_reg = nvme_id_data[addr_d[5:3]][addr_d[4:0]];
                    end
                end
                default: begin
                    // 其他扩展配置空间
                    read_data_reg = function_cfgspace[addr_d[9:7]][addr_d[6:2]];
                end
            endcase
        end
    end
    
    // 配置空间写入逻辑
    always @(posedge clk_pcie) begin
        // 更新访问计数和模式
        if (wr_be_d != 4'b0000 || rdreq_tp != 2'b00) begin
            last_access_timestamp <= last_access_timestamp + 1;
            
            // 检查是否为驱动访问特征模式
            if ((wr_be_d != 4'b0000) && (addr_d[9:2] == 8'h01)) begin  // Command寄存器写入
                access_pattern_counter <= access_pattern_counter + 1;
                
                // 根据访问模式检测驱动加载状态
                if (access_pattern_counter > 16'h0010) begin
                    driver_loaded_state <= 8'h01;  // 驱动已加载
                end
            end
        end

        // 写入操作处理
        if (wr_be_d != 4'b0000) begin
            // 配置空间写入操作
            if (addr_d[9:8] == 2'b00) begin
                // 处理标准配置头部写入
                case (addr_d[7:2])
                    6'h01: begin  // Command寄存器
                        if (wr_be_d[0]) function_cfgspace[function_id][addr_d[7:2]][7:0] <= wr_data_d[7:0] & 8'hF7;
                        if (wr_be_d[1]) function_cfgspace[function_id][addr_d[7:2]][15:8] <= wr_data_d[15:8] & 8'h0F;
                        // 状态寄存器通常是RO或RW1C，这里简化处理
                    end
                    
                    6'h04, 6'h05, 6'h06: begin  // BAR寄存器
                        // 只有特定位可写 - 简单处理为整个寄存器可写
                        if (wr_be_d[0]) function_cfgspace[function_id][addr_d[7:2]][7:0] <= wr_data_d[7:0];
                        if (wr_be_d[1]) function_cfgspace[function_id][addr_d[7:2]][15:8] <= wr_data_d[15:8];
                        if (wr_be_d[2]) function_cfgspace[function_id][addr_d[7:2]][23:16] <= wr_data_d[23:16];
                        if (wr_be_d[3]) function_cfgspace[function_id][addr_d[7:2]][31:24] <= wr_data_d[31:24];
                    end
                    
                    6'h11: begin  // Subsystem ID/Vendor ID
                        // 通常只读，但在某些情况下可能需要写入
                        if (wr_be_d[0]) function_cfgspace[function_id][addr_d[7:2]][7:0] <= wr_data_d[7:0];
                        if (wr_be_d[1]) function_cfgspace[function_id][addr_d[7:2]][15:8] <= wr_data_d[15:8];
                        if (wr_be_d[2]) function_cfgspace[function_id][addr_d[7:2]][23:16] <= wr_data_d[23:16];
                        if (wr_be_d[3]) function_cfgspace[function_id][addr_d[7:2]][31:24] <= wr_data_d[31:24];
                    end
                    
                    6'h10, 6'h11: begin  // MSI-X 能力结构
                        // 允许写入控制位
                        if (wr_be_d[0]) function_cfgspace[function_id][addr_d[7:2]][7:0] <= wr_data_d[7:0] & 8'h03;
                        if (wr_be_d[1]) function_cfgspace[function_id][addr_d[7:2]][15:8] <= wr_data_d[15:8] & 8'h80;
                        // 其他位只读
                    end
                    
                    default: begin
                        // 其他配置空间寄存器
                    end
                endcase
            end else begin
                // 扩展配置空间写入
                case (addr_d[9:7])
                    3'b010: begin  // 共享配置区域
                        if (wr_be_d[0]) shared_regs[addr_d[6:2]][7:0] <= wr_data_d[7:0];
                        if (wr_be_d[1]) shared_regs[addr_d[6:2]][15:8] <= wr_data_d[15:8];
                        if (wr_be_d[2]) shared_regs[addr_d[6:2]][23:16] <= wr_data_d[23:16];
                        if (wr_be_d[3]) shared_regs[addr_d[6:2]][31:24] <= wr_data_d[31:24];
                    end
                    
                    default: begin
                        // 其他扩展区域写入 - 功能特定配置
                        if (wr_be_d[0]) function_cfgspace[addr_d[9:7]][addr_d[6:2]][7:0] <= wr_data_d[7:0];
                        if (wr_be_d[1]) function_cfgspace[addr_d[9:7]][addr_d[6:2]][15:8] <= wr_data_d[15:8];
                        if (wr_be_d[2]) function_cfgspace[addr_d[9:7]][addr_d[6:2]][23:16] <= wr_data_d[23:16];
                        if (wr_be_d[3]) function_cfgspace[addr_d[9:7]][addr_d[6:2]][31:24] <= wr_data_d[31:24];
                    end
                endcase
            end
        end
        
        // 更新调试状态
        debug_status <= {driver_loaded_state, 8'h00, access_pattern_counter};
    end
    
    // 输出最终读取数据
    assign rd_data = read_data_reg;

endmodule 
//
// PCILeech FPGA.
//
// PCIe增强型自定义配置空间阴影模块。
// 实现动态响应控制和访问模式识别，增强安全性。
//
// (c) Ulf Frisk, 2021-2024
// Author: Ulf Frisk, pcileech@frizk.net
// Modified: <项目维护者>
//

`timescale 1ns / 1ps

`include "pcileech_header.svh"
`include "pcileech_rw1c_register.sv"

module pcileech_tlps128_cfgspace_shadow_advanced(
    input                   rst,
    input                   clk_pcie,
    input                   clk_sys,
    IfAXIS128.sink_lite     tlps_in,
    input [15:0]            pcie_id,
    IfAXIS128.source        tlps_cfg_rsp,
    IfShadow2Fifo.shadow    dshadow2fifo
);

    // ----------------------------------------------------------------------------
    // 访问模式识别和动态响应控制
    // ----------------------------------------------------------------------------
    reg [7:0]  access_pattern_counter;
    reg [31:0] last_access_addr;
    reg [31:0] access_time_counter;  // 改用普通计数器替代$time
    reg [31:0] access_interval;      // 访问间隔计数器
    reg        suspicious_activity;
    reg [1:0]  defense_level;        // 0:正常, 1:警戒, 2:高度防御
    reg [3:0]  consecutive_access_count;  // 连续访问计数器
    
    // 配置空间访问请求解析
    wire                pcie_rx_valid   = tlps_in.tvalid && tlps_in.tuser[0];
    wire                pcie_rx_rden    = pcie_rx_valid && (tlps_in.tdata[31:25] == 7'b0000010);   // CfgRd
    wire                pcie_rx_wren    = pcie_rx_valid && (tlps_in.tdata[31:25] == 7'b0100010);   // CfgWr
    wire [9:0]          pcie_rx_addr    = tlps_in.tdata[75:66];
    
    // 增强的地址有效性检查
    wire                pcie_rx_addr_in_range = (pcie_rx_addr < 10'h400);  // 4KB boundary check
    wire                pcie_rx_addr_aligned = (pcie_rx_addr[1:0] == 2'b00); // 确保地址4字节对齐
    wire                pcie_rx_addr_valid = pcie_rx_addr_in_range && pcie_rx_addr_aligned;
    
    // 地址错误计数器
    reg [7:0]           pcie_addr_error_cnt = 8'h00;
    
    always @(posedge clk_pcie) begin
        if (rst) begin
            pcie_addr_error_cnt <= 8'h00;
        end else if (pcie_rx_valid && (pcie_rx_rden || pcie_rx_wren) && !pcie_rx_addr_valid) begin
            if (pcie_addr_error_cnt < 8'hFF) begin
                pcie_addr_error_cnt <= pcie_addr_error_cnt + 1'b1;
            end
        end
    end
    
    // 访问模式分析状态机
    localparam PATTERN_NORMAL = 2'b00;
    localparam PATTERN_WATCH = 2'b01;
    localparam PATTERN_ALERT = 2'b10;
    reg [1:0] pattern_state;
    
    // 其他重要数据提取
    wire [31:0]         pcie_rx_data    = tlps_in.tdata[127:96];
    wire [7:0]          pcie_rx_tag     = tlps_in.tdata[47:40];
    wire [2:0]          pcie_rx_status  = {~pcie_rx_valid, ~pcie_rx_addr_valid, 1'b0};  // Status for completion
    wire [3:0]          pcie_rx_be      = {tlps_in.tdata[32], tlps_in.tdata[33], tlps_in.tdata[34], tlps_in.tdata[35]};
    wire [15:0]         pcie_rx_reqid   = tlps_in.tdata[63:48];
    
    // 访问模式分析逻辑
    always @(posedge clk_pcie) begin
        if (rst) begin
            access_pattern_counter <= 8'h0;
            pattern_state <= PATTERN_NORMAL;
            defense_level <= 2'b00;
            suspicious_activity <= 1'b0;
            consecutive_access_count <= 4'h0;
            access_interval <= 32'h0;
            access_time_counter <= 32'h0;
            last_access_addr <= 32'h0;
        end else begin
            // 递增时间计数器，用于测量访问间隔
            access_time_counter <= access_time_counter + 1'b1;
            
            // 访问频率监控
            if (pcie_rx_valid && pcie_rx_addr_valid) begin
                if (access_pattern_counter < 8'hFF)
                    access_pattern_counter <= access_pattern_counter + 1'b1;
                    
                // 计算访问间隔
                access_interval <= access_time_counter;
                access_time_counter <= 32'h0; // 重置计数器
                
                // 检测连续访问模式
                if (pcie_rx_addr == last_access_addr + 4) begin
                    if (consecutive_access_count < 4'hF)
                        consecutive_access_count <= consecutive_access_count + 1'b1;
                        
                    if (access_interval < 32'd100) begin  // 快速连续访问阈值
                        if (pattern_state == PATTERN_NORMAL)
                            pattern_state <= PATTERN_WATCH;
                        else if (pattern_state == PATTERN_WATCH && consecutive_access_count > 4'h3)
                            pattern_state <= PATTERN_ALERT;
                    end
                end else begin
                    // 非连续访问或间隔过长时重置模式状态
                    if (consecutive_access_count > 3 && access_interval > 32'd1000) begin
                        pattern_state <= PATTERN_NORMAL;
                        consecutive_access_count <= 4'h0;
                    end
                end
                
                last_access_addr <= pcie_rx_addr;
            end else begin
                // 无访问时缓慢降低计数器数值
                if (access_pattern_counter > 0 && access_time_counter > 32'd1000)
                    access_pattern_counter <= access_pattern_counter - 1'b1;
            end
            
            // 动态防御级别调整
            case (pattern_state)
                PATTERN_NORMAL: defense_level <= 2'b00;
                PATTERN_WATCH:  defense_level <= (access_pattern_counter > 8'h20) ? 2'b01 : 2'b00;
                PATTERN_ALERT:  defense_level <= 2'b10;
                default:       defense_level <= 2'b00;
            endcase
            
            suspicious_activity <= (pattern_state == PATTERN_ALERT) || (access_pattern_counter > 8'h80);
        end
    end

    // ----------------------------------------------------------------------------
    // USB RECEIVE (时钟域转换):
    // ----------------------------------------------------------------------------
    wire                usb_rx_rden_out;
    wire                usb_rx_wren_out;
    wire                usb_rx_valid;
    wire                usb_rx_rden = usb_rx_valid && usb_rx_rden_out;
    wire                usb_rx_wren = usb_rx_valid && usb_rx_wren_out;
    wire    [3:0]       usb_rx_be;
    wire    [31:0]      usb_rx_data;
    wire    [9:0]       usb_rx_addr;
    wire                usb_rx_addr_lo;
    fifo_49_49_clk2 i_fifo_49_49_clk2(
        .rst            ( rst                       ),
        .wr_clk         ( clk_sys                   ),
        .rd_clk         ( clk_pcie                  ),
        .wr_en          ( dshadow2fifo.rx_rden || dshadow2fifo.rx_wren ),
        .din            ( {dshadow2fifo.rx_rden, dshadow2fifo.rx_wren, dshadow2fifo.rx_addr_lo, dshadow2fifo.rx_addr, dshadow2fifo.rx_be, dshadow2fifo.rx_data} ),
        .full           (                           ),
        .rd_en          ( 1'b1                      ),
        .dout           ( {usb_rx_rden_out, usb_rx_wren_out, usb_rx_addr_lo, usb_rx_addr, usb_rx_be, usb_rx_data} ),    
        .empty          (                           ),
        .valid          ( usb_rx_valid              )
    );

    // ----------------------------------------------------------------------------
    // WRITE multiplexor: simple naive multiplexor which will prioritize in order:
    // (1) PCIe (if enabled), (2) USB, (3) INTERNAL.
    // Collisions will be discarded (it's assumed that they'll be very rare)
    // ----------------------------------------------------------------------------
    // Write Control Logic with FIFO Status Check and Overflow Protection
    wire            fifo_ready = ~i_fifo_49_49_clk2.full;
    reg             fifo_overflow_detected = 1'b0;
    reg [7:0]       fifo_overflow_counter = 8'h00;
    
    // 添加FIFO溢出检测和恢复逻辑
    always @(posedge clk_pcie) begin
        if (rst) begin
            fifo_overflow_detected <= 1'b0;
            fifo_overflow_counter <= 8'h00;
        end else begin
            if (i_fifo_49_49_clk2.full && (pcie_rx_wren || usb_rx_wren)) begin
                fifo_overflow_detected <= 1'b1;
                fifo_overflow_counter <= fifo_overflow_counter + 1'b1;
            end else if (fifo_overflow_detected && !i_fifo_49_49_clk2.full) begin
                fifo_overflow_counter <= fifo_overflow_counter;
                if (fifo_overflow_counter > 8'h10) begin
                    fifo_overflow_detected <= 1'b0;
                    fifo_overflow_counter <= 8'h00;
                end
            end
        end
    end
    
    wire            bram_wr_1_tlp = pcie_rx_wren & dshadow2fifo.cfgtlp_en & pcie_rx_addr_valid & fifo_ready & ~fifo_overflow_detected;
    wire            bram_wr_2_usb = ~bram_wr_1_tlp & usb_rx_wren & fifo_ready & ~fifo_overflow_detected;
    wire [3:0]      bram_wr_be = bram_wr_1_tlp ? (dshadow2fifo.cfgtlp_wren ? pcie_rx_be : 4'b0000) : (bram_wr_2_usb ? usb_rx_be : 4'b0000);
    wire [31:0]     bram_wr_data = bram_wr_1_tlp ? pcie_rx_data : (bram_wr_2_usb ? usb_rx_data : 32'h00000000);

    // ----------------------------------------------------------------------------
    // 读取状态机和BRAM存储器访问
    // ----------------------------------------------------------------------------
    `define S_SHADOW_CFGSPACE_IDLE  2'b00
    `define S_SHADOW_CFGSPACE_TLP   2'b01
    `define S_SHADOW_CFGSPACE_USB   2'b10
    `define S_SHADOW_CFGSPACE_ERROR 2'b11  // 错误恢复状态
    
    wire [15:0]     bram_rd_reqid;
    wire [1:0]      bram_rd_tp;
    wire [7:0]      bram_rd_tag;
    wire [9:0]      bram_rd_addr;
    wire [31:0]     bram_rd_data;
    wire [31:0]     bram_rd_data_z  = dshadow2fifo.cfgtlp_zero ? 32'h00000000 : bram_rd_data;
    wire            bram_rd_valid   = (bram_rd_tp == `S_SHADOW_CFGSPACE_TLP);
    wire            bram_rd_tlpwr;
    
    wire            bram_rd_1_tlp   = pcie_rx_rden & dshadow2fifo.cfgtlp_en;
    wire            bram_tlp        = bram_rd_1_tlp | bram_wr_1_tlp;
    wire            bram_rd_2_usb   = ~bram_tlp & usb_rx_rden;
    wire [1:0]      bram_rdreq_tp   = bram_tlp ? `S_SHADOW_CFGSPACE_TLP : (bram_rd_2_usb ? `S_SHADOW_CFGSPACE_USB : `S_SHADOW_CFGSPACE_IDLE);
    wire [9:0]      bram_rdreq_addr = bram_tlp ? pcie_rx_addr : usb_rx_addr;
    wire [7:0]      bram_rdreq_tag  = bram_tlp ? pcie_rx_tag : {7'h00, usb_rx_addr_lo};
    wire [15:0]     bram_rdreq_reqid= bram_tlp ? pcie_rx_reqid : 16'h0000;
    
    // 添加内存包装器实例 - 负责4kB配置空间存储
    pcileech_mem_wrap i_pcileech_mem_wrap(
        .clk_pcie       ( clk_pcie                 ), // <-
        .rdwr_addr      ( bram_rdreq_addr          ), // <-
        .wr_be          ( bram_wr_be               ), // <-
        .wr_data        ( bram_wr_data             ), // <-
        .rdreq_tag      ( bram_rdreq_tag           ), // <-
        .rdreq_tp       ( bram_rdreq_tp            ), // <-
        .rdreq_reqid    ( bram_rdreq_reqid         ), // <-
        .rdreq_tlpwr    ( bram_wr_1_tlp            ), // <-
        .rd_data        ( bram_rd_data             ), // ->
        .rd_addr        ( bram_rd_addr             ), // ->
        .rd_tag         ( bram_rd_tag              ), // ->
        .rd_tp          ( bram_rd_tp               ), // ->
        .rd_reqid       ( bram_rd_reqid            ), // ->
        .rd_tlpwr       ( bram_rd_tlpwr            )  // ->
    );

    // ----------------------------------------------------------------------------
    // 动态响应生成器
    // ----------------------------------------------------------------------------
    reg [31:0] dynamic_response_data;
    reg [3:0]  dynamic_response_be;
    reg        response_valid;
    reg [7:0]  response_delay_counter;
    reg        delay_in_progress;
    
    // 响应延迟控制
    always @(posedge clk_pcie) begin
        if (rst) begin
            response_delay_counter <= 8'h0;
            delay_in_progress <= 1'b0;
        end else if (defense_level == 2'b01 && pcie_rx_valid) begin
            response_delay_counter <= 8'h10;  // 设置16个时钟周期的延迟
            delay_in_progress <= 1'b1;
        end else if (response_delay_counter > 0) begin
            response_delay_counter <= response_delay_counter - 1'b1;
        end else begin
            delay_in_progress <= 1'b0;
        end
    end
    
    // 动态响应生成
    always @(*) begin
        case (defense_level)
            2'b00: begin // 正常模式 - 标准响应
                dynamic_response_data = 32'h8086_9A0B;  // 标准设备ID - Intel RST VMD控制器
                dynamic_response_be = 4'b1111;
                response_valid = 1'b1;
            end
            2'b01: begin // 警戒模式 - 延迟响应
                dynamic_response_data = 32'h8086_9A0B;
                dynamic_response_be = 4'b1111;
                response_valid = ~delay_in_progress;  // 延迟期间不响应
            end
            2'b10: begin // 高度防御 - 伪装响应
                if (consecutive_access_count > 4'h8) begin
                    // 完全屏蔽响应
                    dynamic_response_data = 32'h0;
                    dynamic_response_be = 4'b0000;
                    response_valid = 1'b0;
                end else begin
                    // 返回模糊的设备信息
                    dynamic_response_data = 32'hFFFF_FFFF;  // 未知设备ID
                    dynamic_response_be = 4'b1111;
                    response_valid = 1'b1;
                end
            end
            default: begin
                dynamic_response_data = 32'h8086_9A0B;
                dynamic_response_be = 4'b1111;
                response_valid = 1'b1;
            end
        endcase
    end

    // ----------------------------------------------------------------------------
    // 配置空间与BAR空间一致性维护
    // ----------------------------------------------------------------------------
    reg [31:0] shadow_bar_space [0:15];  // BAR空间影子寄存器
    reg [31:0] cfg_space_cache [0:63];   // 配置空间缓存
    
    // BAR空间更新逻辑
    always @(posedge clk_pcie) begin
        if (rst) begin
            for (int i = 0; i < 16; i = i + 1)
                shadow_bar_space[i] <= 32'h0;
        end else if (pcie_rx_wren && (pcie_rx_addr[9:4] == 6'h1)) begin
            shadow_bar_space[pcie_rx_addr[3:0]] <= tlps_in.tdata[127:96];
        end
    end

    // ----------------------------------------------------------------------------
    // 完成包生成和传输控制
    // ----------------------------------------------------------------------------
    reg [128:0] cpl_tlps;
    reg         cfg_wren;
    wire        tx_full;
    wire        tx_empty;
    wire        tx_valid;
    wire        tx_tp;
    
    // 完成包生成逻辑
    always @(*) begin
        if (pcie_rx_rden && response_valid) begin
            cpl_tlps[127:96] = dynamic_response_data;
            cpl_tlps[95:32]  = {pcie_id, 16'h0, 32'h0};
            cpl_tlps[31:0]   = {7'b0001010, 1'b0, 8'h0, 1'b0, 3'b000, 12'h4};
            cpl_tlps[128]    = 1'b1;
            cfg_wren         = 1'b1;
        end else begin
            cpl_tlps         = 129'h0;
            cfg_wren         = 1'b0;
        end
    end

    // FIFO实例化 - 用于缓存和转发TLP响应包
    fifo_129_129_clk1 i_fifo_129_129_clk1 (
        .srst           ( rst                      ),
        .clk            ( clk_pcie                 ),
        .wr_en          ( cfg_wren & ~tx_full     ),
        .din            ( cpl_tlps                 ),
        .full           ( tx_full                  ),
        .rd_en          ( tlps_cfg_rsp.tready & ~tx_empty ),
        .dout           ( {tx_tp, tlps_cfg_rsp.tdata} ),
        .empty          ( tx_empty                 ),
        .valid          ( tx_valid                 )
    );
    
    // 响应TLP输出接口信号赋值
    assign tlps_cfg_rsp.tvalid  = tx_valid;
    assign tlps_cfg_rsp.tkeepdw = (tx_tp ? 4'b1111 : 4'b0111);
    assign tlps_cfg_rsp.tlast   = 1'b1;
    assign tlps_cfg_rsp.tuser   = 4'b0000;
    assign tlps_cfg_rsp.has_data = ~tx_empty;
    
    // USB结果输出 - 用于USB请求返回数据
    reg [31:0] usb_response_data;
    reg usb_tx_valid;
    
    // 基于USB读请求选择正确的数据返回
    always @(posedge clk_sys) begin
        if (rst) begin
            usb_response_data <= 32'h0;
            usb_tx_valid <= 1'b0;
        end else if (dshadow2fifo.rx_rden) begin
            usb_tx_valid <= 1'b1;
            if (dshadow2fifo.rx_addr[9:4] == 6'h1) begin
                // BAR空间访问
                usb_response_data <= shadow_bar_space[dshadow2fifo.rx_addr[3:0]];
            end else begin
                // 配置空间普通寄存器访问
                usb_response_data <= cfg_space_cache[dshadow2fifo.rx_addr[5:0]];
            end
        end else begin
            usb_tx_valid <= 1'b0;
        end
    end
    
    // 调试接口 - 将关键状态传递给上层模块
    assign dshadow2fifo.debug_data = {defense_level, suspicious_activity, pattern_state, access_pattern_counter};
    
    // 输出USB读请求的结果
    assign dshadow2fifo.tx_data = usb_response_data;
    assign dshadow2fifo.tx_valid = usb_tx_valid;
    assign dshadow2fifo.tx_addr = dshadow2fifo.rx_addr;
    assign dshadow2fifo.tx_addr_lo = dshadow2fifo.rx_addr_lo;

endmodule
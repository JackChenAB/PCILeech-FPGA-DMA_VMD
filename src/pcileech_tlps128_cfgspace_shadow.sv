//
// PCILeech FPGA.
//
// PCIe custom shadow configuration space.
// Xilinx PCIe core will take configuration space priority; if Xilinx PCIe core
// is configured to forward configuration requests to user application such TLP
// will end up being processed by this module.
//
// (c) Ulf Frisk, 2021-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps

module pcileech_tlps128_cfgspace_shadow(
    input                   rst,
    input                   clk_pcie,
    input                   clk_sys,
    IfAXIS128.sink_lite     tlps_in,
    input [15:0]            pcie_id,
    IfAXIS128.source        tlps_cfg_rsp,
    IfShadow2Fifo.shadow    dshadow2fifo
);
    // ----------------------------------------------------------------------------
    // PCIe RECEIVE:
    // ----------------------------------------------------------------------------
    // Configuration Request Validation with Enhanced Boundary Checking
    wire                pcie_rx_valid   = tlps_in.tvalid && tlps_in.tuser[0];
    wire                pcie_rx_rden    = pcie_rx_valid && (tlps_in.tdata[31:25] == 7'b0000010);   // CfgRd: Fmt[2:0]=000b (3 DW header, no data), CfgRd0/CfgRd1=0010xb
    wire                pcie_rx_wren    = pcie_rx_valid && (tlps_in.tdata[31:25] == 7'b0100010);   // CfgWr: Fmt[2:0]=010b (3 DW header, data),    CfgWr0/CfgWr1=0010xb
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
            pcie_addr_error_cnt <= pcie_addr_error_cnt + 1'b1;
        end
    end
    wire [31:0]         pcie_rx_data    = tlps_in.tdata[127:96];
    wire [7:0]          pcie_rx_tag     = tlps_in.tdata[47:40];
    wire [2:0]          pcie_rx_status  = {~pcie_rx_valid, ~pcie_rx_addr_valid, 1'b0};  // Status for completion
    wire [3:0]          pcie_rx_be      = {tlps_in.tdata[32], tlps_in.tdata[33], tlps_in.tdata[34], tlps_in.tdata[35]};
    wire [15:0]         pcie_rx_reqid   = tlps_in.tdata[63:48];
        
    // ----------------------------------------------------------------------------
    // USB RECEIVE (clock domain crossing):
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
    // WRITE multiplexor and state machine: simple naive multiplexor which will prioritize in order:
    // (1) PCIe (if enabled), (2) USB, (3) INTERNAL.
    // Collisions will be discarded (it's assumed that they'll be very rare)
    // 增强状态机定义，添加错误恢复状态
    // ----------------------------------------------------------------------------
    `define S_SHADOW_CFGSPACE_IDLE  2'b00
    `define S_SHADOW_CFGSPACE_TLP   2'b01
    `define S_SHADOW_CFGSPACE_USB   2'b10
    `define S_SHADOW_CFGSPACE_ERROR 2'b11  // 新增错误恢复状态
    
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
    
    // READ state machine with enhanced error handling:
    reg [1:0]       bram_rd_tp = `S_SHADOW_CFGSPACE_IDLE;
    reg [9:0]       bram_rd_addr;
    reg [31:0]      bram_rd_data_z;
    reg [7:0]       bram_rd_tag;
    reg [7:0]       error_recovery_counter = 8'h00;
    reg             state_timeout_detected = 1'b0;
    reg [15:0]      bram_rd_reqid;
    reg             bram_rd_tlpwr;
    
    // 状态机超时检测计数器
    reg [15:0]      state_timeout_counter = 16'h0000;
    
    // BRAM MEMORY ACCESS for the 4kB / 0x1000 byte shadow configuration space.    
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
    
    always @ ( posedge clk_pcie )
    begin
        if ( rst ) begin
            bram_rd_tp <= `S_SHADOW_CFGSPACE_IDLE;
            state_timeout_counter <= 16'h0000;
            state_timeout_detected <= 1'b0;
            error_recovery_counter <= 8'h00;
        end else begin
            // 状态机超时检测逻辑 - 增强版，防止计数器溢出
            if (bram_rd_tp != `S_SHADOW_CFGSPACE_IDLE) begin
                if (state_timeout_counter < 16'hFFF0) begin  // 防止溢出
                    state_timeout_counter <= state_timeout_counter + 1'b1;
                end
                // 超时阈值调整为更合理的值
                if (state_timeout_counter >= 16'h1FF0) begin
                    state_timeout_detected <= 1'b1;
                end
            end else begin
                state_timeout_counter <= 16'h0000;
                state_timeout_detected <= 1'b0;
            end
            
            case ( bram_rd_tp )
                `S_SHADOW_CFGSPACE_IDLE: begin
                    error_recovery_counter <= 8'h00;
                end
                `S_SHADOW_CFGSPACE_TLP, `S_SHADOW_CFGSPACE_USB: begin
                    if (state_timeout_detected) begin
                        bram_rd_tp <= `S_SHADOW_CFGSPACE_ERROR;
                    end
                end
                `S_SHADOW_CFGSPACE_ERROR: begin
                    // 错误恢复逻辑
                    error_recovery_counter <= error_recovery_counter + 1'b1;
                    if (error_recovery_counter >= 8'h10) begin
                        bram_rd_tp <= `S_SHADOW_CFGSPACE_IDLE;
                        error_recovery_counter <= 8'h00;
                        // 重置超时标志和计数器
                        state_timeout_counter <= 16'h0000;
                        state_timeout_detected <= 1'b0;
                    end
                end
                default: begin
                    // 安全处理：意外状态时恢复到IDLE
                    bram_rd_tp <= `S_SHADOW_CFGSPACE_IDLE;
                end
            endcase
        end
    end
    
    // PCIe REPLY with enhanced error handling:
    reg [2:0] pcie_error_cnt;
    reg pcie_cfg_timeout;
    reg [7:0] pcie_cfg_tag_prev;
    reg [15:0] pcie_cfg_reqid_prev;
    reg [31:0] pcie_timeout_counter;
    reg pcie_cfg_error;
    
    // Error detection for PCIe configuration transactions
    always @(posedge clk_pcie) begin
        if (rst) begin
            pcie_error_cnt <= 3'b000;
            pcie_cfg_timeout <= 1'b0;
            pcie_cfg_tag_prev <= 8'h00;
            pcie_cfg_reqid_prev <= 16'h0000;
            pcie_timeout_counter <= 32'h0;
            pcie_cfg_error <= 1'b0;
        end else begin
            // Check for configuration request timeout
            if (bram_rd_valid) begin
                if ((pcie_cfg_tag_prev == bram_rd_tag) &&
                    (pcie_cfg_reqid_prev == bram_rd_reqid)) begin
                    pcie_cfg_timeout <= 1'b1;
                    pcie_error_cnt <= pcie_error_cnt + 1;
                    pcie_cfg_error <= 1'b1;
                end
                pcie_timeout_counter <= 32'h0;
                pcie_cfg_tag_prev <= bram_rd_tag;
                pcie_cfg_reqid_prev <= bram_rd_reqid;
            end else if (pcie_timeout_counter < 32'hFFFFFFFF) begin
                pcie_timeout_counter <= pcie_timeout_counter + 1;
                // 设置超时阈值为1000个时钟周期
                if (pcie_timeout_counter >= 32'd1000) begin
                    pcie_cfg_timeout <= 1'b1;
                    pcie_cfg_error <= 1'b1;
                end
            end
        end
    end
    
    pcileech_cfgspace_pcie_tx i_pcileech_cfgspace_pcie_tx(
        .rst            ( rst                       ),  // <-
        .clk_pcie       ( clk_pcie                  ),  // <-
        .pcie_id        ( pcie_id                   ),  // <- [15:0]
        .pcie_rx_status ( pcie_rx_status            ), // <- [2:0]
        .tlps_cfg_rsp   ( tlps_cfg_rsp              ),
        // cfgspace:
        .cfg_wren       ( bram_rd_valid && !pcie_cfg_timeout ), // <-
        .cfg_tlpwr      ( bram_rd_tlpwr             ),  // <-
        .cfg_tag        ( bram_rd_tag               ),  // <- [7:0]
        .cfg_data       ( bram_rd_data_z            ),  // <- [32:0]
        .cfg_reqid      ( bram_rd_reqid             )   // <- [15:0]
    );
    
    // USB REPLY with enhanced FIFO monitoring:
    wire usb_fifo_full, usb_fifo_empty;
    reg [2:0] usb_fifo_error_cnt;
    reg usb_fifo_overflow, usb_fifo_underflow;
    reg [31:0] usb_fifo_usage_counter;
    reg usb_fifo_error;
    
    always @(posedge clk_pcie) begin
        if (rst) begin
            usb_fifo_error_cnt <= 3'b000;
            usb_fifo_overflow <= 1'b0;
            usb_fifo_underflow <= 1'b0;
            usb_fifo_usage_counter <= 32'h0;
            usb_fifo_error <= 1'b0;
        end else begin
            // 监控FIFO使用情况
            if (!usb_fifo_empty) begin
                usb_fifo_usage_counter <= usb_fifo_usage_counter + 1;
            end else begin
                usb_fifo_usage_counter <= 32'h0;
            end
            
            // Detect overflow condition
            if (usb_fifo_full && (bram_rd_tp == `S_SHADOW_CFGSPACE_USB)) begin
                usb_fifo_overflow <= 1'b1;
                usb_fifo_error_cnt <= usb_fifo_error_cnt + 1;
                usb_fifo_error <= 1'b1;
            end
            
            // Detect underflow condition
            if (usb_fifo_empty && dshadow2fifo.tx_valid) begin
                usb_fifo_underflow <= 1'b1;
                usb_fifo_error_cnt <= usb_fifo_error_cnt + 1;
                usb_fifo_error <= 1'b1;
            end
            
            // 检测FIFO长时间占用
            if (usb_fifo_usage_counter >= 32'd1000) begin
                usb_fifo_error <= 1'b1;
                usb_fifo_error_cnt <= usb_fifo_error_cnt + 1;
            end
        end
    end
    
    // 改进的跨时钟域FIFO，添加同步复位和数据有效性检查
    reg rst_pcie_sync, rst_sys_sync;
    reg [1:0] rst_pcie_meta, rst_sys_meta;
    
    // 同步复位信号到各自时钟域
    always @(posedge clk_pcie) begin
        rst_pcie_meta <= {rst_pcie_meta[0], rst};
        rst_pcie_sync <= rst_pcie_meta[1];
    end
    
    always @(posedge clk_sys) begin
        rst_sys_meta <= {rst_sys_meta[0], rst};
        rst_sys_sync <= rst_sys_meta[1];
    end
    
    // 添加数据有效性检查
    wire wr_data_valid = (bram_rd_tp == `S_SHADOW_CFGSPACE_USB) && !usb_fifo_full;
    reg wr_data_valid_reg;
    
    always @(posedge clk_pcie) begin
        if (rst_pcie_sync)
            wr_data_valid_reg <= 1'b0;
        else
            wr_data_valid_reg <= wr_data_valid;
    end
    
    fifo_43_43_clk2 i_fifo_43_43_clk2(
        .rst            ( rst                       ),
        .wr_clk         ( clk_pcie                  ),
        .rd_clk         ( clk_sys                   ),
        .wr_en          ( wr_data_valid_reg && wr_data_valid ),  // 确保数据稳定
        .din            ( {bram_rd_tag[0], bram_rd_addr, bram_rd_data_z} ),
        .full           ( usb_fifo_full             ),
        .rd_en          ( !usb_fifo_empty           ),
        .dout           ( {dshadow2fifo.tx_addr_lo, dshadow2fifo.tx_addr, dshadow2fifo.tx_data} ),    
        .empty          ( usb_fifo_empty            ),
        .valid          ( dshadow2fifo.tx_valid     )
    );
    
endmodule



// PCIe TLP cfg reply module:
module pcileech_cfgspace_pcie_tx(
    input                   rst,
    input                   clk_pcie,
    input   [15:0]          pcie_id,        // PCIe id of this core
    input   [2:0]           pcie_rx_status, // PCIe状态位，从父模块传递
    IfAXIS128.source        tlps_cfg_rsp,
    // cfgspace:
    input                   cfg_wren,
    input                   cfg_tlpwr,
    input [7:0]             cfg_tag,
    input [31:0]            cfg_data,
    input [15:0]            cfg_reqid
    );
    
    // TLP Completion Package with Error Status
    wire [31:0]     cpl_tlp_data_dw0_rd  = {29'b01001010000000000000000000000, pcie_rx_status};
    wire [31:0]     cpl_tlp_data_dw0_wr  = {29'b00001010000000000000000000000, pcie_rx_status};
    wire [31:0]     cpl_tlp_data_dw1     = { `_bs16(pcie_id), 16'h0004 };
    wire [31:0]     cpl_tlp_data_dw2     = { cfg_reqid, cfg_tag, 8'h00 };
    wire [31:0]     cpl_tlp_data_dw3     = cfg_data;
    wire [127:0]    cpl_tlp_rd           = { cpl_tlp_data_dw3, cpl_tlp_data_dw2, cpl_tlp_data_dw1, cpl_tlp_data_dw0_rd };
    wire [127:0]    cpl_tlp_wr           = { 32'h00000000,     cpl_tlp_data_dw2, cpl_tlp_data_dw1, cpl_tlp_data_dw0_wr };
    wire [128:0]    cpl_tlps             = cfg_tlpwr ? {1'b0, cpl_tlp_wr} : {1'b1, cpl_tlp_rd};

    // Cross-clock domain synchronization for control signals
    reg [2:0] sync_rst_pcie;
    always @(posedge clk_pcie) begin
        sync_rst_pcie <= {sync_rst_pcie[1:0], rst};
    end

    wire tx_tp;
    wire tx_empty;
    wire tx_full;
    wire tx_valid;
    
    // FIFO for TLP completion packages with status monitoring
    fifo_129_129_clk1 i_fifo_129_129_clk1 (
        .srst           ( sync_rst_pcie[2]          ),
        .clk            ( clk_pcie                  ),
        // data in
        .wr_en          ( cfg_wren & ~tx_full      ),
        .din            ( cpl_tlps                  ),
        .full           ( tx_full                   ),
        // data out
        .rd_en          ( tlps_cfg_rsp.tready & ~tx_empty ),
        .dout           ( {tx_tp, tlps_cfg_rsp.tdata} ), 
        .empty          ( tx_empty                  ),
        .valid          ( tx_valid                  )
    );
    
    // State machine error handling
    reg error_state;
    always @(posedge clk_pcie) begin
        if (sync_rst_pcie[2]) begin
            error_state <= 1'b0;
        end else begin
            error_state <= (tx_full & cfg_wren) | (tx_empty & tlps_cfg_rsp.tready) | error_state;
        end
    end
    
    assign tlps_cfg_rsp.tkeepdw = (tx_tp ? 4'b1111 : 4'b0111);
    assign tlps_cfg_rsp.tlast = 1;
    assign tlps_cfg_rsp.tuser = 0;
    assign tlps_cfg_rsp.has_data = ~tx_empty;    
endmodule



// Wrapper module for the BRAM-backed configuration space.
module pcileech_mem_wrap(
    input               clk_pcie,
    
    // Address common to Read/Write:
    input   [9:0]       rdwr_addr,
    
    // Write to 'configuration/action space':
    input   [3:0]       wr_be,
    input   [31:0]      wr_data,
       
    // Read from 'configuration space':
    input   [7:0]       rdreq_tag,
    input   [1:0]       rdreq_tp,
    input   [15:0]      rdreq_reqid,
    input               rdreq_tlpwr,
    
    output bit  [9:0]   rd_addr,
    output      [31:0]  rd_data,
    output bit  [7:0]   rd_tag,
    output bit  [1:0]   rd_tp,
    output bit  [15:0]  rd_reqid,
    output bit          rd_tlpwr
    );
    
    bit [3:0]  wr_be_d;
    bit [31:0] wr_data_d;
    
    wire [31:0] wr_mask;
    wire [31:0] wr_dina;
    
    // DELAY TO FOLLOW BRAM DELAY
    always @ ( posedge clk_pcie )
        begin
            wr_be_d     <= wr_be;
            wr_data_d   <= wr_data;
            rd_addr     <= rdwr_addr;
            rd_tag      <= rdreq_tag;
            rd_tp       <= rdreq_tp;
            rd_reqid    <= rdreq_reqid;
            rd_tlpwr    <= rdreq_tlpwr;
        end

    // BRAM: 'configuration space' - 4kB / 0x1000 bytes:
    bram_pcie_cfgspace i_bram_pcie_cfgspace(
        .clka           ( clk_pcie                  ),
        .clkb           ( clk_pcie                  ),
        .wea            ( wr_be_d                   ),
        .addra          ( rd_addr                   ),
        .dina           ( wr_dina                   ),
        .addrb          ( rdwr_addr                 ),
        .doutb          ( rd_data                   )
    );
    
    // DROM: 'configuration space' - 4kB / 0x1000 bytes write mask:
    drom_pcie_cfgspace_writemask i_drom_pcie_cfgspace_writemask(
        .a              ( rd_addr                   ),
        .spo            ( wr_mask                   )
    );
    
    genvar i;
    generate
        for (i = 0; i < 32; i++) begin
            assign wr_dina[i] = wr_mask[i] ? wr_data_d[i] : rd_data[i];
        end
    endgenerate

endmodule

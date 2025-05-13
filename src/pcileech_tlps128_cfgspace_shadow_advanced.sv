`timescale 1ns / 1ps

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
    reg [31:0] last_access_time;
    reg [31:0] access_interval;    // 访问间隔计数器
    reg        suspicious_activity;
    reg [1:0]  defense_level;      // 0:正常, 1:警戒, 2:高度防御
    reg [3:0]  consecutive_access_count;  // 连续访问计数器
    
    // 配置空间访问请求解析
    wire                pcie_rx_valid   = tlps_in.tvalid && tlps_in.tuser[0];
    wire                pcie_rx_rden    = pcie_rx_valid && (tlps_in.tdata[31:25] == 7'b0000010);   // CfgRd
    wire                pcie_rx_wren    = pcie_rx_valid && (tlps_in.tdata[31:25] == 7'b0100010);   // CfgWr
    wire [9:0]          pcie_rx_addr    = tlps_in.tdata[75:66];
    
    // 访问模式分析状态机
    localparam PATTERN_NORMAL = 2'b00;
    localparam PATTERN_WATCH = 2'b01;
    localparam PATTERN_ALERT = 2'b10;
    reg [1:0] pattern_state;
    
    always @(posedge clk_pcie) begin
        if (rst) begin
            access_pattern_counter <= 8'h0;
            pattern_state <= PATTERN_NORMAL;
            defense_level <= 2'b00;
            suspicious_activity <= 1'b0;
            consecutive_access_count <= 4'h0;
            access_interval <= 32'h0;
            last_access_time <= 32'h0;
        end else begin
            // 访问频率监控
            if (pcie_rx_valid) begin
                if (access_pattern_counter < 8'hFF)
                    access_pattern_counter <= access_pattern_counter + 1'b1;
                    
                // 检测连续访问模式
                // 计算访问间隔
                access_interval <= last_access_time - $time;
                last_access_time <= $time;
                
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
                    pattern_state <= PATTERN_NORMAL;
                    consecutive_access_count <= 4'h0;
                end
                
                last_access_addr <= pcie_rx_addr;
            end else begin
                if (access_pattern_counter > 0)
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
                dynamic_response_data = 32'h8086201D;  // 标准设备ID
                dynamic_response_be = 4'b1111;
                response_valid = 1'b1;
            end
            2'b01: begin // 警戒模式 - 延迟响应
                dynamic_response_data = 32'h8086201D;
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
                    dynamic_response_data = 32'hFFFF0000;  // 未知设备ID
                    dynamic_response_be = 4'b1111;
                    response_valid = 1'b1;
                end
            end
            default: begin
                dynamic_response_data = 32'h8086201D;
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
        if (pcie_rx_rden) begin
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

    // FIFO实例化
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
    
    // 输出信号赋值
    assign tlps_cfg_rsp.tkeepdw = (tx_tp ? 4'b1111 : 4'b0111);
    assign tlps_cfg_rsp.tlast = 1;
    assign tlps_cfg_rsp.tuser = 0;
    assign tlps_cfg_rsp.has_data = ~tx_empty;
    
    // 调试接口
    assign dshadow2fifo.debug_data = {defense_level, suspicious_activity, pattern_state, access_pattern_counter};

endmodule
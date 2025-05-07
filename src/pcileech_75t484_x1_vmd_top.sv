//
// PCILeech FPGA.
//
// Top module for various 75T-484 x1 Artix-7 boards with Intel VMD support.
//
// (c) Ulf Frisk, 2019-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_75t484_x1_vmd_top #(
    // Intel VMD控制器设备ID (9A0B)
    parameter       PARAM_DEVICE_ID = 16'h9A0B,
    parameter       PARAM_VERSION_NUMBER_MAJOR = 4,
    parameter       PARAM_VERSION_NUMBER_MINOR = 14,
    // 自定义值可用于存储类代码信息 (010400 - 存储控制器)
    parameter       PARAM_CUSTOM_VALUE = 32'h00010400
) (
    // SYS
    input           clk,
    input           ft601_clk,
    
    // SYSTEM LEDs and BUTTONs
    output          user_ld1_n,
    output          user_ld2_n,
    input           user_sw1_n,
    input           user_sw2_n,
    
    // PCI-E FABRIC
    output  [0:0]   pcie_tx_p,
    output  [0:0]   pcie_tx_n,
    input   [0:0]   pcie_rx_p,
    input   [0:0]   pcie_rx_n,
    input           pcie_clk_p,
    input           pcie_clk_n,
    input           pcie_present,
    input           pcie_perst_n,
    output reg      pcie_wake_n = 1'b1,
    
    // TO/FROM FT601 PADS
    output          ft601_rst_n,
    
    inout   [31:0]  ft601_data,
    output  [3:0]   ft601_be,
    input           ft601_rxf_n,
    input           ft601_txe_n,
    output          ft601_wr_n,
    output          ft601_siwu_n,
    output          ft601_rd_n,
    output          ft601_oe_n
);

    // -------------------------------------------------------------------------
    // DEVICE CONFIG
    // -------------------------------------------------------------------------
    
    // 设备状态信号
    wire            led_state;
    wire            led_identify;
    wire            pcie_reset;
    
    // PCIe接口信号
    wire            pcie_clk;
    wire            pcie_lnk_up;
    
    // 数据传输接口
    IfPCIeFifoTlp   dfifo();
    IfShadow2Fifo   dshadow2fifo();
    
    // -------------------------------------------------------------------------
    // SYSTEM CORE
    // -------------------------------------------------------------------------
    
    pcileech_fifo #(
        .PARAM_DEVICE_ID            ( PARAM_DEVICE_ID               ),
        .PARAM_VERSION_NUMBER_MAJOR ( PARAM_VERSION_NUMBER_MAJOR    ),
        .PARAM_VERSION_NUMBER_MINOR ( PARAM_VERSION_NUMBER_MINOR    ),
        .PARAM_CUSTOM_VALUE         ( PARAM_CUSTOM_VALUE            )
    ) i_pcileech_fifo (
        .clk                        ( clk                           ),
        .clk_pcie                   ( pcie_clk                      ),
        .rst                        ( pcie_reset                    ),
        // FIFO CTL
        .led_state                  ( led_state                     ),
        .led_identify               ( led_identify                  ),
        // FIFO DATA
        .ft601_clk                  ( ft601_clk                     ),
        .ft601_rst_n                ( ft601_rst_n                   ),
        .ft601_data                 ( ft601_data                    ),
        .ft601_be                   ( ft601_be                      ),
        .ft601_rxf_n                ( ft601_rxf_n                   ),
        .ft601_txe_n                ( ft601_txe_n                   ),
        .ft601_wr_n                 ( ft601_wr_n                    ),
        .ft601_siwu_n               ( ft601_siwu_n                  ),
        .ft601_rd_n                 ( ft601_rd_n                    ),
        .ft601_oe_n                 ( ft601_oe_n                    ),
        // PCIe TLP
        .dfifo                      ( dfifo                         ),
        .dshadow2fifo               ( dshadow2fifo                  )
    );
    
    // -------------------------------------------------------------------------
    // PCIe CORE
    // -------------------------------------------------------------------------
    
    pcileech_pcie_a7 i_pcileech_pcie_a7(
        .clk_sys                    ( clk                           ),
        .rst                        ( pcie_reset                    ),
        // PCIe fabric
        .pcie_tx_p                  ( pcie_tx_p                     ),
        .pcie_tx_n                  ( pcie_tx_n                     ),
        .pcie_rx_p                  ( pcie_rx_p                     ),
        .pcie_rx_n                  ( pcie_rx_n                     ),
        .pcie_clk_p                 ( pcie_clk_p                    ),
        .pcie_clk_n                 ( pcie_clk_n                    ),
        .pcie_perst_n               ( pcie_perst_n                  ),
        // PCIe status
        .pcie_clk                   ( pcie_clk                      ),
        .pcie_lnk_up                ( pcie_lnk_up                   ),
        // TLP data
        .dfifo                      ( dfifo                         ),
        .dshadow2fifo               ( dshadow2fifo                  )
    );
    
    // -------------------------------------------------------------------------
    // SYSTEM MONITORING AND LEDS
    // -------------------------------------------------------------------------
    
    // 系统复位信号生成
    reg [15:0]      pcie_reset_r = 16'hffff;
    assign          pcie_reset = pcie_reset_r[15];
    
    always @ ( posedge clk )
        if ( !pcie_perst_n )
            pcie_reset_r <= 16'hffff;
        else
            pcie_reset_r <= { pcie_reset_r[14:0], 1'b0 };
    
    // LED控制
    assign user_ld1_n = ~(led_state & pcie_lnk_up);
    assign user_ld2_n = ~led_identify;

endmodule
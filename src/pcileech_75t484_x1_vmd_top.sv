//
// PCILeech FPGA.
//
// 顶层模块 - 为Artix-7 XC7A75T-484封装PCIe x1实现
// 支持Intel RST VMD控制器仿真
//
// (c) Ulf Frisk, 2019-2024
// 作者: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_75t484_x1_vmd_top #(
    // Intel RST VMD控制器配置
    parameter       PARAM_DEVICE_ID = 16'h9A0B,        // Intel RST VMD控制器设备ID
    parameter       PARAM_VENDOR_ID = 16'h8086,        // Intel厂商ID
    parameter       PARAM_SUBSYS_ID = 16'h0000,        // 子系统ID
    parameter       PARAM_SUBSYS_VENDOR_ID = 16'h0000, // 子系统厂商ID
    parameter       PARAM_REVISION_ID = 8'h01,         // 设备修订号
    parameter       PARAM_VERSION_NUMBER_MAJOR = 4,    // 主版本号
    parameter       PARAM_VERSION_NUMBER_MINOR = 14,   // 次版本号
    // PCI桥接器类代码: 06 04 00 (基类/子类/接口)
    parameter       PARAM_CLASS_CODE = 24'h060400,     // PCI-to-PCI桥接器类代码
    // 传递给子模块的自定义参数
    parameter       PARAM_CUSTOM_VALUE = 32'h00060400  // 自定义值 (此处用于传递类代码)
) (
    // 系统时钟
    input           clk,                // 系统时钟
    input           ft601_clk,          // FT601接口时钟
    
    // 系统LED和按钮接口
    output          user_ld1_n,         // 用户LED1，低电平有效，显示设备状态
    output          user_ld2_n,         // 用户LED2，低电平有效，显示通信状态
    input           user_sw1_n,         // 用户开关1，低电平有效
    input           user_sw2_n,         // 用户开关2，低电平有效
    
    // PCIe接口信号
    output  [0:0]   pcie_tx_p,          // PCIe发送差分信号正极
    output  [0:0]   pcie_tx_n,          // PCIe发送差分信号负极
    input   [0:0]   pcie_rx_p,          // PCIe接收差分信号正极
    input   [0:0]   pcie_rx_n,          // PCIe接收差分信号负极
    input           pcie_clk_p,         // PCIe参考时钟差分信号正极
    input           pcie_clk_n,         // PCIe参考时钟差分信号负极
    input           pcie_present,       // PCIe设备在位检测信号
    input           pcie_perst_n,       // PCIe复位信号，低电平有效
    output reg      pcie_wake_n = 1'b1, // PCIe唤醒信号，低电平有效
    
    // FT601接口信号
    output          ft601_rst_n,        // FT601复位信号，低电平有效
    
    inout   [31:0]  ft601_data,         // FT601数据总线
    output  [3:0]   ft601_be,           // FT601字节使能信号
    input           ft601_rxf_n,        // FT601接收FIFO非空标志，低电平有效
    input           ft601_txe_n,        // FT601发送FIFO非满标志，低电平有效
    output          ft601_wr_n,         // FT601写使能信号，低电平有效
    output          ft601_siwu_n,       // FT601立即更新状态信号，低电平有效
    output          ft601_rd_n,         // FT601读使能信号，低电平有效
    output          ft601_oe_n          // FT601输出使能信号，低电平有效
);

    // -------------------------------------------------------------------------
    // 设备状态信号
    // -------------------------------------------------------------------------
    
    wire            led_state;           // 状态LED控制信号
    wire            led_identify;        // 识别LED控制信号
    wire            pcie_reset;          // PCIe复位信号
    
    // PCIe时钟和链路状态
    wire            pcie_clk;            // PCIe参考时钟
    wire            pcie_lnk_up;         // PCIe链路建立状态
    
    // 数据传输接口
    IfPCIeFifoTlp   dfifo();             // TLP数据FIFO接口
    IfShadow2Fifo   dshadow2fifo();      // 配置空间影子FIFO接口
    
    // -------------------------------------------------------------------------
    // 系统核心组件
    // -------------------------------------------------------------------------
    
    // 创建接口实例
    IfComToFifo     dcom_fifo();         // 通信到FIFO接口
    IfPCIeFifoCfg   dcfg();              // PCIe配置接口
    IfPCIeFifoCore  dpcie();             // PCIe核心接口
    
    // FIFO网络控制核心
    pcileech_fifo #(
        .PARAM_DEVICE_ID            ( PARAM_DEVICE_ID               ),
        .PARAM_VENDOR_ID            ( PARAM_VENDOR_ID               ),
        .PARAM_SUBSYS_ID            ( PARAM_SUBSYS_ID               ),
        .PARAM_SUBSYS_VENDOR_ID     ( PARAM_SUBSYS_VENDOR_ID        ),
        .PARAM_REVISION_ID          ( PARAM_REVISION_ID             ),
        .PARAM_CLASS_CODE           ( PARAM_CLASS_CODE              ),
        .PARAM_VERSION_NUMBER_MAJOR ( PARAM_VERSION_NUMBER_MAJOR    ),
        .PARAM_VERSION_NUMBER_MINOR ( PARAM_VERSION_NUMBER_MINOR    ),
        .PARAM_CUSTOM_VALUE         ( PARAM_CUSTOM_VALUE            )
    ) i_pcileech_fifo (
        .clk                        ( clk                           ),
        .rst                        ( pcie_reset                    ),
        .rst_cfg_reload             ( 1'b0                          ),  // 禁用配置重载功能
        
        .pcie_present               ( pcie_present                  ),
        .pcie_perst_n               ( pcie_perst_n                  ),
        
        // FIFO <--> 通信控制器接口
        .dcom                       ( dcom_fifo.mp_fifo             ),
        
        // FIFO <--> PCIe接口
        .dcfg                       ( dcfg.mp_fifo                  ),
        .dtlp                       ( dfifo.mp_fifo                 ),
        .dpcie                      ( dpcie.mp_fifo                 ),
        .dshadow2fifo               ( dshadow2fifo.fifo             )
    );
    
    // FT601通信控制器
    pcileech_com i_pcileech_com(
        .clk                        ( clk                           ),
        .rst                        ( pcie_reset                    ),
        
        // FIFO接口
        .dfifo                      ( dcom_fifo.mp_com              ),
        
        // FT601物理接口
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
        
        // 状态输出
        .led_state                  ( led_state                     ),
        .led_identify               ( led_identify                  )
    );
    
    // -------------------------------------------------------------------------
    // PCIe核心
    // -------------------------------------------------------------------------
    
    pcileech_pcie_a7 i_pcileech_pcie_a7(
        .clk_sys                    ( clk                           ),
        .rst                        ( pcie_reset                    ),
        // PCIe物理接口
        .pcie_tx_p                  ( pcie_tx_p                     ),
        .pcie_tx_n                  ( pcie_tx_n                     ),
        .pcie_rx_p                  ( pcie_rx_p                     ),
        .pcie_rx_n                  ( pcie_rx_n                     ),
        .pcie_clk_p                 ( pcie_clk_p                    ),
        .pcie_clk_n                 ( pcie_clk_n                    ),
        .pcie_perst_n               ( pcie_perst_n                  ),
        // PCIe状态
        .pcie_clk                   ( pcie_clk                      ),
        .pcie_lnk_up                ( pcie_lnk_up                   ),
        // TLP数据接口
        .dfifo                      ( dfifo                         ),
        .dshadow2fifo               ( dshadow2fifo                  )
    );
    
    // -------------------------------------------------------------------------
    // 系统监控和LED控制
    // -------------------------------------------------------------------------
    
    // 系统复位信号生成
    reg [15:0]      pcie_reset_r = 16'hffff;
    assign          pcie_reset = pcie_reset_r[15];
    
    // 复位延迟计数器逻辑
    always @ ( posedge clk )
        if ( !pcie_perst_n )
            pcie_reset_r <= 16'hffff;
        else
            pcie_reset_r <= { pcie_reset_r[14:0], 1'b0 };
    
    // LED状态指示
    assign user_ld1_n = ~(led_state & pcie_lnk_up);  // LED1指示设备状态和PCIe链路建立
    assign user_ld2_n = ~led_identify;               // LED2指示通信识别

endmodule
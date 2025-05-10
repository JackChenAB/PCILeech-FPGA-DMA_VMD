# PCILeech FPGA DMA 仿真 VMD 控制器项目

## 项目概述

本项目是PCILeech FPGA实现，基于Xilinx Artix-7 XC7A75T-FGG484芯片，专门仿真Intel RST VMD（Volume Management Device）控制器。PCILeech是一个直接内存访问（DMA）工具，可用于硬件安全研究和测试。该项目通过模拟Intel RST VMD控制器（设备ID：9A0B）实现对现代系统的DMA访问，有效绕过AXX（Access Control Enforcement）安全机制。

## 技术原理

### VMD控制器仿真

本项目通过以下方式实现VMD控制器仿真：

1. **设备伪装** - 将FPGA设备伪装为Intel RST VMD控制器（设备ID：9A0B），使系统识别为受信任设备
2. **PCIe配置空间模拟** - 完整实现PCIe配置空间，包括必要的能力结构（Capability Structures）
3. **MSI-X中断支持** - 实现MSI-X中断机制，确保与现代操作系统兼容
4. **BAR空间实现** - 提供完整的基地址寄存器（BAR）空间实现，支持内存映射操作

### 关键模块说明

- **pcileech_fifo.sv** - FIFO网络控制模块，负责数据传输和命令处理
- **pcileech_ft601.sv** - FT601/FT245控制器模块，处理USB通信
- **pcileech_pcie_cfg_a7.sv** - PCIe配置模块，处理Artix-7的CFG操作
- **pcileech_75t484_x1_vmd_top.sv** - 顶层模块，集成所有功能组件
- **pcileech_bar_impl_vmd_msix.sv** - 实现带MSI-X中断功能的BAR，支持Intel RST VMD控制器仿真

## 项目结构

- `ip/` - 包含项目所需的IP核文件
  - 包括PCIe接口、FIFO、BRAM等IP核
- `src/` - 包含SystemVerilog源代码文件
  - 核心功能模块和顶层设计
- `vivado_build.tcl` - Vivado构建脚本
- `vivado_generate_project_captaindma_75t.tcl` - 项目生成脚本

## 构建说明

1. 安装Xilinx Vivado设计套件（推荐2022.1或更高版本）
2. 在Vivado Tcl Shell中运行以下命令生成项目：
   ```
   source vivado_generate_project_captaindma_75t.tcl -notrace
   ```
3. 生成比特流文件：
   ```
   source vivado_build.tcl -notrace
   ```
   注意：合成和实现步骤可能需要较长时间。

## 使用方法

1. 将生成的比特流文件下载到支持的FPGA开发板
2. 将FPGA开发板连接到目标系统的PCIe插槽
3. 使用PCILeech软件通过USB接口与FPGA通信，执行DMA操作
4. 系统将识别FPGA为Intel RST VMD控制器，允许DMA访问

### 支持的操作

- 内存读写操作
- 物理内存转储
- DMA攻击测试
- 硬件安全研究

## 技术规格

- **FPGA芯片**：Xilinx Artix-7 XC7A75T-FGG484
- **PCIe接口**：Gen2 x1
- **USB接口**：通过FT601实现高速数据传输
- **仿真设备**：Intel RST VMD控制器（设备ID：9A0B）
- **PCI类代码**：060400（PCI桥接器）

## 许可证信息

本项目采用MIT许可证开源。

```
MIT License

版权所有 (c) 2024 PCILeech项目贡献者

特此免费授予任何获得本软件及相关文档文件（"软件"）副本的人不受限制地处理本软件的权利，
包括但不限于使用、复制、修改、合并、发布、分发、再许可和/或出售软件副本的权利，
以及允许向其提供本软件的人这样做，但须符合以下条件：

上述版权声明和本许可声明应包含在本软件的所有副本或重要部分中。

本软件按"原样"提供，不提供任何形式的明示或暗示的保证，包括但不限于对适销性、
特定用途的适用性和非侵权性的保证。在任何情况下，作者或版权持有人均不对任何索赔、
损害或其他责任负责，无论是在合同诉讼、侵权行为或其他方面，由软件或软件的使用或
其他交易引起、产生或与之相关。
```

## 如何贡献

我们欢迎社区成员对本项目做出贡献。如果您想参与贡献，请遵循以下步骤：

1. Fork本仓库
2. 创建您的特性分支 (`git checkout -b feature/amazing-feature`)
3. 提交您的更改 (`git commit -m 'Add some amazing feature'`)
4. 推送到分支 (`git push origin feature/amazing-feature`)
5. 开启一个Pull Request

### 贡献指南

- 请确保您的代码符合项目的编码规范
- 添加适当的注释和文档
- 对于FPGA设计的修改，请提供相应的仿真结果或测试报告
- 确保您的更改不会破坏现有功能

## 联系方式

如有任何问题或建议，请通过以下方式联系我们：

- 提交Issue
- 发送电子邮件至[1719297084@qq.com]

## 致谢

- 特别感谢Ulf Frisk（pcileech@frizk.net）的原始PCILeech项目
- 感谢Dmytro Oleksiuk (@d_olex) 对FIFO网络模块的贡献
- 感谢所有为本项目做出贡献的开发者和研究人员
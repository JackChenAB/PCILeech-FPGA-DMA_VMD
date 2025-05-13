# PCILeech FPGA DMA 仿真 VMD 控制器项目

## 免责声明
本项目仅用于研究、教育与安全测试目的。作者不鼓励、支持或容忍任何使用本项目进行下列行为：
未经授权访问或控制他人计算机系统；
绕过、禁用或对抗任何类型的安全、反作弊、或隐私保护机制；
在真实环境中部署该代码进行恶意活动、作弊、数据窃取或破坏.

项目中的所有代码和技术细节仅供反作弊系统开发者、安全研究员和硬件工程师用于：
理解 DMA 技术的工作原理；
开发检测、对抗和防护机制；
测试自研设备或实验平台.
使用者须自行承担使用本代码产生的一切法律与安全责任。 作者及贡献者对因本项目产生的任何直接或间接后果概不负责.


## 项目概述

本项目是PCILeech FPGA实现，基于Xilinx Artix-7 XC7A75T-FGG484芯片，专门仿真Intel RST VMD（Volume Management Device）控制器。PCILeech是一个直接内存访问（DMA）工具，可用于硬件安全研究和测试。该项目通过模拟Intel RST VMD控制器（设备ID：9A0B）实现对现代系统的DMA访问.

## 最新更新

- **IP核优化** - 修复了配置空间内存深度，支持更完整的VMD能力集合
- **安全性增强** - 添加了访问模式识别和动态响应控制机制
- **隐身模式** - 实现了TLP回响和扫描检测功能，应对安全监控
- **MSI-X完善** - 改进MSI-X中断处理逻辑，提高系统兼容性
- **状态机改进** - 修复了各模块状态机的超时处理逻辑
- **RW1C寄存器实现** - 新增符合PCIe规范的RW1C寄存器模块，专门处理状态寄存器，提升兼容性
- **敏感更新** - 

## 技术原理

### VMD控制器仿真

本项目通过以下方式实现VMD控制器仿真：

1. **设备伪装** - 将FPGA设备伪装为Intel RST VMD控制器（设备ID：9A0B），使系统识别为受信任设备
2. **PCIe配置空间模拟** - 完整实现PCIe配置空间，包括必要的能力结构（Capability Structures）
3. **MSI-X中断支持** - 实现MSI-X中断机制，确保与现代操作系统兼容
4. **BAR空间实现** - 提供完整的基地址寄存器（BAR）空间实现，支持内存映射操作
5. **动态响应机制** - 智能识别系统查询模式，自适应调整响应策略

### 关键模块说明

- **pcileech_fifo.sv** - FIFO网络控制模块，负责数据传输和命令处理
- **pcileech_ft601.sv** - FT601/FT245控制器模块，处理USB通信
- **pcileech_pcie_cfg_a7.sv** - PCIe配置模块，处理Artix-7的CFG操作
- **pcileech_tlps128_cfgspace_shadow.sv** - 配置空间阴影模块，支持动态配置响应
- **pcileech_tlps128_cfgspace_shadow_advanced.sv** - 增强型配置空间，支持访问模式分析
- **pcileech_pcie_tlp_a7.sv** - TLP处理核心，支持回响和隐身模式
- **pcileech_bar_impl_vmd_msix.sv** - 实现带MSI-X中断功能的BAR，支持VMD控制器
- **pcileech_75t484_x1_vmd_top.sv** - 顶层模块，集成所有功能组件
- **pcileech_rw1c_register.sv** - 标准PCIe RW1C寄存器实现，提供防作弊状态寄存器操作
- **pcileech_pcie_tlps128_status.sv** - PCIe TLP设备状态寄存器模块，使用RW1C处理状态位
- **pcileech_tlps128_anti_cheat.sv** - 敏感模块

## 项目结构

- `ip/` - 包含项目所需的IP核文件
  - 包括PCIe接口、FIFO、BRAM等IP核
  - 最新版本已修复内存深度和COE文件格式问题
- `src/` - 包含SystemVerilog源代码文件
  - 核心功能模块和顶层设计
- `vivado_build.tcl` - Vivado构建脚本
- `vivado_generate_project_captaindma_75t.tcl` - 项目生成脚本

## IP核修复说明

最新版本修复了以下IP核相关问题：

1. **配置空间深度扩展** - 将BRAM深度从1024增加到2048，支持完整的VMD控制器特性
2. **COE文件格式修正** - 添加了正确的初始化格式头部
3. **BAR空间内存扩展** - 支持更大的寄存器区域，满足MSI-X表和PBA需求
4. **Vendor/Device ID一致性** - 确保所有模块使用统一的厂商ID和设备ID

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
4. 使用IP核验证脚本检查IP配置一致性：
   ```
   source ip/verify_ip_consistency.tcl
   ```

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
- NVMe命令模拟（新增功能）

## 技术规格

- **FPGA芯片**：Xilinx Artix-7 XC7A75T-FGG484
- **PCIe接口**：Gen2 x1
- **USB接口**：通过FT601实现高速数据传输
- **仿真设备**：Intel RST VMD控制器（设备ID：9A0B）
- **PCI类代码**：080600（Intel VMD控制器）
- **内存容量**：支持最大2048深度的配置空间，4K的BAR空间
- **RW1C寄存器规格**：
  - 支持最大32位宽度，可配置默认值
  - 4种工作状态（正常、警告、恢复、错误）
  - 访问计数最大支持255次
  - 16位访问历史模式记录，用于探测检测
  - 内置恢复机制，防止永久锁死

## 安全功能说明

最新版本增加了以下安全特性：

1. **访问模式分析** - 监控系统对VMD设备的访问模式，识别异常扫描行为
2. **动态响应控制** - 根据访问模式自动调整响应策略，应对安全检测
3. **TLP回响功能** - 支持将接收到的TLP包回传，实现通信伪装
4. **隐身模式** - 当检测到系统扫描时激活，降低被检测风险
5. **标准RW1C寄存器** - 实现符合PCIe规范的RW1C (Read-Write 1 to Clear) 寄存器：
   - 支持正确的"写1清零"操作，处理PCIe状态寄存器
   - 内置多种状态（正常、警告、恢复、错误）自动处理机制
   - 硬件事件设置接口，允许硬件自动设置对应状态位
   - 访问模式监控功能，自动检测异常访问模式

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

如有任何问题或建议，请通过以下方式联系：

- 提交Issue
- 发送电子邮件至[1719297084@qq.com]

## 致谢

- 特别感谢Ulf Frisk（pcileech@frizk.net）的原始PCILeech项目
- 感谢Dmytro Oleksiuk (@d_olex) 对FIFO网络模块的贡献
- 感谢所有为本项目做出贡献的开发者和研究人员
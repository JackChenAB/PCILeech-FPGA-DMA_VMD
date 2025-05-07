# PCILeech FPGA DMA 仿真 VMD 固件项目开源信息

## 项目概述

本项目是PCILeech FPGA实现，基于Xilinx Artix-7 XC7A75T-FGG484芯片。仿真VMD固件动态。PCILeech是一个直接内存访问（DMA）工具，可用于硬件安全研究和测试。该项目包含了完整的FPGA设计文件、Vivado TCL脚本和源代码。

## 项目结构

- `ip/` - 包含项目所需的IP核文件
- `src/` - 包含SystemVerilog源代码文件
- `vivado_build.tcl` - Vivado构建脚本
- `vivado_generate_project_captaindma_75t.tcl` - 项目生成脚本

## 构建说明

1. 安装Xilinx Vivado设计套件（推荐2022版本）
2. 在Vivado Tcl Shell中运行以下命令生成项目：
   ```
   source vivado_generate_project_captaindma_75t.tcl -notrace
   ```
3. 生成比特流文件：
   ```
   source vivado_build.tcl -notrace
   ```
   注意：合成和实现步骤可能需要较长时间。

## 许可证信息

本项目采用MIT许可证开源。

```
MIT License

版权所有 (c) [年份] [版权所有者]

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

感谢所有为本项目做出贡献的开发者和研究人员。
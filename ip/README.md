# PCILeech FPGA IP核设置

本目录包含PCILeech FPGA DMA VMD控制器项目所需的IP核文件。这些文件对于成功生成和运行Xilinx FPGA设计至关重要。

## IP核文件说明

### 主要IP核文件

- **pcie_7x_0.xci** - PCIe IP核，用于实现PCIe接口
- **bram_pcie_cfgspace.xci** - 存储PCIe配置空间内容的BRAM
- **drom_pcie_cfgspace_writemask.xci** - 存储PCIe配置空间写掩码的分布式ROM
- **bram_bar_zero4k.xci** - BAR空间实现的BRAM
- **fifo_*.xci** - 各种FIFO模块，用于数据传输和缓冲

### 配置文件

- **pcileech_cfgspace.coe** - PCIe配置空间初始值
- **pcileech_cfgspace_writemask.coe** - PCIe配置空间写掩码
- **pcileech_bar_zero4k.coe** - BAR空间初始值

### 工具脚本

- **generate_pcileech_cfgspace_writemask.py** - 生成PCIe配置空间写掩码的Python脚本
- **generate_writemask.php** - 生成PCIe配置空间写掩码的PHP脚本（备选方案）
- **verify_ip_consistency.tcl** - 验证IP核配置一致性的TCL脚本

## VMD控制器IP核配置

### PCIe配置空间写掩码

写掩码文件(pcileech_cfgspace_writemask.coe)定义了哪些PCIe配置空间寄存器可写，哪些只读。这对于正确实现符合PCIe规范的VMD控制器至关重要。

PCIe标准定义了多种寄存器类型：
- **RO (Read Only)** - 只读寄存器
- **RW (Read Write)** - 可读写寄存器
- **RW1C (Read Write 1 to Clear)** - 写1清零寄存器
- **RO/HwInit (Read Only/Hardware Initialized)** - 由硬件初始化的只读寄存器

写掩码的工作原理：
- 掩码中的0位：对应的寄存器位是只读的
- 掩码中的1位：对应的寄存器位是可写的

VMD控制器需要特别注意的寄存器包括：
1. **状态寄存器(Status Register)** - 通常是RW1C类型，需要正确处理写1清零操作
2. **命令寄存器(Command Register)** - 可写类型，控制设备行为
3. **设备控制/状态寄存器(Device Control/Status Register)** - 混合类型，需要分别处理

### 生成写掩码文件

可以使用以下方法生成写掩码文件：

#### 使用Python脚本(推荐)

```bash
python generate_pcileech_cfgspace_writemask.py
```

#### 使用PHP脚本(备选)

```bash
php generate_writemask.php
```

生成的pcileech_cfgspace_writemask.coe文件会被自动创建或更新，格式如下：

```
memory_initialization_radix=16;
memory_initialization_vector=
00000000,ffff0000,00000000,...;
```

### BRAM深度配置

新版本将配置空间BRAM深度从1024增加到2048，以支持完整的VMD控制器特性。这需要修改以下IP核：

- **bram_pcie_cfgspace.xci** - 配置空间内存
- **drom_pcie_cfgspace_writemask.xci** - 写掩码内存

### MSI-X支持配置

为了支持MSI-X中断功能，BAR空间需要配置MSI-X表和PBA区域：

1. **MSI-X表区域** - 位于偏移0x1000，大小为1KB（支持16个中断向量）
2. **MSI-X PBA区域** - 位于偏移0x2000，大小为64字节
3. **BAR空间总大小** - 至少4KB，以满足MSI-X和控制器寄存器需求

## IP核一致性验证

在进行任何IP核配置修改后，应运行一致性验证脚本以确保所有IP核配置正确：

```bash
source verify_ip_consistency.tcl
```

此脚本检查以下内容：
- 配置空间深度是否足够（≥2048）
- 写掩码格式是否正确
- BAR空间大小是否满足要求
- 设备/厂商ID设置是否一致

## VMD控制器IP核特殊配置

Intel RST VMD控制器(设备ID: 9A0B)需要特定配置：

1. **设备ID** - 必须设置为0x9A0B
2. **厂商ID** - 必须设置为0x8086 (Intel)
3. **类代码** - 设置为060400 (PCI-to-PCI桥接器)
4. **链接能力** - 需要支持ASPM (Active State Power Management)
5. **MSI-X能力** - 必须支持至少1个中断向量
6. **电源管理能力** - 需要正确实现D0-D3电源状态

## 项目代码如何使用IP核

项目代码通过以下方式使用这些IP核：

1. **pcileech_tlps128_cfgspace_shadow.sv** - 使用配置空间和写掩码文件实现PCIe配置空间
2. **pcileech_bar_impl_vmd_msix.sv** - 实现BAR空间，支持MSI-X功能
3. **pcileech_pcie_a7.sv** - 使用PCIe IP核实现PCIe接口
4. **pcileech_fifo.sv** - 使用各种FIFO IP核实现数据传输

## 注意事项和故障排除

- 如果生成项目时遇到IP核相关错误，请检查IP版本与Vivado版本是否兼容
- 写掩码格式必须正确，否则会导致PCIe配置空间行为异常
- BAR空间大小必须足够容纳MSI-X表和VMD寄存器
- 所有IP核应使用相同的设备ID和厂商ID

## 从PCILeech到VMD控制器的修改

从原始PCILeech FPGA设计到VMD控制器仿真的主要IP修改包括：

1. 修改设备ID为Intel RST VMD控制器ID (9A0B)
2. 扩展配置空间BRAM深度以支持更多能力结构
3. 添加RW1C寄存器支持（通过写掩码实现）
4. 配置BAR空间以支持MSI-X和VMD寄存器
5. 优化FIFO配置以提高数据传输稳定性 
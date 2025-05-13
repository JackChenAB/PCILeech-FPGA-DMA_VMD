# PCILeech FPGA IP核设置

本目录包含PCILeech FPGA DMA VMD控制器项目所需的IP核文件。这些文件对于成功生成和运行Xilinx FPGA设计至关重要。

## IP核文件说明

### 主要IP核文件

- **pcie_7x_0.xci** - PCIe IP核，用于实现PCIe接口
- **bram_pcie_cfgspace.xci** - 存储PCIe配置空间内容的BRAM
- **drom_pcie_cfgspace_writemask.xci** - 存储PCIe配置空间写掩码的分布式ROM
- **bram_bar_zero4k.xci** - BAR空间实现的BRAM
- **fifo_*.xci** - 各种FIFO模块，用于数据传输和缓冲

### 配置文件(COE)

COE (Coefficient) 文件在FPGA设计中用于初始化存储器内容，如BRAM、ROM等。在PCILeech-FPGA项目中，这些文件主要用于：

1. PCIe配置空间的初始化 (`pcileech_cfgspace.coe`)
2. 写掩码定义 (`pcileech_cfgspace_writemask.coe`)
3. BAR区域的默认内容 (`pcileech_bar_zero4k.coe`)
4. NVMe配置内容 (`nvme_config.coe`, `nvme_endpoint_config.coe`, `nvme_endpoint_[1-2].coe`)
5. 配置选择器设置 (`config_selector.coe`)
6. VMD控制器特定内容 (`vmd_msix.coe`, `vmd_bar.coe`)

### 工具脚本

- **generate_writemask.php** - 生成PCIe配置空间写掩码的PHP脚本
- **verify_ip_consistency.tcl** - 验证IP核配置一致性的TCL脚本
- **fix_coe_mask_format.php** - 修复COE文件格式的PHP脚本
- **maintain_coe_format.php** - 维护COE文件标准格式的PHP脚本
- **generate_vmd_msix.php** - 生成VMD控制器MSI-X表格初始化数据
- **generate_vmd_bar.php** - 生成VMD控制器BAR区域初始化数据
- **generate_nvme_endpoints.php** - 生成多个NVMe端点的配置数据

## COE文件标准格式

为了保持代码库的一致性和可读性，所有COE文件应遵循以下格式标准：

```
memory_initialization_radix=16;
memory_initialization_vector=
00000000 FFFF0000 00000000 FFFFFF00
FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF
...
00000000 00000000 00000000 00000000;
```

主要格式规则：
- 第一行指定数据格式为十六进制 (`radix=16`)
- 向量声明后换行
- 每行包含4个数据值，用空格分隔
- 文件末尾的分号之前不应有额外的换行

## COE文件维护工具

本目录包含以下用于维护COE文件格式的PHP脚本：

1. `fix_coe_mask_format.php` - 一次性修复脚本，将单行格式转换为多行格式
2. `maintain_coe_format.php` - 维护脚本，定期运行以确保所有文件保持标准格式

### 使用方法

在ip目录下运行：

```bash
php maintain_coe_format.php
```

该脚本将：
- 检查所有.coe文件的格式
- 转换单行格式为标准多行格式
- 修复空行问题
- 提供详细的处理报告

## COE文件组织

COE文件按功能分类如下：

### 1. 基础PCIe配置

- `pcileech_cfgspace.coe` - PCIe设备的标准配置空间
- `pcileech_cfgspace_writemask.coe` - 定义哪些配置寄存器可写
- `pcileech_bar_zero4k.coe` - 基本BAR空间内容

### 2. VMD控制器特定文件

- `vmd_msix.coe` - VMD控制器的MSI-X表格数据
- `vmd_bar.coe` - VMD控制器BAR区域寄存器初始值

### 3. NVMe设备配置

- `nvme_config.coe` - NVMe控制器通用配置
- `nvme_endpoint_config.coe` - NVMe端点基本配置
- `nvme_endpoint_[1-2].coe` - 具体NVMe端点的特定配置

### 4. 其他配置

- `config_selector.coe` - 系统配置选择器设置

## 生成新的COE文件

如果需要生成新的COE文件，可以使用以下脚本：

1. 写掩码相关：
   - `generate_writemask.php` - 生成PCIe配置空间写掩码

2. VMD控制器相关：
   - `generate_vmd_msix.php` - 生成VMD控制器MSI-X表格数据
   - `generate_vmd_bar.php` - 生成VMD控制器BAR区域寄存器数据

3. NVMe端点相关：
   - `generate_nvme_endpoints.php` - 生成多个NVMe端点的配置数据

也可以手动创建遵循标准格式的COE文件，或者使用维护脚本将单行格式转换为标准多行格式。

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

```bash
php generate_writemask.php
```

生成的pcileech_cfgspace_writemask.coe文件会被自动创建或更新，格式如下：

```
memory_initialization_radix=16;
memory_initialization_vector=
00000000 FFFF0000 00000000 FFFFFF00
...
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
- 修改COE文件后，需要重新生成IP核心才能使更改生效
- 一些IP核心可能对COE文件格式有特定要求，请参考Xilinx文档
- 在版本控制提交前，请确保运行维护脚本检查COE文件格式

**重要**：COE文件格式错误可能导致IP核生成失败或行为不符合预期。在提交代码前，请确保所有COE文件都遵循标准格式。

## 从PCILeech到VMD控制器的修改

从原始PCILeech FPGA设计到VMD控制器仿真的主要IP修改包括：

1. 修改设备ID为Intel RST VMD控制器ID (9A0B)
2. 扩展配置空间BRAM深度以支持更多能力结构
3. 添加RW1C寄存器支持（通过写掩码实现）
4. 配置BAR空间以支持MSI-X和VMD寄存器
5. 优化FIFO配置以提高数据传输稳定性 

## VMD和NVMe配置文件

项目新增了多个配置文件，支持Intel RST VMD控制器和多个NVMe设备的模拟：

1. **VMD控制器文件**：
   - `vmd_msix.coe` - 定义VMD控制器的MSI-X表格初始化数据，支持高级中断功能
   - `vmd_bar.coe` - 初始化VMD控制器的BAR区域寄存器，这些寄存器暴露给主机系统

2. **NVMe端点文件**：
   - `nvme_endpoint_[1-2].coe` - 为多个NVMe端点设备提供特定配置
   - 每个设备具有唯一的设备ID、序列号和容量设置

这些配置文件与`pcileech_bar_impl_vmd_msix.sv`模块配合使用，实现完整的VMD控制器和NVMe端点功能。要更新或修改这些配置，可以使用相应的生成脚本重新生成配置文件。 
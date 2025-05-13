# PCILeech FPGA-DMA_VMD IP核说明

本目录包含PCILeech FPGA-DMA项目所使用的Intel VMD控制器模拟所需的IP核文件。

## IP核文件列表及用途

### COE配置文件
- `pcileech_cfgspace.coe`: PCIe配置空间初始化数据
- `pcileech_cfgspace_writemask.coe`: PCIe配置空间写入掩码
- `pcileech_bar_zero4k.coe`: BAR区域初始化数据(全零)

### BRAM核心
- `bram_pcie_cfgspace.xci`: PCIe配置空间存储器
- `bram_bar_zero4k.xci`: PCIe BAR区域存储器
- `drom_pcie_cfgspace_writemask.xci`: PCIe配置空间写入掩码

### PCIe核心
- `pcie_7x_0.xci`: PCIe接口IP核，配置为Intel VMD控制器

### 通信FIFO核心
- 各种FIFO设计用于数据通信和缓冲

## IP核修改事项

以下是对IP核进行的重要修改：

1. 设备标识修改：
   - 厂商ID (Vendor ID): 从原先的10EE修改为8086 (Intel)
   - 设备ID (Device ID): 9A0B (Intel VMD Controller)
   - 设备类别: 08h (Generic System Peripheral)
   - 子类别: 06h (Intel VMD Controller)

2. 内存配置修改：
   - PCIe配置空间深度增加至2048字，支持完整的Intel VMD配置空间
   - BAR区域深度增加至4096字，满足VMD MSI-X和注册表空间要求

3. COE格式修正：
   - 添加了`memory_initialization_radix=16`声明，确保正确的格式化

## 使用方法

1. 在合成前运行验证脚本检查IP核配置一致性：
   ```
   cd ip
   tclsh verify_ip_consistency.tcl
   ```

2. 如果需要定制或重新生成IP核，请注意以下事项：
   - 保持设备ID和类型匹配Intel VMD控制器规范
   - 确保BRAM深度足够支持VMD所需的内存空间
   - 生成新的IP核后，运行验证脚本检查一致性

## 注意事项

- 修改设备ID可能导致与某些设备的兼容性问题，请谨慎处理
- 增加BRAM深度会占用更多FPGA资源
- 确保COE文件中的数据格式正确，包含必要的格式声明

## 故障排除

如遇问题，请检查：
1. IP核综合日志中有关格式的错误
2. COE文件的格式是否包含正确的初始化声明
3. 空间大小是否符合Intel VMD控制器的硬件需求 
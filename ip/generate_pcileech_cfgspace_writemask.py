# PCIe 配置空间写掩码文件生成脚本 适用于 PCILeech-FPGA-DMA_VMD 项目 Python 3.x 版本

from pathlib import Path

# 初始化写掩码数组（全部默认为0，表示不可写）
writemask = ["00000000"] * 512

# ----------------------------
# PCIe配置空间标准写掩码设置
# ----------------------------

# 厂商ID和设备ID (0x00) - 只读
writemask[0] = "00000000"

# 命令和状态寄存器 (0x04)
writemask[1] = "ffff0000"  # 命令寄存器可写

# 类别代码和修订ID (0x08) - 只读
writemask[2] = "00000000"

# BIST, 报头类型, 潜伏期计时器, 缓存行大小 (0x0C)
writemask[3] = "ffffff00"  # BIST部分可写，其余只读

# BAR0-BAR5 (0x10-0x24)
for i in range(4, 10):
    writemask[i] = "ffffffff"  # 基址寄存器完全可写

# 总线号、设备号、功能号等 (0x28-0x3C) - 部分可写
writemask[10] = "00000000"  # Cardbus CIS指针 - 只读
writemask[11] = "00000000"  # 子系统厂商ID和子系统ID - 只读
writemask[12] = "00000000"  # 扩展ROM基址 - 此设为只读
writemask[13] = "00000000"  # 能力指针和保留位 - 只读
writemask[14] = "00000000"  # 保留位 - 只读
writemask[15] = "000000ff"  # 中断线/针脚/最小授权/最大延迟 - 部分可写

# PCIe能力结构 (0x40-0x60)
writemask[18] = "00000000"  # 能力ID - 只读
writemask[48] = "0fff0000"  # 设备状态寄存器（RW1C）

# 电源管理能力结构
writemask[65] = "00ff0000"  # PM状态/控制寄存器中的RW1C位

# MSI-X能力结构
writemask[98] = "00070000"  # 控制寄存器部分可写

# 可自定义添加 Intel VMD 或厂商私有区域写掩码

# --------------------------
# 生成 COE 文件格式输出
# --------------------------

coe_content = "memory_initialization_radix=16;\n"
coe_content += "memory_initialization_vector=\n"
coe_content += ",".join(writemask)
coe_content += ";"

output_path = Path(__file__).parent / "pcileech_cfgspace_writemask.coe"
output_path.write_text(coe_content)

print(f"PCIe 配置空间写掩码文件已成功生成: {output_path}")

# 输出统计信息
non_zero_masks = sum(1 for mask in writemask if mask != "00000000")
print(f"总寄存器数量: {len(writemask)}")
print(f"可写寄存器数量: {non_zero_masks}")

# 输出前32个寄存器的写掩码值
print("前32个寄存器的写掩码值:")
for i in range(32):
    if writemask[i] != "00000000":
        print(f"0x{i * 4:02X}: {writemask[i]}")

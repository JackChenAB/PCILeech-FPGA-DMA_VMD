<?php
/**
 * PCIe配置空间写掩码文件生成脚本
 * 适用于PCILeech-FPGA-DMA_VMD项目
 * PHP 7.4版本
 */

// 初始化写掩码数组（全部默认为0，表示不可写）
$writemask = array_fill(0, 512, "00000000");

// 根据PCIe规范和Intel VMD规范设置正确的写掩码
// 注意：索引对应DWORD地址（4字节单位）

// PCIe配置空间标准写掩码设置
// ---------------------------

// 厂商ID和设备ID (0x00) - 只读
$writemask[0] = "00000000";

// 命令和状态寄存器 (0x04)
$writemask[1] = "ffff0000";  // 命令寄存器可写

// 类别代码和修订ID (0x08) - 只读
$writemask[2] = "00000000";

// BIST, 报头类型, 潜伏期计时器, 缓存行大小 (0x0C)
$writemask[3] = "ffffff00";  // BIST部分可写，其余只读

// BAR0-BAR5 (0x10-0x24)
for ($i = 4; $i <= 9; $i++) {
    $writemask[$i] = "ffffffff";  // 基址寄存器完全可写
}

// 总线号、设备号、功能号等 (0x28-0x3C) - 部分可写
$writemask[10] = "00000000";  // Cardbus CIS指针 - 只读
$writemask[11] = "00000000";  // 子系统厂商ID和子系统ID - 只读
$writemask[12] = "00000000";  // 扩展ROM基址 - 可写但在此设为只读
$writemask[13] = "00000000";  // 能力指针和保留位 - 只读
$writemask[14] = "00000000";  // 保留位 - 只读
$writemask[15] = "000000ff";  // 中断线、中断针脚、最小授权和最大延迟 - 部分可写

// PCIe能力结构 (0x40-0x60)
// 偏移0x48中的设备状态寄存器是RW1C类型
$writemask[18] = "00000000";  // 能力头和能力ID - 只读
$writemask[48] = "0fff0000";  // 设备状态寄存器（高16位）是RW1C类型

// 电源管理能力结构
// 偏移0x64中的PM状态/控制寄存器包含RW1C位
$writemask[65] = "00ff0000";  // PM状态/控制寄存器中部分位是RW1C

// MSI-X能力结构
// 控制寄存器可写，但表格偏移量和PBA偏移量寄存器只读
$writemask[98] = "00070000";  // MSI-X控制寄存器部分可写

// 特定厂商功能区域 (自定义) - 添加任何VMD特定的可写寄存器
// 此处可根据Intel VMD规范添加特定寄存器的写掩码

// 生成COE文件内容
$coe_content = "memory_initialization_radix=16;\n";
$coe_content .= "memory_initialization_vector=";
$coe_content .= implode(",", $writemask);
$coe_content .= ";";  // 确保末尾有分号

// 写入文件
$output_file = __DIR__ . '/pcileech_cfgspace_writemask.coe';
file_put_contents($output_file, $coe_content);

echo "PCIe配置空间写掩码文件已成功生成: " . $output_file . PHP_EOL;

// 输出一些统计信息
$non_zero_masks = 0;
foreach ($writemask as $mask) {
    if ($mask !== "00000000") {
        $non_zero_masks++;
    }
}
echo "总寄存器数量: " . count($writemask) . PHP_EOL;
echo "可写寄存器数量: " . $non_zero_masks . PHP_EOL;

// 输出前32个寄存器的写掩码值，以供参考
echo "前32个寄存器的写掩码值:" . PHP_EOL;
for ($i = 0; $i < 32; $i++) {
    if ($writemask[$i] !== "00000000") {
        echo sprintf("0x%02X: %s\n", $i * 4, $writemask[$i]);
    }
} 
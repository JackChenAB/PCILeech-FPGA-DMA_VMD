<?php
/**
 * 生成VMD BAR区域初始化数据
 * 
 * 此脚本生成vmd_bar.coe文件，用于初始化VMD控制器的BAR区域寄存器
 * 这是VMD控制器通过PCIe BAR暴露给主机的寄存器空间
 */

// 配置参数
$bar_size_words = 1024;  // BAR区域大小，以32位字为单位
$output_file = 'vmd_bar.coe';  // 输出文件名

echo "生成VMD BAR区域初始化数据...\n";

// 初始化COE文件头部
$coe_content = "memory_initialization_radix=16;\nmemory_initialization_vector=\n";

// 生成BAR区域数据
$data = array();

// 定义关键寄存器的固定值
$registers = array(
    0x00 => 0x00000000,  // VMD控制器标识
    0x04 => 0x00000001,  // 版本信息
    0x08 => 0x00000000,  // 功能控制
    0x0C => 0x00000000,  // 状态寄存器
    0x10 => 0x00002000,  // MSI-X表格偏移
    0x14 => 0x00003000,  // MSI-X PBA偏移
    0x18 => 0x00000020,  // MSI-X表格大小 (32个条目)
    0x1C => 0x00000000,  // 保留
    0x20 => 0x00000000,  // 链路控制
    0x24 => 0x00000000,  // 链路状态
    0x28 => 0x00000000,  // 错误状态
    0x2C => 0x00000000,  // 错误掩码
    0x30 => 0x00000000,  // NVMe端点管理
    0x34 => 0x00000000,  // 端点状态
    0x38 => 0x00000000,  // 设备数量
    0x3C => 0x00000000   // 保留/能力指针
);

// 填充BAR区域数据
for ($i = 0; $i < $bar_size_words; $i++) {
    if (isset($registers[$i * 4])) {
        // 使用预定义的寄存器值
        $data[] = sprintf("%08x", $registers[$i * 4]);
    } else {
        // 默认为0
        $data[] = "00000000";
    }
}

// 格式化数据为易读的COE格式
$formatted_data = array();
for ($i = 0; $i < count($data); $i += 4) {
    $line = array();
    for ($j = 0; $j < 4 && ($i + $j) < count($data); $j++) {
        $line[] = $data[$i + $j];
    }
    $formatted_data[] = implode(" ", $line);
}

// 将数据添加到COE内容中
$coe_content .= implode("\n", $formatted_data);
$coe_content .= ";";

// 写入文件
file_put_contents($output_file, $coe_content);

echo "已生成 $output_file 文件，包含 " . count($data) . " 个32位寄存器值。\n";
echo "BAR区域大小为 " . ($bar_size_words * 4) . " 字节。\n";
?> 
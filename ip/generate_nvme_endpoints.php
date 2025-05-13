<?php
/**
 * 生成多个NVMe端点的初始化配置数据
 * 
 * 此脚本生成多个NVMe端点设备的配置文件，这些设备将通过VMD控制器连接
 */

// 配置参数
$endpoint_count = 2;  // NVMe端点数量减少至2个（不包括VMD控制器）
$base_output_name = 'nvme_endpoint_';  // 输出文件名前缀

echo "生成 {$endpoint_count} 个NVMe端点配置数据...\n";

// NVMe设备基本信息
$nvme_vendor_id = 0x8086;  // Intel
$nvme_device_id = 0x2700;  // 基本NVMe控制器ID
$nvme_subsys_vendor_id = 0x8086;
$nvme_rev = 0x00010300;  // NVMe修订版本1.3
$nvme_namespace_size = 0x00100000;  // 命名空间大小(512KB模拟)

// 每个端点的容量和序列号递增
$capacity_increment = 0x00010000;  // 每个设备容量增加值
$serial_base = 0x4E564D30;  // "NVM0" - ASCII

// 为每个NVMe端点生成配置文件
for ($i = 0; $i < $endpoint_count; $i++) {
    $endpoint_id = $i + 1;  // 端点ID从1开始(0是VMD控制器)
    $output_file = $base_output_name . $endpoint_id . '.coe';
    
    // 计算当前设备的特定参数
    $current_device_id = $nvme_device_id + $endpoint_id;
    $current_serial = $serial_base + $endpoint_id;  // NVM1, NVM2, ...
    $current_capacity = $nvme_namespace_size + ($capacity_increment * $i);
    
    // 初始化COE文件头部
    $coe_content = "memory_initialization_radix=16;\nmemory_initialization_vector=\n";
    
    // 生成设备ID和控制器信息数据
    $data = array();
    
    // 控制器信息 - 16个32位字
    $data[] = sprintf("%08x", $nvme_rev);                  // NVMe修订版本
    $data[] = sprintf("%08x", 0x00000001);                 // 支持1个命名空间
    $data[] = sprintf("%08x", ($current_device_id << 16) | $nvme_vendor_id);  // 设备和厂商ID
    $data[] = sprintf("%08x", 0x00000001);                 // 功能支持
    $data[] = sprintf("%08x", $current_serial);            // 序列号(前4字节)
    $data[] = sprintf("%08x", 0x30303030);                 // 序列号(后4字节) - "0000"
    $data[] = sprintf("%08x", 0x4E564D65);                 // 模型名称(前4字节) - "NVMe"
    $data[] = sprintf("%08x", 0x20456E64);                 // 模型名称(中4字节) - " End"
    $data[] = sprintf("%08x", 0x706F696E);                 // 模型名称(后4字节) - "poin"
    $data[] = sprintf("%08x", 0x74000000);                 // 模型名称(补充) - "t"
    $data[] = sprintf("%08x", 0x50434965);                 // 固件版本 - "PCIe"
    $data[] = sprintf("%08x", 0x6563680a);                 // 固件版本(续) - "ech\n"
    $data[] = sprintf("%08x", 0x00010000);                 // 管理队列条目数
    $data[] = sprintf("%08x", 0x00000020);                 // 每个队列最大条目数
    $data[] = sprintf("%08x", 0x00000001);                 // 唯一ID
    $data[] = sprintf("%08x", 0x00000000);                 // 保留
    
    // 命名空间信息 - 16个32位字
    $data[] = sprintf("%08x", $current_capacity & 0xFFFFFFFF);        // 命名空间大小低32位
    $data[] = sprintf("%08x", ($current_capacity >> 32) & 0xFFFFFFFF); // 命名空间大小高32位
    $data[] = sprintf("%08x", $current_capacity & 0xFFFFFFFF);        // 命名空间容量低32位
    $data[] = sprintf("%08x", ($current_capacity >> 32) & 0xFFFFFFFF); // 命名空间容量高32位
    $data[] = sprintf("%08x", 0x00000000);                 // 命名空间使用率
    $data[] = sprintf("%08x", 0x00000000);                 // 命名空间使用率(高)
    $data[] = sprintf("%08x", 0x00000001);                 // 命名空间特性
    $data[] = sprintf("%08x", 0x00000000);                 // 命名空间状态
    $data[] = sprintf("%08x", 0x00000000);                 // 保留
    $data[] = sprintf("%08x", 0x00000000);                 // 保留
    $data[] = sprintf("%08x", 0x4E564D65);                 // EUI64标识符(字节0-3)
    $data[] = sprintf("%08x", $endpoint_id << 24);         // EUI64标识符(字节4-7)
    $data[] = sprintf("%08x", 0x00000000);                 // 保留
    $data[] = sprintf("%08x", 0x00000000);                 // 保留
    $data[] = sprintf("%08x", 0x00000000);                 // 保留
    $data[] = sprintf("%08x", 0x00000000);                 // 保留
    
    // 格式化数据为易读的COE格式
    $formatted_data = array();
    for ($j = 0; $j < count($data); $j += 4) {
        $line = array();
        for ($k = 0; $k < 4 && ($j + $k) < count($data); $k++) {
            $line[] = $data[$j + $k];
        }
        $formatted_data[] = implode(" ", $line);
    }
    
    // 将数据添加到COE内容中
    $coe_content .= implode("\n", $formatted_data);
    $coe_content .= ";";
    
    // 写入文件
    file_put_contents($output_file, $coe_content);
    
    echo "已生成 $output_file 文件，包含 " . count($data) . " 个32位配置值。\n";
}

echo "完成生成 {$endpoint_count} 个NVMe端点配置文件！\n";
?> 
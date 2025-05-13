<?php
/**
 * 生成VMD MSI-X表格初始化数据
 * 
 * 此脚本生成vmd_msix.coe文件，用于初始化VMD控制器的MSI-X表格
 * MSI-X表格是PCIe设备用于支持高级中断功能的数据结构
 */

// 配置参数
$table_entries = 32;  // MSI-X表格条目数量
$output_file = 'vmd_msix.coe';  // 输出文件名

// 创建MSI-X表格条目
// 每个条目包含4个32位字：
// 1. 消息地址低32位
// 2. 消息地址高32位
// 3. 消息数据
// 4. 向量控制

echo "生成VMD MSI-X表格初始化数据...\n";

// 初始化COE文件头部
$coe_content = "memory_initialization_radix=16;\nmemory_initialization_vector=\n";

// 生成MSI-X表格数据
$data = array();
for ($i = 0; $i < $table_entries; $i++) {
    // 每个条目的默认值
    // 消息地址低32位 (初始为0)
    $data[] = "00000000";
    
    // 消息地址高32位 (初始为0)
    $data[] = "00000000";
    
    // 消息数据 (初始为0)
    $data[] = "00000000";
    
    // 向量控制 (默认屏蔽位置1)
    $data[] = "00000001";
}

// 添加PBA (Pending Bit Array) - 放在MSI-X表格之后
// 每个PBA是一个32位值，表示32个向量的挂起状态
for ($i = 0; $i < ($table_entries + 31) / 32; $i++) {
    $data[] = "00000000";  // 所有位初始为0，表示没有挂起的中断
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

echo "已生成 $output_file 文件，包含 " . count($data) . " 个32位数据值。\n";
echo "MSI-X表格包含 $table_entries 个条目，每个条目4个32位字。\n";
echo "额外生成 " . ceil($table_entries / 32) . " 个PBA 32位值。\n";
?> 
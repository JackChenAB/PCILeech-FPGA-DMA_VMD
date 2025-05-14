<?php
/**
 * 统一掩码文件生成脚本
 * 适用于PCILeech-FPGA-DMA_VMD项目
 * 生成所有需要的COE格式掩码文件
 * 
 * 支持的掩码文件：
 * 1. pcileech_cfgspace_writemask.coe - PCIe配置空间写掩码
 * 2. pcileech_bar_zero4k_writemask.coe - BAR 0区域写掩码
 * 3. vmd_bar_writemask.coe - VMD控制器BAR区域写掩码
 * 4. vmd_msix_writemask.coe - MSI-X表写掩码
 * 5. nvme_endpoint_writemask.coe - NVMe端点写掩码
 * 6. config_selector.coe - 配置选择器
 * 7. rw1c_register_template.coe - RW1C寄存器模板配置
 * 
 * 使用方法：php generate_all_writemasks.php
 */

// 通用函数：将掩码数组转换为COE文件内容
function generateCoeContent($writemask, $values_per_line = 4) {
    $coe_content = "memory_initialization_radix=16;\n";
    $coe_content .= "memory_initialization_vector=\n";
    
    $lines = [];
    $current_line = [];
    
    foreach ($writemask as $mask) {
        $current_line[] = $mask;
        
        if (count($current_line) >= $values_per_line) {
            $lines[] = implode(" ", $current_line);
            $current_line = [];
        }
    }
    
    // 处理最后一行（如果有）
    if (!empty($current_line)) {
        $lines[] = implode(" ", $current_line);
    }
    
    $coe_content .= implode("\n", $lines);
    $coe_content .= "; ";
    
    return $coe_content;
}

// 生成PCIe配置空间写掩码
function generatePcieCfgspaceWritemask() {
    // 初始化写掩码数组（默认为只读）
    $writemask = array_fill(0, 1024, "00000000");
    
    // 根据PCIe规范设置写掩码
    // 命令和状态寄存器 (0x04)
    $writemask[1] = "ffff0000";  // 命令寄存器可写
    
    // BIST, 报头类型等 (0x0C)
    $writemask[3] = "ffffff00";  // BIST部分可写
    
    // BAR0-BAR5 (0x10-0x24)
    for ($i = 4; $i <= 9; $i++) {
        $writemask[$i] = "ffffffff";  // 基址寄存器完全可写
    }
    
    // 中断配置 (0x3C)
    $writemask[15] = "000000ff";  // 中断线、中断针脚等部分可写
    
    // PCIe能力结构
    $writemask[18] = "00ff0000";  // PCIe相关寄存器部分可写
    $writemask[48] = "0fff0000";  // 设备状态寄存器（RW1C类型）
    
    // MSI-X能力结构
    $writemask[24] = "0007ffff";  // MSI-X控制寄存器和表格地址部分可写
    
    // 输出COE文件
    $output_file = __DIR__ . '/pcileech_cfgspace_writemask.coe';
    file_put_contents($output_file, generateCoeContent($writemask));
    echo "已生成PCIe配置空间写掩码: " . $output_file . PHP_EOL;
}

// 生成BAR 0区域写掩码（仅前32字节可写）
function generateBarZero4kWritemask() {
    // 初始化写掩码数组（默认为只读）
    $writemask = array_fill(0, 1024, "00000000");
    
    // 仅前8个DWORD可写（前32字节）
    for ($i = 0; $i < 8; $i++) {
        $writemask[$i] = "ffffffff";
    }
    
    // 输出COE文件
    $output_file = __DIR__ . '/pcileech_bar_zero4k_writemask.coe';
    file_put_contents($output_file, generateCoeContent($writemask));
    echo "已生成BAR 0区域写掩码: " . $output_file . PHP_EOL;
}

// 生成VMD控制器BAR区域写掩码（前40字节可写）
function generateVmdBarWritemask() {
    // 初始化写掩码数组（默认为只读）
    $writemask = array_fill(0, 1024, "00000000");
    
    // 前10个DWORD可写（前40字节）
    for ($i = 0; $i < 8; $i++) {
        $writemask[$i] = "ffffffff";
    }
    // 第9-10个DWORD可写
    $writemask[8] = "ffffffff";
    $writemask[9] = "ffffffff";
    
    // 输出COE文件
    $output_file = __DIR__ . '/vmd_bar_writemask.coe';
    file_put_contents($output_file, generateCoeContent($writemask));
    echo "已生成VMD控制器BAR区域写掩码: " . $output_file . PHP_EOL;
}

// 生成MSI-X表写掩码（每个表项最高4位可写）
function generateVmdMsixWritemask() {
    // 初始化写掩码数组
    $writemask = array_fill(0, 128, "ffffffff");
    
    // 对于每个MSI-X表项的最后一个DWORD，设置高4位可写
    for ($i = 3; $i < 128; $i += 4) {
        $writemask[$i] = "f0000000";
    }
    
    // 输出COE文件
    $output_file = __DIR__ . '/vmd_msix_writemask.coe';
    file_put_contents($output_file, generateCoeContent($writemask));
    echo "已生成MSI-X表写掩码: " . $output_file . PHP_EOL;
}

// 生成NVMe端点写掩码
function generateNvmeEndpointWritemask() {
    // 初始化写掩码数组（默认为只读）
    $writemask = array_fill(0, 60, "00000000");
    
    // 前7个DWORD完全可写
    for ($i = 0; $i < 7; $i++) {
        $writemask[$i] = "ffffffff";
    }
    
    // 第7个DWORD完全可写
    $writemask[7] = "ffffffff";
    
    // 第8个DWORD的最低位不可写（特殊控制位）
    $writemask[8] = "fffffffe";
    
    // 第9个DWORD高16位可写
    $writemask[9] = "ffff0000";
    
    // 输出COE文件
    $output_file = __DIR__ . '/nvme_endpoint_writemask.coe';
    file_put_contents($output_file, generateCoeContent($writemask));
    echo "已生成NVMe端点写掩码: " . $output_file . PHP_EOL;
}

// 生成配置选择器（使用优化的配置值）
function generateConfigSelector() {
    // 初始化写掩码数组（默认为0）
    $writemask = array_fill(0, 64, "00000000");
    
    // 设置优化的配置值，开启增强安全规避和动态响应功能
    $writemask[0] = "00000003";
    $writemask[1] = "00000001";
    
    // 输出COE文件
    $output_file = __DIR__ . '/config_selector.coe';
    file_put_contents($output_file, generateCoeContent($writemask));
    echo "已生成配置选择器: " . $output_file . PHP_EOL;
}

// 生成RW1C寄存器模板配置
function generateRw1cRegisterTemplate() {
    // 初始化写掩码数组（默认为0）
    $writemask = array_fill(0, 64, "00000000");
    
    // 设置RW1C寄存器模板
    $writemask[8] = "ffffffff";  // 第3个寄存器组RW1C控制
    $writemask[9] = "00000000";  // 第3个寄存器组初始值
    $writemask[10] = "00000000";  // 第3个寄存器组标记
    
    // 设置RW1C寄存器状态
    $writemask[12] = "ffffffff";
    $writemask[13] = "ffffffff"; 
    $writemask[14] = "ffffffff";
    $writemask[15] = "ffffffff";
    
    // 输出COE文件
    $output_file = __DIR__ . '/rw1c_register_template.coe';
    file_put_contents($output_file, generateCoeContent($writemask));
    echo "已生成RW1C寄存器模板配置: " . $output_file . PHP_EOL;
}

// 执行所有生成函数
echo "开始生成掩码文件...\n";
generatePcieCfgspaceWritemask();
generateBarZero4kWritemask();
generateVmdBarWritemask();
generateVmdMsixWritemask();
generateNvmeEndpointWritemask();
generateConfigSelector();
generateRw1cRegisterTemplate();
echo "所有掩码文件生成完成!\n";

// 输出统计信息
echo "\n生成的掩码文件一览:\n";
echo "1. pcileech_cfgspace_writemask.coe - PCIe配置空间写掩码\n";
echo "2. pcileech_bar_zero4k_writemask.coe - BAR 0区域写掩码\n";
echo "3. vmd_bar_writemask.coe - VMD控制器BAR区域写掩码\n";
echo "4. vmd_msix_writemask.coe - MSI-X表写掩码\n";
echo "5. nvme_endpoint_writemask.coe - NVMe端点写掩码\n";
echo "6. config_selector.coe - 配置选择器\n";
echo "7. rw1c_register_template.coe - RW1C寄存器模板配置\n"; 
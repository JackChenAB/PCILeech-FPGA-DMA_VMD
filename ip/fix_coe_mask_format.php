<?php
/**
 * 修复IP目录中所有.coe文件的掩码格式，将单行格式转换为易读的多行格式
 * 这个脚本会处理当前目录中的所有.coe文件，将它们格式化为一致的多行格式
 */

// 获取当前目录下所有.coe文件
$coeFiles = glob("*.coe");
echo "找到 " . count($coeFiles) . " 个.coe文件\n";

foreach ($coeFiles as $filePath) {
    fixCoeFile($filePath);
}

echo "所有.coe文件处理完成\n";

/**
 * 修复.coe文件的格式，将单行向量转换为多行格式
 */
function fixCoeFile($filePath) {
    // 读取文件内容
    $content = file_get_contents($filePath);
    if ($content === false) {
        echo "无法读取文件 {$filePath}\n";
        return;
    }

    // 提取初始化向量部分
    if (!preg_match('/memory_initialization_vector=(.*?);/s', $content, $matches)) {
        echo "在文件 {$filePath} 中未找到初始化向量\n";
        return;
    }

    $vectorData = trim($matches[1]);
    
    // 检查是否已经是多行格式
    if (strpos($vectorData, "\n") !== false) {
        echo "文件 {$filePath} 已经是多行格式\n";
        return;
    }

    // 将向量数据按逗号分割
    $values = explode(',', $vectorData);
    
    // 每行放4个值
    $formattedVector = "\n";
    for ($i = 0; $i < count($values); $i += 4) {
        $lineValues = array_slice($values, $i, 4);
        $formattedVector .= implode(' ', $lineValues);
        if ($i + 4 < count($values)) {
            $formattedVector .= "\n";
        }
    }
    
    // 构建新内容
    $newContent = "memory_initialization_radix=16;\nmemory_initialization_vector={$formattedVector};\n";
    
    // 写回文件
    if (file_put_contents($filePath, $newContent) === false) {
        echo "无法写入文件 {$filePath}\n";
        return;
    }
    
    echo "已修复文件 {$filePath}\n";
} 
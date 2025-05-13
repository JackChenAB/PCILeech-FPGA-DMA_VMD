<?php
/**
 * 维护IP目录中所有.coe文件的掩码格式
 * 这个脚本会检查所有.coe文件，确保它们都是多行格式
 * 建议定期运行此脚本，作为项目维护的一部分
 */

// 报告和统计信息
$totalFiles = 0;
$formattedFiles = 0;
$alreadyFormattedFiles = 0;
$skipFiles = 0;

// 获取所有.coe文件
$coeFiles = glob("*.coe");
$totalFiles = count($coeFiles);
echo "开始检查 {$totalFiles} 个.coe文件的格式...\n";

foreach ($coeFiles as $filePath) {
    formatCoeFile($filePath);
}

// 输出统计信息
echo "\n总结:\n";
echo "总计检查文件: {$totalFiles}\n";
echo "已格式化文件: {$formattedFiles}\n";
echo "已经是格式化的文件: {$alreadyFormattedFiles}\n";
echo "跳过的文件: {$skipFiles}\n";

/**
 * 检查并格式化.coe文件
 */
function formatCoeFile($filePath) {
    global $formattedFiles, $alreadyFormattedFiles, $skipFiles;
    
    // 读取文件内容
    $content = file_get_contents($filePath);
    if ($content === false) {
        echo "[错误] 无法读取文件 {$filePath}\n";
        $skipFiles++;
        return;
    }

    // 提取初始化向量部分
    if (!preg_match('/memory_initialization_vector=(.*?)(?:;|\Z)/s', $content, $matches)) {
        echo "[警告] 在文件 {$filePath} 中未找到初始化向量\n";
        $skipFiles++;
        return;
    }

    $vectorData = trim($matches[1]);
    
    // 检查是否已经是多行格式
    if (strpos($vectorData, "\n") !== false) {
        echo "[信息] 文件 {$filePath} 已经是多行格式\n";
        $alreadyFormattedFiles++;
        
        // 检查是否有额外的空行
        $lines = explode("\n", $vectorData);
        $hasEmptyLines = false;
        foreach ($lines as $line) {
            if (trim($line) === '') {
                $hasEmptyLines = true;
                break;
            }
        }
        
        if ($hasEmptyLines) {
            echo "[修复] 移除文件 {$filePath} 中的空行\n";
            $newVectorData = "";
            foreach ($lines as $line) {
                if (trim($line) !== '') {
                    $newVectorData .= trim($line) . "\n";
                }
            }
            $newContent = "memory_initialization_radix=16;\nmemory_initialization_vector=\n" . trim($newVectorData) . ";\n";
            file_put_contents($filePath, $newContent);
            $formattedFiles++;
        }
        
        return;
    }

    // 将向量数据按逗号分割
    $values = explode(',', $vectorData);
    
    // 每行放4个值
    $formattedVector = "\n";
    for ($i = 0; $i < count($values); $i += 4) {
        $lineValues = array_slice($values, $i, min(4, count($values) - $i));
        $formattedVector .= implode(' ', $lineValues);
        if ($i + 4 < count($values)) {
            $formattedVector .= "\n";
        }
    }
    
    // 构建新内容
    $newContent = "memory_initialization_radix=16;\nmemory_initialization_vector={$formattedVector};\n";
    
    // 写回文件
    if (file_put_contents($filePath, $newContent) === false) {
        echo "[错误] 无法写入文件 {$filePath}\n";
        $skipFiles++;
        return;
    }
    
    echo "[格式化] 已格式化文件 {$filePath}\n";
    $formattedFiles++;
} 
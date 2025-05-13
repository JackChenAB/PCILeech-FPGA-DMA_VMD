#!/usr/bin/tclsh

# PCILeech FPGA IP核一致性检查脚本
# 此脚本用于验证所有IP核配置的一致性，确保无冲突

puts "PCILeech FPGA IP核验证开始..."

# 检查COE文件格式
proc check_coe_format {file} {
    if {[catch {set fp [open $file r]} err]} {
        puts "错误: 无法打开文件 $file: $err"
        return 0
    }
    
    set data [read $fp]
    close $fp
    
    # 检查COE文件格式
    if {![string match "*memory_initialization_radix*" $data]} {
        puts "警告: $file 缺少正确的radix声明"
        return 0
    }
    
    return 1
}

# 检查IP核配置一致性
proc check_ip_consistency {} {
    set consistency_ok 1
    
    # 检查所有COE文件
    foreach coe_file [glob -nocomplain "*.coe"] {
        if {![check_coe_format $coe_file]} {
            set consistency_ok 0
            puts "请修复 $coe_file 格式问题"
        } else {
            puts "$coe_file 格式正确"
        }
    }
    
    # 检查PCIe与VMD设备ID一致性
    if {[catch {set fp [open "pcie_7x_0.xci" r]} err]} {
        puts "警告: 无法读取PCIe IP核配置文件"
        set consistency_ok 0
    } else {
        set pcie_data [read $fp]
        close $fp
        
        # 检查VMD设备ID
        if {![string match "*\"Vendor_ID\": \[ { \"value\": \"8086\"*" $pcie_data]} {
            puts "警告: PCIe IP核的Vendor ID不是Intel (8086)"
            set consistency_ok 0
        }
        
        if {![string match "*\"Device_ID\": \[ { \"value\": \"9A0B\"*" $pcie_data]} {
            puts "警告: PCIe IP核的Device ID不是9A0B (Intel RST VMD Controller)"
            set consistency_ok 0
        }
        
        # 检查VMD设备类型配置
        if {![string match "*\"Class_Code_Base\": \[ { \"value\": \"08\"*" $pcie_data]} {
            puts "警告: PCIe IP核的Class Code不匹配VMD控制器 (08h)"
            set consistency_ok 0
        }
        
        if {![string match "*\"Class_Code_Sub\": \[ { \"value\": \"06\"*" $pcie_data]} {
            puts "警告: PCIe IP核的子类代码不匹配VMD控制器 (06h)"
            set consistency_ok 0
        }
    }
    
    # 检查BRAM配置
    if {[catch {set fp [open "bram_pcie_cfgspace.xci" r]} err]} {
        puts "警告: 无法读取配置空间BRAM IP核文件"
        set consistency_ok 0
    } else {
        set bram_data [read $fp]
        close $fp
        
        # 检查深度配置
        if {![string match "*\"Write_Depth_A\": \[ { \"value\": \"2048\"*" $bram_data]} {
            puts "警告: 配置空间BRAM深度不足，应至少为2048"
            set consistency_ok 0
        }
    }
    
    # 检查BAR BRAM配置
    if {[catch {set fp [open "bram_bar_zero4k.xci" r]} err]} {
        puts "警告: 无法读取BAR空间BRAM IP核文件"
        set consistency_ok 0
    } else {
        set bar_data [read $fp]
        close $fp
        
        # 检查深度配置
        if {![string match "*\"Write_Depth_A\": \[ { \"value\": \"4096\"*" $bar_data]} {
            puts "警告: BAR空间BRAM深度不足，应为4096"
            set consistency_ok 0
        }
    }
    
    return $consistency_ok
}

# 主检查流程
if {[check_ip_consistency]} {
    puts "IP核验证通过! 所有配置一致且符合VMD控制器要求。"
} else {
    puts "IP核验证失败! 请修复上述问题。"
    exit 1
}

puts "PCILeech FPGA IP核验证完成。" 
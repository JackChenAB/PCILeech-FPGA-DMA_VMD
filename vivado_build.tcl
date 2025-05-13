#
# 请在 Vivado Tcl Shell 中运行此脚本（Run this script within Vivado Tcl Shell）
# 使用命令：source vivado_build.tcl -notrace （Use command: source vivado_build.tcl -notrace）
#

# 自动设置项目名称（Automatically set the project name）
set _xil_proj_name_ "pcileech_captaindma_75t"

puts "-------------------------------------------------------"
puts " 开始为 ${_xil_proj_name_} 项目执行综合步骤（Starting synthesis for project ${_xil_proj_name_}）"
puts "-------------------------------------------------------"

# 启动综合任务，使用 4 个并发作业（Launch synthesis with 4 parallel jobs）
launch_runs -jobs 4 synth_1

puts "-------------------------------------------------------"
puts " 等待综合步骤完成 ...（Waiting for synthesis to complete...）"
puts " 这可能需要很长时间。（This might take a long time.）"
puts "-------------------------------------------------------"

# 阻塞等待综合完成（Wait until synthesis completes）
wait_on_run synth_1

puts "-------------------------------------------------------"
puts " 开始实现步骤（Starting implementation step）"
puts "-------------------------------------------------------"

# 启动实现任务，并执行到比特流写入阶段（Launch implementation run up to write_bitstream step）
launch_runs -jobs 4 impl_1 -to_step write_bitstream

puts "-------------------------------------------------------"
puts " 等待实现步骤完成 ...（Waiting for implementation to complete...）"
puts " 这可能需要很长时间。（This might take a long time.）"
puts "-------------------------------------------------------"

# 阻塞等待实现完成（Wait until implementation is finished）
wait_on_run impl_1

# 拷贝生成的比特流文件到当前目录，并按项目命名（Copy generated .bin file to current directory with project-based name）
file copy -force ./${_xil_proj_name_}/${_xil_proj_name_}.runs/impl_1/pcileech_75t484_x1_vmd_top.bin ${_xil_proj_name_}.bin

puts "-------------------------------------------------------"
puts " 构建完成。（Build completed.）"
puts "-------------------------------------------------------"

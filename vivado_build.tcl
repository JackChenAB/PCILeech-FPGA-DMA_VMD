#
# RUN FROM WITHIN "Vivado Tcl Shell" WITH COMMAND:
# source vivado_build.tcl -notrace
#
# 自动获取当前项目名称
set _xil_proj_name_ "pcileech_captaindma_75t"

puts "-------------------------------------------------------"
puts " 开始为 ${_xil_proj_name_} 项目执行综合步骤            "
puts "-------------------------------------------------------"
launch_runs -jobs 4 synth_1
puts "-------------------------------------------------------"
puts " 等待综合步骤完成 ...                                  "
puts " 这可能需要很长时间。                                  "
puts "-------------------------------------------------------"
wait_on_run synth_1
puts "-------------------------------------------------------"
puts " 开始实现步骤                                          "
puts "-------------------------------------------------------"
launch_runs -jobs 4 impl_1 -to_step write_bitstream
puts "-------------------------------------------------------"
puts " 等待实现步骤完成 ...                                  "
puts " 这可能需要很长时间。                                  "
puts "-------------------------------------------------------"
wait_on_run impl_1

# 生成的比特流文件基于当前项目名称和顶层模块自动命名
file copy -force ./${_xil_proj_name_}/${_xil_proj_name_}.runs/impl_1/pcileech_75t484_x1_vmd_top.bin ${_xil_proj_name_}.bin
puts "-------------------------------------------------------"
puts " 构建完成。                                            "
puts "-------------------------------------------------------"

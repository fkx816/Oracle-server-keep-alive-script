#!/bin/bash
# by spiritlhl
# from https://github.com/spiritLHLS/Oracle-server-keep-alive-script
# Modified to use stress tool for reliable memory allocation

# 设置语言环境
if [[ -d "/usr/share/locale/en_US.UTF-8" ]]; then
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8
  export LANGUAGE=en_US.UTF-8
else
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  export LANGUAGE=C.UTF-8
fi

# 检查并安装必要的命令
command -v bc >/dev/null 2>&1 || { 
  echo "bc is required but not installed. Installing..."
  apt update && apt install bc -y
}

command -v stress >/dev/null 2>&1 || { 
  echo "stress is required but not installed. Installing..."
  apt update && apt install stress -y
}

pid_file=/tmp/memory-limit.pid

# PID文件检查，防止重复运行
if [ -e "${pid_file}" ]; then
  # 如果 PID 文件存在，则读取其中的 PID
  pid=$(cat "${pid_file}")
  # 检查该 PID 是否对应一个正在运行的进程
  if ps -p "${pid}" >/dev/null 2>&1; then
    echo "Error: Another instance of memory-limit.sh is already running with PID ${pid}"
    exit 1
  fi
  # 如果 PID 文件存在，但对应的进程已经停止运行，删除 PID 文件
  rm -f "${pid_file}"
fi

# 写入当前进程的PID
echo $$ > "${pid_file}"

# 记录脚本开始运行
echo "$(date): Memory limiter started with stress tool"

# 清理函数
cleanup() {
  echo "$(date): Cleaning up..."
  # 杀死所有由此脚本启动的stress进程
  pkill -f "stress.*--vm.*--vm-bytes.*--timeout" 2>/dev/null
  rm -f "${pid_file}"
  exit 0
}

# 设置信号处理
trap cleanup SIGTERM SIGINT

# 主循环
while true; do
  # 获取内存信息（KB为单位）
  mem_info=$(free | grep '^Mem:')
  mem_total=$(echo $mem_info | awk '{print $2}')
  mem_used=$(echo $mem_info | awk '{print $3}')
  
  # 检查是否获取到有效的内存数据
  if [[ ! "$mem_total" =~ ^[0-9]+$ ]] || [[ ! "$mem_used" =~ ^[0-9]+$ ]]; then
    echo "$(date): Error getting memory info, retrying in 60 seconds..."
    sleep 60
    continue
  fi
  
  # 计算当前内存使用率
  mem_usage=$(echo "scale=2; $mem_used/$mem_total * 100.0" | bc)
  echo "$(date): Current memory usage: ${mem_usage}% (${mem_used}/${mem_total} KB)"
  
  # 检查内存使用率是否低于25%
  if [ $(echo "$mem_usage < 25" | bc) -eq 1 ]; then
    # 计算目标内存使用量（总内存的25%）
    target_mem_usage=$(echo "scale=0; $mem_total * 0.25 / 1" | bc)
    echo "$(date): Target memory usage: ${target_mem_usage} KB"
    
    # 计算需要额外占用的内存量
    stress_mem=$(echo "$target_mem_usage - $mem_used" | bc)
    echo "$(date): Memory to allocate: ${stress_mem} KB"
    
    # 确保需要分配的内存量大于0
    if [ $(echo "$stress_mem > 0" | bc) -eq 1 ]; then
      # 转换为MB
      stress_mem_in_mb=$(echo "scale=0; $stress_mem / 1024" | bc)
      echo "$(date): Memory to allocate in MB: ${stress_mem_in_mb}"
      
      # 确保分配的内存量合理（大于0且小于可用内存）
      if [ $stress_mem_in_mb -gt 0 ]; then
        # 获取可用内存量进行安全检查
        mem_available=$(echo $mem_info | awk '{print $7}')
        if [[ "$mem_available" =~ ^[0-9]+$ ]]; then
          available_mb=$(echo "scale=0; $mem_available / 1024" | bc)
          
          # 确保不会分配超过可用内存的80%
          safe_limit=$(echo "scale=0; $available_mb * 0.8 / 1" | bc)
          if [ $(echo "$stress_mem_in_mb > $safe_limit" | bc) -eq 1 ]; then
            stress_mem_in_mb=$safe_limit
            echo "$(date): Adjusted allocation to safe limit: ${stress_mem_in_mb}MB"
          fi
        fi
        
        echo "$(date): Using stress to allocate ${stress_mem_in_mb}MB of memory..."
        
        # 使用stress工具占用内存
        # --vm 1: 启动1个内存工作进程
        # --vm-bytes: 指定每个工作进程分配的内存量
        # --vm-keep: 保持分配的内存不释放
        # --timeout: 运行时间（300秒 = 5分钟）
        stress --vm 1 --vm-bytes "${stress_mem_in_mb}M" --vm-keep --timeout 300s &
        stress_pid=$!
        
        echo "$(date): Stress started with PID $stress_pid, will run for 300 seconds..."
        
        # 等待stress进程完成
        wait $stress_pid
        stress_exit_code=$?
        
        if [ $stress_exit_code -eq 0 ]; then
          echo "$(date): Stress completed successfully"
        else
          echo "$(date): Stress exited with code $stress_exit_code"
        fi
      else
        echo "$(date): Invalid memory allocation size: ${stress_mem_in_mb}MB"
      fi
    else
      echo "$(date): No additional memory allocation needed (calculated: ${stress_mem} KB)"
    fi
  else
    echo "$(date): Memory usage already above 25%, sleeping for 300 seconds..."
  fi
  
  # 等待300秒后进行下一次检查
  echo "$(date): Waiting 300 seconds before next check..."
  sleep 300
done

# 脚本退出时的清理工作
cleanup

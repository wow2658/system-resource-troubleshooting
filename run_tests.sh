#!/bin/bash

# run_tests.sh

export AGENT_LOG_DIR=/var/log/agent-app
mkdir -p $AGENT_LOG_DIR

run_monitor() {
    # 3초마다 monitor.sh 실행
    while true; do
        ./monitor.sh
        # 에러 발생 시 종료
        if [ $? -ne 0 ]; then
            break
        fi
        sleep 3
    done
}

run_scenario() {
    # 1. 시나리오 파라미터(인자) 받기
    # 리눅스 함수는 파라미터를 (arg1, arg2) 형태로 받지 않고, $1, $2 같은 위치 변수로 받는다.
    # local: 이 함수 안에서만 쓰고 버릴 '지역 변수'임을 선언한다.
    # [파라미터 설명 가이드]
    local scenario_name=$1
    local mem=$2
    local cpu=$3
    local mt=$4
    local timeout_secs=$5
    
    # 2. 테스트 시작 알림 화면 출력
    echo "====================================="
    echo "Starting Scenario: $scenario_name"
    echo "MEMORY_LIMIT=$mem, CPU_MAX_OCCUPY=$cpu, MULTI_THREAD_ENABLE=$mt"
    echo "====================================="
    
    # 3. 환경 변수(Environment Variable) 주입
    export MEMORY_LIMIT=$mem
    export CPU_MAX_OCCUPY=$cpu
    export MULTI_THREAD_ENABLE=$mt
    
    # 원본 파일 비우기 (단독 테스트용)
    > "$AGENT_LOG_DIR/agent_app.log"
    > "$AGENT_LOG_DIR/monitor.log"
    
    chmod 777 "$AGENT_LOG_DIR/agent_app.log" 2>/dev/null
    chmod 777 "$AGENT_LOG_DIR/monitor.log" 2>/dev/null

    # 5. 테스트 앱 백그라운드 실행 (화면에만 나오는 부팅 로그까지 파일에 모두 누적 기록)
    ./agent-leak-app-x86 >> "$AGENT_LOG_DIR/agent_app.log" 2>&1 &
    
    # $!: 직전에 백그라운드로 실행시킨 프로그램의 고유 번호(PID)를 보관한다.
    APP_PID=$!
    
    # 앱이 부팅되고 포트를 개방할 때까지 약 1~2초가 소요되므로 대기한다.
    sleep 2
    
    # 5-1. [UFW 활성화] 방화벽 켜기 (비밀번호 없이 sudo 가능)
    sudo ufw --force enable >/dev/null 2>&1
    
    # 5-2. [보안] 시크릿 키 권한 설정 (400)
    chmod 400 /home/agentuser/agent_home/api_keys/secret.key 2>/dev/null
    
    # 6. 모니터링 스크립 백그라운드 실행
    run_monitor &
    
    # 나중에 끄기 위해 모니터링 프로세스의 번호를 MON_PID에 보관한다.
    MON_PID=$!
    
    # 7. 타임아웃 및 앱 종료 대기 로직
    local timeout_triggered=0
    if [ "$timeout_secs" -gt 0 ]; then
        count=0
        while kill -0 $APP_PID 2>/dev/null; do
            sleep 1
            count=$((count+1))
            if [ $count -ge $timeout_secs ]; then
                echo "Timeout reached ($timeout_secs secs). Killing app..."
                NOW=$(date "+%Y-%m-%d %H:%M:%S")
                if [[ "$scenario_name" == *"Deadlock_Before"* ]]; then
                    MSG="[$NOW] [CRITICAL] 💀 데드락(교착상태) 발생: 앱이 응답을 멈추고 무한 대기에 빠짐 (타임아웃 ${timeout_secs}초 도달로 런너가 강제 사살)"
                else
                    MSG="[$NOW] [SUCCESS] 🎯 지정된 타임아웃(${timeout_secs}초) 도달! 앱이 뻗지 않고 무사히 생존했습니다. (방어 성공)"
                fi
                echo "$MSG"
                echo "$MSG" >> "$AGENT_LOG_DIR/monitor.log"
                pkill -9 -f agent-leak-app 2>/dev/null
                timeout_triggered=1
                break
            fi
        done
        
        # 타임아웃 전에 죽어버린 경우
        if [ $timeout_triggered -eq 0 ]; then
            NOW=$(date "+%Y-%m-%d %H:%M:%S")
            if [[ "$scenario_name" == *"CPU_Before"* ]]; then
                MSG="[$NOW] [CRITICAL] 💀 앱 강제 종료됨: 내부 하드코딩된 '자결 임계점(CPU 50% 초과)'을 넘어서 Watchdog이 사살함! (관제 스크립트의 20% 경고와 다름)"
                echo "$MSG"
            elif [[ "$scenario_name" == *"OOM_Before"* ]]; then
                MSG="[$NOW] [CRITICAL] 💀 앱 강제 종료됨: 내부 파라미터로 주입된 '자결 임계점(MEMORY ${mem}MB 초과)'을 넘어서 자결함! (관제 스크립트의 80% 경고와 다름)"
                echo "$MSG"
            else
                MSG="[$NOW] [CRITICAL] 💀 앱 강제 종료됨: 도커(Docker) 컨테이너의 '물리적 메모리 한계(120MB)'를 초과하여 OS OOM Killer가 사살함!"
                echo "$MSG"
            fi
        fi
    else
        wait $APP_PID 2>/dev/null
        NOW=$(date "+%Y-%m-%d %H:%M:%S")
        if [[ "$scenario_name" == *"OOM_Before"* ]]; then
            MSG="[$NOW] [CRITICAL] 💀 앱 강제 종료됨: 내부 파라미터로 주입된 '자결 임계점(MEMORY ${mem}MB 초과)'을 넘어서 자결함! (관제 스크립트의 80% 경고와 다름)"
            echo "$MSG"
        fi
    fi
    
    # 8. 잔여 프로세스 정리 (Clean-up)
    pkill -9 -f agent-leak-app 2>/dev/null
    sleep 3
    kill -9 $MON_PID 2>/dev/null
    
    # 완성된 로그를 예쁜 이름표를 붙여서 별도로 백업 (파일 분리 유지)
    cp "$AGENT_LOG_DIR/agent_app.log" "$AGENT_LOG_DIR/agent_app_${scenario_name}.log" 2>/dev/null
    cp "$AGENT_LOG_DIR/monitor.log" "$AGENT_LOG_DIR/monitor_${scenario_name}.log" 2>/dev/null
    
    echo "Scenario $scenario_name finished."
    echo ""
}

echo "Starting tests..."

# ==================================================================================================
# [파라미터 설명 가이드]
# run_scenario "시나리오명" [MEMORY_LIMIT(MB)] [CPU_MAX_OCCUPY(%)] [MULTI_THREAD_ENABLE(0/1)] [타임아웃(초)]
# - MEMORY_LIMIT: 낮게 주면(60) OOM 발생, 높게 주면(512) 생존.
# - CPU_MAX_OCCUPY: 높게 주면(80) 50% 방어 룰(Watchdog)에 걸려 자결, 낮게 주면(40) 안전하게 생존.
# - MULTI_THREAD: 0이면 순차 실행으로 데드락 회피, 1이면 스레드 경합 시켜 데드락 발생.
# - 타임아웃: 0이면 뻗을 때까지 무한 대기, 60/30이면 지정된 시간만큼 살았으면 성공으로 간주하고 종료.
# ==================================================================================================

# 1. CPU Spike (Before)
# [시행착오 노트] 데드락이나 OOM이 꼬이지 않도록 다른 변수들은 안전치(Memory 512, Thread 0)로 고정한다.
# CPU 사용률만 80%로 높게 잡아, 50% 초과 시 발동하는 Watchdog 강제 종료(SIGTERM) 로직을 순수하게 유도한다. (90초 타임아웃)
# run_scenario "CPU_Before" 512 80 0 90

# 1-1. CPU Spike (After)
# CPU 사용 제한을 40%로 낮춰 Watchdog 임계점(50%)을 회피하고 생존 확인 (60초 타임아웃)
# run_scenario "CPU_After" 512 40 0 60

# 2. OOM Crash (Before)
# [시행착오 노트] CPU는 안전하게 40%로 고정하고, 오직 MEMORY_LIMIT만 60MB로 타이트하게 잡아 순수한 OOM 종료를 유도한다.
# run_scenario "OOM_Before" 60 40 0 0

# 2-1. OOM Crash (After)
# 메모리를 512MB로 늘려 생존 시간 증가 확인 (180초 타임아웃)
# run_scenario "OOM_After" 512 40 0 180

# 3. Deadlock (Before)
# [시행착오 노트] CPU는 안전하게 40%로 낮춰 주고, 멀티스레드(1)를 활성화하여 완벽한 원형 대기(Circular Wait) 교착상태를 유도한다.
# run_scenario "Deadlock_Before" 512 40 1 60

# 3-1. Deadlock (After)
# 멀티스레드 해제(0)하여 스레드 순차 실행함으로써 데드락 회피 및 정상 동작 확인 (60초 타임아웃)
run_scenario "Deadlock_After" 512 40 0 120

echo "All tests completed."

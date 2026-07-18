#!/bin/bash
# 스크립트 실행 환경 설정 (명령어 인식 오류 방지를 위한 기본 경로 등록)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 로그 저장 디렉터리 및 파일 위치 변수 세팅
AGENT_LOG_DIR=/var/log/agent-app
# 환경 변수 MONITOR_LOG_FILE이 주입되면 그 파일을 쓰고, 없으면 기본 monitor.log를 사용한다.
LOG_FILE=${MONITOR_LOG_FILE:-$AGENT_LOG_DIR/monitor.log}

# 로그 타임스탬프용 현재 시각을 YYYY-MM-DD HH:MM:SS 형태로 추출
NOW=$(date "+%Y-%m-%d %H:%M:%S")
# [쉘 스크립트 문법 상식: $ 기호의 정체]
# 쉘 스크립트에서 $ 기호는 아주 중요한 두 가지 역할을 한다.
# 1. 변수 값 꺼내기 ($변수명): 변수(주머니) 안에 들어있는 "진짜 알맹이(값)"를 꺼내달라는 뜻이다. (예: $NOW, $LOG_FILE, $PID)
# 2. 명령어 결과 뽑아오기 $(명령어): 괄호 안의 리눅스 명령어를 몰래 먼저 실행하고, 그 화면에 뜰 "결과 텍스트"만 통째로 쏙 뽑아오라는 뜻이다.

# 1. 프로세스 생존 점검
# [명령어 어원 및 유래 상식]
# - pgrep (Process GREP): Process + grep(Global Regular Expression Print)의 약어. 수많은 프로세스 중 원하는 패턴을 찾아(grep) 출력해 주는 명령어이다.
# - head: 약어가 아니며, 데이터가 길 때 '머리(윗부분)'만 잘라서 보여준다는 직관적인 영단어 그 자체이다 (반대는 tail).
#
# [옵션 및 정규표현식(Regex) 기호 설명]
# - -f (full): 프로세스 이름뿐만 아니라 실행된 커맨드 전체 라인에서 "agent.*app" 패턴을 찾음
# - .* (정규표현식 와일드카드): 점(.)은 '아무 글자 1개', 별(*)은 '바로 앞 글자가 0번 이상 반복됨'을 뜻한다.
#   즉, 두 개가 합쳐진 '.*'는 "중간에 어떤 문자가 길게 끼어있든 다 무시하고 퉁치겠다"는 윈도우/쉘의 '*' 와일드카드와 완벽히 같은 역할을 한다.
# - -n 1 (number): 결과가 여러 개 나올 경우 맨 위에서 1줄만 자름
PID=$(pgrep -f "agent.*app" | tail -n 1)

# - [ -z ]: zero의 약자. 변수("$PID") 안에 들어있는 문자열의 길이가 0인지(비어있는지) 검사
if [ -z "$PID" ]; then 
    # =================================================================================
    # [ ✨ 핵심 로직: 프로세스 유언장(CRITICAL) 파싱 ]
    # 앱 사망 시, 무작정 "PID Not Found"만 찍는 대신 원본 로그(agent_app.log)를 뒤져서
    # 프로세스가 마지막으로 남긴 CRITICAL 원인 메시지를 찾아 관제 로그에 박아넣습니다!
    # =================================================================================
    LAST_CRITICAL=$(grep "\[CRITICAL\]" "$AGENT_LOG_DIR/agent_app.log" 2>/dev/null | tail -n 1 | awk -F'\[CRITICAL\] ' '{print $2}')
    if [ -n "$LAST_CRITICAL" ]; then
        echo "[$NOW] [CRITICAL] 프로세스 사망. 원인: $LAST_CRITICAL" >> $LOG_FILE
    else
        echo "[$NOW] [CRITICAL] 프로세스 사망 (PID Not Found). 모니터링 중단." >> $LOG_FILE
    fi
    exit 1
fi

# 2. 포트 바인딩 점검
# - ss: 네트워크 포트 상태 확인 명령어 (netstat의 최신 대체품)
# - -t (TCP), -u (UDP), -l (Listening 대기상태), -n (이름 대신 숫자 포트로 표시)
# - grep -q (quiet): 일치하는 문자열을 화면에 출력하지 않고 조용히 성공(0) 실패(1) 여부만 반환
if ! ss -tuln | grep -q ":15034"; then 
    echo "[$NOW] [CRITICAL] 15034 포트 단절 (Port Down). 모니터링 중단." >> $LOG_FILE
    exit 1
fi

# 3. 방화벽 점검 (경고)
WARN_MSG=""
if ! ufw status 2>/dev/null | grep -qw "active"; then 
    WARN_MSG="$WARN_MSG  [WARNING: UFW Inactive]"
fi

# 4. 자원 수집 (시스템 명령어의 출력물에서 불필요한 문자를 제거하고 순수 '수치'만 정밀하게 파싱)

# [TOP] 시스템 전체 CPU 및 대상 프로세스의 상태 추출 (top -n 2의 두 번째 결과가 실제 순간 점유율)
TOP_OUTPUT=$(top -b -n 2 -d 1)
TOP_SYS_CPU=$(echo "$TOP_OUTPUT" | grep "Cpu(s)" | tail -1 | awk '{print $2 + $4}')
# 1/2번째 반복문 전체에서 가장 CPU 점유율이 높은 프로세스를 동적으로 추출 (부모/자식 관계 무관하게 가장 일 많이 하는 놈 추적)
TOP_PROC_STATS=$(echo "$TOP_OUTPUT" | awk '/^ *[0-9]+/ {print $1, $9, $10}' | sort -k2 -nr | head -n 1)
ACTIVE_PID=$(echo "$TOP_PROC_STATS" | awk '{print $1}')
TOP_PROC_CPU=$(echo "$TOP_PROC_STATS" | awk '{print $2}')
NUM_CORES=$(grep -c ^processor /proc/cpuinfo)
TOP_PROC_CPU=$(echo "scale=1; $TOP_PROC_CPU * $NUM_CORES" | bc -l)
TOP_PROC_MEM=$(echo "$TOP_PROC_STATS" | awk '{print $3}')
if [ -z "$TOP_PROC_CPU" ]; then TOP_PROC_CPU="0.0"; fi
if [ -z "$TOP_PROC_MEM" ]; then TOP_PROC_MEM="0.0"; fi
CPU_USAGE=$TOP_PROC_CPU

# [PS] 프로세스 레벨의 CPU, MEM 추출 (Average over time)
PS_STATS=$(ps -p $PID -o %cpu,%mem,rss --no-headers | awk '{print $1, $2, $3}')
PS_PROC_CPU=$(echo "$PS_STATS" | awk '{print $1}')
PS_PROC_MEM=$(echo "$PS_STATS" | awk '{print $2}')
PS_PROC_RSS_KB=$(echo "$PS_STATS" | awk '{print $3}')
if [ -z "$PS_PROC_CPU" ]; then PS_PROC_CPU="0.0"; fi
if [ -z "$PS_PROC_MEM" ]; then PS_PROC_MEM="0.0"; fi
if [ -z "$PS_PROC_RSS_KB" ]; then PS_PROC_RSS_KB=0; fi
PS_PROC_RSS_MB=$((PS_PROC_RSS_KB / 1024))

# [APP] 앱 전용 자원 및 내부 임계치 대비 사용률(%) - Hybrid 관제 파싱 기법 적용!
# OS의 top 명령어는 스텔스 로드에 속아 0%를 반환하므로, agent_app.log 파일에서 앱이 주장하는 '순수 내부 수치'를 직접 긁어옵니다.

# 1. 앱 내부 CPU Load 수치 파싱
APP_CPU_LOG=$(grep "\[CpuWorker\] Current Load" "$AGENT_LOG_DIR/agent_app.log" 2>/dev/null | tail -n 1 | awk -F'Current Load: ' '{print $2}' | sed 's/%//' | tr -d '\r')
if [ -n "$APP_CPU_LOG" ]; then
    APP_CPU_PCT=$APP_CPU_LOG
else
    # 파싱 실패 시 기존 수식 백업
    if [ -n "$CPU_MAX_OCCUPY" ] && [ "$CPU_MAX_OCCUPY" -gt 0 ]; then
        APP_CPU_PCT=$(echo "scale=1; $TOP_PROC_CPU / $CPU_MAX_OCCUPY * 100" | bc -l)
    else
        APP_CPU_PCT="N/A"
    fi
fi

# 2. 앱 내부 Memory Heap 수치 파싱
APP_MEM_LOG=$(grep "\[MemoryWorker\] Current Heap" "$AGENT_LOG_DIR/agent_app.log" 2>/dev/null | tail -n 1 | awk -F'Current Heap: ' '{print $2}' | sed 's/MB//' | tr -d '\r')
if [ -n "$APP_MEM_LOG" ]; then
    APP_MEM_MB=$APP_MEM_LOG
else
    # 파싱 실패 시 ps 기반 백업
    APP_MEM_KB=$(ps -p $PID -o rss= | awk '{print $1}')
    if [ -z "$APP_MEM_KB" ]; then APP_MEM_KB=0; fi
    APP_MEM_MB=$((APP_MEM_KB / 1024))
fi

# 3. Memory 한계 대비 사용률(%) 계산
if [ -n "$MEMORY_LIMIT" ] && [ "$MEMORY_LIMIT" -gt 0 ]; then
    APP_MEM_PCT=$(( APP_MEM_MB * 100 / MEMORY_LIMIT ))
else
    APP_MEM_PCT=$(free | grep Mem | awk '{printf("%.0f", $3/$2 * 100)}')
fi
MEM_USAGE=$APP_MEM_PCT

# [DISK 사용량 추출 원리]
# 1. df / : 'Disk Free' 명령어. 시스템 루트 디스크의 용량 상태를 출력한다. (헤더 1줄과 데이터 1줄 출력됨)
# 2. | tail -1 : 헤더 줄을 제외하고 마지막 데이터 줄 1줄만 파이프라인으로 넘긴다.
# 3. | awk '{print $5}' : 공백 기준으로 문자열을 파싱하여, 5번째 컬럼에 위치한 디스크 사용률 데이터만 추출한다. (예: 28%)
# 4. | sed 's/%//' : 추출된 데이터의 '%' 문자를 제거하여 순수 정수 값만 남긴다. 이후 조건문에서의 정수형 비교 연산 에러를 방지하기 위함이다.
# df로 하드 상태 뽑고 👉 제목 줄 떼고 데이터 1줄만 남긴 다음 👉 5번째 칸에 있는 글자 뽑고 👉 '%' 기호는 지워버리고 숫자 알맹이만 내놓으라는 거구나
DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
DISK_USED_SIZE=$(df -h / | tail -1 | awk '{print $3}')


# 5. 임계값 경고 (파싱된 숫자 데이터들을 기반으로 조건부 경고 메시지를 문자열에 누적시킴)

# [CPU 임계값 비교 원리]
# MEM과 DISK는 이전 단계에서 순수 정수(Integer)로 정제해 두었으나, CPU는 합산 결과가 소수점(예: 3.5)으로 나온다.
# 리눅스 bash 쉘의 기본 [ ] 조건문은 소수점 비교 연산을 지원하지 못하므로, 기본 조건문에 그대로 넣으면 에러가 발생하며 터져버린다.
# 이를 해결하기 위해 리눅스 내장 소수점 계산기인 'bc(Basic Calculator)' 프로그램에 연산을 외주(하청) 맡긴다.
# 1. echo "$CPU_USAGE > 20" : 비교할 수식(예: 3.5 > 20)을 텍스트 문장으로 만든다.
# 2. | bc -l : 수식을 파이프(|)를 통해 계산기에 던져준다.
# 3. 계산기의 답변 : 수식이 참이면 1, 거짓이면 0을 뱉어낸다.
# 4. -eq 1 : 계산기가 뱉어낸 결과물이 1과 같은지(-eq, EQual) 우회하여 검증한다.

# 애초에 CPU도 메모리처럼 정수로 깎아버리면 이런 고생을 안 해도 되지 않을까?
# - 물론 정수형으로 만들면 조건문은 단순해지지만, CPU는 마이크로 버스트(미세한 부하 폭증)가 잦은 가장 민감한 자원이다.
# - 코드를 쉽게 짜겠다고 소수점을 버리면, 최종 로그를 수집하는 모니터링 대시보드(ELK 등)에서 정밀한 곡선 그래프를 그릴 수 없게 된다.
# - 즉, "조건문 작성이 조금 복잡해지더라도, 관제 데이터의 품질(정밀도)을 끝까지 사수하기 위한 설계적 결단"이다.

# 결론: 저 복잡한 한 줄은 "소수점 계산을 못 하니까, 문장으로 예쁘게 써서 계산기한테 물어보고 올게!"라는 처절한 몸부림의 결과물이다.
if [ $(echo "$CPU_USAGE > 40" | bc -l) -eq 1 ]; then 
    WARN_MSG="$WARN_MSG [WARNING: CPU High (관제 임계점)]"
fi

# [MEM / DISK 임계값 비교 원리]
# 4단계에서 소수점과 %를 떼어내고 순수 '정수(Integer)'로 정제해 둔 데이터를 비교한다.
# bash에서는 꺾쇠(>) 기호가 파일 저장용 리다이렉션으로 예약되어 있으므로, 전용 정수 비교 연산자인 '-gt'(Greater Than)를 사용하여 직관적으로 처리한다.
if [ "$MEM_USAGE" -gt 80 ]; then WARN_MSG="$WARN_MSG [WARNING: MEM High (관제 임계점)]"; fi
if [ "$DISK_USAGE" -gt 80 ]; then WARN_MSG="$WARN_MSG [WARNING: DISK High]"; fi


# 6. 관제 데이터 누적 (시계열 추적 및 수집기 연동을 고려한 로그 포맷팅)

# [중앙 집중형 로그 수집기 및 포맷 고정의 원리]
# - 실무 서버 운영 환경에서는 관리자가 수십, 수백 대의 서버에 일일이 들어가 로그 파일을 보지 않고, ELK(Logstash) 스택이나 Splunk 같은 '중앙 집중형 로그 수집기' 시스템을 구축해 한곳에서 모아본다.
# - 일기장처럼 줄바꿈을 많이 하거나 풀어서 쓰면 기계(로그 수집기)가 데이터를 파싱하지 못하므로, 규칙적인 'KEY:VALUE(이름표:값)' 구조를 유지하고 공백으로 칸을 구분한 단일 행(Single-line) 포맷으로 조립한다.
# - 이렇게 짜두면 수집기 내부의 패턴 분석 기술(정규표현식, Regex)이 "CPU 짝꿍은 몇 번, MEM 짝꿍은 몇 번" 하고 숫자만 번개처럼 쏙쏙 빼가서 모니터링 웹 화면에 실시간 상태 변화 대시보드 그래프를 아주 예쁘게 그릴 수 있다.
# - 과거부터 현재까지 서버 자원이 어떻게 변화했는지 히스토리(시계열 데이터)를 온전히 보존하기 위해, 파일을 덮어쓰는 기호('>')가 아닌 파일 맨 끝에 내용을 추가하여 누적하는 이어쓰기 리다이렉션 기호('>>')를 사용하여 관제 로그 파일에 영구 기록한다.
#
# [ELK, Splunk 및 단일 행(Single-line) 포맷 상세 해부]
# 1. ELK 스택과 Splunk란 무엇인가?
# - 서버 엔지니어와 개발자들의 필수 무기인 "중앙 집중형 로그 수집 및 분석 플랫폼"이다. 쉽게 말해 전교생의 일기장을 한 곳에 모아놓고 빅데이터 분석을 해주는 초대형 시스템이다.
# - 서버가 수십, 수백 대 단위로 넘어가면 장애 발생 시 일일이 서버에 접속해서(SSH) 로그를 뒤지는 것은 불가능에 가깝다.
# - 그래서 각 서버에서 생성되는 텍스트 로그들을 실시간으로 한곳에 빨아들인 다음, 웹 대시보드로 보여주고 검색하게 해주는 시스템이다.
# 
# 2. 대표적인 로그 수집 플랫폼
# - ELK Stack (오픈소스 진영): Elastic사에서 만든 세 가지 소프트웨어의 조합이다.
#   E (Elasticsearch): 거대한 검색 엔진이자 데이터베이스. 수억 건의 로그를 저장하고 0.1초 만에 찾아낸다.
#   L (Logstash): 스크립트가 뱉어내는 CPU:20% MEM:15% 같은 로그를 빨아들여서 정돈한 뒤 창고에 넣어준다.
#   K (Kibana): 창고에 쌓인 로그를 읽어와서 실시간 그래프, 파이 차트 등으로 시각화해 주는 웹 대시보드이다.
# - Splunk (상용 진영): 글로벌 대기업이나 금융권에서 표준으로 많이 쓰는 기업용 유료 소프트웨어로, 검색 문법이 매우 강력하다.
#
# 3. 왜 스크립트 주석에서 이를 언급하는가? 단일 행(Single-line) 포맷의 중요성
# - ELK나 Splunk 같은 로그 수집기들은 구구절절한 일기장 형식의 로그보다, 기계가 파싱하기 쉬운 KEY:VALUE(이름표:값) 형태의 단일 행(Single-line) 데이터를 선호한다.
# - 단일 행 포맷이란, 한 번 측정한 서버의 상태 데이터 전체를 줄바꿈(Enter) 없이 가로로 길게 딱 한 줄로만 이어 붙여서 기록하는 방식이다.
# 
# [멀티 행(Multi-line) 포맷의 문제점]
# [2026-07-17 10:45:00] 시스템 상태 보고
# - CPU 점유율: 20%
# - MEM 점유율: 15%
# - 사람 눈에는 잘 읽히지만, 기계는 보통 '한 줄 = 1개의 독립적인 데이터'로 인식하므로 데이터를 갈기갈기 찢어서 개별 처리해 버린다.
# 
# [단일 행(Single-line) 포맷의 장점]
# [2026-07-17 10:45:00] PID:1234 CPU:20% MEM:15% DISK:40% [WARNING: CPU High]
# - 완벽한 데이터 패키징: 기계가 저 한 줄만 딱 퍼가면 그 시간대의 모든 지표가 한 덩어리로 안전하게 수집된다.
# - 쉬운 파싱: 구조가 일정하므로 기계에게 "공백을 기준으로 잘라서 이름표:값 짝꿍을 찾아라"라고 명령하기 쉽다.
#
# 결론: 맨 마지막 줄을 보면 중간에 줄바꿈 없이 띄어쓰기로만 구분해서 길게 한 줄로 조립하여 출력하도록(echo ... >>) 설계해 둔 것이다. 
# [UPDATE] 로그 출력 시 앱의 고유 메모리 용량(MB)도 함께 기록하여 정밀 분석을 돕는다.
# [유저 특별 요청 반영] top, ps, app 로그를 한방에 보여주기 위해 상세 출력 추가!
# 단일 행 요약을 출력하기 전에, top과 ps 커맨드의 실제 출력물을 통째로 로그에 박아넣는다.
    # 4연속 0%이면 데드락 카운터 증가
    is_deadlock=0
    if [ "$(echo "$CPU_USAGE == 0" | bc -l)" -eq 1 ]; then
        if [ ! -f "/tmp/deadlock_counter" ]; then
            echo "1" > /tmp/deadlock_counter
        else
            deadlock_count=$(cat /tmp/deadlock_counter)
            deadlock_count=$((deadlock_count + 1))
            echo "$deadlock_count" > /tmp/deadlock_counter
            if [ "$deadlock_count" -ge 4 ]; then
                is_deadlock=1
            fi
        fi
    else
        echo "0" > /tmp/deadlock_counter
    fi



    SUMMARY_LINE="[$NOW] PROCESS:agent-leak-app TOP_CPU:${TOP_PROC_CPU}% PS_CPU:${PS_PROC_CPU}% PARSING_CPU:${APP_CPU_PCT}% TOP_MEM:${TOP_PROC_MEM}%(${PS_PROC_RSS_MB}MB) PS_MEM:${PS_PROC_MEM}%(${PS_PROC_RSS_MB}MB) PARSING_MEM:${APP_MEM_PCT}%(${APP_MEM_MB}MB) DISK:${DISK_USAGE}%(${DISK_USED_SIZE}) $WARN_MSG"

    if [ $is_deadlock -eq 1 ]; then
        echo "$SUMMARY_LINE [CRITICAL: DEADLOCK DETECTED - Silent Hang]" >> $LOG_FILE
    else
        echo "$SUMMARY_LINE" >> $LOG_FILE
    fi
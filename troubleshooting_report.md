# 시스템 장애 분석 및 이슈 리포트 (GitHub Issue 형식)

본 리포트는 과제 요구사항에 따라 3가지 장애 유형(CPU 과점유, OOM Crash, Deadlock)에 대해 GitHub Issue 형태로 작성된 기술 보고서입니다.

---

## Issue #1: [Bug] CPU 과점유 - Watchdog 방어 로직에 의한 프로세스 강제 종료

### 1. Description (현상 설명)
- **발생 현상**: `agent-leak-app` 실행 후 약 30초가 경과하자, 시스템 모니터링 도구(`top`, `ps`) 상으로는 CPU 점유율이 임계치(80%)에 도달하지 않았음에도 불구하고 프로세스가 돌연 사망하는 현상이 발생했습니다.
- **발생 조건**: 앱 구동 시 할당된 컨테이너의 `CPU_MAX_OCCUPY` 파라미터가 80%로 설정된 상태(`CPU_Before` 시나리오)에서 발생했습니다.

### 2. Evidence & Logs (증거 자료)
**1. monitor.sh 관제 로그 (`monitor_CPU_Before.log`)**
```text
[2026-07-18 19:06:20] PROCESS:agent-leak-app TOP_CPU:36.0% PS_CPU:0.8% PARSING_CPU:35.11% ... [UFW Active]
[2026-07-18 19:06:24] PROCESS:agent-leak-app TOP_CPU:0% PS_CPU:0.8% PARSING_CPU:42.89% ... [UFW Active]
[2026-07-18 19:06:29] PROCESS:agent-leak-app TOP_CPU:12.0% PS_CPU:0.9% PARSING_CPU:43.48% ... [UFW Active]
[2026-07-18 19:06:33] [CRITICAL] 프로세스 사망. 원인: [CpuWorker] CPU Threshold Violated! (51.370000000000005%).
```
> `top` 명령어는 0~36% 사이를 요동치며 실제 부하를 놓쳤으나, 하이브리드 파싱 모니터(`PARSING_CPU`)는 실제 부하가 51%까지 점진적으로 상승함을 정확히 포착했습니다.

**2. 프로그램 실행 로그 (`agent_app_CPU_Before.log`)**
```text
2026-07-18 19:06:27,952 [INFO] [CpuWorker] Current Load: 43.48%
2026-07-18 19:06:31,069 [INFO] [CpuWorker] Current Load: 51.37%
2026-07-18 19:06:31,172 [CRITICAL] [CpuWorker] CPU Threshold Violated! (51.370000000000005%).
```

### 3. Root Cause Analysis (원인 분석)
- **Watchdog 보호 조치**: 애플리케이션 내부(`CpuWorker`)에 CPU 점유율이 50%를 초과할 경우, 시스템 전체의 마비를 방지하기 위해 스스로 프로세스를 사살(SIGTERM)하는 `Watchdog` 정책이 하드코딩되어 있었습니다. 파라미터로 주입된 80%까지 도달하기 전, 부하가 51.37%를 넘기자 이 보호 로직이 발동하여 앱이 자결한 것입니다.
- **OS 모니터링 도구의 기만 (Micro-burst)**: 앱이 찰나의 순간에만 연산을 수행하고 길게 쉬는 마이크로 슬립(Micro-sleep) 기법을 사용했습니다. 리눅스의 `top` 명령어는 주기적으로 스냅샷을 찍는 폴링(Polling) 구조의 근본적 한계를 지녀, 이 엇갈리는 타이밍에 의해 부하를 0% 또는 12%로 오판했습니다. `ps` 명령어 역시 긴 휴식 시간에 의해 누적 평균치가 희석되어 0.9%의 정상 수치로 잘못 보고했습니다. 

### 4. Workaround & Verification (조치 및 검증)
- **조치 내용**: `run_tests.sh` 내 컨테이너 환경변수 파라미터 `CPU_MAX_OCCUPY` 값을 기존 80%에서 Watchdog 자결 임계점(50%)보다 낮은 **40%**로 하향 조정(`CPU_After` 시나리오)하여 부하의 상한선을 원천 제한했습니다.
- **Before & After 비교**:
  - **Before**: 부하가 지속 상승하여 51.37%에 도달 ➡ Watchdog 발동으로 약 30초 만에 프로세스 자결.
  - **After**: 부하가 정확히 40.00%에서 정점을 찍고 쿨다운(Cooldown) 사이클로 진입하여, 정해진 타임아웃(60초)까지 죽지 않고 무사히 생존함.
```text
[2026-07-18 19:16:43] PROCESS:agent-leak-app TOP_CPU:0% PARSING_CPU:40.00% ... [UFW Active]
[2026-07-18 19:16:47] PROCESS:agent-leak-app TOP_CPU:36.0% PARSING_CPU:36.36% ... [UFW Active]
...
[2026-07-18 19:17:17] [SUCCESS] 🎯 지정된 타임아웃(60초) 도달! 앱이 뻗지 않고 무사히 생존했습니다. (방어 성공)
```

---

## Issue #2: [Bug] OOM Crash - 메모리 누수로 인한 MemoryGuard 자결 및 프로세스 종료

### 1. Description (현상 설명)
- **발생 현상**: `agent-leak-app` 실행 후 불과 10여 초 만에 메모리 사용량이 급증하다가, 프로세스가 돌연 강제 종료(사망)하는 현상이 발생했습니다.
- **발생 조건**: 앱 구동 시 할당된 컨테이너의 `MEMORY_LIMIT` 환경변수가 60MB로 매우 타이트하게 설정된 상태(`OOM_Before` 시나리오)에서 발생했습니다.

### 2. Evidence & Logs (증거 자료)
**1. monitor.sh 관제 로그 (`monitor_OOM_Before.log`)**
```text
[2026-07-18 19:51:21] PROCESS:agent-leak-app TOP_CPU:0% ... PARSING_MEM:83%(50MB) ... [UFW Active] [WARNING: MEM High (관제 임계점)]
[2026-07-18 19:51:26] [CRITICAL] 프로세스 사망. 원인: [MemoryGuard] Self-terminating process 12 to prevent system instability.
```

**2. 프로그램 실행 로그 (`agent_app_OOM_Before.log`)**
```text
2026-07-18 19:51:20,283 [INFO] [MemoryWorker] Current Heap: 50MB
2026-07-18 19:51:23,328 [INFO] [MemoryWorker] Current Heap: 75MB
2026-07-18 19:51:23,329 [CRITICAL] [MemoryGuard] Memory limit exceeded (75MB >= 60MB) / (Recommend Over 256MB)
2026-07-18 19:51:23,331 [CRITICAL] [MemoryGuard] Self-terminating process 12 to prevent system instability.
```

### 3. Root Cause Analysis (원인 분석)
- **메모리 누수(Memory Leak) 결함**: 어플리케이션(`MemoryWorker`) 내부 로직에서 약 3초 단위로 25MB의 힙(Heap) 메모리를 무한정 할당하기만 하고 해제(Garbage Collection 또는 Free)하지 않는 치명적인 메모리 누수 결함이 존재합니다.
- **MemoryGuard 방어 로직**: 컨테이너나 호스트 전체의 물리적 메모리가 고갈되어 시스템 패닉(OS OOM Killer 발동)이 발생하는 최악의 사태를 막기 위해, 앱 내부에 `MemoryGuard` 정책이 내장되어 있습니다. 이 로직은 주입된 `MEMORY_LIMIT` (현재 60MB)를 초과(75MB 도달)하자, 시스템 불안정성을 예방하기 위해 프로세스를 스스로 SIGTERM(사살)시켰습니다.

### 4. Workaround & Verification (조치 및 검증)
- **조치 내용**: `run_tests.sh` 내 컨테이너 환경변수 파라미터 `MEMORY_LIMIT` 값을 기존 60MB에서 `MemoryGuard`가 권장하는 256MB를 상회하는 **512MB**로 대폭 상향 조정(`OOM_After` 시나리오)하여 가용 메모리를 넉넉히 확보했습니다. 관찰 시간을 3분(180초)으로 연장하여 누수의 끝을 확인했습니다.
- **Before & After 비교**:
  - **Before**: 60MB 한계에 부딪혀 약 10초 만에 강제 종료됨.
  - **After**: 메모리 누수가 525MB까지 치솟았으나 앱이 터지지 않았으며, 도리어 앱에 내장된 **자가 치유(Cache Flush)** 메커니즘이 정상 발동하여 힙 메모리를 25MB로 완벽히 비워내고 안정화(`[System] Memory Cache Flushed`)되는 것을 확인했습니다. 이후 180초 타임아웃까지 무사히 생존함.
```text
[2026-07-18 20:12:08] PROCESS:agent-leak-app TOP_CPU:36.0% ... PARSING_MEM:97%(500MB) ... [UFW Active] [WARNING: MEM High]
[2026-07-18 20:12:12] PROCESS:agent-leak-app TOP_CPU:0% ... PARSING_MEM:102%(525MB) ... [UFW Active] [WARNING: MEM High]
[2026-07-18 20:12:16] PROCESS:agent-leak-app TOP_CPU:0% ... PARSING_MEM:4%(25MB) ... [UFW Active]
```
- **최종 결론**: 512MB 증설은 단순한 "생명 연장(임시방편)"이 아니었습니다! 앱 내부에는 약 525MB 도달 시 메모리를 자체적으로 청소(Garbage Collection)하는 `Cache Flush` 로직이 설계되어 있었습니다. 그러나 기존 환경변수가 60MB로 너무 낮게 설정된 탓에, 앱이 스스로 치료를 시작하기도 전에 `MemoryGuard`가 앱을 강제 사살해 버렸던 것입니다. 즉, **올바른 메모리 임계치(512MB) 설정 자체가 이 장애의 완벽한 근본 해결책**이었음을 증명했습니다.

---

## Issue #3: [Bug] Deadlock - 멀티스레드 환경에서 원형 대기(Circular Wait)로 인한 영구 정지(Hang)

### 1. Description (현상 설명)
- **발생 현상**: `agent-leak-app` 실행 후 몇 초 지나지 않아 프로그램의 연산이 완전히 멈추고, 어떠한 로그도 추가로 출력되지 않는 영원한 대기 상태(식물인간 상태)에 빠졌습니다.
- **발생 조건**: 컨테이너 구동 시 `MULTI_THREAD_ENABLE=1` 파라미터를 주입하여 100개의 스레드가 동시에 자원에 접근하도록 허용한 상태(`Deadlock_Before` 시나리오)에서 발생했습니다.

### 2. Evidence & Logs (증거 자료 및 로그 상세 해설)
이 로그는 "데드락(교착 상태)"이 발생하는 아주 전형적인 과정을 실시간으로 보여주고 있습니다.

**[로그 번역 및 현상 해설]**

```text
2026-07-18 20:15:36,249 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
2026-07-18 20:15:36,249 [INFO] [AgentWorker][Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
```
👉 **스레드 1**: "작업 시작! 일단 공유 메모리 A에 자물쇠(Lock)를 채우러 갑니다."
👉 **스레드 2**: "나도 작업 시작! 나는 소켓 풀 B에 자물쇠 채우러 갑니다."

```text
2026-07-18 20:15:36,251 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-07-18 20:15:36,252 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
```
👉 **스레드 1**: "공유 메모리 A 획득 완료! (안 놔주고 꽉 쥐고 있음)"
👉 **스레드 2**: "소켓 풀 B 획득 완료! (나도 안 놔주고 꽉 쥐고 있음)"

```text
2026-07-18 20:15:36,255 [INFO] [AgentWorker][Worker-Thread-1] Processing critical data in Memory A...
2026-07-18 20:15:36,257 [INFO] [AgentWorker][Worker-Thread-2] Establishing network connections in Pool B...
```
👉 **스레드 1**: "메모리 A에서 중요 데이터 처리 중..."
👉 **스레드 2**: "소켓 풀 B에서 네트워크 연결 설정 중..."
*(여기까지는 각자 자기 할 일을 잘 하고 있습니다. 하지만 이제 문제가 터집니다)*

```text
2026-07-18 20:15:38,268 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
2026-07-18 20:15:38,270 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
```
👉 **스레드 1**: "앗, 작업을 끝내려면 소켓 풀 B가 추가로 필요한데? 소켓 풀 B 넘겨줄 때까지 여기서 대기할게! (상태: BLOCKED(막힘))"

```text
2026-07-18 20:15:38,272 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
2026-07-18 20:15:38,274 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```
👉 **스레드 2**: "어? 나도 로그를 쓰려면 공유 메모리 A가 추가로 필요한데? 공유 메모리 A 넘겨줄 때까지 나도 여기서 대기할게! (상태: BLOCKED(막힘))"

**2. monitor.sh 관제 로그 (`monitor_Deadlock_Before.log`) 및 시스템 도구(`ps`, `top`) 교차 검증**
관제 스크립트는 내부적으로 `pgrep`과 `top`, `ps`를 파싱하여 아래와 같이 자원 사용량이 0%로 수렴하는 'Silent Hang' 상태를 완벽히 감지해 냈습니다.

```text
[2026-07-18 20:15:44] PROCESS:agent-leak-app TOP_CPU:0% ... PARSING_CPU:0% ... PARSING_MEM:3% ... [CRITICAL: DEADLOCK DETECTED - Silent Hang]
[2026-07-18 20:16:01] PROCESS:agent-leak-app TOP_CPU:0% ... PARSING_CPU:0% ... PARSING_MEM:3% ... [CRITICAL: DEADLOCK DETECTED - Silent Hang]
...
[2026-07-18 20:16:31] [CRITICAL] 💀 데드락(교착상태) 발생: 앱이 응답을 멈추고 무한 대기에 빠짐 (타임아웃 60초 도달로 런너가 강제 사살)
```
> **[평가 요구사항: 수동 교차 검증 방법]**
> - **PID 존재 증거 (`ps -ef | grep agent-leak-app`)**: 위 관제 중 해당 명령어를 치면 프로세스(PID)가 죽지 않고 살아있음을 확인할 수 있습니다.
> - **CPU/MEM 변화 정체 증거 (`top -H` 또는 `ps -L`)**: 해당 명령어로 스레드 단위 조회를 해보면, 모든 워커 스레드의 CPU 점유율 수치가 단 0.1%도 요동치지 않고 완전히 정체(Stagnation)된 상태임을 직접 눈으로 교차 검증할 수 있습니다.

### 3. Root Cause Analysis (원인 분석)
결국, **스레드 1**은 자신이 가진 A를 안 놓은 채로 스레드 2가 가진 B를 달라고 버티고, 동시에 **스레드 2**는 자신이 가진 B를 안 놓은 채로 스레드 1이 가진 A를 달라고 버티는 상황입니다.
마치 두 고집불통이 서로 "네가 먼저 손에 쥔 거 놔라!" 하면서 영원히 양보하지 않고 대치하는 상태, 이것이 바로 컴퓨터 공학에서 말하는 **'데드락(Deadlock, 교착 상태)'**입니다. 그래서 앱이 오류를 뿜고 죽지도 못한 채, 영원히 Status: BLOCKED 상태로 멈춰서 '식물인간'이 되어버린 것입니다.

### 4. Workaround & Verification (조치 및 검증)
- **조치 내용**: `run_tests.sh` 내 환경변수 파라미터 `MULTI_THREAD_ENABLE` 값을 1에서 **0**으로 비활성화(`Deadlock_After` 시나리오)하여, 스레드들이 자원을 동시에 경합하지 않고 순차적으로 점유하고 해제하도록 제어 흐름을 강제했습니다.
- **Before & After 비교**:
  - **Before**: 런타임 직후 100개의 스레드가 락(Lock)을 물고 물려 응답을 멈추고 60초 타임아웃에 의해 강제 사살됨.
  - **After**: 단일 스레드로 동작하게 되면서 자원 경합이 원천 차단되었으며, 교착 상태 없이 관제 타임아웃(60초) 시점까지 모든 연산을 안정적으로 수행하고 `[SUCCESS]` 판정을 받으며 무사히 생존함.
```text
[2026-07-18 20:48:04] [Thread-A] Task Started. Calculating... (20%)
...
[2026-07-18 20:48:04] [Scheduler] All tasks completed.
...
[2026-07-18 20:50:29] [SUCCESS] 🎯 지정된 타임아웃(60초) 도달! 앱이 뻗지 않고 무사히 생존했습니다. (방어 성공)
```
- **근본적 해결 제안**: 멀티스레드 환경을 아예 끄는(0) 것은 애플리케이션의 성능 저하를 초래하는 임시 회피책(Workaround)에 불과합니다. 근본적인 해결을 위해서는 멀티스레드를 유지하되, 소스 코드 레벨에서 **모든 스레드가 동일한 순서(예: 무조건 A 획득 후 B 획득)로 Lock을 요청하도록 리팩토링(Lock Ordering)** 하거나 타임아웃 락(Timeout Lock) 기법을 도입해야 합니다.

---

## 5. 보너스 과제 (선택): 스케줄링 알고리즘 추론

### [Analysis] 로그 패턴 분석을 통한 스케줄링 알고리즘 추론

#### 1. 로그 관찰 개요
`agent-leak-app`의 정상 실행 상태(멀티스레드 비활성화, 순차 모드)에서 발생하는 워커(Worker) 스레드들의 작업 로그를 수집하여, OS 또는 런타임이 작업을 처리하는 스케줄링 기법을 역추적했습니다.

#### 2. 증거 자료 (Application Log Snapshot)
로그의 타임스탬프와 작업 진행률(Progress)을 분석한 결과, 하나의 작업이 완료되기 전에 다른 작업이 끼어드는 현상이 관측되었습니다.

```text
[2026-07-18 20:48:04,336] [Thread-A] Task Started. Calculating... (20%)
[2026-07-18 20:48:04,388] [Thread-A] Calculating... (40%)
[2026-07-18 20:48:04,440] [Thread-A] Preempted. Progress saved at (40%) <-- A 중단(선점됨)
[2026-07-18 20:48:04,492] [Thread-B] Task Started. Calculating... (20%) <-- B 시작
[2026-07-18 20:48:04,544] [Thread-B] Calculating... (40%)
[2026-07-18 20:48:04,596] [Thread-B] Preempted. Progress saved at (40%) <-- B 중단
[2026-07-18 20:48:04,648] [Thread-C] Task Started. Calculating... (20%) <-- C 시작
[2026-07-18 20:48:04,701] [Thread-C] Calculating... (40%)
[2026-07-18 20:48:04,755] [Thread-C] Preempted. Progress saved at (40%) <-- C 중단
[2026-07-18 20:48:04,807] [Thread-A] Resumed. Calculating... (60%)      <-- A 재개
```

#### 3. 패턴 분석 및 결론
* **순차 처리(FCFS) 아님**: 
  만약 FCFS (선입선출) 이었다면? 식당에서 줄 선 순서대로 밥을 먹는 방식입니다. `Thread-A`가 먼저 도착했으니 끝날 때까지 CPU를 절대 양보하지 않습니다.
  
  **[예상 로그 형태]**
  ```text
  [Thread-A] Task Started. Calculating... (20%)
  [Thread-A] Calculating... (40%)
  [Thread-A] Calculating... (60%)
  [Thread-A] Calculating... (80%)
  [Thread-A] Task Completed. (100%)  <-- 중간에 끊기는 일 없이 혼자 끝까지 다 씀!
  [Thread-B] Task Started. Calculating... (20%)
  [Thread-B] Calculating... (40%)
  ... (B 완료 후 C 시작)
  ```
  - **특징**: `Preempted(중단)`나 `Resumed(재개)`라는 단어가 로그에 절대 등장하지 않습니다. A가 100% 끝날 때까지 B와 C는 하염없이 기다려야만 하는(Convoy Effect) 답답한 로그가 찍혔을 겁니다. 하지만 실제 로그에서는 40% 시점에 강제로 실행 권한을 뺏기는(Preempted) 현상이 관찰되었습니다.

* **우선순위(Priority) 아님**: 
  만약 Priority (우선순위) 이었다면? 스레드마다 VIP 등급이 매겨져 있는 방식입니다. (예: `Thread-A: 일반`, `Thread-B: VIP`, `Thread-C: VVIP`)

  **[예상 로그 형태 (선점형 우선순위의 경우)]**
  ```text
  [Thread-A] Task Started. Calculating... (20%)
  [Thread-A] Calculating... (40%)
  [Thread-A] Preempted. <-- 갑자기 나보다 높은 VIP(B)가 등장해서 쫓겨남
  [Thread-B] Task Started. Calculating... (20%)
  [Thread-B] Preempted. <-- 앗! 제일 높은 VVIP(C)가 등장해서 B도 쫓겨남
  [Thread-C] Task Started. Calculating... (20%)
  [Thread-C] Calculating... (100%) Task Completed. <-- VVIP인 C는 끝까지 방해받지 않고 완료
  [Thread-B] Resumed. Calculating... (40%) ... (B 완료)
  [Thread-A] Resumed. Calculating... (60%) ... (A 완료)
  ```
  - **특징**: 라운드 로빈처럼 "골고루 40%씩 나눠 가지는" 패턴이 무너집니다. 우선순위가 높은 작업이 100% 완료될 때까지 낮은 작업은 계속 뒤로 밀리며, 최악의 경우 일반 등급인 A는 영원히 CPU를 할당받지 못해 굶어 죽는(Starvation) 현상이 발생했을 수도 있습니다. 하지만 실제로는 특정 스레드의 잦은 독점이나 새치기 없이 A -> B -> C 순서대로 정확히 40% 분량만큼 공평하게 CPU를 교대하는 모습을 보입니다.

* **최종 결론**: 
  위 증거들을 종합할 때, 각 스레드가 정해진 시간 또는 작업 할당량(Quantum)만큼 CPU를 사용한 뒤 강제로 자원을 반납(Preempted)하고 큐의 다음 스레드에게 기회를 넘기는 **라운드 로빈(Round-Robin, RR) 알고리즘**으로 완벽하게 추론됩니다.

#### 4. 라운드 로빈(Round-Robin) 스케줄링의 아키텍처 적합성 분석
* **장점**: 모든 프로세스가 공평하게 CPU 시간을 할당받으므로 특정 프로세스가 자원을 독점해 다른 프로세스가 굶어 죽는 기아(Starvation) 현상이 발생하지 않습니다. 응답 시간이 예측 가능하고 평균적으로 빠릅니다.
* **단점**: 시간 할당량(Quantum)을 너무 짧게 설정하면 문맥 교환(Context Switching) 오버헤드가 커져 전체 시스템 성능이 저하될 수 있으며, 너무 길게 설정하면 FCFS와 다를 바 없게 됩니다.
* **적합한 아키텍처**:
  - 사용자에게 짧은 지연 시간 안에 공평하게 응답해야 하는 **대화형 시스템**이나 **실시간 응답이 중요한 웹 서버(Web Server)**에 매우 적합합니다. 다수의 클라이언트 요청을 동시에 끊김 없이 처리하는 듯한 환상을 제공할 수 있습니다.
  - 반면, 무거운 연산을 한 번에 끝까지 처리해야 하는 **배치 처리(Batch Processing) 서버**에는 잦은 문맥 교환으로 인한 오버헤드 때문에 부적합합니다.

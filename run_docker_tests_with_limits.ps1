# [스크립트 존재 이유 및 핵심 원리]
# 이 스크립트는 매번 길고 복잡한 docker run 명령어를 타이핑하는 번거로움을 없애기 위한 '매크로(바로가기)' 역할을 합니다.
# 
# 특히 핵심은 -v (Volume Mount) 옵션입니다.
# 과제로 주어진 도커 이미지(agent-tester) 내부에는 우리가 수정한 최신 테스트/관제 스크립트가 없습니다.
# 따라서 윈도우 환경에 있는 우리 파일들을 리눅스 도커 컨테이너 내부로 덮어쓰기(주입) 하여 실행시키기 위해
# -v 옵션으로 파일 및 폴더 경로들을 연결해 주는 것입니다.

Write-Output "====================================================================="
Write-Output " [안내] Docker 컨테이너에서 시스템 장애(CPU, OOM, Deadlock) 테스트를 시작합니다."
Write-Output "====================================================================="

# [Docker 명령어 한 줄씩 파헤치기]
# docker run : 새로운 도커 컨테이너를 하나 생성하고 실행하라는 기본 명령어
# --rm       : (ReMove) 테스트가 끝나고 컨테이너가 종료되면, 찌꺼기로 남지 않게 즉시 자동 삭제(깔끔한 뒷정리)
# [Docker 명령어 한 줄씩 파헤치기]
# docker run : 새로운 도커 컨테이너를 하나 생성하고 실행하라는 기본 명령어
# --rm       : (ReMove) 테스트가 끝나고 컨테이너가 종료되면, 찌꺼기로 남지 않게 즉시 자동 삭제(깔끔한 뒷정리)
# -v (Volume) : 내 윈도우 컴퓨터의 폴더와 도커 리눅스의 폴더를 "동기화(연결)" 하라는 옵션
#   - "${PWD}\logs" (윈도우 폴더) -> 도커 안의 "/var/log/agent-app" 폴더에 연결함 (앱 로그 실시간 저장용)
#   - "${PWD}\run_tests.sh" -> 도커 안의 쉘 스크립트에 덮어쓰기(주입)
#   - "${PWD}\monitor.sh" -> 도커 안의 관제 스크립트에 덮어쓰기(주입)
# agent-tester : 실행할 도커 이미지의 이름
# bash -c "명령어" : 컨테이너가 켜지자마자 리눅스 쉘을 열고 run_tests.sh를 즉시 실행하라!
# ` (백틱)   : 파워쉘에서 "명령어가 너무 기니까 아랫줄로 계속 이어집니다"를 뜻하는 줄바꿈 연장 기호

docker run --rm `
  -v "${PWD}\logs:/var/log/agent-app" `
  -v "${PWD}\run_tests.sh:/home/agentuser/run_tests.sh" `
  -v "${PWD}\monitor.sh:/home/agentuser/monitor.sh" `
  agent-tester bash -c "/home/agentuser/run_tests.sh"

Write-Output ""
Write-Output "테스트가 완료되었습니다!"

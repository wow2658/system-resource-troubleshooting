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

# docker run : 새로운 도커 컨테이너를 생성하고 실행하라는 명령어
# --rm       : (ReMove) 테스트가 끝나면 컨테이너 찌꺼기를 자동 삭제
docker run --rm `
# --cap-add=NET_ADMIN, NET_RAW : 방화벽(UFW) 테스트를 위해 컨테이너에 네트워크 제어 특권을 부여합니다.
# ` (백틱)   : 파워쉘에서 명령어를 아랫줄로 계속 이어갈 때 쓰는 연장 기호
  --cap-add=NET_ADMIN --cap-add=NET_RAW `
  # -v (Volume Mount) 옵션: Dockerfile의 COPY로 구워진 옛날 파일 무시하고, 내 컴퓨터 최신 파일로 덮어쓰기(주입)
  #   - "${PWD}\logs" -> 밖의 logs 폴더를 도커 안의 로그 폴더와 연결 (로그 실시간 저장)
  -v "${PWD}\logs:/var/log/agent-app" `
  #   - "${PWD}\run_tests.sh" -> 내 컴퓨터의 최신 테스트 스크립트를 도커 안에 덮어쓰기
  -v "${PWD}\run_tests.sh:/home/agentuser/run_tests.sh" `
  #   - "${PWD}\monitor.sh" -> 내 컴퓨터의 최신 관제 스크립트를 도커 안에 덮어쓰기
  -v "${PWD}\monitor.sh:/home/agentuser/monitor.sh" `
  # bash -c "명령어" : 컨테이너가 켜지자마자 리눅스 쉘을 열고 명령어를 즉시 실행
  
  # agent-tester : 실행할 도커 이미지의 이름
  agent-tester bash -c "/home/agentuser/run_tests.sh"

Write-Output ""
Write-Output "테스트가 완료되었습니다!"

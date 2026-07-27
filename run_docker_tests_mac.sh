#!/bin/bash

echo "====================================================================="
echo " [안내] Mac/Linux 환경에서 Docker 시스템 장애 테스트를 시작합니다."
echo "====================================================================="

# 1. 테스트 결과가 저장될 logs 디렉토리가 없다면 자동 생성
mkdir -p "${PWD}/logs"

# 2. Docker 컨테이너 실행 (1:1 대응 주석을 위해 Bash 배열 방식 사용)
# Bash(Mac) 환경에서는 명령어 줄바꿈(\) 사이에 주석(#)을 넣으면 스크립트가 고장나기 때문에 이렇게 작성합니다.
DOCKER_ARGS=(
  # --rm : 테스트가 끝나면 컨테이너 찌꺼기를 자동 삭제
  --rm
  
  # --cap-add=NET_ADMIN, NET_RAW : 방화벽(UFW) 테스트를 위해 컨테이너에 네트워크 제어 특권을 부여합니다.
  --cap-add=NET_ADMIN
  --cap-add=NET_RAW
  
  # -v (Volume Mount) 옵션: Dockerfile의 COPY로 구워진 옛날 파일 무시하고, 내 컴퓨터 최신 파일로 덮어쓰기(주입)
  # 밖의 logs 폴더를 도커 안의 로그 폴더와 연결 (로그 실시간 저장)
  -v "${PWD}/logs:/var/log/agent-app"
  
  # 내 컴퓨터의 최신 테스트 스크립트를 도커 안에 덮어쓰기
  -v "${PWD}/run_tests.sh:/home/agentuser/run_tests.sh"
  
  # 내 컴퓨터의 최신 관제 스크립트를 도커 안에 덮어쓰기
  -v "${PWD}/monitor.sh:/home/agentuser/monitor.sh"
)

# agent-tester : 실행할 도커 이미지의 이름
# bash -c "명령어" : 컨테이너가 켜지자마자 리눅스 쉘을 열고 명령어를 즉시 실행
docker run "${DOCKER_ARGS[@]}" agent-tester bash -c "/home/agentuser/run_tests.sh"

echo ""
echo "테스트가 완료되었습니다! 결과는 logs/ 폴더를 확인해주세요."

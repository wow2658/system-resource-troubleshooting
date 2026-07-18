# [기본 이미지 설정]
# 도커 컨테이너의 뼈대가 될 운영체제를 지정한다.
# 태그(22.04)를 명시하여, 나중에 빌드해도 항상 동일한 우분투 22.04 버전을 가져오도록 고정한다. (재현성 보장)
FROM ubuntu:22.04

# [타임존(KST) 세팅]
# Ubuntu 컨테이너의 기본 시간대는 UTC(협정 세계시)이므로, 한국 표준시(Asia/Seoul)로 강제 고정한다.
ENV TZ=Asia/Seoul
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# [필수 패키지 설치]
# RUN: 도커 이미지를 빌드하는 동안 리눅스 쉘 명령어를 실행하라는 지시어이다.
# 1. apt-get update: 우분투 패키지 저장소의 최신 목록을 다운로드한다.
# 2. apt-get install -y: 중간에 "설치하시겠습니까(Y/N)?" 묻는 창을 무시하고 무조건(Yes) 설치하도록 한다.
# 3. 설치하는 패키지들:
#    - tzdata: 타임존(KST) 설정을 시스템에 적용하기 위한 필수 패키지이다.
#    - procps: top, ps, free 같은 핵심 프로세스 및 자원 모니터링 명령어를 포함한다. (monitor.sh 실행 필수)
#    - iproute2: ss, ip 같은 네트워크 상태 확인 명령어를 포함한다.
#    - bc: bash 쉘에서 소수점 계산을 하기 위한 기본 계산기 프로그램이다. (monitor.sh 임계값 로직 필수)
#    - ufw: 방화벽 설정 도구.
# 4. rm -rf /var/lib/apt/lists/*: 패키지 설치가 끝난 후 불필요해진 임시 캐시 파일들을 삭제하여 도커 이미지의 전체 용량을 최적화(다이어트)한다.
# 참고: DEBIAN_FRONTEND=noninteractive는 tzdata 설치 중 지역을 묻는 팝업창이 떠서 빌드가 멈추는 현상을 방지한다.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    tzdata \
    procps \
    iproute2 \
    bc \
    ufw \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# agentuser가 비밀번호 없이 ufw 제어 및 상태 확인을 할 수 있도록 sudoers 파일 수정
RUN echo "agentuser ALL=(ALL) NOPASSWD: /usr/sbin/ufw" >> /etc/sudoers

# [비루트(Non-root) 사용자 생성]
# 도커 컨테이너를 최고 관리자(root) 권한으로 돌리는 것은 보안상 매우 위험하므로, 전용 일반 사용자를 만든다.
# useradd: 리눅스 사용자 추가 명령어.
# -m: 사용자의 홈 디렉터리(/home/agentuser)를 자동으로 생성한다.
# -s /bin/bash: 이 사용자가 로그인했을 때 기본으로 사용할 쉘을 bash로 지정한다.
# agentuser: 새로 만들 사용자의 이름이다.
RUN useradd -m -s /bin/bash agentuser

# [환경 변수(ENV) 설정]
# ENV: 컨테이너 내부 전체에서 전역 변수처럼 재사용할 수 있는 환경 변수를 선언한다.
# 경로를 변수로 빼두면 나중에 경로가 바뀌어도 이곳만 수정하면 되므로 유지보수성이 대폭 향상된다.
ENV AGENT_HOME=/home/agentuser/agent_home
ENV AGENT_PORT=15034
ENV AGENT_LOG_DIR=/var/log/agent-app
ENV AGENT_UPLOAD_DIR=/home/agentuser/agent_home/upload_files
ENV AGENT_KEY_PATH=/home/agentuser/agent_home/api_keys

# [필수 디렉터리 생성 및 권한 부여]
# RUN 명령어 여러 개를 하나로 묶기 위해 && 기호를 사용한다. (도커 이미지 레이어를 줄여서 용량과 빌드 속도를 최적화하는 기법)
# mkdir -p: 부모 디렉터리가 없으면 에러를 내지 않고 함께(자동으로) 생성해 준다.
# chown -R agentuser:agentuser: 생성된 폴더와 그 안의 모든 파일(-R, Recursive)의 소유권(주인)을 root에서 agentuser로 변경한다.
# 이를 통해 나중에 agentuser로 로그인했을 때 권한 부족(Permission Denied) 에러 없이 파일 쓰기가 가능해진다.
RUN mkdir -p $AGENT_HOME/upload_files && \
    mkdir -p $AGENT_HOME/api_keys && \
    mkdir -p $AGENT_LOG_DIR && \
    chown -R agentuser:agentuser /home/agentuser && \
    chown -R agentuser:agentuser $AGENT_LOG_DIR

# [시크릿 키(비밀번호) 파일 임의 생성]
# 에이전트 앱이 구동될 때 읽어 들일 임시 API 키 파일을 텍스트 형태(secret.key)로 만들어 준다.
# 파일을 만든 후, 역시 agentuser가 읽고 쓸 수 있도록 소유권을 변경해 준다.
RUN echo "agent_api_key_test" > $AGENT_HOME/api_keys/secret.key && \
    chown agentuser:agentuser $AGENT_HOME/api_keys/secret.key

# [외부 파일(스크립트 및 실행 파일) 복사]
# COPY: 로컬 PC(호스트 컴퓨터)에 있는 파일을 도커 이미지 내부로 복사해 넣는 지시어이다.
# --chown=agentuser:agentuser 옵션을 쓰면, 복사함과 동시에 파일의 주인을 agentuser로 싹 바꿔서 복사해 준다. (매우 편리한 도커 전용 문법)
# 1. agent-leak-app-x86: 누수(Leak) 테스트용 에이전트 실행 파일.
# 2. monitor.sh: 우리가 작성했던 자원 모니터링 스크립트.
# 3. run_tests.sh: 테스트 자동화 스크립트.
COPY --chown=agentuser:agentuser agent-leak-app-x86 /home/agentuser/
COPY --chown=agentuser:agentuser monitor.sh /home/agentuser/
COPY --chown=agentuser:agentuser run_tests.sh /home/agentuser/

# [실행 권한 부여]
# 복사된 파일들은 기본적으로 단순한 텍스트 파일로 취급될 수 있으므로, 리눅스가 이를 '프로그램'으로 인식하고 실행할 수 있도록 실행 권한(+x, eXecutable)을 부여한다.
RUN chmod +x /home/agentuser/agent-leak-app-x86 && \
    chmod +x /home/agentuser/monitor.sh && \
    chmod +x /home/agentuser/run_tests.sh

# [사용자(USER) 및 작업 공간(WORKDIR) 전환]
# USER: 이 시점 이후부터 실행되는 모든 RUN, CMD 명령어 등은 root가 아닌 agentuser 권한으로 실행되도록 스위칭한다. (보안 목적)
# WORKDIR: 컨테이너에 접속(exec)했을 때 처음 진입하게 되는 기본 폴더(cd 명령어와 같은 효과)를 /home/agentuser로 고정한다.
USER agentuser
WORKDIR /home/agentuser

# [컨테이너 기본 실행 명령어]
# CMD: 도커 컨테이너가 켜질 때 단 한 번, 가장 마지막에 자동으로 실행될 기본 명령어를 지정한다.
# 여기서는 /bin/bash를 띄워두도록 설정하여, 컨테이너가 켜진 채로 종료되지 않고 대기하게 만들며 사용자가 쉘에 접속할 수 있도록 유지한다.
CMD ["/bin/bash"]

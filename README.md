# 요구사항 수행 내역서

## 개요

이번 작업은 Ubuntu 24.04 LTS 기반 리눅스 환경에서 애플리케이션 운영에 필요한 최소 서버 구성을 만드는 것을 목표로 했다.

## 수행 환경

| 항목  | 값                   |
| --- | ------------------- |
| OS  | Ubuntu 24.04 LTS    |
| 환경  | Linux VM (Orbstack) |

## 1. 기본 보안 및 네트워크 설정

### 1.1 SSH 포트 변경 및 root 로그인 차단

기본 SSH 포트인 `22`번은 일반적으로 많이 알려져 있어 자동화된 접근 시도의 대상이 되기 쉽다. 이번 설정에서는 SSH 포트를 `20022`로 변경해 기본 포트 노출을 줄였다.

또한 root 계정은 시스템 전체 권한을 가진 계정이므로 원격 SSH 로그인을 막았다. 관리 작업은 일반 계정으로 접속한 뒤 필요한 명령만 `sudo`로 실행하는 방식이 더 적절하다고 판단했다.

수행 명령어:

```bash
sudo apt update
sudo apt install -y openssh-server

sudo sed -i 's/^#\?Port .*/Port 20022/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl start ssh
```

확인 명령어:

```bash
grep -E '^(Port|PermitRootLogin)' /etc/ssh/sshd_config
sudo ss -tulnp | grep ssh
```

확인 결과:
![SSH 설정 확인](images/Pasted%20image%2020260531101603.png)
### 1.2 방화벽 설정

방화벽은 서버에 들어오거나 서버에서 나가는 네트워크 요청을 규칙에 따라 통제하는 기능이다. 이번 미션에서는 필요한 포트만 열어두고 나머지 인바운드 접근은 차단하는 방식으로 구성했다.

수행 명령어:

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 20022/tcp
sudo ufw allow 15034/tcp
sudo ufw enable
```

설정 의미:

| 설정 | 의미 |
| --- | --- |
| `default deny incoming` | 외부에서 새로 들어오는 연결은 기본 차단 |
| `default allow outgoing` | 서버에서 외부로 나가는 연결은 기본 허용 |
| `allow 20022/tcp` | SSH 접속 허용 |
| `allow 15034/tcp` | 애플리케이션 접속 허용 |

서버가 먼저 요청한 연결의 응답은 차단되지 않는다. 예를 들어 `apt update`는 서버가 먼저 외부 저장소로 요청을 보내는 outbound 연결이고, 그 응답은 기존 연결의 일부로 처리된다.

확인 명령어:

```bash
sudo ufw status verbose
```

확인 결과:
![UFW 상태 확인](images/Pasted%20image%2020260531101847.png)

## 2. 계정/그룹/권한 체계

### 2.1 계정과 그룹 생성

역할을 분리하기 위해 세 개의 계정을 만들었다.

| 계정            | 용도                   |
| ------------- | -------------------- |
| `agent-admin` | 앱 실행, 운영 관리, cron 실행 |
| `agent-dev`   | 스크립트 작성 및 운영 보조      |
| `agent-test`  | QA/테스트               |

그룹은 공유 영역과 핵심 운영 영역을 나누기 위해 두 개로 구성했다.

| 그룹             | 멤버                                       | 접근 목적             |
| -------------- | ---------------------------------------- | ----------------- |
| `agent-common` | `agent-admin`, `agent-dev`, `agent-test` | 공용 업로드 영역         |
| `agent-core`   | `agent-admin`, `agent-dev`               | 키 파일, 로그, 운영 스크립트 |

수행 명령어:

```bash
sudo groupadd agent-common
sudo groupadd agent-core

sudo useradd -m agent-admin
sudo useradd -m agent-dev
sudo useradd -m agent-test

sudo usermod -aG agent-common agent-admin
sudo usermod -aG agent-common agent-dev
sudo usermod -aG agent-common agent-test
sudo usermod -aG agent-core agent-admin
sudo usermod -aG agent-core agent-dev
```

확인 명령어:

```bash
id agent-admin
id agent-dev
id agent-test
getent group agent-common
getent group agent-core
```

확인 결과:
![계정 및 그룹 확인](images/Pasted%20image%2020260531102210.png)
### 2.2 디렉토리 구조 생성

과제 수행에 필요한 파일 및 로그 등을 저장할 디렉토리를 생성한다.

```bash
sudo mkdir -p /home/agent-admin/agent-app/upload_files
sudo mkdir -p /home/agent-admin/agent-app/api_keys
sudo mkdir -p /home/agent-admin/agent-app/bin
sudo mkdir -p /var/log/agent-app
```

### 2.3 권한 및 ACL 설정

권한 정책은 다음과 같이 잡았다.

| 경로 | 권한 정책 |
| --- | --- |
| `/home/agent-admin/agent-app/upload_files` | `agent-common` 그룹 읽기/쓰기 가능 |
| `/home/agent-admin/agent-app/api_keys` | `agent-core` 그룹만 접근 |
| `/var/log/agent-app` | `agent-core` 그룹만 접근 |

`agent-test`는 `upload_files`까지 접근해야 하므로 상위 경로에는 통과 권한만 부여했다. 이렇게 하면 공용 디렉토리에는 접근할 수 있지만, 상위 디렉토리의 목록이나 민감 디렉토리까지 불필요하게 노출하지 않을 수 있다.

수행 명령어:

```bash
sudo apt install -y acl 

sudo setfacl -m g:agent-common:--x /home/agent-admin

sudo chown agent-admin:agent-core /home/agent-admin/agent-app
sudo chmod 750 /home/agent-admin/agent-app
sudo setfacl -m g:agent-common:--x /home/agent-admin/agent-app

sudo chown agent-admin:agent-common /home/agent-admin/agent-app/upload_files
sudo chmod 2770 /home/agent-admin/agent-app/upload_files
sudo setfacl -m d:g:agent-common:rwx /home/agent-admin/agent-app/upload_files
sudo setfacl -m d:m:rwx /home/agent-admin/agent-app/upload_files

sudo chown agent-admin:agent-core /home/agent-admin/agent-app/api_keys
sudo chmod 2770 /home/agent-admin/agent-app/api_keys
sudo setfacl -m d:g:agent-core:rwx /home/agent-admin/agent-app/api_keys
sudo setfacl -m d:m:rwx /home/agent-admin/agent-app/api_keys

sudo chown agent-admin:agent-core /var/log/agent-app
sudo chmod 2770 /var/log/agent-app
sudo setfacl -m d:g:agent-core:rwx /var/log/agent-app
sudo setfacl -m d:m:rwx /var/log/agent-app
```

확인 명령어:

```bash
sudo ls -ld /home/agent-admin
sudo ls -ld /home/agent-admin/agent-app
sudo ls -ld /home/agent-admin/agent-app/upload_files
sudo ls -ld /home/agent-admin/agent-app/api_keys
sudo ls -ld /var/log/agent-app

sudo getfacl /home/agent-admin
sudo getfacl /home/agent-admin/agent-app
sudo getfacl /home/agent-admin/agent-app/upload_files
sudo getfacl /home/agent-admin/agent-app/api_keys
sudo getfacl /var/log/agent-app
```

확인 결과:
![권한 확인 1](images/Pasted%20image%2020260531102825.png)

![권한 확인 2](images/Pasted%20image%2020260531102852.png)

![ACL 확인 1](images/Pasted%20image%2020260531102920.png)
![ACL 확인 2](images/Pasted%20image%2020260531102940.png)

## 3. 애플리케이션 실행 환경 구성

### 3.1 앱 파일 배치

제공받은 agnet-app파일을 vm환경으로 넘겨준다. 이후 환경 변수를 설정 한 후, 키파일을 생성한 뒤, agent-app파일을 실행시킨다. 이 과정은 agnet-admin에서 진행한다.

예시 명령어:

```bash
sudo -iu agent-admin
bash

cp /mnt/mac/
chown agent-admin:agent-core /home/agent-admin/agent-app/agent-app
chmod 750 /home/agent-admin/agent-app/agent-app

ls -l /home/agent-admin/agent-app/
```

확인 결과:
![앱 파일 배치 확인](images/Pasted%20image%2020260531105728.png)

### 3.2 환경 변수 설정

앱 실행에 필요한 경로와 포트를 환경 변수로 고정했다. 설정은 앱을 실행하는 `agent-admin` 계정의 `.bashrc`에 추가했다.

`agent-admin` 계정에서 수행:

```bash
cat <<EOF >> ~/.bashrc
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=\$AGENT_HOME/upload_files
export AGENT_KEY_PATH=\$AGENT_HOME/api_keys
export AGENT_KEY_FILE=\$AGENT_HOME/api_keys/secret.key
export AGENT_LOG_DIR=/var/log/agent-app
EOF
source ~/.bashrc
```

확인 명령어:

```bash
env | grep AGENT
```

확인 결과:

![환경 변수 확인](images/Pasted%20image%2020260531105806.png)
### 3.3 키 파일 생성

키 파일은 미션에서 요구한 경로와 내용으로 생성했다.

```bash
echo "agent_api_key_test" > "$AGENT_KEY_FILE"
cat "$AGENT_KEY_FILE"
ls /home/agent-admin/agent-app/api_keys/
```

확인 결과:
![키 파일 확인](images/Pasted%20image%2020260531105925.png)
### 3.4 앱 실행 확인

앱은 root가 아닌 `agent-admin` 계정으로 실행했다.

```bash
$AGENT_HOME/agent-app
```

확인 결과:
![앱 실행 확인](images/Pasted%20image%2020260531110040.png)

성공 기준:

- Boot Sequence 5단계가 모두 `[OK]`
- 마지막에 `Agent READY` 출력
- 앱이 `0.0.0.0:15034`에서 LISTEN

포트 확인:

```bash
sudo ss -tulnp | grep 15034
```

확인 결과:

![앱 포트 LISTEN 확인](images/Pasted%20image%2020260531110244.png)
## 4. 시스템 관제 자동화 스크립트 구현

### 4.1 파일 위치와 권한

`monitor.sh`는 `$AGENT_HOME/bin` 아래에 배치했다.

```text
/home/agent-admin/agent-app/bin/monitor.sh
```

권한 정책:

| 항목 | 값 |
| --- | --- |
| 소유자 | `agent-dev` |
| 그룹 | `agent-core` |
| 권한 | `750` |
| 실행 계정 | `agent-admin` |

권한 설정:

```bash
sudo chown agent-dev:agent-core /home/agent-admin/agent-app/bin/monitor.sh
sudo chmod 750 /home/agent-admin/agent-app/bin/monitor.sh
ls -l /home/agent-admin/agent-app/bin/monitor.sh
```

### 4.2 구현한 점검 항목

점검 항목:

- 앱 프로세스 실행 여부
- TCP `15034` LISTEN 여부
- UFW 활성화 상태
- CPU 사용률
- 메모리 사용률
- 루트 파티션 디스크 사용률
- 임계값 초과 경고
- `/var/log/agent-app/monitor.log` 기록

임계값:

| 항목 | 경고 조건 |
| --- | --- |
| CPU | `20%` 초과 |
| MEM | `10%` 초과 |
| DISK_USED | `80%` 초과 |

로그 형식:

```text
[YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%
```

### 4.3 실행 및 로그 확인

```bash
/home/agent-admin/agent-app/bin/monitor.sh
tail -n 10 /var/log/agent-app/monitor.log
```

확인 결과:
![monitor.sh 실행 결과](images/Pasted%20image%2020260531112717.png)


![monitor.log 확인](images/Pasted%20image%2020260531112653.png)
### 4.4 로그 용량 관리

`monitor.log`가 계속 커지는 것을 막기 위해 logrotate 정책을 추가했다.

설정 파일:

```text
/etc/logrotate.d/agent-app-monitor
```

설정 내용:

```text
/var/log/agent-app/monitor.log {
    size 10M
    rotate 10
    missingok
    notifempty
    copytruncate
}
```

확인 명령어:

```bash
sudo logrotate -d /etc/logrotate.d/agent-app-monitor
sudo logrotate -f /etc/logrotate.d/agent-app-monitor
```

명령어 의미:

- `sudo logrotate -d /etc/logrotate.d/agent-app-monitor`
  - debug 모드로 실행한다.
  - 실제 로그 파일을 변경하지 않고, 설정 파일을 읽었을 때 어떤 로테이션 작업이 수행될지 미리 확인한다.
  - 설정 문법이나 대상 로그 파일 인식 여부를 점검할 때 사용했다.
- `sudo logrotate -f /etc/logrotate.d/agent-app-monitor`
  - force 모드로 실행한다.
	  - 로그 파일 크기 조건을 기다리지 않고 로테이션을 강제로 수행한다.
  - 설정이 실제로 동작하는지 확인하기 위해 사용했다.

정리하면 `-d`는 안전하게 미리 보는 검증용이고, `-f`는 실제 로테이션 동작을 강제로 확인하는 명령어다.

## 5. 자동 실행(cron) 설정

### 5.1 crontab 등록

모니터링을 수동으로 실행하지 않아도 되도록 `agent-admin` 계정의 crontab에 등록했다.

```bash
crontab -e
```

등록 내용:

```cron
* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/monitor-cron.log 2>&1
```

의미:

- `* * * * *`: 매분 실행
- `>>`: 실행 결과를 파일에 누적
- `2>&1`: 에러 출력도 같은 파일에 기록

### 5.2 자동 실행 확인

```bash
crontab -l
tail -f /var/log/agent-app/monitor.log
```

확인 결과:
![crontab 등록 확인](images/Pasted%20image%2020260531120617.png)
![cron 자동 실행 확인](images/Pasted%20image%2020260531120535.png)

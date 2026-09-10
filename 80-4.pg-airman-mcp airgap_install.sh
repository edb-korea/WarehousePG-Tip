#!/usr/bin/env bash
# ============================================================================
# pg-airman-mcp 에어갭 설치 스크립트
#
# 실행 위치: 인터넷이 없는 RHEL 9.2 대상 서버
# 사전 준비: 01_staging_prepare.sh 로 만든 pg-airman-mcp-airgap-bundle.tar.gz
#            를 같은 디렉터리에 옮겨 두세요.
#
# 이 스크립트는 컴파일러를 전혀 요구하지 않습니다.
# (psycopg[c]는 스테이징 서버에서 이미 wheel로 컴파일되어 있음)
# 단, libpq.so 런타임 공유 라이브러리는 필요합니다 (psycopg-c가 동적 링크).
# ============================================================================
set -euo pipefail

BUNDLE="${1:-pg-airman-mcp-airgap-bundle.tar.gz}"
INSTALL_ROOT="/opt/pg-airman-mcp"

if [ ! -f "$BUNDLE" ]; then
    echo "번들 파일을 찾을 수 없습니다: $BUNDLE"
    echo "사용법: $0 [번들.tar.gz 경로]"
    exit 1
fi

echo "=== [1/5] 번들 압축 해제 -> $INSTALL_ROOT ==="
sudo mkdir -p "$INSTALL_ROOT"
sudo tar -xzf "$BUNDLE" -C "$INSTALL_ROOT"

echo "=== [2/5] libpq 런타임 라이브러리 확인 ==="
if ! ldconfig -p | grep -q 'libpq\.so'; then
    echo "!! libpq.so 를 찾지 못했습니다. psycopg[c]가 동작하려면 필요합니다."
    echo "   조직 리포에 따라 패키지명이 다를 수 있습니다 (예: postgresql, libpq)."
    echo "   예: sudo dnf install -y postgresql"
    exit 1
fi
echo "libpq.so 확인됨."

echo "=== [3/5] Python 3.12 런타임 배치 ==="
PY_TARBALL=$(find "$INSTALL_ROOT/python-runtime" -maxdepth 1 -name 'cpython-*-x86_64-unknown-linux-gnu-install_only.tar.gz' | head -n1)
if [ -z "$PY_TARBALL" ]; then
    echo "번들 안에서 Python 런타임 tar.gz 를 찾지 못했습니다."
    exit 1
fi
sudo tar -xzf "$PY_TARBALL" -C "$INSTALL_ROOT"
AIRGAP_PY="$INSTALL_ROOT/python/bin/python3.12"
sudo "$AIRGAP_PY" --version

echo "=== [4/5] 가상환경 생성 + 오프라인 wheel 설치 (--no-index) ==="
sudo "$AIRGAP_PY" -m venv "$INSTALL_ROOT/venv"
sudo "$INSTALL_ROOT/venv/bin/pip" install --no-index \
    --find-links="$INSTALL_ROOT/wheelhouse" pg-airman-mcp

echo "=== [5/5] systemd 유닛 등록 ==="
if [ -f "$INSTALL_ROOT/systemd/pg-airman-mcp.service" ]; then
    sudo cp "$INSTALL_ROOT/systemd/pg-airman-mcp.service" /etc/systemd/system/
    sudo systemctl daemon-reload
    echo "systemd 유닛 설치됨: /etc/systemd/system/pg-airman-mcp.service"
else
    echo "(systemd 유닛 파일이 번들에 없습니다 — 수동으로 배치하세요)"
fi

cat <<'EOF'

--------------------------------------------------------------------
설치 완료. 다음 단계:

1) DB 접속 정보 등 환경변수 확인/수정:
     sudoedit /etc/systemd/system/pg-airman-mcp.service

2) 서비스 활성화:
     sudo systemctl enable --now pg-airman-mcp
     sudo systemctl status pg-airman-mcp

3) SELinux 환경이라면 (mcp-clickhouse 때처럼 AVC 차단이 있을 수 있음),
   서비스가 뜨지 않거나 포트 바인딩이 안 되면 먼저 아래로 점검:
     sudo ausearch -m avc -ts recent
     sudo semanage port -l | grep <포트번호>
   필요시 audit2allow로 커스텀 정책을 생성하세요.
--------------------------------------------------------------------
EOF

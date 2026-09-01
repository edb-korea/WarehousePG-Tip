#!/usr/bin/env bash
# ============================================================================
# pg-airman-mcp 오프라인(air-gap) 설치 번들 준비 스크립트
#
# 실행 위치: 인터넷이 연결된 "빌드 스테이징" 서버
#           반드시 에어갭 대상과 동일한 OS/아키텍처여야 합니다.
#           (RHEL 9.2 x86_64 — 최소한 커널/glibc 마이너 버전까지 동일 권장)
#
# 배경:
#  - RHEL 9.2 자체 리포지토리에는 Python 3.12가 없습니다.
#    (Red Hat 공식 문서: 3.11은 9.2부터, 3.12는 9.4부터 AppStream 제공)
#    -> python-build-standalone의 사전 컴파일 런타임을 사용합니다.
#  - pg-airman-mcp는 최근 psycopg[binary] -> psycopg[c]로 전환되어
#    설치 시점에 C 컴파일이 필요합니다.
#    -> 이 스크립트가 스테이징 서버에서 미리 wheel로 컴파일해 두므로,
#       에어갭 서버에는 컴파일러가 필요 없습니다.
#    (단, psycopg[c]는 libpq를 동적 링크하므로 에어갭 서버에 libpq.so
#     런타임 라이브러리는 반드시 있어야 합니다.)
# ============================================================================
set -euo pipefail

# ---- 설정값 (필요시 환경변수로 덮어쓰기) ------------------------------------
WORKDIR="${WORKDIR:-$HOME/pg-airman-mcp-bundle}"

# python-build-standalone 릴리스 태그와, 그 태그가 포함하는 실제 CPython 버전.
# 아래는 예시값입니다. 반드시 최신 태그를 확인해서 교체하세요:
#   https://github.com/astral-sh/python-build-standalone/releases
# (release asset 이름 형식: cpython-{version}+{tag}-x86_64-unknown-linux-gnu-install_only.tar.gz)
PBS_TAG="${PBS_TAG:-20260127}"
PBS_PYVER="${PBS_PYVER:-3.12.12}"

# 고정 버전이 필요하면 PKG_VERSION=1.1.1 처럼 지정, 비워두면 최신 버전 사용
PKG_NAME="pg-airman-mcp"
PKG_VERSION="${PKG_VERSION:-}"

echo "=== [1/6] 작업 디렉터리 준비: $WORKDIR ==="
mkdir -p "$WORKDIR"/{python-runtime,rpms,wheelhouse,systemd}
cd "$WORKDIR"

echo "=== [2/6] Python 3.12 standalone 런타임 다운로드 ==="
PBS_FILE="cpython-${PBS_PYVER}+${PBS_TAG}-x86_64-unknown-linux-gnu-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE}"
if [ ! -f "python-runtime/${PBS_FILE}" ]; then
    curl -fL -o "python-runtime/${PBS_FILE}" "$PBS_URL"
fi
tar -tzf "python-runtime/${PBS_FILE}" >/dev/null   # 아카이브 무결성만 확인

echo "=== [3/6] psycopg[c] 빌드용 RPM 설치 (스테이징 서버 전용, 에어갭 전송 불필요) ==="
# gcc/make/libpq-devel은 보통 BaseOS/AppStream에 있지만, 조직 리포 구성에 따라
# CodeReady Builder(CRB) 활성화가 필요할 수 있습니다:
#   subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms
sudo dnf install -y gcc make libpq-devel

echo "=== [4/6] Python 압축 해제 + 빌드용 venv 생성 ==="
tar -xzf "python-runtime/${PBS_FILE}" -C python-runtime
STAGE_PY="$WORKDIR/python-runtime/python/bin/python3.12"
"$STAGE_PY" --version

"$STAGE_PY" -m venv "$WORKDIR/build-venv"
# shellcheck disable=SC1091
source "$WORKDIR/build-venv/bin/activate"
pip install --upgrade pip wheel setuptools

echo "=== [5/6] pg-airman-mcp + 전체 의존성 wheel 사전 컴파일 ==="
PKG_SPEC="$PKG_NAME"
[ -n "$PKG_VERSION" ] && PKG_SPEC="${PKG_NAME}==${PKG_VERSION}"

# pip wheel은 sdist(psycopg-c 포함)를 이 자리에서 직접 빌드하여
# 이미 컴파일된 .whl 파일로 만들어 줍니다.
pip wheel "$PKG_SPEC" -w "$WORKDIR/wheelhouse"

deactivate

echo "=== [6/6] 번들 압축 ==="
cp "$(dirname "$0")/pg-airman-mcp.service" "$WORKDIR/systemd/" 2>/dev/null || \
    echo "(참고: pg-airman-mcp.service를 같은 폴더에 두면 자동으로 번들에 포함됩니다)"

cd "$WORKDIR"
tar -czf pg-airman-mcp-airgap-bundle.tar.gz \
    "python-runtime/${PBS_FILE}" \
    wheelhouse \
    systemd

echo ""
echo "완료: $WORKDIR/pg-airman-mcp-airgap-bundle.tar.gz"
echo "  -> 이 파일 + 02_airgap_install.sh 를 에어갭 서버로 옮기세요."
echo "  -> rpms/ 디렉터리는 스테이징 빌드 전용이며 전송할 필요 없습니다"
echo "     (컴파일 결과가 이미 wheelhouse 안의 .whl 에 반영되어 있습니다)."

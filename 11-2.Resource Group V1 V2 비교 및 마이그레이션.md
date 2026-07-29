# Resource Group V1과 V2 비교 및 마이그레이션 가이드

## 1. Resource Group V1 vs V2 핵심 비교

| 항목 | V1 (WHPG 6) | V2 (WHPG 7) |
|---|---|---|
| 동시성(Concurrency) | 트랜잭션 레벨 관리 | 동일 |
| CPU | 퍼센트 또는 코어 수 지정, cgroup 사용 | 퍼센트/코어 수 지정에 더해 **그룹별 상한(CPU_MAX_PERCENT)** 설정 가능 |
| 메모리 | 트랜잭션 레벨 관리, **오버서브스크립션(초과 할당) 불가** | 트랜잭션 레벨 관리, **오버서브스크립션 허용**, 설정이 더 단순·편리해짐 |
| Disk I/O | ❌ 미지원 | ✅ 읽기/쓰기 최대 처리량 및 초당 I/O 횟수(IOPS) 제한 지원 (**cgroup v2에서만** 가능) |
| 사용자 | SUPERUSER/일반 사용자에 제한 적용, 기본 그룹 2개(`admin_group`, `default_group`) | SUPERUSER/일반 사용자/**시스템 프로세스**까지 제한 적용, 기본 그룹 3개(`admin_group`, `default_group`, **`system_group`** 추가) |
| 큐잉(Queueing) | 슬롯 없거나 메모리 부족 시 대기 | 슬롯 없을 때만 대기 (메모리 부족은 별도 처리) |
| 쿼리 실패 조건 | 고정 메모리 한도 초과 + 공유 메모리 없을 때 | 할당 메모리가 시스템 가용 메모리+스필 한도 초과 시 |
| 제한 우회 | `SET`/`RESET`/`SHOW`는 제한 미적용 | 위와 동일 + **특정 쿼리를 동시성 제한에서 우회하도록 설정 가능** |
| 외부 컴포넌트 | PL/Container CPU+메모리 관리 | PL/Container **CPU만** 관리(메모리는 제외) |
| cgroup 버전 | v1 전용 | v1/v2 모두 지원 (IO_LIMIT은 v2 전용) |

---

## 2. 리소스 그룹 속성(Attribute) 변경 사항

### 신규 추가된 속성
(`CREATE RESOURCE GROUP` / `ALTER RESOURCE GROUP`에서 사용)

| 속성 | 설명 |
|---|---|
| `CPU_MAX_PERCENT` | 리소스 그룹이 사용할 수 있는 CPU 자원의 상한선 |
| `CPU_WEIGHT` | 리소스 그룹의 스케줄링 우선순위 |
| `MIN_COST` | 쿼리 플랜 비용이 이 값 이상이어야 해당 그룹 규칙이 적용됨 |
| `IO_LIMIT` | 디바이스 I/O 사용량(최대 읽기/쓰기 처리량, 초당 읽기/쓰기 횟수) 제한 |

### 제거된 속성

- `CPU_RATE_LIMIT`
- `MEMORY_AUDITOR`
- `MEMORY_SPILL_RATIO`
- `MEMORY_SHARED_QUOTA`

---

## 3. 서버 설정 파라미터(GUC) 변경

### `gp_resource_manager` 값 변경

| 값 | 설명 |
|---|---|
| `none` | 리소스 관리자 사용 안 함 (기본값) |
| `group` | 리소스 그룹 사용, cgroup **v1** 기반 |
| `group-v2` (신규) | 리소스 그룹 사용, cgroup **v2** 기반 |
| `queue` | 리소스 큐 사용 |

### 신규 파라미터

| 파라미터 | 설명 |
|---|---|
| `gp_resgroup_memory_query_fixed_mem` | 세션 레벨에서 고정 메모리량 오버라이드 |
| `gp_resource_group_move_timeout` | `pg_resgroup_move_query()` 함수의 대기 타임아웃(ms) |
| `gp_resource_group_bypass_direct_dispatch` | 다이렉트 디스패치 쿼리의 리소스 그룹 제한 우회 |

### 제거된 파라미터

- `gp_resource_group_cpu_ceiling_enforcement`
- `gp_resource_group_enable_recalculate_query_mem`
- `gp_resource_group_memory_limit`

---

## 4. 시스템 뷰 변경

| 뷰 | 변경 내용 |
|---|---|
| `gp_resgroups_config` | `cpu_rate_limit`, `memory_shared_quota`, `memory_spill_ratio`, `memory_auditor` → `cpu_max_percent`, `cpu_weight`, `cpuset`, `min_cost`, `io_limit`로 교체 |
| `gp_resgroup_status` | `rsgname` → `groupname`으로 이름 변경, `cpu_usage`/`memory_usage`는 `gp_resgroup_status_per_host`로 이동 |
| `gp_resgroup_status_per_host` | 호스트명/메모리 관련 필드 제거, `segment_id`/`cpu_usage`/`memory_usage` 필드 추가 |
| `gp_resgroup_status_per_segment` | `rsgname`, `hostname`, 메모리 관련 필드 제거, `groupname`/`vmem_usage` 필드 추가 |
| `gp_resgroup_iostats_per_host` (신규) | I/O 통계 전용 뷰 신규 추가 |

---

## 5. 마이그레이션 가이드

### Step 1. 기존 V1 설정값 조회 및 백업

```sql
SELECT groupid, groupname, concurrency, cpu_rate_limit, memory_limit,
       memory_shared_quota, memory_spill_ratio, memory_auditor
FROM gp_toolkit.gp_resgroup_config;
```

> V6 기준 정확한 뷰/컬럼명은 환경에 따라 다를 수 있으므로, 사전에 전체 목록을 CSV로 백업해 두는 것을 권장합니다.

### Step 2. 속성 매핑표를 참고해 V2 값으로 변환

| V1 속성 | V2 대응 | 변환 방법 |
|---|---|---|
| `CPU_RATE_LIMIT` (퍼센트) | `CPU_MAX_PERCENT` 또는 `CPU_WEIGHT` | 절대 상한이 목적이면 `CPU_MAX_PERCENT`, 상대적 우선순위가 목적이면 `CPU_WEIGHT`로 재설계 |
| `MEMORY_LIMIT` | 유지 (동작 방식만 변경, 오버서브스크립션 허용) | 값은 그대로 가져오되 오버서브스크립션 정책 재검토 필요 |
| `MEMORY_SHARED_QUOTA` | ❌ 제거됨 | 별도 대응 속성 없음 — V2의 새 메모리 모델에 맞게 재설계 필요 |
| `MEMORY_SPILL_RATIO` | ❌ 제거됨 | 스필 제어는 V2의 새 메모리 관리 방식(가용 메모리+스필 한도 초과 시 실패)에 맡겨짐 |
| `MEMORY_AUDITOR` | ❌ 제거됨 | vmtracker 방식이 기본이 되어 별도 지정 불필요 |
| (신규) | `IO_LIMIT` | V1에는 없던 개념. cgroup v2 사용 시 새로 설계해서 추가 |

### Step 3. `gp_resource_manager` 전환 (재시작 필요)

```bash
# cgroup v2 사용 시
gpconfig -c gp_resource_manager -v "group-v2"

# cgroup v1 유지 시
gpconfig -c gp_resource_manager -v "group"

gpstop -ra
```

### Step 4. 리소스 그룹 재생성 (V2 속성 기준)

```sql
-- 예: V1에서 CPU_RATE_LIMIT=20, MEMORY_LIMIT=30 이었던 그룹
CREATE RESOURCE GROUP etl_group
WITH (
    CPU_MAX_PERCENT=20,
    CPU_WEIGHT=100,
    CONCURRENCY=10,
    MEMORY_LIMIT=30,
    MIN_COST=0
);

-- Disk I/O 제한이 필요하면 (cgroup v2 환경만)
ALTER RESOURCE GROUP etl_group SET IO_LIMIT '*:1000mbps';
```

### Step 5. 역할(Role)에 재할당

```sql
ALTER ROLE etl_user RESOURCE GROUP etl_group;
```

### Step 6. 검증

```sql
SELECT groupname, cpu_max_percent, cpu_weight, cpuset, min_cost, io_limit
FROM gp_resgroups_config;

SELECT groupname, num_running, num_queueing, vmem_usage
FROM gp_resgroup_status_per_segment;
```

---

## 6. 마이그레이션 시 특히 주의할 점

1. **`MEMORY_SHARED_QUOTA`/`MEMORY_SPILL_RATIO`/`MEMORY_AUDITOR`는 단순 값 이전이 불가능**합니다. V2의 메모리 모델(오버서브스크립션 허용 + 다른 실패 조건)이 근본적으로 다르므로, 기존 값을 그대로 새 속성에 넣지 말고 워크로드를 재테스트하며 새로 튜닝해야 합니다.
2. **cgroup v1 → v2 전환 시 OS 레벨 준비**가 선행되어야 합니다 (마운트된 cgroup 파일시스템 확인, `gpadmin`의 `/sys/fs/cgroup/cgroup.procs` 쓰기 권한 등).
3. `system_group`이라는 새 기본 그룹이 추가되었으므로, 기존에 시스템 프로세스에 별도 제한을 두지 않았다면 이 신규 그룹의 기본 설정값이 운영에 영향을 주는지 반드시 확인해야 합니다.
4. `rsgname → groupname` 같은 **시스템 뷰 컬럼명 변경**으로 인해, 기존 모니터링 스크립트/대시보드 쿼리는 반드시 수정이 필요합니다.
5. 실제 전환 전, **스테이징 환경에서 워크로드 재현 테스트**를 강력히 권장합니다. 특히 메모리 오버서브스크립션 허용으로 인한 동작 변화는 실측 없이는 예측하기 어렵습니다.


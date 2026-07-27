-- =============================================================================
-- LMS Avro Binary Decoder — WarehousePG PL/Python3 Function
--
-- 역할:
--   inner schema Avro 이진(bytea)을 직접 JSON으로 디코딩합니다.
--   outer EventRecord envelope 없이 inner data bytes만 입력받습니다.
--
-- 전제조건:
--   - plpython3u 확장 설치
--   - fastavro 라이브러리 설치 (pip3 install fastavro)
--
-- 설치:
--   psql -d <db> -f avro_decode_inner.sql
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS plpython3u;


-- =============================================================================
-- avro_decode_inner(p_avro_bytes, p_schema_name) → jsonb
--
-- 파라미터:
--   p_avro_bytes  : inner schema Avro 이진 데이터 (bytea)
--   p_schema_name : 스키마 이름 (기본값: 'fds.event_log')
-- =============================================================================
CREATE OR REPLACE FUNCTION avro_decode_inner(
    p_avro_bytes  bytea,
    p_schema_name text DEFAULT 'fds.event_log'
)
RETURNS jsonb
LANGUAGE plpython3u
STABLE
AS $$
import io
import json

# =============================================================================
# inner 스키마 레지스트리
#
# 필드 타입 매핑 (Java DataType → Avro type):
#   BOOLEAN                              → "boolean"
#   TINYINT / SMALLINT / INTEGER         → "int"
#   BIGINT / TIMESTAMP / DATETIME        → "long"
#   KAFKA_PARTITION                      → "int"
#   KAFKA_OFFSET / KAFKA_TIMESTAMP       → "long"
#   REAL                                 → "float"
#   FLOAT / DOUBLE                       → "double"
#   STRING                               → "string"
#   BINARY / encryptionAlgorithm 있는 필드 → "bytes"
#
# 모든 필드는 ["null", <type>] union + default=None
# (Java LogAvroSchema.toAvroSchema 동일)
#
# 스키마 추가 방법:
#   INNER_SCHEMAS["새스키마명"] = { "type": "record", "name": "...", "fields": [...] }
# =============================================================================
INNER_SCHEMAS = {
    "event_log": {
        "type": "record",
        "name": "event_log",
        "namespace": "test",
        "fields": [
            # event time | BIGINT → long  | PK
            {"name": "evnt_dttm",  "type": ["null", "long"],   "default": None},
            # customer_id   | BIGINT → long  | PK, partitionKey, 개인정보
            {"name": "intg_cstno", "type": ["null", "long"],   "default": None},
            # product_id      | STRING, encoding=DICTIONARY, length=32
            {"name": "prtno",      "type": ["null", "string"], "default": None},
            # payload | STRING, length=16384
            {"name": "evnt_payload",  "type": ["null", "string"], "default": None},
        ],
    },

    # -------------------------------------------------------------------------
    # 추가 스키마 예시
    # -------------------------------------------------------------------------
    # "login_log": {
    #     "type": "record",
    #     "name": "login_log",
    #     "namespace": "test",
    #     "fields": [
    #         {"name": "login_time", "type": ["null", "long"],   "default": None},  # 로그인 시각
    #         {"name": "client_id",    "type": ["null", "string"], "default": None},  # 사용자 ID
    #         {"name": "ip_address",    "type": ["null", "string"], "default": None},  # IP 주소
    #         {"name": "device_type",  "type": ["null", "string"], "default": None},  # 디바이스 유형
    #     ],
    # },

}

# =============================================================================
# 디코딩
# =============================================================================
try:
    import fastavro
    import fastavro.schema

    schema_dict = INNER_SCHEMAS.get(p_schema_name)
    if schema_dict is None:
        return json.dumps({
            "error":     f"Unknown schema: {p_schema_name!r}",
            "available": list(INNER_SCHEMAS.keys()),
        }, ensure_ascii=False)

    schema = fastavro.schema.parse_schema(schema_dict)
    record = fastavro.schemaless_reader(io.BytesIO(bytes(p_avro_bytes)), schema)

    # bytes/bytearray 필드 → hex 문자열 변환
    for k, v in record.items():
        if isinstance(v, (bytes, bytearray)):
            record[k] = v.hex()

    return json.dumps(record, ensure_ascii=False, default=str)

except Exception as e:
    import traceback
    return json.dumps({
        "error": str(e),
        "type":  type(e).__name__,
        "trace": traceback.format_exc(),
    }, ensure_ascii=False)
$$;

COMMENT ON FUNCTION avro_decode_inner(bytea, text) IS
'LMS inner schema Avro 이진(bytea)을 JSONB로 디코딩합니다.
p_schema_name 기본값: ''fds.event_log''
새 스키마 추가: 함수 내 INNER_SCHEMAS 딕셔너리에 항목을 추가하세요.';


-- =============================================================================
-- 사용 예시
-- =============================================================================

-- 기본 사용 (fds.event_log 스키마)
-- SELECT avro_decode_inner(avro_data) FROM lms_raw_events LIMIT 5;

-- 스키마 명시
-- SELECT avro_decode_inner(avro_data, 'fds.event_log') FROM lms_raw_events;

-- 특정 필드 추출
-- SELECT
--     avro_decode_inner(avro_data) ->> 'cstno'                            AS cstno,
--     avro_decode_inner(avro_data) ->> 'evnt_cntx'                        AS evnt_cntx,
--     to_timestamp((avro_decode_inner(avro_data) ->> 'evnt_dttm')::bigint / 1000.0) AS evnt_time
-- FROM lms_raw_events;

-- 함수 설치 확인
SELECT
    proname                                          AS function_name,
    pg_catalog.pg_get_function_arguments(oid)        AS arguments,
    prorettype::regtype                              AS return_type
FROM pg_proc
WHERE proname = 'avro_decode_inner'
ORDER BY proname;

-- =============================================================================
-- 다른 예시. 
-- =============================================================================
CREATE OR REPLACE FUNCTION avro_decode_inner(payload bytea)
    RETURNS json
    AS $$
    import io
    import json
    import fastavro

    if payload is None:
        return None

    # --- 커스텀 스키마(내장) -------------------------------------------
    SCHEMA_DICT = {
        "name": "fds.event_log",
        "fields": [
            {"name": "evnt_dttm",  "dataType": "BIGINT",       "nullable": False},
            {"name": "intg_cstno", "dataType": "BIGINT",       "nullable": False},
            {"name": "kafka_ofst", "dataType": "KAFKA_OFFSET", "nullable": False},
            {"name": "cstno",      "dataType": "STRING",       "nullable": False},
            {"name": "evnt_cntx",  "dataType": "STRING",       "nullable": False},
        ],
    }

    TYPE_MAP = {
        "BIGINT": "long",
        "INT": "int",
        "INTEGER": "int",
        "STRING": "string",
        "VARCHAR": "string",
        "DOUBLE": "double",
        "FLOAT": "float",
        "BOOLEAN": "boolean",
        "TIMESTAMP": "long",
        "KAFKA_OFFSET": "long",   # base 타입 추정 - 생산자와 일치 필요
    }

    def avro_type(field):
        dt = field["dataType"]
        if dt not in TYPE_MAP:
            raise ValueError("알 수 없는 dataType: %s (field=%s)" % (dt, field["name"]))
        base = TYPE_MAP[dt]
        return ["null", base] if field.get("nullable", False) else base

    def to_avro_schema(custom):
        full = custom["name"]
        if "." in full:
            ns, name = full.rsplit(".", 1)
        else:
            ns, name = "fds", full
        fields = []
        for f in custom["fields"]:
            af = {"name": f["name"], "type": avro_type(f)}
            if f.get("nullable", False):
                af["default"] = None
            fields.append(af)
        return {"type": "record", "namespace": ns, "name": name, "fields": fields}

    # --- 파싱된 스키마 캐시 (세션 내 재사용) ---------------------------
    schema = SD.get("event_log_schema")
    if schema is None:
        schema = fastavro.parse_schema(to_avro_schema(SCHEMA_DICT))
        SD["event_log_schema"] = schema

    # --- 디코딩 -------------------------------------------------------
    # bytea 는 PL/Python 으로 bytes 형태로 전달됨
    record = fastavro.schemaless_reader(io.BytesIO(bytes(payload)), schema)
    return json.dumps(record, ensure_ascii=False)
$$ LANGUAGE plpython3u IMMUTABLE;

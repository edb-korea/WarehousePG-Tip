#!/usr/bin/env python3
"""
whpg_copy_log_summary.py

WarehousePG whpg-copy 실행 로그를 분석해서, 테이블별 시작/종료 시각, 처리 건수, 성공 여부를 요약합니다.

사용법:
    python3 whpg_copy_log_summary.py <로그파일경로> [--csv 출력파일.csv]

예:
    python3 whpg_copy_log_summary.py whpg-copy.log
    python3 whpg_copy_log_summary.py whpg-copy.log --csv summary.csv
"""

import re
import sys
import argparse
from collections import OrderedDict
from datetime import datetime, timezone

# 각 로그 라인 패턴 (task id 기준으로 시작/종료/처리건수를 매칭)
RE_START = re.compile(
    r'^(?P<ts>\S+)\s+INFO data_task\(\)\{id=(?P<id>\d+)\}: '
    r'whpg_copy::executor::copy_task: Executing CopyTask\. '
    r'(?P<src>\S+) -> (?P<dst>\S+) dry_run=\S+'
)

RE_COUNT = re.compile(
    r'^(?P<ts>\S+)\s+INFO data_task\(\)\{id=(?P<id>\d+)\}: '
    r'whpg_copy::executor::copy_task: Row count validation passed\. '
    r'Count: (?P<count>\d+)'
)

RE_SUCCESS = re.compile(
    r'^(?P<ts>\S+)\s+INFO data_task\(\)\{id=(?P<id>\d+)\}: '
    r'whpg_copy::cmd::copy: Finished data task\. dst_name="(?P<dst>[^"]+)"'
)

RE_FAIL = re.compile(
    r'^(?P<ts>\S+)\s+ERROR data_task\(\)\{id=(?P<id>\d+)\}: '
    r'whpg_copy::cmd::copy: Task execution failed\. dst_name="(?P<dst>[^"]+)"'
)


def parse_ts(ts: str):
    """'2026-07-21T06:52:11.812283Z' 형태의 문자열을 datetime으로 변환. 실패 시 None."""
    if not ts or ts == 'N/A':
        return None
    try:
        return datetime.strptime(ts, '%Y-%m-%dT%H:%M:%S.%fZ').replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def format_duration(start_ts: str, end_ts: str) -> str:
    """시작-종료 timestamp 문자열로부터 처리 수행시간(HH:MM:SS)을 계산."""
    start_dt = parse_ts(start_ts)
    end_dt = parse_ts(end_ts)
    if start_dt is None or end_dt is None:
        return 'N/A'
    delta = end_dt - start_dt
    total_seconds = int(delta.total_seconds())
    if total_seconds < 0:
        return 'N/A'
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f'{hours:02d}:{minutes:02d}:{seconds:02d}'


def is_sequence_object(name: str) -> bool:
    """시퀀스 setval 작업(테이블 복사가 아님)은 요약에서 제외."""
    return name.endswith('_seq') or '_seq"' in name


def parse_log(path):
    tasks = OrderedDict()  # task_id -> dict(table, start, end, count, status)

    with open(path, 'r', errors='replace') as f:
        for line in f:
            m = RE_START.match(line)
            if m:
                tid = m.group('id')
                tasks.setdefault(tid, {})
                tasks[tid]['table'] = m.group('dst')
                tasks[tid]['start'] = m.group('ts')
                continue

            m = RE_COUNT.match(line)
            if m:
                tid = m.group('id')
                tasks.setdefault(tid, {})
                tasks[tid]['count'] = m.group('count')
                continue

            m = RE_SUCCESS.match(line)
            if m:
                tid = m.group('id')
                tasks.setdefault(tid, {})
                tasks[tid].setdefault('table', m.group('dst'))
                tasks[tid]['end'] = m.group('ts')
                tasks[tid]['status'] = 'Success'
                continue

            m = RE_FAIL.match(line)
            if m:
                tid = m.group('id')
                tasks.setdefault(tid, {})
                tasks[tid].setdefault('table', m.group('dst'))
                tasks[tid]['end'] = m.group('ts')
                tasks[tid]['status'] = 'Failed'
                continue

    # 시퀀스(setval) 작업 제외, 실제 테이블 복사 작업만 필터링
    rows = []
    for tid, info in tasks.items():
        table = info.get('table', 'UNKNOWN')
        if is_sequence_object(table):
            continue
        start = info.get('start', 'N/A')
        end = info.get('end', 'N/A')
        rows.append({
            'table': table,
            'start': start,
            'end': end,
            'duration': format_duration(start, end),
            'count': info.get('count', 'NA'),
            'status': info.get('status', 'Unknown/Cancelled'),
        })

    # 시작 시각 기준 정렬 (N/A는 뒤로)
    rows.sort(key=lambda r: (r['start'] == 'N/A', r['start']))
    return rows


def print_table(rows):
    header = ('테이블명', '시작시간', '종료시간', '처리 수행시간', '처리건수', '성공여부')
    widths = [
        max(len(header[0]), max((len(r['table']) for r in rows), default=0)),
        max(len(header[1]), max((len(r['start']) for r in rows), default=0)),
        max(len(header[2]), max((len(r['end']) for r in rows), default=0)),
        max(len(header[3]), max((len(r['duration']) for r in rows), default=0)),
        max(len(header[4]), max((len(r['count']) for r in rows), default=0)),
        max(len(header[5]), max((len(r['status']) for r in rows), default=0)),
    ]

    def fmt_row(cols):
        return ' : '.join(c.ljust(w) for c, w in zip(cols, widths))

    print(fmt_row(header))
    print(fmt_row(['-' * w for w in widths]))
    for r in rows:
        print(fmt_row([r['table'], r['start'], r['end'], r['duration'], r['count'], r['status']]))


def write_csv(rows, path):
    import csv
    with open(path, 'w', newline='', encoding='utf-8-sig') as f:
        w = csv.writer(f)
        w.writerow(['테이블명', '시작시간', '종료시간', '처리 수행시간', '처리건수', '성공여부'])
        for r in rows:
            w.writerow([r['table'], r['start'], r['end'], r['duration'], r['count'], r['status']])


def main():
    ap = argparse.ArgumentParser(description='whpg-copy 로그 요약 스크립트')
    ap.add_argument('logfile', help='분석할 whpg-copy 로그 파일 경로')
    ap.add_argument('--csv', help='결과를 CSV로 저장할 파일 경로 (선택)')
    args = ap.parse_args()

    rows = parse_log(args.logfile)
    if not rows:
        print('로그에서 테이블 복사 작업을 찾지 못했습니다.')
        sys.exit(0)

    print_table(rows)

    if args.csv:
        write_csv(rows, args.csv)
        print(f'\nCSV 저장 완료: {args.csv}')


if __name__ == '__main__':
    main()

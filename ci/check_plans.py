#!/usr/bin/env python3
"""ci/out/*.plan.txt から ShowPlanXML を取り出し、インデックスの効き方を判定する。

ルール（閾値は ci/plan-check.config.json）:
  - Clustered Index Scan / Table Scan / Index Scan が出たら失敗（許可テーブルを除く）
  - Key Lookup / RID Lookup が maxLookups を超えたら失敗
  - PlanAffectingConvert（ConvertIssue = 'Seek Plan'）が出たら失敗
1件でも失敗したら終了コード 1。
"""
import glob
import json
import re
import sys
import xml.etree.ElementTree as ET


def local(tag: str) -> str:
    return tag.rsplit('}', 1)[-1]


def main() -> int:
    with open('ci/plan-check.config.json', encoding='utf-8') as fh:
        config = json.load(fh)
    allow_scan = set(config.get('allowScanTables', []))
    max_lookups = int(config.get('maxLookups', 0))

    failed = False
    for path in sorted(glob.glob('ci/out/*.plan.txt')):
        name = path.split('/')[-1].removesuffix('.plan.txt')
        text = open(path, encoding='utf-8', errors='replace').read()
        m = re.search(r'<ShowPlanXML.*?</ShowPlanXML>', text, re.S)
        if not m:
            print(f'FAIL {name}: プラン XML が見つからない')
            failed = True
            continue
        root = ET.fromstring(m.group(0))
        problems: list[str] = []
        lookups = 0
        for el in root.iter():
            tag = local(el.tag)
            if tag == 'RelOp':
                op = el.get('PhysicalOp')
                if op in ('Clustered Index Scan', 'Table Scan', 'Index Scan'):
                    table = None
                    for desc in el.iter():
                        if local(desc.tag) == 'Object':
                            table = desc.get('Table')
                            break
                    if table not in allow_scan:
                        problems.append(f'Scan: {op} on {table}')
                elif op in ('Key Lookup', 'RID Lookup'):
                    lookups += 1
            elif tag == 'PlanAffectingConvert' and el.get('ConvertIssue') == 'Seek Plan':
                problems.append(f"Implicit conversion (Seek Plan): {el.get('Expression')}")
        if lookups > max_lookups:
            problems.append(f'Lookup: {lookups} 件（上限 {max_lookups}）')
        if problems:
            failed = True
            print(f'FAIL {name}')
            for p in problems:
                print(f'  - {p}')
        else:
            print(f'PASS {name}')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())

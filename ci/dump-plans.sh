#!/usr/bin/env bash
# 対象クエリを実際のプラン付きで実行し、生出力を ci/out/<name>.plan.txt に保存する。
# 判定は ci/check_plans.py が行う。
# sqlcmd が PATH にあればそれを使い、無ければ mssql-tools18 のコンテナで実行する。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p ci/out

HOST="${SQLSERVER_HOST:-localhost}"
DB="${SQLSERVER_DB:-PlanCheckDemo}"
USER_NAME="${SQLSERVER_USER:-sa}"
PASS="${SQLSERVER_PASSWORD:?SQLSERVER_PASSWORD is required}"

run_sqlcmd() {
  if command -v sqlcmd >/dev/null 2>&1; then
    sqlcmd -S "$HOST" -U "$USER_NAME" -P "$PASS" -C "$@"
  else
    docker run --rm --network host -v "$PWD:/work" -w /work \
      mcr.microsoft.com/mssql-tools18 \
      /opt/mssql-tools18/bin/sqlcmd -S "$HOST" -U "$USER_NAME" -P "$PASS" -C "$@"
  fi
}

for f in ci/targets/*.sql; do
  name="$(basename "$f" .sql)"
  query="$(cat "$f")"
  # -y 0: 可変長出力（プラン XML）を切り捨てない
  run_sqlcmd -d "$DB" -Q "SET STATISTICS XML ON; $query" -y 0 -h -1 -o "ci/out/$name.plan.txt"
  echo "dumped: $name"
done

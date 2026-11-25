# SQL Server インデックス調査クエリ集

実行プランで「インデックスが効いているか／効いていないか」を見分けるための手順とクエリ集。

## 手順

1. 対象の遅いクエリを、実際の実行プラン付きで実行する（SSMS: Ctrl+M「実際の実行プランを含める」）。あわせて `SET STATISTICS IO ON; SET STATISTICS TIME ON;` で論理読み取り数と実行時間を取る。
2. プランの XML を判定クエリにかける（`queries/01-plan-operators.sql`、`queries/02-implicit-conversion.sql`）。
3. 本番で直接実行できない場合は、プランキャッシュから同じプランを引く（`queries/03-plan-cache.sql`）。
4. インデックス自体の使用実績は usage stats で裏取りする（`queries/04-index-usage.sql`）。

## プランの読み方（要点）

| オペレーター | 意味 |
|---|---|
| Index Seek | 効いている。狙った行だけを取りに行っている |
| Index Scan | インデックスを全件なめている。実質スキャン（カバリングの Scan は許容の場合あり） |
| Clustered Index Scan / Table Scan | そのインデックスは効いていない。全件走査 |
| Index Seek + Key Lookup / RID Lookup | 一部だけ効いている。本体へ列を取りに戻っている。カバリング化の候補 |

- Seek のプロパティで **Seek Predicates**（キーで絞れた部分）と **Predicate**（取得後の残余フィルタ）を分けて見る。条件が Predicate 側に落ちていたら、複合インデックスの先頭列で絞れていない、列に関数を被せた、前方一致でない LIKE などが原因。
- **暗黙の型変換**（CONVERT_IMPLICIT / PlanAffectingConvert）が列側にかかると Seek が死ぬ。varchar 列 × nvarchar パラメータが典型例で、アプリ側のパラメータ型が原因のことが多い。
- 推定行数と実際行数が大きくズレていたら統計情報の古さも疑う。
- SSMS の緑色「Missing Index」は提案止まり。そのまま作ると重複インデックスが増えるので参考程度に。

## 注意

- `sys.dm_db_index_usage_stats` は SQL Server 再起動でリセットされる。起動直後の値は当てにならない。
- プランキャッシュの内容も再起動やメモリ圧迫で消える。調査は遅さが再現している時に行う。

## デッドロック調査

手順は `docs/deadlock-investigation.md`。同じテーブルに複数業務の UPDATE / DELETE / INSERT が重なってデッドロックする形を想定している。

- `queries/05-deadlock-history.sql` — system_health から直近のデッドロックグラフ（XML）を抜く
- `queries/06-deadlock-summary.sql` — グラフを要約し、合流点（どのインデックスで掴み合ったか）を特定する
- `queries/07-table-index-detail.sql` — 対象テーブルのインデックス詳細（キー列・包含列・行数）
- `queries/08-live-locks.sql` — バッチ実行中のロック状況とブロックをその場で見る
- `queries/09-plan-cache-by-table.sql` — 対象テーブルを触るプランをキャッシュから探し、シーク／スキャンを判定する
- `queries/10-statistics-freshness.sql` — 対象テーブルの統計情報の鮮度（最終更新と変更行数）を確認する

## GitHub Actions でクエリチェック（サンプル）

`.github/workflows/query-plan-check.yml` は、対象クエリの実行プランを自動判定するサンプル。

- SQL Server 2022 のコンテナに対して `ci/seed.sql` でデモデータを作り、`ci/targets/*.sql` を実際のプラン付きで実行して判定する
- 判定ルール（`ci/Invoke-PlanCheck.ps1`、閾値は `ci/plan-check.config.json`）:
  - Clustered Index Scan / Table Scan / Index Scan が出たら失敗（許可テーブルは config で指定）
  - Key Lookup / RID Lookup が上限を超えたら失敗
  - PlanAffectingConvert（Seek Plan）が出たら失敗＝暗黙変換で Seek が落ちている
- `ci/targets-examples/bad-leading-wildcard.sql` は不合格例。`ci/targets/` にコピーして回すと失敗することを確認できる

実 DB を相手にする場合:

1. ワークフローの `services` を消し、`runs-on` を DB にネットワークで届く self-hosted ランナーに変える
2. 接続先（`SQLSERVER_HOST` / `SQLSERVER_DB` / `SQLSERVER_USER` / `SQLSERVER_PASSWORD`）はリポジトリの Secrets から渡す
3. チェックしたいクエリを `ci/targets/` に追加する（読み取り専用アカウントで実行すること）

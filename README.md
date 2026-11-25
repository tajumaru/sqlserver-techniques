# SQL Server インデックス調査クエリ集

実行プランで「インデックスが効いているか／効いていないか」を見分けるための手順とクエリ集。

## 実行条件

- 04・07・08 の結果1・10・13 の統計と断片化は、クエリを実行した DB が対象。08 の結果2、13 のその他の項目、および 12 の待機統計はインスタンス全体が対象。
- インスタンス全体の状態を取得するには、SQL Server 2019 以前は `VIEW SERVER STATE`、SQL Server 2022 以降は `VIEW SERVER PERFORMANCE STATE` など、使用する管理ビュー・関数に応じた権限が必要。テーブルや統計を見るには対象 DB での参照権限も必要。 [Microsoft Learn の権限一覧](https://learn.microsoft.com/ja-jp/sql/relational-databases/system-dynamic-management-views/system-dynamic-management-views)
- `dm_db_stats_properties` は SQL Server 2012 SP1 以降。06・13 が使う `STRING_AGG` は SQL Server 2017 以降。13 の `WITHIN GROUP` による並べ替えには互換性レベル 110 以上が必要。 [STRING_AGG の仕様](https://learn.microsoft.com/ja-jp/sql/t-sql/functions/string-agg-transact-sql)
- `system_health` を使う調査はオンプレミスの SQL Server を前提とする。リングバッファの古い記録は上書きされ、XML 変換の 4 MB 上限でも欠落し得る。 [リングバッファの仕様](https://learn.microsoft.com/ja-jp/sql/relational-databases/extended-events/targets-for-extended-events-in-sql-server)

## 手順

1. 対象の遅いクエリを、実際の実行プラン付きで実行する（SSMS: Ctrl+M「実際の実行プランを含める」）。更新文の場合はデータも更新される。あわせて `SET STATISTICS IO ON; SET STATISTICS TIME ON;` で論理読み取り数と実行時間を取る。
2. プランの XML を判定クエリにかける（`queries/01-plan-operators.sql`、`queries/02-implicit-conversion.sql`）。
3. 本番で直接実行できない場合は、プランキャッシュからコンパイル時のプランを探す（`queries/03-plan-cache.sql`）。
4. インデックス自体の使用実績は usage stats で裏取りする（`queries/04-index-usage.sql`）。

## プランの読み方（要点）

| オペレーター | 意味 |
|---|---|
| Index Seek | 効いている。狙った行だけを取りに行っている |
| Index Scan | インデックスをスキャンする。読む範囲は実際のプランと読み取り数で確認する |
| Clustered Index Scan / Table Scan | クラスタ化インデックスまたはテーブルをスキャンする。全行を読むとは限らない |
| Index Seek + Key Lookup / RID Lookup | 一部だけ効いている。本体へ列を取りに戻っている。カバリング化の候補 |

- Seek のプロパティで **Seek Predicates**（キーで絞れた部分）と **Predicate**（取得後の残余フィルタ）を分けて見る。条件が Predicate 側に落ちていたら、複合インデックスの先頭列で絞れていない、列に関数を被せた、前方一致でない LIKE などが原因。
- **暗黙の型変換**（CONVERT_IMPLICIT / PlanAffectingConvert）が列側にかかるとシークに影響することがある。varchar 列 × nvarchar パラメータが典型例で、アプリ側のパラメータ型が原因のことが多い。
- 推定行数と実際行数が大きくズレていたら統計情報の古さも疑う。
- SSMS の緑色「Missing Index」は提案止まり。そのまま作ると重複インデックスが増えるので参考程度に。

## 注意

- `sys.dm_db_index_usage_stats` は SQL Server の再起動や DB の切り離しで消える。起動直後の値は当てにならない。
- プランキャッシュの内容も再起動やメモリ圧迫で消える。調査は遅さが再現している時に行う。

## デッドロック調査

手順は `docs/deadlock-investigation.md`。同じテーブルに複数業務の UPDATE / DELETE / INSERT が重なってデッドロックする形を想定している。

- `queries/05-deadlock-history.sql` — system_health から直近のデッドロックグラフを含むイベント XML を取得する
- `queries/06-deadlock-summary.sql` — グラフを要約し、ロックが重なった場所を調べる。結果2を外部共有するときは SQL 文面・ログイン名・アプリ名を伏せる
- `queries/07-table-index-detail.sql` — 対象テーブルのインデックス詳細（キー列・包含列・行数）
- `queries/08-live-locks.sql` — バッチ実行中のロック状況とブロックをその場で見る
- `queries/09-plan-cache-by-table.sql` — 同名表を含むコンパイル時のプランを探す。プラン全体で Index Scan、Clustered Index Scan、Table Scan の有無を確認する
- `queries/10-statistics-freshness.sql` — 対象テーブルの統計情報の鮮度（最終更新と変更回数）を確認する
- `queries/11-deadlock-verdict.sql` — 合流点・プラン・統計の確認をまとめて行う。別 DB なら再実行を案内し、表や確認材料が見つからない場合は未確認と表示する。件数・割合・判定・統計の最終更新日時を返す。外部共有時はインデックス名を伏せる。プラン走査は間引き／なし／一括を選べる
- `queries/12-wait-stats-diff.sql` — 待機統計の差分。同じセッションで2回実行し、間の時間帯に「何待ちで時間を食ったか」を見る
- `queries/13-health-check.sql` — 健康診断（統合版）。ブロッキング・実行中・待機の内訳・統計・断片化・デッドロック・メモリ待ちを1回で判定まで返す

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

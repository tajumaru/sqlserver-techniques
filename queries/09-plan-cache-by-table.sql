-- 対象テーブルを触るプランをプランキャッシュから探す（シーク判定）
--
-- 使い方:
--   先頭の @TableName を対象に書き換えて実行する。
--   そのテーブルを参照するキャッシュ済みプランが、
--   論理読み取りの多い順に返る。query_plan 列を SSMS で開くと
--   実際のプランを確認できる。
--
-- 見るポイント:
--   - scan_flag が「あり」のプランは、そのテーブルへのアクセスに
--     スキャン系オペレーターが混ざっている。主キーで絞るはずの
--     UPDATE / DELETE / SELECT がスキャンになっていたら、
--     ロック範囲が広がりデッドロックの温床になる。
--   - 判定はプラン全体への混入チェックなので、別テーブルの
--     スキャンで「あり」になることもある。最終確認はプランを
--     開いて、対象テーブル側のオペレーターを見ること。
--   - クエリ文での検索は 03-plan-cache.sql、本ファイルは
--     テーブル起点の検索という役割分担。

DECLARE @TableName sysname = N'テーブル名';   -- ← 書き換える

DECLARE @TableBracketed nvarchar(517) = QUOTENAME(@TableName);

SELECT TOP (50)
    qs.execution_count,
    qs.total_logical_reads,
    qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_logical_reads,
    CASE WHEN qp.query_plan.exist('//*:RelOp[@PhysicalOp = "Index Scan"
                                          or @PhysicalOp = "Clustered Index Scan"
                                          or @PhysicalOp = "Table Scan"]') = 1
         THEN N'スキャン系オペレーターあり（要確認）'
         ELSE N'なし'
    END AS scan_flag,
    SUBSTRING(st.text,
              (qs.statement_start_offset / 2) + 1,
              ((CASE qs.statement_end_offset
                     WHEN -1 THEN DATALENGTH(st.text)
                     ELSE qs.statement_end_offset
                 END - qs.statement_start_offset) / 2) + 1) AS statement_text,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qp.query_plan.exist('//*:Object[@Table = sql:variable("@TableBracketed")]') = 1
ORDER BY qs.total_logical_reads DESC;

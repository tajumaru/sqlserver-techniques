-- 対象テーブルを触るプランをプランキャッシュから探す（シーク判定）
--
-- @TableName を書き換える。DB・スキーマを問わず同名表を含む。
-- 結果は文の累積論理読み取り順。TOP は表示件数の上限。
-- query_plan はコンパイル時のプラン。判定は文単位ではなくプラン全体で行う。
-- scan_flag は同じプラン内のどこかに Index Scan / Clustered Index Scan /
-- Table Scan のいずれかがあることを示す。対象表の操作はプランを開いて確認する。

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

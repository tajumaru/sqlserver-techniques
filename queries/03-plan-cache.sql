-- 03: プランキャッシュから対象クエリのプランを引く（本番で再実行できない時）
-- QueryText はバッチ全体。平均読み取りは文単位の統計で、表示された文面全体とは対応しない場合がある。
-- TOP は表示件数の上限。
-- query_plan 列をクリックすると図のプランが開く。そのまま 01 / 02 の @plan にも使える。

SELECT TOP 20
    qs.execution_count,
    CAST(qs.total_logical_reads AS decimal(28, 4)) / NULLIF(qs.execution_count, 0) AS AvgLogicalReads,
    qs.last_execution_time,
    st.text AS QueryText,
    qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE st.text LIKE N'%対象テーブル名%'
ORDER BY AvgLogicalReads DESC;

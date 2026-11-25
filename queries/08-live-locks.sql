-- 実行中のロック状況（バッチが重なる時間帯に、その場で実行する）
--
-- 使い方:
--   デッドロックが起きる時間帯に、対象バッチの実行中に実行する。
--   結果1: 対象テーブルに今かかっているロックの集計
--          （どのインデックスに・どのモードで・何件か）
--          hobt_id から所属を引けないロックは集計から漏れることがある。
--   結果2: インスタンス全体で待たされている側のリクエストとバッチ文面。
--          待たせている側は ID のみで、SQL は含まない。
--
-- 見るポイント:
--   - 結果1 で PAGE / OBJECT ロックが大量に出ていたら、
--     ロックが膨らんでいる（スキャンや大量行処理の疑い）。
--     普段は KEY（行キー）中心のはず。
--   - 特定の非クラスタ化インデックスにロックが集中していたら、
--     そこが合流点の候補。
--   - 結果2 の wait_resource と待たされている側のバッチ文面が、
--     デッドロック直前の姿を捉えることがある。

DECLARE @SchemaName sysname = N'dbo';
DECLARE @TableName  sysname = N'テーブル名';   -- ← 書き換える

DECLARE @ObjectId int = OBJECT_ID(QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName));

-- 結果1: 対象テーブルのロック集計
SELECT
    l.resource_type,
    COALESCE(i.name, N'(ヒープ/オブジェクト)') AS index_name,
    l.request_mode,
    l.request_status,
    COUNT(*) AS lock_count
FROM sys.dm_tran_locks AS l
LEFT JOIN sys.partitions AS p
    ON p.hobt_id = l.resource_associated_entity_id
   AND l.resource_type IN ('KEY', 'PAGE', 'RID')
LEFT JOIN sys.indexes AS i
    ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE l.resource_database_id = DB_ID()
  AND ((l.resource_type = 'OBJECT' AND l.resource_associated_entity_id = @ObjectId)
       OR p.object_id = @ObjectId)
GROUP BY l.resource_type, COALESCE(i.name, N'(ヒープ/オブジェクト)'),
         l.request_mode, l.request_status
ORDER BY lock_count DESC;

-- 結果2: ブロック中のセッション
SELECT
    r.session_id,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time,
    r.wait_resource,
    LEFT(t.text, 1000) AS running_sql
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id <> 0
ORDER BY r.wait_time DESC;

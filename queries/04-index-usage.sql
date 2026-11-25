-- 04: インデックスの使用実績（そもそも Seek で使われているか）
-- 読み方:
--   user_seeks = 0 で user_scans だけ多い → Seek に使われていない
--   user_lookups が多い → 必要な列をインデックスに含めることを検討する候補
--   user_updates が多く seeks が無い → 書込みコストだけ払っている候補
-- 注意: この統計は SQL Server の再起動や DB の切り離しで消える。
-- 観測なしの回数と日時は NULL で表示する。

SELECT
    OBJECT_NAME(i.object_id) AS TableName,
    i.name  AS IndexName,
    CASE WHEN s.object_id IS NULL THEN N'観測なし' ELSE N'観測あり' END AS usage_status,
    s.user_seeks,     -- Seek で使われた回数
    s.user_scans,     -- Scan でなめられた回数
    s.user_lookups,   -- Key Lookup で戻された回数
    s.user_updates,   -- 書込みで払っているコスト
    s.last_user_seek, s.last_user_scan
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS s
  ON s.object_id = i.object_id AND s.index_id = i.index_id
 AND s.database_id = DB_ID()
WHERE i.object_id = OBJECT_ID(N'dbo.対象テーブル')
ORDER BY s.user_seeks DESC;

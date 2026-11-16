-- 04: インデックスの使用実績（そもそも Seek で使われているか）
-- 読み方:
--   user_seeks = 0 で user_scans だけ多い → Seek に使われていない
--   user_lookups が多い → カバリング不足（本体へ戻りすぎ）
--   user_updates が多く seeks が無い → 書込みコストだけ払っている候補
-- 注意: この統計は SQL Server 再起動でリセットされる。

SELECT
    OBJECT_NAME(s.object_id) AS TableName,
    i.name  AS IndexName,
    s.user_seeks,     -- Seek で使われた回数
    s.user_scans,     -- Scan でなめられた回数
    s.user_lookups,   -- Key Lookup で戻された回数
    s.user_updates,   -- 書込みで払っているコスト
    s.last_user_seek, s.last_user_scan
FROM sys.dm_db_index_usage_stats s
JOIN sys.indexes i
  ON i.object_id = s.object_id AND i.index_id = s.index_id
WHERE s.database_id = DB_ID()
  AND s.object_id = OBJECT_ID('dbo.対象テーブル')
ORDER BY s.user_seeks DESC;

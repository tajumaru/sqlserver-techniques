-- 対象テーブルのインデックス詳細（合流点の候補探し）
--
-- 使い方:
--   先頭の @SchemaName / @TableName を対象に書き換えて実行する。
--   インデックスごとのキー列・包含列・インデックス内の概算行数が返る。
--
-- 見るポイント:
--   - 非クラスタ化インデックスのキー列に「状態」「区分」「日付」の
--     ような値の種類が少ない列（低基数列）がないか。
--     主キーの値が違う業務同士でも、そのインデックスの中では
--     同じキー・同じページに密集し、デッドロックの合流点になる。
--   - UPDATE が書き換える列が、どのインデックスに含まれているか。
--     含まれるインデックスは全て維持対象になり、ロックの接点が増える。
--   - 使用実績の裏取りは 04-index-usage.sql を併用する。

DECLARE @SchemaName sysname = N'dbo';
DECLARE @TableName  sysname = N'テーブル名';   -- ← 書き換える

SELECT
    i.index_id,
    i.name            AS index_name,
    i.type_desc,
    i.is_primary_key,
    i.is_unique,
    keys.key_columns,
    inc.included_columns,
    ps.row_count
FROM sys.indexes AS i
INNER JOIN sys.objects AS o
    ON o.object_id = i.object_id
INNER JOIN sys.schemas AS s
    ON s.schema_id = o.schema_id
OUTER APPLY (
    SELECT STUFF((
        SELECT N', ' + c.name
        FROM sys.index_columns AS ic
        INNER JOIN sys.columns AS c
            ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
          AND ic.is_included_column = 0
          AND ic.key_ordinal > 0
        ORDER BY ic.key_ordinal
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
) AS keys(key_columns)
OUTER APPLY (
    SELECT STUFF((
        SELECT N', ' + c.name
        FROM sys.index_columns AS ic
        INNER JOIN sys.columns AS c
            ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
          AND ic.is_included_column = 1
        ORDER BY ic.index_column_id
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
) AS inc(included_columns)
OUTER APPLY (
    SELECT SUM(p.rows) AS row_count
    FROM sys.partitions AS p
    WHERE p.object_id = i.object_id AND p.index_id = i.index_id
) AS ps
WHERE o.type = 'U'
  AND o.name = @TableName
  AND s.name = @SchemaName
ORDER BY i.index_id;

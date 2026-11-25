/*
  10-statistics-freshness.sql
  対象テーブルの統計情報の鮮度を確認する。

  使い方：
    @SchemaName / @TableName を対象テーブルに変えて実行する。
    結果は統計ごとに1行で、古い順に並ぶ。

  読み方：
    - last_updated        … 最終更新日時
    - modification_counter… 最終更新以降の変更回数
    - pct_changed         … 統計取得時の行数に対する変更回数の割合（100％超もあり得る）
    変更割合が大きいのに更新が古い統計は、推定が外れて
    読み取りが増えることがある。シークでも推定が外れて読みすぎる
    ことがあるため、09 の読み取り量と合わせて判断する。

  注意：
    - 統計が未作成の列は結果に出ない。
    - 表示できる範囲を超えた変更割合は NULL になる。
    - 自動更新（AUTO_UPDATE_STATISTICS）が既定で有効。古典的な発火条件は
      「行数の20％＋500行」の変更、SQL Server 2016以降（互換性レベル130以上）
      では行数に応じて閾値が下がる動的ルールになる。
    - 主キーのように値が増え続ける列（採番キーなど）は、
      ヒストグラムの末尾より先の新しい値が「1行」と推定されやすい
      （ascending key 問題）。その場合は統計の手動更新が効くことがある。
*/

DECLARE @SchemaName sysname = N'dbo';
DECLARE @TableName  sysname = N'YourTableName';

SELECT
    s.name        AS stats_name,
    i.name        AS index_name,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    sp.modification_counter,
    TRY_CAST(100.0 * sp.modification_counter / NULLIF(sp.rows, 0) AS decimal(12, 1)) AS pct_changed
FROM sys.stats AS s
JOIN sys.tables  AS t   ON t.object_id = s.object_id
JOIN sys.schemas AS sch ON sch.schema_id = t.schema_id
LEFT JOIN sys.indexes AS i
       ON i.object_id = s.object_id
      AND i.index_id  = s.stats_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE sch.name = @SchemaName
  AND t.name   = @TableName
ORDER BY sp.last_updated;

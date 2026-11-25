/*
  10-statistics-freshness.sql
  対象テーブルの統計情報の鮮度を確認する。

  使い方：
    @SchemaName / @TableName を対象テーブルに変えて実行する。
    結果は統計ごとに1行で、古い順に並ぶ。

  読み方：
    - stats_name          … 統計の名前。_WA_Sys_ で始まる名前は
                            SQL Server が自動で作った列の統計で、
                            名前だけではどの列か分からない
    - stats_kind          … 自動作成（列の統計）／インデックスの統計／手動作成
    - target_columns      … その統計が対象にしている列（順番どおり、カンマ区切り）
    - last_updated        … 最終更新日時
    - modification_counter… 最終更新以降の変更回数
    - pct_changed         … 統計取得時の行数に対する変更回数の割合（100％超もあり得る）
    変更割合が大きいのに更新が古い統計は、推定が外れて
    読み取りが増えることがある。シークでも推定が外れて読みすぎる
    ことがあるため、09 の読み取り量と合わせて判断する。

  注意：
    - 対象列の表示に STRING_AGG を使うため SQL Server 2017 以降が必要
      （並び替え付きの集計には互換性レベル 110 以上）。
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
    CASE WHEN s.auto_created = 1 THEN N'自動作成（列の統計）'
         WHEN i.index_id IS NOT NULL THEN N'インデックスの統計'
         ELSE N'手動作成' END AS stats_kind,
    cols.target_columns,
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
OUTER APPLY (
    SELECT STRING_AGG(c.name, N', ') WITHIN GROUP (ORDER BY sc.stats_column_id) AS target_columns
    FROM sys.stats_columns AS sc
    JOIN sys.columns AS c
      ON c.object_id = sc.object_id
     AND c.column_id = sc.column_id
    WHERE sc.object_id = s.object_id
      AND sc.stats_id  = s.stats_id
) AS cols
WHERE sch.name = @SchemaName
  AND t.name   = @TableName
ORDER BY sp.last_updated;

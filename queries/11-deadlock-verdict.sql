/*
  11-deadlock-verdict.sql
  デッドロックの「判定まで」を、この1本の中で完結させる統合診断。

  想定する環境：
    お客様のデータを持ち出せない環境。グラフそのもの（05/06）や
    SQL 文面を外に出さず、サーバー内で集計と判定まで終わらせる。

  出力の約束：
    件数・割合・判定・統計の最終更新日時を返す。
    SQL の文面・行データ・接続情報・業務名は一切出さない。
    インデックス名だけは判定に必要なため出る
    （外に共有する場合は、インデックス名を伏せても判定は読める）。

  使い方：
    そのまま実行する。デッドロックの記録の中で
    最も多く現れた表とインデックスの組を調べる。別 DB ならそこで打ち切り、
    表を一意に特定できない場合は「未確認」とする。
    結果は1つだけ（番号・項目・結果）。

  負荷について：
    重いのはプランキャッシュの走査だけ。先頭の @PlanScan で選べる。
      N'間引き' … 既定。文面にテーブル名を含むプランだけに絞り、
                   次の候補があれば200件ごとに1秒休む。候補の収集には休止が効かず、
                   ビューなどを経由して文面に表名がない場合は漏れ得る
      N'しない' … プラン走査を丸ごと省く。記録と統計だけで判定する
                   （スキャンの有無は「未確認」として判定に出る）
      N'一括'   … 絞らず一気に走査する。閑散期向け
    所要時間は保有する記録・プラン・統計の量によって変わる。

  判定の根拠（内部で使っている材料）：
    - 合流点の集計 … 06 と同じ system_health のデッドロックグラフ
    - プランの集計 … 09 と同じプランキャッシュの走査判定
    - 統計の鮮度   … 10 と同じ dm_db_stats_properties
    文の種類（UPDATE/DELETE/INSERT/SELECT の内訳）は、プロセスの
    inputbuf 先頭から動詞を推定した「参考値」。照合順序によっては小文字を見落とす。

  注意：
    - ring_buffer に記録が無ければ「記録なし」と判定する
      （古い記録はローテーションで消える）。通常の結果では、XML への変換で
      欠落があれば別の行に表示する。
*/

SET NOCOUNT ON;

DECLARE @PlanScan nvarchar(10) = N'間引き';   -- N'間引き' / N'しない' / N'一括'

IF @PlanScan IS NULL OR @PlanScan NOT IN (N'間引き', N'しない', N'一括')
BEGIN
    SELECT N'@PlanScan に「間引き」「しない」「一括」のいずれかを指定してください。' AS 案内;
    RETURN;
END;

-- 1) 直近30件のデッドロックを取り込む（06 と同じ抽出）
IF OBJECT_ID('tempdb..#dl') IS NOT NULL DROP TABLE #dl;
CREATE TABLE #dl (
    deadlock_no  int IDENTITY(1,1),
    occurred_at  datetime2,
    graph        xml
);

DECLARE @ring_buffer xml;
SELECT @ring_buffer = CAST(st.target_data AS xml)
FROM sys.dm_xe_session_targets AS st
INNER JOIN sys.dm_xe_sessions AS s
    ON s.address = st.event_session_address
WHERE s.name = 'system_health'
  AND st.target_name = 'ring_buffer';

DECLARE @truncated bit = @ring_buffer.exist('/RingBufferTarget[@truncated="1"]');

;WITH ev AS (
    SELECT
        x.value('@timestamp', 'datetime2') AS occurred_at,
        x.query('.') AS graph
    FROM @ring_buffer.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS t(x)
)
INSERT INTO #dl (occurred_at, graph)
SELECT TOP (30) occurred_at, graph
FROM ev
ORDER BY occurred_at DESC;

DECLARE @n int = (SELECT COUNT(*) FROM #dl);

-- 2) リソース（合流点）を集計する
IF OBJECT_ID('tempdb..#res') IS NOT NULL DROP TABLE #res;
CREATE TABLE #res (
    resource_type varchar(30),
    db_id         int NULL,
    object_name   nvarchar(512) COLLATE DATABASE_DEFAULT,
    index_name    sysname COLLATE DATABASE_DEFAULT NULL
);

INSERT INTO #res (resource_type, db_id, object_name, index_name)
SELECT
    r.value('local-name(.)', 'varchar(30)'),
    r.value('@dbid', 'int'),
    r.value('@objectname', 'nvarchar(512)'),
    r.value('@indexname', 'sysname')
FROM #dl AS d
CROSS APPLY d.graph.nodes('event/data/value/deadlock/resource-list/*') AS t(r);

DECLARE @res_total int = (SELECT COUNT(*) FROM #res);

DECLARE @top_obj nvarchar(512), @top_idx sysname, @top_cnt int, @top_db_id int;
SELECT TOP (1)
    @top_db_id = db_id,
    @top_obj = object_name,
    @top_idx = index_name,
    @top_cnt = COUNT(*)
FROM #res
GROUP BY db_id, object_name, index_name
ORDER BY COUNT(*) DESC, db_id, object_name, index_name;

DECLARE @named_db sysname = PARSENAME(@top_obj, 3);
DECLARE @resource_db sysname = DB_NAME(@top_db_id);
IF (@top_db_id IS NOT NULL AND (@top_db_id <> DB_ID() OR @resource_db <> DB_NAME()))
   OR (@named_db IS NOT NULL AND @named_db <> DB_NAME())
BEGIN
    SELECT 2 AS no, N'合流点' AS item,
           N'合流点は別 DB の表です。その DB に接続してこのクエリを再実行してください。' AS result;
    DROP TABLE #res;
    DROP TABLE #dl;
    RETURN;
END;

DECLARE @top_key int = 0, @top_page int = 0;
SELECT
    @top_key  = SUM(CASE WHEN resource_type LIKE 'key%'  THEN 1 ELSE 0 END),
    @top_page = SUM(CASE WHEN resource_type LIKE 'page%' THEN 1 ELSE 0 END)
FROM #res
WHERE (db_id = @top_db_id OR (db_id IS NULL AND @top_db_id IS NULL))
  AND (object_name = @top_obj OR (object_name IS NULL AND @top_obj IS NULL))
  AND (index_name = @top_idx OR (index_name IS NULL AND @top_idx IS NULL));

-- 3) 文の種類の内訳（参考：inputbuf 先頭から動詞を推定）
DECLARE @v_upd int = 0, @v_del int = 0, @v_ins int = 0, @v_sel int = 0, @v_oth int = 0;
;WITH ib AS (
    SELECT ISNULL(LEFT(p.value('(inputbuf/text())[1]', 'nvarchar(4000)'), 300), N'') AS t
    FROM #dl AS d
    CROSS APPLY d.graph.nodes('event/data/value/deadlock/process-list/process') AS x(p)
),
pos AS (
    SELECT
        CASE WHEN CHARINDEX('UPDATE', t) = 0 THEN 2147483647 ELSE CHARINDEX('UPDATE', t) END AS pu,
        CASE WHEN CHARINDEX('DELETE', t) = 0 THEN 2147483647 ELSE CHARINDEX('DELETE', t) END AS pd,
        CASE WHEN CHARINDEX('INSERT', t) = 0 THEN 2147483647 ELSE CHARINDEX('INSERT', t) END AS pi,
        CASE WHEN CHARINDEX('SELECT', t) = 0 THEN 2147483647 ELSE CHARINDEX('SELECT', t) END AS ps
    FROM ib
),
verb AS (
    SELECT CASE
             WHEN m = 2147483647 THEN N'不明'
             WHEN m = pu THEN N'UPDATE'
             WHEN m = pd THEN N'DELETE'
             WHEN m = pi THEN N'INSERT'
             ELSE N'SELECT'
           END AS v
    FROM (
        SELECT pu, pd, pi, ps,
               CASE WHEN pu <= pd AND pu <= pi AND pu <= ps THEN pu
                    WHEN pd <= pi AND pd <= ps THEN pd
                    WHEN pi <= ps THEN pi
                    ELSE ps END AS m
        FROM pos
    ) AS q
)
SELECT
    @v_upd = ISNULL(SUM(CASE WHEN v = N'UPDATE' THEN 1 ELSE 0 END), 0),
    @v_del = ISNULL(SUM(CASE WHEN v = N'DELETE' THEN 1 ELSE 0 END), 0),
    @v_ins = ISNULL(SUM(CASE WHEN v = N'INSERT' THEN 1 ELSE 0 END), 0),
    @v_sel = ISNULL(SUM(CASE WHEN v = N'SELECT' THEN 1 ELSE 0 END), 0),
    @v_oth = ISNULL(SUM(CASE WHEN v = N'不明'   THEN 1 ELSE 0 END), 0)
FROM verb;

-- 4) 合流点の表を一意に特定する
DECLARE @tbl sysname = PARSENAME(@top_obj, 1);
DECLARE @sch sysname = PARSENAME(@top_obj, 2);

DECLARE @oid int;
SELECT @oid = CASE WHEN COUNT(*) = 1 THEN MIN(t.object_id) END
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.name = @tbl
  AND (@sch IS NULL OR s.name = @sch)
  AND (@sch IS NOT NULL OR @top_obj IN (@tbl, QUOTENAME(@tbl)))
  AND PARSENAME(@top_obj, 4) IS NULL;

DECLARE @index_kind nvarchar(50);
SELECT @index_kind = CASE WHEN is_primary_key = 1 THEN N'主キー'
                          WHEN type IN (1, 5) THEN N'クラスタ化インデックス'
                          WHEN type IN (2, 6) THEN N'非クラスタ化インデックス' END
FROM sys.indexes
WHERE object_id = @oid AND name = @top_idx;

-- 5) プランの集計（09 と同じ判定：対象テーブルを触るプランとスキャンの有無）
--    @PlanScan で負荷を選ぶ。'しない' のときは @plans が NULL のままになる
DECLARE @plans int = NULL, @scans int = NULL;
IF @oid IS NOT NULL AND @PlanScan <> N'しない'
BEGIN
    DECLARE @tblb nvarchar(517) = QUOTENAME(@tbl);

    IF @PlanScan = N'一括'
    BEGIN
        SELECT
            @plans = COUNT(*),
            @scans = ISNULL(SUM(CONVERT(int, scan.has_scan)), 0)
        FROM sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
        CROSS APPLY (VALUES (qp.query_plan.exist('//*:RelOp[@PhysicalOp = "Index Scan"
                                                         or @PhysicalOp = "Clustered Index Scan"
                                                         or @PhysicalOp = "Table Scan"]'))) AS scan(has_scan)
        WHERE qp.query_plan.exist('//*:Object[@Table = sql:variable("@tblb")]') = 1;
    END
    ELSE
    BEGIN
        -- 間引き：文面にテーブル名を含むプランだけに絞り、
        -- 200件ごとに1秒休ませながら1件ずつ判定する
        DECLARE @handles TABLE (plan_handle varbinary(64) PRIMARY KEY);
        INSERT INTO @handles (plan_handle)
        SELECT DISTINCT qs.plan_handle
        FROM sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
        WHERE st.text LIKE N'%' + REPLACE(REPLACE(REPLACE(REPLACE(
            @tbl, N'\', N'\\'), N'%', N'\%'), N'_', N'\_'), N'[', N'\[') + N'%'
            ESCAPE N'\';

        SET @plans = 0;
        SET @scans = 0;

        DECLARE @ph varbinary(64), @qp xml, @done int = 0;
        DECLARE plan_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT plan_handle FROM @handles;
        OPEN plan_cur;
        FETCH NEXT FROM plan_cur INTO @ph;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @qp = NULL;
            SELECT @qp = query_plan FROM sys.dm_exec_query_plan(@ph);
            IF @qp IS NOT NULL
               AND @qp.exist('//*:Object[@Table = sql:variable("@tblb")]') = 1
            BEGIN
                SET @plans += 1;
                IF @qp.exist('//*:RelOp[@PhysicalOp = "Index Scan"
                                        or @PhysicalOp = "Clustered Index Scan"
                                        or @PhysicalOp = "Table Scan"]') = 1
                    SET @scans += 1;
            END;
            SET @done += 1;
            FETCH NEXT FROM plan_cur INTO @ph;
            IF @@FETCH_STATUS = 0 AND @done % 200 = 0
                WAITFOR DELAY '00:00:01';
        END;
        CLOSE plan_cur;
        DEALLOCATE plan_cur;
    END;
END;

-- 6) 統計の最大変更割合と最古の最終更新
DECLARE @worst_pct decimal(38, 10), @oldest datetime2;
IF @oid IS NOT NULL
BEGIN
    SELECT
        @worst_pct = MAX(100.0 * sp.modification_counter / NULLIF(sp.rows, 0)),
        @oldest = MIN(sp.last_updated)
    FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE s.object_id = @oid;
END;

-- 7) 判定を組み立てて、1つの結果で返す
DECLARE @verdict TABLE (no int, item nvarchar(50), result nvarchar(2000));
INSERT INTO @verdict VALUES
    (1, N'記録件数',
        CASE WHEN @ring_buffer IS NULL THEN N'ring_buffer を取得できないため未確認'
             WHEN @n = 0 THEN N'取得できた範囲にデッドロックの記録なし'
             ELSE N'ring_buffer の直近のデッドロック記録 ' + CONVERT(nvarchar(10), @n) + N'件' END),
    (2, N'合流点',
        CASE WHEN @res_total = 0 THEN N'リソースの記録がないため未確認'
             ELSE ISNULL(@top_idx, N'（インデックス名なし）')
                + N' に ' + CONVERT(nvarchar(10), @res_total) + N'件中 ' + CONVERT(nvarchar(10), @top_cnt) + N'件'
                + N'（' + CONVERT(nvarchar(10), CAST(100.0 * @top_cnt / NULLIF(@res_total, 0) AS decimal(5,1))) + N'%）'
                + N'。KEY系 ' + CONVERT(nvarchar(10), @top_key) + N'件 / PAGE系 ' + CONVERT(nvarchar(10), @top_page) + N'件'
                + N' / その他 ' + CONVERT(nvarchar(10), @top_cnt - @top_key - @top_page) + N'件'
                + CASE WHEN @oid IS NULL THEN N'。表を特定できなかった（未確認）'
                       ELSE N'。' + ISNULL(@index_kind, N'インデックス種別は未確認') END END),
    (4, N'プラン',
        CASE WHEN @oid IS NULL THEN N'対象テーブルを特定できなかったため未確認'
             WHEN @plans IS NULL THEN N'プラン走査は未実施。スキャンの有無は未確認'
             WHEN @plans = 0 THEN N'対象のプランがキャッシュに見つからなかったため未確認'
             ELSE N'表名を含むプランの該当件数 ' + CONVERT(nvarchar(10), @plans)
                + N'件、同じプラン内にスキャン系があるもの ' + CONVERT(nvarchar(10), @scans) + N'件'
                + CASE WHEN @PlanScan = N'間引き' THEN N'（間引き走査、プラン単位）'
                       ELSE N'（一括走査、文の統計行単位）' END END),
    (5, N'統計の鮮度',
        CASE WHEN @oid IS NULL THEN N'対象テーブルを特定できなかったため未確認'
             ELSE N'最大変更割合 ' + ISNULL(CONVERT(nvarchar(35), CAST(@worst_pct AS decimal(30,1))) + N'%', N'未確認')
                + N'。最古の最終更新 ' + ISNULL(CONVERT(nvarchar(20), @oldest, 120), N'未確認') END),
    (6, N'総合判定',
        CASE WHEN @res_total = 0 THEN N'合流点は未確認'
             WHEN @top_page > @top_key AND @top_page * 2 > @top_cnt THEN N'ページ単位の衝突が中心'
             WHEN @index_kind IS NOT NULL THEN N'記録上の合流点は ' + @index_kind
             ELSE N'合流点のインデックス種別は未確認' END),
    (7, N'総合判定（統計）',
        CASE WHEN @worst_pct IS NULL THEN N'統計の変更割合は未確認'
             WHEN @worst_pct >= 20 THEN N'変更割合が20%以上の統計あり。調査の目安'
             ELSE N'取得した統計の変更割合はすべて20%未満' END
        + CASE WHEN @plans = 0 THEN N'。プランがキャッシュに無いため未確認'
               WHEN @plans IS NULL THEN N'。プランは未確認'
               ELSE N'。スキャンの確認は結果4を参照' END);

IF @n > 0
    INSERT INTO @verdict VALUES (3, N'文の内訳（参考）',
        N'UPDATE ' + CONVERT(nvarchar(10), @v_upd)
        + N' / DELETE ' + CONVERT(nvarchar(10), @v_del)
        + N' / INSERT ' + CONVERT(nvarchar(10), @v_ins)
        + N' / SELECT ' + CONVERT(nvarchar(10), @v_sel)
        + N' / 不明 ' + CONVERT(nvarchar(10), @v_oth));

IF @truncated = 1
    INSERT INTO @verdict VALUES (8, N'記録の欠落', N'ring_buffer の XML 変換で記録の一部が欠落しています。');

SELECT no, item, result
FROM @verdict
ORDER BY no;

-- 後片付け（同じセッションで再実行しても残らないように）
DROP TABLE #res;
DROP TABLE #dl;

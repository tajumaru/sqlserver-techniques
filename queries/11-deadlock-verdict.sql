/*
  11-deadlock-verdict.sql
  デッドロックの「判定まで」を、この1本の中で完結させる統合診断。

  想定する環境：
    お客様のデータを持ち出せない環境。グラフそのもの（05/06）や
    SQL 文面を外に出さず、サーバー内で集計と判定まで終わらせる。

  出力の約束：
    出るのは「件数」「割合」「型の判定」だけ。
    SQL の文面・行データ・接続情報・業務名は一切出さない。
    インデックス名だけは判定に必要なため出る
    （外に共有する場合は、インデックス名を伏せても判定は読める）。

  使い方：
    そのまま実行する。対象テーブルは、デッドロックの記録の中で
    最も多く合流点になったテーブルから自動で特定する。
    結果は1つだけ（番号・項目・結果）。

  負荷について：
    重いのはプランキャッシュの走査だけ。先頭の @PlanScan で選べる。
      N'間引き' … 既定。文面にテーブル名を含むプランだけに絞り、
                   200件ごとに1秒休ませながら走査する（CPU を分散）
      N'しない' … プラン走査を丸ごと省く。記録と統計だけで判定する
                   （スキャンの有無は「未確認」として判定に出る）
      N'一括'   … 絞らず一気に走査する。閑散期向け
    記録の読み取り・合流点の集計・統計の確認はいずれも軽い。

  判定の根拠（内部で使っている材料）：
    - 合流点の集計 … 06 と同じ system_health のデッドロックグラフ
    - プランの集計 … 09 と同じプランキャッシュの走査判定
    - 統計の鮮度   … 10 と同じ dm_db_stats_properties
    文の種類（UPDATE/DELETE/INSERT/SELECT の内訳）は、プロセスの
    inputbuf 先頭から動詞を推定した「参考値」。

  注意：
    - ring_buffer に記録が無ければ「記録なし」と判定する
      （古い記録はローテーションで消える。発生直後の実行が確実）。
*/

SET NOCOUNT ON;

DECLARE @PlanScan nvarchar(10) = N'間引き';   -- N'間引き' / N'しない' / N'一括'

-- 1) 直近30件のデッドロックを取り込む（06 と同じ抽出）
IF OBJECT_ID('tempdb..#dl') IS NOT NULL DROP TABLE #dl;
CREATE TABLE #dl (
    deadlock_no  int IDENTITY(1,1),
    occurred_at  datetime2,
    graph        xml
);

WITH ev AS (
    SELECT
        x.value('@timestamp', 'datetime2') AS occurred_at,
        x.query('.')                       AS graph
    FROM (
        SELECT CAST(st.target_data AS XML) AS target_data
        FROM sys.dm_xe_session_targets AS st
        INNER JOIN sys.dm_xe_sessions AS s
            ON s.address = st.event_session_address
        WHERE s.name = 'system_health'
          AND st.target_name = 'ring_buffer'
    ) AS d
    CROSS APPLY d.target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS t(x)
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
    object_name   nvarchar(512),
    index_name    sysname NULL
);

INSERT INTO #res (resource_type, object_name, index_name)
SELECT
    r.value('local-name(.)', 'varchar(30)'),
    r.value('@objectname', 'nvarchar(512)'),
    r.value('@indexname', 'sysname')
FROM #dl AS d
CROSS APPLY d.graph.nodes('event/data/value/deadlock/resource-list/*') AS t(r);

DECLARE @res_total int = (SELECT COUNT(*) FROM #res);

DECLARE @top_obj nvarchar(512), @top_idx sysname, @top_cnt int;
SELECT TOP (1)
    @top_obj = object_name,
    @top_idx = index_name,
    @top_cnt = COUNT(*)
FROM #res
GROUP BY object_name, index_name
ORDER BY COUNT(*) DESC;

DECLARE @top_key int = 0, @top_page int = 0;
SELECT
    @top_key  = SUM(CASE WHEN resource_type LIKE '%key%'  THEN 1 ELSE 0 END),
    @top_page = SUM(CASE WHEN resource_type LIKE '%page%' THEN 1 ELSE 0 END)
FROM #res
WHERE object_name = @top_obj
  AND ISNULL(index_name, N'') = ISNULL(@top_idx, N'');

-- 3) 文の種類の内訳（参考：inputbuf 先頭から動詞を推定）
DECLARE @v_upd int = 0, @v_del int = 0, @v_ins int = 0, @v_sel int = 0, @v_oth int = 0;
WITH ib AS (
    SELECT LEFT(p.value('(inputbuf/text())[1]', 'nvarchar(4000)'), 300) AS t
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
    @v_upd = SUM(CASE WHEN v = N'UPDATE' THEN 1 ELSE 0 END),
    @v_del = SUM(CASE WHEN v = N'DELETE' THEN 1 ELSE 0 END),
    @v_ins = SUM(CASE WHEN v = N'INSERT' THEN 1 ELSE 0 END),
    @v_sel = SUM(CASE WHEN v = N'SELECT' THEN 1 ELSE 0 END),
    @v_oth = SUM(CASE WHEN v = N'不明'   THEN 1 ELSE 0 END)
FROM verb;

-- 4) 対象テーブルを特定する（合流点の最頻テーブル）
DECLARE @tbl sysname = PARSENAME(@top_obj, 1);
DECLARE @sch sysname = PARSENAME(@top_obj, 2);

DECLARE @oid int;
SELECT @oid = t.object_id
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.name = @tbl
  AND (@sch IS NULL OR s.name = @sch);

DECLARE @clustered_name sysname;
SELECT @clustered_name = name
FROM sys.indexes
WHERE object_id = @oid AND type = 1;

DECLARE @top_is_clustered bit =
    CASE WHEN @top_idx IS NOT NULL AND @top_idx = @clustered_name THEN 1 ELSE 0 END;

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
            @scans = SUM(CASE WHEN qp.query_plan.exist('//*:RelOp[@PhysicalOp = "Index Scan"
                                                                  or @PhysicalOp = "Clustered Index Scan"
                                                                  or @PhysicalOp = "Table Scan"]') = 1
                              THEN 1 ELSE 0 END)
        FROM sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
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
        WHERE st.text LIKE N'%' + @tbl + N'%';

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
            IF @done % 200 = 0 WAITFOR DELAY '00:00:01';
            FETCH NEXT FROM plan_cur INTO @ph;
        END;
        CLOSE plan_cur;
        DEALLOCATE plan_cur;
    END;
END;

-- 6) 統計の鮮度（10 と同じ：最も変わった統計と、最古の最終更新）
DECLARE @worst_pct decimal(6,1) = NULL, @worst_name sysname = NULL, @oldest datetime = NULL;
IF @oid IS NOT NULL
BEGIN
    SELECT TOP (1)
        @worst_pct  = CAST(100.0 * sp.modification_counter / NULLIF(sp.rows, 0) AS decimal(6,1)),
        @worst_name = s.name
    FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE s.object_id = @oid
    ORDER BY 100.0 * sp.modification_counter / NULLIF(sp.rows, 0) DESC;

    SELECT @oldest = MIN(sp.last_updated)
    FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE s.object_id = @oid;
END;

-- 7) 判定を組み立てて、1つの結果で返す
IF OBJECT_ID('tempdb..#verdict') IS NOT NULL DROP TABLE #verdict;
CREATE TABLE #verdict (
    no     int,
    item   nvarchar(50),
    result nvarchar(2000)
);

INSERT INTO #verdict (no, item, result)
VALUES (1, N'記録件数',
        CASE WHEN @n = 0
             THEN N'デッドロックの記録なし'
             ELSE N'直近のデッドロック記録 ' + CAST(@n AS nvarchar(10)) + N'件（ring_buffer 内）'
        END);

IF @n > 0
BEGIN
    INSERT INTO #verdict (no, item, result)
    VALUES (2, N'合流点',
            ISNULL(@top_idx, N'（インデックス名なし）')
            + N' に ' + CAST(@res_total AS nvarchar(10)) + N'件中 ' + CAST(@top_cnt AS nvarchar(10)) + N'件'
            + N'（' + CAST(CAST(100.0 * @top_cnt / NULLIF(@res_total, 0) AS decimal(5,1)) AS nvarchar(10)) + N'%）'
            + N'。内訳 KEY系 ' + CAST(@top_key AS nvarchar(10)) + N'件 / PAGE系 ' + CAST(@top_page AS nvarchar(10)) + N'件'
            + CASE WHEN @top_is_clustered = 1 THEN N'。このインデックスはクラスタ化（主キー側）' ELSE N'' END);

    INSERT INTO #verdict (no, item, result)
    VALUES (3, N'文の内訳（参考）',
            N'UPDATE ' + CAST(@v_upd AS nvarchar(10))
            + N' / DELETE ' + CAST(@v_del AS nvarchar(10))
            + N' / INSERT ' + CAST(@v_ins AS nvarchar(10))
            + N' / SELECT ' + CAST(@v_sel AS nvarchar(10))
            + N' / 不明 ' + CAST(@v_oth AS nvarchar(10)));
END;

IF @oid IS NOT NULL AND @plans IS NOT NULL
    INSERT INTO #verdict (no, item, result)
    VALUES (4, N'プラン',
            N'対象テーブルを触るプラン ' + CAST(@plans AS nvarchar(10))
            + N'件、うちスキャン系 ' + CAST(ISNULL(@scans, 0) AS nvarchar(10)) + N'件'
            + CASE WHEN @PlanScan = N'間引き' THEN N'（間引き走査）' ELSE N'' END);
ELSE IF @oid IS NOT NULL
    INSERT INTO #verdict (no, item, result)
    VALUES (4, N'プラン',
            N'プラン走査は未実施（@PlanScan = しない）。スキャンの有無は未確認');

IF @oid IS NOT NULL AND @worst_pct IS NOT NULL
    INSERT INTO #verdict (no, item, result)
    VALUES (5, N'統計の鮮度',
            N'最も変わった統計「' + ISNULL(@worst_name, N'') + N'」で変更 '
            + CAST(@worst_pct AS nvarchar(10)) + N'%'
            + N'。最終更新の最古は ' + CONVERT(nvarchar(20), @oldest, 120));

-- 総合判定（ルールに基づく機械的な判定）
IF @n = 0
    INSERT INTO #verdict (no, item, result)
    VALUES (6, N'総合判定',
            N'記録がないため判定できない。ring_buffer は古いものから消えるので、発生直後に再実行すること');
ELSE
BEGIN
    IF @top_page > @top_key
        INSERT INTO #verdict (no, item, result)
        VALUES (6, N'総合判定',
                N'ページ単位の衝突が中心。近いキー同士の同時処理、大量処理を刻んでいないこと、ロック昇格を疑う');
    ELSE IF @top_is_clustered = 1
        INSERT INTO #verdict (no, item, result)
        VALUES (6, N'総合判定',
                N'主キー（クラスタ）上での衝突。値が異なるはずの行同士が合っているので、範囲で掴む文・主キー以外の条件で広く取る文・業務間の処理順の違いを疑う');
    ELSE
        INSERT INTO #verdict (no, item, result)
        VALUES (6, N'総合判定',
                N'合流点は非クラスタ化インデックス「' + ISNULL(@top_idx, N'') + N'」。対策の中心は、掴む順序の統一と、そのインデックスの見直し');

    IF @plans IS NULL
    BEGIN
        IF ISNULL(@worst_pct, 0) >= 20
            INSERT INTO #verdict (no, item, result)
            VALUES (7, N'総合判定（統計）',
                    N'統計は古い。ただしプラン走査をしていないため、スキャンが頻度を押し上げているかは未確認。@PlanScan を「間引き」にして再実行すると確認できる');
        ELSE
            INSERT INTO #verdict (no, item, result)
            VALUES (7, N'総合判定（統計）',
                    N'統計は新しめ。プラン走査は未実施のため、スキャンの有無だけ未確認');
    END
    ELSE IF @plans > 0 AND ISNULL(@scans, 0) * 2 >= @plans AND ISNULL(@worst_pct, 0) >= 20
        INSERT INTO #verdict (no, item, result)
        VALUES (7, N'総合判定（統計）',
                N'スキャンのプランが優勢で、統計も古い。統計の更新でデッドロックの頻度が下がる見込みがある');
    ELSE IF @plans > 0 AND ISNULL(@scans, 0) * 2 >= @plans
        INSERT INTO #verdict (no, item, result)
        VALUES (7, N'総合判定（統計）',
                N'スキャンのプランが優勢だが、統計は新しめ。暗黙変換や WHERE の形を疑う（統計更新の効果は限定的）');
    ELSE IF ISNULL(@worst_pct, 0) >= 20
        INSERT INTO #verdict (no, item, result)
        VALUES (7, N'総合判定（統計）',
                N'プランはシーク中心だが統計は古い。統計更新は予防にはなるが、頻度の主因ではない可能性が高い');
    ELSE
        INSERT INTO #verdict (no, item, result)
        VALUES (7, N'総合判定（統計）',
                N'プラン・統計とも大きな異常なし。頻度の主因は、掴む順序と合流点のインデックス側にある');
END;

SELECT no, item, result
FROM #verdict
ORDER BY no;

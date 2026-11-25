/*
  13-health-check.sql
  健康診断（統合版）。11 の日常版。

  1回の実行で、インスタンスと「実行した DB」の状態を
  項目・結果・判定の形で返す。SQL の文面は出さない
  （件数・時間・分類・割合）ので、判定だけを外に持ち帰れる。

  項目：
    1. ブロッキング      … いま誰かが誰かを待たせていないか
    2. 実行中の処理      … 長時間の実行が走っていないか
    3. 待機の内訳        … 起動または手動クリアからの累積で、何待ちが支配的か
    4. 統計の鮮度        … 実行した DB の統計が古くなっていないか
    5. インデックス断片化… 実行した DB のインデックスの行内データの断片化（パーティション単位）
    6. デッドロック      … 保持分のうち直近24時間の記録件数
    7. メモリ割り当て待ち… メモリ不足で待っているクエリがないか

  注意：
    - 項目4 は実行した DB の全統計を評価する。項目5 も同じ DB が対象。
    - 項目3 は累積の概観。時間帯を絞った分析は 12（差分）を使う。
    - 項目4・5 は対象が多いほど時間がかかる。項目5 は LIMITED モードで
      調べる。先頭の @IncludeFrag を「しない」にすると項目5は未実施になる。
    - temp テーブルは使わない（テーブル変数だけなので何も残らない）。
    - 待機の内訳の文字列化に STRING_AGG を使うため SQL Server 2017 以降。
      WITHIN GROUP で並べ替えるため、実行する DB の互換性レベルは 110 以上。
*/

SET NOCOUNT ON;

DECLARE @IncludeFrag nvarchar(10) = N'する';  -- N'する' / N'しない'
IF @IncludeFrag IS NULL OR @IncludeFrag NOT IN (N'する', N'しない')
BEGIN
    SELECT N'@IncludeFrag に「する」または「しない」を指定してください。' AS 案内;
    RETURN;
END;

DECLARE @v TABLE (
    no      int,
    item    nvarchar(50),
    result  nvarchar(1000),
    verdict nvarchar(500)
);

-- 1) ブロッキング
DECLARE @blocked int, @unknown_blocker int, @block_max_sec int;
SELECT
    @blocked = COUNT(CASE WHEN blocking_session_id > 0 THEN 1 END),
    @unknown_blocker = COUNT(CASE WHEN blocking_session_id < 0 THEN 1 END),
    @block_max_sec = ISNULL(MAX(wait_time), 0) / 1000
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0;

INSERT INTO @v VALUES (1, N'ブロッキング',
    N'ブロック元の ID が正の待機 ' + CAST(@blocked AS nvarchar(10)) + N'件、最長 '
    + CAST(@block_max_sec AS nvarchar(10)) + N'秒（両区分の最長）'
    + CASE WHEN @unknown_blocker > 0 THEN N'。出所不明のブロック元あり（待機 '
        + CAST(@unknown_blocker AS nvarchar(10)) + N'件）' ELSE N'' END,
    CASE WHEN @blocked = 0 AND @unknown_blocker = 0 THEN N'なし'
         ELSE N'発生中。08 で中身を確認する' END);

-- 2) 実行中の処理
DECLARE @running int = 0, @run_max_sec int = 0;
SELECT
    @running     = COUNT(*),
    @run_max_sec = ISNULL(MAX(total_elapsed_time), 0) / 1000
FROM sys.dm_exec_requests
WHERE session_id > 50
  AND session_id <> @@SPID;

INSERT INTO @v VALUES (2, N'実行中の処理',
    N'実行中 ' + CAST(@running AS nvarchar(10)) + N'件、最長 '
    + CAST(@run_max_sec AS nvarchar(10)) + N'秒',
    CASE WHEN @running = 0 THEN N'実行中の処理なし'
         WHEN @run_max_sec < 60 THEN N'通常範囲'
         ELSE N'1分以上の実行あり' END);

-- 3) 待機の内訳（起動または手動クリアからの累積、アイドル系を除く）
DECLARE @waits_text nvarchar(1000), @majority_class nvarchar(50);
;WITH w AS (
    SELECT
        CASE
            WHEN wait_type LIKE 'PAGEIOLATCH%' THEN N'I/O'
            WHEN wait_type LIKE 'LCK%'         THEN N'ロック'
            WHEN wait_type LIKE 'PAGELATCH%' OR wait_type LIKE 'LATCH%' THEN N'ラッチ'
            WHEN wait_type IN ('CXPACKET', 'CXCONSUMER') OR wait_type LIKE 'EXCHANGE%' THEN N'並列'
            WHEN wait_type = 'SOS_SCHEDULER_YIELD' OR wait_type = 'THREADPOOL' THEN N'CPU'
            WHEN wait_type = 'WRITELOG' OR wait_type LIKE 'LOGBUFFER%' THEN N'ログ'
            WHEN wait_type LIKE 'RESOURCE_SEMAPHORE%' THEN N'メモリ'
            WHEN wait_type = 'ASYNC_NETWORK_IO' THEN N'ネットワーク'
            ELSE N'その他'
        END AS class,
        wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE wait_time_ms > 0
      AND wait_type NOT IN (
        'BROKER_EVENTHANDLER', 'BROKER_RECEIVE_WAITFOR', 'BROKER_TASK_STOP',
        'BROKER_TO_FLUSH', 'BROKER_TRANSMITTER', 'CHECKPOINT_QUEUE', 'CHKPT',
        'CLR_SEMAPHORE', 'DBMIRROR_DBM_EVENT', 'DBMIRROR_EVENTS_QUEUE',
        'DBMIRROR_WORKER_QUEUE', 'DBMIRRORING_CMD', 'DIRTY_PAGE_POLL',
        'DISPATCHER_QUEUE_SEMAPHORE', 'EXECSYNC', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
        'FT_IFTSHC_MUTEX', 'HADR_CLUSAPI_CALL', 'HADR_LOGCAPTURE_WAIT',
        'HADR_NOTIFICATION_DEQUEUE', 'HADR_TIMER_TASK', 'HADR_WORK_QUEUE',
        'KSOURCE_WAKEUP', 'LAZYWRITER_SLEEP', 'LOGMGR_QUEUE',
        'ONDEMAND_TASK_QUEUE', 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
        'QDS_ASYNC_QUEUE', 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        'REQUEST_FOR_DEADLOCK_SEARCH', 'RESOURCE_QUEUE', 'SERVER_IDLE_CHECK',
        'SLEEP_BPOOL_FLUSH', 'SLEEP_DBSTARTUP', 'SLEEP_DCOMSTARTUP',
        'SLEEP_MASTERDBREADY', 'SLEEP_MASTERMDREADY', 'SLEEP_MASTERUPGRADED',
        'SLEEP_MSDBSTARTUP', 'SLEEP_SYSTEMTASK', 'SLEEP_TASK',
        'SLEEP_TEMPDBSTARTUP', 'SP_SERVER_DIAGNOSTICS_SLEEP',
        'SQLTRACE_BUFFER_FLUSH', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        'SQLTRACE_WAIT_ENTRIES', 'TRACEWRITE', 'WAIT_FOR_RESULTS',
        'WAITFOR', 'WAITFOR_TASKSHUTDOWN', 'XE_DISPATCHER_JOIN',
        'XE_DISPATCHER_WAIT', 'XE_TIMER_EVENT'
      )
),
agg AS (
    SELECT class, SUM(wait_time_ms) AS ms FROM w GROUP BY class
),
tot AS (
    SELECT SUM(ms) AS t FROM agg
),
top3 AS (
    SELECT TOP (3) class, ms, t, CAST(100.0 * ms / NULLIF(t, 0) AS decimal(5,1)) AS pct
    FROM agg CROSS JOIN tot ORDER BY ms DESC, class
)
SELECT
    @waits_text = STRING_AGG(class + N' ' + CAST(pct AS nvarchar(10)) + N'%', N' / ') WITHIN GROUP (ORDER BY ms DESC, class),
    @majority_class = MAX(CASE WHEN ms > t - ms THEN class END)
FROM top3;

INSERT INTO @v VALUES (3, N'待機の内訳（累積）',
    ISNULL(@waits_text, N'記録なし'),
    CASE WHEN @waits_text IS NULL THEN N'記録なし'
         WHEN @majority_class IS NOT NULL THEN @majority_class + N'待ちが過半。ここから掘る。時間帯の特定は 12（差分）'
         ELSE N'分散している。時間帯の特定は 12（差分）を使う' END);

-- 4) 統計の鮮度（実行した DB）
DECLARE @stats_count int, @stats_bad int, @stats_worst decimal(38, 10);
SELECT
    @stats_count = COUNT(*),
    @stats_worst = ISNULL(MAX(pct), 0),
    @stats_bad   = ISNULL(SUM(CASE WHEN pct >= 20 THEN 1 ELSE 0 END), 0)
FROM (
    SELECT 100.0 * sp.modification_counter / NULLIF(sp.rows, 0) AS pct
    FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE sp.rows > 0
) AS q;

INSERT INTO @v VALUES (4, N'統計の鮮度（この DB）',
    N'変更20%以上の統計 ' + CAST(@stats_bad AS nvarchar(10)) + N'件、最大 '
    + CAST(CAST(@stats_worst AS decimal(30,1)) AS nvarchar(35)) + N'%',
    CASE WHEN @stats_count = 0 THEN N'評価できる統計なし'
         WHEN @stats_bad > 0 THEN N'変更割合の大きい統計あり。10 で詳細を見る'
         ELSE N'評価した統計の変更割合はすべて20%未満' END);

-- 5) インデックス断片化（実行した DB、LIMITED モード）
IF @IncludeFrag = N'しない'
    INSERT INTO @v VALUES (5, N'インデックス断片化（この DB）', N'未実施', N'未実施');
ELSE
BEGIN
    DECLARE @frag_count int, @frag_bad int, @frag_max decimal(5,1);
    SELECT
        @frag_count = COUNT(*),
        @frag_bad = ISNULL(SUM(CASE WHEN avg_fragmentation_in_percent >= 30 THEN 1 ELSE 0 END), 0),
        @frag_max = ISNULL(MAX(avg_fragmentation_in_percent), 0)
    FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED')
    WHERE index_id > 0
      AND alloc_unit_type_desc = 'IN_ROW_DATA'
      AND page_count >= 1000;

    INSERT INTO @v VALUES (5, N'インデックス断片化（この DB）',
        N'断片化30%以上（1,000ページ以上）のパーティション '
        + CAST(@frag_bad AS nvarchar(10)) + N'件、最大 ' + CAST(@frag_max AS nvarchar(10)) + N'%',
        CASE WHEN @frag_count = 0 THEN N'評価対象のパーティションなし'
             WHEN @frag_bad > 0 THEN N'再編成・再構築の候補あり'
             ELSE N'対象パーティションに大きな断片化なし' END);
END;

-- 6) デッドロック（保持分のうち直近24時間）
DECLARE @dl24 int, @ring_buffer xml;
SELECT @ring_buffer = CAST(st.target_data AS xml)
FROM sys.dm_xe_session_targets AS st
INNER JOIN sys.dm_xe_sessions AS s
    ON s.address = st.event_session_address
WHERE s.name = 'system_health'
  AND st.target_name = 'ring_buffer';

SELECT @dl24 = COUNT(*)
FROM @ring_buffer.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS t(x)
WHERE x.value('@timestamp', 'datetime2') >= DATEADD(HOUR, -24, SYSUTCDATETIME());

INSERT INTO @v VALUES (6, N'デッドロック（保持分のうち直近24時間）',
    CASE WHEN @ring_buffer IS NULL THEN N'ring_buffer を取得できないため未確認'
         ELSE CAST(@dl24 AS nvarchar(10)) + N'件'
            + CASE WHEN @ring_buffer.exist('/RingBufferTarget[@truncated="1"]') = 1
                   THEN N'（XML 変換で欠落あり）' ELSE N'' END END,
    CASE WHEN @ring_buffer IS NULL THEN N'未確認'
         WHEN @dl24 = 0 THEN N'取得できた範囲に記録なし'
         WHEN @dl24 >= 5 THEN N'保持分に5件以上。11 で確認する'
         ELSE N'記録あり。11 で確認する' END);

-- 7) メモリ割り当て待ち
DECLARE @mg_wait int = 0;
SELECT @mg_wait = COUNT(*)
FROM sys.dm_exec_query_memory_grants
WHERE grant_time IS NULL;

INSERT INTO @v VALUES (7, N'メモリ割り当て待ち',
    CAST(@mg_wait AS nvarchar(10)) + N'件',
    CASE WHEN @mg_wait = 0 THEN N'なし'
         ELSE N'メモリ待ちのクエリあり。大きなソート・ハッシュを疑う' END);

SELECT no, item, result, verdict
FROM @v
ORDER BY no;

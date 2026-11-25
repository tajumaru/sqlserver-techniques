/*
  13-health-check.sql
  健康診断（統合版）。11 の日常版。

  1回の実行で、インスタンスと「実行した DB」の状態を
  項目・結果・判定の形で返す。SQL の文面は出さない
  （件数と時間だけ）ので、判定だけを外に持ち帰れる。

  項目：
    1. ブロッキング      … いま誰かが誰かを待たせていないか
    2. 実行中の処理      … 長時間の実行が走っていないか
    3. 待機の内訳        … 起動からの累積で、何待ちが支配的か
    4. 統計の鮮度        … 実行した DB の統計が古くなっていないか
    5. インデックス断片化… 実行した DB の大きなインデックスの断片化
    6. デッドロック      … 直近24時間の発生件数
    7. メモリ割り当て待ち… メモリ不足で待っているクエリがないか

  注意：
    - 項目4・5 の対象は「このクエリを実行した DB」だけ。
    - 項目3 は累積の概観。時間帯を絞った分析は 12（差分）を使う。
    - 項目5 は LIMITED モード（軽量）だが、インデックス数が多い DB
      では数秒かかることがある。
    - temp テーブルは使わない（テーブル変数だけなので何も残らない）。
    - 待機の内訳の文字列化に STRING_AGG を使うため SQL Server 2017 以降。
*/

SET NOCOUNT ON;

DECLARE @v TABLE (
    no      int,
    item    nvarchar(50),
    result  nvarchar(1000),
    verdict nvarchar(500)
);

-- 1) ブロッキング
DECLARE @blocked int = 0, @block_max_sec int = 0;
SELECT
    @blocked     = COUNT(*),
    @block_max_sec = ISNULL(MAX(wait_time), 0) / 1000
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0;

INSERT INTO @v VALUES (1, N'ブロッキング',
    N'待たされている処理 ' + CAST(@blocked AS nvarchar(10)) + N'件、最長 '
    + CAST(@block_max_sec AS nvarchar(10)) + N'秒',
    CASE WHEN @blocked = 0 THEN N'なし'
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

-- 3) 待機の内訳（起動からの累積、アイドル系を除く）
DECLARE @waits_text nvarchar(1000), @top_pct decimal(5,1) = 0, @top_class nvarchar(50);
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
    SELECT TOP (3) class, ms, CAST(100.0 * ms / NULLIF((SELECT t FROM tot), 0) AS decimal(5,1)) AS pct
    FROM agg ORDER BY ms DESC
)
SELECT
    @waits_text = STRING_AGG(class + N' ' + CAST(pct AS nvarchar(10)) + N'%', N' / ') WITHIN GROUP (ORDER BY ms DESC),
    @top_pct    = MAX(pct),
    @top_class  = (SELECT TOP (1) class FROM top3 ORDER BY ms DESC)
FROM top3;

INSERT INTO @v VALUES (3, N'待機の内訳（累積）',
    ISNULL(@waits_text, N'記録なし'),
    CASE WHEN @top_pct >= 50 THEN ISNULL(@top_class, N'') + N'待ちが過半。ここから掘る。時間帯の特定は 12（差分）'
         ELSE N'分散している。時間帯の特定は 12（差分）を使う' END);

-- 4) 統計の鮮度（実行した DB）
DECLARE @stats_bad int = 0, @stats_worst decimal(6,1) = 0;
SELECT
    @stats_worst = ISNULL(MAX(pct), 0),
    @stats_bad   = SUM(CASE WHEN pct >= 20 THEN 1 ELSE 0 END)
FROM (
    SELECT CAST(100.0 * sp.modification_counter / NULLIF(sp.rows, 0) AS decimal(6,1)) AS pct
    FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE sp.rows > 0
) AS q;

INSERT INTO @v VALUES (4, N'統計の鮮度（この DB）',
    N'変更20%以上の統計 ' + CAST(@stats_bad AS nvarchar(10)) + N'件、最大 '
    + CAST(@stats_worst AS nvarchar(10)) + N'%',
    CASE WHEN @stats_worst >= 20 THEN N'古い統計あり。10 で詳細を見る'
         ELSE N'概ね新しい' END);

-- 5) インデックス断片化（実行した DB、LIMITED モード）
DECLARE @frag_bad int = 0, @frag_max decimal(5,1) = 0;
SELECT
    @frag_bad = SUM(CASE WHEN avg_fragmentation_in_percent >= 30 THEN 1 ELSE 0 END),
    @frag_max = ISNULL(MAX(avg_fragmentation_in_percent), 0)
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED')
WHERE index_id > 0
  AND page_count >= 1000;

INSERT INTO @v VALUES (5, N'インデックス断片化（この DB）',
    N'断片化30%以上（1,000ページ超） ' + CAST(@frag_bad AS nvarchar(10)) + N'件、最大 '
    + CAST(@frag_max AS nvarchar(10)) + N'%',
    CASE WHEN @frag_bad > 0 THEN N'再編成・再構築の候補あり'
         ELSE N'大きな断片化なし' END);

-- 6) デッドロック（直近24時間）
DECLARE @dl24 int = 0;
;WITH ev AS (
    SELECT x.value('@timestamp', 'datetime2') AS occurred_at
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
SELECT @dl24 = COUNT(*)
FROM ev
WHERE occurred_at >= DATEADD(HOUR, -24, CAST(SYSUTCDATETIME() AS datetime2));

INSERT INTO @v VALUES (6, N'デッドロック（直近24時間）',
    CAST(@dl24 AS nvarchar(10)) + N'件',
    CASE WHEN @dl24 = 0 THEN N'なし'
         WHEN @dl24 >= 5 THEN N'多発。11 で判定を急ぐ'
         ELSE N'発生あり。11 で判定する' END);

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

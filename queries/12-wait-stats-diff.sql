/*
  12-wait-stats-diff.sql
  待機統計の「差分」を見る。調査の入口。

  仕組み：
    dm_os_wait_stats はインスタンス起動または手動クリアからの累積なので、そのままでは
    「いつ・何待ちで時間を食ったか」が分からない。このファイルは
    1回目の実行で現在値を記録し、2回目以降の実行で「前回の実行からの増分」
    だけを出す。バッチの実行前と実行後に挟む、障害の前後で挟む、など
    「見たい時間帯」を挟んで使う。

  使い方：
    同じセッション（同じクエリウィンドウ）で2回実行する。
    1回目 …「記録した」という案内だけが返る
    2回目 … 増分の上位15件（待ちの種類・増えた時間・意味）と、
             スナップショット更新の案内が返る
    3回目以降も、前回の実行からの増分になる。

  temp テーブルについて：
    差分を取るため、このファイルだけは #wait_snapshot を
    セッションに残す設計（セッションを閉じれば自動で消える）。
    手動で片付ける場合は DROP TABLE #wait_snapshot を実行する。

  注意：
    - 再起動すると接続と基準が消えるため、新しい接続で初回から測る。
    - 同じ接続内の巻き戻りは手動クリア（DBCC SQLPERF）で起きる。
      待ち時間の合計が前回より小さい場合は案内だけを返し、今回値を次の基準にする。
      クリア後に合計が前回以上まで増えると検知できない。
    - アイドル系の待機は差分表示から除く。リセット検知の合計には含める。
    - 増分の見方：wait_time の大半が signal（CPU に空きがなく待った分）
      なら CPU 側、resource（wait_time − signal）が大半なら
      ロックや I/O など「相手・媒体待ち」側。
*/

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#wait_snapshot') IS NULL
BEGIN
    CREATE TABLE #wait_snapshot (
        wait_type           nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL,
        waiting_tasks_count bigint NOT NULL,
        wait_time_ms        bigint NOT NULL,
        signal_wait_time_ms bigint NOT NULL
    );
    BEGIN TRY
        INSERT INTO #wait_snapshot (wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms)
        SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
        FROM sys.dm_os_wait_stats;
    END TRY
    BEGIN CATCH
        DROP TABLE #wait_snapshot;
        THROW;
    END CATCH;

    SELECT N'1回目の待機統計を記録しました。同じ接続で再実行すると、前回の実行からの増分が出ます。' AS 案内;
    RETURN;
END;

IF OBJECT_ID('tempdb..#wait_current') IS NOT NULL DROP TABLE #wait_current;
CREATE TABLE #wait_current (
    wait_type           nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL,
    waiting_tasks_count bigint NOT NULL,
    wait_time_ms        bigint NOT NULL,
    signal_wait_time_ms bigint NOT NULL
);
INSERT INTO #wait_current (wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms)
SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
FROM sys.dm_os_wait_stats;

DECLARE @reset bit = CASE
    WHEN (SELECT SUM(CONVERT(decimal(38, 0), wait_time_ms)) FROM #wait_current)
       < (SELECT SUM(CONVERT(decimal(38, 0), wait_time_ms)) FROM #wait_snapshot)
    THEN 1 ELSE 0 END;

IF @reset = 0
BEGIN
    ;WITH delta AS (
        SELECT
            cur.wait_type,
            cur.waiting_tasks_count - ISNULL(snap.waiting_tasks_count, 0) AS waits_delta,
            cur.wait_time_ms - ISNULL(snap.wait_time_ms, 0) AS wait_ms_delta,
            cur.signal_wait_time_ms - ISNULL(snap.signal_wait_time_ms, 0) AS signal_ms_delta
        FROM #wait_current AS cur
        LEFT JOIN #wait_snapshot AS snap
            ON snap.wait_type COLLATE DATABASE_DEFAULT = cur.wait_type
        WHERE cur.wait_type NOT IN (
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
    )
    SELECT TOP (15)
        wait_type,
        waits_delta                                            AS 増えた回数,
        wait_ms_delta                                          AS 増えた待ち時間ms,
        CASE WHEN wait_ms_delta >= signal_ms_delta
             THEN wait_ms_delta - signal_ms_delta ELSE 0 END       AS うち相手媒体待ちms,
        signal_ms_delta                                        AS うちCPU待ちms,
        CASE
            WHEN wait_type LIKE 'PAGEIOLATCH%' THEN N'I/O待ち（ディスク読み書き）'
            WHEN wait_type LIKE 'LCK%'         THEN N'ロック待ち'
            WHEN wait_type LIKE 'PAGELATCH%' OR wait_type LIKE 'LATCH%'
                                               THEN N'ラッチ競合（ページの取り合い。tempdb 等）'
            WHEN wait_type IN ('CXPACKET', 'CXCONSUMER') OR wait_type LIKE 'EXCHANGE%'
                                               THEN N'並列処理の待ち'
            WHEN wait_type = 'SOS_SCHEDULER_YIELD'
                                               THEN N'CPU待ち（実行キューの混雑）'
            WHEN wait_type = 'WRITELOG' OR wait_type LIKE 'LOGBUFFER%'
                                               THEN N'トランザクションログの書き込み待ち'
            WHEN wait_type LIKE 'RESOURCE_SEMAPHORE%'
                                               THEN N'メモリ割り当て待ち'
            WHEN wait_type = 'ASYNC_NETWORK_IO' THEN N'結果送信の待ち（受け側が遅い）'
            ELSE N'その他'
        END                                                    AS 意味
    FROM delta
    WHERE wait_ms_delta > 0
    ORDER BY wait_ms_delta DESC;
END;

-- 入れ替えに失敗した場合は、直前の基準を保つ。
DECLARE @outer_tran int = @@TRANCOUNT;
IF @outer_tran = 0
    BEGIN TRANSACTION;
ELSE
    SAVE TRANSACTION wait_snapshot_update;

BEGIN TRY
    DELETE FROM #wait_snapshot;
    INSERT INTO #wait_snapshot (wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms)
    SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
    FROM #wait_current;

    IF @outer_tran = 0
        COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @outer_tran = 0 AND XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    ELSE IF @outer_tran > 0 AND XACT_STATE() = 1
        ROLLBACK TRANSACTION wait_snapshot_update;
    THROW;
END CATCH;

DROP TABLE #wait_current;
SELECT CASE WHEN @reset = 1
    THEN N'待機統計がリセットされたと判断しました。差分の表示を省き、今回値を新しい基準にしました。'
    ELSE N'基準を更新しました。次回も前回の実行からの増分が出ます。片付けるには DROP TABLE #wait_snapshot を実行します。'
END AS 案内;

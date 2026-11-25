/*
  12-wait-stats-diff.sql
  待機統計の「差分」を見る。調査の入口。

  仕組み：
    dm_os_wait_stats はインスタンス起動からの累積なので、そのままでは
    「いつ・何待ちで時間を食ったか」が分からない。このファイルは
    1回目の実行で現在値を記録し、2回目以降の実行で「前回からの増分」
    だけを出す。バッチの実行前と実行後に挟む、障害の前後で挟む、など
    「見たい時間帯」を挟んで使う。

  使い方：
    同じセッション（同じクエリウィンドウ）で2回実行する。
    1回目 …「記録した」という案内だけが返る
    2回目 … 増分の上位15件（待ちの種類・増えた時間・意味）と、
             スナップショット更新の案内が返る
    3回目以降は、2回目からの増分になる。

  temp テーブルについて：
    差分を取るため、このファイルだけは #wait_snapshot を
    セッションに残す設計（セッションを閉じれば自動で消える）。
    手動で片付ける場合は DROP TABLE #wait_snapshot を実行する。

  注意：
    - 2回の実行の間にインスタンスが再起動すると累積値が巻き戻る。
      その場合は「現在値そのもの」を増分として扱う。
    - 意味のない待機（アイドル系）は集計から除いてある。
    - 増分の見方：wait_time の大半が signal（CPU に空きがなく待った分）
      なら CPU 側、resource（wait_time − signal）が大半なら
      ロックや I/O など「相手・媒体待ち」側。
*/

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#wait_snapshot') IS NULL
BEGIN
    SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
    INTO #wait_snapshot
    FROM sys.dm_os_wait_stats;

    SELECT N'1回目：現在の待機統計を記録した。調査したい時間帯の後にもう一度、同じセッションで実行すると、その間の増分が出る' AS 案内;
END
ELSE
BEGIN
    -- 増分（再起動で巻き戻った列は現在値を増分とみなす）
    ;WITH delta AS (
        SELECT
            cur.wait_type,
            CASE WHEN cur.waiting_tasks_count < snap.waiting_tasks_count
                 THEN cur.waiting_tasks_count
                 ELSE cur.waiting_tasks_count - snap.waiting_tasks_count END AS waits_delta,
            CASE WHEN cur.wait_time_ms < snap.wait_time_ms
                 THEN cur.wait_time_ms
                 ELSE cur.wait_time_ms - snap.wait_time_ms END AS wait_ms_delta,
            CASE WHEN cur.signal_wait_time_ms < snap.signal_wait_time_ms
                 THEN cur.signal_wait_time_ms
                 ELSE cur.signal_wait_time_ms - snap.signal_wait_time_ms END AS signal_ms_delta
        FROM sys.dm_os_wait_stats AS cur
        INNER JOIN #wait_snapshot AS snap
            ON snap.wait_type = cur.wait_type
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
        wait_ms_delta - signal_ms_delta                        AS うち相手媒体待ちms,
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

    -- スナップショットを現在値に更新する（次回はここからの増分）
    DROP TABLE #wait_snapshot;
    SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
    INTO #wait_snapshot
    FROM sys.dm_os_wait_stats;

    SELECT N'スナップショットを更新した。次に実行すると、ここからの増分が出る（増分が無ければ結果は空）。片付ける場合は DROP TABLE #wait_snapshot' AS 案内;
END;

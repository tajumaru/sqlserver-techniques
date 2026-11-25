-- デッドロックグラフの要約（05 の XML を読める形にばらす）
--
-- 使い方:
--   そのまま実行すると3つの結果が返る。
--     結果1: デッドロックの一覧（発生時刻・全犠牲プロセスのカンマ区切り）
--     結果2: プロセスの一覧（どの業務が・何の SQL で・何を待ったか）
--     結果3: リソースの一覧（どのオブジェクト／インデックスで
--            誰が掴み、誰が待ったか）← 調査の中心はここ
--
-- 外部共有時は、結果2 の inputbuf（SQL 文面）・ログイン名・アプリ名を伏せること。
-- STRING_AGG を使うため SQL Server 2017 以降が必要。
--
-- 読み方:
--   - 結果3 の index_name が主キーなら「主キー上での衝突」、
--     非クラスタ化インデックスの名前なら「そのインデックスが合流点」。
--   - resource_type が KEY か PAGE かでも型が分かれる
--     （KEY = 行キー、PAGE = ページ、OBJECT = オブジェクト）。
--     その他は XML の要素名。所有者・待機者は全員を id(mode) で表示する。
--   - 結果2 の client_app / login_name で、どの業務のプロセスか
--     特定する。inputbuf は各プロセスの入力バッチの先頭1,000文字。
--
-- 注意:
--   - 時刻は UTC が正本。occurred_at_jst は +9 時間した参考値。
--   - 05 と同じ system_health の ring_buffer を、このクエリの実行時に読み直す。
--     古いものから消え、XML 変換上限（4 MB）でも欠落し得る。

IF OBJECT_ID('tempdb..#dl') IS NOT NULL DROP TABLE #dl;
CREATE TABLE #dl (
    deadlock_no  int IDENTITY(1,1),
    occurred_at  datetime2,
    graph        xml,
    victims      varchar(max)
);

;WITH events AS (
    SELECT x.value('@timestamp', 'datetime2') AS event_time, x.query('.') AS graph
    FROM (
        SELECT CAST(st.target_data AS XML) AS target_data
        FROM sys.dm_xe_session_targets AS st
        INNER JOIN sys.dm_xe_sessions AS s
            ON s.address = st.event_session_address
        WHERE s.name = 'system_health'
          AND st.target_name = 'ring_buffer'
    ) AS d
    CROSS APPLY d.target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS t(x)
), details AS (
    SELECT e.event_time, e.graph, v.victims
    FROM events AS e
    OUTER APPLY (
        SELECT STRING_AGG(ids.process_id, ',') AS victims
        FROM e.graph.nodes('event/data/value/deadlock/victim-list/deadlockProcess') AS t(p)
        CROSS APPLY (VALUES (p.value('@id', 'varchar(max)'))) AS ids(process_id)
    ) AS v
)
INSERT INTO #dl (graph, victims, occurred_at)
SELECT graph, victims,
       event_time AS occurred_at FROM details
ORDER BY occurred_at;

-- 結果1: デッドロックの一覧
SELECT
    d.deadlock_no,
    d.occurred_at,
    DATEADD(HOUR, 9, d.occurred_at) AS occurred_at_jst,
    d.victims AS victim_process
FROM #dl AS d
ORDER BY d.occurred_at DESC, d.deadlock_no DESC;

-- 結果2: プロセスの一覧
SELECT
    d.deadlock_no,
    p.value('@id', 'varchar(50)')            AS process_id,
    CASE WHEN CHARINDEX(',' + p.value('@id', 'varchar(50)') + ',', ',' + d.victims + ',') > 0
         THEN N'犠牲' ELSE N'' END           AS victim,
    p.value('@clientapp', 'nvarchar(128)')   AS client_app,
    p.value('@loginname', 'nvarchar(128)')   AS login_name,
    p.value('@isolationlevel', 'varchar(50)') AS isolation_level,
    p.value('@waitresource', 'varchar(256)') AS wait_resource,
    LEFT(p.value('(inputbuf/text())[1]', 'nvarchar(4000)'), 1000) AS inputbuf
FROM #dl AS d
CROSS APPLY d.graph.nodes('event/data/value/deadlock/process-list/process') AS t(p)
ORDER BY d.occurred_at DESC, d.deadlock_no DESC, process_id;

-- 結果3: リソースの一覧（合流点の特定）
SELECT
    d.deadlock_no,
    CASE r.value('local-name(.)', 'varchar(30)')
        WHEN 'keylock' THEN 'KEY'
        WHEN 'pagelock' THEN 'PAGE'
        WHEN 'objectlock' THEN 'OBJECT'
        ELSE r.value('local-name(.)', 'varchar(30)')
    END AS resource_type,
    r.value('@objectname', 'nvarchar(512)') AS object_name,
    r.value('@indexname', 'sysname') AS index_name,
    owners.owner_process,
    waiters.waiter_process
FROM #dl AS d
CROSS APPLY d.graph.nodes('event/data/value/deadlock/resource-list/*') AS t(r)
OUTER APPLY (
    SELECT STRING_AGG(CONCAT(parts.process_id, '(', parts.lock_mode, ')'), ',') AS owner_process
    FROM r.nodes('owner-list/owner') AS o(p)
    CROSS APPLY (VALUES (p.value('@id', 'varchar(max)'), p.value('@mode', 'varchar(20)')))
        AS parts(process_id, lock_mode)
) AS owners
OUTER APPLY (
    SELECT STRING_AGG(CONCAT(parts.process_id, '(', parts.lock_mode, ')'), ',') AS waiter_process
    FROM r.nodes('waiter-list/waiter') AS w(p)
    CROSS APPLY (VALUES (p.value('@id', 'varchar(max)'), p.value('@mode', 'varchar(20)')))
        AS parts(process_id, lock_mode)
) AS waiters
ORDER BY d.occurred_at DESC, d.deadlock_no DESC, resource_type, index_name;

-- 後片付け（同じセッションで再実行しても残らないように）
DROP TABLE #dl;

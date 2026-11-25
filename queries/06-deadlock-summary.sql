-- デッドロックグラフの要約（05 の XML を読める形にばらす）
--
-- 使い方:
--   そのまま実行すると3つの結果が返る。
--     結果1: デッドロックの一覧（発生時刻・犠牲になったプロセス）
--     結果2: プロセスの一覧（どの業務が・何の SQL で・何を待ったか）
--     結果3: リソースの一覧（どのオブジェクト／インデックスで
--            誰が掴み、誰が待ったか）← 調査の中心はここ
--
-- 読み方:
--   - 結果3 の indexname が主キーなら「主キー上での衝突」、
--     非クラスタ化インデックスの名前なら「そのインデックスが合流点」。
--   - resource_type が KEY か PAGE かでも型が分かれる
--     （KEY = 行キー同士、PAGE = ページ単位のぶつかり）。
--   - 結果2 の client_app / login_name で、どの業務のプロセスか
--     特定する。inputbuf が各プロセスの実行中 SQL。
--
-- 注意:
--   - 時刻は UTC が正本。occurred_at_jst は +9 時間した参考値。
--   - 元データは 05 と同じ system_health の ring_buffer。
--     古いものから消える点も同じ。

IF OBJECT_ID('tempdb..#dl') IS NOT NULL DROP TABLE #dl;
CREATE TABLE #dl (
    deadlock_no  int IDENTITY(1,1),
    occurred_at  datetime2,
    graph        xml
);

INSERT INTO #dl (occurred_at, graph)
SELECT
    x.value('@timestamp', 'datetime2'),
    x.query('.')
FROM (
    SELECT CAST(st.target_data AS XML) AS target_data
    FROM sys.dm_xe_session_targets AS st
    INNER JOIN sys.dm_xe_sessions AS s
        ON s.address = st.event_session_address
    WHERE s.name = 'system_health'
      AND st.target_name = 'ring_buffer'
) AS d
CROSS APPLY d.target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS t(x)
ORDER BY occurred_at;

-- 結果1: デッドロックの一覧
SELECT
    d.deadlock_no,
    d.occurred_at,
    DATEADD(HOUR, 9, d.occurred_at) AS occurred_at_jst,
    d.graph.value('(event/data/value/deadlock/victim-list/deadlockProcess/@id)[1]', 'varchar(50)') AS victim_process
FROM #dl AS d
ORDER BY d.deadlock_no DESC;

-- 結果2: プロセスの一覧
SELECT
    d.deadlock_no,
    p.value('@id', 'varchar(50)')            AS process_id,
    CASE WHEN p.value('@id', 'varchar(50)')
              = d.graph.value('(event/data/value/deadlock/victim-list/deadlockProcess/@id)[1]', 'varchar(50)')
         THEN N'犠牲' ELSE N'' END           AS victim,
    p.value('@clientapp', 'nvarchar(128)')   AS client_app,
    p.value('@loginname', 'nvarchar(128)')   AS login_name,
    p.value('@isolationlevel', 'varchar(50)') AS isolation_level,
    p.value('@waitresource', 'varchar(256)') AS wait_resource,
    LEFT(p.value('(inputbuf/text())[1]', 'nvarchar(4000)'), 1000) AS inputbuf
FROM #dl AS d
CROSS APPLY d.graph.nodes('event/data/value/deadlock/process-list/process') AS t(p)
ORDER BY d.deadlock_no DESC, process_id;

-- 結果3: リソースの一覧（合流点の特定）
SELECT
    d.deadlock_no,
    r.value('local-name(.)', 'varchar(30)')        AS resource_type,
    r.value('@objectname', 'nvarchar(512)')        AS object_name,
    r.value('@indexname', 'sysname')               AS index_name,
    r.value('(owner-list/owner/@id)[1]', 'varchar(50)')   AS owner_process,
    r.value('(owner-list/owner/@mode)[1]', 'varchar(20)') AS owner_mode,
    r.value('(waiter-list/waiter/@id)[1]', 'varchar(50)')   AS waiter_process,
    r.value('(waiter-list/waiter/@mode)[1]', 'varchar(20)') AS waiter_mode
FROM #dl AS d
CROSS APPLY d.graph.nodes('event/data/value/deadlock/resource-list/*') AS t(r)
ORDER BY d.deadlock_no DESC, resource_type, index_name;

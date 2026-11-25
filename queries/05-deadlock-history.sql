-- デッドロック履歴の取得（system_health 拡張イベントから）
--
-- 使い方:
--   そのまま実行すると、記録が残っている直近のデッドロックが
--   発生日時の新しい順に返る。deadlock_graph はイベント全体の XML。
--   グラフ本体は event/data/value/deadlock の内側にある。
--
-- 外部共有時は、XML 内の SQL 文面・ログイン名・アプリ名を伏せること。
--
-- 注意:
--   - system_health は SQL Server の既定で動いている拡張イベント
--     セッション。デッドロックは xml_deadlock_report として
--     自動で記録される（追加の設定は不要）。
--   - ring_buffer は容量が小さく、古いものから消える。XML への変換上限（4 MB）でも欠落し得る。
--     発生に気づいたら早めに抜いて保存すること。
--   - もっと長く残したい場合は event_file 側を見るか、
--     専用の拡張イベントセッションを別途用意する。
--
-- 読み解きの要点（deadlock_graph の中身）:
--   - victim-list        : 犠牲になったプロセス（ロールバックされた側）
--   - process-list       : 各プロセスの実行中 SQL（inputbuf）、
--                          待っているリソース（waitresource）
--   - resource-list      : ロックの対象（objectname / indexname）と
--                          所有・待機の関係（owner-list / waiter-list）
--   見る順番は「どのオブジェクト・インデックスで」「どの SQL 同士が」
--   「どのリソースを持ち、何を待ったか」。取得順や原因は他の観測と合わせて調べる。

SELECT
    x.value('@timestamp', 'datetime2') AS occurred_at,
    x.query('.')                       AS deadlock_graph
FROM (
    SELECT CAST(st.target_data AS XML) AS target_data
    FROM sys.dm_xe_session_targets AS st
    INNER JOIN sys.dm_xe_sessions AS s
        ON s.address = st.event_session_address
    WHERE s.name = 'system_health'
      AND st.target_name = 'ring_buffer'
) AS d
CROSS APPLY d.target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS t(x)
ORDER BY occurred_at DESC;

-- 02: 暗黙の型変換（Seek を殺す犯人）をプランXMLから拾う
-- ConvertIssue = 'Seek Plan' が出たら、変換が列側にかかって Seek が落ちている。
-- 典型例: varchar 列に対して nvarchar パラメータで比較している（アプリ側の型指定が原因）。

DECLARE @plan XML = N'ここにプランXML';

;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
conv AS (
    SELECT c.value('@ConvertIssue','nvarchar(60)')  AS Issue,
           c.value('@Expression','nvarchar(1000)')  AS Expression
    FROM @plan.nodes('//PlanAffectingConvert') AS q(c)
    UNION ALL
    SELECT 'Convert', c.value('@Expression','nvarchar(1000)')
    FROM @plan.nodes('//Convert') AS q(c)
)
SELECT * FROM conv;

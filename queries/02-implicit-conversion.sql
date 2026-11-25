-- 02: 暗黙の型変換の手がかりをプランXMLから拾う
-- Issue が 'Seek Plan' なら、変換がシークに影響する可能性を示す警告。
-- 'Convert（参考）' は全 Convert の一覧。暗黙かどうかは式の確認が要る。
-- 典型例: varchar 列に対して nvarchar パラメータで比較している（アプリ側の型指定が原因）。

DECLARE @plan XML = NULL;  -- NULL を N'プラン XML' に置き換える
IF @plan IS NULL
BEGIN
    SELECT N'@plan にプラン XML を貼り付けてから実行してください。' AS 案内;
    RETURN;
END;

;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
conv AS (
    SELECT c.value('@ConvertIssue','nvarchar(60)')  AS Issue,
           c.value('@Expression','nvarchar(1000)')  AS Expression
    FROM @plan.nodes('//PlanAffectingConvert') AS q(c)
    UNION ALL
    SELECT N'Convert（参考）', c.value('@Expression','nvarchar(1000)')
    FROM @plan.nodes('//Convert') AS q(c)
)
SELECT * FROM conv;

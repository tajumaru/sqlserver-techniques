-- 01: プランXMLから Seek / Scan / Lookup のオペレーターを一覧化する
-- 使い方: SSMS のプランを右クリック →「実行プラン XML の表示」でコピーし、
--         @plan に貼る。プランキャッシュから取る場合は 03 の query_plan 列を代入する。
-- Lookup は PhysicalOp に現れない場合がある。Scan でも全行を読むとは限らない。

DECLARE @plan XML = NULL;  -- NULL を N'プラン XML' に置き換える
IF @plan IS NULL
BEGIN
    SELECT N'@plan にプラン XML を貼り付けてから実行してください。' AS 案内;
    RETURN;
END;

;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT
    RelOp.value('@NodeId','int')              AS NodeId,
    RelOp.value('@PhysicalOp','nvarchar(60)') AS Operator,   -- Seek / Scan / Lookup を見る
    RelOp.value('@EstimateRows','float')      AS EstRows,
    Obj.value('@Table','nvarchar(128)')       AS TableName,
    Obj.value('@Index','nvarchar(128)')       AS IndexName
FROM @plan.nodes('//RelOp') AS q(RelOp)
OUTER APPLY RelOp.nodes('*/Object') AS o(Obj)
WHERE RelOp.value('@PhysicalOp','nvarchar(60)') LIKE '%Seek%'
   OR RelOp.value('@PhysicalOp','nvarchar(60)') LIKE '%Scan%'
   OR RelOp.value('@PhysicalOp','nvarchar(60)') LIKE '%Lookup%';

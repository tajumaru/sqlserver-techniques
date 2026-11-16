-- 01: プランXMLから Seek / Scan / Lookup のオペレーターを一覧化する
-- 使い方: SSMS のプランを右クリック →「実行プラン XML の表示」でコピーし、
--         @plan に貼る。プランキャッシュから取る場合は 03 の query_plan 列を代入する。

DECLARE @plan XML = N'ここにプランXML';

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

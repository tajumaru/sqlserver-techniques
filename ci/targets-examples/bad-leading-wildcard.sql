-- 不合格例（わざと）: 前方ワイルドカード LIKE は Seek できず Index Scan になる。
-- ci/targets/ にコピーしてワークフローを回すと、チェックが失敗することを確認できる。
SELECT CustomerId, Email
FROM dbo.Customers
WHERE Email LIKE '%12345%';

-- 合格例: Email の等値検索は IX_Customers_Email の Index Seek になる
SELECT CustomerId, Email
FROM dbo.Customers
WHERE Email = 'user12345@example.com';

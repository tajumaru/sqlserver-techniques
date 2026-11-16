-- サンプル用スキーマとデータ（GitHub Actions のデモで使う）
-- Email の一意インデックスに対して Seek になるクエリと、
-- 前方ワイルドカードで Scan になるクエリを再現するための最小構成。

CREATE TABLE dbo.Customers (
    CustomerId int IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED,
    Email      nvarchar(256) NOT NULL,
    Name       nvarchar(100) NOT NULL,
    CreatedAt  datetime2 NOT NULL DEFAULT sysdatetime()
);
GO

CREATE UNIQUE NONCLUSTERED INDEX IX_Customers_Email
    ON dbo.Customers (Email);
GO

INSERT INTO dbo.Customers (Email, Name)
SELECT TOP 20000
       'user' + CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS varchar(10)) + '@example.com',
       'User ' + CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS varchar(10))
FROM sys.all_objects a
CROSS JOIN sys.all_objects b;
GO

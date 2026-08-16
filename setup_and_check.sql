-- =============================================
-- 通用高风险分录(HRC)筛查 - 建表、索引与环境检查
-- 适用于标准 SQL Server（无需任何客户特定对象）
-- 注意：路径均使用相对/注释形式，不硬编码绝对路径
-- =============================================

PRINT '===========================================';
PRINT '1. SQL Server 环境检查';
PRINT '===========================================';
SELECT
    @@VERSION      AS sql_version,
    @@SERVERNAME   AS server_name,
    DB_NAME()      AS current_database;
GO

-- =============================================
-- 2. 创建通用日记账分录表 dbo.journal_entries
--    （若已存在则跳过；可按需改为 DROP/CREATE）
-- =============================================
IF OBJECT_ID('dbo.journal_entries', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.journal_entries (
        voucher_no      VARCHAR(50)    NOT NULL,  -- 会计凭证号码
        company_code    VARCHAR(10)    NOT NULL,  -- 公司代码（通用占位 C001..C00N）
        dr_cr_indicator CHAR(1)        NOT NULL,  -- 借贷标识 H=贷方, S=借方
        gl_account      VARCHAR(20)    NOT NULL,  -- 总账科目代码
        account_desc    NVARCHAR(200)  NULL,      -- 科目描述
        username        VARCHAR(50)    NULL,      -- 创建人用户名
        voucher_date    DATE           NULL,      -- 凭证日期
        item_text       NVARCHAR(500)  NULL,      -- 项目文本/分录描述
        amount          DECIMAL(18,2)  NULL,      -- 按本位币计的金额
        customer_no     VARCHAR(50)    NULL,      -- 客户/客商编号
        customer_name   NVARCHAR(200)  NULL,      -- 客户/客商名称
        fiscal_period   INT            NULL,      -- 会计期间 1-12
        voucher_status  CHAR(1)        NULL,      -- 凭证状态 D=已删除
        CONSTRAINT PK_journal_entries PRIMARY KEY (company_code, voucher_no, gl_account)
    );
    PRINT '   ✓ 已创建表 dbo.journal_entries';
END
ELSE
    PRINT '   • 表 dbo.journal_entries 已存在，跳过创建';
GO

-- =============================================
-- 3. 创建索引（提升筛查性能；已存在则跳过）
-- =============================================
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'idx_je_company' AND object_id = OBJECT_ID('dbo.journal_entries'))
    CREATE INDEX idx_je_company ON dbo.journal_entries(company_code);
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'idx_je_voucher' AND object_id = OBJECT_ID('dbo.journal_entries'))
    CREATE INDEX idx_je_voucher ON dbo.journal_entries(voucher_no);
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'idx_je_period' AND object_id = OBJECT_ID('dbo.journal_entries'))
    CREATE INDEX idx_je_period ON dbo.journal_entries(fiscal_period, company_code);
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'idx_je_user' AND object_id = OBJECT_ID('dbo.journal_entries'))
    CREATE INDEX idx_je_user ON dbo.journal_entries(username);
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'idx_je_account' AND object_id = OBJECT_ID('dbo.journal_entries'))
    CREATE INDEX idx_je_account ON dbo.journal_entries(gl_account);
PRINT '===========================================';
PRINT '   ✓ 索引检查/创建完成';
PRINT '===========================================';
GO

-- =============================================
-- 4. 数据就绪检查（可选）
-- =============================================
DECLARE @row_count INT = 0;
SELECT @row_count = COUNT(*) FROM dbo.journal_entries;
PRINT '   dbo.journal_entries 当前记录数: ' + CAST(@row_count AS VARCHAR);
IF @row_count = 0
    PRINT '   • 尚未导入数据；可先运行 examples.sql 插入合成示例数据自测。';
ELSE
    PRINT '   ✓ 已存在数据，可直接运行 hrc_screening.sql。';
GO

-- 导出建议（相对路径/注释形式，避免硬编码绝对路径）：
--   bcp "SELECT * FROM dbo.journal_entries" queryout ".\output\hrc_export.csv" -c -t, -S localhost -d <DB> -T
--   或使用 SSIS / OPENROWSET 写入 Excel。

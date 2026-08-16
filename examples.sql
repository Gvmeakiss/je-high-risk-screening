-- =============================================
-- 合成示例数据（自测用，无任何客户信息）
-- 5 家通用公司 C001..C005，覆盖 HRC1/HRC2/HRC3 各类命中与反例
-- 运行顺序：setup_and_check.sql -> 本文件 -> hrc_screening.sql
-- =============================================

-- 清空后插入（便于重复自测）
DELETE FROM dbo.journal_entries;
GO

-- ----------------------------------------------------------
-- C001：含 HRC1.1、HRC1.2 命中，以及一条「收入+对应资产」正常凭证
-- ----------------------------------------------------------
-- HRC1.1 命中：贷方收入 + 批处理用户
INSERT INTO dbo.journal_entries (voucher_no, company_code, dr_cr_indicator, gl_account, account_desc, username, voucher_date, item_text, amount, customer_no, fiscal_period, voucher_status) VALUES
('V101', 'C001', 'H', '6001', N'主营业务收入', 'WF-BATCH', '2025-11-05', N'月末收入结转', 120000.00, 'CUST01', 11, ''),
-- HRC1.1 命中：贷方收入 + 纯数字用户
('V102', 'C001', 'H', '6002', N'其他业务收入', '0001234',  '2025-11-20', N'调整收入',    88000.00, 'CUST02', 11, ''),
-- HRC1.2 命中：借方生产成本 + 人为操作
('V103', 'C001', 'S', '5001', N'生产成本',     '0002222',  '2025-12-10', N'人为操作调整', 45000.00, 'CUST03', 12, ''),
-- 正常凭证（不应被 HRC2.1 命中）：收入 + 对应应收账款
('V104', 'C001', 'H', '6001', N'主营业务收入', '0001234',  '2025-12-15', N'销售确认',     60000.00, 'CUST04', 12, ''),
('V104', 'C001', 'S', '1122', N'应收账款',     '0001234',  '2025-12-15', N'销售确认',     60000.00, 'CUST04', 12, ''),
-- 反例（不应被 HRC1.1 命中）：贷方收入但为字母用户名（非手工特征）
('V105', 'C001', 'H', '6001', N'主营业务收入', 'AUDIT01',  '2025-11-30', N'审计调整',     20000.00, 'CUST05', 11, '');

-- ----------------------------------------------------------
-- C002：含 HRC2.1 命中（收入贷记但无对应资产）
-- ----------------------------------------------------------
INSERT INTO dbo.journal_entries (voucher_no, company_code, dr_cr_indicator, gl_account, account_desc, username, voucher_date, item_text, amount, customer_no, fiscal_period, voucher_status) VALUES
('V201', 'C002', 'H', '6001', N'主营业务收入', '0003333', '2025-10-08', N'无对应资产收入', 75000.00, 'CUST06', 10, '');

-- ----------------------------------------------------------
-- C003：含 HRC2.2 命中（利息收入贷记但无对应资产）
-- ----------------------------------------------------------
INSERT INTO dbo.journal_entries (voucher_no, company_code, dr_cr_indicator, gl_account, account_desc, username, voucher_date, item_text, amount, customer_no, fiscal_period, voucher_status) VALUES
('V301', 'C003', 'H', '660302', N'利息收入', '0004444', '2025-12-22', N'利息入账', 15000.00, 'CUST07', 12, '');

-- ----------------------------------------------------------
-- C004：含 HRC3 命中（关键人员名单 U0001/U0002 编制）
-- ----------------------------------------------------------
INSERT INTO dbo.journal_entries (voucher_no, company_code, dr_cr_indicator, gl_account, account_desc, username, voucher_date, item_text, amount, customer_no, fiscal_period, voucher_status) VALUES
('V401', 'C004', 'S', '1001', N'库存现金',   'U0001', '2025-11-11', N'备用金',   5000.00,  '', 11, ''),
('V402', 'C004', 'H', '6001', N'主营业务收入', 'U0002', '2025-12-01', N'收入',  30000.00, 'CUST08', 12, '');

-- ----------------------------------------------------------
-- C005：干净公司，仅含正常「收入+对应资产」凭证（验证无误报）
-- ----------------------------------------------------------
INSERT INTO dbo.journal_entries (voucher_no, company_code, dr_cr_indicator, gl_account, account_desc, username, voucher_date, item_text, amount, customer_no, fiscal_period, voucher_status) VALUES
('V501', 'C005', 'H', '6001', N'主营业务收入', '0005555', '2025-10-15', N'销售',    90000.00, 'CUST09', 10, ''),
('V501', 'C005', 'S', '1122', N'应收账款',     '0005555', '2025-10-15', N'销售',    90000.00, 'CUST09', 10, '');

-- ----------------------------------------------------------
-- 自测预期（执行 hrc_screening.sql 后）：
--   HRC1.1 (贷方收入+手工特征):
--      C001 -> V101, V102, V104        (V105 字母用户名不命中)
--      C002 -> V201                    (V201 也为数字用户名贷方收入)
--      C005 -> V501
--   HRC1.2 (借方生产成本+人为操作):
--      C001 -> V103
--   HRC2.1 (收入贷记但无对应资产):
--      C001 -> V101, V102, V105        (V104 因有 1122 对应资产不命中)
--      C002 -> V201
--      C004 -> V402
--   HRC2.2 (利息收入贷记但无对应资产):
--      C003 -> V301
--   HRC3  (关键人员名单 U0001/U0002):
--      C004 -> V401, V402
--   反例验证：V104/V501 有对应资产 -> HRC2.1 不命中；V105 字母用户名 -> HRC1.1 不命中
-- ----------------------------------------------------------
SELECT '示例数据插入完成，共 ' + CAST(COUNT(*) AS VARCHAR) + ' 行。' AS msg FROM dbo.journal_entries;
GO

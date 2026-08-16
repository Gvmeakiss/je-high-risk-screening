-- =============================================
-- 通用高风险分录(HRC)筛查模板  -  主脚本
-- 整合 Simple / Complete / SQL 三版方法论为一份
-- 参数化、可配置、已脱敏的 T-SQL 脚本
-- 目标表: dbo.journal_entries
-- 适用于标准 SQL Server，可直接在合成数据上运行
-- =============================================
-- 使用顺序：
--   1) setup_and_check.sql   (建表+索引)
--   2) examples.sql          (可选，插入合成数据自测)
--   3) 本脚本 hrc_screening.sql
-- =============================================

-- =============================================
-- 配置区（用户须按自身环境填写，已全部脱敏为占位）
-- 原脚本中「按公司代码的特殊排除规则」已改写为下方可配置列表变量，
-- 不再硬编码任何客户特定的公司代码或内部科目。
-- =============================================

-- 0) 筛查期间（会计期间下限；原脚本为 10-12 月）
DECLARE @start_period INT = 10;   -- 仅筛查 fiscal_period >= @start_period 的分录

-- 1) 待筛查公司清单（示例占位 C001..C005，请替换为实际公司代码）
DECLARE @company_list TABLE (company_code VARCHAR(10));
INSERT INTO @company_list VALUES ('C001'),('C002'),('C003'),('C004'),('C005');

-- 2) 跳过筛查的公司清单
DECLARE @skip_list TABLE (company_code VARCHAR(10));
-- INSERT INTO @skip_list VALUES ('C009');

-- 3) 可配置排除列表（演示「按公司特殊排除规则」的参数化；原脚本曾硬编码若干特定公司代码，此处改为可配置）
-- 3a) 用户账号以 E 或 B 开头即排除的公司（示例占位，按实际组织口径填写）
DECLARE @exclude_username_eb TABLE (company_code VARCHAR(10));
-- INSERT INTO @exclude_username_eb VALUES ('C002');

-- 3b) 剔除科目描述含「集团内往来」类关键词的公司（原针对特定公司，示例占位）
DECLARE @exclude_group_internal TABLE (company_code VARCHAR(10));
-- INSERT INTO @exclude_group_internal VALUES ('C003');
-- 集团内往来关键词（示例占位；按实际科目描述口径配置）
DECLARE @interco_keywords TABLE (kw NVARCHAR(50));
INSERT INTO @interco_keywords VALUES (N'%集团内%'), (N'%集团往来%'), (N'%内部往来%');

-- 3c) 利息收入筛查中，额外将「长期应收款类」科目视为对应资产的公司（原针对特定公司）
--     用通用占位科目前缀 1999 示意（代表长期应收款类，非真实科目，请按实际科目表替换）
DECLARE @include_long_term_receivable TABLE (company_code VARCHAR(10));
-- INSERT INTO @include_long_term_receivable VALUES ('C001');

-- 3d) 利息收入筛查中，将「利息收入本身」也视为对应资产的公司（原针对特定公司）
DECLARE @interest_self_offset TABLE (company_code VARCHAR(10));
-- INSERT INTO @interest_self_offset VALUES ('C004');

-- 4) 关键人员（如业务总监）名单（示例占位，请替换为实际用户名）
DECLARE @key_user_list TABLE (username VARCHAR(50));
INSERT INTO @key_user_list VALUES ('U0001'),('U0002'),('U0003');

-- 5) 科目前缀参数（通用示例；SAP 标准科目区间示意，可按科目表调整）
DECLARE @rev_prefix        CHAR(2)  = '60';      -- 收入科目前缀
DECLARE @cost_prefix       CHAR(5)  = '5001';    -- 生产成本科目前缀
DECLARE @interest_prefix   CHAR(6)  = '660302';  -- 利息收入科目前缀
DECLARE @lt_recv_prefix    CHAR(4)  = '1999';    -- 长期应收款类（通用占位示例，非真实科目，请按实际科目表调整）
DECLARE @cash_bank_prefix  CHAR(2)  = '10';      -- 现金/银行存款科目前缀

-- 对应资产/债权类科目前缀集合（应收、预收、应收票据、职工薪酬等）
DECLARE @asset_prefixes TABLE (p VARCHAR(4));
INSERT INTO @asset_prefixes VALUES ('1122'),('2203'),('1121'),('2211');

-- =============================================
-- 结果临时表
-- =============================================
IF OBJECT_ID('tempdb..#HRC_Summary') IS NOT NULL DROP TABLE #HRC_Summary;
CREATE TABLE #HRC_Summary (
    company_code  VARCHAR(10),
    hrc1_1_desc   NVARCHAR(500),
    hrc1_2_desc   NVARCHAR(500),
    hrc2_1_desc   NVARCHAR(500),
    hrc2_2_desc   NVARCHAR(500),
    hrc3_desc     NVARCHAR(500)
);

IF OBJECT_ID('tempdb..#HRC_Detail') IS NOT NULL DROP TABLE #HRC_Detail;
CREATE TABLE #HRC_Detail (
    hrc_type     VARCHAR(10),
    company_code VARCHAR(10),
    voucher_no   VARCHAR(50)
);

-- =============================================
-- 主循环：逐公司应用 HRC1 / HRC2 / HRC3
-- （逐公司便于套用「按公司特殊规则」；
--  若所有公司规则一致，可改写为集合式查询以提升并行性能）
-- =============================================
DECLARE @co VARCHAR(10);
DECLARE co_cursor CURSOR FOR
    SELECT company_code FROM @company_list
    WHERE company_code NOT IN (SELECT company_code FROM @skip_list);

OPEN co_cursor;
FETCH NEXT FROM co_cursor INTO @co;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT 'Processing company: ' + ISNULL(@co, '');

    -- 公司级开关（由可配置列表推导）
    DECLARE @eb_excl      BIT = CASE WHEN EXISTS (SELECT 1 FROM @exclude_username_eb      WHERE company_code = @co) THEN 1 ELSE 0 END;
    DECLARE @grp_excl     BIT = CASE WHEN EXISTS (SELECT 1 FROM @exclude_group_internal   WHERE company_code = @co) THEN 1 ELSE 0 END;
    DECLARE @ltr_excl     BIT = CASE WHEN EXISTS (SELECT 1 FROM @include_long_term_receivable WHERE company_code = @co) THEN 1 ELSE 0 END;
    DECLARE @intself_excl BIT = CASE WHEN EXISTS (SELECT 1 FROM @interest_self_offset     WHERE company_code = @co) THEN 1 ELSE 0 END;

    -- ==========================================
    -- HRC1.1 贷方含收入的手工分录
    -- ==========================================
    DECLARE @hrc1_1_desc NVARCHAR(500) = '';

    IF OBJECT_ID('tempdb..#hrc1_1_final') IS NOT NULL DROP TABLE #hrc1_1_final;

    -- 基础筛选：贷方收入 + 手工分录特征（批处理/纯数字用户名）
    SELECT DISTINCT voucher_no
    INTO #hrc1_1_final
    FROM dbo.journal_entries
    WHERE company_code = @co
      AND dr_cr_indicator = 'H'                       -- 贷方
      AND gl_account LIKE @rev_prefix + '%'           -- 收入科目
      AND fiscal_period >= @start_period
      AND ISNULL(voucher_status, '') <> 'D'           -- 排除已删除
      AND (username IN ('WF-BATCH', 'SAP_WFRT')
           OR username LIKE '[0-9]%');               -- 纯数字用户名（手工录入特征）

    DECLARE @hrc1_1_count INT = (SELECT COUNT(*) FROM #hrc1_1_final);

    IF @hrc1_1_count <= 5
    BEGIN
        SET @hrc1_1_desc = '筛选报告期内贷方包含收入的手工分录';
    END
    ELSE
    BEGIN
        -- 进一步筛选：含「错误/冲销/调差/调整」等关键词
        DELETE f FROM #hrc1_1_final f
        WHERE f.voucher_no NOT IN (
            SELECT DISTINCT j.voucher_no
            FROM dbo.journal_entries j
            WHERE j.company_code = @co
              AND j.voucher_no IN (SELECT voucher_no FROM #hrc1_1_final)
              AND (j.item_text LIKE N'%错误%' OR j.item_text LIKE N'%冲销%'
                   OR j.item_text LIKE N'%调差%' OR j.item_text LIKE N'%调整%')
        );
        SET @hrc1_1_count = (SELECT COUNT(*) FROM #hrc1_1_final);

        IF @hrc1_1_count <= 5
            SET @hrc1_1_desc = '筛选报告期内贷方包含收入的手工分录，再筛选出含「错误、冲销、调差、调整」等字样的凭证';
        ELSE
        BEGIN
            -- 再进一步：客商编号仅出现一次
            DELETE f FROM #hrc1_1_final f
            WHERE f.voucher_no NOT IN (
                SELECT DISTINCT j.voucher_no
                FROM dbo.journal_entries j
                WHERE j.company_code = @co
                  AND j.voucher_no IN (SELECT voucher_no FROM #hrc1_1_final)
                  AND j.customer_no IS NOT NULL AND j.customer_no <> ''
                  AND j.customer_no IN (
                      SELECT customer_no
                      FROM dbo.journal_entries
                      WHERE company_code = @co
                        AND customer_no IS NOT NULL AND customer_no <> ''
                      GROUP BY customer_no
                      HAVING COUNT(DISTINCT voucher_no) = 1
                  )
            );
            SET @hrc1_1_desc = '筛选报告期内贷方包含收入的手工分录，再筛选出含「错误、冲销、调差、调整」等字样，且该客商编号仅出现一次的凭证';
        END
    END

    -- ==========================================
    -- HRC1.2 借方含生产成本的手工分录
    -- ==========================================
    DECLARE @hrc1_2_desc NVARCHAR(500) = '';
    IF OBJECT_ID('tempdb..#hrc1_2_final') IS NOT NULL DROP TABLE #hrc1_2_final;

    -- 通用变体：要求项目文本含「人为操作」关键词
    SELECT DISTINCT voucher_no
    INTO #hrc1_2_final
    FROM dbo.journal_entries
    WHERE company_code = @co
      AND dr_cr_indicator = 'S'                       -- 借方
      AND gl_account LIKE @cost_prefix + '%'          -- 生产成本科目
      AND item_text LIKE N'%人为操作%'
      AND fiscal_period >= @start_period
      AND ISNULL(voucher_status, '') <> 'D'
      AND (username IN ('WF-BATCH', 'SAP_WFRT') OR username LIKE '[0-9]%');

    DECLARE @hrc1_2_count INT = (SELECT COUNT(*) FROM #hrc1_2_final);

    IF @hrc1_2_count <= 3
        SET @hrc1_2_desc = '筛选报告期内借方包含生产成本的手工分录，再筛选出项目文本含「人为操作」的凭证';
    ELSE
    BEGIN
        -- 数量偏多时进一步收紧：仅保留客商编号仅出现一次者
        DELETE f FROM #hrc1_2_final f
        WHERE f.voucher_no NOT IN (
            SELECT DISTINCT j.voucher_no
            FROM dbo.journal_entries j
            WHERE j.company_code = @co
              AND j.voucher_no IN (SELECT voucher_no FROM #hrc1_2_final)
              AND j.customer_no IS NOT NULL AND j.customer_no <> ''
              AND j.customer_no IN (
                  SELECT customer_no
                  FROM dbo.journal_entries
                  WHERE company_code = @co
                    AND customer_no IS NOT NULL AND customer_no <> ''
                  GROUP BY customer_no
                  HAVING COUNT(DISTINCT voucher_no) = 1
              )
        );
        SET @hrc1_2_desc = '筛选报告期内借方包含生产成本的手工分录（含「人为操作」），且该客商编号仅出现一次';
    END

    -- 注：原脚本对部分公司采用「仅按 5001 科目、不要求关键词」的特殊变体；
    --     本模板以通用变体为准。如需该特殊变体，可将上方 item_text 条件改为可配置开关。

    -- ==========================================
    -- HRC2.1 收入贷记但未借记对应资产（差集运算）
    -- ==========================================
    DECLARE @hrc2_1_desc NVARCHAR(500) = '';
    IF OBJECT_ID('tempdb..#hrc2_1_revenue') IS NOT NULL DROP TABLE #hrc2_1_revenue;
    IF OBJECT_ID('tempdb..#hrc2_1_assets')  IS NOT NULL DROP TABLE #hrc2_1_assets;
    IF OBJECT_ID('tempdb..#hrc2_1_final')   IS NOT NULL DROP TABLE #hrc2_1_final;

    -- 所有贷方收入凭证
    SELECT DISTINCT voucher_no INTO #hrc2_1_revenue
    FROM dbo.journal_entries
    WHERE company_code = @co AND dr_cr_indicator = 'H'
      AND gl_account LIKE @rev_prefix + '%'
      AND fiscal_period >= @start_period
      AND ISNULL(voucher_status, '') <> 'D';

    -- 所有借方对应资产/债权凭证
    SELECT DISTINCT voucher_no INTO #hrc2_1_assets
    FROM dbo.journal_entries
    WHERE company_code = @co AND dr_cr_indicator = 'S'
      AND fiscal_period >= @start_period
      AND ISNULL(voucher_status, '') <> 'D'
      AND (LEFT(gl_account, 4) IN (SELECT p FROM @asset_prefixes)
           OR LEFT(gl_account, 2) = @cash_bank_prefix);

    -- 差集：有收入但无对应资产
    SELECT r.voucher_no INTO #hrc2_1_final
    FROM #hrc2_1_revenue r
    LEFT JOIN #hrc2_1_assets a ON r.voucher_no = a.voucher_no
    WHERE a.voucher_no IS NULL;

    DECLARE @hrc2_1_count INT = (SELECT COUNT(*) FROM #hrc2_1_final);

    IF @hrc2_1_count <= 3
    BEGIN
        SET @hrc2_1_desc = '报告期内贷记包含收入，未借记应收账款、预收账款、应收票据、职工薪酬、现金或银行存款的会计分录';
    END
    ELSE
    BEGIN
        -- 排除用户账号以 E（或 E/B）开头的凭证
        DELETE f FROM #hrc2_1_final f
        WHERE f.voucher_no IN (
            SELECT j.voucher_no
            FROM dbo.journal_entries j
            WHERE j.company_code = @co
              AND j.voucher_no IN (SELECT voucher_no FROM #hrc2_1_final)
              AND (
                    (LEFT(j.username, 1) = 'E' AND @eb_excl = 0)
                 OR (LEFT(j.username, 1) IN ('E','B') AND @eb_excl = 1)
              )
        );

        IF @eb_excl = 1
            SET @hrc2_1_desc = '报告期内贷记包含收入，未借记应收账款等对应资产，且用户账号开头不为 E 或 B 的凭证';
        ELSE
            SET @hrc2_1_desc = '报告期内贷记包含收入，未借记应收账款等对应资产，且用户账号开头不为 E 的凭证';

        -- 剔除集团内往来描述（按可配置公司列表与关键词）
        IF @grp_excl = 1
        BEGIN
            DELETE f FROM #hrc2_1_final f
            WHERE f.voucher_no IN (
                SELECT j.voucher_no
                FROM dbo.journal_entries j
                WHERE j.company_code = @co
                  AND j.voucher_no IN (SELECT voucher_no FROM #hrc2_1_final)
                  AND EXISTS (SELECT 1 FROM @interco_keywords k WHERE j.account_desc LIKE k.kw)
            );
            SET @hrc2_1_desc = @hrc2_1_desc + N'，并剔除科目描述含「集团内往来」字样的分录';
        END
    END

    -- ==========================================
    -- HRC2.2 利息收入贷记但未借记对应资产（差集运算）
    -- ==========================================
    DECLARE @hrc2_2_desc NVARCHAR(500) = '';
    IF OBJECT_ID('tempdb..#hrc2_2_interest') IS NOT NULL DROP TABLE #hrc2_2_interest;
    IF OBJECT_ID('tempdb..#hrc2_2_assets')  IS NOT NULL DROP TABLE #hrc2_2_assets;
    IF OBJECT_ID('tempdb..#hrc2_2_final')   IS NOT NULL DROP TABLE #hrc2_2_final;

    -- 所有贷方利息收入凭证
    SELECT DISTINCT voucher_no INTO #hrc2_2_interest
    FROM dbo.journal_entries
    WHERE company_code = @co AND dr_cr_indicator = 'H'
      AND gl_account LIKE @interest_prefix + '%'
      AND fiscal_period >= @start_period
      AND ISNULL(voucher_status, '') <> 'D';

    -- 对应资产借方凭证（按公司可配置扩展长期应收款/利息收入自抵）
    SELECT DISTINCT voucher_no INTO #hrc2_2_assets
    FROM dbo.journal_entries
    WHERE company_code = @co AND dr_cr_indicator = 'S'
      AND fiscal_period >= @start_period
      AND ISNULL(voucher_status, '') <> 'D'
      AND (LEFT(gl_account, 4) IN ('1132','1221')          -- 应收利息、其他应收款
           OR LEFT(gl_account, 2) = @cash_bank_prefix       -- 现金/银行存款
           OR (@ltr_excl = 1 AND LEFT(gl_account, 4) = @lt_recv_prefix)     -- 长期应收款类（可配置）
           OR (@intself_excl = 1 AND LEFT(gl_account, 6) = @interest_prefix)); -- 利息收入自抵（可配置）

    -- 差集
    SELECT r.voucher_no INTO #hrc2_2_final
    FROM #hrc2_2_interest r
    LEFT JOIN #hrc2_2_assets a ON r.voucher_no = a.voucher_no
    WHERE a.voucher_no IS NULL;

    -- 剔除集团内往来（按可配置公司列表）
    IF @grp_excl = 1
        DELETE f FROM #hrc2_2_final f
        WHERE f.voucher_no IN (
            SELECT j.voucher_no
            FROM dbo.journal_entries j
            WHERE j.company_code = @co
              AND j.voucher_no IN (SELECT voucher_no FROM #hrc2_2_final)
              AND EXISTS (SELECT 1 FROM @interco_keywords k WHERE j.account_desc LIKE k.kw)
        );

    IF @ltr_excl = 1 AND @intself_excl = 1
        SET @hrc2_2_desc = '报告期内贷记包含利息收入，未借记应收利息、其他应收款、长期应收款、利息收入、现金或银行存款的会计分录';
    ELSE IF @ltr_excl = 1
        SET @hrc2_2_desc = '报告期内贷记包含利息收入，未借记应收利息、其他应收款、长期应收款、现金或银行存款的会计分录';
    ELSE IF @intself_excl = 1
        SET @hrc2_2_desc = '报告期内贷记包含利息收入，未借记应收利息、其他应收款、利息收入、现金或银行存款的会计分录';
    ELSE
        SET @hrc2_2_desc = '报告期内贷记包含利息收入，未借记应收利息、其他应收款、现金或银行存款的会计分录';

    -- ==========================================
    -- HRC3 关键人员名单编制的分录
    -- ==========================================
    DECLARE @hrc3_desc NVARCHAR(500) = '报告期内关键人员（如业务总监）名单中人员编制的手工分录';
    IF OBJECT_ID('tempdb..#hrc3_final') IS NOT NULL DROP TABLE #hrc3_final;

    SELECT DISTINCT voucher_no INTO #hrc3_final
    FROM dbo.journal_entries
    WHERE company_code = @co
      AND username IN (SELECT username FROM @key_user_list)
      AND fiscal_period >= @start_period
      AND ISNULL(voucher_status, '') <> 'D';

    -- ==========================================
    -- 汇总 + 明细落表
    -- ==========================================
    INSERT INTO #HRC_Summary (company_code, hrc1_1_desc, hrc1_2_desc, hrc2_1_desc, hrc2_2_desc, hrc3_desc)
    VALUES (@co, @hrc1_1_desc, @hrc1_2_desc, @hrc2_1_desc, @hrc2_2_desc, @hrc3_desc);

    INSERT INTO #HRC_Detail (hrc_type, company_code, voucher_no)
    SELECT 'HRC1.1', @co, voucher_no FROM #hrc1_1_final
    UNION ALL SELECT 'HRC1.2', @co, voucher_no FROM #hrc1_2_final
    UNION ALL SELECT 'HRC2.1', @co, voucher_no FROM #hrc2_1_final
    UNION ALL SELECT 'HRC2.2', @co, voucher_no FROM #hrc2_2_final
    UNION ALL SELECT 'HRC3',   @co, voucher_no FROM #hrc3_final;

    -- 清理本轮临时表
    IF OBJECT_ID('tempdb..#hrc1_1_final')  IS NOT NULL DROP TABLE #hrc1_1_final;
    IF OBJECT_ID('tempdb..#hrc1_2_final')  IS NOT NULL DROP TABLE #hrc1_2_final;
    IF OBJECT_ID('tempdb..#hrc2_1_revenue') IS NOT NULL DROP TABLE #hrc2_1_revenue;
    IF OBJECT_ID('tempdb..#hrc2_1_assets')  IS NOT NULL DROP TABLE #hrc2_1_assets;
    IF OBJECT_ID('tempdb..#hrc2_1_final')   IS NOT NULL DROP TABLE #hrc2_1_final;
    IF OBJECT_ID('tempdb..#hrc2_2_interest') IS NOT NULL DROP TABLE #hrc2_2_interest;
    IF OBJECT_ID('tempdb..#hrc2_2_assets')  IS NOT NULL DROP TABLE #hrc2_2_assets;
    IF OBJECT_ID('tempdb..#hrc2_2_final')   IS NOT NULL DROP TABLE #hrc2_2_final;
    IF OBJECT_ID('tempdb..#hrc3_final')     IS NOT NULL DROP TABLE #hrc3_final;

    FETCH NEXT FROM co_cursor INTO @co;
END

CLOSE co_cursor;
DEALLOCATE co_cursor;

-- =============================================
-- 输出结果
-- =============================================
PRINT '===========================================';
PRINT 'HRC 汇总（按公司）';
PRINT '===========================================';
SELECT * FROM #HRC_Summary ORDER BY company_code;

PRINT '===========================================';
PRINT 'HRC 命中明细（凭证明细）';
PRINT '===========================================';
SELECT hrc_type, company_code, voucher_no,
       COUNT(*) OVER (PARTITION BY hrc_type, company_code) AS hit_count
FROM #HRC_Detail
ORDER BY hrc_type, company_code, voucher_no;

-- 清理
IF OBJECT_ID('tempdb..#HRC_Summary') IS NOT NULL DROP TABLE #HRC_Summary;
IF OBJECT_ID('tempdb..#HRC_Detail')  IS NOT NULL DROP TABLE #HRC_Detail;

PRINT '高风险分录筛选完成！';
GO

-- =============================================
-- 性能建议（参考）：
--   1. 已在 setup_and_check.sql 建立 company_code / voucher_no /
--      fiscal_period / username / gl_account 索引。
--   2. 百万行级数据建议按月或按公司分批，或改写为集合式查询并行执行。
--   3. 导出可用 bcp / SSIS / OPENROWSET，路径使用相对路径或注释说明。
-- =============================================

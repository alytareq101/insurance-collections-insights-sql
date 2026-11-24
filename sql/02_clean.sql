-- =============================================================
-- 02_clean.sql
-- Turns raw_installments (the export, quirks included) into a clean
-- installments table: the same rules as the Power Query pipeline.
-- =============================================================

USE premium_tracker;

-- 1. The snapshot date, kept in one place (same idea as AsOfDate in Power BI)
DROP TABLE IF EXISTS settings;
CREATE TABLE settings (as_of DATE NOT NULL);
INSERT INTO settings VALUES ('2026-11-17');

-- 2. Clean table
--    a) TRIM spaces in names
--    b) 'False' key accounts -> NULL, then filled from the customer's other rows
--    c) DISTINCT removes the exact duplicate lines
--    d) gross_premium > 0 removes refunds (credit notes)
DROP TABLE IF EXISTS installments;
CREATE TABLE installments AS
SELECT
    d.insurer, d.customer, d.premium_date, d.policy_no,
    d.net_premium, d.gross_premium, d.insurance_type, d.product,
    COALESCE(d.key_account, k.key_account) AS key_account,
    d.effective_from, d.effective_to, d.status,
    d.breakdown_requested, d.breakdown_received, d.breakdown_issue,
    d.breakdown_confirmed, d.invoice_received, d.invoice_issue,
    d.sent_to_client, d.pop_received, d.receipt_received, d.settled_date
FROM (
    SELECT DISTINCT
        TRIM(insurer)  AS insurer,
        TRIM(customer) AS customer,
        premium_date, policy_no, net_premium, gross_premium,
        insurance_type, product,
        CASE WHEN key_account IS NULL OR TRIM(key_account) IN ('', 'False')
             THEN NULL ELSE TRIM(key_account) END AS key_account,
        effective_from, effective_to, status,
        breakdown_requested, breakdown_received, breakdown_issue,
        breakdown_confirmed, invoice_received, invoice_issue,
        sent_to_client, pop_received, receipt_received, settled_date
    FROM raw_installments
    WHERE gross_premium > 0
) AS d
LEFT JOIN (
    -- each customer's real key account (ignoring the 'False' export errors)
    SELECT TRIM(customer) AS customer, MAX(TRIM(key_account)) AS key_account
    FROM raw_installments
    WHERE key_account IS NOT NULL AND TRIM(key_account) NOT IN ('', 'False')
    GROUP BY TRIM(customer)
) AS k ON k.customer = d.customer;

ALTER TABLE installments
    ADD COLUMN installment_id INT AUTO_INCREMENT PRIMARY KEY FIRST;

-- 3. Checks (compare with Power BI)
SELECT COUNT(*)                                      AS clean_rows,        -- 481
       COUNT(DISTINCT customer)                      AS customers,         -- 45
       SUM(key_account IS NULL)                      AS missing_key_acct,  -- 0
       ROUND(SUM(gross_premium) / 1e6, 1)            AS total_due_m        -- 263.4
FROM installments;

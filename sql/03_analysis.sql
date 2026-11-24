-- =============================================================
-- 03_analysis.sql
-- Premium collection analysis: 8 business questions, answered in SQL
-- Data: mock insurance premium installments (fictional, no real clients),
--       cleaned in 02_clean.sql. Snapshot date (as_of) = 17 Nov 2026.
-- Tip: in MySQL Workbench, select one query and click Run to run it alone.
-- =============================================================

USE premium_tracker;


-- -------------------------------------------------------------
-- Q1. Where is the outstanding money stuck, and who has to act?
-- -------------------------------------------------------------
-- Each unpaid installment gets the label of the first step that hasn't
-- happened yet, so we can see who is holding it up.
SELECT
    CASE
        WHEN breakdown_requested IS NULL THEN '1 Not started'
        WHEN breakdown_received  IS NULL THEN '2 Waiting breakdown (Insurer)'
        WHEN breakdown_confirmed IS NULL THEN '3 Reviewing breakdown (Us)'
        WHEN invoice_received    IS NULL THEN '4 Waiting invoice (Insurer)'
        WHEN sent_to_client      IS NULL THEN '5 Reviewing invoice (Us)'
        WHEN pop_received        IS NULL THEN '6 Waiting payment (Client)'
        WHEN receipt_received    IS NULL THEN '7 Waiting receipt (Insurer)'
        ELSE                                  '8 Waiting settlement (Finance)'
    END                         AS stage,
    COUNT(*)                    AS installments,
    ROUND(SUM(gross_premium))   AS outstanding_egp
FROM installments
WHERE status = 'Outstanding'
GROUP BY stage
ORDER BY stage;

-- What it tells us: about 24M is already moving through the process.
-- 11.1M of that is waiting for clients to pay, and almost as much (9.3M)
-- is waiting for insurers to send a receipt. So the insurers hold up
-- nearly as much money as the clients do. The 39.6M "Not started" is just
-- future installments, nothing to worry about yet.


-- -------------------------------------------------------------
-- Q2. Which key accounts hold the overdue money?
-- -------------------------------------------------------------
-- Overdue = still unpaid and past its premium date. For each client group
-- we show its share of all overdue money and a running total.
WITH overdue AS (
    SELECT i.key_account,
           i.customer,
           i.gross_premium
    FROM installments AS i
    CROSS JOIN settings AS s
    WHERE i.status = 'Outstanding'
      AND i.premium_date < s.as_of
)
SELECT
    key_account,
    COUNT(DISTINCT customer)                                              AS customers,
    ROUND(SUM(gross_premium))                                             AS overdue_egp,
    ROUND(100 * SUM(gross_premium) / SUM(SUM(gross_premium)) OVER (), 1)  AS share_pct,
    ROUND(100 * SUM(SUM(gross_premium)) OVER (ORDER BY SUM(gross_premium) DESC)
              / SUM(SUM(gross_premium)) OVER (), 1)                       AS running_pct
FROM overdue
GROUP BY key_account
ORDER BY overdue_egp DESC;

-- What it tells us: just 3 of the 11 groups (Zenith Group, Crescent Holding
-- and Cedar Industries) account for 58% of everything overdue. If the
-- Account Managers start with these three, they cover most of the problem.


-- -------------------------------------------------------------
-- Q3. Which insurers are the slowest? (ranked)
-- -------------------------------------------------------------
-- Average days each insurer takes to send a breakdown, an invoice and a
-- receipt, then ranked from slowest (1) to fastest.
WITH speed AS (
    SELECT insurer,
           COUNT(breakdown_received)                                        AS breakdowns,
           ROUND(AVG(DATEDIFF(breakdown_received, breakdown_requested)), 1) AS avg_breakdown_days,
           ROUND(AVG(DATEDIFF(invoice_received,  breakdown_confirmed)), 1)  AS avg_invoice_days,
           ROUND(AVG(DATEDIFF(receipt_received,  pop_received)), 1)         AS avg_receipt_days
    FROM installments
    GROUP BY insurer
)
SELECT *,
       RANK() OVER (ORDER BY avg_breakdown_days DESC) AS slowest_rank
FROM speed
ORDER BY slowest_rank;

-- What it tells us: Red Sea Cover is the slowest with breakdowns (about 7
-- days) and Atlas Re-Assurance takes longest to confirm a payment (10 days).
-- For almost every insurer, the receipt is the slowest step, which fits
-- with the 9.3M we saw waiting on receipts in Q1.
-- Note: these are calendar days. The Power BI dashboard counts working days
-- only, so its numbers are smaller, but the ranking comes out almost the same.


-- -------------------------------------------------------------
-- Q4. Which insurers send wrong documents most often? Medical vs Life?
-- -------------------------------------------------------------
-- Turns each Yes/No error flag into 1/0, so the average is the error rate.
-- Medical and Life are shown side by side for every insurer.
WITH flags AS (
    SELECT insurer,
           insurance_type,
           CASE breakdown_issue WHEN 'Yes' THEN 1 WHEN 'No' THEN 0 END AS bd_err,
           CASE invoice_issue   WHEN 'Yes' THEN 1 WHEN 'No' THEN 0 END AS inv_err
    FROM installments
)
SELECT insurer,
       COUNT(bd_err)                                                             AS breakdowns_reviewed,
       ROUND(100 * AVG(bd_err), 1)                                               AS breakdown_error_pct,
       ROUND(100 * AVG(CASE WHEN insurance_type = 'Medical' THEN bd_err END), 1) AS medical_error_pct,
       ROUND(100 * AVG(CASE WHEN insurance_type = 'Life'    THEN bd_err END), 1) AS life_error_pct,
       ROUND(100 * AVG(inv_err), 1)                                              AS invoice_error_pct
FROM flags
GROUP BY insurer
ORDER BY breakdown_error_pct DESC;

-- What it tells us: almost half of all breakdowns (44%) come back wrong,
-- and about 1 in 5 invoices. Medical breakdowns are wrong more often than
-- Life ones for every single insurer (50% vs 33%), probably because medical
-- member lists are more complicated. Red Sea Cover is both slow (Q3) and
-- error-prone, so its mistakes likely explain a lot of its delays.
-- Careful: Red Sea and Crescent only have 16-17 reviews, so their rates
-- could move a lot with a few more cases.


-- -------------------------------------------------------------
-- Q5. Is on-time payment getting better or worse?
-- -------------------------------------------------------------
-- On time = the client paid on or before the premium date. Shown per month
-- and as a rolling 3-month rate, complete months only.
WITH monthly AS (
    SELECT DATE_FORMAT(i.premium_date, '%Y-%m')              AS month,
           COUNT(*)                                          AS due,
           SUM(i.pop_received IS NOT NULL
               AND i.pop_received <= i.premium_date)         AS on_time
    FROM installments AS i
    CROSS JOIN settings AS s
    WHERE i.premium_date >= '2025-03-01'
      AND i.premium_date <  DATE_FORMAT(s.as_of, '%Y-%m-01')   -- complete months only
    GROUP BY month
)
SELECT month,
       due,
       on_time,
       ROUND(100 * on_time / due, 1)                          AS on_time_pct,
       ROUND(100 * SUM(on_time) OVER w / SUM(due) OVER w, 1)  AS on_time_pct_3m
FROM monthly
WINDOW w AS (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
ORDER BY month;

-- What it tells us: on-time payment drops to around 46% over the year-end
-- months (Nov-Jan), climbs back to 69% by August 2026, and then falls hard
-- in September (32%). September is worth a closer look. Each month only has
-- 10-24 installments, so single months jump around; the 3-month rate shows
-- the real direction.


-- -------------------------------------------------------------
-- Q6. Hypothesis: do clients pay late when they get the invoice late?
-- -------------------------------------------------------------
-- Lead time = days between the client receiving the invoice and the due
-- date. We group premiums by how much notice the client had.
WITH lead_time AS (
    SELECT DATEDIFF(i.premium_date, i.sent_to_client)   AS lead_days,
           (i.pop_received IS NOT NULL
            AND i.pop_received <= i.premium_date)       AS on_time,
           DATEDIFF(i.pop_received, i.premium_date)     AS days_paid_after_due
    FROM installments AS i
    CROSS JOIN settings AS s
    WHERE i.premium_date < s.as_of            -- only premiums already due
      AND i.sent_to_client IS NOT NULL        -- the client got the invoice
)
SELECT
    CASE
        WHEN lead_days < 0  THEN '1 Sent after the due date'
        WHEN lead_days <= 4 THEN '2 0-4 days notice'
        WHEN lead_days <= 9 THEN '3 5-9 days notice'
        ELSE                     '4 10+ days notice'
    END                                  AS notice_given,
    COUNT(*)                             AS installments,
    ROUND(100 * AVG(on_time), 1)         AS on_time_pct,
    ROUND(AVG(days_paid_after_due), 1)   AS avg_days_paid_after_due
FROM lead_time
GROUP BY notice_given
ORDER BY notice_given;

-- What it tells us: yes, the hypothesis holds. When the invoice reaches the
-- client after the due date, nobody pays on time. With less than 5 days'
-- notice, only 1 in 5 pays on time; with 10 or more days, almost 4 in 5 do,
-- and on average they even pay a day early. So the best way to get paid on
-- time is to get invoices out early: faster breakdowns and fewer mistakes.
-- Honest note: this is mock data built from real process experience, so with
-- real data I'd also check other factors like client size or insurer.


-- -------------------------------------------------------------
-- Q7. How often do we request breakdowns late, and what does it cost?
-- -------------------------------------------------------------
-- Our rule is to ask the insurer 14 working days before the premium date,
-- which is about 20 calendar days. Anything later is a delay on our side.
WITH requests AS (
    SELECT i.gross_premium,
           DATEDIFF(i.premium_date, i.breakdown_requested)   AS days_before_due,
           (i.pop_received IS NOT NULL
            AND i.pop_received <= i.premium_date)            AS on_time
    FROM installments AS i
    CROSS JOIN settings AS s
    WHERE i.breakdown_requested IS NOT NULL
      AND i.premium_date < s.as_of                -- only premiums already due
)
SELECT
    CASE WHEN days_before_due < 20 THEN 'Late request (<20 days)'
         ELSE                            'On-time request (20+ days)'
    END                              AS request_timing,
    COUNT(*)                         AS installments,
    ROUND(SUM(gross_premium))        AS premiums_egp,
    ROUND(AVG(days_before_due), 1)   AS avg_days_before_due,
    ROUND(100 * AVG(on_time), 1)     AS paid_on_time_pct
FROM requests
GROUP BY request_timing
ORDER BY request_timing;

-- What it tells us: about 1 in 8 requests (51 of 395) went out late, covering
-- 23M in premiums. Only 14% of those got paid on time, compared with 61% when
-- we asked on schedule. This one is fully in our hands: a tighter weekly
-- Thursday review would protect a lot of collections.


-- -------------------------------------------------------------
-- Q8. Money clients already paid, but Odoo still shows as outstanding
-- -------------------------------------------------------------
-- The client has sent proof of payment, but the installment isn't settled
-- yet. Grouped by insurer, with a total row at the bottom.
SELECT
    COALESCE(i.insurer, 'TOTAL')                                 AS insurer,
    COUNT(*)                                                     AS installments,
    ROUND(SUM(i.gross_premium))                                  AS paid_not_settled_egp,
    ROUND(SUM(CASE WHEN i.premium_date < s.as_of
                   THEN i.gross_premium ELSE 0 END))             AS wrongly_counted_overdue_egp,
    SUM(i.receipt_received IS NULL)                              AS waiting_on_insurer_receipt,
    ROUND(AVG(DATEDIFF(s.as_of, i.pop_received)), 1)             AS avg_days_since_client_paid
FROM installments AS i
CROSS JOIN settings AS s
WHERE i.pop_received IS NOT NULL       -- the client has paid
  AND i.settled_date IS NULL           -- but Odoo still shows Outstanding
GROUP BY i.insurer WITH ROLLUP
ORDER BY GROUPING(i.insurer), paid_not_settled_egp DESC;

-- What it tells us: clients have already paid about 10M that Odoo still
-- lists as outstanding, and in 10 of the 14 cases we're just waiting for the
-- insurer's receipt. 6.07M of it is even counted as overdue, which is 41% of
-- all overdue money. In other words, Account Managers would be chasing
-- clients who already paid. The real follow-up is with the insurers.
-- Crescent Takaful has kept a paying client waiting 23 days.

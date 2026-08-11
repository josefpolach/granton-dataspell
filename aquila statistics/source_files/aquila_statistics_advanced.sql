-- ============================================================
-- Aquila — Advanced Statistics
-- ============================================================
-- Mirrors client_statistics/source_files/client_statistics_advanced.sql,
-- remapped onto the Aquila case data model.
--
-- MAPPING FROM client_statistics -> aquila
--   client        -> "user" (+ user_role)   single tenant: System Air
--   record        -> case_item              the billable unit
--   job_harvest   -> "case"                 the batch a unit belongs to
--   r.created_at  -> "case".created_at      case_item has no timestamp of its own
--   tiered price  -> 0.035 EUR * n          pay-as-you-go, no tiers, no minimum
--                    + 650 EUR / month       mandatory Azure Cloud Infrastructure fee
--
-- BILLABLE ITEM: case_item.status_id IN (2 MATCHED, 4 MATCH_NOT_FOUND, 5 PAIRED)
--
-- The supplied billing definition applies no is_deleted filter; the
-- `-- AND ... is_deleted = FALSE` lines are left commented out throughout so
-- every query below reconciles exactly with the billing query.
--
-- Queries 1–8 are the direct counterparts of the client_statistics set.
-- Queries 9–13 are Aquila-specific — matching quality, funnel and latency
-- signals that the client_statistics model had no equivalent for.
--
-- PRICING (EUR is the billing currency; CZK is derived):
--     items_amount_eur = billable_items * 0.035
--     azure_fee_eur    = 650            -- per MONTH, for the whole customer
--     total_eur        = items_amount_eur + azure_fee_eur
--     total_czk        = total_eur * :eur_to_czk_rate   (set below, TODO: confirm)
--
-- The Azure fee is customer-wide, so it is NOT split across per-user rows.
-- Per-user amounts below are item charges only; the fee is applied once per
-- month, in query 6 (the only query that reports an invoice-level total).
--
-- Unit price / fee / FX rate are inlined per query — search/replace to change:
--     0.035::numeric   unit price EUR per item
--     650::numeric     Azure monthly fee EUR
--     25.0::numeric    EUR -> CZK rate
--
-- EXCLUDED ACCOUNTS: five internal/test user_ids are filtered out of every
--       query below. The filter is written as
--           (c.user_id IS NULL OR c.user_id NOT IN (...))
--       because a bare NOT IN would also drop cases with a NULL user_id
--       (NULL NOT IN (...) yields NULL, not TRUE) — those accounts are not on
--       the exclusion list, so they are kept.
-- ============================================================


-- ============================================================
-- 1. MONTH-OVER-MONTH GROWTH PER USER
-- ============================================================
WITH billable AS (
    SELECT
        COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)') AS user_name,
        DATE_TRUNC('month', c.created_at) AS month,
        c.case_id,
        i.item_id
    FROM case_item i
    INNER JOIN "case" c ON c.case_id = i.case_id
    LEFT  JOIN "user" u ON u.user_id = c.user_id
    WHERE i.status_id IN (2, 4, 5)
    AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
    --   AND i.is_deleted = FALSE
),
monthly_per_user AS (
    SELECT
        user_name,
        month,
        COUNT(DISTINCT case_id)             AS cases,
        COUNT(item_id)                            AS billable_items,
        ROUND(COUNT(item_id) * 0.035::numeric, 2) AS amount_eur
    FROM billable
    GROUP BY user_name, month
)
SELECT
    user_name,
    month,
    cases,
    billable_items,
    amount_eur,
    LAG(billable_items) OVER (PARTITION BY user_name ORDER BY month) AS prev_month_items,
    LAG(amount_eur)     OVER (PARTITION BY user_name ORDER BY month) AS prev_month_amount_eur,
    ROUND((billable_items - LAG(billable_items) OVER (PARTITION BY user_name ORDER BY month))
        * 100.0 / NULLIF(LAG(billable_items) OVER (PARTITION BY user_name ORDER BY month), 0), 1
    )                                                                AS items_growth_pct,
    ROUND((amount_eur - LAG(amount_eur) OVER (PARTITION BY user_name ORDER BY month))
        * 100.0 / NULLIF(LAG(amount_eur) OVER (PARTITION BY user_name ORDER BY month), 0), 1
    )                                                                AS revenue_growth_pct
FROM monthly_per_user
ORDER BY user_name, month;


-- ============================================================
-- 2. DAILY ITEM VOLUME (heatmap data)
-- ============================================================
SELECT
    COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)') AS user_name,
    DATE(c.created_at)          AS day,
    COUNT(DISTINCT c.case_id)   AS cases,
    COUNT(i.item_id)            AS billable_items
FROM case_item i
INNER JOIN "case" c ON c.case_id = i.case_id
LEFT  JOIN "user" u ON u.user_id = c.user_id
WHERE i.status_id IN (2, 4, 5)
AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
--AND i.is_deleted = FALSE
GROUP BY user_name, DATE(c.created_at)
ORDER BY day, user_name;


-- ============================================================
-- 3. CONSUMPTION TREND PER USER (line chart — one line per user)
-- ============================================================
SELECT
    COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)') AS user_name,
    DATE_TRUNC('month', c.created_at)       AS month,
    COUNT(DISTINCT c.case_id)               AS cases,
    COUNT(i.item_id)                              AS billable_items,
    ROUND(COUNT(i.item_id) * 0.035::numeric, 2)   AS amount_eur,
    ROUND(ROUND(COUNT(i.item_id) * 0.035::numeric, 2) * 25.0::numeric, 2) AS amount_czk
FROM case_item i
INNER JOIN "case" c ON c.case_id = i.case_id
LEFT  JOIN "user" u ON u.user_id = c.user_id
WHERE i.status_id IN (2, 4, 5)
AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
--AND i.is_deleted = FALSE
GROUP BY user_name, DATE_TRUNC('month', c.created_at)
ORDER BY month, user_name;


-- ============================================================
-- 4. ITEM STATUS DISTRIBUTION PER USER
--    (all statuses, not just billable — shows what share is actually billed)
-- ============================================================
SELECT
    COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)') AS user_name,
    i.status_id,
    s.status_name,
    (i.status_id IN (2, 4, 5))  AS is_billable,
    COUNT(*)                    AS item_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY
        COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)')), 1) AS pct_of_user
FROM case_item i
INNER JOIN "case"       c ON c.case_id  = i.case_id
INNER JOIN item_status  s ON s.status_id = i.status_id
LEFT  JOIN "user"       u ON u.user_id  = c.user_id
WHERE (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
--AND i.is_deleted = FALSE
GROUP BY user_name, i.status_id, s.status_name
ORDER BY user_name, i.status_id;


-- ============================================================
-- 5. CASE EFFICIENCY PER USER (items per case)
--    counterpart of "harvest job efficiency"
-- ============================================================
-- Aggregate per case first, so the median/percentiles are case-weighted
-- (aggregating straight off the item rows would weight each case by its own size).
WITH per_case AS (
    SELECT
        COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)') AS user_name,
        c.case_id,
        COUNT(i.item_id) AS items_in_case
    FROM "case" c
    INNER JOIN case_item i ON i.case_id = c.case_id AND i.status_id IN (2, 4, 5)
    LEFT  JOIN "user"    u ON u.user_id = c.user_id
    AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
    --   AND i.is_deleted = FALSE
    GROUP BY user_name, c.case_id
)
SELECT
    user_name,
    COUNT(*)                AS cases,
    SUM(items_in_case)      AS billable_items,
    ROUND(SUM(items_in_case)::numeric / NULLIF(COUNT(*), 0), 1) AS items_per_case,
    MIN(items_in_case)      AS smallest_case,
    MAX(items_in_case)      AS largest_case,
    ROUND(PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY items_in_case)::numeric, 1) AS median_case_size,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY items_in_case)::numeric, 1) AS p95_case_size
FROM per_case
GROUP BY user_name
ORDER BY items_per_case DESC;


-- ============================================================
-- 6. CUMULATIVE CONSUMPTION OVER THE YEAR (YTD line chart)
-- ============================================================
-- This is the only query that reports an invoice-level total, so it is where
-- the mandatory Azure Cloud Infrastructure fee is applied: once per month,
-- for the whole customer. Item charges are computed off the raw item count,
-- so no per-user rounding leaks into the total.
WITH monthly_totals AS (
    SELECT
        DATE_TRUNC('month', c.created_at)             AS month,
        COUNT(i.item_id)                              AS monthly_items,
        ROUND(COUNT(i.item_id) * 0.035::numeric, 2)   AS items_amount_eur,
        650::numeric                                  AS azure_fee_eur
    FROM case_item i
    INNER JOIN "case" c ON c.case_id = i.case_id
    WHERE i.status_id IN (2, 4, 5)
    AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
    --   AND i.is_deleted = FALSE
    --   AND c.is_deleted = FALSE
    GROUP BY DATE_TRUNC('month', c.created_at)
),
monthly_billed AS (
    SELECT
        month,
        monthly_items,
        items_amount_eur,
        azure_fee_eur,
        ROUND(items_amount_eur + azure_fee_eur, 2)                    AS total_eur,
        ROUND(ROUND(items_amount_eur + azure_fee_eur, 2) * 25.0::numeric, 2) AS total_czk
    FROM monthly_totals
)
SELECT
    month,
    monthly_items,
    items_amount_eur,
    azure_fee_eur,
    total_eur,
    total_czk,
    SUM(monthly_items) OVER (ORDER BY month)            AS cumulative_items,
    ROUND(SUM(total_eur) OVER (ORDER BY month), 2)      AS cumulative_eur,
    ROUND(SUM(total_czk) OVER (ORDER BY month), 2)      AS cumulative_czk
FROM monthly_billed
ORDER BY month;


-- ============================================================
-- 7. VOLUME BAND PER USER PER MONTH
--    (replaces "tier distribution" — pay-as-you-go has no price tiers,
--     so these bands are descriptive only, not billing brackets)
-- ============================================================
WITH per_user_month AS (
    SELECT
        COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)') AS user_name,
        DATE_TRUNC('month', c.created_at)   AS month,
        COUNT(DISTINCT c.case_id)           AS cases,
        COUNT(i.item_id)                    AS billable_items
    FROM case_item i
    INNER JOIN "case" c ON c.case_id = i.case_id
    LEFT  JOIN "user" u ON u.user_id = c.user_id
    WHERE i.status_id IN (2, 4, 5)
    AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
    --   AND i.is_deleted = FALSE
    GROUP BY user_name, DATE_TRUNC('month', c.created_at)
)
SELECT
    user_name,
    month,
    cases,
    billable_items,
    ROUND(billable_items * 0.035::numeric, 2) AS amount_eur,
    CASE
        WHEN billable_items <=   500 THEN '0–500'
        WHEN billable_items <=  1000 THEN '501–1000'
        WHEN billable_items <=  1500 THEN '1001–1500'
        WHEN billable_items <=  2000 THEN '1501–2000'
        WHEN billable_items <=  3000 THEN '2001–3000'
        WHEN billable_items <=  5000 THEN '3001–5000'
        ELSE '5000+'
    END AS volume_band
FROM per_user_month
ORDER BY month, billable_items DESC;


-- ============================================================
-- 8. TOP USERS BY VOLUME — PARETO (80/20)
-- ============================================================
WITH per_user AS (
    SELECT
        COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)') AS user_name,
        COUNT(i.item_id) AS billable_items
    FROM case_item i
    INNER JOIN "case" c ON c.case_id = i.case_id
    LEFT  JOIN "user" u ON u.user_id = c.user_id
    WHERE i.status_id IN (2, 4, 5)
    AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
    --   AND i.is_deleted = FALSE
    GROUP BY user_name
),
ranked AS (
    SELECT
        user_name,
        billable_items,
        RANK() OVER (ORDER BY billable_items DESC) AS rank,
        ROUND(billable_items * 100.0 / SUM(billable_items) OVER (), 1) AS pct_of_total,
        ROUND(SUM(billable_items) OVER (ORDER BY billable_items DESC)
            * 100.0 / SUM(billable_items) OVER (), 1) AS cumulative_pct
    FROM per_user
)
SELECT rank, user_name, billable_items, pct_of_total, cumulative_pct
FROM ranked
ORDER BY rank;


-- ============================================================
-- 9. MATCHING QUALITY PER USER PER MONTH  (Aquila-specific)
--    How much of what we bill actually produced a usable match.
--    NOT_MATCHED (3) is shown for context — it is NOT billed.
-- ============================================================
SELECT
    COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)') AS user_name,
    DATE_TRUNC('month', c.created_at) AS month,
    COUNT(*) FILTER (WHERE i.status_id IN (2, 4, 5))     AS billable_items,
    COUNT(*) FILTER (WHERE i.status_id = 5)              AS paired,
    COUNT(*) FILTER (WHERE i.status_id = 2)              AS matched_not_paired,
    COUNT(*) FILTER (WHERE i.status_id = 4)              AS match_not_found,
    COUNT(*) FILTER (WHERE i.status_id = 3)              AS not_matched_unbilled,
    COUNT(*) FILTER (WHERE i.status_id = 1)              AS still_created_unbilled,
    ROUND(COUNT(*) FILTER (WHERE i.status_id = 5) * 100.0
        / NULLIF(COUNT(*) FILTER (WHERE i.status_id IN (2, 4, 5)), 0), 1) AS pair_rate_pct,
    ROUND(COUNT(*) FILTER (WHERE i.status_id = 4) * 100.0
        / NULLIF(COUNT(*) FILTER (WHERE i.status_id IN (2, 4, 5)), 0), 1) AS no_match_rate_pct,
    ROUND(COUNT(*) FILTER (WHERE i.exact_dimensions_found) * 100.0
        / NULLIF(COUNT(*) FILTER (WHERE i.status_id IN (2, 4, 5)), 0), 1) AS exact_dimensions_pct
FROM case_item i
INNER JOIN "case" c ON c.case_id = i.case_id
LEFT  JOIN "user" u ON u.user_id = c.user_id
WHERE (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
--AND i.is_deleted = FALSE
GROUP BY user_name, DATE_TRUNC('month', c.created_at)
ORDER BY month, user_name;


-- ============================================================
-- 10. CASE STATE FUNNEL PER MONTH  (Aquila-specific)
--     Cases are secondary to billing, but this shows how many uploads
--     reach a terminal state. state_id >= 4 = "settled" per your definition
--     (note: that band includes FAILED (4) and DROPPED (8)).
-- ============================================================
SELECT
    DATE_TRUNC('month', c.created_at)   AS month,
    cs.state_id,
    cs.state_name,
    (c.state_id >= 4)                   AS is_settled,
    COUNT(*)                            AS cases,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY DATE_TRUNC('month', c.created_at)), 1) AS pct_of_month,
    SUM(c.items_total)                  AS items_total,
    ROUND(AVG(c.percentage_matched), 1) AS avg_pct_matched,
    ROUND(AVG(c.percentage_done), 1)    AS avg_pct_done
FROM "case" c
INNER JOIN case_state cs ON cs.state_id = c.state_id
WHERE (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
--AND c.is_deleted = FALSE
GROUP BY DATE_TRUNC('month', c.created_at), cs.state_id, cs.state_name, (c.state_id >= 4)
ORDER BY month, cs.state_id;


-- ============================================================
-- 11. PROCESSING LATENCY PER MONTH  (Aquila-specific)
--     created_at -> queued_at  = upload/parse time
--     queued_at  -> last_modified = processing time (terminal cases only)
-- ============================================================
SELECT
    DATE_TRUNC('month', c.created_at) AS month,
    COUNT(*)                          AS cases,
    ROUND(AVG(EXTRACT(EPOCH FROM (c.queued_at - c.created_at)))::numeric, 1)    AS avg_parse_secs,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (c.queued_at - c.created_at)))::numeric, 1) AS p50_parse_secs,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (c.queued_at - c.created_at)))::numeric, 1) AS p95_parse_secs,
    ROUND(AVG(EXTRACT(EPOCH FROM (c.last_modified - c.queued_at)))::numeric, 1) AS avg_process_secs,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (c.last_modified - c.queued_at)))::numeric, 1) AS p50_process_secs,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (c.last_modified - c.queued_at)))::numeric, 1) AS p95_process_secs,
    ROUND(AVG(c.items_total)::numeric, 1) AS avg_items_per_case
FROM "case" c
WHERE c.queued_at IS NOT NULL
  AND c.state_id >= 4          -- terminal states only, so last_modified is meaningful
  AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
--AND c.is_deleted = FALSE
GROUP BY DATE_TRUNC('month', c.created_at)
ORDER BY month;


-- ============================================================
-- 12. OFFER CANDIDATE DEPTH & MATCH DISTANCE  (Aquila-specific)
--     How many offers the matcher produced per billable item, and how
--     good the one the user actually picked was.
-- ============================================================
WITH billable_items AS (
    SELECT
        COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)') AS user_name,
        DATE_TRUNC('month', c.created_at) AS month,
        i.item_id
    FROM case_item i
    INNER JOIN "case" c ON c.case_id = i.case_id
    LEFT  JOIN "user" u ON u.user_id = c.user_id
    WHERE i.status_id IN (2, 4, 5)
    AND (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
    --   AND i.is_deleted = FALSE
),
per_item AS (
    SELECT
        b.user_name,
        b.month,
        b.item_id,
        COUNT(o.offer_item_id)                                  AS offers_offered,
        COUNT(o.offer_item_id) FILTER (WHERE o.is_selected)     AS offers_selected,
        MIN(o.match_distance)                                   AS best_distance,
        MIN(o.match_distance) FILTER (WHERE o.is_selected)      AS selected_distance
    FROM billable_items b
    LEFT JOIN offer_item o ON o.item_id = b.item_id
    GROUP BY b.user_name, b.month, b.item_id
)
SELECT
    user_name,
    month,
    COUNT(*)                                                    AS billable_items,
    ROUND(AVG(offers_offered)::numeric, 2)                      AS avg_offers_per_item,
    COUNT(*) FILTER (WHERE offers_offered = 0)                  AS items_with_no_offer,
    COUNT(*) FILTER (WHERE offers_selected > 0)                 AS items_with_selection,
    ROUND(COUNT(*) FILTER (WHERE offers_selected > 0) * 100.0 / NULLIF(COUNT(*), 0), 1) AS selection_rate_pct,
    ROUND(AVG(best_distance)::numeric, 4)                       AS avg_best_distance,
    ROUND(AVG(selected_distance)::numeric, 4)                   AS avg_selected_distance,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY selected_distance)::numeric, 4) AS p50_selected_distance
FROM per_item
GROUP BY user_name, month
ORDER BY month, user_name;


-- ============================================================
-- 13. ACCESSORY ATTACH RATE PER MONTH  (Aquila-specific)
--     Upsell signal: how often a selected offer carries selected accessories.
-- ============================================================
SELECT
    DATE_TRUNC('month', c.created_at)                       AS month,
    COUNT(DISTINCT o.offer_item_id)                         AS selected_offers,
    COUNT(pa.accessory_id)                                  AS accessories_offered,
    COUNT(pa.accessory_id) FILTER (WHERE pa.is_selected)    AS accessories_selected,
    SUM(pa.accessory_quantity) FILTER (WHERE pa.is_selected) AS accessory_qty_selected,
    ROUND(COUNT(DISTINCT o.offer_item_id) FILTER (WHERE pa.is_selected) * 100.0
        / NULLIF(COUNT(DISTINCT o.offer_item_id), 0), 1)    AS offers_with_accessory_pct
FROM "case" c
INNER JOIN case_item  i  ON i.case_id = c.case_id AND i.status_id IN (2, 4, 5)
INNER JOIN offer_item o  ON o.item_id = i.item_id AND o.is_selected = TRUE
LEFT  JOIN product_accessory pa ON pa.offer_item_id = o.offer_item_id
WHERE (c.user_id IS NULL OR c.user_id NOT IN (
          '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
          'a997e479-9df4-44de-a9ef-bc10ce8376f7',
          '0954b909-1130-4f94-af06-00193783ce31',
          '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
          '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
--AND i.is_deleted = FALSE
GROUP BY DATE_TRUNC('month', c.created_at)
ORDER BY month;

-- Client Statistics - Advanced Queries
-- Based on: record, client, job_harvest, state_id, created_at
-- Pricing tiers: 0-500 @10, 501-1000 @9, 1001-1500 @8, 1501-2000 @7, 2001-3000 @6, 3001-5000 @5 Kč/doc
-- Minimum monthly: 2,990 Kč

-- Reusable pricing macro as CTE (referenced by multiple queries below)
-- monthly_price(n) = GREATEST(2990, tiered calculation)


-- ============================================================
-- 1. MONTH-OVER-MONTH GROWTH PER CLIENT
-- ============================================================
WITH monthly_per_client AS (
    SELECT
        c.name                              AS client_name,
        DATE_TRUNC('month', r.created_at)   AS month,
        COUNT(DISTINCT r.job_harvest_id)    AS jobs_harvested,
        COUNT(r.record_id)                  AS records_created,
        GREATEST(2990,
            CASE
                WHEN COUNT(r.record_id) <= 500  THEN COUNT(r.record_id) * 10
                WHEN COUNT(r.record_id) <= 1000 THEN 5000  + (COUNT(r.record_id) - 500)  * 9
                WHEN COUNT(r.record_id) <= 1500 THEN 9500  + (COUNT(r.record_id) - 1000) * 8
                WHEN COUNT(r.record_id) <= 2000 THEN 13500 + (COUNT(r.record_id) - 1500) * 7
                WHEN COUNT(r.record_id) <= 3000 THEN 17000 + (COUNT(r.record_id) - 2000) * 6
                WHEN COUNT(r.record_id) <= 5000 THEN 23000 + (COUNT(r.record_id) - 3000) * 5
                ELSE NULL
            END
        )                                   AS monthly_price_czk
    FROM record r
    INNER JOIN client c ON r.client_id = c.client_id
    WHERE r.is_deleted = false
      AND (r.state_id >= 18 OR r.state_id = 12)
    GROUP BY c.name, DATE_TRUNC('month', r.created_at)
)
SELECT
    client_name,
    month,
    records_created,
    monthly_price_czk,
    LAG(records_created)    OVER (PARTITION BY client_name ORDER BY month) AS prev_month_records,
    LAG(monthly_price_czk)  OVER (PARTITION BY client_name ORDER BY month) AS prev_month_price_czk,
    ROUND((records_created - LAG(records_created) OVER (PARTITION BY client_name ORDER BY month))
        * 100.0 / NULLIF(LAG(records_created) OVER (PARTITION BY client_name ORDER BY month), 0), 1
    )                                                                       AS records_growth_pct,
    ROUND((monthly_price_czk - LAG(monthly_price_czk) OVER (PARTITION BY client_name ORDER BY month))
        * 100.0 / NULLIF(LAG(monthly_price_czk) OVER (PARTITION BY client_name ORDER BY month), 0), 1
    )                                                                       AS revenue_growth_pct
FROM monthly_per_client
ORDER BY client_name, month;


-- ============================================================
-- 2. DAILY DOCUMENT VOLUME (heatmap data)
-- ============================================================
SELECT
    c.name                  AS client_name,
    DATE(r.created_at)      AS day,
    COUNT(r.record_id)      AS records_created
FROM record r
INNER JOIN client c ON r.client_id = c.client_id
WHERE r.is_deleted = false
  AND (r.state_id >= 18 OR r.state_id = 12)
GROUP BY c.name, DATE(r.created_at)
ORDER BY day, client_name;


-- ============================================================
-- 3. CLIENT REVENUE TREND (line chart — one line per client)
-- ============================================================
SELECT
    c.name                              AS client_name,
    DATE_TRUNC('month', r.created_at)   AS month,
    COUNT(r.record_id)                  AS records_created,
    GREATEST(2990,
        CASE
            WHEN COUNT(r.record_id) <= 500  THEN COUNT(r.record_id) * 10
            WHEN COUNT(r.record_id) <= 1000 THEN 5000  + (COUNT(r.record_id) - 500)  * 9
            WHEN COUNT(r.record_id) <= 1500 THEN 9500  + (COUNT(r.record_id) - 1000) * 8
            WHEN COUNT(r.record_id) <= 2000 THEN 13500 + (COUNT(r.record_id) - 1500) * 7
            WHEN COUNT(r.record_id) <= 3000 THEN 17000 + (COUNT(r.record_id) - 2000) * 6
            WHEN COUNT(r.record_id) <= 5000 THEN 23000 + (COUNT(r.record_id) - 3000) * 5
            ELSE NULL
        END
    )                                   AS monthly_price_czk
FROM record r
INNER JOIN client c ON r.client_id = c.client_id
WHERE r.is_deleted = false
  AND (r.state_id >= 18 OR r.state_id = 12)
GROUP BY c.name, DATE_TRUNC('month', r.created_at)
ORDER BY month, client_name;


-- ============================================================
-- 4. STATE DISTRIBUTION PER CLIENT
-- ============================================================
SELECT
    c.name          AS client_name,
    r.state_id,
    COUNT(*)        AS record_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY c.name), 1) AS pct_of_client
FROM record r
INNER JOIN client c ON r.client_id = c.client_id
WHERE r.is_deleted = false
GROUP BY c.name, r.state_id
ORDER BY c.name, r.state_id;


-- ============================================================
-- 5. HARVEST JOB EFFICIENCY PER CLIENT
-- ============================================================
SELECT
    c.name                                          AS client_name,
    COUNT(DISTINCT r.job_harvest_id)                AS jobs_harvested,
    COUNT(r.record_id)                              AS records_created,
    ROUND(COUNT(r.record_id)::numeric /
          NULLIF(COUNT(DISTINCT r.job_harvest_id), 0), 1) AS records_per_job
FROM record r
INNER JOIN client c ON r.client_id = c.client_id
WHERE r.is_deleted = false
  AND (r.state_id >= 18 OR r.state_id = 12)
GROUP BY c.name
ORDER BY records_per_job DESC;


-- ============================================================
-- 6. CUMULATIVE REVENUE OVER THE YEAR (YTD line chart)
-- ============================================================
WITH monthly_revenue AS (
    SELECT
        DATE_TRUNC('month', r.created_at)   AS month,
        SUM(
            GREATEST(2990,
                CASE
                    WHEN COUNT(r.record_id) OVER (PARTITION BY c.client_id, DATE_TRUNC('month', r.created_at)) <= 500
                        THEN COUNT(r.record_id) OVER (PARTITION BY c.client_id, DATE_TRUNC('month', r.created_at)) * 10
                    ELSE NULL -- handled in outer query
                END
            )
        )                                   AS monthly_total_czk
    FROM record r
    INNER JOIN client c ON r.client_id = c.client_id
    WHERE r.is_deleted = false
      AND (r.state_id >= 18 OR r.state_id = 12)
    GROUP BY DATE_TRUNC('month', r.created_at)
),
per_client_month AS (
    SELECT
        c.name                              AS client_name,
        DATE_TRUNC('month', r.created_at)   AS month,
        GREATEST(2990,
            CASE
                WHEN COUNT(r.record_id) <= 500  THEN COUNT(r.record_id) * 10
                WHEN COUNT(r.record_id) <= 1000 THEN 5000  + (COUNT(r.record_id) - 500)  * 9
                WHEN COUNT(r.record_id) <= 1500 THEN 9500  + (COUNT(r.record_id) - 1000) * 8
                WHEN COUNT(r.record_id) <= 2000 THEN 13500 + (COUNT(r.record_id) - 1500) * 7
                WHEN COUNT(r.record_id) <= 3000 THEN 17000 + (COUNT(r.record_id) - 2000) * 6
                WHEN COUNT(r.record_id) <= 5000 THEN 23000 + (COUNT(r.record_id) - 3000) * 5
                ELSE NULL
            END
        )                                   AS monthly_price_czk
    FROM record r
    INNER JOIN client c ON r.client_id = c.client_id
    WHERE r.is_deleted = false
      AND (r.state_id >= 18 OR r.state_id = 12)
    GROUP BY c.name, DATE_TRUNC('month', r.created_at)
),
monthly_totals AS (
    SELECT
        month,
        SUM(monthly_price_czk)  AS monthly_revenue_czk
    FROM per_client_month
    GROUP BY month
)
SELECT
    month,
    monthly_revenue_czk,
    SUM(monthly_revenue_czk) OVER (ORDER BY month) AS cumulative_revenue_czk
FROM monthly_totals
ORDER BY month;


-- ============================================================
-- 7. TIER DISTRIBUTION PER CLIENT PER MONTH
-- ============================================================
WITH per_client_month AS (
    SELECT
        c.name                              AS client_name,
        DATE_TRUNC('month', r.created_at)   AS month,
        COUNT(r.record_id)                  AS records_created
    FROM record r
    INNER JOIN client c ON r.client_id = c.client_id
    WHERE r.is_deleted = false
      AND (r.state_id >= 18 OR r.state_id = 12)
    GROUP BY c.name, DATE_TRUNC('month', r.created_at)
)
SELECT
    client_name,
    month,
    records_created,
    CASE
        WHEN records_created <= 500  THEN '0–500 (10 Kč)'
        WHEN records_created <= 1000 THEN '501–1000 (9 Kč)'
        WHEN records_created <= 1500 THEN '1001–1500 (8 Kč)'
        WHEN records_created <= 2000 THEN '1501–2000 (7 Kč)'
        WHEN records_created <= 3000 THEN '2001–3000 (6 Kč)'
        WHEN records_created <= 5000 THEN '3001–5000 (5 Kč)'
        ELSE '5000+ (custom)'
    END AS pricing_tier
FROM per_client_month
ORDER BY month, records_created DESC;


-- ============================================================
-- 8. TOP CLIENTS BY VOLUME — PARETO (80/20)
-- ============================================================
WITH per_client AS (
    SELECT
        c.name              AS client_name,
        COUNT(r.record_id)  AS records_created
    FROM record r
    INNER JOIN client c ON r.client_id = c.client_id
    WHERE r.is_deleted = false
      AND (r.state_id >= 18 OR r.state_id = 12)
    GROUP BY c.name
),
ranked AS (
    SELECT
        client_name,
        records_created,
        RANK() OVER (ORDER BY records_created DESC)             AS rank,
        ROUND(records_created * 100.0 / SUM(records_created) OVER (), 1) AS pct_of_total,
        ROUND(SUM(records_created) OVER (ORDER BY records_created DESC)
            * 100.0 / SUM(records_created) OVER (), 1)         AS cumulative_pct
    FROM per_client
)
SELECT
    rank,
    client_name,
    records_created,
    pct_of_total,
    cumulative_pct
FROM ranked
ORDER BY rank;

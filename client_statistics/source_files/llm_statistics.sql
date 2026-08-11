-- LLM Usage Statistics
-- Pricing: Input €2.101/1M, Output €8.41/1M tokens
-- Link: llm_usage.record_id → record.record_id → client.client_id

-- ============================================================
-- 1. LLM COST PER CLIENT PER MONTH
-- ============================================================
WITH cost_per_call AS (
    SELECT
        lu.record_id,
        lu.invoked_at,
        lu.prompt_tokens,
        lu.completion_tokens,
        lu.total_tokens,
        lu.elapsed_time_seconds,
        lu.model_name,
        (lu.prompt_tokens     * 2.101  / 1000000.0 +
         lu.completion_tokens * 8.41   / 1000000.0) AS cost_eur
    FROM llm_usage lu
)
SELECT
    c.name                                      AS client_name,
    DATE_TRUNC('month', cpc.invoked_at)         AS month,
    COUNT(DISTINCT r.record_id)                 AS records_processed,
    COUNT(cpc.record_id)                        AS llm_calls,
    SUM(cpc.prompt_tokens)                      AS total_prompt_tokens,
    SUM(cpc.completion_tokens)                  AS total_completion_tokens,
    SUM(cpc.total_tokens)                       AS total_tokens,
    ROUND(SUM(cpc.cost_eur)::numeric, 4)        AS total_cost_eur
FROM cost_per_call cpc
INNER JOIN record r   ON cpc.record_id = r.record_id
INNER JOIN client c   ON r.client_id   = c.client_id
GROUP BY c.name, DATE_TRUNC('month', cpc.invoked_at)
ORDER BY month DESC, total_cost_eur DESC;


-- ============================================================
-- 2. AVERAGE PROCESSING TIME PER CLIENT
-- ============================================================
SELECT
    c.name                                              AS client_name,
    COUNT(DISTINCT r.record_id)                         AS records_processed,
    ROUND(AVG(lu.elapsed_time_seconds)::numeric, 2)     AS avg_elapsed_sec,
    ROUND(MIN(lu.elapsed_time_seconds)::numeric, 2)     AS min_elapsed_sec,
    ROUND(MAX(lu.elapsed_time_seconds)::numeric, 2)     AS max_elapsed_sec,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (
        ORDER BY lu.elapsed_time_seconds
    )::numeric, 2)                                      AS p95_elapsed_sec
FROM llm_usage lu
INNER JOIN record r ON lu.record_id = r.record_id
INNER JOIN client c ON r.client_id  = c.client_id
GROUP BY c.name
ORDER BY avg_elapsed_sec DESC;


-- ============================================================
-- 3. TOKEN EFFICIENCY RATIO PER CLIENT
-- (low ratio = model reads a lot, writes little)
-- ============================================================
SELECT
    c.name                                                          AS client_name,
    SUM(lu.prompt_tokens)                                           AS total_prompt_tokens,
    SUM(lu.completion_tokens)                                       AS total_completion_tokens,
    ROUND((SUM(lu.completion_tokens)::numeric /
           NULLIF(SUM(lu.prompt_tokens), 0) * 100), 2)             AS completion_pct,
    ROUND((SUM(lu.prompt_tokens)     * 2.101 / 1000000.0 +
           SUM(lu.completion_tokens) * 8.41  / 1000000.0)::numeric, 4) AS total_cost_eur
FROM llm_usage lu
INNER JOIN record r ON lu.record_id = r.record_id
INNER JOIN client c ON r.client_id  = c.client_id
GROUP BY c.name
ORDER BY total_cost_eur DESC;


-- ============================================================
-- 4. LLM CALLS PER RECORD PER CLIENT
-- (> 1 means multi-turn / retry logic triggered)
-- ============================================================
SELECT
    c.name                                                  AS client_name,
    COUNT(DISTINCT r.record_id)                             AS records,
    COUNT(lu.usage_id)                                      AS llm_calls,
    ROUND(COUNT(lu.usage_id)::numeric /
          NULLIF(COUNT(DISTINCT r.record_id), 0), 2)        AS calls_per_record
FROM llm_usage lu
INNER JOIN record r ON lu.record_id = r.record_id
INNER JOIN client c ON r.client_id  = c.client_id
GROUP BY c.name
ORDER BY calls_per_record DESC;


-- ============================================================
-- 5. MODEL USAGE OVER TIME
-- ============================================================
SELECT
    DATE_TRUNC('month', lu.invoked_at)              AS month,
    lu.model_name,
    COUNT(lu.usage_id)                              AS llm_calls,
    SUM(lu.total_tokens)                            AS total_tokens,
    ROUND(AVG(lu.elapsed_time_seconds)::numeric, 2) AS avg_elapsed_sec,
    ROUND((SUM(lu.prompt_tokens)     * 2.101 / 1000000.0 +
           SUM(lu.completion_tokens) * 8.41  / 1000000.0)::numeric, 4) AS total_cost_eur
FROM llm_usage lu
GROUP BY DATE_TRUNC('month', lu.invoked_at), lu.model_name
ORDER BY month DESC, llm_calls DESC;


-- ============================================================
-- 6. DAILY PROCESSING VOLUME (heatmap data)
-- ============================================================
SELECT
    DATE(lu.invoked_at)     AS day,
    COUNT(lu.usage_id)      AS llm_calls,
    COUNT(DISTINCT lu.record_id) AS records_processed,
    SUM(lu.total_tokens)    AS total_tokens,
    ROUND((SUM(lu.prompt_tokens)     * 2.101 / 1000000.0 +
           SUM(lu.completion_tokens) * 8.41  / 1000000.0)::numeric, 4) AS cost_eur
FROM llm_usage lu
GROUP BY DATE(lu.invoked_at)
ORDER BY day;


-- ============================================================
-- 7. SLOWEST RECORDS (TOP 50)
-- ============================================================
SELECT
    c.name                          AS client_name,
    lu.record_id,
    lu.elapsed_time_seconds,
    lu.total_tokens,
    lu.model_name,
    DATE(lu.invoked_at)             AS date,
    ROUND((lu.prompt_tokens     * 2.101 / 1000000.0 +
           lu.completion_tokens * 8.41  / 1000000.0)::numeric, 6) AS cost_eur
FROM llm_usage lu
INNER JOIN record r ON lu.record_id = r.record_id
INNER JOIN client c ON r.client_id  = c.client_id
ORDER BY lu.elapsed_time_seconds DESC
LIMIT 50;


-- ============================================================
-- 8. MONTHLY COST TREND (all clients combined)
-- ============================================================
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', lu.invoked_at)  AS month,
        SUM(lu.prompt_tokens)               AS prompt_tokens,
        SUM(lu.completion_tokens)           AS completion_tokens,
        SUM(lu.total_tokens)                AS total_tokens,
        COUNT(lu.usage_id)                  AS llm_calls,
        ROUND((SUM(lu.prompt_tokens)     * 2.101 / 1000000.0 +
               SUM(lu.completion_tokens) * 8.41  / 1000000.0)::numeric, 4) AS cost_eur
    FROM llm_usage lu
    GROUP BY DATE_TRUNC('month', lu.invoked_at)
)
SELECT
    month,
    prompt_tokens,
    completion_tokens,
    total_tokens,
    llm_calls,
    cost_eur,
    ROUND(SUM(cost_eur) OVER (ORDER BY month)::numeric, 4) AS cumulative_cost_eur
FROM monthly
ORDER BY month;

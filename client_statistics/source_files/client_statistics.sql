WITH per_client AS (
    SELECT
        c.name AS client_name,
        COUNT(DISTINCT r.job_harvest_id) AS jobs_harvested,
        COUNT(r.record_id) AS records_created,
        GREATEST(2990,
            CASE
                WHEN COUNT(r.record_id) <= 500  THEN COUNT(r.record_id) * 10
                WHEN COUNT(r.record_id) <= 1000 THEN 5000 + (COUNT(r.record_id) - 500) * 9
                WHEN COUNT(r.record_id) <= 1500 THEN 9500 + (COUNT(r.record_id) - 1000) * 8
                WHEN COUNT(r.record_id) <= 2000 THEN 13500 + (COUNT(r.record_id) - 1500) * 7
                WHEN COUNT(r.record_id) <= 3000 THEN 17000 + (COUNT(r.record_id) - 2000) * 6
                WHEN COUNT(r.record_id) <= 5000 THEN 23000 + (COUNT(r.record_id) - 3000) * 5
                ELSE NULL -- custom pricing (5000+ documents)
            END
        ) AS monthly_price_czk
    FROM
        record r
            INNER JOIN client c ON r.client_id = c.client_id
    WHERE
        (r.state_id >= 18
            or r.state_id = 12)
    -- (r.state_id < 18
    --     and r.state_id != 12)
    -- r.state_id >= 11
      AND
        r.is_deleted = false
      AND EXTRACT(YEAR FROM r.created_at) = 2026
      AND EXTRACT(MONTH FROM r.created_at) = 04
    GROUP BY
        c.name
)

SELECT * FROM per_client

UNION ALL

SELECT
    'ZZ TOTAL',
    SUM(jobs_harvested),
    SUM(records_created),
    SUM(monthly_price_czk)
FROM per_client

ORDER BY
    client_name;



-- ============================================================
-- Aquila — Monthly Billing Summary
-- ============================================================
-- Customer:      System Air (single tenant — no client table in the schema,
--                so the breakdown dimension is "user" + user_role)
-- Billing model: pay-as-you-go in EUR
--                  items_amount_eur  = billable_items * 0.035 EUR
--                  azure_fee_eur     = 650 EUR  (mandatory, per month, customer-wide)
--                  total_eur         = items_amount_eur + azure_fee_eur
--                  total_czk         = total_eur * eur_to_czk_rate
--                No tiers, no monthly minimum.
--
-- The Azure Cloud Infrastructure fee is ONE charge per MONTH for the whole
-- customer — it is never split across the per-user rows. Per-user rows below
-- carry item charges only; the fee is added once, as its own line.
--
-- BILLABLE ITEM (as supplied):
--     case_item.status_id IN (2 MATCHED, 4 MATCH_NOT_FOUND, 5 PAIRED)
--     attributed to a period by its parent "case".created_at
--     (case_item has no created_at — the parent case is the only time anchor)
--
-- Excluded by that definition: 1 CREATED (never processed), 3 NOT_MATCHED.
--
-- NOTE: the supplied billing query does not filter is_deleted on either table.
--       The `-- AND ... is_deleted = FALSE` lines below are kept commented out
--       so this file matches the agreed definition exactly; uncomment if
--       user-deleted items/cases should stop being billed.
--
-- NOTE: the invoice total is charged off the raw item count, not off the sum
--       of the per-user rounded amounts, so per-user rounding never leaks into
--       the total. The per-user rows may therefore differ from the subtotal by
--       a cent or two — the subtotal is the authoritative figure.
--
-- EXCLUDED ACCOUNTS: five internal/test user_ids are filtered out. The filter
--       is written as (c.user_id IS NULL OR c.user_id NOT IN (...)) because a
--       bare NOT IN would also drop cases with a NULL user_id (NULL NOT IN
--       yields NULL, not TRUE) — those are not on the exclusion list.
--
-- NOTE: CZK is derived from the ROUNDED EUR amount (the figure actually
--       invoiced), not from the raw product — so the notebook, this file and
--       the invoice all reconcile to the cent.
-- ============================================================

-- >>> Set the billing period, unit price, Azure fee and FX rate here <<<
WITH params AS (
    SELECT
        DATE '2026-07-01'   AS period_from,       -- inclusive
        DATE '2026-08-01'   AS period_to,         -- exclusive
        0.035::numeric      AS unit_price_eur,    -- EUR per billable item
        650::numeric        AS azure_fee_eur,     -- mandatory monthly infra fee
        25.0::numeric       AS eur_to_czk_rate    -- TODO: confirm contractual rate
),
billable AS (
    SELECT
        c.case_id,
        i.item_id,
        COALESCE(NULLIF(TRIM(u.first_name || ' ' || u.last_name), ''), u.email, '(unknown user)') AS user_name,
        COALESCE(ur.role_name, '(none)') AS role_name
    FROM case_item i
    INNER JOIN "case"    c  ON c.case_id = i.case_id
    LEFT  JOIN "user"    u  ON u.user_id = c.user_id
    LEFT  JOIN user_role ur ON ur.role_id = u.role_id
    CROSS JOIN params p
    WHERE i.status_id IN (2, 4, 5)
      AND c.created_at >= p.period_from
      AND c.created_at <  p.period_to
      AND (c.user_id IS NULL OR c.user_id NOT IN (
              '88bcefe9-b2c8-44de-ba8b-49853f9b0d3b',
              'a997e479-9df4-44de-a9ef-bc10ce8376f7',
              '0954b909-1130-4f94-af06-00193783ce31',
              '5b9f2bbf-f5bf-4df0-a007-653e8c6a34e9',
              '0e862f6c-3661-46d5-a951-28b2f7d39ca2'))
    --   AND i.is_deleted = FALSE
    --   AND c.is_deleted = FALSE
),
per_user AS (
    SELECT
        b.user_name,
        b.role_name,
        COUNT(DISTINCT b.case_id)                          AS cases,
        COUNT(b.item_id)                                   AS billable_items,
        ROUND(COUNT(b.item_id) * p.unit_price_eur, 2)      AS amount_eur,
        ROUND(ROUND(COUNT(b.item_id) * p.unit_price_eur, 2)
              * p.eur_to_czk_rate, 2)                      AS amount_czk
    FROM billable b
    CROSS JOIN params p
    GROUP BY b.user_name, b.role_name, p.unit_price_eur, p.eur_to_czk_rate
),
totals AS (
    SELECT
        SUM(cases)          AS cases,
        SUM(billable_items) AS billable_items
    FROM per_user
)
SELECT user_name, role_name, cases, billable_items, amount_eur, amount_czk
FROM per_user

UNION ALL

-- Item charges, computed off the raw item count (not the sum of rounded rows)
SELECT
    'ZZ SUBTOTAL (items)', '', t.cases, t.billable_items,
    ROUND(t.billable_items * p.unit_price_eur, 2),
    ROUND(ROUND(t.billable_items * p.unit_price_eur, 2) * p.eur_to_czk_rate, 2)
FROM totals t CROSS JOIN params p

UNION ALL

-- Mandatory Azure Cloud Infrastructure fee — once per month, customer-wide
SELECT
    'ZZ AZURE INFRA FEE', '', NULL, NULL,
    ROUND(p.azure_fee_eur, 2),
    ROUND(p.azure_fee_eur * p.eur_to_czk_rate, 2)
FROM params p

UNION ALL

SELECT
    'ZZ TOTAL', '', t.cases, t.billable_items,
    ROUND(t.billable_items * p.unit_price_eur + p.azure_fee_eur, 2),
    ROUND(ROUND(t.billable_items * p.unit_price_eur + p.azure_fee_eur, 2) * p.eur_to_czk_rate, 2)
FROM totals t CROSS JOIN params p

ORDER BY user_name;

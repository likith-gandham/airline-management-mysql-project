-- =====================================================================
-- File: 06_advanced_queries.sql
-- The analytical core of the project. Organized into four groups:
--   A. Recursive CTEs — graph traversal over the route network
--   B. Window functions — ranking, running totals, trend detection
--   C. JSON queries — reading the fare_rules demand curves directly
--   D. Cohort / customer-value analysis — non-recursive CTEs
-- =====================================================================
USE skylink_airlines;

-- =======================================================================
-- A. RECURSIVE CTEs
-- =======================================================================

-- ---------------------------------------------------------------------
-- A1. All airports reachable from ORD within 2 connections, with the
-- path taken and cumulative distance. This is genuine graph traversal
-- (BFS-style) expressed purely in SQL — the kind of query a real
-- airline's route-planning system runs constantly.
-- ---------------------------------------------------------------------
WITH RECURSIVE reachable_airports AS (
    -- Anchor: direct routes from ORD
    SELECT
        r.destination_airport AS airport,
        1 AS hops,
        CAST(CONCAT('ORD -> ', r.destination_airport) AS CHAR(200)) AS path,
        r.distance_km AS total_distance
    FROM routes r
    WHERE r.origin_airport = 'ORD'

    UNION ALL

    -- Recursive step: one more hop from any airport already reached,
    -- capped at 2 hops and forbidden from revisiting an airport already
    -- in the path (prevents infinite loops on a cyclic graph).
    SELECT
        r.destination_airport,
        ra.hops + 1,
        CAST(CONCAT(ra.path, ' -> ', r.destination_airport) AS CHAR(200)),
        ra.total_distance + r.distance_km
    FROM reachable_airports ra
    JOIN routes r ON ra.airport = r.origin_airport
    WHERE ra.hops < 2
      AND r.destination_airport <> 'ORD'
      AND NOT FIND_IN_SET(r.destination_airport, REPLACE(ra.path, ' -> ', ','))
)
SELECT airport, hops, path, total_distance
FROM reachable_airports
ORDER BY hops, total_distance;

-- ---------------------------------------------------------------------
-- A2. Practical connecting-flight finder: valid 1-stop itineraries from
-- LAX to LHR where the layover is between 1-6 hours (a real
-- constraint — too short risks a missed connection, too long is a poor
-- passenger experience). This mirrors what Amadeus/Sabre-style booking
-- engines compute on every search.
-- ---------------------------------------------------------------------
WITH RECURSIVE connections AS (
    SELECT
        f1.flight_id AS leg1_flight_id,
        f1.flight_number AS leg1_number,
        r1.origin_airport AS origin,
        r1.destination_airport AS layover_airport,
        f1.departure_datetime AS leg1_departure,
        f1.arrival_datetime AS leg1_arrival,
        1 AS legs
    FROM flights f1
    JOIN routes r1 ON f1.route_id = r1.route_id
    WHERE r1.origin_airport = 'LAX'
      AND f1.status = 'Scheduled'
),
one_stop AS (
    SELECT
        c.leg1_flight_id, c.leg1_number, c.origin, c.layover_airport,
        c.leg1_departure, c.leg1_arrival,
        f2.flight_id AS leg2_flight_id,
        f2.flight_number AS leg2_number,
        r2.destination_airport AS final_destination,
        f2.departure_datetime AS leg2_departure,
        f2.arrival_datetime AS leg2_arrival,
        TIMESTAMPDIFF(MINUTE, c.leg1_arrival, f2.departure_datetime) AS layover_minutes
    FROM connections c
    JOIN routes r2 ON r2.origin_airport = c.layover_airport
    JOIN flights f2 ON f2.route_id = r2.route_id AND f2.status = 'Scheduled'
    WHERE r2.destination_airport = 'LHR'
      AND f2.departure_datetime > c.leg1_arrival
)
SELECT
    leg1_number, origin, layover_airport, leg1_departure, leg1_arrival,
    leg2_number, final_destination, leg2_departure, leg2_arrival,
    layover_minutes,
    ROUND(layover_minutes / 60.0, 1) AS layover_hours
FROM one_stop
WHERE layover_minutes BETWEEN 60 AND 360
ORDER BY leg1_departure;

-- =======================================================================
-- B. WINDOW FUNCTIONS
-- =======================================================================

-- ---------------------------------------------------------------------
-- B1. Rank flights by revenue within their own route (DENSE_RANK),
-- so you can see, per route, which specific departure is the top earner.
-- ---------------------------------------------------------------------
SELECT
    route,
    flight_number,
    departure_datetime,
    flight_revenue,
    DENSE_RANK() OVER (PARTITION BY route ORDER BY flight_revenue DESC) AS revenue_rank_in_route
FROM (
    SELECT
        CONCAT(r.origin_airport, ' -> ', r.destination_airport) AS route,
        f.flight_number,
        f.departure_datetime,
        COALESCE(SUM(b.price_paid), 0) AS flight_revenue
    FROM flights f
    JOIN routes r ON f.route_id = r.route_id
    LEFT JOIN bookings b ON f.flight_id = b.flight_id AND b.status = 'Confirmed'
    GROUP BY route, f.flight_number, f.departure_datetime
) revenue_per_flight
ORDER BY route, revenue_rank_in_route;

-- ---------------------------------------------------------------------
-- B2. Day-over-day price movement per flight using LAG() — shows the
-- dynamic pricing engine's effect over time, price increase/decrease,
-- and percent change since the previous recorded price point.
-- ---------------------------------------------------------------------
SELECT
    flight_id,
    recorded_at,
    old_price,
    new_price,
    LAG(new_price) OVER (PARTITION BY flight_id ORDER BY recorded_at) AS previous_price,
    new_price - LAG(new_price) OVER (PARTITION BY flight_id ORDER BY recorded_at) AS price_change,
    ROUND(
        (new_price - LAG(new_price) OVER (PARTITION BY flight_id ORDER BY recorded_at))
        / LAG(new_price) OVER (PARTITION BY flight_id ORDER BY recorded_at) * 100, 2
    ) AS pct_change
FROM price_history
ORDER BY flight_id, recorded_at;

-- ---------------------------------------------------------------------
-- B3. Running total of daily revenue, plus a 3-day moving average —
-- classic time-series analytics expressed with window frames.
-- ---------------------------------------------------------------------
SELECT
    booking_date,
    daily_revenue,
    SUM(daily_revenue) OVER (ORDER BY booking_date ROWS UNBOUNDED PRECEDING) AS running_total_revenue,
    ROUND(AVG(daily_revenue) OVER (ORDER BY booking_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS moving_avg_3day
FROM (
    SELECT DATE(booking_datetime) AS booking_date, SUM(price_paid) AS daily_revenue
    FROM bookings
    WHERE status = 'Confirmed'
    GROUP BY DATE(booking_datetime)
) daily
ORDER BY booking_date;

-- ---------------------------------------------------------------------
-- B4. Passenger value segmentation with NTILE(4) — splits all
-- passengers into revenue quartiles, a simple but genuinely useful
-- segmentation technique for targeted marketing.
-- ---------------------------------------------------------------------
SELECT
    passenger_id,
    full_name,
    lifetime_spend,
    NTILE(4) OVER (ORDER BY lifetime_spend DESC) AS spend_quartile
FROM (
    SELECT p.passenger_id, p.full_name, COALESCE(SUM(b.price_paid), 0) AS lifetime_spend
    FROM passengers p
    LEFT JOIN bookings b ON p.passenger_id = b.passenger_id AND b.status = 'Confirmed'
    GROUP BY p.passenger_id, p.full_name
) passenger_spend
ORDER BY spend_quartile, lifetime_spend DESC;

-- =======================================================================
-- C. JSON QUERIES
-- =======================================================================

-- ---------------------------------------------------------------------
-- C1. Extract each class's demand curve directly from the JSON column
-- and flatten it into rows — demonstrates JSON_TABLE, the modern
-- SQL/JSON standard way to shred a JSON array into relational rows.
-- ---------------------------------------------------------------------
SELECT
    fr.seat_class,
    fr.class_multiplier,
    jt_thresholds.threshold,
    jt.multiplier
FROM fare_rules fr,
     JSON_TABLE(
        fr.demand_curve,
        '$.occupancy_thresholds[*]' COLUMNS (
            idx FOR ORDINALITY,
            threshold DECIMAL(4,2) PATH '$'
        )
     ) AS jt_thresholds,
     JSON_TABLE(
        fr.demand_curve,
        '$.price_multipliers[*]' COLUMNS (
            idx2 FOR ORDINALITY,
            multiplier DECIMAL(4,2) PATH '$'
        )
     ) AS jt
WHERE jt_thresholds.idx = jt.idx2
ORDER BY fr.seat_class, jt_thresholds.threshold;

-- ---------------------------------------------------------------------
-- C2. Simple JSON_EXTRACT usage: pull just specific values per class
-- without JSON_TABLE, for comparison. (Written with JSON_UNQUOTE +
-- JSON_EXTRACT rather than the -> / ->> shorthand operators, since the
-- shorthand is not available on every MySQL/MariaDB build — this form
-- is universally portable.)
-- ---------------------------------------------------------------------
SELECT
    seat_class,
    class_multiplier,
    JSON_UNQUOTE(JSON_EXTRACT(demand_curve, '$.occupancy_thresholds[0]')) AS first_threshold,
    JSON_UNQUOTE(JSON_EXTRACT(demand_curve, '$.price_multipliers[2]'))    AS highest_multiplier
FROM fare_rules;

-- =======================================================================
-- D. COHORT / CUSTOMER-VALUE ANALYSIS (non-recursive CTEs)
-- =======================================================================

-- ---------------------------------------------------------------------
-- D1. Customer lifetime value ranked with running contribution to total
-- revenue — identifies how much of total revenue the top N passengers
-- represent (classic Pareto / 80-20 analysis).
-- ---------------------------------------------------------------------
WITH passenger_ltv AS (
    SELECT
        p.passenger_id,
        p.full_name,
        p.loyalty_tier,
        COALESCE(SUM(b.price_paid), 0) AS lifetime_value
    FROM passengers p
    LEFT JOIN bookings b ON p.passenger_id = b.passenger_id AND b.status = 'Confirmed'
    GROUP BY p.passenger_id, p.full_name, p.loyalty_tier
),
ranked AS (
    SELECT
        *,
        RANK() OVER (ORDER BY lifetime_value DESC) AS value_rank,
        SUM(lifetime_value) OVER (ORDER BY lifetime_value DESC ROWS UNBOUNDED PRECEDING) AS cumulative_value,
        SUM(lifetime_value) OVER () AS total_value
    FROM passenger_ltv
)
SELECT
    value_rank, full_name, loyalty_tier, lifetime_value,
    ROUND(cumulative_value / total_value * 100, 1) AS cumulative_pct_of_revenue
FROM ranked
ORDER BY value_rank;

-- ---------------------------------------------------------------------
-- D2. Signup-month cohort analysis: for each cohort (month a passenger
-- signed up), how many are still booking, and their average spend.
-- ---------------------------------------------------------------------
WITH cohorts AS (
    SELECT
        passenger_id,
        DATE_FORMAT(signup_date, '%Y-%m') AS cohort_month
    FROM passengers
),
cohort_activity AS (
    SELECT
        c.cohort_month,
        COUNT(DISTINCT c.passenger_id) AS cohort_size,
        COUNT(DISTINCT b.passenger_id) AS active_bookers,
        COALESCE(SUM(b.price_paid), 0) AS cohort_revenue
    FROM cohorts c
    LEFT JOIN bookings b ON c.passenger_id = b.passenger_id AND b.status = 'Confirmed'
    GROUP BY c.cohort_month
)
SELECT
    cohort_month,
    cohort_size,
    active_bookers,
    ROUND(active_bookers / cohort_size * 100, 1) AS pct_active,
    cohort_revenue,
    ROUND(cohort_revenue / cohort_size, 2) AS revenue_per_signup
FROM cohort_activity
ORDER BY cohort_month;

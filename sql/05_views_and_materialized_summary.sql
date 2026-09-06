-- =====================================================================
-- File: 05_views_and_materialized_summary.sql
-- Three reporting views, plus a materialized-view substitute: MySQL/
-- MariaDB have no native MATERIALIZED VIEW, so the standard real-world
-- pattern is a summary table refreshed on a schedule via the EVENT
-- scheduler — implemented here exactly as a DBA would in production.
-- =====================================================================
USE skylink_airlines;

-- ---------------------------------------------------------------------
-- VIEW: v_flight_occupancy
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_flight_occupancy AS
SELECT
    f.flight_id,
    f.flight_number,
    CONCAT(r.origin_airport, ' -> ', r.destination_airport) AS route,
    f.departure_datetime,
    a.total_capacity,
    COUNT(CASE WHEN s.status = 'Booked' THEN 1 END) AS seats_booked,
    ROUND(COUNT(CASE WHEN s.status = 'Booked' THEN 1 END) / a.total_capacity * 100, 1) AS occupancy_pct,
    f.current_price
FROM flights f
JOIN routes r   ON f.route_id = r.route_id
JOIN aircraft a ON f.aircraft_id = a.aircraft_id
LEFT JOIN seats s ON f.flight_id = s.flight_id
GROUP BY f.flight_id, f.flight_number, route, f.departure_datetime, a.total_capacity, f.current_price;

-- ---------------------------------------------------------------------
-- VIEW: v_revenue_by_route
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_revenue_by_route AS
SELECT
    CONCAT(r.origin_airport, ' -> ', r.destination_airport) AS route,
    COUNT(DISTINCT f.flight_id) AS flights_operated,
    COUNT(b.booking_id) AS total_bookings,
    SUM(b.price_paid) AS total_revenue,
    ROUND(AVG(b.price_paid), 2) AS avg_price_paid
FROM routes r
JOIN flights f ON r.route_id = f.route_id
LEFT JOIN bookings b ON f.flight_id = b.flight_id AND b.status = 'Confirmed'
GROUP BY route
ORDER BY total_revenue DESC;

-- ---------------------------------------------------------------------
-- VIEW: v_passenger_loyalty_summary
-- Deliberately excludes passport_number/phone (PII) — this view is
-- what the analyst_role (see 07_security_and_roles.sql) is granted
-- access to instead of the raw passengers table.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_passenger_loyalty_summary AS
SELECT
    p.passenger_id,
    p.loyalty_tier,
    p.loyalty_points,
    COUNT(b.booking_id) AS total_bookings,
    COALESCE(SUM(b.price_paid), 0) AS lifetime_spend
FROM passengers p
LEFT JOIN bookings b ON p.passenger_id = b.passenger_id AND b.status = 'Confirmed'
GROUP BY p.passenger_id, p.loyalty_tier, p.loyalty_points;

-- ---------------------------------------------------------------------
-- "MATERIALIZED VIEW" — mv_daily_revenue_summary is refreshed by this
-- procedure, which the EVENT below calls automatically every night.
-- Reporting dashboards should query the summary table, NOT recompute
-- SUM(price_paid) live across all bookings every time — this is the
-- textbook reason materialized views/summary tables exist.
-- ---------------------------------------------------------------------
DELIMITER $$
CREATE PROCEDURE refresh_daily_revenue_summary()
BEGIN
    REPLACE INTO mv_daily_revenue_summary (summary_date, total_bookings, total_revenue, avg_price_paid, last_refreshed)
    SELECT
        DATE(booking_datetime),
        COUNT(*),
        SUM(price_paid),
        ROUND(AVG(price_paid), 2),
        NOW()
    FROM bookings
    WHERE status = 'Confirmed'
    GROUP BY DATE(booking_datetime);
END$$
DELIMITER ;

-- Run once immediately so the summary table isn't empty before the
-- first scheduled refresh fires.
CALL refresh_daily_revenue_summary();

-- Enable the event scheduler and register the nightly refresh. In a
-- real deployment this is set in my.cnf (event_scheduler=ON); enabling
-- it here at the session/global level makes the demo self-contained.
SET GLOBAL event_scheduler = ON;

CREATE EVENT IF NOT EXISTS ev_refresh_daily_revenue
ON SCHEDULE EVERY 1 DAY
STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 2 HOUR)
DO
    CALL refresh_daily_revenue_summary();

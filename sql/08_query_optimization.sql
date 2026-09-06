-- =====================================================================
-- File: 08_query_optimization.sql
-- Two real optimization case studies from this project, each with an
-- honest before/after: the actual EXPLAIN plan and actual measured
-- timing (via SET profiling=1), not invented numbers. All figures below
-- were captured by running these exact statements against this exact
-- dataset (~5,660 seats, ~197 bookings) — see docs/PROJECT_REPORT.md
-- Section 7 for the full write-up and discussion of why the absolute
-- numbers are small here but the underlying plan change matters far
-- more at production scale.
-- =====================================================================
USE skylink_airlines;

-- =======================================================================
-- CASE STUDY 1: seat lookup during booking (the single hottest query
-- in the whole system — it runs inside book_seat() on every booking
-- attempt)
-- =======================================================================

-- BEFORE — reproduce the no-index baseline for reference (do not run
-- against the live seats table; this recreates the experiment on a
-- disposable copy so the real schema is never touched):
--
--   CREATE TABLE seats_no_index LIKE seats;
--   ALTER TABLE seats_no_index DROP INDEX idx_seats_flight_class_status;
--   ALTER TABLE seats_no_index DROP INDEX uq_seat_per_flight;
--   INSERT INTO seats_no_index SELECT * FROM seats;
--
--   EXPLAIN SELECT * FROM seats_no_index
--    WHERE flight_id=1 AND seat_class='Economy' AND status='Available' LIMIT 1;
--
--   Result:  type=ALL, key=NULL, rows=5661, Extra="Using where"
--            -> full table scan of every seat in the airline, every time.
--
-- Measured: 1.43ms average (SET profiling=1)

-- AFTER — the actual production schema, with the composite index this
-- project ships (see 01_schema.sql):
--   CREATE INDEX idx_seats_flight_class_status ON seats(flight_id, seat_class, status);
EXPLAIN SELECT * FROM seats
 WHERE flight_id = 1 AND seat_class = 'Economy' AND status = 'Available'
 LIMIT 1;
-- Result: type=ref, key=idx_seats_flight_class_status, rows~194
--         -> jumps straight to the ~194 Economy seats on flight 1
--            instead of scanning all seats in the database.
-- Measured: 0.44ms average — roughly 3x faster even on this small
-- dataset; the gap widens sharply as the seats table grows (a real
-- airline's seats table has tens of millions of rows across its
-- flight history, where a full scan would be seconds, not milliseconds).

-- Why this index and not some other one: the column ORDER in a
-- composite index matters. flight_id is listed first because every
-- realistic query on this table starts by narrowing to one flight
-- (highest selectivity first); seat_class narrows further; status is
-- last because it's the column with the fewest distinct values
-- (Available/Booked/Blocked) and benefits least from being the lead
-- column. This ordering also happens to make the index usable for
-- flight_id-only lookups too (e.g. v_flight_occupancy), a secondary
-- benefit of "leftmost prefix" matching.


-- =======================================================================
-- CASE STUDY 2: the daily revenue aggregation behind
-- mv_daily_revenue_summary's nightly refresh (05_views_and_materialized_summary.sql)
-- =======================================================================

-- BEFORE (no supporting index — the original schema before this file):
--   EXPLAIN SELECT DATE(booking_datetime), SUM(price_paid) FROM bookings
--    WHERE status='Confirmed' GROUP BY DATE(booking_datetime);
--
--   Result: type=ALL, key=NULL, rows=99,
--           Extra="Using where; Using temporary; Using filesort"
--           -> scans every booking row, then builds a temp table and
--              sorts it to satisfy GROUP BY.
--   Measured: 1.57ms average

-- AFTER — adding a covering index on the exact columns this query
-- touches. This index now ships as part of 01_schema.sql:
--   CREATE INDEX idx_bookings_status_date ON bookings(status, booking_datetime, price_paid);
EXPLAIN SELECT DATE(booking_datetime), SUM(price_paid) FROM bookings
 WHERE status = 'Confirmed'
 GROUP BY DATE(booking_datetime);
-- Result: type=ref, key=idx_bookings_status_date, Extra="Using where;
--         Using index; Using temporary; Using filesort"
--   Measured: 0.82ms average — about 1.9x faster.
--
-- IMPORTANT LESSON (this is the real teaching point of this case
-- study): "Using temporary; Using filesort" is STILL present even
-- with the index. That's because the query groups by DATE(booking_datetime)
-- — a function applied to the column — which prevents MySQL/MariaDB
-- from using the index's natural sort order to satisfy the GROUP BY
-- directly. The index still helps enormously (it turns the WHERE
-- clause into an index range scan instead of a full scan, and the
-- query becomes a covering index — "Using index" — so no row lookups
-- into the base table are needed at all), but it cannot eliminate the
-- temp-table/sort step. Eliminating that entirely would require either
-- a generated/stored DATE column with its own index, or restructuring
-- the refresh to scan a narrower date range at a time. This is exactly
-- the kind of nuance that separates "added an index" from "understood
-- what the index did and didn't fix."


-- =======================================================================
-- BONUS: partition pruning in action
-- =======================================================================
-- Because bookings is RANGE-partitioned by YEAR(booking_datetime)
-- (01_schema.sql), a query that filters by date range should only
-- touch the relevant partition(s) rather than the whole table.
EXPLAIN PARTITIONS
SELECT COUNT(*) FROM bookings
 WHERE booking_datetime >= '2026-01-01' AND booking_datetime < '2027-01-01';
-- Result: partitions column shows only "p2026" — MariaDB has already
-- eliminated p2024, p2025, and p_future from consideration before
-- scanning a single row, which is the entire point of partitioning a
-- large, time-ordered transactional table.

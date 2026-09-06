-- =====================================================================
-- SKYLINK AIRLINES — Flight Reservation, Dynamic Pricing & Revenue
-- Management System
-- File: 01_schema.sql
-- Engine: MariaDB 10.11 / MySQL 8.0+
-- =====================================================================

DROP DATABASE IF EXISTS skylink_airlines;
CREATE DATABASE skylink_airlines CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE skylink_airlines;

-- ---------------------------------------------------------------------
-- 1. AIRPORTS  (nodes of the route graph; full-text search enabled)
-- ---------------------------------------------------------------------
CREATE TABLE airports (
    airport_code    CHAR(3) PRIMARY KEY,              -- IATA code, e.g. 'ORD'
    airport_name    VARCHAR(120) NOT NULL,
    city            VARCHAR(80)  NOT NULL,
    country         VARCHAR(80)  NOT NULL,
    timezone        VARCHAR(40)  NOT NULL,
    FULLTEXT KEY ft_airport_search (airport_name, city, country)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2. AIRCRAFT  (fleet, defines seat layout capacity per class)
-- ---------------------------------------------------------------------
CREATE TABLE aircraft (
    aircraft_id       INT AUTO_INCREMENT PRIMARY KEY,
    model             VARCHAR(60) NOT NULL,
    manufacturer      VARCHAR(60) NOT NULL,
    economy_seats     SMALLINT UNSIGNED NOT NULL,
    premium_seats     SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    business_seats    SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    first_seats       SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    total_capacity    SMALLINT UNSIGNED GENERATED ALWAYS AS
                        (economy_seats + premium_seats + business_seats + first_seats) STORED
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. ROUTES  (directed edges of the airport graph — used for recursive
--    CTE connection-finding later)
-- ---------------------------------------------------------------------
CREATE TABLE routes (
    route_id          INT AUTO_INCREMENT PRIMARY KEY,
    origin_airport     CHAR(3) NOT NULL,
    destination_airport CHAR(3) NOT NULL,
    distance_km       INT NOT NULL,
    avg_flight_minutes SMALLINT NOT NULL,
    CONSTRAINT fk_route_origin FOREIGN KEY (origin_airport) REFERENCES airports(airport_code),
    CONSTRAINT fk_route_dest   FOREIGN KEY (destination_airport) REFERENCES airports(airport_code),
    CONSTRAINT chk_route_not_self CHECK (origin_airport <> destination_airport),
    CONSTRAINT uq_route UNIQUE (origin_airport, destination_airport)
) ENGINE=InnoDB;

CREATE INDEX idx_routes_origin ON routes(origin_airport);
CREATE INDEX idx_routes_dest   ON routes(destination_airport);

-- ---------------------------------------------------------------------
-- 4. CREW
-- ---------------------------------------------------------------------
CREATE TABLE crew (
    crew_id     INT AUTO_INCREMENT PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL,
    role        ENUM('Captain','First Officer','Purser','Flight Attendant') NOT NULL,
    hire_date   DATE NOT NULL
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 5. FLIGHTS
-- ---------------------------------------------------------------------
CREATE TABLE flights (
    flight_id          INT AUTO_INCREMENT PRIMARY KEY,
    flight_number      VARCHAR(10) NOT NULL,
    route_id           INT NOT NULL,
    aircraft_id        INT NOT NULL,
    departure_datetime DATETIME NOT NULL,
    arrival_datetime   DATETIME NOT NULL,
    base_price         DECIMAL(10,2) NOT NULL,
    current_price      DECIMAL(10,2) NOT NULL,
    status             ENUM('Scheduled','Boarding','Departed','Arrived','Cancelled') NOT NULL DEFAULT 'Scheduled',
    CONSTRAINT fk_flight_route    FOREIGN KEY (route_id) REFERENCES routes(route_id),
    CONSTRAINT fk_flight_aircraft FOREIGN KEY (aircraft_id) REFERENCES aircraft(aircraft_id),
    CONSTRAINT chk_flight_times CHECK (arrival_datetime > departure_datetime)
) ENGINE=InnoDB;

CREATE INDEX idx_flights_route_date ON flights(route_id, departure_datetime);
CREATE INDEX idx_flights_departure  ON flights(departure_datetime);

-- ---------------------------------------------------------------------
-- 6. FLIGHT_CREW  (junction table, M:N)
-- ---------------------------------------------------------------------
CREATE TABLE flight_crew (
    flight_id INT NOT NULL,
    crew_id   INT NOT NULL,
    PRIMARY KEY (flight_id, crew_id),
    CONSTRAINT fk_fc_flight FOREIGN KEY (flight_id) REFERENCES flights(flight_id) ON DELETE CASCADE,
    CONSTRAINT fk_fc_crew   FOREIGN KEY (crew_id) REFERENCES crew(crew_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 7. SEATS  (generated per-flight by a stored procedure, not by hand)
-- ---------------------------------------------------------------------
CREATE TABLE seats (
    seat_id     BIGINT AUTO_INCREMENT PRIMARY KEY,
    flight_id   INT NOT NULL,
    seat_number VARCHAR(5) NOT NULL,
    seat_class  ENUM('Economy','Premium','Business','First') NOT NULL,
    status      ENUM('Available','Booked','Blocked') NOT NULL DEFAULT 'Available',
    CONSTRAINT fk_seat_flight FOREIGN KEY (flight_id) REFERENCES flights(flight_id) ON DELETE CASCADE,
    CONSTRAINT uq_seat_per_flight UNIQUE (flight_id, seat_number)
) ENGINE=InnoDB;

-- This composite index is the single most important index in the schema:
-- book_seat() filters on exactly these three columns to find a free seat.
CREATE INDEX idx_seats_flight_class_status ON seats(flight_id, seat_class, status);

-- ---------------------------------------------------------------------
-- 8. PASSENGERS
-- ---------------------------------------------------------------------
CREATE TABLE passengers (
    passenger_id     INT AUTO_INCREMENT PRIMARY KEY,
    full_name        VARCHAR(100) NOT NULL,
    email            VARCHAR(120) NOT NULL UNIQUE,
    phone            VARCHAR(20),
    passport_number  VARCHAR(20) NOT NULL UNIQUE,
    loyalty_tier     ENUM('Standard','Silver','Gold','Platinum') NOT NULL DEFAULT 'Standard',
    loyalty_points   INT NOT NULL DEFAULT 0,
    signup_date      DATE NOT NULL DEFAULT (CURRENT_DATE)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 9. FARE_RULES  (JSON column: per-class demand-pricing multipliers)
-- ---------------------------------------------------------------------
CREATE TABLE fare_rules (
    fare_rule_id   INT AUTO_INCREMENT PRIMARY KEY,
    seat_class     ENUM('Economy','Premium','Business','First') NOT NULL UNIQUE,
    class_multiplier DECIMAL(4,2) NOT NULL,
    demand_curve   JSON NOT NULL
    -- demand_curve example:
    -- {"occupancy_thresholds": [0.5, 0.75, 0.9], "price_multipliers": [1.0, 1.15, 1.35]}
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 10. BOOKINGS  (RANGE-partitioned by year — demonstrates partitioning
--     on a large, ever-growing transactional table)
-- ---------------------------------------------------------------------
-- NOTE ON DESIGN TRADE-OFF: MySQL/MariaDB InnoDB does not allow a
-- partitioned table to carry FOREIGN KEY constraints (or to be the
-- target of one). Since bookings is intentionally partitioned by year
-- for scalability, referential integrity to passengers/flights/seats
-- is enforced procedurally instead (see 03_functions_and_procedures.sql,
-- book_seat() and cancel_booking()) and defensively by the
-- trg_bookings_before_insert trigger in 04_triggers.sql. This is the
-- standard, documented trade-off any DBA makes when partitioning a
-- transactional fact table — see docs/PROJECT_REPORT.md Section 4.
CREATE TABLE bookings (
    booking_id       BIGINT AUTO_INCREMENT,
    passenger_id     INT NOT NULL,
    flight_id        INT NOT NULL,
    seat_id          BIGINT NOT NULL,
    booking_datetime DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status           ENUM('Confirmed','Cancelled','Refunded') NOT NULL DEFAULT 'Confirmed',
    price_paid       DECIMAL(10,2) NOT NULL,
    payment_method   ENUM('Card','Wallet','BankTransfer','LoyaltyPoints') NOT NULL,
    PRIMARY KEY (booking_id, booking_datetime)
) ENGINE=InnoDB
  PARTITION BY RANGE (YEAR(booking_datetime)) (
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026),
    PARTITION p2026 VALUES LESS THAN (2027),
    PARTITION p_future VALUES LESS THAN MAXVALUE
);

CREATE INDEX idx_bookings_passenger ON bookings(passenger_id);
CREATE INDEX idx_bookings_flight    ON bookings(flight_id);
-- Covering index for the daily-revenue aggregation behind
-- mv_daily_revenue_summary — see 08_query_optimization.sql Case Study 2
-- for the EXPLAIN/timing evidence behind this specific column order.
CREATE INDEX idx_bookings_status_date ON bookings(status, booking_datetime, price_paid);

-- ---------------------------------------------------------------------
-- 11. BOOKING_AUDIT_LOG  (populated entirely by triggers — never by
--     application code — so it can be trusted as a tamper-evident trail)
-- ---------------------------------------------------------------------
CREATE TABLE booking_audit_log (
    log_id        BIGINT AUTO_INCREMENT PRIMARY KEY,
    booking_id    BIGINT NOT NULL,
    action        ENUM('INSERT','UPDATE','DELETE') NOT NULL,
    old_status    VARCHAR(20),
    new_status    VARCHAR(20),
    changed_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    changed_by    VARCHAR(100) NOT NULL DEFAULT (CURRENT_USER())
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 12. PRICE_HISTORY  (populated by trigger whenever flights.current_price
--     changes — powers the LAG/LEAD pricing-trend queries later)
-- ---------------------------------------------------------------------
CREATE TABLE price_history (
    price_history_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    flight_id         INT NOT NULL,
    old_price         DECIMAL(10,2),
    new_price         DECIMAL(10,2) NOT NULL,
    recorded_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_ph_flight FOREIGN KEY (flight_id) REFERENCES flights(flight_id)
) ENGINE=InnoDB;

CREATE INDEX idx_price_history_flight_time ON price_history(flight_id, recorded_at);

-- ---------------------------------------------------------------------
-- 13. LOYALTY_TRANSACTIONS  (points ledger — every award/redemption
--     is its own row, never an in-place balance update, so the
--     ledger can always be replayed/audited)
-- ---------------------------------------------------------------------
CREATE TABLE loyalty_transactions (
    txn_id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    passenger_id      INT NOT NULL,
    points            INT NOT NULL,             -- positive = earned, negative = redeemed
    txn_type          ENUM('Earn','Redeem','Adjustment') NOT NULL,
    related_booking_id BIGINT,
    txn_datetime      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_loyalty_passenger FOREIGN KEY (passenger_id) REFERENCES passengers(passenger_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 14. MV_DAILY_REVENUE_SUMMARY  (a "materialized view" — MariaDB/MySQL
--     have no native MATERIALIZED VIEW, so a real summary table
--     refreshed by a scheduled EVENT is the standard substitute)
-- ---------------------------------------------------------------------
CREATE TABLE mv_daily_revenue_summary (
    summary_date   DATE PRIMARY KEY,
    total_bookings INT NOT NULL,
    total_revenue  DECIMAL(12,2) NOT NULL,
    avg_price_paid DECIMAL(10,2) NOT NULL,
    last_refreshed DATETIME NOT NULL
) ENGINE=InnoDB;

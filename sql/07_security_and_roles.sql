-- =====================================================================
-- File: 07_security_and_roles.sql
-- Role-based access control built on the principle of least privilege.
-- Three roles, each granted only what that job function actually needs
-- — none of them get blanket access to the base tables.
-- =====================================================================
USE skylink_airlines;

-- ---------------------------------------------------------------------
-- OPERATIONAL NOTE (found during testing of this very script): a fresh
-- MySQL/MariaDB install often ships with anonymous accounts
-- (''@'localhost') left over from initialization. Because the server's
-- account-matching algorithm checks literal hostnames before wildcard
-- ('%') hosts, an anonymous ''@'localhost' account silently intercepts
-- every login attempted from localhost — including logins for named
-- users like 'agent_jsmith' — before their own '%'-host grant is ever
-- consulted, producing a confusing "Access denied" for the RIGHT
-- username with the WRONG credentials check. Always remove these
-- first on a new instance (this is exactly what mysql_secure_installation
-- automates):
--   DROP USER IF EXISTS ''@'localhost';
--   DROP USER IF EXISTS ''@'%';
-- ---------------------------------------------------------------------
DROP USER IF EXISTS ''@'localhost';

-- ---------------------------------------------------------------------
-- ROLE 1: booking_agent
-- A front-desk/call-center agent needs to search flights and create or
-- cancel bookings — but should NEVER be able to directly UPDATE a
-- seat's status or a booking's price by hand (that would bypass the
-- dynamic pricing engine and the audit trail entirely). So this role
-- gets SELECT on read-only reference/search tables, and EXECUTE on the
-- procedures — nothing else. All writes happen only through the
-- transaction-safe procedures.
-- ---------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS booking_agent;
GRANT SELECT ON skylink_airlines.flights        TO booking_agent;
GRANT SELECT ON skylink_airlines.routes         TO booking_agent;
GRANT SELECT ON skylink_airlines.airports       TO booking_agent;
GRANT SELECT ON skylink_airlines.seats          TO booking_agent;
GRANT SELECT ON skylink_airlines.v_flight_occupancy TO booking_agent;
GRANT EXECUTE ON PROCEDURE skylink_airlines.book_seat      TO booking_agent;
GRANT EXECUTE ON PROCEDURE skylink_airlines.cancel_booking TO booking_agent;

-- ---------------------------------------------------------------------
-- ROLE 2: data_analyst
-- Needs broad read access for reporting — but passenger PII (passport
-- numbers, phone numbers, email) is off-limits. The analyst gets the
-- aggregated/anonymized views instead of the raw passengers table,
-- plus read access to operational tables needed for revenue analysis.
-- ---------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS data_analyst;
GRANT SELECT ON skylink_airlines.v_flight_occupancy         TO data_analyst;
GRANT SELECT ON skylink_airlines.v_revenue_by_route          TO data_analyst;
GRANT SELECT ON skylink_airlines.v_passenger_loyalty_summary TO data_analyst;
GRANT SELECT ON skylink_airlines.mv_daily_revenue_summary    TO data_analyst;
GRANT SELECT ON skylink_airlines.bookings       TO data_analyst;
GRANT SELECT ON skylink_airlines.flights        TO data_analyst;
GRANT SELECT ON skylink_airlines.routes         TO data_analyst;
GRANT SELECT ON skylink_airlines.price_history  TO data_analyst;
-- Deliberately NOT granted: SELECT on passengers (contains passport
-- numbers, phone, email — PII). The analyst works from
-- v_passenger_loyalty_summary instead, which exposes only
-- loyalty_tier, points, and spend.

-- ---------------------------------------------------------------------
-- ROLE 3: db_admin
-- Full administrative access — schema changes, all data, all
-- procedures. Reserved for the DBA account only.
-- ---------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS db_admin;
GRANT ALL PRIVILEGES ON skylink_airlines.* TO db_admin;

-- ---------------------------------------------------------------------
-- Example accounts (passwords are placeholders — rotate before any
-- real deployment). Each is granted exactly one role, demonstrating
-- role-based rather than per-user privilege management.
-- ---------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'agent_jsmith'@'%'   IDENTIFIED BY 'ChangeMe_Agent!1';
CREATE USER IF NOT EXISTS 'analyst_rpatel'@'%' IDENTIFIED BY 'ChangeMe_Analyst!1';
CREATE USER IF NOT EXISTS 'dba_admin'@'%'      IDENTIFIED BY 'ChangeMe_Admin!1';

GRANT booking_agent TO 'agent_jsmith'@'%';
GRANT data_analyst  TO 'analyst_rpatel'@'%';
GRANT db_admin      TO 'dba_admin'@'%';

SET DEFAULT ROLE booking_agent FOR 'agent_jsmith'@'%';
SET DEFAULT ROLE data_analyst  FOR 'analyst_rpatel'@'%';
SET DEFAULT ROLE db_admin      FOR 'dba_admin'@'%';

FLUSH PRIVILEGES;

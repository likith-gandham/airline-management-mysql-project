-- =====================================================================
-- File: 04_triggers.sql
-- Four triggers, each demonstrating a distinct classic use case:
--   1. Defense-in-depth overbooking prevention (BEFORE INSERT)
--   2. Tamper-evident audit trail (AFTER INSERT/UPDATE)
--   3. Automatic price-change history (AFTER UPDATE)
--   4. Business-rule automation: loyalty points + tier upgrades (AFTER INSERT)
-- =====================================================================
USE skylink_airlines;

DELIMITER $$

-- ---------------------------------------------------------------------
-- 1. Defense-in-depth: the procedure locks the seat row with
-- SELECT ... FOR UPDATE and leaves its status as 'Available' up until
-- the booking row itself is inserted — this trigger is what actually
-- flips the seat to 'Booked', and refuses the insert outright if the
-- seat isn't 'Available' at that instant. This protects the table's
-- integrity even against a buggy or malicious direct INSERT that
-- bypasses the stored procedure entirely.
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_bookings_before_insert
BEFORE INSERT ON bookings
FOR EACH ROW
BEGIN
    DECLARE v_seat_status VARCHAR(20);
    SELECT status INTO v_seat_status FROM seats WHERE seat_id = NEW.seat_id;
    IF NEW.status = 'Confirmed' AND v_seat_status <> 'Available' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Overbooking blocked: seat is not available.';
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 1b. The trigger that actually owns the Available -> Booked transition,
-- so there is exactly one code path (this trigger) that can ever mark
-- a seat Booked — not the application, not the procedure.
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_bookings_mark_seat_booked
AFTER INSERT ON bookings
FOR EACH ROW
BEGIN
    IF NEW.status = 'Confirmed' THEN
        UPDATE seats SET status = 'Booked' WHERE seat_id = NEW.seat_id;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 2. Audit trail — every INSERT/UPDATE to bookings is logged
-- automatically. Nothing about this depends on application code
-- remembering to log; it is structurally guaranteed.
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_bookings_audit_insert
AFTER INSERT ON bookings
FOR EACH ROW
BEGIN
    INSERT INTO booking_audit_log (booking_id, action, old_status, new_status)
    VALUES (NEW.booking_id, 'INSERT', NULL, NEW.status);
END$$

CREATE TRIGGER trg_bookings_audit_update
AFTER UPDATE ON bookings
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO booking_audit_log (booking_id, action, old_status, new_status)
        VALUES (NEW.booking_id, 'UPDATE', OLD.status, NEW.status);
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 3. Price history — whenever a flight's current_price changes for
-- any reason, the change is captured automatically. This is what
-- powers the LAG()/LEAD() pricing-trend analysis in 06_advanced_queries.sql.
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_flights_price_change
AFTER UPDATE ON flights
FOR EACH ROW
BEGIN
    IF OLD.current_price <> NEW.current_price THEN
        INSERT INTO price_history (flight_id, old_price, new_price)
        VALUES (NEW.flight_id, OLD.current_price, NEW.current_price);
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 4. Loyalty automation — 1 point per whole dollar spent, awarded the
-- instant a booking is confirmed, plus an automatic tier upgrade once
-- a passenger crosses a points threshold. This demonstrates embedding
-- a real business rule directly in the data layer so it can never be
-- "forgotten" by a client application.
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_bookings_award_loyalty
AFTER INSERT ON bookings
FOR EACH ROW
BEGIN
    DECLARE v_points INT;
    IF NEW.status = 'Confirmed' THEN
        SET v_points = FLOOR(NEW.price_paid);

        INSERT INTO loyalty_transactions (passenger_id, points, txn_type, related_booking_id)
        VALUES (NEW.passenger_id, v_points, 'Earn', NEW.booking_id);

        UPDATE passengers
           SET loyalty_points = loyalty_points + v_points
         WHERE passenger_id = NEW.passenger_id;

        UPDATE passengers
           SET loyalty_tier = CASE
                WHEN loyalty_points >= 50000 THEN 'Platinum'
                WHEN loyalty_points >= 20000 THEN 'Gold'
                WHEN loyalty_points >= 5000  THEN 'Silver'
                ELSE 'Standard'
           END
         WHERE passenger_id = NEW.passenger_id;
    END IF;
END$$

DELIMITER ;

-- =====================================================================
-- File: 03_functions_and_procedures.sql
-- The heart of the system: transaction-safe booking (prevents double
-- booking under concurrency via SELECT ... FOR UPDATE), a dynamic
-- pricing engine driven by the fare_rules JSON demand curve, and
-- supporting procedures.
-- =====================================================================
USE skylink_airlines;

DELIMITER $$

-- ---------------------------------------------------------------------
-- PROCEDURE: generate_seats_for_flight
-- Populates the seats table for one flight based on its aircraft's
-- class layout. Idempotent: safe to call twice (skips if seats exist).
-- ---------------------------------------------------------------------
CREATE PROCEDURE generate_seats_for_flight(IN p_flight_id INT)
BEGIN
    DECLARE v_economy SMALLINT; DECLARE v_premium SMALLINT;
    DECLARE v_business SMALLINT; DECLARE v_first SMALLINT;
    DECLARE v_existing INT;
    DECLARE v_row INT DEFAULT 0;
    DECLARE v_seat_num INT;
    DECLARE v_letter CHAR(1);

    SELECT COUNT(*) INTO v_existing FROM seats WHERE flight_id = p_flight_id;
    IF v_existing = 0 THEN
        SELECT a.economy_seats, a.premium_seats, a.business_seats, a.first_seats
          INTO v_economy, v_premium, v_business, v_first
          FROM flights f JOIN aircraft a ON f.aircraft_id = a.aircraft_id
         WHERE f.flight_id = p_flight_id;

        -- First class rows (2 seats per row: A, F)
        SET v_seat_num = 0;
        WHILE v_seat_num < v_first DO
            SET v_row = v_row + 1;
            SET v_letter = IF(v_seat_num % 2 = 0, 'A', 'F');
            INSERT INTO seats (flight_id, seat_number, seat_class)
                VALUES (p_flight_id, CONCAT(v_row, v_letter), 'First');
            SET v_seat_num = v_seat_num + 1;
        END WHILE;

        -- Business rows (4 seats per row: A,C,D,F)
        SET v_seat_num = 0;
        WHILE v_seat_num < v_business DO
            IF v_seat_num % 4 = 0 THEN SET v_row = v_row + 1; END IF;
            SET v_letter = ELT((v_seat_num % 4) + 1, 'A', 'C', 'D', 'F');
            INSERT INTO seats (flight_id, seat_number, seat_class)
                VALUES (p_flight_id, CONCAT(v_row, v_letter), 'Business');
            SET v_seat_num = v_seat_num + 1;
        END WHILE;

        -- Premium rows (6 seats per row: A,B,C,D,E,F)
        SET v_seat_num = 0;
        WHILE v_seat_num < v_premium DO
            IF v_seat_num % 6 = 0 THEN SET v_row = v_row + 1; END IF;
            SET v_letter = ELT((v_seat_num % 6) + 1, 'A','B','C','D','E','F');
            INSERT INTO seats (flight_id, seat_number, seat_class)
                VALUES (p_flight_id, CONCAT(v_row, v_letter), 'Premium');
            SET v_seat_num = v_seat_num + 1;
        END WHILE;

        -- Economy rows (6 seats per row: A,B,C,D,E,F)
        SET v_seat_num = 0;
        WHILE v_seat_num < v_economy DO
            IF v_seat_num % 6 = 0 THEN SET v_row = v_row + 1; END IF;
            SET v_letter = ELT((v_seat_num % 6) + 1, 'A','B','C','D','E','F');
            INSERT INTO seats (flight_id, seat_number, seat_class)
                VALUES (p_flight_id, CONCAT(v_row, v_letter), 'Economy');
            SET v_seat_num = v_seat_num + 1;
        END WHILE;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- FUNCTION: calculate_dynamic_price
-- Reads fare_rules.demand_curve (JSON) for the given class, compares
-- current occupancy % against the thresholds, and returns the price
-- after applying the matching multiplier plus a last-minute-booking
-- surcharge (the closer to departure, the higher the surcharge, capped
-- at 20%). This is the pricing model referenced throughout the report.
-- ---------------------------------------------------------------------
CREATE FUNCTION calculate_dynamic_price(p_flight_id INT, p_seat_class VARCHAR(20))
RETURNS DECIMAL(10,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_base_price DECIMAL(10,2);
    DECLARE v_total_of_class INT;
    DECLARE v_booked_of_class INT;
    DECLARE v_occupancy DECIMAL(5,4);
    DECLARE v_multiplier DECIMAL(4,2);
    DECLARE v_demand_curve JSON;
    DECLARE v_days_to_departure INT;
    DECLARE v_time_surcharge DECIMAL(4,3);
    DECLARE v_final_price DECIMAL(10,2);
    DECLARE v_idx INT DEFAULT 0;
    DECLARE v_threshold DECIMAL(5,2);
    DECLARE v_curve_len INT;

    SELECT f.base_price, DATEDIFF(f.departure_datetime, NOW())
      INTO v_base_price, v_days_to_departure
      FROM flights f WHERE f.flight_id = p_flight_id;

    SELECT COUNT(*) INTO v_total_of_class
      FROM seats WHERE flight_id = p_flight_id AND seat_class = p_seat_class;

    SELECT COUNT(*) INTO v_booked_of_class
      FROM seats WHERE flight_id = p_flight_id AND seat_class = p_seat_class AND status = 'Booked';

    SET v_occupancy = IF(v_total_of_class = 0, 0, v_booked_of_class / v_total_of_class);

    SELECT class_multiplier, demand_curve INTO v_multiplier, v_demand_curve
      FROM fare_rules WHERE seat_class = p_seat_class;

    -- Walk the occupancy_thresholds array; use the highest multiplier
    -- whose threshold the current occupancy has crossed.
    SET v_curve_len = JSON_LENGTH(JSON_EXTRACT(v_demand_curve, '$.occupancy_thresholds'));
    SET v_multiplier = JSON_EXTRACT(v_demand_curve, '$.price_multipliers[0]') + 0.0;
    WHILE v_idx < v_curve_len DO
        SET v_threshold = JSON_EXTRACT(v_demand_curve, CONCAT('$.occupancy_thresholds[', v_idx, ']')) + 0.0;
        IF v_occupancy >= v_threshold THEN
            SET v_multiplier = JSON_EXTRACT(v_demand_curve, CONCAT('$.price_multipliers[', v_idx, ']')) + 0.0;
        END IF;
        SET v_idx = v_idx + 1;
    END WHILE;

    -- Last-minute surcharge: up to +20% as departure approaches, 0% at 30+ days out
    SET v_time_surcharge = CASE
        WHEN v_days_to_departure <= 1  THEN 0.20
        WHEN v_days_to_departure <= 3  THEN 0.12
        WHEN v_days_to_departure <= 7  THEN 0.06
        WHEN v_days_to_departure <= 14 THEN 0.02
        ELSE 0.00
    END;

    SELECT class_multiplier INTO @v_class_mult FROM fare_rules WHERE seat_class = p_seat_class;

    SET v_final_price = ROUND(v_base_price * @v_class_mult * v_multiplier * (1 + v_time_surcharge), 2);
    RETURN v_final_price;
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE: book_seat
-- The critical-path transaction. Uses SELECT ... FOR UPDATE to lock a
-- candidate seat row so two simultaneous booking attempts on the last
-- available seat of a class cannot both succeed (classic lost-update /
-- race condition, prevented here at the database layer rather than
-- trusted to the application). Wrapped in an error handler so any
-- failure rolls back cleanly and reports a message instead of a raw
-- SQL exception.
-- ---------------------------------------------------------------------
CREATE PROCEDURE book_seat(
    IN  p_passenger_id INT,
    IN  p_flight_id    INT,
    IN  p_seat_class   VARCHAR(20),
    IN  p_payment_method VARCHAR(20),
    OUT p_booking_id   BIGINT,
    OUT p_message      VARCHAR(200)
)
proc_body: BEGIN
    DECLARE v_seat_id BIGINT DEFAULT NULL;
    DECLARE v_price DECIMAL(10,2);
    DECLARE v_flight_status VARCHAR(20);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_booking_id = NULL;
        SET p_message = 'Booking failed due to an internal error; transaction rolled back.';
    END;

    START TRANSACTION;

    SELECT status INTO v_flight_status FROM flights WHERE flight_id = p_flight_id FOR UPDATE;
    IF v_flight_status IS NULL THEN
        ROLLBACK;
        SET p_booking_id = NULL; SET p_message = 'Flight does not exist.';
        LEAVE proc_body;
    ELSEIF v_flight_status IN ('Departed','Arrived','Cancelled') THEN
        ROLLBACK;
        SET p_booking_id = NULL; SET p_message = CONCAT('Cannot book: flight status is ', v_flight_status, '.');
        LEAVE proc_body;
    END IF;

    -- Lock exactly one available seat of the requested class so a
    -- concurrent transaction cannot select the same seat before we commit.
    SELECT seat_id INTO v_seat_id
      FROM seats
     WHERE flight_id = p_flight_id AND seat_class = p_seat_class AND status = 'Available'
     ORDER BY seat_id
     LIMIT 1
     FOR UPDATE;

    IF v_seat_id IS NULL THEN
        ROLLBACK;
        SET p_booking_id = NULL;
        SET p_message = CONCAT('No available ', p_seat_class, ' seats on this flight.');
        LEAVE proc_body;
    END IF;

    SET v_price = calculate_dynamic_price(p_flight_id, p_seat_class);

    -- Seat status transition (Available -> Booked) is owned entirely by
    -- trg_bookings_mark_seat_booked (see 04_triggers.sql) — the single
    -- code path allowed to make that change, so it can never drift out
    -- of sync with whether a Confirmed booking row actually exists.
    INSERT INTO bookings (passenger_id, flight_id, seat_id, status, price_paid, payment_method)
    VALUES (p_passenger_id, p_flight_id, v_seat_id, 'Confirmed', v_price, p_payment_method);

    SET p_booking_id = LAST_INSERT_ID();

    -- current_price is the flight's displayed "headline" fare — by
    -- airline industry convention that's always the Economy price,
    -- regardless of which class this particular booking was for.
    -- (Earlier draft mistakenly recalculated using whichever class was
    -- just booked, causing current_price to swing wildly between
    -- Economy-level and Business/First-level figures — see
    -- docs/PROJECT_REPORT.md Section 6 for this design note.)
    UPDATE flights SET current_price = calculate_dynamic_price(p_flight_id, 'Economy')
     WHERE flight_id = p_flight_id;

    COMMIT;
    SET p_message = CONCAT('Booking confirmed. Seat ',
        (SELECT seat_number FROM seats WHERE seat_id = v_seat_id),
        ' — price paid: $', v_price);
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE: cancel_booking
-- Frees the seat, marks the booking Cancelled, and refunds loyalty
-- points earned on that booking via a negative ledger entry (never
-- edits the original Earn row — the ledger is append-only).
-- ---------------------------------------------------------------------
CREATE PROCEDURE cancel_booking(
    IN  p_booking_id BIGINT,
    OUT p_message    VARCHAR(200)
)
proc_body: BEGIN
    DECLARE v_seat_id BIGINT;
    DECLARE v_status VARCHAR(20);
    DECLARE v_passenger_id INT;
    DECLARE v_points_awarded INT DEFAULT 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_message = 'Cancellation failed due to an internal error; transaction rolled back.';
    END;

    START TRANSACTION;

    SELECT seat_id, status, passenger_id INTO v_seat_id, v_status, v_passenger_id
      FROM bookings WHERE booking_id = p_booking_id
      FOR UPDATE;

    IF v_seat_id IS NULL THEN
        ROLLBACK; SET p_message = 'Booking not found.'; LEAVE proc_body;
    ELSEIF v_status <> 'Confirmed' THEN
        ROLLBACK; SET p_message = CONCAT('Booking is already ', v_status, '.'); LEAVE proc_body;
    END IF;

    UPDATE bookings SET status = 'Cancelled' WHERE booking_id = p_booking_id;
    UPDATE seats SET status = 'Available' WHERE seat_id = v_seat_id;

    SELECT COALESCE(SUM(points), 0) INTO v_points_awarded
      FROM loyalty_transactions WHERE related_booking_id = p_booking_id AND txn_type = 'Earn';

    IF v_points_awarded > 0 THEN
        INSERT INTO loyalty_transactions (passenger_id, points, txn_type, related_booking_id)
        VALUES (v_passenger_id, -v_points_awarded, 'Adjustment', p_booking_id);
        UPDATE passengers SET loyalty_points = loyalty_points - v_points_awarded
         WHERE passenger_id = v_passenger_id;
    END IF;

    COMMIT;
    SET p_message = 'Booking cancelled and seat released.';
END$$

DELIMITER ;

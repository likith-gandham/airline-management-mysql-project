-- =====================================================================
-- File: seed_bookings.sql  (helper — not part of the numbered sequence;
-- generates realistic booking activity so the analytics in
-- 06_advanced_queries.sql have real data to work on)
-- =====================================================================
USE skylink_airlines;

DELIMITER $$
CREATE PROCEDURE seed_bookings()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_passenger INT;
    DECLARE v_flight INT;
    DECLARE v_class VARCHAR(20);
    DECLARE v_bid BIGINT;
    DECLARE v_msg VARCHAR(200);
    DECLARE v_payment VARCHAR(20);

    WHILE i < 140 DO
        SET v_passenger = 1 + FLOOR(RAND() * 15);
        -- weight toward the earlier (near-term / already-flown) flights
        SET v_flight = 1 + FLOOR(RAND() * 18);
        SET v_class = ELT(1 + FLOOR(RAND() * 6), 'Economy','Economy','Economy','Premium','Business','First');
        SET v_payment = ELT(1 + FLOOR(RAND() * 4), 'Card','Wallet','BankTransfer','LoyaltyPoints');

        CALL book_seat(v_passenger, v_flight, v_class, v_payment, v_bid, v_msg);
        -- silently continue past "no seats available" — that's expected
        -- once a class fills up, exactly like a real booking system
        SET i = i + 1;
    END WHILE;
END$$
DELIMITER ;

CALL seed_bookings();
DROP PROCEDURE seed_bookings;

SELECT status, COUNT(*) FROM bookings GROUP BY status;

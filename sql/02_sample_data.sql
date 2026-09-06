-- =====================================================================
-- File: 02_sample_data.sql
-- Airports form a deliberate hub-and-spoke network (ORD and DXB as
-- hubs) so the recursive route-finding queries in 06 have real
-- multi-hop paths to discover.
-- =====================================================================
USE skylink_airlines;

-- ---------------------------------------------------------------------
-- AIRPORTS
-- ---------------------------------------------------------------------
INSERT INTO airports (airport_code, airport_name, city, country, timezone) VALUES
('ORD', 'O''Hare International Airport',        'Chicago',      'USA',            'America/Chicago'),
('JFK', 'John F. Kennedy International Airport','New York',     'USA',            'America/New_York'),
('LAX', 'Los Angeles International Airport',    'Los Angeles',  'USA',            'America/Los_Angeles'),
('ATL', 'Hartsfield-Jackson Airport',           'Atlanta',      'USA',            'America/New_York'),
('DFW', 'Dallas/Fort Worth International',      'Dallas',       'USA',            'America/Chicago'),
('SEA', 'Seattle-Tacoma International',         'Seattle',      'USA',            'America/Los_Angeles'),
('DXB', 'Dubai International Airport',          'Dubai',        'UAE',            'Asia/Dubai'),
('LHR', 'Heathrow Airport',                     'London',       'UK',             'Europe/London'),
('CDG', 'Charles de Gaulle Airport',            'Paris',        'France',         'Europe/Paris'),
('FRA', 'Frankfurt Airport',                    'Frankfurt',    'Germany',        'Europe/Berlin'),
('SIN', 'Singapore Changi Airport',             'Singapore',    'Singapore',      'Asia/Singapore'),
('HND', 'Haneda Airport',                       'Tokyo',        'Japan',          'Asia/Tokyo'),
('DEL', 'Indira Gandhi International',          'New Delhi',    'India',          'Asia/Kolkata'),
('SYD', 'Sydney Kingsford Smith Airport',       'Sydney',       'Australia',      'Australia/Sydney'),
('GRU', 'São Paulo/Guarulhos International',    'São Paulo',    'Brazil',         'America/Sao_Paulo');

-- ---------------------------------------------------------------------
-- AIRCRAFT
-- ---------------------------------------------------------------------
INSERT INTO aircraft (model, manufacturer, economy_seats, premium_seats, business_seats, first_seats) VALUES
('737 MAX 8',      'Boeing',   150, 0,  16, 0),
('A320neo',        'Airbus',   144, 0,  12, 0),
('787-9 Dreamliner','Boeing',  198, 21, 28, 0),
('A350-900',       'Airbus',   231, 24, 32, 0),
('777-300ER',      'Boeing',   200, 40, 42, 8),
('A380-800',       'Airbus',   300, 60, 76, 14);

-- ---------------------------------------------------------------------
-- ROUTES  (hub-and-spoke: ORD and DXB act as hubs, enabling multi-hop
-- itineraries e.g. LAX -> ORD -> LHR, or SYD -> DXB -> CDG)
-- ---------------------------------------------------------------------
INSERT INTO routes (origin_airport, destination_airport, distance_km, avg_flight_minutes) VALUES
('ORD','JFK', 1188, 145), ('JFK','ORD', 1188, 150),
('ORD','LAX', 2802, 250), ('LAX','ORD', 2802, 235),
('ORD','ATL', 975,  120), ('ATL','ORD', 975,  125),
('ORD','DFW', 1290, 150), ('DFW','ORD', 1290, 145),
('ORD','SEA', 2790, 245), ('SEA','ORD', 2790, 230),
('ORD','LHR', 6350, 490), ('LHR','ORD', 6350, 510),
('ORD','FRA', 7080, 520), ('FRA','ORD', 7080, 545),
('JFK','LHR', 5540, 420), ('LHR','JFK', 5540, 440),
('LAX','HND', 8815, 605), ('HND','LAX', 8815, 590),
('LAX','SYD', 12073,890), ('SYD','LAX', 12073,870),
('DXB','LHR', 5480, 425), ('LHR','DXB', 5480, 435),
('DXB','CDG', 5240, 410), ('CDG','DXB', 5240, 420),
('DXB','SIN', 5840, 435), ('SIN','DXB', 5840, 440),
('DXB','DEL', 2200, 210), ('DEL','DXB', 2200, 205),
('DXB','SYD', 12050,830), ('SYD','DXB', 12050,850),
('SIN','HND', 5320, 415), ('HND','SIN', 5320, 420),
('CDG','GRU', 9430, 680), ('GRU','CDG', 9430, 665),
('FRA','DEL', 6080, 460), ('DEL','FRA', 6080, 470);

-- ---------------------------------------------------------------------
-- CREW
-- ---------------------------------------------------------------------
INSERT INTO crew (full_name, role, hire_date) VALUES
('James Whitfield', 'Captain', '2011-03-14'),
('Priya Nandakumar', 'Captain', '2014-07-02'),
('Miguel Santos',    'First Officer', '2018-01-20'),
('Aiko Tanaka',      'First Officer', '2019-06-11'),
('Sophie Laurent',   'Purser', '2016-09-05'),
('Daniel Achebe',    'Flight Attendant', '2020-02-17'),
('Fatima Al-Sayed',  'Flight Attendant', '2021-05-23'),
('Chen Wei',         'Flight Attendant', '2017-11-30');

-- ---------------------------------------------------------------------
-- FARE_RULES  (JSON demand curve per class — read by calculate_dynamic_price)
-- ---------------------------------------------------------------------
INSERT INTO fare_rules (seat_class, class_multiplier, demand_curve) VALUES
('Economy',  1.00, JSON_OBJECT('occupancy_thresholds', JSON_ARRAY(0.5, 0.75, 0.9),
                                'price_multipliers',    JSON_ARRAY(1.00, 1.15, 1.35))),
('Premium',  1.60, JSON_OBJECT('occupancy_thresholds', JSON_ARRAY(0.5, 0.75, 0.9),
                                'price_multipliers',    JSON_ARRAY(1.00, 1.10, 1.25))),
('Business', 3.20, JSON_OBJECT('occupancy_thresholds', JSON_ARRAY(0.4, 0.7, 0.85),
                                'price_multipliers',    JSON_ARRAY(1.00, 1.20, 1.45))),
('First',    5.50, JSON_OBJECT('occupancy_thresholds', JSON_ARRAY(0.3, 0.6, 0.8),
                                'price_multipliers',    JSON_ARRAY(1.00, 1.25, 1.60)));

-- ---------------------------------------------------------------------
-- FLIGHTS  (a mix of past and upcoming, across several routes)
-- ---------------------------------------------------------------------
INSERT INTO flights (flight_number, route_id, aircraft_id, departure_datetime, arrival_datetime, base_price, current_price, status) VALUES
('SL101', 1,  3, '2026-09-10 08:00:00', '2026-09-10 10:25:00', 220.00, 220.00, 'Scheduled'),
('SL102', 2,  3, '2026-09-10 18:00:00', '2026-09-10 20:30:00', 220.00, 220.00, 'Scheduled'),
('SL201', 3,  4, '2026-09-11 07:00:00', '2026-09-11 09:10:00', 310.00, 310.00, 'Scheduled'),
('SL202', 4,  4, '2026-09-11 17:30:00', '2026-09-11 19:45:00', 310.00, 310.00, 'Scheduled'),
('SL301', 11, 5, '2026-09-12 21:00:00', '2026-09-13 13:10:00', 780.00, 780.00, 'Scheduled'),
('SL302', 12, 5, '2026-09-14 09:00:00', '2026-09-14 12:05:00', 820.00, 820.00, 'Scheduled'),
('SL401', 21, 6, '2026-09-12 22:30:00', '2026-09-13 07:35:00', 950.00, 950.00, 'Scheduled'),
('SL402', 22, 6, '2026-09-15 02:00:00', '2026-09-15 06:15:00', 900.00, 900.00, 'Scheduled'),
('SL501', 23, 5, '2026-09-13 15:00:00', '2026-09-13 21:50:00', 640.00, 640.00, 'Scheduled'),
('SL502', 24, 5, '2026-09-16 08:30:00', '2026-09-16 15:20:00', 610.00, 610.00, 'Scheduled'),
('SL601', 25, 3, '2026-09-13 04:00:00', '2026-09-13 07:35:00', 480.00, 480.00, 'Scheduled'),
('SL602', 26, 3, '2026-09-17 10:00:00', '2026-09-17 13:25:00', 470.00, 470.00, 'Scheduled'),
('SL701', 5,  1, '2026-09-10 06:30:00', '2026-09-10 08:30:00', 140.00, 140.00, 'Scheduled'),
('SL702', 6,  1, '2026-09-10 19:00:00', '2026-09-10 21:05:00', 140.00, 140.00, 'Scheduled'),
('SL801', 7,  2, '2026-08-20 08:00:00', '2026-08-20 10:30:00', 165.00, 165.00, 'Arrived'),
('SL802', 8,  2, '2026-08-20 18:00:00', '2026-08-20 20:25:00', 165.00, 165.00, 'Arrived'),
('SL901', 13, 4, '2026-08-15 20:00:00', '2026-08-16 07:20:00', 720.00, 720.00, 'Arrived'),
('SL902', 27, 4, '2026-08-18 12:00:00', '2026-08-18 19:15:00', 590.00, 590.00, 'Arrived'),
('SL111', 1,  3, '2026-09-25 08:00:00', '2026-09-25 10:25:00', 225.00, 225.00, 'Scheduled'),
('SL211', 3,  4, '2026-09-26 07:00:00', '2026-09-26 09:10:00', 315.00, 315.00, 'Scheduled'),
-- Deliberately timed to create a valid LAX -> ORD -> LHR one-stop
-- connection (see 06_advanced_queries.sql, query A2): arrives ORD at
-- 19:25 on 9/12, and SL301 (ORD -> LHR) departs 21:00 the same day —
-- a realistic ~1h35m layover.
('SL203', 4,  4, '2026-09-12 15:30:00', '2026-09-12 19:25:00', 300.00, 300.00, 'Scheduled');

-- ---------------------------------------------------------------------
-- FLIGHT_CREW  (a couple of crews assigned across flights)
-- ---------------------------------------------------------------------
INSERT INTO flight_crew (flight_id, crew_id) VALUES
(1,1),(1,3),(1,5),(1,6),
(2,2),(2,4),(2,7),(2,8),
(5,1),(5,3),(5,5),(5,6),(5,7),
(7,2),(7,4),(7,5),(7,8);

-- ---------------------------------------------------------------------
-- PASSENGERS
-- ---------------------------------------------------------------------
INSERT INTO passengers (full_name, email, phone, passport_number, loyalty_tier, loyalty_points, signup_date) VALUES
('Emily Carter',    'emily.carter@mail.com',    '3125550101', 'P10001', 'Gold',     18500, '2019-03-12'),
('Liam Johnson',    'liam.johnson@mail.com',    '3125550102', 'P10002', 'Standard', 1200,  '2024-06-01'),
('Olivia Brown',    'olivia.brown@mail.com',    '3125550103', 'P10003', 'Platinum', 42300, '2015-11-08'),
('Noah Davis',      'noah.davis@mail.com',      '3125550104', 'P10004', 'Silver',   6400,  '2021-02-19'),
('Ava Wilson',      'ava.wilson@mail.com',      '3125550105', 'P10005', 'Standard', 800,   '2025-01-05'),
('Ethan Martinez',  'ethan.martinez@mail.com',  '3125550106', 'P10006', 'Gold',     21000, '2018-07-22'),
('Sophia Anderson', 'sophia.anderson@mail.com', '3125550107', 'P10007', 'Standard', 300,   '2026-02-14'),
('Mason Taylor',    'mason.taylor@mail.com',    '3125550108', 'P10008', 'Silver',   5200,  '2022-05-30'),
('Isabella Thomas',  'isabella.thomas@mail.com','3125550109', 'P10009', 'Platinum', 55000, '2013-09-17'),
('Lucas Moore',     'lucas.moore@mail.com',     '3125550110', 'P10010', 'Standard', 950,   '2024-10-03'),
('Mia Jackson',     'mia.jackson@mail.com',     '3125550111', 'P10011', 'Gold',     19800, '2017-04-25'),
('Alexander White', 'alexander.white@mail.com', '3125550112', 'P10012', 'Standard', 400,   '2025-08-11'),
('Charlotte Harris','charlotte.harris@mail.com','3125550113', 'P10013', 'Silver',   7100,  '2020-12-01'),
('Benjamin Martin', 'benjamin.martin@mail.com', '3125550114', 'P10014', 'Standard', 150,   '2026-05-19'),
('Amelia Thompson', 'amelia.thompson@mail.com', '3125550115', 'P10015', 'Gold',     16700, '2019-08-08'),
-- Additional passengers with deliberately overlapping signup months so
-- the cohort analysis in 06_advanced_queries.sql (query D2) has real
-- multi-person cohorts to analyze, not one passenger per month.
('Grace Kim',       'grace.kim@mail.com',       '3125550116', 'P10016', 'Standard', 200,  '2025-01-20'),
('Henry Wu',        'henry.wu@mail.com',        '3125550117', 'P10017', 'Standard', 500,  '2025-01-28'),
('Ella Robinson',   'ella.robinson@mail.com',   '3125550118', 'P10018', 'Silver',   4800, '2024-06-15'),
('Jack Walker',     'jack.walker@mail.com',     '3125550119', 'P10019', 'Standard', 600,  '2024-06-22'),
('Zoe Hall',        'zoe.hall@mail.com',        '3125550120', 'P10020', 'Standard', 300,  '2024-10-10'),
('Leo Allen',       'leo.allen@mail.com',       '3125550121', 'P10021', 'Standard', 250,  '2024-10-18'),
('Nora Young',      'nora.young@mail.com',      '3125550122', 'P10022', 'Gold',     17000,'2019-03-05'),
('Owen King',       'owen.king@mail.com',       '3125550123', 'P10023', 'Standard', 700,  '2025-08-25'),
('Ivy Wright',      'ivy.wright@mail.com',      '3125550124', 'P10024', 'Standard', 150,  '2026-02-08'),
('Felix Scott',     'felix.scott@mail.com',     '3125550125', 'P10025', 'Standard', 400,  '2026-05-14');

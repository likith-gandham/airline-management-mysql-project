# SkyLink Airlines — Flight Reservation, Dynamic Pricing & Revenue Management System

An advanced SQL/DBMS project: a working airline reservation system covering
schema design, concurrency-safe transactions, trigger-driven business rules,
a JSON-based dynamic pricing engine, recursive route-graph queries, window-
function analytics, role-based security, and query optimization — every
piece built and verified against a live MariaDB 10.11 instance, not just
written and assumed correct.

## Why this project

Most course SQL projects stop at CRUD + a few joins. This one is built
around the questions a real airline's reservation system actually has to
answer: *How do we stop two customers from booking the same seat at the
same instant? How does the price change as a flight fills up? How do we
find every reachable destination — including multi-stop connections —
from a given airport? How do we let a booking agent create reservations
without ever letting them corrupt the seat map by hand?*

## Project structure

```
airline_advanced_sql_project/
├── README.md                             — This file
├── sql/
│   ├── 01_schema.sql                     — DDL: 14 tables, partitioning, JSON, full-text index
│   ├── 02_sample_data.sql                — Airports, routes, aircraft, flights, passengers
│   ├── 03_functions_and_procedures.sql   — Dynamic pricing engine + concurrency-safe booking
│   ├── 04_triggers.sql                   — Overbooking defense, audit log, loyalty automation
│   ├── 05_views_and_materialized_summary.sql — Reporting views + scheduled-event summary table
│   ├── 06_advanced_queries.sql           — Recursive CTEs, window functions, JSON, cohort analysis
│   ├── 07_security_and_roles.sql         — Least-privilege roles (agent / analyst / admin)
│   ├── 08_query_optimization.sql         — Real EXPLAIN/timing before-and-after case studies
│   └── seed_bookings.sql                 — Generates realistic booking activity for testing
├── diagrams/
│   ├── ER_diagram.md                     — Entity-relationship diagram (renders inline on GitHub)
│   └── ER_diagram.mmd                    — Same diagram as plain Mermaid source (for mermaid.live, etc.)
└── docs/
    └── PROJECT_REPORT.md                 — Full design rationale, trade-offs, and findings
```

## How to run it

Requires MySQL 8.0+ or MariaDB 10.6+ (for `JSON_TABLE` and window function support).

```bash
mysql -u root < sql/01_schema.sql
mysql -u root skylink_airlines < sql/02_sample_data.sql
mysql -u root skylink_airlines < sql/03_functions_and_procedures.sql
mysql -u root skylink_airlines < sql/04_triggers.sql
mysql -u root skylink_airlines < sql/05_views_and_materialized_summary.sql
mysql -u root skylink_airlines < sql/07_security_and_roles.sql
```

Then generate seats for every flight (the seat map is built by a stored
procedure per aircraft layout, not hand-inserted):

```sql
-- Run once after loading the schema and sample data:
DELIMITER //
CREATE PROCEDURE generate_all_seats()
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE fid INT;
  DECLARE cur CURSOR FOR SELECT flight_id FROM flights;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO fid;
    IF done THEN LEAVE read_loop; END IF;
    CALL generate_seats_for_flight(fid);
  END LOOP;
  CLOSE cur;
END //
DELIMITER ;
CALL generate_all_seats();
DROP PROCEDURE generate_all_seats;
```

Then optionally populate realistic booking activity for testing the
analytics in `06_advanced_queries.sql`:

```bash
mysql -u root skylink_airlines < sql/seed_bookings.sql
```

Finally, explore `06_advanced_queries.sql` (analytics) and
`08_query_optimization.sql` (EXPLAIN/timing case studies) — every query
in both files can be run independently.

## Try booking a seat yourself

```sql
CALL book_seat(1, 1, 'Economy', 'Card', @booking_id, @message);
SELECT @booking_id, @message;
```

Try it twice in a row on a flight with only one seat left in a class to
see the "no seats available" path, or try `cancel_booking(@booking_id, @msg)`
to release it again.

## What makes this "advanced"

| Feature | Where |
|---|---|
| Recursive CTE graph traversal (route network, multi-hop connections) | `06_advanced_queries.sql` §A |
| Concurrency-safe booking via `SELECT ... FOR UPDATE` row locking | `03_functions_and_procedures.sql` |
| JSON-driven dynamic pricing engine | `03_functions_and_procedures.sql`, `fare_rules` table |
| RANGE partitioning by year on the transactional bookings table | `01_schema.sql` |
| Trigger-enforced overbooking defense (independent of application code) | `04_triggers.sql` |
| Materialized-view substitute refreshed by a scheduled `EVENT` | `05_views_and_materialized_summary.sql` |
| Window functions: `DENSE_RANK`, `LAG`, running totals, `NTILE` | `06_advanced_queries.sql` §B |
| `JSON_TABLE` and `JSON_EXTRACT` queries | `06_advanced_queries.sql` §C |
| Cohort analysis and Pareto/LTV analysis with CTEs | `06_advanced_queries.sql` §D |
| Role-based security with least privilege (PII locked out of the analyst role) | `07_security_and_roles.sql` |
| `EXPLAIN`-driven index design with real before/after measurements | `08_query_optimization.sql` |

See **`docs/PROJECT_REPORT.md`** for the full design rationale — including
two real bugs found and fixed during testing, the trade-offs behind
partitioning without foreign keys, and why the security model deliberately
withholds passenger PII from the analytics role.

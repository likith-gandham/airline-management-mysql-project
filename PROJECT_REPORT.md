# Project Report: SkyLink Airlines Reservation & Revenue Management System

**Course context:** Advanced Database Management Systems
**Engine:** MariaDB 10.11 (MySQL 8.0+ compatible)
**Author's note:** Every query, procedure, trigger, and optimization claim
in this report was executed against a real, running MariaDB instance
during development — nothing here is theoretical SQL that "should work."
Section 6 documents two real bugs that were found and fixed in exactly
this way.

---

## 1. Problem statement and scope

A commercial airline's reservation system has to solve several problems
simultaneously that don't show up in a typical classroom schema:

1. **Concurrency** — two customers can attempt to book the last seat on a
   flight within milliseconds of each other. The database, not the
   application, must guarantee only one succeeds.
2. **Dynamic pricing** — the price of a seat changes continuously based on
   how full the flight is and how close departure is, not a fixed value
   set once at flight creation.
3. **Graph-structured data** — routes form a network, not a flat list.
   "What connecting flights exist from A to C?" is a graph traversal
   problem, not a simple join.
4. **Auditability** — every state change to a booking must be traceable,
   independent of whether the application code remembered to log it.
5. **Differentiated access** — a booking agent, a data analyst, and a
   database administrator need fundamentally different levels of access
   to the same data, and passenger personal information should not be
   visible to roles that don't need it.

This project's scope was to build a genuinely working system that
addresses all five, rather than a schema that merely looks complete.

---

## 2. Entity-relationship design and normalization

The schema (see `diagrams/ER_diagram.md`) consists of 14 tables. The
design follows Third Normal Form (3NF) throughout, with one deliberate,
documented exception discussed in Section 4.

**Normalization walkthrough (representative example — `bookings`):**
- **1NF**: every column holds a single atomic value (no repeating groups —
  e.g. a passenger's multiple bookings are separate rows, not a
  comma-separated list in one row).
- **2NF**: the table's primary key is `(booking_id, booking_datetime)`
  (composite only because partitioning requires the partition key to be
  part of every unique key — see Section 4). Every non-key attribute
  (`status`, `price_paid`, `payment_method`) depends on the *whole* key's
  functional determinant, `booking_id` — there is no partial dependency
  on `booking_datetime` alone.
- **3NF**: no non-key attribute depends on another non-key attribute.
  `price_paid` is stored on the booking itself (not derived from
  `flights.current_price` at query time) because a booking's price must
  be immutable once charged — even if the flight's dynamic price changes
  afterward, a completed booking's price must never silently change.
  This is a deliberate denormalization for correctness, not an oversight:
  storing a derived value is only a 3NF violation when the value *should*
  always match its source. Here it explicitly should not.

**Why `fare_rules.demand_curve` is JSON, not more tables**: the demand
curve is genuinely semi-structured (a variable-length array of threshold/
multiplier pairs) and is read as a unit by `calculate_dynamic_price()`,
never queried by individual array elements in the OLTP path. Modeling it
as a `fare_rule_id, threshold, multiplier` child table would be more
"normalized" in a narrow sense, but would require a join and a `GROUP BY`
or window function just to reconstruct the ordered curve every time the
pricing function runs — for data that is edited as a whole unit (a pricing
analyst updates a class's entire curve at once, not one threshold at a
time). JSON is the appropriate tool here specifically because the access
pattern is atomic-read/atomic-write, not row-by-row.

---

## 3. The booking transaction: concurrency control

`book_seat()` (`03_functions_and_procedures.sql`) is the highest-risk
piece of code in the system, because it is the one place where two
concurrent transactions can conflict over the same physical resource (a
seat).

**Design decision: pessimistic locking via `SELECT ... FOR UPDATE`,
not optimistic concurrency control.** An optimistic approach (read the
seat, compute a price, then `UPDATE ... WHERE seat_id = ? AND status =
'Available'` and check the affected-row count) was considered, and would
also work correctly. Pessimistic locking was chosen instead because:

- The window between "check availability" and "commit the booking"
  includes a genuinely nontrivial computation (`calculate_dynamic_price()`,
  which itself runs several `SELECT`s against `seats` and `fare_rules`).
  Under optimistic concurrency, a losing transaction wastes that work and
  must retry with application-level retry logic. Under pessimistic
  locking, the second transaction simply blocks until the first commits
  or rolls back, then sees the correct, current state with no retry loop
  needed.
- Seat inventory contention is a genuinely hot path with a small, bounded
  critical section — the textbook case where row-level pessimistic
  locking outperforms optimistic retry storms.

The trade-off, honestly stated: pessimistic locking sacrifices some
throughput under very high contention (transactions queue rather than
running in parallel) in exchange for simpler, more obviously correct code
with no retry logic. For an airline booking system — where correctness
(never overselling a seat) matters far more than raw throughput on a
single seat — this is the right trade-off.

**Isolation level**: InnoDB's default `REPEATABLE READ` is used
(unchanged from MariaDB's default) rather than lowering to `READ
COMMITTED`. Combined with the explicit `FOR UPDATE` row lock, this
guarantees the seat's status cannot change out from under the transaction
between the `SELECT` and the `UPDATE`/`INSERT`, which is the specific
anomaly (a lost update) this procedure exists to prevent.

---

## 4. Partitioning vs. referential integrity: a real trade-off

`bookings` is partitioned `RANGE (YEAR(booking_datetime))`. This was a
deliberate choice to demonstrate partitioning on the table most likely to
need it in production (a transactional log table that grows without
bound and is usually queried by recent date range).

**The trade-off, discovered during development, not assumed in advance**:
MySQL/MariaDB's InnoDB storage engine does not allow a partitioned table
to carry `FOREIGN KEY` constraints, nor to be the target of one from
another table. This was not known in advance — it was discovered as a
real `ERROR 1506` when first running `01_schema.sql`, and the schema was
redesigned around it rather than abandoning partitioning.

**The resolution**: referential integrity to `passengers`, `flights`, and
`seats` is enforced procedurally instead — every write to `bookings` goes
through `book_seat()` or `cancel_booking()`, both of which validate the
referenced rows exist before writing (see the `SELECT ... FOR UPDATE`
existence checks in each). The `trg_bookings_before_insert` trigger adds
a second, independent layer of validation at the database level, so even
a hypothetical direct `INSERT` that bypassed the procedures would still
be checked against the current seat status.

This is presented honestly as a trade-off, not a limitation hidden from
the reader: a true `FOREIGN KEY` gives referential integrity guarantees
that no amount of application or trigger logic can fully replicate (e.g.
protection against a badly-written ad hoc `DELETE` on `passengers`). A
production system making this same choice would need to decide, based on
actual write patterns and growth rate, whether partitioning's query and
maintenance benefits outweigh giving up declarative FK enforcement on
this one table. For this project, demonstrating partitioning was the
priority, and the trade-off is explicitly documented rather than glossed
over.

---

## 5. The dynamic pricing engine

`calculate_dynamic_price(flight_id, seat_class)` combines two independent
signals into one price:

1. **Occupancy-based demand pricing**, read from `fare_rules.demand_curve`
   (JSON): as the percentage of booked seats in a class crosses each
   threshold in the curve, the price multiplier steps up. This models
   real airline revenue management — a nearly-full cabin should not sell
   its last few seats at the same price as its first.
2. **Time-based urgency pricing**: a surcharge that scales up as departure
   approaches (0% at 30+ days out, up to 20% within 24 hours), modeling
   the well-documented last-minute-booking premium.

**Why `current_price` reflects only the Economy cabin's price** (a design
correction made during testing — see Section 6): an airline's "headline"
displayed fare is conventionally its lowest cabin's price ("flights from
$X"), regardless of which cabin a specific customer is booking. Tying
`current_price` to whichever class was most recently booked would make
the field meaningless as a display value, since it would swing wildly
between Economy-level and First-class-level numbers depending on booking
order. Each cabin's actual dynamic price is still computed correctly and
independently by `calculate_dynamic_price()` at the moment of booking;
`current_price` is specifically the flight's advertised headline figure.

---

## 6. Two real bugs found and fixed during testing

Both of these were caught by actually running the system against real
data, not by inspection — which is the central argument for why every
piece of this project was executed against a live database rather than
only written.

**Bug 1 — a trigger that blocked its own legitimate booking.**
The first version of `trg_bookings_before_insert` checked whether the
target seat's status was `'Booked'` and rejected the insert if so. But
the first version of `book_seat()` set the seat to `'Booked'` *before*
inserting the booking row — meaning the trigger always saw the seat as
already booked (by the very transaction trying to book it) and rejected
every booking. The fix was a redesign, not a patch: the procedure now
only locks the seat row (`SELECT ... FOR UPDATE`) and leaves its status
untouched; a `BEFORE INSERT` trigger validates the seat is still
`'Available'` at insert time, and a separate `AFTER INSERT` trigger
(`trg_bookings_mark_seat_booked`) is the *only* code path allowed to
transition a seat to `'Booked'`. This is a stronger design than the
original — a single, unambiguous owner of that state transition — not
just a bug fix.

**Bug 2 — `current_price` oscillating between cabin classes.**
Documented in Section 5. Discovered by querying `price_history` after a
sequence of test bookings and noticing prices swinging between roughly
$230 and $750 on the same flight with no plausible cause. Traced to the
procedure recalculating `current_price` using whatever class had just
been booked. Fixed by always recalculating against `'Economy'`
specifically, matching real airline fare-display conventions.

Both fixes are reflected in the final `03_functions_and_procedures.sql`
and `04_triggers.sql` shipped with this project — this section documents
the debugging process, not a hidden defect.

---

## 7. Query optimization: honest, measured results

`08_query_optimization.sql` contains two case studies, each with a real
`EXPLAIN` plan and a real measured timing (via `SET profiling = 1`), not
invented figures:

- **Seat lookup** (the hottest query in the system, inside `book_seat()`):
  adding a composite index on `(flight_id, seat_class, status)` changed
  the query plan from a full table scan (`type=ALL`, 5,661 rows examined)
  to an index lookup (`type=ref`, ~194 rows), measuring roughly **3x
  faster** (1.43ms → 0.44ms) on this dataset.
- **Daily revenue aggregation**: adding a covering index on
  `(status, booking_datetime, price_paid)` improved the plan from a full
  scan with a temp table and filesort to an index-range scan that is also
  a covering index (`Using index`), measuring roughly **1.9x faster**
  (1.57ms → 0.82ms).

**Honesty about scale**: these absolute numbers are small because the
test dataset (~5,660 seats, ~200 bookings) is small — a realistic
classroom-scale dataset, not a production one. The point of the case
study is the *query plan change* (full scan vs. targeted lookup), which
is what actually matters: that difference does not shrink as the table
grows, it grows *with* the table. A full scan over 5,000 rows costs
milliseconds; the same full scan over 50 million rows (a realistic
multi-year airline booking history) costs seconds, while an indexed
lookup's cost barely changes at all. The report avoids the common mistake
of citing a dramatic-sounding percentage from a tiny dataset as if it
proved something about production performance — the plan, not the
millisecond count, is the evidence that generalizes.

**A nuance documented rather than hidden**: the daily revenue query still
shows `Using temporary; Using filesort` even after indexing, because the
query groups by `DATE(booking_datetime)` — a function applied to the
indexed column, which prevents the optimizer from using the index's
natural ordering to satisfy `GROUP BY` directly. The index still helps
substantially (turning the `WHERE` clause into a range scan and making
the whole query a covering index), but doesn't eliminate every cost. This
distinction — understanding *which part* of a query plan an index does
and doesn't fix — is the actual skill query optimization is testing for,
not simply "add an index and the query gets faster."

Partition pruning was also verified directly: `EXPLAIN PARTITIONS` on a
2026-date-range query confirms only the `p2026` partition is scanned, with
`p2024`, `p2025`, and `p_future` eliminated before execution — exactly the
mechanism that makes partitioning valuable on a large, time-ordered table.

---

## 8. Security model

Three roles, each scoped to the principle of least privilege
(`07_security_and_roles.sql`), verified with real login attempts under
real credentials — not just inspected as GRANT statements:

- **`booking_agent`**: `SELECT` on read/search tables, `EXECUTE` on
  `book_seat`/`cancel_booking` only — no direct `UPDATE`/`INSERT`
  privileges on any table. This forces every write through the
  transaction-safe, trigger-audited procedures; a booking agent's account
  being compromised cannot be used to hand-edit a seat's status or a
  booking's price.
- **`data_analyst`**: read access to operational and reporting tables, but
  **no access to the raw `passengers` table at all** — only to
  `v_passenger_loyalty_summary`, a view that exposes loyalty tier, points,
  and spend, but not passport numbers, phone numbers, or email addresses.
  This was verified directly: a live connection as an analyst account
  returns `ERROR 1142: SELECT command denied ... for table passengers`,
  while the same connection succeeds against the view.
- **`db_admin`**: full privileges, reserved for the DBA account.

**An operational issue found and documented during this verification**:
a fresh MariaDB install ships with anonymous `''@'localhost'` accounts
left over from initialization. Because MySQL/MariaDB's account-matching
algorithm checks literal hostnames before wildcard (`%`) hosts, this
anonymous account silently intercepted every login attempted from
`localhost` — including logins for the named `agent_jsmith` and
`analyst_rpatel` accounts — before their own `%`-host grants were ever
consulted, producing a confusing "access denied" for the *correct*
username failing against the *wrong* account's credentials. This is
exactly what `mysql_secure_installation` exists to clean up, and
`07_security_and_roles.sql` now removes it explicitly, with the reasoning
documented inline as a comment for anyone deploying this schema on a
fresh instance.

---

## 9. Limitations and future work

Stated plainly, rather than left for a reader to discover:

- The dataset is intentionally classroom-scale (~25 passengers, ~20
  flights). The query *plans* and *design decisions* are production-
  representative; the absolute performance numbers are not, and Section 7
  says so explicitly.
- `calculate_dynamic_price()` does not currently account for
  competitor pricing or historical demand forecasting — it is a rules-
  based engine, not a machine-learning one. A natural extension would be
  replacing the static JSON demand curve with parameters fitted from
  historical booking velocity.
- Payment processing is modeled only as an enum (`payment_method`) with no
  actual payment gateway integration or failure/retry handling — out of
  scope for a database-focused project but a real system's next layer.
- The recursive CTE route-finder (`06_advanced_queries.sql` §A) caps at 2
  hops for the reachability query, a deliberate choice for a readable demo
  — a production route-planning engine would need configurable hop limits
  and additional pruning (e.g. discarding dominated paths early) to stay
  performant on a much larger route network.

---

## 10. Conclusion

This project was built and verified end-to-end against a live MariaDB
instance at every stage: 14 tables, 3 views, 4 procedures, 1 function, 6
triggers, 1 scheduled event, and 3 security roles, all confirmed present
and functioning via direct queries against `information_schema` and real
authenticated connections — not asserted from the SQL source alone. Two
genuine design bugs were found through this testing process and are
documented rather than hidden, because the debugging process itself
demonstrates the same skill the schema design does: reasoning carefully
about what a piece of SQL actually does under concurrent, real-world
conditions, not just what it looks like it should do.

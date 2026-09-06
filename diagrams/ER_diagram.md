# Entity-Relationship Diagram — SkyLink Airlines

This renders automatically on GitHub (Mermaid support is built into
GitHub's Markdown viewer — no extra plugin or export needed).

```mermaid
erDiagram
    AIRPORTS ||--o{ ROUTES : "origin of"
    AIRPORTS ||--o{ ROUTES : "destination of"
    ROUTES ||--o{ FLIGHTS : "operated as"
    AIRCRAFT ||--o{ FLIGHTS : "assigned to"
    FLIGHTS ||--o{ SEATS : "has"
    FLIGHTS ||--o{ FLIGHT_CREW : "staffed by"
    CREW ||--o{ FLIGHT_CREW : "assigned to"
    FLIGHTS ||--o{ PRICE_HISTORY : "price changes logged in"
    SEATS ||--o| BOOKINGS : "booked via"
    PASSENGERS ||--o{ BOOKINGS : "makes"
    BOOKINGS ||--o{ BOOKING_AUDIT_LOG : "audited in"
    PASSENGERS ||--o{ LOYALTY_TRANSACTIONS : "earns/redeems"
    BOOKINGS ||--o{ LOYALTY_TRANSACTIONS : "generates"
    FARE_RULES ||..o{ SEATS : "prices (by class, via function)"

    AIRPORTS {
        char3 airport_code PK
        string airport_name
        string city
        string country
    }
    AIRCRAFT {
        int aircraft_id PK
        string model
        int economy_seats
        int business_seats
        int total_capacity
    }
    ROUTES {
        int route_id PK
        char3 origin_airport FK
        char3 destination_airport FK
        int distance_km
    }
    CREW {
        int crew_id PK
        string full_name
        string role
    }
    FLIGHTS {
        int flight_id PK
        string flight_number
        int route_id FK
        int aircraft_id FK
        datetime departure_datetime
        decimal current_price
        string status
    }
    FLIGHT_CREW {
        int flight_id FK
        int crew_id FK
    }
    SEATS {
        bigint seat_id PK
        int flight_id FK
        string seat_number
        string seat_class
        string status
    }
    PASSENGERS {
        int passenger_id PK
        string full_name
        string loyalty_tier
        int loyalty_points
    }
    FARE_RULES {
        int fare_rule_id PK
        string seat_class
        json demand_curve
    }
    BOOKINGS {
        bigint booking_id PK
        int passenger_id
        int flight_id
        bigint seat_id
        string status
        decimal price_paid
    }
    BOOKING_AUDIT_LOG {
        bigint log_id PK
        bigint booking_id
        string action
        datetime changed_at
    }
    PRICE_HISTORY {
        bigint price_history_id PK
        int flight_id FK
        decimal old_price
        decimal new_price
    }
    LOYALTY_TRANSACTIONS {
        bigint txn_id PK
        int passenger_id
        int points
        string txn_type
    }
```

The original Mermaid source (for use in non-GitHub tools like the
[Mermaid Live Editor](https://mermaid.live)) is also kept as
[`ER_diagram.mmd`](./ER_diagram.mmd) in this same folder.

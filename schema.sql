-- ZenSched Property-Preservation Local Database Schema
-- SQLite database for clients (national vendors, servicers, REO, HOA, direct),
-- a cache of property addresses, the inspector roster, work orders, visits,
-- mileage, client invoices / receivables, and 1099 inspector payouts.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, timesheets).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my preservation-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 preservation-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- THIS IS NOT A SAFEGUARD / MCS / SERVICELINK PORTAL, AND IT IS NOT A RULES
-- ENGINE. It does not submit occupancy results, photos, or invoices into any
-- national-vendor portal, does not know HUD / FHA / investor timelines, and
-- does not generate a conveyance package. You still upload the photos and
-- result codes in the portal the vendor gave you. This kit puts every stop
-- on the inspector's phone, GPS-stamps the visit, and captures the field
-- report so you can invoice and pay 1099s from records you actually have.
--
-- PRIVACY: occupant names, lockbox codes, and gate codes live ONLY in this
-- file on your computer: work_orders.occupant_name, work_orders.access_notes,
-- places.access_notes. Property street addresses DO go to ZenSched — the
-- geofence needs them. ZenSched titles are "WO 88217 - Elm St" (vendor order
-- number + street, never an occupant). SKILL.md forbids the agent from putting
-- any local-only column into a ZenSched field.

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session (timezone, defaults, business name, form id).
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My Field Services');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '-05:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('state', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_inspector_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_visit_minutes', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('report_form_id', NULL);
-- IRS standard mileage rate for business use. 0.70 is the 2025 rate ($0.70/mile);
-- the IRS announces a new rate each December. Update this once a year.
INSERT OR IGNORE INTO settings (key, value) VALUES ('irs_mileage_rate', '0.70');

-- Clients: who hires you and who pays you. A national field-services vendor
-- (the MCS / Safeguard / ServiceLink *shape* of client — this kit does not
-- talk to those portals), a mortgage servicer, an REO / asset manager, an
-- HOA / property manager, or a direct owner. payment_terms_days drives invoice
-- due dates; default_* fees snapshot onto the work order when left NULL.
CREATE TABLE IF NOT EXISTS clients (
  client_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_name TEXT NOT NULL,
  client_type TEXT NOT NULL DEFAULT 'national_vendor'
    CHECK (client_type IN ('national_vendor', 'servicer', 'reo', 'hoa', 'direct', 'other')),
  contact_name TEXT,                                -- AP / dispatch contact, LOCAL ONLY
  contact_phone TEXT,
  billing_email TEXT,
  payment_terms_days INTEGER NOT NULL DEFAULT 30,   -- net 30 / net 45; direct = 0
  default_fee REAL,                                 -- $ per completed order (occupancy etc.)
  default_rush_fee REAL,                            -- $ added when the order is rush
  notes TEXT,
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Places: a cache of property addresses -> ZenSched location ids.
-- Occupancy routes hit new houses every day; a handful of REO / HOA
-- properties repeat. normalized_address is the de-dup key: the agent builds
-- it as lowercase(address + city + state + zip) with commas, periods, and '#'
-- removed and whitespace collapsed to single spaces (SQLite cannot collapse
-- whitespace, so the agent does it). The agent looks here FIRST and only
-- calls location_create (geocode, $0.03) on a miss. Hand-tuned pins
-- (location_update) therefore survive for a repeat vacant. place_label is
-- the ONLY name sent to ZenSched for this address; street_name (no house
-- number) feeds event titles ("WO 88217 - Elm St"). access_notes is LOCAL
-- ONLY (gate code, lockbox, "key under mat").
CREATE TABLE IF NOT EXISTS places (
  place_id INTEGER PRIMARY KEY AUTOINCREMENT,
  normalized_address TEXT NOT NULL UNIQUE,
  address TEXT NOT NULL,
  city TEXT,
  state TEXT,
  zip TEXT,
  street_name TEXT,                                 -- 'Elm St' (no number); used in event titles
  place_label TEXT,                                 -- sent to ZenSched: 'Property - Elm St'
  zensched_location_id INTEGER,                     -- from location_create (permanent)
  access_notes TEXT,                                -- LOCAL ONLY: gate code, lockbox, dog, 'rear unit'
  is_repeat_site INTEGER DEFAULT 0,                 -- 1 = REO / HOA / property you expect to return to
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Inspectors: in solo mode this is one row (you, is_owner = 1) whose
-- zensched_worker_id came from inviting yourself. In agency mode add a row
-- per 1099 inspector with payout_type/payout_value:
--   per_visit -> $ per visit actually completed
--   percent   -> % of the work order's billable total
CREATE TABLE IF NOT EXISTS inspectors (
  inspector_id INTEGER PRIMARY KEY AUTOINCREMENT,
  inspector_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite
  is_owner INTEGER DEFAULT 0,                       -- 1 = the business owner (no payouts)
  payout_type TEXT
    CHECK (payout_type IS NULL OR payout_type IN ('per_visit', 'percent')),
  payout_value REAL,                                -- $ (per_visit) or % (percent)
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Work orders: one row per job from a client. Analog of process-serving
-- `cases`. A work order has one property (place_id) and one or more visits.
-- The order carries the fee snapshot and the vendor deadline (due_by).
--
-- work_order_ref is YOUR reference, filled by trigger as 'WO-2026-0001' when
-- NULL. client_order_ref is the vendor's order number (used in ZenSched
-- titles: "WO 88217 - Elm St"). occupant_name and access_notes are LOCAL ONLY
-- and never reach ZenSched.
--
-- status: open -> completed (a visit was pulled, including inaccessible)
--                | no_access (owner closed without a completed visit)
--                | cancelled (client withdrew).
-- completed_visit_id points at the visit that closed the order.
CREATE TABLE IF NOT EXISTS work_orders (
  work_order_id INTEGER PRIMARY KEY AUTOINCREMENT,
  work_order_ref TEXT UNIQUE,                       -- 'WO-2026-0001', filled by trigger if NULL
  client_id INTEGER NOT NULL,
  client_order_ref TEXT,                            -- vendor / portal order number, e.g. '88217'
  place_id INTEGER NOT NULL,
  order_type TEXT NOT NULL DEFAULT 'occupancy'
    CHECK (order_type IN ('occupancy', 'secure', 'winterize', 'lawn', 'debris', 'lock_change', 'other')),
  occupant_name TEXT,                               -- LOCAL ONLY
  access_notes TEXT,                                -- LOCAL ONLY: lockbox / gate for THIS order
  is_rush INTEGER DEFAULT 0,
  received_date TEXT DEFAULT (date('now', 'localtime')),
  due_by TEXT,                                      -- ISO date the vendor needs the result by
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'completed', 'cancelled', 'no_access')),
  fee REAL,                                         -- NULL -> client default (trigger)
  rush_fee REAL,                                    -- NULL -> client default (trigger); billed when is_rush = 1
  other_fee REAL,                                   -- wait time, extra trip, cancellation, ...
  completed_at TEXT,                                -- local 'YYYY-MM-DDTHH:MM', from the closing visit's check-in
  completed_visit_id INTEGER,
  notes TEXT,
  invoiced INTEGER DEFAULT 0,
  paid_out INTEGER DEFAULT 0,                       -- 1 = sub payout done (agency mode)
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE,
  FOREIGN KEY (place_id) REFERENCES places(place_id) ON DELETE RESTRICT,
  FOREIGN KEY (completed_visit_id) REFERENCES visits(visit_id) ON DELETE SET NULL
);

-- Visits: THE driving table. Analog of process-serving `attempts`. One row
-- per visit window on a work order; each row maps to exactly one ZenSched
-- shift. Two ways a row is born:
--   planned  - created at intake (due-by window) or when the owner schedules
--   ad hoc   - "I'm at Elm St now": scheduled_start = now, is_adhoc = 1, and
--              the inspector punches within the minute
--
-- High volume, same day: ONE ZenSched EVENT per place per calendar day
-- (start_date = end_date = the visit date). A second visit to the same house
-- the same afternoon reuses that event; a monthly occupancy re-opens a new
-- one-day event. zensched_event_id is stored on the visit; the views surface
-- a sibling day's event so the agent does not create a second one.
--
-- scheduled_start is LOCAL wall-clock time as 'YYYY-MM-DDTHH:MM' or
-- 'YYYY-MM-DDTHH:MM:SS' with NO offset and no 'Z'; the views append
-- settings.timezone_offset to produce start_iso / end_iso for shift_create.
--
-- status: planned -> completed (Field Report pulled) | cancelled (window not used).
-- occupancy / property_condition / issues / inaccessible_reason / photo_count /
-- report_dc_id come from the Field Report. checked_in_at / checked_out_at /
-- gps_verified / checkin_distance_m are copied from shift_status once.
CREATE TABLE IF NOT EXISTS visits (
  visit_id INTEGER PRIMARY KEY AUTOINCREMENT,
  work_order_id INTEGER NOT NULL,
  place_id INTEGER,                                 -- NULL -> work_orders.place_id (trigger)
  inspector_id INTEGER,                             -- NULL -> settings.default_inspector_id (trigger)
  scheduled_start TEXT NOT NULL                     -- local 'YYYY-MM-DDTHH:MM[:SS]', no offset
    CHECK (scheduled_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-2][0-9]:[0-5][0-9]*'
           AND scheduled_start NOT GLOB '*T*[+-]*'
           AND scheduled_start NOT GLOB '*Z'),
  duration_minutes INTEGER                          -- NULL -> settings.default_visit_minutes
    CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 5 AND 480),
  is_adhoc INTEGER DEFAULT 0,                       -- 1 = "I'm here now" window created on the spot
  status TEXT NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned', 'completed', 'cancelled')),
  occupancy TEXT,                                   -- form option key: occupied, vacant, unknown, inaccessible
  property_condition TEXT,                          -- form option key: secure, unsecure, damaged
  issues TEXT,                                      -- form multi_select keys, comma-separated
  inaccessible_reason TEXT,                         -- from the form when occupancy = inaccessible
  photo_count INTEGER DEFAULT 0,                    -- exterior + meter photos (images stay on ZenSched)
  zensched_event_id INTEGER,                        -- one-day event for this place on this date
  zensched_shift_id INTEGER UNIQUE,
  report_dc_id INTEGER,                             -- Field Report submission_id
  checked_in_at TEXT,                               -- from shift_status (ISO with offset)
  checked_out_at TEXT,
  gps_verified INTEGER,                             -- 1 if the check-in punch was on site
  checkin_distance_m INTEGER,
  notes TEXT,                                       -- from the form + owner notes
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (work_order_id) REFERENCES work_orders(work_order_id) ON DELETE CASCADE,
  FOREIGN KEY (place_id) REFERENCES places(place_id) ON DELETE RESTRICT,
  FOREIGN KEY (inspector_id) REFERENCES inspectors(inspector_id) ON DELETE SET NULL
);

-- Mileage: one row per trip. visit_id is NULL for non-visit trips (supply run,
-- locksmith pickup). rate and deduction are filled by trigger when left NULL
-- (rate from settings.irs_mileage_rate at the time of the trip).
CREATE TABLE IF NOT EXISTS mileage (
  trip_id INTEGER PRIMARY KEY AUTOINCREMENT,
  visit_id INTEGER,
  trip_date TEXT NOT NULL,                          -- ISO date
  miles REAL NOT NULL CHECK (miles >= 0),
  from_label TEXT,                                  -- 'Home', 'Property - Elm St'
  to_label TEXT,
  purpose TEXT,                                     -- 'WO-2026-0001 occupancy round trip'
  rate REAL,                                        -- $/mile snapshot (trigger)
  deduction REAL,                                   -- miles * rate (trigger)
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (visit_id) REFERENCES visits(visit_id) ON DELETE SET NULL
);

-- Invoices: one per client per billing run. invoice_number is filled by trigger
-- if left NULL. due_date is invoice_date + the client's payment_terms_days.
-- line_items is a JSON array with one object per work order (ref, vendor
-- order number, type, occupancy, fee breakdown) so the invoice can be regenerated.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id INTEGER NOT NULL,
  invoice_number TEXT UNIQUE,                       -- 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  sent_date TEXT,
  line_items TEXT,                                  -- JSON array
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE
);

-- Payouts: what you owe a 1099 inspector for one visit (agency mode).
-- One row per visit. amount is filled by trigger when left NULL:
--   per_visit -> inspectors.payout_value
--   percent   -> work order billable_total * payout_value / 100
-- Never insert a payout for the owner row.
CREATE TABLE IF NOT EXISTS payouts (
  payout_id INTEGER PRIMARY KEY AUTOINCREMENT,
  inspector_id INTEGER NOT NULL,
  visit_id INTEGER NOT NULL UNIQUE,
  amount REAL,                                      -- trigger fills if NULL
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (inspector_id) REFERENCES inspectors(inspector_id) ON DELETE CASCADE,
  FOREIGN KEY (visit_id) REFERENCES visits(visit_id) ON DELETE CASCADE
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_places_location ON places(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_work_orders_client ON work_orders(client_id, invoiced);
CREATE INDEX IF NOT EXISTS idx_work_orders_status_due ON work_orders(status, due_by);
CREATE INDEX IF NOT EXISTS idx_work_orders_place ON work_orders(place_id);
CREATE INDEX IF NOT EXISTS idx_work_orders_client_ref ON work_orders(client_order_ref);
CREATE INDEX IF NOT EXISTS idx_visits_order ON visits(work_order_id, status);
CREATE INDEX IF NOT EXISTS idx_visits_start ON visits(scheduled_start);
CREATE INDEX IF NOT EXISTS idx_visits_status_start ON visits(status, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_visits_place_start ON visits(place_id, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_visits_inspector ON visits(inspector_id, status);
CREATE INDEX IF NOT EXISTS idx_visits_event ON visits(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_mileage_date ON mileage(trip_date);
CREATE INDEX IF NOT EXISTS idx_mileage_visit ON mileage(visit_id);
CREATE INDEX IF NOT EXISTS idx_invoices_client ON invoices(client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_paid ON invoices(paid, due_date);
CREATE INDEX IF NOT EXISTS idx_payouts_inspector ON payouts(inspector_id, paid);

-- What a work order bills depends on what happened. This is the single place
-- that rule lives; receivables, invoicing, and payouts read billable_total
-- from here rather than re-deriving it.
--   completed  -> fee + rush_fee (if rush) + other_fee
--                 (inaccessible occupancy is still completed: you went and reported)
--   no_access  -> other_fee only (owner closed without a completed visit)
--   cancelled  -> other_fee only
--   open       -> 0
CREATE VIEW IF NOT EXISTS billable_orders AS
SELECT
  w.work_order_id,
  w.work_order_ref,
  w.client_order_ref,
  COALESCE(w.client_order_ref, w.work_order_ref)   AS order_label,
  w.client_id,
  w.order_type,
  w.status,
  w.is_rush,
  w.received_date,
  w.due_by,
  date(w.completed_at)                             AS completed_date,
  w.fee,
  CASE WHEN w.is_rush = 1 THEN COALESCE(w.rush_fee, 0) ELSE 0 END AS rush_fee_billed,
  w.other_fee,
  COALESCE(v.visits_made, 0)                       AS visits_made,
  v.last_occupancy,
  CASE w.status
    WHEN 'completed' THEN round(COALESCE(w.fee, 0)
                                + CASE WHEN w.is_rush = 1 THEN COALESCE(w.rush_fee, 0) ELSE 0 END
                                + COALESCE(w.other_fee, 0), 2)
    WHEN 'no_access' THEN round(COALESCE(w.other_fee, 0), 2)
    WHEN 'cancelled' THEN round(COALESCE(w.other_fee, 0), 2)
    ELSE 0
  END                                              AS billable_total,
  w.invoiced,
  w.paid_out,
  w.completed_visit_id
FROM work_orders w
LEFT JOIN (
  SELECT work_order_id,
         COUNT(*) AS visits_made,
         (SELECT v2.occupancy FROM visits v2
          WHERE v2.work_order_id = visits.work_order_id AND v2.status = 'completed'
          ORDER BY COALESCE(v2.checked_in_at, v2.scheduled_start) DESC LIMIT 1) AS last_occupancy
  FROM visits
  WHERE status = 'completed'
  GROUP BY work_order_id
) v ON v.work_order_id = w.work_order_id;

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_client_timestamp
AFTER UPDATE ON clients
BEGIN
  UPDATE clients SET updated_at = datetime('now') WHERE client_id = NEW.client_id;
END;

CREATE TRIGGER IF NOT EXISTS update_place_timestamp
AFTER UPDATE ON places
BEGIN
  UPDATE places SET updated_at = datetime('now') WHERE place_id = NEW.place_id;
END;

CREATE TRIGGER IF NOT EXISTS update_inspector_timestamp
AFTER UPDATE ON inspectors
BEGIN
  UPDATE inspectors SET updated_at = datetime('now') WHERE inspector_id = NEW.inspector_id;
END;

CREATE TRIGGER IF NOT EXISTS update_work_order_timestamp
AFTER UPDATE OF client_id, client_order_ref, place_id, order_type, occupant_name, access_notes,
                is_rush, received_date, due_by, status, fee, rush_fee, other_fee,
                completed_at, completed_visit_id, notes, invoiced, paid_out
ON work_orders
BEGIN
  UPDATE work_orders SET updated_at = datetime('now') WHERE work_order_id = NEW.work_order_id;
END;

CREATE TRIGGER IF NOT EXISTS update_visit_timestamp
AFTER UPDATE OF work_order_id, place_id, inspector_id, scheduled_start, duration_minutes, is_adhoc,
                status, occupancy, property_condition, issues, inaccessible_reason, photo_count,
                zensched_event_id, zensched_shift_id, report_dc_id, checked_in_at, checked_out_at,
                gps_verified, checkin_distance_m, notes
ON visits
BEGIN
  UPDATE visits SET updated_at = datetime('now') WHERE visit_id = NEW.visit_id;
END;

-- Auto-number work orders: WO-2026-0001, WO-2026-0002, ... (year received,
-- sequence = work_order_id, so numbers never collide or reset). An explicit
-- work_order_ref is kept.
CREATE TRIGGER IF NOT EXISTS number_work_order
AFTER INSERT ON work_orders
WHEN NEW.work_order_ref IS NULL
BEGIN
  UPDATE work_orders
  SET work_order_ref = 'WO-' || strftime('%Y', COALESCE(NEW.received_date, date('now', 'localtime'))) || '-' || printf('%04d', NEW.work_order_id)
  WHERE work_order_id = NEW.work_order_id;
END;

-- Fill fee defaults the agent left NULL:
--   fee / rush_fee <- clients.default_*, else 0
--   other_fee <- 0
-- Fees are snapshots: changing a client's defaults later never rewrites history.
CREATE TRIGGER IF NOT EXISTS fill_work_order_defaults
AFTER INSERT ON work_orders
BEGIN
  UPDATE work_orders
  SET fee      = COALESCE(NEW.fee,      (SELECT default_fee      FROM clients WHERE client_id = NEW.client_id), 0),
      rush_fee = COALESCE(NEW.rush_fee, (SELECT default_rush_fee FROM clients WHERE client_id = NEW.client_id), 0),
      other_fee = COALESCE(NEW.other_fee, 0)
  WHERE work_order_id = NEW.work_order_id;
END;

-- Fill defaults the agent left NULL:
--   duration_minutes <- settings.default_visit_minutes (else 30)
--   inspector_id     <- settings.default_inspector_id (solo mode: you)
--   place_id         <- the work order's place
CREATE TRIGGER IF NOT EXISTS fill_visit_defaults
AFTER INSERT ON visits
BEGIN
  UPDATE visits
  SET duration_minutes = COALESCE(NEW.duration_minutes,
                                  (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_visit_minutes'),
                                  30),
      inspector_id = COALESCE(NEW.inspector_id,
                              (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_inspector_id' AND value IS NOT NULL)),
      place_id = COALESCE(NEW.place_id,
                          (SELECT place_id FROM work_orders WHERE work_order_id = NEW.work_order_id))
  WHERE visit_id = NEW.visit_id;
END;

-- Mileage: snapshot the IRS rate and compute the deduction.
CREATE TRIGGER IF NOT EXISTS fill_mileage_deduction
AFTER INSERT ON mileage
BEGIN
  UPDATE mileage
  SET rate = COALESCE(NEW.rate, (SELECT CAST(value AS REAL) FROM settings WHERE key = 'irs_mileage_rate'), 0),
      deduction = round(NEW.miles * COALESCE(NEW.rate, (SELECT CAST(value AS REAL) FROM settings WHERE key = 'irs_mileage_rate'), 0), 2)
  WHERE trip_id = NEW.trip_id;
END;

CREATE TRIGGER IF NOT EXISTS recompute_mileage_deduction
AFTER UPDATE OF miles, rate ON mileage
BEGIN
  UPDATE mileage SET deduction = round(NEW.miles * COALESCE(NEW.rate, 0), 2) WHERE trip_id = NEW.trip_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Payout amount from the inspector's split when the agent leaves it NULL.
-- per_visit -> payout_value
-- percent   -> billable_total of the visit's work order * payout_value / 100
-- If the inspector has no payout_type the amount stays NULL and payouts_due
-- flags it (needs_amount = 1).
CREATE TRIGGER IF NOT EXISTS fill_payout_amount
AFTER INSERT ON payouts
WHEN NEW.amount IS NULL
BEGIN
  UPDATE payouts
  SET amount = (SELECT CASE i.payout_type
                         WHEN 'per_visit' THEN i.payout_value
                         WHEN 'percent' THEN round((SELECT b.billable_total
                                                    FROM billable_orders b
                                                    JOIN visits v ON v.work_order_id = b.work_order_id
                                                    WHERE v.visit_id = NEW.visit_id) * i.payout_value / 100.0, 2)
                       END
                FROM inspectors i
                WHERE i.inspector_id = NEW.inspector_id)
  WHERE payout_id = NEW.payout_id;
END;

-- Every planned visit (any date) with everything the agent needs to put it
-- on ZenSched. start_iso / end_iso carry settings.timezone_offset and are
-- ready for shift_create. High-volume same-day: one event per place per
-- calendar day — day_event_id is a sibling visit's event on the same place
-- and date, so a second stop (or an "I'm here now") is one shift_create.
--   needs_location = 1 -> the place has no ZenSched location yet
--   needs_event    = 1 -> this place has no event yet for this date
--   needs_shift    = 1 -> the visit has no ZenSched shift yet
--   event_start_date / event_end_date = the visit's local date (same-day event)
CREATE VIEW IF NOT EXISTS visits_planned AS
SELECT
  v.visit_id,
  v.status,
  v.is_adhoc,
  v.scheduled_start,
  v.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', v.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(v.scheduled_start, '+' || v.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  w.work_order_id,
  w.work_order_ref,
  w.client_order_ref,
  COALESCE(w.client_order_ref, w.work_order_ref)                                  AS order_label,
  w.order_type,
  w.occupant_name,
  w.access_notes                                                                  AS order_access_notes,
  w.is_rush,
  w.due_by,
  CASE WHEN w.due_by IS NOT NULL
       THEN CAST(julianday(w.due_by) - julianday(date('now', 'localtime')) AS INTEGER) END AS days_left,
  w.status                                                                        AS order_status,
  cl.client_id,
  cl.client_name,
  cl.client_type,
  p.place_id,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Property - ' || COALESCE(p.street_name, p.address))     AS zensched_location_name,
  'WO ' || COALESCE(w.client_order_ref, w.work_order_ref) || ' - ' || COALESCE(p.street_name, p.address) AS zensched_event_title,
  p.access_notes                                                                  AS place_access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  COALESCE(v.zensched_event_id,
           (SELECT v2.zensched_event_id FROM visits v2
            WHERE v2.place_id = COALESCE(v.place_id, w.place_id)
              AND date(v2.scheduled_start) = date(v.scheduled_start)
              AND v2.zensched_event_id IS NOT NULL
            ORDER BY v2.visit_id LIMIT 1))                                        AS zensched_event_id,
  CASE WHEN v.zensched_event_id IS NULL
            AND NOT EXISTS (SELECT 1 FROM visits v2
                            WHERE v2.place_id = COALESCE(v.place_id, w.place_id)
                              AND date(v2.scheduled_start) = date(v.scheduled_start)
                              AND v2.zensched_event_id IS NOT NULL) THEN 1 ELSE 0 END AS needs_event,
  date(v.scheduled_start)                                                         AS event_start_date,
  date(v.scheduled_start)                                                         AS event_end_date,
  v.zensched_shift_id,
  CASE WHEN v.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  v.inspector_id,
  i.inspector_name,
  i.zensched_worker_id,
  v.notes,
  'loc-place-' || p.place_id                                                      AS loc_idempotency_key,
  'event-place-' || p.place_id || '-' || strftime('%Y%m%d', v.scheduled_start)    AS event_idempotency_key,
  'shift-visit-' || v.visit_id                                                    AS shift_idempotency_key
FROM visits v
JOIN work_orders w ON w.work_order_id = v.work_order_id
JOIN clients cl ON cl.client_id = w.client_id
JOIN places p ON p.place_id = COALESCE(v.place_id, w.place_id)
LEFT JOIN inspectors i ON i.inspector_id = v.inspector_id
WHERE v.status = 'planned'
ORDER BY v.scheduled_start;

-- Today's board: planned and completed visits whose local date is today
-- (the computer running the database). Completed rows stay so the owner can
-- see what is done vs still out. Same columns as visits_planned plus
-- occupancy / GPS stamps for completed stops.
CREATE VIEW IF NOT EXISTS visits_today AS
SELECT
  v.visit_id,
  v.status,
  v.is_adhoc,
  v.scheduled_start,
  v.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', v.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(v.scheduled_start, '+' || COALESCE(v.duration_minutes, 30) || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  w.work_order_id,
  w.work_order_ref,
  w.client_order_ref,
  COALESCE(w.client_order_ref, w.work_order_ref)                                  AS order_label,
  w.order_type,
  w.occupant_name,
  w.access_notes                                                                  AS order_access_notes,
  w.is_rush,
  w.due_by,
  CASE WHEN w.due_by IS NOT NULL
       THEN CAST(julianday(w.due_by) - julianday(date('now', 'localtime')) AS INTEGER) END AS days_left,
  w.status                                                                        AS order_status,
  cl.client_id,
  cl.client_name,
  cl.client_type,
  p.place_id,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Property - ' || COALESCE(p.street_name, p.address))     AS zensched_location_name,
  'WO ' || COALESCE(w.client_order_ref, w.work_order_ref) || ' - ' || COALESCE(p.street_name, p.address) AS zensched_event_title,
  p.access_notes                                                                  AS place_access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  COALESCE(v.zensched_event_id,
           (SELECT v2.zensched_event_id FROM visits v2
            WHERE v2.place_id = COALESCE(v.place_id, w.place_id)
              AND date(v2.scheduled_start) = date(v.scheduled_start)
              AND v2.zensched_event_id IS NOT NULL
            ORDER BY v2.visit_id LIMIT 1))                                        AS zensched_event_id,
  CASE WHEN v.zensched_event_id IS NULL
            AND NOT EXISTS (SELECT 1 FROM visits v2
                            WHERE v2.place_id = COALESCE(v.place_id, w.place_id)
                              AND date(v2.scheduled_start) = date(v.scheduled_start)
                              AND v2.zensched_event_id IS NOT NULL) THEN 1 ELSE 0 END AS needs_event,
  date(v.scheduled_start)                                                         AS event_start_date,
  date(v.scheduled_start)                                                         AS event_end_date,
  v.zensched_shift_id,
  CASE WHEN v.zensched_shift_id IS NULL AND v.status = 'planned' THEN 1 ELSE 0 END AS needs_shift,
  v.inspector_id,
  i.inspector_name,
  i.zensched_worker_id,
  v.occupancy,
  v.property_condition,
  v.issues,
  v.inaccessible_reason,
  v.photo_count,
  v.gps_verified,
  v.checkin_distance_m,
  v.checked_in_at,
  v.checked_out_at,
  v.notes,
  'loc-place-' || p.place_id                                                      AS loc_idempotency_key,
  'event-place-' || p.place_id || '-' || strftime('%Y%m%d', v.scheduled_start)    AS event_idempotency_key,
  'shift-visit-' || v.visit_id                                                    AS shift_idempotency_key
FROM visits v
JOIN work_orders w ON w.work_order_id = v.work_order_id
JOIN clients cl ON cl.client_id = w.client_id
JOIN places p ON p.place_id = COALESCE(v.place_id, w.place_id)
LEFT JOIN inspectors i ON i.inspector_id = v.inspector_id
WHERE v.status IN ('planned', 'completed')
  AND date(v.scheduled_start) = date('now', 'localtime')
ORDER BY v.scheduled_start;

-- Same planned columns, next 7 days (today through today + 6).
CREATE VIEW IF NOT EXISTS visits_upcoming AS
SELECT *
FROM visits_planned
WHERE date(scheduled_start) BETWEEN date('now', 'localtime') AND date('now', 'localtime', '+6 days')
ORDER BY scheduled_start;

-- Open work orders due today, with whether a visit is already on the phone.
CREATE VIEW IF NOT EXISTS orders_due_today AS
SELECT
  w.work_order_id,
  w.work_order_ref,
  w.client_order_ref,
  COALESCE(w.client_order_ref, w.work_order_ref)   AS order_label,
  w.order_type,
  w.is_rush,
  w.due_by,
  w.status,
  w.fee,
  cl.client_id,
  cl.client_name,
  w.occupant_name,
  p.place_id,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  p.street_name,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END AS needs_location,
  (SELECT COUNT(*) FROM visits v WHERE v.work_order_id = w.work_order_id AND v.status = 'planned') AS planned_visits,
  (SELECT COUNT(*) FROM visits v WHERE v.work_order_id = w.work_order_id AND v.status = 'completed') AS completed_visits,
  (SELECT MIN(v.scheduled_start) FROM visits v WHERE v.work_order_id = w.work_order_id AND v.status = 'planned') AS next_planned,
  w.notes
FROM work_orders w
JOIN clients cl ON cl.client_id = w.client_id
JOIN places p ON p.place_id = w.place_id
WHERE w.status = 'open'
  AND w.due_by = date('now', 'localtime')
ORDER BY w.is_rush DESC, w.work_order_id;

-- Open work orders past due_by. Lead with these at session start.
CREATE VIEW IF NOT EXISTS orders_overdue AS
SELECT
  w.work_order_id,
  w.work_order_ref,
  w.client_order_ref,
  COALESCE(w.client_order_ref, w.work_order_ref)   AS order_label,
  w.order_type,
  w.is_rush,
  w.due_by,
  CAST(julianday(date('now', 'localtime')) - julianday(w.due_by) AS INTEGER) AS days_overdue,
  w.status,
  w.fee,
  cl.client_id,
  cl.client_name,
  w.occupant_name,
  p.place_id,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  p.street_name,
  p.zensched_location_id,
  (SELECT COUNT(*) FROM visits v WHERE v.work_order_id = w.work_order_id AND v.status = 'planned') AS planned_visits,
  (SELECT COUNT(*) FROM visits v WHERE v.work_order_id = w.work_order_id AND v.status = 'completed') AS completed_visits,
  (SELECT MIN(v.scheduled_start) FROM visits v WHERE v.work_order_id = w.work_order_id AND v.status = 'planned') AS next_planned,
  w.notes
FROM work_orders w
JOIN clients cl ON cl.client_id = w.client_id
JOIN places p ON p.place_id = w.place_id
WHERE w.status = 'open'
  AND w.due_by IS NOT NULL
  AND w.due_by < date('now', 'localtime')
ORDER BY w.due_by, w.work_order_id;

-- Places on an open order or a planned visit that still need a ZenSched
-- location (location_create, $0.03). One row per place.
CREATE VIEW IF NOT EXISTS needs_location AS
SELECT
  p.place_id,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.street_name,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Property - ' || COALESCE(p.street_name, p.address)) AS zensched_location_name,
  p.zensched_location_id,
  p.access_notes,
  p.is_repeat_site,
  1                                                AS needs_location,
  'loc-place-' || p.place_id                       AS loc_idempotency_key,
  (SELECT COUNT(*) FROM work_orders w WHERE w.place_id = p.place_id AND w.status = 'open') AS open_orders,
  (SELECT COUNT(*) FROM visits v WHERE v.place_id = p.place_id AND v.status = 'planned') AS planned_visits
FROM places p
WHERE p.zensched_location_id IS NULL
  AND (
    EXISTS (SELECT 1 FROM work_orders w WHERE w.place_id = p.place_id AND w.status = 'open')
    OR EXISTS (SELECT 1 FROM visits v WHERE v.place_id = p.place_id AND v.status = 'planned')
  )
ORDER BY p.place_id;

-- Uninvoiced billable work grouped by client, with the billing contact and
-- terms. Completed orders bill the fee plus rush; no_access / cancelled bill
-- other_fee only (see billable_orders).
CREATE VIEW IF NOT EXISTS receivables_by_client AS
SELECT
  cl.client_id,
  cl.client_name,
  cl.client_type,
  cl.contact_name,
  cl.billing_email,
  cl.payment_terms_days,
  COUNT(b.work_order_id)                           AS order_count,
  SUM(CASE WHEN b.status = 'completed' THEN 1 ELSE 0 END) AS completed_count,
  SUM(CASE WHEN b.status = 'no_access' THEN 1 ELSE 0 END) AS no_access_count,
  SUM(b.visits_made)                               AS visits_made,
  SUM(b.billable_total)                            AS total_billable,
  MIN(b.received_date)                             AS first_date,
  MAX(COALESCE(b.completed_date, b.received_date)) AS last_date
FROM billable_orders b
JOIN clients cl ON cl.client_id = b.client_id
WHERE b.invoiced = 0
  AND b.status IN ('completed', 'no_access', 'cancelled')
  AND b.billable_total > 0
GROUP BY cl.client_id
ORDER BY total_billable DESC;

-- Unpaid invoices with aging. days_past_due is negative while not yet due.
--   current : not yet due
--   30      : 1-30 days past due
--   60      : 31-60 days past due
--   90+     : more than 60 days past due (chase now; stop taking their work?)
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  i.invoice_id,
  i.invoice_number,
  cl.client_id,
  cl.client_name,
  cl.client_type,
  cl.contact_name,
  cl.billing_email,
  cl.payment_terms_days,
  i.invoice_date,
  i.due_date,
  i.sent_date,
  i.total_amount,
  CAST(julianday(date('now', 'localtime')) - julianday(i.due_date) AS INTEGER) AS days_past_due,
  CASE
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 0  THEN 'current'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 30 THEN '30'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 60 THEN '60'
    ELSE '90+'
  END                                              AS aging_bucket,
  CASE WHEN i.due_date < date('now', 'localtime') THEN 1 ELSE 0 END AS overdue
FROM invoices i
JOIN clients cl ON cl.client_id = i.client_id
WHERE i.paid = 0
ORDER BY i.due_date;

-- Mileage by calendar month: trips, miles, and the deduction at the snapshot rate.
CREATE VIEW IF NOT EXISTS mileage_by_month AS
SELECT
  strftime('%Y-%m', m.trip_date)                   AS month,
  COUNT(m.trip_id)                                 AS trips,
  SUM(m.miles)                                     AS miles,
  SUM(m.deduction)                                 AS deduction,
  SUM(CASE WHEN m.visit_id IS NULL THEN m.miles ELSE 0 END) AS non_visit_miles
FROM mileage m
GROUP BY strftime('%Y-%m', m.trip_date)
ORDER BY month DESC;

-- Agency mode: unpaid 1099 payouts, one row per visit, with a running total
-- per inspector (inspector_total_due). Owner rows never appear.
-- needs_amount = 1 means the inspector has no payout_type; ask the owner.
CREATE VIEW IF NOT EXISTS payouts_due AS
SELECT
  p.payout_id,
  i.inspector_id,
  i.inspector_name,
  i.email,
  i.payout_type,
  i.payout_value,
  v.visit_id,
  w.work_order_id,
  COALESCE(w.client_order_ref, w.work_order_ref)   AS order_label,
  w.order_type,
  w.status                                         AS order_status,
  date(COALESCE(substr(v.checked_in_at, 1, 19), v.scheduled_start)) AS work_date,
  v.occupancy,
  b.billable_total,
  p.amount,
  CASE WHEN p.amount IS NULL THEN 1 ELSE 0 END     AS needs_amount,
  SUM(p.amount) OVER (PARTITION BY i.inspector_id) AS inspector_total_due,
  w.invoiced                                       AS client_invoiced
FROM payouts p
JOIN inspectors i ON i.inspector_id = p.inspector_id
JOIN visits v ON v.visit_id = p.visit_id
JOIN work_orders w ON w.work_order_id = v.work_order_id
JOIN billable_orders b ON b.work_order_id = w.work_order_id
WHERE p.paid = 0
  AND i.is_owner = 0
ORDER BY i.inspector_name, work_date;

-- Agency mode: completed visits worked by a sub that have no payouts row yet.
-- The agent inserts one per row when recording results.
CREATE VIEW IF NOT EXISTS payouts_missing AS
SELECT
  v.visit_id,
  w.work_order_id,
  COALESCE(w.client_order_ref, w.work_order_ref)   AS order_label,
  w.order_type,
  v.status,
  date(COALESCE(substr(v.checked_in_at, 1, 19), v.scheduled_start)) AS work_date,
  v.occupancy,
  i.inspector_id,
  i.inspector_name,
  i.payout_type,
  i.payout_value,
  b.billable_total
FROM visits v
JOIN inspectors i ON i.inspector_id = v.inspector_id AND i.is_owner = 0
JOIN work_orders w ON w.work_order_id = v.work_order_id
JOIN billable_orders b ON b.work_order_id = w.work_order_id
WHERE v.status = 'completed'
  AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.visit_id = v.visit_id)
ORDER BY work_date;

-- Per inspector, last 30 days: visits completed, occupancy mix, ad hoc share,
-- and the share whose check-in was GPS-verified. Owner included so the solo
-- inspector sees their own numbers.
CREATE VIEW IF NOT EXISTS inspector_activity AS
SELECT
  i.inspector_id,
  i.inspector_name,
  i.is_owner,
  i.is_active,
  COUNT(v.visit_id)                                AS visits_30d,
  SUM(CASE WHEN v.occupancy = 'vacant' THEN 1 ELSE 0 END)          AS vacant_30d,
  SUM(CASE WHEN v.occupancy = 'occupied' THEN 1 ELSE 0 END)        AS occupied_30d,
  SUM(CASE WHEN v.occupancy = 'inaccessible' THEN 1 ELSE 0 END)    AS inaccessible_30d,
  SUM(CASE WHEN v.is_adhoc = 1 THEN 1 ELSE 0 END)                  AS adhoc_30d,
  SUM(CASE WHEN v.gps_verified = 1 THEN 1 ELSE 0 END)              AS gps_verified_30d,
  CASE WHEN COUNT(v.visit_id) > 0
       THEN round(100.0 * SUM(CASE WHEN v.gps_verified = 1 THEN 1 ELSE 0 END) / COUNT(v.visit_id), 1) END AS gps_verified_pct,
  SUM(CASE WHEN v.photo_count > 0 THEN 1 ELSE 0 END)               AS with_photo_30d,
  MAX(COALESCE(substr(v.checked_in_at, 1, 16), v.scheduled_start)) AS last_visit_at,
  (SELECT COUNT(*) FROM visits v2 WHERE v2.inspector_id = i.inspector_id AND v2.status = 'planned'
     AND v2.scheduled_start >= strftime('%Y-%m-%dT%H:%M', 'now', 'localtime')) AS planned_ahead
FROM inspectors i
LEFT JOIN visits v ON v.inspector_id = i.inspector_id
  AND v.status = 'completed'
  AND date(COALESCE(substr(v.checked_in_at, 1, 19), v.scheduled_start)) >= date('now', 'localtime', '-30 days')
GROUP BY i.inspector_id
ORDER BY visits_30d DESC, i.inspector_name;

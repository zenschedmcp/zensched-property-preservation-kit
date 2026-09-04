# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for a first day of operation, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

The business is **Heartland Field Services**, a solo inspector (Jordan Hale) in Independence, Missouri, Central time (`-05:00` in September), with one 1099 sub (Chris Nguyen) paid $12 a visit. IDs and responses are illustrative. ZenSched IDs are integers. Watch what does **not** cross to ZenSched: occupant names, lockbox codes, gate codes, Jordan's client contact. ZenSched sees `WO 88217 - Elm St`, a street address, a same-day event with that title, 30-minute shifts, GPS punches, and Field Reports with occupancy / condition / photos.

The client is **Apex National Field** — a national vendor in the MCS / Safeguard / ServiceLink *shape* (they dispatch occupancies by order number and pay net 30). This kit does not talk to those portals; Jordan still uploads photos there. Apex is who gets the invoice.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My Field Services, timezone_offset = -05:00, state = NULL,
    default_inspector_id = NULL, default_visit_minutes = 30,
    invoice_due_days = 30, invoice_prefix = INV, report_form_id = NULL, irs_mileage_rate = 0.70
sqlite_query:   SELECT * FROM orders_overdue;     → (none)
sqlite_query:   SELECT * FROM orders_due_today;   → (none)
sqlite_query:   SELECT * FROM visits_today;       → (none)
```

## Monday: "We're Heartland Field Services in Independence, Missouri, Central time. I'm Jordan Hale, jordan@heartlandfield.example, 816-555-0140. I've got one 1099, Chris Nguyen, chris@heartlandfield.example, I pay him $12 a visit. Set us up."

```
sqlite_execute: UPDATE settings SET value = 'Heartland Field Services' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '-05:00' WHERE key = 'timezone_offset';
sqlite_execute: UPDATE settings SET value = 'MO' WHERE key = 'state';
```

Agent (first metered call this session, rule 11):

> Saved. Since you're also an inspector on the phone, I need to invite you to ZenSched as a worker so your visits show up in the app, and Chris too; that's $0.25 each, one time. If the account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
worker_invite:
  email: "jordan@heartlandfield.example"
  first_name: "Jordan"
  last_name: "Hale"
  idempotency_key: "worker-jordan@heartlandfield.example"
  → worker_id: 701, status: "invited", invitation_sent: true
    billing: { meter: "worker_invite", units: 1, price: 0.25 }

sqlite_execute:
  INSERT INTO inspectors (inspector_name, email, phone, zensched_worker_id, is_owner)
  VALUES ('Jordan Hale', 'jordan@heartlandfield.example', '816-555-0140', 701, 1);
  → lastInsertRowid = 1

sqlite_execute: UPDATE settings SET value = '1' WHERE key = 'default_inspector_id';

worker_invite:
  email: "chris@heartlandfield.example"
  first_name: "Chris"
  last_name: "Nguyen"
  idempotency_key: "worker-chris@heartlandfield.example"
  → worker_id: 702, status: "invited"      ($0.25)

sqlite_execute:
  INSERT INTO inspectors (inspector_name, email, zensched_worker_id, is_owner, payout_type, payout_value)
  VALUES ('Chris Nguyen', 'chris@heartlandfield.example', 702, 0, 'per_visit', 12);
  → lastInsertRowid = 2
```

> You're both invited; install the app from the email. Next, the Field Report: it's free to create and every visit comes back with occupancy, condition, issues, exterior photos, and optional meter shots. No signature pad on it, on purpose. Want me to set it up now?

Owner: *"yes"*

```
form_create:
  title: "Field Report"
  idempotency_key: "form-field-report"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Field report", "text": "Fill in before you drive off. Occupancy and condition only. Do not write occupant names, lockbox codes, gate codes, or loan numbers here — those stay with the office."},
  {"type": "select", "label": "Occupancy", "identifier": "occupancy", "required": true,
   "options": ["Occupied", "Vacant", "Unknown", "Inaccessible"]},
  {"type": "select", "label": "Property condition", "identifier": "property_condition", "required": true,
   "options": ["Secure", "Unsecure", "Damaged"]},
  {"type": "multi_select", "label": "Issues", "identifier": "issues",
   "options": ["None", "Broken window", "Open door", "Debris", "Lawn overgrown", "Utilities on", "Squatters suspected", "Other"]},
  {"type": "photo", "label": "Exterior photos", "identifier": "exterior", "max_images": 6, "required": true},
  {"type": "photo", "label": "Utilities / meters", "identifier": "utilities_meters", "max_images": 2},
  {"type": "textarea", "label": "Notes", "identifier": "notes"},
  {"type": "textarea", "label": "Why inaccessible", "identifier": "inaccessible_reason",
   "show_if": {"field": "occupancy", "op": "equals", "value": "inaccessible", "action": "show"}}
]
```

```
  → form_id: 501, fields: [ ...8 fields echoed with identifiers occupancy, property_condition, issues, exterior, utilities_meters, notes, inaccessible_reason... ]

sqlite_execute: UPDATE settings SET value = '501' WHERE key = 'report_form_id';
```

> Field Report created; I'll attach it to every stop automatically. One thing to tell Chris: no occupant names, lockbox codes, or gate codes in the form. Now the check-in policy: I'd like a 100 m radius, a 45-minute early/late window so you can punch when you actually get there (and so an "I'm here now" window I open while you're parking still takes the punch), and a check-out reminder 15 minutes after a window ends. OK?

Owner: *"yes"*

```
policy_update:
  policy_id: 0
  settings_json: "{\"checkin_radius_m\": 100, \"checkin_slack_min\": 45, \"checkout_reminder_min_after\": 15}"
  → policy_id: 0, updated: [ "checkin_radius_m", "checkin_slack_min", "checkout_reminder_min_after" ]
```

## Tuesday: "Apex National Field sent today's occupancies. Take them, first stop 8:00, then every 45 minutes."

> *From: dispatch@apexnational.example — Heartland, four occupancy inspections due 9/8, Independence / KC metro. Our file numbers below. Standard $18. Rush the Oak Ave — need it this morning.*
>
> *88217  1418 Elm St, Independence MO 64050  Occupancy. Last known: vacant. Lockbox 4481 side door. Due 9/8.*
> *88218  2204 Oak Ave, Kansas City MO 64127  Occupancy RUSH. Gated, code 9912. Occupant of record Maria Santos. Due 9/8.*
> *88219  88 Maple Ct, Raytown MO 64133  Occupancy. Due 9/8.*
> *88221  315 Pine Rd, Blue Springs MO 64014  Occupancy. Due 9/8.*

The agent parses: client Apex National Field (national vendor, MCS-like), four occupancy orders, all due 2026-09-08, $18, 88218 rush, occupant / lockbox / gate **local only**.

```
sqlite_query: SELECT client_id, payment_terms_days FROM clients WHERE client_name LIKE 'Apex%';   → (none)

sqlite_execute:
  INSERT INTO clients (client_name, client_type, contact_name, billing_email, payment_terms_days, default_fee, default_rush_fee)
  VALUES ('Apex National Field', 'national_vendor', 'Apex Dispatch', 'ap@apexnational.example', 30, 18, 10);
  → lastInsertRowid = 1
```

> I don't have Apex National Field as a client yet. I've added them as a national vendor at $18 occupancy / $10 rush; I've assumed net 30. Tell me if their schedule differs. This kit will not submit results into their portal — you'll still upload photos there.

```
sqlite_query: SELECT place_id FROM places WHERE normalized_address = '1418 elm st independence mo 64050';   → (none)
sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, access_notes, is_repeat_site)
  VALUES ('1418 elm st independence mo 64050', '1418 Elm St', 'Independence', 'MO', '64050', 'Elm St',
          'Property - Elm St', 'Lockbox 4481, side door.', 0);
  → lastInsertRowid = 1
sqlite_execute:
  INSERT INTO work_orders (client_id, client_order_ref, place_id, order_type, due_by, fee)
  VALUES (1, '88217', 1, 'occupancy', '2026-09-08', 18);
  → lastInsertRowid = 1
  (triggers fill: work_order_ref WO-2026-0001, rush_fee 10, other_fee 0)

sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, access_notes, is_repeat_site)
  VALUES ('2204 oak ave kansas city mo 64127', '2204 Oak Ave', 'Kansas City', 'MO', '64127', 'Oak Ave',
          'Property - Oak Ave', 'Gated, code 9912.', 0);
  → 2
sqlite_execute:
  INSERT INTO work_orders (client_id, client_order_ref, place_id, order_type, occupant_name, access_notes, is_rush, due_by)
  VALUES (1, '88218', 2, 'occupancy', 'Maria Santos', 'Gate 9912.', 1, '2026-09-08');
  → 2
  (trigger: WO-2026-0002, fee 18, rush_fee 10)

sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, is_repeat_site)
  VALUES ('88 maple ct raytown mo 64133', '88 Maple Ct', 'Raytown', 'MO', '64133', 'Maple Ct', 'Property - Maple Ct', 0);
  → 3
sqlite_execute:
  INSERT INTO work_orders (client_id, client_order_ref, place_id, order_type, due_by)
  VALUES (1, '88219', 3, 'occupancy', '2026-09-08');
  → 3

sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, is_repeat_site)
  VALUES ('315 pine rd blue springs mo 64014', '315 Pine Rd', 'Blue Springs', 'MO', '64014', 'Pine Rd', 'Property - Pine Rd', 0);
  → 4
sqlite_execute:
  INSERT INTO work_orders (client_id, client_order_ref, place_id, order_type, due_by)
  VALUES (1, '88221', 4, 'occupancy', '2026-09-08');
  → 4

sqlite_execute: INSERT INTO visits (work_order_id, scheduled_start) VALUES (1, '2026-09-08T08:00');   → 1
sqlite_execute: INSERT INTO visits (work_order_id, scheduled_start) VALUES (2, '2026-09-08T08:45');   → 2
sqlite_execute: INSERT INTO visits (work_order_id, scheduled_start) VALUES (3, '2026-09-08T09:30');   → 3
sqlite_execute: INSERT INTO visits (work_order_id, scheduled_start) VALUES (4, '2026-09-08T10:15');   → 4

sqlite_query: SELECT visit_id, order_label, zensched_event_title, street_address, needs_location, needs_event, needs_shift,
                     event_start_date, event_end_date, start_iso, end_iso, loc_idempotency_key, event_idempotency_key, shift_idempotency_key
              FROM visits_planned ORDER BY scheduled_start;
  → 1 | 88217 | WO 88217 - Elm St   | 1418 Elm St, Independence, MO 64050 | 1 | 1 | 1 | 2026-09-08 | 2026-09-08 | 2026-09-08T08:00:00-05:00 .. 08:30 | loc-place-1 | event-place-1-20260908 | shift-visit-1
    2 | 88218 | WO 88218 - Oak Ave  | 2204 Oak Ave, Kansas City, MO 64127 | 1 | 1 | 1 | 2026-09-08 | 2026-09-08 | 2026-09-08T08:45:00-05:00 .. 09:15 | loc-place-2 | event-place-2-20260908 | shift-visit-2
    3 | 88219 | WO 88219 - Maple Ct | 88 Maple Ct, Raytown, MO 64133      | 1 | 1 | 1 | 2026-09-08 | 2026-09-08 | 2026-09-08T09:30:00-05:00 .. 10:00 | loc-place-3 | event-place-3-20260908 | shift-visit-3
    4 | 88221 | WO 88221 - Pine Rd  | 315 Pine Rd, Blue Springs, MO 64014 | 1 | 1 | 1 | 2026-09-08 | 2026-09-08 | 2026-09-08T10:15:00-05:00 .. 10:45 | loc-place-4 | event-place-4-20260908 | shift-visit-4
```

Event titles are vendor order number + street. Maria Santos, lockbox 4481, and gate 9912 are not in `zensched_event_title` or `zensched_location_name`.

> Putting this on ZenSched costs $0.03 per new address to geocode (four here); each visit then costs $0.35 in GPS check-in/out and reading the Field Report with its photos. OK to proceed for this and future lists?

Owner: *"yes"*

```
location_create:
  name: "Property - Elm St"
  street_address: "1418 Elm St, Independence, MO 64050"
  checkin_radius_m: 100
  idempotency_key: "loc-place-1"
  → location_id: 9201, lat: 39.0912, lng: -94.4153, pin_quality: "street",
    radius_note: "Check-in radius is enforced by the talent policy ...",
    billing: { meter: "geocode", units: 1, price: 0.03 }
sqlite_execute: UPDATE places SET zensched_location_id = 9201 WHERE place_id = 1;

location_create: name "Property - Oak Ave", street_address "2204 Oak Ave, Kansas City, MO 64127", checkin_radius_m 100, idempotency_key "loc-place-2"   → 9202   ($0.03)
sqlite_execute: UPDATE places SET zensched_location_id = 9202 WHERE place_id = 2;
location_create: name "Property - Maple Ct", street_address "88 Maple Ct, Raytown, MO 64133", checkin_radius_m 100, idempotency_key "loc-place-3"     → 9203   ($0.03)
sqlite_execute: UPDATE places SET zensched_location_id = 9203 WHERE place_id = 3;
location_create: name "Property - Pine Rd", street_address "315 Pine Rd, Blue Springs, MO 64014", checkin_radius_m 100, idempotency_key "loc-place-4" → 9204   ($0.03)
sqlite_execute: UPDATE places SET zensched_location_id = 9204 WHERE place_id = 4;

event_create:
  location_id: 9201
  title: "WO 88217 - Elm St"
  start_date: "2026-09-08"
  end_date:   "2026-09-08"
  idempotency_key: "event-place-1-20260908"
  → event_id: 7301
form_assign:
  form_id: 501
  event_id: 7301
  idempotency_key: "assign-report-7301"
  → status: "assigned", form_id: 501, event_id: 7301, policy_id: 0
sqlite_execute: UPDATE visits SET zensched_event_id = 7301 WHERE visit_id = 1;

event_create: location 9202, title "WO 88218 - Oak Ave",  start_date "2026-09-08", end_date "2026-09-08", idempotency_key "event-place-2-20260908" → 7302
form_assign:  form_id 501, event_id 7302, idempotency_key "assign-report-7302"
sqlite_execute: UPDATE visits SET zensched_event_id = 7302 WHERE visit_id = 2;
event_create: location 9203, title "WO 88219 - Maple Ct", start_date "2026-09-08", end_date "2026-09-08", idempotency_key "event-place-3-20260908" → 7303
form_assign:  form_id 501, event_id 7303, idempotency_key "assign-report-7303"
sqlite_execute: UPDATE visits SET zensched_event_id = 7303 WHERE visit_id = 3;
event_create: location 9204, title "WO 88221 - Pine Rd",  start_date "2026-09-08", end_date "2026-09-08", idempotency_key "event-place-4-20260908" → 7304
form_assign:  form_id 501, event_id 7304, idempotency_key "assign-report-7304"
sqlite_execute: UPDATE visits SET zensched_event_id = 7304 WHERE visit_id = 4;

shift_create:
  event_id: 7301
  worker_id: 701
  start: "2026-09-08T08:00:00-05:00"
  end:   "2026-09-08T08:30:00-05:00"
  idempotency_key: "shift-visit-1"
  → shift_id: 89001, status: "scheduled", forms_installed: [501]
shift_create: event 7302, worker 701, "2026-09-08T08:45:00-05:00" .. "2026-09-08T09:15:00-05:00", idempotency_key "shift-visit-2" → 89002
shift_create: event 7303, worker 701, "2026-09-08T09:30:00-05:00" .. "2026-09-08T10:00:00-05:00", idempotency_key "shift-visit-3" → 89003
shift_create: event 7304, worker 701, "2026-09-08T10:15:00-05:00" .. "2026-09-08T10:45:00-05:00", idempotency_key "shift-visit-4" → 89004

sqlite_execute: UPDATE visits SET zensched_shift_id = 89001 WHERE visit_id = 1;
sqlite_execute: UPDATE visits SET zensched_shift_id = 89002 WHERE visit_id = 2;
sqlite_execute: UPDATE visits SET zensched_shift_id = 89003 WHERE visit_id = 3;
sqlite_execute: UPDATE visits SET zensched_shift_id = 89004 WHERE visit_id = 4;
```

Nothing about Maria Santos, lockbox 4481, or gate 9912 is in `name`, `title`, or `notes`. Each place has its own same-day event; a second visit to Elm this afternoon would reuse event 7301.

> Intaken **4 occupancy orders** for Apex National Field, all due today. Elm, Oak, Maple, and Pine are pinned. Stops on your phone: 8:00 88217 Elm, 8:45 88218 Oak (rush), 9:30 88219 Maple, 10:15 88221 Pine. $18 each, plus $10 rush on Oak. Occupant names and lockbox / gate codes are only on your computer; ZenSched sees "WO 88217 - Elm St". You'll still upload the photos in Apex's portal — this is your GPS record and the invoice.

## Tuesday morning: three planned stops, one inaccessible

7:58, outside 1418 Elm St, in the ZenSched app: Jordan taps **Check in** (GPS: 11 m from the pin, verified, $0.10). Walks the house. Vacant, boarded, grass cut, meters off. Four exterior photos + one electric meter. Opens **Field Report**: Occupancy = Vacant; Condition = Secure; Issues = None; Exterior = 4; Meters = 1. Submits. **Check out** 8:14 ($0.10).

8:47 at 2204 Oak Ave: the gate is locked and 9912 does not work. Check in from the street (18 m, verified). Two photos of the closed gate and the house number. Field Report: Occupancy = Inaccessible; Condition = Secure; Issues = None; Why inaccessible = "Gate locked, posted code did not work, no pedestrian access"; Exterior = 2. Check out 8:55.

9:31 at 88 Maple Ct: Check in (9 m, verified). Curtains moving, car in the drive, someone answers through the door and will not come out. Occupied. Three exterior photos. Field Report: Occupancy = Occupied; Condition = Secure; Issues = None. Check out 9:42.

## Tuesday, 10:02 am: "I'm at Pine now, running early."

The inspector is standing at the curb; speed matters. Pine was planned for 10:15.

```
sqlite_query:
  SELECT w.work_order_id, w.place_id, p.zensched_location_id, v.visit_id, v.zensched_event_id, v.zensched_shift_id
  FROM work_orders w JOIN places p ON p.place_id = w.place_id
  JOIN visits v ON v.work_order_id = w.work_order_id AND v.status = 'planned'
  WHERE w.client_order_ref = '88221';
  → wo 4 | place 4 | location 9204 | visit 4 | event 7304 | shift 89004
```

The planned window is 13 minutes out, inside the 45-minute slack — Jordan can punch the existing shift. The agent says so rather than opening a second window:

> Pine is already on your phone for 10:15–10:45. With 45 minutes of slack you can check in now. Go.

Jordan checks in at 10:03 (14 m, verified). Vacant, rear slider open, broken kitchen window, lawn overgrown. Five exterior photos + gas and electric meters. Field Report: Occupancy = Vacant; Condition = Unsecure; Issues = Broken window, Open door, Lawn overgrown; Exterior = 5; Meters = 2; Notes = "Rear slider open, kitchen window broken, lot overgrown." Check out 10:19.

(If Pine had had **no** planned window, the agent would have inserted an `is_adhoc` visit, reused event 7304, and `shift_create`'d with `scheduled_start` = now — the same "I'm here now" path as process-serving.)

## Tuesday afternoon: "Chris is circling back to Oak. The office has a new gate code. Chris at Oak now."

A second visit the same day to the same place reuses today's event.

```
sqlite_query:
  SELECT w.work_order_id, p.place_id, p.zensched_location_id,
         (SELECT v2.zensched_event_id FROM visits v2
          WHERE v2.place_id = p.place_id AND date(v2.scheduled_start) = '2026-09-08'
            AND v2.zensched_event_id IS NOT NULL LIMIT 1) AS day_event_id
  FROM work_orders w JOIN places p ON p.place_id = w.place_id
  WHERE w.client_order_ref = '88218' AND w.status = 'open';
  → wo 2 | place 2 | location 9202 | day_event_id 7302

sqlite_execute: INSERT INTO visits (work_order_id, scheduled_start, duration_minutes, inspector_id, is_adhoc)
                VALUES (2, '2026-09-08T14:20', 30, 2, 1);   → 5
sqlite_query:   SELECT start_iso, end_iso, needs_location, needs_event, zensched_event_id, zensched_worker_id, shift_idempotency_key
                FROM visits_planned WHERE visit_id = 5;
  → 2026-09-08T14:20:00-05:00 | 2026-09-08T14:50:00-05:00 | 0 | 0 | 7302 | 702 | shift-visit-5

shift_create:
  event_id: 7302
  worker_id: 702
  start: "2026-09-08T14:20:00-05:00"
  end:   "2026-09-08T14:50:00-05:00"
  idempotency_key: "shift-visit-5"
  → shift_id: 89005, status: "scheduled", forms_installed: [501]
sqlite_execute: UPDATE visits SET zensched_shift_id = 89005, zensched_event_id = 7302 WHERE visit_id = 5;
```

`needs_event = 0` because visit 2 already opened today's Oak event. One `shift_create`. The new gate code stays in `work_orders.access_notes` (local); ZenSched is not told.

> Window's on Chris's phone: 2:20–2:50 pm at Oak Ave. He can check in now.

Chris checks in at 2:22 (16 m, verified). Gate still will not open; he photographs the gate and the posted "no trespassing" sign. Field Report: Occupancy = Inaccessible; Condition = Secure; Why inaccessible = "Second attempt; new code also failed; no pedestrian gate." Exterior = 2. Check out 2:28.

## Tuesday night: "Log today's visits."

```
shift_list: date_from "2026-09-08", date_to "2026-09-08", status "checked_out"
  → [ { shift_id: 89001, worker_id: 701, event_id: 7301, actual_in: "2026-09-08T07:58:10-05:00", actual_out: "2026-09-08T08:14:40-05:00" },
      { shift_id: 89002, worker_id: 701, event_id: 7302, actual_in: "2026-09-08T08:47:05-05:00", actual_out: "2026-09-08T08:55:20-05:00" },
      { shift_id: 89003, worker_id: 701, event_id: 7303, actual_in: "2026-09-08T09:31:00-05:00", actual_out: "2026-09-08T09:42:15-05:00" },
      { shift_id: 89004, worker_id: 701, event_id: 7304, actual_in: "2026-09-08T10:03:20-05:00", actual_out: "2026-09-08T10:19:50-05:00" },
      { shift_id: 89005, worker_id: 702, event_id: 7302, actual_in: "2026-09-08T14:22:00-05:00", actual_out: "2026-09-08T14:28:30-05:00" } ]
(free)

shift_status: 89001 → punches: [ { type: "in", gps_verified: true, distance_from_site_m: 11 }, { type: "out", gps_verified: true, distance_from_site_m: 13 } ]
shift_status: 89002 → in verified 18 m, out verified 17 m
shift_status: 89003 → in verified 9 m, out verified 10 m
shift_status: 89004 → in verified 14 m, out verified 12 m
shift_status: 89005 → in verified 16 m, out verified 15 m
(free)
```

> Reading the five Field Reports with their exterior photos is about $0.75. Each bills once; after this I answer from the local record. OK?

Owner: *"go"*

```
form_submissions:
  form_id: 501
  event_id: 7301
  limit: 20
  → submissions: [
      { submission_id: 4501, worker_id: 701, event_id: 7301, submitted_at: "2026-09-08 08:13:40",
        data: { occupancy: "vacant", property_condition: "secure", issues: ["none"] },
        media: [ { field: "exterior", cdn_url: "https://cdn.zensched.com/m/.../e1.jpg" }, ... 4 exterior ... ,
                 { field: "utilities_meters", cdn_url: ".../m1.jpg" } ] }
    ], count: 1, billing: { meter: "form_media", units: 1, price: 0.15 }

form_submissions: form_id 501, event_id 7302, limit 20      ($0.30: two submissions with photos)
  → [ { submission_id: 4502, worker_id: 701, submitted_at: "2026-09-08 08:54:10",
        data: { occupancy: "inaccessible", property_condition: "secure", issues: ["none"],
                inaccessible_reason: "Gate locked, posted code did not work, no pedestrian access" }, media: [ 2 exterior ] },
      { submission_id: 4503, worker_id: 702, submitted_at: "2026-09-08 14:27:40",
        data: { occupancy: "inaccessible", property_condition: "secure",
                inaccessible_reason: "Second attempt; new code also failed; no pedestrian gate." }, media: [ 2 exterior ] } ]

form_submissions: form_id 501, event_id 7303, limit 20      ($0.15)
  → [ { submission_id: 4504, worker_id: 701, submitted_at: "2026-09-08 09:41:20",
        data: { occupancy: "occupied", property_condition: "secure", issues: ["none"] }, media: [ 3 exterior ] } ]

form_submissions: form_id 501, event_id 7304, limit 20      ($0.15)
  → [ { submission_id: 4505, worker_id: 701, submitted_at: "2026-09-08 10:18:30",
        data: { occupancy: "vacant", property_condition: "unsecure",
                issues: ["broken_window", "open_door", "lawn_overgrown"],
                notes: "Rear slider open, kitchen window broken, lot overgrown." },
        media: [ 5 exterior, 2 meters ] } ]

sqlite_execute:
  UPDATE visits SET status = 'completed', occupancy = 'vacant', property_condition = 'secure', issues = 'none',
         photo_count = 5, report_dc_id = 4501,
         checked_in_at = '2026-09-08T07:58:10-05:00', checked_out_at = '2026-09-08T08:14:40-05:00', gps_verified = 1, checkin_distance_m = 11
  WHERE visit_id = 1;
sqlite_execute: UPDATE work_orders SET status = 'completed', completed_at = '2026-09-08T07:58', completed_visit_id = 1 WHERE work_order_id = 1;

sqlite_execute:
  UPDATE visits SET status = 'completed', occupancy = 'inaccessible', property_condition = 'secure', issues = 'none',
         inaccessible_reason = 'Gate locked, posted code did not work, no pedestrian access',
         photo_count = 2, report_dc_id = 4502,
         checked_in_at = '2026-09-08T08:47:05-05:00', checked_out_at = '2026-09-08T08:55:20-05:00', gps_verified = 1, checkin_distance_m = 18
  WHERE visit_id = 2;

sqlite_execute:
  UPDATE visits SET status = 'completed', occupancy = 'inaccessible', property_condition = 'secure',
         inaccessible_reason = 'Second attempt; new code also failed; no pedestrian gate.',
         photo_count = 2, report_dc_id = 4503,
         checked_in_at = '2026-09-08T14:22:00-05:00', checked_out_at = '2026-09-08T14:28:30-05:00', gps_verified = 1, checkin_distance_m = 16
  WHERE visit_id = 5;
sqlite_execute: UPDATE work_orders SET status = 'completed', completed_at = '2026-09-08T14:22', completed_visit_id = 5 WHERE work_order_id = 2;

sqlite_execute:
  UPDATE visits SET status = 'completed', occupancy = 'occupied', property_condition = 'secure', issues = 'none',
         photo_count = 3, report_dc_id = 4504,
         checked_in_at = '2026-09-08T09:31:00-05:00', checked_out_at = '2026-09-08T09:42:15-05:00', gps_verified = 1, checkin_distance_m = 9
  WHERE visit_id = 3;
sqlite_execute: UPDATE work_orders SET status = 'completed', completed_at = '2026-09-08T09:31', completed_visit_id = 3 WHERE work_order_id = 3;

sqlite_execute:
  UPDATE visits SET status = 'completed', occupancy = 'vacant', property_condition = 'unsecure',
         issues = 'broken_window,open_door,lawn_overgrown',
         photo_count = 7, report_dc_id = 4505, notes = 'Rear slider open, kitchen window broken, lot overgrown.',
         checked_in_at = '2026-09-08T10:03:20-05:00', checked_out_at = '2026-09-08T10:19:50-05:00', gps_verified = 1, checkin_distance_m = 14
  WHERE visit_id = 4;
sqlite_execute: UPDATE work_orders SET status = 'completed', completed_at = '2026-09-08T10:03', completed_visit_id = 4 WHERE work_order_id = 4;

sqlite_query:   SELECT * FROM payouts_missing;
  → Chris Nguyen | per_visit 12 | 88218 | visit 5 | 2026-09-08 | inaccessible
sqlite_execute: INSERT INTO payouts (inspector_id, visit_id) VALUES (2, 5);      (trigger: amount 12)
```

Inaccessible on Oak still **completes** the work order — Jordan (and Chris) went and reported; Apex pays the occupancy fee. The photos stay on ZenSched; locally there is a count and the submission id. Maria Santos's name never left the local row.

> Logged five visits, four orders closed.
> - **88217** Elm St 7:58–8:14, GPS-verified 11 m: **vacant, secure**, no issues, 4 exterior + 1 meter. $18.
> - **88218** Oak Ave (rush) attempt 1 8:47–8:55, verified 18 m: **inaccessible**, gate locked, 2 photos. Attempt 2 (Chris, ad hoc) 2:22–2:28, verified 16 m: still inaccessible, new code failed, 2 photos. Closed as completed / inaccessible. $18 + $10 rush. Chris is owed $12.
> - **88219** Maple Ct 9:31–9:42, verified 9 m: **occupied, secure**, 3 photos. $18.
> - **88221** Pine Rd 10:03–10:19, verified 14 m: **vacant, unsecure**, broken window + open door + lawn overgrown, 5 exterior + 2 meters. $18.
>
> $82 receivable from Apex National Field (3 × $18 + $18 + $10 rush). I'll draft the invoice when you say. You'll still upload the photo sets in their portal — I have the submission ids (4501–4505) if you want the CDN links.

## Tuesday night: "Invoice Apex, and what do I owe Chris."

```
sqlite_query: SELECT * FROM payouts_missing;   → (none)
sqlite_query: SELECT * FROM payouts_due;
  → Chris Nguyen | per_visit 12 | 88218 | visit 5 | 2026-09-08 | inaccessible | 12.00 | inspector_total_due 12.00

sqlite_query: SELECT * FROM receivables_by_client;
  → Apex National Field | national_vendor | ap@apexnational.example | net 30 | 4 orders (4 completed) | 5 visits | 82.00

sqlite_execute:
  INSERT INTO invoices (client_id, invoice_date, due_date, total_amount, line_items)
  SELECT b.client_id, date('now', 'localtime'),
         date('now', 'localtime', '+' || (SELECT payment_terms_days FROM clients WHERE client_id = 1) || ' days'),
         SUM(b.billable_total),
         json_group_array(json_object('work_order_ref', b.work_order_ref, 'client_order_ref', b.client_order_ref,
                                      'order_type', b.order_type, 'status', b.status, 'completed_date', b.completed_date,
                                      'occupancy', b.last_occupancy, 'visits', b.visits_made, 'fee', b.fee,
                                      'rush_fee', b.rush_fee_billed, 'other_fee', b.other_fee, 'billable', b.billable_total))
  FROM billable_orders b WHERE b.invoiced = 0 AND b.client_id = 1 AND b.billable_total > 0 GROUP BY b.client_id;
sqlite_execute: UPDATE work_orders SET invoiced = 1 WHERE invoiced = 0 AND client_id = 1 AND status IN ('completed', 'no_access', 'cancelled');
sqlite_query:   SELECT invoice_number, invoice_date, due_date, total_amount FROM invoices WHERE invoice_id = last_insert_rowid();
  → INV-2026-0001 | 2026-09-08 | 2026-10-08 | 82.00
```

> Chris: 1 visit on 88218 (inaccessible callback), **$12** due. Say "paid Chris" and I'll mark it.
>
> Here's the Apex National Field invoice, ready to paste into their payables (not into a portal this kit does not have):
>
> ```
> Heartland Field Services
> Invoice INV-2026-0001
> To: Apex National Field (ap@apexnational.example)
> Date: Sep 8, 2026    Due: Oct 8, 2026 (net 30)
>
>   WO-2026-0001  Your order 88217   Occupancy   Vacant / secure     $18.00
>   WO-2026-0002  Your order 88218   Occupancy   Inaccessible (rush) $28.00
>   WO-2026-0003  Your order 88219   Occupancy   Occupied / secure   $18.00
>   WO-2026-0004  Your order 88221   Occupancy   Vacant / unsecure   $18.00
>
> Total due: $82.00
> ```
>
> No occupant names, lockbox codes, or street addresses — your order numbers identify the files. GPS-verified at each pin; photo submissions 4501–4505 on ZenSched. Say "sent" when it's out.

## Tuesday night: "Who owes me money?"

```
sqlite_query: SELECT * FROM invoices_outstanding;
  → INV-2026-0001 | Apex National Field | due 2026-10-08 | 82.00 | days_past_due -30 | current
```

> Outstanding: $82, all current (Apex INV-2026-0001, due Oct 8). I'll flag it after Oct 8 if they haven't paid.

## Summary of who stored what

| Thing | Where | Why |
|---|---|---|
| Maria Santos, lockbox 4481, gate 9912 | SQLite **only** (`work_orders.occupant_name`, `work_orders.access_notes`, `places.access_notes`) | Occupant PII and access codes never reach ZenSched |
| Apex Dispatch contact | SQLite (`clients.contact_name`) | Billing; ZenSched does not model clients |
| Apex National Field: terms, billing email, $18 / $10 rush | SQLite (`clients`) | Receivables |
| Each property address, normalized, with its ZenSched location id | SQLite (`places`) | De-dup cache; a repeat vacant skips the $0.03 geocode and keeps its pin |
| `Property - Elm St` / `Oak Ave` / `Maple Ct` / `Pine Rd` and their street addresses and GPS pins | ZenSched (ID in `places`) | Needed for geofenced check-in; labels carry the street, no names |
| One same-day event per place (`WO 88217 - Elm St`) | ZenSched (ID in `visits`) | High-volume same-day; a second Oak visit reused event 7302 |
| One shift per visit (30-minute window), planned or ad hoc | ZenSched (ID in `visits`) | The thing a GPS punch attaches to; never copied |
| Jordan and Chris as ZenSched workers | ZenSched (IDs in `inspectors`) | Solo owner is also an inspector; 1099 gets the same app |
| GPS punches, arrival time, distance from pin | ZenSched (originals); stamps copied once to `visits.checked_in_at` / `checked_out_at` / `gps_verified` / `checkin_distance_m` | Proof each visit happened where and when |
| The Field Report form | ZenSched (ID in `settings`) | Installed on the phone per shift; no signature field |
| Five Field Report submissions, exterior + meter photos | ZenSched (originals); occupancy, condition, issues, photo count, `report_dc_id` in `visits` | Read once (metered $0.15 each = $0.75); images stay on ZenSched |
| Check-in policy (100 m radius, 45 min slack, 15 min check-out reminder) | ZenSched (policy 0) | Radius and slack are enforced by the policy, not per location |
| Fees per order, $82 invoice, aging | SQLite (`work_orders`, `billable_orders`, `invoices`, `invoices_outstanding`) | Receivables from the national vendor |
| Chris's $12 payout | SQLite (`payouts`) | Per visit, not hourly; owner's own visits never generate payouts |

# ZenSched Property-Preservation Reference Kit

A copy-pasteable setup for a solo vacant-property inspector, or a 2–8 inspector shop that dispatches subcontracted (1099) field techs, that wants an AI assistant to run work-order intake, same-day GPS-verified visits, occupancy / condition photo reports, receivables from national vendors and servicers, and sub payouts. ZenSched handles the phone app, the GPS check-in at each property, the per-place same-day event and per-visit shift, and the Field Report. A small local database on your computer holds your clients, the addresses you have been to, your work orders (with occupant names and lockbox / gate codes), every visit with its GPS stamps, invoices, and payouts.

**You do not need to know how to program or write SQL to use this.** You paste a vendor work-order list into your AI assistant ("Apex sent today's occupancies, take them"), text it "I'm at Elm now", ask "what's on the board", "log today's visits", "invoice Apex", "who owes me money", "what do I owe Chris", and the AI does the work using two tools you set up once. Setup takes about 15 minutes and is the only technical part.

If you *are* a developer, skip to [For developers](#for-developers).

## This is not a Safeguard / MCS / ServiceLink portal — read this first

**What this kit is:** a way for a field-services inspector to get every stop onto their phone (planned from a pasted list, or opened on the spot when they pull up to a house), prove with a GPS-verified check-in that each visit happened at that address at that time, record what they saw (occupancy, condition, issues, exterior photos, meters), and turn those records into invoices, receivables follow-up, mileage totals, and 1099 payouts, with an AI assistant doing the clerical work.

**What it is not:**

- **It is not a national-vendor portal, and it does not submit to one.** Safeguard, MCS, ServiceLink, and the other national field-services platforms are how most of this work is *ordered*. This kit does not log into them, does not push occupancy results or photos into them, and does not generate a conveyance package. You still upload the photos and result codes in the portal the vendor gave you. The Field Report and the GPS punches are *your* record so you can invoice and pay inspectors from something you actually have.
- **It does not know HUD, FHA, GSE, or investor timelines.** How many days after vacancy a first occupancy is due, when winterization is required, what "secure" means for a given client: those are yours. `orders_due_today` and `orders_overdue` are dates you typed, not a rules engine.
- **It does not watermark photos.** ZenSched records the GPS punch coordinates and the upload time server-side, and the Field Report's exterior photos are stored with the submission, but the exported image is **not** stamped with the date, time, and coordinates. If a vendor or court later wants a readable stamp on the image itself, shoot with your phone camera's timestamp / GPS overlay turned on (or a GPS-stamp camera app) and upload *that* image.
- **It is not a lockbox manager, and it is not a loan file.** Occupant names, lockbox codes, and gate codes stay on your computer. Loan numbers, borrower SSNs, and investor IDs are not stored anywhere in this kit.

If any of that is a deal-breaker, this kit is not for you. If you want every vacant visit GPS-stamped at the curb, a photo report you can invoice from, and receivables you can actually chase, read on.

## What lives where

**ZenSched (source of truth for where the inspector was and when):**

- Locations (one per property address, cached locally so a repeat vacant is created once; the check-in radius is a policy setting)
- Workers (you, in solo mode; you plus your 1099s in agency mode, each with the mobile app)
- Events (one per property per calendar day — high-volume same-day work, not a 60-day job)
- Shifts (one per visit: a 30-minute window, planned ahead or opened on the spot, with a push notification to the inspector)
- GPS punches (check-in / check-out with distance-from-the-pin verification)
- The Field Report form (occupancy, condition, issues, exterior photos, meters, notes) and every submission with its photos

**Local SQLite database (`preservation-ops.db`, on your computer):**

- Clients: national vendors, servicers, REO / asset managers, HOAs, direct owners, with payment terms and a default occupancy / rush fee
- Places: every address you have been sent to, normalized, with its ZenSched location id and access notes (gate code, lockbox, "rear unit") — **access notes never leave your computer**
- Inspectors: you (and your 1099s); payout split per sub (per visit, or percent of the order)
- Work orders: the vendor's order number, order type, occupant name (**never leaves your computer**), due date, fee snapshot, rush flag, status
- Visits: one row per visit window, the ZenSched event (same-day, per place) and shift id, the Field Report's occupancy / condition / issues / photo count / submission id, and the GPS stamps copied once
- Mileage with the IRS rate snapshot and deduction
- Invoices per client with aging; payouts per 1099 per visit
- Your settings (timezone, default inspector, visit length, invoice terms and prefix, mileage rate, Field Report form id)

**Never duplicated:** the live schedule, punches, and photos stay in ZenSched. The local database stores *references* to them plus the few facts you need to answer "did Chris go", "what's the occupancy", and "who owes me" without paying to re-read records.

### Privacy note

Everything that identifies an occupant or opens a door lives only in the local database: `work_orders.occupant_name`, `work_orders.access_notes`, `places.access_notes`, and `clients.contact_name`. `SKILL.md` forbids the AI from putting any of them into any ZenSched field, including location names, event titles, notes, and cancellation reasons (subs see those). **Property street addresses do go to ZenSched** — the geofence cannot work without them. ZenSched receives, per stop, the street address, a location label (`Property - Elm St`), an event title made of the vendor order number and the street (`WO 88217 - Elm St`), and the Field Report. The form itself tells the inspector not to write names or codes in it.

## How it works day to day

Your AI assistant has two sets of tools:

1. **ZenSched tools** (`location_create`, `event_create`, `shift_create`, `shift_status`, `form_submissions`, ...) that talk to ZenSched over the internet.
2. **A SQLite tool** (`sqlite_query`, `sqlite_execute`) that reads and writes `preservation-ops.db` on your computer.

When you paste a work-order list, the AI extracts the client, each vendor order number, the address, the type, the rush flag, the due date, and the fee; adds the client if new; looks each address up in your `places` cache (a vacant you have been to before is reused, a new address is geocoded once); saves each order as `WO-2026-0001`; pins every new property on ZenSched and opens a **same-day event** so an unplanned "I'm here now" later is one call; and puts a visit window on your phone. You see the stop in the app, check in at the curb (GPS-verified), walk the property, fill in the Field Report with exterior photos, check out. When you decide to hit a house between two planned stops, you text the AI "I'm at Elm now" and a window is on your phone before you are out of the truck. In the evening you say "log today's visits" and the AI pulls the verified times and the reports, closes each order, and tells you what is now receivable. "Invoice Apex" produces a plain-text invoice under their terms; "who owes me money" ages what is open; "what do I owe Chris" lists his visits. You never run SQL yourself. `SKILL.md` in this repo is the instruction sheet that teaches the AI how to do all of this; you paste it into your AI tool once.

## Setup

### 0. What you need

- **An AI tool that supports MCP.** These instructions use Claude Desktop (Windows or Mac). Cursor works too.
- **Node.js 20 or newer.** The SQLite tool runs on it. Download the LTS installer from [nodejs.org](https://nodejs.org/) and run it with the defaults. This is the only software install.
- You do **not** need the `sqlite3` command-line program, Python, or Git.

### 1. Make a folder for your data

Create a folder where the database will live and write down its full path. Examples:

- Windows: `C:\Users\YourName\preservation-ops`
- Mac: `/Users/yourname/preservation-ops`

The database file will be created automatically inside this folder the first time the AI uses it. This folder will contain occupant names and lockbox / gate codes; keep it on an encrypted, backed-up disk, not in a shared folder.

### 2. Add both tools to your AI's config file

Open the MCP configuration file for your AI tool:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json` (paste that into the File Explorer address bar)
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json` (in Claude Desktop: Settings → Developer → Edit Config)
- **Cursor:** Settings → MCP → Add new global MCP server

Paste in the contents of `mcp.json.example` from this repo, then change one line, the `SQLITE_PATH`, to point at your folder from step 1 plus `\preservation-ops.db` (Windows) or `/preservation-ops.db` (Mac):

```json
{
  "mcpServers": {
    "zensched": {
      "url": "https://mcp.zensched.com/mcp",
      "headers": { "Authorization": "Bearer zsc_your_key_here" }
    },
    "preservation-ops-db": {
      "command": "npx",
      "args": ["-y", "easy-sqlite-mcp"],
      "env": { "SQLITE_PATH": "/Users/yourname/preservation-ops/preservation-ops.db" }
    }
  }
}
```

**Windows path gotcha:** inside a JSON file every backslash must be doubled. Write `"C:\\Users\\YourName\\preservation-ops\\preservation-ops.db"`, not `"C:\Users\..."`. A single backslash will silently break the config.

**Leave `zsc_your_key_here` exactly as it is for now.** You do not have a key yet. The ZenSched tools that create your account work without one, and you will fill this in during step 3.

Save the file and **fully quit and reopen** your AI tool (on Mac, Cmd-Q; on Windows, right-click the tray icon → Quit). It only reads this file on startup.

### 3. Create your ZenSched account

In a new chat, type:

> Call `zensched_guide`, then call `account_create` with org_name "My Field Services" (use my real business name if I told you one). Show me the `zsc_` key it returns.

Copy the `zsc_` key. Go back to the config file from step 2, replace `zsc_your_key_here` with your real key, save, and fully quit and reopen the AI tool again.

Some clients can adopt the key mid-session with `account_use_key`; you can ask the AI to try that to keep going immediately, but still update the config file so the key survives restarts. Keep the key private; it is the password to your account.

### 4. Create the database tables

Open `schema.sql` from this repo in any text editor, copy the whole thing, and paste it into the chat with this message in front of it:

> Create these tables in my preservation-ops database. Run each statement one at a time using the SQLite tool, then list the tables to confirm.

The AI will run 60 statements and confirm the tables exist. The `preservation-ops.db` file now exists in your folder with default settings (30-minute visit windows, net 30, $0.70/mile) you can change.

If you happen to have the `sqlite3` command-line tool, `sqlite3 preservation-ops.db < schema.sql` does the same thing, but it is not required.

### 5. Teach the AI the workflow

Paste the contents of `SKILL.md` into your AI tool as standing instructions. In Claude Desktop, create a Project and put it in the project instructions; in Cursor, save it as a rule. Then tell it your basics once:

> We're Heartland Field Services in Independence, Missouri, Central time. It's me, Jordan Hale, jordan@example.com. Set me up.

It writes those to the `settings` table, **invites you to ZenSched as a worker** (you are the inspector on the phone; $0.25, one time), creates the Field Report form on ZenSched (free), saves the form id so every stop gets it automatically, and sets the check-in policy. In agency mode you then say "add my sub Chris Nguyen, chris@example.com, I pay him $12 a visit" (or "60%") for each inspector you dispatch.

**Check-in radius and slack.** ZenSched enforces the radius through the account's policy, not per address, and with geofencing on it raises anything under 100 m to about 91 m (300 ft), so a house and its driveway are covered as is. For gated communities and rural lots where you park a long way from the pin, ask the AI to "set the check-in radius to 150 m" or 250 m (`policy_update`), or to move the pin onto the building for a repeat vacant (`location_update`, free; the `places` cache keeps it). The kit sets `checkin_slack_min` to **45**: that is the early/late tolerance around a shift, so you can punch at 7:50 for an 8:30 window, and an "I'm here now" window the AI opened a minute after you parked still accepts the punch. `remote_checkin` turns GPS verification off for every visit and should be a last resort, because it also turns off the proof.

**Forgotten check-outs.** The kit sets a check-out reminder 15 minutes after the window ends (`checkout_reminder_min_after`).

### 6. Funding (only when asked)

The first 200 ZenSched tool calls per day are free. Some things are metered: creating a location (geocoding, $0.03; skipped for a cached repeat address), inviting a worker ($0.25, including yourself), each GPS-verified check-in or check-out ($0.10), and reading a Field Report ($0.15 with the exterior photos, which the form requires; each record is billed once, ever). When a metered call happens without funds, the AI will get a `payment_required` response and tell you how to add the $5 activation deposit, which is credited to your balance. You will not be charged without seeing this first.

A visit at a new address costs $0.03 + $0.20 + $0.15 = **$0.38**; every further visit at that address, and every visit at a cached address, costs **$0.35**. Forty occupancy stops a month is about $14. The AI states the cost before it spends.

## Using it

Everything after setup is plain English. Examples:

- (paste the vendor's work-order list) "Take these." / "Take these, first stop 8:00, then every 45 minutes."
- "What's on the board today?" / "What's overdue?"
- "I'm at Elm now." / "Chris at Oak now."
- "Log today's visits." / "What was the occupancy on 88217?"
- "Did Chris actually hit Oak this morning?"
- "Invoice Apex National Field." / "Invoice everyone."
- "Who owes me money?" / "Apex paid INV-2026-0001."
- "What do I owe Chris?" / "Paid Chris."
- "Mileage for September?"

See `QUICKSTART.md` for the first-week walkthrough and `example-workflow.md` for exactly which tools the AI calls behind each of these.

### Planned windows and "I'm here now"

ZenSched only records a GPS check-in against a scheduled shift, and inspectors decide to hit a house between two planned stops. The kit handles that two ways, and `SKILL.md` teaches both:

- **Planned windows.** When a list comes in, the AI creates a visit window on the due date (or today) for each order. You can give it a route ("first stop 8:00, then every 45 minutes") or leave the default morning window and rearrange later.
- **"I'm here now."** You (or a sub, through you) text the AI "I'm at Elm now". The AI inserts a visit with `scheduled_start` = now, creates a shift from now to now + 30 minutes on that place's **existing same-day event**, and replies in one line. The inspector punches within the minute. Because every property gets its location and today's event at intake, this is a single ZenSched call.

The `checkin_slack_min` policy setting (45 minutes in this kit) is what makes both work: early or late punches around a planned window are accepted, and an ad hoc window created a minute after the inspector parked accepts the punch too. This is the kit's answer to a platform gap: ZenSched has no "check in now at location X" without a shift, so the agent creates the shift. It is one round-trip, not zero.

### What "invoice" means here

"Invoice Apex" records the invoice in your database (number, date, due date under that client's terms, total, which work orders with occupancy results and the fee breakdown) and the AI writes out a plain-text invoice you can paste into an email or the vendor's payables portal, with a line per order (your ref, their order number, type, occupancy or inaccessible, fee, rush). It does **not** generate a PDF, submit it to a national-vendor portal, or collect payment. Invoices never carry an occupant name, a lockbox code, or a street address; the vendor's order number identifies the file to them. When the client pays, tell the AI ("Apex paid INV-2026-0001") and it marks it paid. "Who owes me money" ages what is open into current / 30 / 60 / 90+ days past due.

### What "payouts" means here (agency mode)

Subs are paid per visit, not by the hour. Each sub has a split: `$12 per visit` (one payout when a visit they completed is logged), or `60%` of what the client is billed for that order. When results are logged, payout rows are created with the amount; "what do I owe Chris" lists his unpaid work and the total, and "paid Chris" marks them. Your own visits never generate payouts. The kit does not calculate taxes, issue 1099s, or pay anyone. If you also want an hours record, ZenSched's `timesheet_export(mode="hours")` is free; `mode="raw"` (one row per punch, free) is the export to hand a vendor if asked for the underlying GPS record.

## Mobile app for inspectors

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.zensched.app)
- **iOS:** [TestFlight](https://testflight.apple.com/join/Wp51m5Yq)

In solo mode you invite yourself; the email arrives at your own address, you install the app, and your visit windows appear as they are created. Each one shows the address and time; you check in on arrival (GPS-verified), walk the property, fill in the Field Report with exterior photos, and check out. Subs get the same email when you add them. iOS is TestFlight for now: builds expire every 90 days and the install is unfamiliar; ask which phones your 1099s carry.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AI says it has no ZenSched tools | Config file not saved, or the app was not fully restarted | Check the JSON is valid (paste it into [jsonlint.com](https://jsonlint.com)), then quit and reopen the app |
| AI says it has no SQLite / `preservation-ops-db` tools | Node.js not installed, or bad `SQLITE_PATH` | Install Node.js LTS; on Windows check every backslash is doubled |
| `SQLITE_PATH` points nowhere / "unable to open database" | Folder from step 1 does not exist | Create the folder; the file is created automatically but the folder is not |
| ZenSched tools return an auth error | Key still says `zsc_your_key_here`, or was pasted with a space | Re-paste the key, restart |
| `payment_required` | Metered call with no balance | Follow the instructions in the response; $5 deposit |
| AI creates shifts at the wrong hour | Timezone not set, or daylight saving changed | "Set my timezone offset to -06:00 in settings" (use your own offset; Central is -05:00 in summer, -06:00 in winter) |
| Visit not on my phone | Planned locally but the ZenSched shift was never created (`needs_shift = 1`) | "Put today's visits on my phone"; the AI finishes the intake steps |
| Check-in rejected: too early / too late | Slack window too small for a dense route | "Set the check-in slack to 60 minutes" (`checkin_slack_min`, max 240), or have the AI `shift_update` the window before you punch |
| Check-in rejected: not at the location, at a gated community or rural lot | You parked outside the policy radius, or the pin is on the road | "Set the check-in radius to 200 m" (`policy_update(0, {"checkin_radius_m": 200})`; never "on that location"), or "move the pin onto the house" (`location_update`, free; the cached place keeps it), or `location_refine` ($0.10) |
| "I'm here now" took too long and the punch was refused | Window opened more than `checkin_slack_min` after the inspector arrived | Have the AI `shift_update` the window to the real arrival time; raise the slack |
| Sub says they visited but there is no check-in | They never punched, or the phone was elsewhere | `shift_status` says `scheduled` / `missed`, or shows a punch with a large distance; that is the answer |
| Forgot to check out | Shift still `checked_in` | Tell the AI the real time; the 15-minute check-out reminder is already on |
| Field Report not on the phone | Form not assigned to that place's event before the shift was created | "Attach the Field Report to Elm" (`form_assign`), then cancel and recreate the shift |
| "Why inaccessible" shows even when Occupancy is Vacant | Conditional fields are web-only on ZenSched | Harmless; leave it blank |
| A sub typed a name or a lockbox code into the notes | Briefing slipped | The AI keeps it local and flags it; remind the sub. Codes stay on your computer, not the form |
| Same house geocoded twice | Address typed differently ("Ave" vs "Avenue", "#12" vs "Apt 12") | Tell the AI it is the same place; it merges the `places` rows and keeps one location |
| `shift_create` fails: date outside the event | The visit is on a different day than the event (events are same-day) | The AI opens a new one-day event for that place and date (free) and retries |
| Exterior photos have no date/time stamp on them | ZenSched does not watermark images | Turn on your camera's timestamp / GPS overlay before shooting if a vendor wants a readable stamp |
| Mileage deduction looks off | `irs_mileage_rate` still last year's | "Set the mileage rate to 0.72"; existing trips keep their snapshot |
| AI asks you to run SQL yourself | It does not have `SKILL.md` loaded | Re-paste `SKILL.md` as project instructions |

If something is confusing or broken in ZenSched itself, ask the AI to call `feedback_submit` with a description. It is free, needs no account, and a human reads every submission.

## For developers

**Architecture.** Two MCP servers, no application code. The agent is the integration layer; `SKILL.md` is the spec it follows. ZenSched is authoritative for operations (schedule, punches, form submissions and photos); SQLite is authoritative for clients, places, roster, work orders (including all occupant PII and access codes), visits, mileage, billing, and payouts; each side stores only the other's IDs, plus a per-visit summary and the GPS stamps cached locally because submission reads are metered. The PII boundary is enforced by data placement (occupant / code columns exist only locally, and the views compute the ZenSched-safe `zensched_location_name` / `zensched_event_title` strings) and by `SKILL.md` rules 1–2; there is no technical control stopping a misbehaving agent, so review the rules if you swap models.

**Data model decisions.**

- **Work order → place → visits.** The process-serving analog is `cases` → `serve_addresses` → `attempts`. Property preservation is one job at one property with one visit most of the time (a callback or an "I'm here now" is a second visit), so there is no separate `properties` table: `work_orders.place_id` is the assigned house and `visits.place_id` is where they actually stood (NULL → the order's place, by trigger). `places` is the address de-dup cache, same as the notary kit.
- **One event per place per calendar day.** High-volume same-day occupancy is a different shape from process-serving (event per address, windowed to `due_by`, rolled at 60 days) and from notary (one-off event per appointment). `event_create` is `start_date = end_date = the visit date`; the visit stores `zensched_event_id`; `visits_planned` / `visits_today` expose a sibling visit's event on the same place and date so a second stop (or an ad hoc punch) is one `shift_create`. A monthly occupancy of the same vacant opens a new one-day event. The 60-day event cap is irrelevant because every event is one day.
- **Planned windows vs ad hoc.** Both are `visits` rows; `is_adhoc` distinguishes them for `inspector_activity`. A planned window has a future `scheduled_start`; an ad hoc one has `scheduled_start` = now and gets a shift immediately. The kit relies on `checkin_slack_min` (45) so both accept real-world punch times. There is no punch-without-shift path on the platform; this is the workaround.
- **`places` is an address de-dup cache.** `normalized_address` is `UNIQUE`; the agent normalizes and looks it up before any `location_create`. A hit reuses `zensched_location_id`, saving the $0.03 and preserving a hand-tuned pin. `street_name` (no house number) is stored so event titles read `WO 88217 - Elm St`; `place_label` defaults to `Property - Elm St` so a repeat vacant does not keep yesterday's order number on the location.
- **`work_order_ref` and `client_order_ref`.** `work_order_ref` is the kit's own number (`WO-{YYYY of received_date}-{work_order_id:04d}`, by trigger when NULL). `client_order_ref` is the vendor's order number and is what appears in ZenSched titles (`order_label = COALESCE(client_order_ref, work_order_ref)`).
- **Solo mode is the default; agency mode is additive.** The owner is invited as a worker and stored on `inspectors` with `is_owner = 1`; `settings.default_inspector_id` points at that row and `fill_visit_defaults` assigns it when `inspector_id` is NULL. Subs are further `inspectors` rows with `payout_type` `CHECK IN ('per_visit','percent')`.
- **Inaccessible completes the order.** Occupancy `inaccessible` is still a completed visit and a completed work order: the inspector went and reported, and national vendors pay the occupancy fee for that result. `no_access` is a separate work-order status the owner sets when they close a job *without* a completed visit (weathered out, never reached); that bills `other_fee` only. `cancelled` bills `other_fee` only. `open` bills 0. That rule lives once, in `billable_orders`.
- **`billable_total` is computed in a view, not stored.** Fee columns on `work_orders` (`fee`, `rush_fee`, `other_fee`) are snapshots filled by trigger from the client's defaults. `completed` → fee + rush (if `is_rush`) + other; `no_access` / `cancelled` → `other_fee`; `open` → 0. `receivables_by_client`, the invoice `INSERT … SELECT`, `payouts_due`, and the `fill_payout_amount` trigger all read from that view.
- **Payouts key on a visit.** `payouts.visit_id` is `UNIQUE`. `fill_payout_amount` uses `payout_value` for `per_visit` and `billable_total × payout_value / 100` for `percent`; no `payout_type` leaves `amount` NULL and `payouts_due.needs_amount = 1`. `payouts_missing` lists completed sub visits without a payout row. Owner rows never appear.
- **`scheduled_start` is local wall-clock time without an offset** (`2026-09-08T08:00`, `CHECK`-constrained to reject a trailing offset or `Z`). `visits_planned` / `visits_today` / `visits_upcoming` emit `start_iso` and `end_iso` by appending `settings.timezone_offset`. Day-based views use `date('now', 'localtime')` because the SQLite MCP server runs on the owner's computer, whose clock is in the business's time zone.
- **`visits_today` includes completed.** The day's board shows what is done vs still out. `visits_upcoming` is planned only, next 7 days. `visits_planned` is the any-date source `visits_upcoming` reads.
- **No signature field on the form.** ZenSched replaces the Submit button with the signature pad when a form has a `signature` field, and the proof here is GPS + photos, not a wet signature. `exterior` is a required `photo` field (`max_images: 6`), so every submission bills $0.15.
- **GPS stamps are copied once.** `checked_in_at`, `checked_out_at`, `gps_verified`, `checkin_distance_m` are filled from `shift_status` when results are pulled, so "did Chris go" is answered locally. ZenSched remains the original.
- **`mileage`** snapshots `rate` from `settings.irs_mileage_rate` (seeded `0.70`, the 2025 IRS business rate; update yearly) and computes `deduction` by trigger. `visit_id` is nullable for supply runs.
- `visits.zensched_shift_id`, `inspectors.zensched_worker_id`, `places.normalized_address`, `work_orders.work_order_ref`, `payouts.visit_id`, and `invoices.invoice_number` are `UNIQUE`. `PRAGMA foreign_keys = ON` is in `schema.sql` and `SKILL.md` tells the agent to run it per session. Deleting a client cascades to work orders, visits, invoices, and payouts and sets `mileage.visit_id` NULL; deleting an inspector sets `visits.inspector_id` NULL and removes their payouts; `places` is `ON DELETE RESTRICT` while work orders and visits reference it; `work_orders.completed_visit_id` is `ON DELETE SET NULL`.

**Field Report form.** Created once with `form_create(title, fields_json, idempotency_key="form-field-report")`; the exact `fields_json` is in `SKILL.md` and `example-workflow.md` (byte-identical) and was validated against ZenSched's form validator (`_validate_fields`): 8 fields, all valid. Every field carries an explicit `identifier` so submission `data` keys are stable (`occupancy`, `property_condition`, `issues`, `exterior`, `utilities_meters`, `notes`, `inaccessible_reason`). Option keys are derived by ZenSched from the labels (lowercase, non-alphanumerics → `_`, truncated at 30 characters); every option label here is ≤ 30 characters, so nothing truncates: `occupancy` ∈ `occupied`, `vacant`, `unknown`, `inaccessible`; `property_condition` ∈ `secure`, `unsecure`, `damaged`; `issues` ∈ `none`, `broken_window`, `open_door`, `debris`, `lawn_overgrown`, `utilities_on`, `squatters_suspected`, `other`. One `show_if` references `occupancy` with `equals inaccessible`; the phone may show "Why inaccessible" unconditionally. Attaching is `form_assign(form_id, event_id=...)` per place-day event, once, before the first shift on that event.

**Idempotency keys.** Deterministic, derived from local IDs so a retried or re-run agent turn cannot duplicate:

- location: `loc-place-{place_id}`
- event: `event-place-{place_id}-{YYYYMMDD of the visit date}`
- shift: `shift-visit-{visit_id}` (an inspector swap on the same visit appends `-2`)
- assignment: `assign-report-{event_id}`
- cancel: `cancel-shift-{shift_id}`
- worker: `worker-{email}`
- form: `form-field-report`

ZenSched caches idempotent responses for 24 hours. The views emit `loc_idempotency_key`, `event_idempotency_key`, and `shift_idempotency_key` per row.

**Timestamps.** `shift_create` / `shift_update` take `start` and `end` in ISO 8601 with an explicit offset. Always use the business's local offset from `settings.timezone_offset` (e.g. `2026-09-08T08:00:00-05:00`), never `Z`. The views build these strings so the agent does not have to. `checked_in_at` / `checked_out_at` keep the offset ZenSched returns.

**Metered reads.** `form_submissions(form_id, event_id=...)` returns every submission on that place's event for that day; the agent matches on `worker_id` / `submitted_at` and skips submission ids already stored, which are free to skip because each submission bills once ever. `form_export` covers a day in one call. `shift_list`, `shift_status`, `event_get`, and `timesheet_export(mode="hours"|"raw")` are free.

**Check-in policy.** The radius is enforced by `policy_update(0, '{"checkin_radius_m": N}')`, not by `location_create(checkin_radius_m=...)`, which is informational; with geofencing on, values under 100 m are raised to about 91 m. `checkin_slack_min` (0–240) is the early/late window around a shift and is the setting that makes planned and ad hoc visits practical; the kit uses 100 m / 45 min / 15-minute check-out reminder.

**SQLite MCP server.** `mcp.json.example` uses [`easy-sqlite-mcp`](https://github.com/chenkumi/easy-sqlite-mcp) (Node, `better-sqlite3`, `SQLITE_PATH` env var). Its `sqlite_execute` calls `prepare()`, so it accepts **one statement per call**; `schema.sql` is written so every statement stands alone and is idempotent. `payouts_due` uses a window function (`SUM() OVER`), which needs SQLite ≥ 3.25 (2018); `better-sqlite3` bundles a current SQLite. Any SQLite MCP server with read and write tools will work; adjust the tool names in `SKILL.md`.

**Schema test.** The schema was verified by splitting the file into its 60 statements with `sqlite3.complete_statement` and executing each individually (as the MCP server does) twice for idempotency (seed rows not duplicated), then exercising: all 9 tables, 13 views, and 12 triggers present; every view on an empty database; `places.normalized_address`, `inspectors.zensched_worker_id`, `visits.zensched_shift_id`, and `payouts.visit_id` `UNIQUE`; the `number_work_order` trigger (`WO-YYYY-0001`, explicit ref kept) and `fill_work_order_defaults` (fees from the client, explicit fee kept, snapshot after a changed default); `fill_visit_defaults` (30 minutes and the default inspector, following a changed setting, explicit values kept, `place_id` from the work order); `visits_planned` / `visits_upcoming` (`start_iso` / `end_iso` with offset for `HH:MM` and `HH:MM:SS` inputs and 30/20-minute durations, the three idempotency keys, `needs_location` / `needs_event` / `needs_shift` before and after ids are set, sibling same-day event reuse, different-day `needs_event`, same-day `event_start_date` = `event_end_date`, titles from `client_order_ref` with no occupant name, 7-day window, cancelled excluded); `visits_today` including completed; `updated_at` triggers on work orders and clients; `needs_location` (unpinned open order listed, pinned place dropped); `orders_due_today` / `orders_overdue` (`days_overdue` 3, today's due excluded from overdue); `billable_orders` for completed (18), rush completed (25+10=35), open (0), `no_access` (`other_fee` 12), cancelled (`other_fee` 8), rush + other (60); `receivables_by_client` totals and the drop-off after invoicing; invoice numbering, total, due date from the client's terms, `line_items` JSON; `invoices_outstanding` aging buckets `current` / `90+` / `60` / `30` with `days_past_due` and paid excluded; payouts for `per_visit` (12), `percent` (50% of 35 = 17.50), no split (NULL), the `UNIQUE` visit key, owner exclusion, `needs_amount`, `inspector_total_due`, paid rows dropping out; `payouts_missing` for a per-visit sub; the mileage trigger (23.4 × 0.70 = 16.38, explicit rate kept, nullable visit, recompute on update) and `mileage_by_month`; `inspector_activity` counts and `gps_verified_pct` (100.0) with the owner included; every `CHECK` (client type, order type, work-order status, visit status, payout type, `scheduled_start` format with offset / `Z` / space / prose rejected, duration range, miles ≥ 0); foreign keys rejecting an unknown client, place, and work order, `RESTRICT` on places, `SET NULL` / cascade on inspector delete, and the full cascade on client delete with `mileage.visit_id` set NULL and the place surviving. 168 checks, all passing.

## Support

- ZenSched docs: <https://www.zensched.com/docs/>
- Tool reference: <https://www.zensched.com/docs/tools/>
- Feedback: ask your AI to call `feedback_submit` (categories: `bug`, `friction`, `missing_capability`, `docs`, `billing`, `feature`, `other`)

## License

MIT. See `LICENSE`.

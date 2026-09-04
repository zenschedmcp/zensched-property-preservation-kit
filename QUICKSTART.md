# Quickstart

Setup is about 15 minutes, once. After that everything is plain English to your AI. Each step below tells you what to do and, where relevant, exactly what to type to the AI.

You need: Claude Desktop (or Cursor) and [Node.js LTS](https://nodejs.org/) installed. Nothing else.

Before you start, read the "This is not a national-vendor portal" section of `README.md`. Short version: this kit puts every stop on your phone, GPS-stamps the visit, and captures the occupancy / field report. It does **not** submit results to Safeguard, MCS, ServiceLink, or any other portal, and it does not know HUD / investor timelines. Occupant names, lockbox codes, and gate codes stay on your computer; ZenSched sees a street address and a title like `WO 88217 - Elm St`.

## 1. Make a data folder

Create a folder such as `C:\Users\YourName\preservation-ops` (Windows) or `/Users/yourname/preservation-ops` (Mac). Note the full path. It will hold occupant names and access codes, so keep it on an encrypted, backed-up disk, not a shared folder.

## 2. Add the two tools to your AI's config

Open the config file:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** Settings → MCP → Add new global MCP server

Paste this in and fix only the `SQLITE_PATH` line to match your folder from step 1:

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

- On Windows, double every backslash: `"C:\\Users\\YourName\\preservation-ops\\preservation-ops.db"`.
- Leave `zsc_your_key_here` as it is. You get the real key in the next step.

Save, then **fully quit and reopen** the AI app.

## 3. Create your ZenSched account

Type to the AI:

> Call zensched_guide, then account_create with org_name "My Field Services". Show me the zsc_ key.

Copy the key into the config file in place of `zsc_your_key_here`. Save. Quit and reopen the app once more. (You can also ask the AI to call `account_use_key` with the key to continue right away, but update the file anyway so it sticks.)

## 4. Create the database tables

Copy the full contents of `schema.sql` and paste it into the chat with this line above it:

> Create these tables in my preservation-ops database. Run each statement one at a time with the SQLite tool, then list the tables to confirm.

## 5. Give the AI its instructions

Paste `SKILL.md` into the AI as standing instructions (Claude Desktop: a Project's instructions; Cursor: a rule). Then:

> We're Heartland Field Services in Independence, Missouri, Central time. It's me, Jordan Hale, jordan@example.com. Set me up.

The AI saves your settings, invites **you** to ZenSched as a worker ($0.25, once; you are the inspector on the phone), calls `form_create` once (free) to build the Field Report you fill in at every property (occupancy, condition, issues, exterior photos, meters, notes; no signature pad), stores the form id so every stop gets it, and sets the check-in policy: 100 m radius, **45 minutes of slack** so an early, late, or on-the-spot punch is accepted, and a check-out reminder 15 minutes after the window. Install the app from the invitation email ([Android](https://play.google.com/store/apps/details?id=com.zensched.app) / [iOS TestFlight](https://testflight.apple.com/join/Wp51m5Yq)).

If you work gated communities and rural lots: "Set the check-in radius to 200 m."

Agency mode: "Add my sub Chris Nguyen, chris@example.com, I pay him $12 a visit" for each 1099 inspector you dispatch. Brief every inspector once: do not type occupant names, lockbox codes, or gate codes into the Field Report.

## 6. Intake a pasted work-order list

Paste the vendor's dispatch list (email, spreadsheet rows, portal copy-paste), then:

> Take these.

Behind the scenes the AI extracts the client, each vendor order number, the address, order type (occupancy / secure / winterize / lawn / debris / lock change), rush flag, due date, fee, and any occupant / lockbox / gate notes; adds the client if new (asks for their terms and fee schedule); checks whether you have been to each address before, and if not calls `location_create` (geocode, $0.03 each, may trigger the $5 activation deposit the first time); saves each order as `WO-2026-0001` with the occupant name kept local; opens **one same-day event per property** titled `WO 88217 - Elm St` (vendor number and street, never a name); attaches the Field Report with `form_assign`; and puts a visit window on your phone with `shift_create`.

> Take these, first stop 8:00, then every 45 minutes.

Same, with the windows where you said.

## 7. The visit

Your phone shows the window with the address. At the property, **Check in** (GPS-verified). Walk it. Open the **Field Report** on the shift: occupancy, condition, issues, exterior photos (required, up to 6), meters if you can see them, notes. If you cannot get on the lot, Occupancy = Inaccessible and say why. Submit. **Check out**.

## 8. "I'm at this address"

You decide to hit a house on the way between two planned stops:

> I'm at 2204 Oak now.

The AI opens a 30-minute window on your phone starting now (one `shift_create` on that place's event for today; a few seconds) and replies in one line. Check in, inspect, record, check out. For a sub: "Chris at Elm now."

## 9. Log the results

> Log today's visits.

The AI pulls the GPS-verified check-in and check-out for each window (free), reads each Field Report once (metered, so it tells you the cost first, $0.15 each because exterior photos are required), updates every visit with occupancy, condition, issues, photo count, and times, and closes the work order (including inaccessible — you went and reported). If a sub is paid per visit, the payout row is created now. It tells you what is now receivable.

> Did Chris actually hit Oak this morning?

Answered from ZenSched's punch record: checked in 8:41 am, 14 m from the pin, out 8:52, four exterior photos. Or: no check-in.

## 10. Money

> Invoice Apex National Field.

A plain-text invoice under their terms with one line per work order (your ref, their order number, type, occupancy result or inaccessible, fee, rush). Nothing about occupants, lockboxes, or street addresses they already have.

> Who owes me money?

Open invoices aged current / 30 / 60 / 90+ days past due.

> Apex paid INV-2026-0001.

Marks it paid.

Agency: "What do I owe Chris?" lists his unpaid visits and the total; "paid Chris" marks them.

## What next

- `README.md` for the full explanation, the portal / privacy / photo boundaries, troubleshooting table, and developer notes
- `example-workflow.md` to see the exact tool calls behind each step above

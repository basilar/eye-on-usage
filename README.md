# EYE.ON

An independent app. Not affiliated with, or endorsed by, E.ON Hungária.

iOS 26 app for quarter-hourly electricity consumption and inverter feed-in from the E.ON Hungária remote-reading portal. Home Screen and Lock Screen widgets, a Control Center control, and Siri/Shortcuts actions.

```
open EonUsage.xcodeproj        # Xcode 26.6, Swift 6, iOS 26 deployment target
./deploy-phone.sh              # or build straight to a paired iPhone (--help for options)
```

Targets: `EonUsage` (app) and `EonUsageWidgets` (WidgetKit extension). `EonUsageCore/` is compiled into both.

Charts without an account: `--demo` launch argument, or **Explore with sample data** on the login screen.

## Distribution

Display name **EYE.ON**; bundle ids stay `hu.randart.EonUsage[.widgets]`, which are not user-visible.

iPhone only (`TARGETED_DEVICE_FAMILY = 1`, all four configurations — the extension's family has to match its host). The layout is single-column with no size-class handling, so claiming iPad would mean iPad screenshots and a reviewer judging it as an iPad app.

- `PrivacyInfo.xcprivacy` in **both** targets — `EonUsageCore` is compiled into the widget too, so both binaries touch `UserDefaults` and both need the required-reason declaration (`1C8F.1` for the App Group defaults, `CA92.1` for the fallback to the app's own).
- The only thing declared as collected is coarse location, for the weather overlay. Requests round the coordinate to two decimals — about a kilometre, finer than the cloud model's own grid — so nothing more precise than that leaves the device. The App Store privacy label must say the same.
- `ITSAppUsesNonExemptEncryption = false` in both Info.plists: HTTPS only, so exempt, and declaring it stops App Store Connect asking on every upload.
- App Review cannot sign in to a private E.ON account. **Point the reviewer at "Explore with sample data" on the login screen** — an un-reviewable login is the most common rejection for an app shaped like this one.

## Portal API

`https://e-portal.eon-hungaria.com/w1000/tavleolv` is an Expo/React-Native-Web front end on two SAP Gateway OData V2 services. It replaced the old ASP.NET W1000 app at `energia.eon-hungaria.hu/W1000`. The Home Assistant endpoints (`/Account/Login`, `/ProfileData/ProfileData`) are gone.

Endpoints below come from the JS bundles:

- `/sap/bc/bsp/sap/zxweb_w1000/_expo/index.js`
- `/sap/bc/bsp/sap/zwb5_ugyint/bundle.js`

Common headers: `Accept: application/json`, `Content-Type: application/json`, `X-Requested-With: X`. Payloads sit under `d`.

### Account service — `/sap/opu/odata/sap/ZWB5_ONLINE_SRV` (`sap-language=HU`)

| Call | Shape |
|---|---|
| `POST /Login` | `{Username, Password, Guid:"", Channel:"WEB", PasswordInit:false, FbId:"", Selectedelmu:false, Delegate:false, Recaptcha:"", Fb:false, KauGuid:"", ServerEvent:"L000", Partners:{results:[]}, Message:{results:[]}}` → `{Ok, Guid, Partners:{results:[{Partner, Sparte, Authid}]}, Message:{results:[…]}}` |
| `POST /Session` | `{Authid, Channel:"WEB", Guid, Partner, ServerEvent:"changePartner", Vkont:"", Vstelle:"", Message:{results:[]}}` |

`Password` is the UTF-8 password, base64-encoded (same as the web client). Empty `Recaptcha` is accepted; a bad login still returns the usual “check your e-mail and password” message, not a captcha challenge.

`Guid` is the session token.

### Metering service — `/sap/opu/odata/sap/ZWB5_W1000` (`sap-language=H`)

Send the GUID as a bearer token in both `Authorization` and `AuthorizationERP`.

| Call | Returns |
|---|---|
| `GET /Pod(Partner='…')?$expand=Pods` | `d.Pods.results` — `{Pod, Sparte, …}` |
| `GET /Intervals` | `d.results` — `{IntervalId, Description, Sparte, Horizon}`; `Horizon` is the max days per request |
| `GET /Variables` | `d.results` — `{MeasVarId, Description, IntervalId, Sparte, Aggregate}` |
| `GET /MeasData(Pod='…',MeasVarList='1,2',Interval='1',StartDate=datetime'2026-09-01T00:00:01',EndDate=datetime'2026-09-01T23:59:59')?$expand=MeasDatas` | `d.MeasDatas.results` — `{Timestamp, MeasVarList, Value1…ValueN}` |

`MeasVarList` lists the requested ids in order, so `Value1` is the first id. Values are strings. `""` is “no reading”, not zero.

`Sparte` is the SAP division: `01` electricity, `02` gas.

A cancelled request (`URLError.cancelled`) is surfaced as `CancellationError`, not as a transport failure — stepping quickly through months cancels each fetch in flight, and that is not an unreachable portal.

### Timestamps

`Timestamp` is OData V2 `/Date(epochMillis)/`. The service stores the meter’s local wall-clock time in that epoch. The portal client renders with `timeZone: "UTC"`, so decode the epoch and read the components in UTC (`Calendar.sapWallClock`). Device local time will shift every reading.

## App flow

1. Sign in, choose the electricity partner, `Session` selects it.
2. `Pod(...)` lists delivery points. One point is selected automatically; several points get a picker.
3. `Intervals`: prefer a description containing `"15"`, otherwise the tightest `Horizon`.
4. `Variables` at that interval are tagged **from grid** / **to grid** from the names: signed `+A` / `-A` first, then OBIS `1.8.0` / `2.8.0`, then Hungarian wording (`vételezett`, `betáplált`, `termelés`, …). Unknown names stay “other” and are not charted. There is no UI for correcting this — the `+A`/`-A` naming has proved reliable — but `Preferences.channelOverrides` is still honoured, so an override stored by an earlier version keeps working.
5. Readings come in `Horizon`-sized chunks and become signed samples: consumption above the baseline, feed-in below.

Day view keeps the 15-minute slots. Week is hourly, month is daily. Cumulative registers (`Aggregate == false`) are not summed.

The chart draws the whole calendar window whether or not the portal has filled it, so a month starts on the 1st, ends on the last day, and leaves the days it has no readings for blank. Nothing beyond today is requested.

The header names the window and opens a calendar for jumping to any date up to today, with a **Today** button beside it. Flicking the chart left or right steps the window; the arrows do the same and stay for accessibility and to show when the window already contains today.

Scrubbing the chart for values is a drag on the same surface, so the two are told apart by velocity: only a thrown gesture pages.

## Caching

A published reading never changes, so days the portal has finished are written to `readings/` in the App Group container and never fetched again. A month costs one request for the newest day or two; scrolling back through history is free after the first visit.

Raw portal rows are cached rather than the mapped series, so correcting a channel's direction in Settings re-renders history from disk instead of re-downloading it.

A day is cached once it is over **and** the portal has stopped adding to it — either its readings reach the end of the day, or the day is more than a week old and its gaps are permanent. Days with no readings are never cached. Sign-out clears the lot; the cache is keyed by delivery point, so switching PODs needs no eviction.

## Widgets and Shortcuts

When a single day is on screen the app writes a `UsageSnapshot` (day totals plus 24 hourly buckets) into the `group.hu.randart.EonUsage` App Group and reloads the widget timelines. Widgets never call the portal themselves — the widget extension cannot read the app's keychain item, so it could not sign in.

The feed-in check publishes a snapshot too, for the newest finished day in the window it fetched. That is what keeps a widget current for someone who has not opened the app in a week: the daily Shortcuts automation refreshes the alert and the widget together. It never moves a widget backwards, and it only runs while the feed-in alert is on, since the alert is what does the fetching.

Widgets print the day they are showing, so a stale one is visible as a stale one.

- `UsageWidget` — small, medium, Lock Screen rectangular and inline.
- `UsageControl` — Control Center button with the latest net balance.
- `EnergySummaryIntent` / `OpenDashboardIntent` — Siri and Shortcuts (usable from Home automations).

Apple’s Home app cannot show this data. Third-party apps cannot add UI there, and Home does not render energy or power even from Matter devices that report it.

## Cloud cover

Optional grey overlay showing hourly sky cover over the delivery point, so a thin day for the inverter can be read against the weather that caused it.

Source is [Open-Meteo](https://open-meteo.com): no account, no key — this app has nowhere safe to keep one, having no server — and, more to the point, it serves *history*, which is what these charts almost always show. Two endpoints, because neither covers everything:

| | covers |
|---|---|
| `api.open-meteo.com/v1/forecast` | about the last 93 days and a fortnight ahead, best available model |
| `archive-api.open-meteo.com/v1/archive` | ERA5 back to 1940, about five days in arrears |

Windows ending more than a week ago go to the archive, everything else to the forecast endpoint.

`timezone=auto` is what makes it line up: Open-Meteo then returns local wall-clock stamps with no offset (`2026-09-03T12:00`), the same convention W1000 uses, so both read correctly on `Calendar.sapWallClock`.

**Day view only.** Hourly cover averaged across a week or a month says almost nothing — the interesting question is which hours of *this* day were overcast, and that resolution is gone once a bar is a whole day.

The curve is drawn over the bars, held back by opacity so they still read through it, and shares the energy axis's own extent: 0% sits on the bottom gridline, 100% on the top one, labelled up the right-hand side. One set of gridlines rules both scales, so the two read against each other rather than merely being superimposed.

Asked for *today*, the service answers with all twenty-four hours — the rest of them forecast — so cloud samples past the current hour are dropped before drawing. Clamping the date range does not help in that case: the window already is today. The comparison is made on the meter's wall clock, not against a bare `Date()`, which would throw away the last two measured hours every summer afternoon.

A second overlay shades the hours the sun was down, from the same request's `daily=sunrise,sunset`. The shaded stretches are derived by *inverting* the daylight rather than drawing it: a window can open mid-morning or close before dusk, and the night either side of a day is two spans, not one.

Both switches are toolbar buttons in the day view — cloud and sun — not settings, because they are things you flick on and off while looking at a chart. Settings only holds the location.

The trailing percentage axis is always laid out, its labels hidden rather than removed when the cloud overlay is off. Dropping the axis would give its width back to the plot and slide every bar sideways each time the button was pressed.

Set the location in Settings, by device or by searching for a place (Open-Meteo geocoding). Until one is set there is no cloud button. It is a fixed coordinate, asked for once — a delivery point does not move, so nothing is tracked. Only the coordinate is ever sent, never the readings. Settled ranges are cached on disk like the readings are.

## Feed-in alert

Warns when the inverter stops exporting. Off by default. Enable it in Settings; threshold 12 / 24 / 36 / 48 / 72 hours (24 by default).

Local notifications only. There is no server. The readings are already a day old when E.ON publishes them.

The gap is from the last exporting bucket to the newest reading on the portal, not to “now”. Using the clock would treat E.ON’s publishing delay as a fault.

- Empty response: no alarm.
- No export in the fetched window: gap is a lower bound (export may have stopped earlier).
- Below 1 Wh per bucket is treated as meter noise, not export.
- Warning at most once per 24 hours while the fault lasts; a “feed-in resumed” notification when it recovers.
- Thresholds under a day will fire on ordinary overnight lulls (Settings mentions this).

### Output drop

The gap check alone misses the commonest inverter failure: one that half-dies and keeps trickling a few watts. Every bucket clears the noise floor, the silence never begins, and no alarm ever fires.

`OutputWatch` asks the other question — is the export still the *size* it used to be? — measured against the site's own recent history, the only baseline available without a weather feed.

- The statistic is the **peak 15-minute bucket**, not the daily total. Cloud halves a daily total routinely; it does not stop a working array spiking during a break in the weather.
- The recent window is scored by its **best** day, the baseline by its **median**. One clear hour on any recent day clears the alarm, and a run of cloud cannot drag the reference down.
- Baseline is 21 days ending just before the recent window, so seasonal decline moves the reference with it. Fewer than 7 baseline days, or a normal peak under 0.05 kWh per bucket, is inconclusive — not healthy, and never an alarm.
- Sensitivity is a setting: off, or below 50 / 35 / 20 / 10 % of normal. 20 % by default.
- An inconclusive verdict says *why* — how many days it had against how many it needs, or how small the normal peak is — in Settings and in the "Check now" line. Showing nothing would be indistinguishable from a healthy site.
- Recovery releases at 1.5× the trigger ratio, so it cannot flap across the threshold.

Weeks of history would be dear to fetch on every check; the readings cache means only the newest day or two actually reaches the portal.

### Running it without opening the app

The check runs when the dashboard loads (at most once every three hours) and from a `BGAppRefreshTask` (`hu.randart.EonUsage.feedInCheck`) requesting a slot every six hours.

**Do not rely on the background task.** iOS grants background refresh in proportion to how often an app is opened, so an alarm you never open the app to read is the first thing it starves — the failure mode and the mitigation are the same thing.

The dependable path, with no server in the design, is to schedule it yourself: a Shortcuts personal automation, Time of Day, Run Immediately, running the **Check feed-in health** action (`CheckFeedInIntent`). It never opens the app, so nothing appears unless something is wrong. Settings spells out the steps.

`CheckFeedInIntent` is declared in the app target, not `EonUsageCore`: Core is built into the widget extension too, and an intent resolved there would run in a process that cannot read the app's keychain item, so the check could not sign in.

## App icon

A redrawing of the E.ON mark — the eye with a lightning bolt cut through the crescent above it — squared off to fill the tile rather than sitting as a circle inside it, which reads better once iOS has masked it. Light, dark and tinted variants.

```
swift Tools/make-icon.swift    # redraws all three into the asset catalogue
```

The geometry lives in that script rather than in a pile of exported PNGs, so it can be adjusted. Checked down to 60 px, where the bolt and pupil still separate. Being E.ON's trademark, it suits a personal build; it would need replacing before any wider distribution.

## Chart colours

Feed-in is green, from-grid is red. Fixed slot order, checked as a categorical pair on both surfaces: Machado severity-1.0 CVD simulation, CIEDE2000, worst case over normal / protan / deutan / tritan — ΔE 21.9 (light) and 28.8 (dark), gate ≥ 8, both steps above 3:1 contrast.

Red against green is the pair CVD punishes hardest, and system red against system green scores 7.9 in dark mode — below the gate. These two are pulled far apart in lightness instead, red the darker on both surfaces, so the bars stay separable by brightness once the hue collapses. That is why the light green is a strong mid green and the dark green a pale mint. Re-run the numbers before changing them.

## Balance figures

The tile under the chart reads the window's net position twice — once in kWh, once against what was drawn — and both wear the same colour: red for a net import, green for a net export, plain when they cancel.

The percentage is `|taken − sent back| / taken`, anchored at break-even rather than at zero flow:

| | shows |
|---|---|
| nothing fed back | **100%** — the whole draw was net |
| feed-in equals consumption | **0%**, uncoloured |
| more fed back than drawn | the surplus over break-even: 701 kWh against 544 kWh is **29%** |

`EnergySeries.balance` names the side, so the same magnitude is never ambiguous, and "level" is tied to what is displayed — anything rounding to 0% counts, rather than a near-miss claiming a direction it cannot see.

# EYE.ON

EYE.ON is an independent app. It has no affiliation with E.ON Hungária, and E.ON Hungária does not endorse it.

EYE.ON is an iOS 26 app. It shows quarter-hourly electricity consumption and inverter feed-in from the E.ON Hungária remote-reading portal. It has Home Screen and Lock Screen widgets, a Control Center control, and Siri and Shortcuts actions.

Available on the App Store: https://apps.apple.com/us/app/eye-on/id6823543677

```
open EonUsage.xcodeproj        # Xcode 26.6, Swift 6, iOS 26 deployment target
./deploy-phone.sh              # or build straight to a paired iPhone (--help for options)
```

The project has two targets: `EonUsage` (the app) and `EonUsageWidgets` (the WidgetKit extension). Both targets compile `EonUsageCore/`.

To see the charts without an account, use the `--demo` launch argument, or tap **Explore with sample data** on the login screen.

## Distribution

The display name is **EYE.ON**. The bundle IDs stay `hu.randart.EonUsage[.widgets]`. Users do not see them.

The app is iPhone only. All four configurations set `TARGETED_DEVICE_FAMILY = 1`, because the extension's family must match its host. The layout has one column and no size-class handling. If the app claimed iPad support, it would need iPad screenshots, and a reviewer would judge it as an iPad app.

- Both targets have a `PrivacyInfo.xcprivacy`. The widget also compiles `EonUsageCore`, so both binaries use `UserDefaults`. Both need the required-reason declaration: `1C8F.1` for the App Group defaults and `CA92.1` for the fallback to the app's own defaults.
- The app declares one collected data type: coarse location, for the weather overlay. Requests round the coordinate to two decimals. That is about a kilometre, which is finer than the grid of the cloud model. Nothing more precise leaves the device. The App Store privacy label must say the same.
- Both Info.plists set `ITSAppUsesNonExemptEncryption = false`. The app uses only HTTPS, so it is exempt. The declaration stops App Store Connect from asking on every upload.
- App Review cannot sign in to a private E.ON account. **Point the reviewer at "Explore with sample data" on the login screen.** A login that the reviewer cannot get past is the most common rejection for an app like this one.

## Portal API

`https://e-portal.eon-hungaria.com/w1000/tavleolv` is an Expo/React-Native-Web front end on two SAP Gateway OData V2 services. It replaced the old ASP.NET W1000 app at `energia.eon-hungaria.hu/W1000`. The Home Assistant endpoints (`/Account/Login`, `/ProfileData/ProfileData`) no longer exist.

The endpoints below come from these JS bundles:

- `/sap/bc/bsp/sap/zxweb_w1000/_expo/index.js`
- `/sap/bc/bsp/sap/zwb5_ugyint/bundle.js`

Every request sends `Accept: application/json`, `Content-Type: application/json` and `X-Requested-With: X`. Payloads are under `d`.

### Account service: `/sap/opu/odata/sap/ZWB5_ONLINE_SRV` (`sap-language=HU`)

| Call | Shape |
|---|---|
| `POST /Login` | `{Username, Password, Guid:"", Channel:"WEB", PasswordInit:false, FbId:"", Selectedelmu:false, Delegate:false, Recaptcha:"", Fb:false, KauGuid:"", ServerEvent:"L000", Partners:{results:[]}, Message:{results:[]}}` → `{Ok, Guid, Partners:{results:[{Partner, Sparte, Authid}]}, Message:{results:[…]}}` |
| `POST /Session` | `{Authid, Channel:"WEB", Guid, Partner, ServerEvent:"changePartner", Vkont:"", Vstelle:"", Message:{results:[]}}` |

`Password` is the UTF-8 password, base64-encoded, the same as in the web client. The service accepts an empty `Recaptcha`. A bad login still returns the usual "check your e-mail and password" message, not a captcha challenge.

`Guid` is the session token.

### Metering service: `/sap/opu/odata/sap/ZWB5_W1000` (`sap-language=H`)

Send the GUID as a bearer token in both `Authorization` and `AuthorizationERP`.

| Call | Returns |
|---|---|
| `GET /Pod(Partner='…')?$expand=Pods` | `d.Pods.results`: `{Pod, Sparte, …}` |
| `GET /Intervals` | `d.results`: `{IntervalId, Description, Sparte, Horizon}`. `Horizon` is the maximum number of days per request. |
| `GET /Variables` | `d.results`: `{MeasVarId, Description, IntervalId, Sparte, Aggregate}` |
| `GET /MeasData(Pod='…',MeasVarList='1,2',Interval='1',StartDate=datetime'2026-09-01T00:00:01',EndDate=datetime'2026-09-01T23:59:59')?$expand=MeasDatas` | `d.MeasDatas.results`: `{Timestamp, MeasVarList, Value1…ValueN}` |

`MeasVarList` lists the requested IDs in order, so `Value1` belongs to the first ID. Values are strings. `""` means "no reading", not zero.

`Sparte` is the SAP division: `01` is electricity and `02` is gas.

The app reports a cancelled request (`URLError.cancelled`) as `CancellationError`, not as a transport failure. When you step quickly through months, the app cancels each fetch in flight. That does not mean the portal is unreachable.

### Timestamps

`Timestamp` is OData V2 `/Date(epochMillis)/`. The service stores the meter's local wall-clock time in that epoch. The portal client renders with `timeZone: "UTC"`. So decode the epoch and read the components in UTC (`Calendar.sapWallClock`). Device local time shifts every reading.

## App flow

1. The user signs in and chooses the electricity partner. `Session` selects that partner.
2. `Pod(...)` lists the delivery points. If there is one point, the app selects it automatically. If there are several, the app shows a picker.
3. `Intervals`: the app prefers a description that contains `"15"`. Otherwise it takes the tightest `Horizon`.
4. The app tags the `Variables` at that interval as **from grid** or **to grid** from their names. It tries signed `+A` / `-A` first, then OBIS `1.8.0` / `2.8.0`, then Hungarian words (`vételezett`, `betáplált`, `termelés`, …). Unknown names stay "other", and the app does not chart them. There is no UI to correct this, because the `+A`/`-A` naming has proved reliable. The app still honours `Preferences.channelOverrides`, so an override that an earlier version stored keeps working.
5. The app fetches readings in `Horizon`-sized chunks and turns them into signed samples: consumption above the baseline, feed-in below it.

The day view keeps the 15-minute slots. The week view is hourly and the month view is daily. The app does not sum cumulative registers (`Aggregate == false`).

The chart draws the whole calendar window, whether or not the portal has filled it. A month starts on the 1st and ends on the last day, and days without readings stay blank. The app requests nothing after today.

The header names the window. Tap it to open a calendar and jump to any date up to today. A **Today** button sits beside it. Flick the chart left or right to step the window. The arrows do the same. They stay for accessibility, and they show when the window already contains today.

A drag on the same surface scrubs the chart for values. The app tells the two gestures apart by velocity: only a thrown gesture pages.

## Caching

A published reading never changes. So the app writes each day that the portal has finished to `readings/` in the App Group container, and never fetches that day again. A month costs one request for the newest day or two. After the first visit, scrolling back through history costs nothing.

The cache holds raw portal rows, not the mapped series. So when a stored channel override changes a channel's direction, the app re-renders history from disk and does not download it again.

The app caches a day once the day is over **and** the portal has stopped adding to it. That is true when the readings reach the end of the day, or when the day is more than a week old and its gaps are permanent. The app never caches a day with no readings. Sign-out clears the whole cache. The cache is keyed by delivery point, so a switch to another POD needs no eviction.

## Widgets and Shortcuts

When a single day is on screen, the app writes a `UsageSnapshot` (day totals plus 24 hourly buckets) into the `group.hu.randart.EonUsage` App Group. Then it reloads the widget timelines. Widgets never call the portal. The widget extension cannot read the app's keychain item, so it cannot sign in.

The feed-in check also publishes a snapshot, for the newest finished day in the window that it fetched. This keeps a widget current for someone who has not opened the app in a week, because the daily Shortcuts automation refreshes the alert and the widget together. The check never moves a widget backwards. It runs only while the feed-in alert is on, because the alert does the fetching.

Each widget prints the day it shows, so you can see when a widget is stale.

- `UsageWidget`: small, medium, Lock Screen rectangular and inline.
- `UsageControl`: a Control Center button with the latest net balance.
- `EnergySummaryIntent` / `OpenDashboardIntent`: Siri and Shortcuts actions, which Home automations can also use.

Apple's Home app cannot show this data. Third-party apps cannot add UI there, and Home does not show energy or power, even from Matter devices that report it.

## Cloud cover

An optional grey overlay shows hourly sky cover over the delivery point. With it, you can read a weak day for the inverter against the weather that caused it.

The source is [Open-Meteo](https://open-meteo.com). It needs no account and no key. The app has no server, so it has nowhere safe to keep a key. More important, Open-Meteo serves *history*, and these charts almost always show history. The app uses two endpoints, because neither covers everything:

| | covers |
|---|---|
| `api.open-meteo.com/v1/forecast` | about the last 93 days and a fortnight ahead, best available model |
| `archive-api.open-meteo.com/v1/archive` | ERA5 back to 1940, about five days in arrears |

Windows that end more than a week ago go to the archive. All other windows go to the forecast endpoint.

`timezone=auto` makes the times line up. With it, Open-Meteo returns local wall-clock stamps with no offset (`2026-09-03T12:00`). W1000 uses the same convention, so both read correctly on `Calendar.sapWallClock`.

**Day view only.** Hourly cover averaged across a week or a month says almost nothing. The useful question is which hours of *this* day were overcast. That detail is lost once a bar covers a whole day.

The app draws the curve over the bars, with reduced opacity so the bars still show through. The curve uses the extent of the energy axis: 0% sits on the bottom gridline and 100% on the top one, with labels up the right-hand side. One set of gridlines serves both scales, so you can read the two against each other.

When the app asks for *today*, the service returns all twenty-four hours, and the hours after now are a forecast. So the app drops cloud samples after the current hour before it draws. A narrower date range does not help, because the window already is today. The app compares on the meter's wall clock, not against a bare `Date()`. A bare `Date()` would discard the last two measured hours every summer afternoon.

A second overlay shades the hours when the sun was down. It uses `daily=sunrise,sunset` from the same request. The app finds the shaded spans by *inverting* the daylight, not by drawing it. A window can open mid-morning or close before dusk, and the night on each side of a day is two spans, not one.

Both switches are toolbar buttons in the day view, one for cloud and one for sun. They are not settings, because you turn them on and off while you look at a chart. Settings holds only the location.

The app always lays out the trailing percentage axis. When the cloud overlay is off, the app hides the axis labels but keeps the axis. If the app removed the axis, the plot would take back its width, and every bar would move sideways each time you pressed the button.

Set the location in Settings. Use the device location, or search for a place (Open-Meteo geocoding). Until you set a location, the cloud button does not appear.

The location is a fixed coordinate that the app asks for once. A delivery point does not move, so the app tracks nothing. The app sends only the coordinate, never the readings. The app caches settled ranges on disk, the same as the readings.

## Feed-in alert

The alert warns you when the inverter stops exporting. It is off by default. Turn it on in Settings and pick a threshold of 12 / 24 / 36 / 48 / 72 hours (24 by default).

The alert uses local notifications only, because there is no server. The readings are already a day old when E.ON publishes them.

The gap runs from the last exporting bucket to the newest reading on the portal, not to "now". If the app measured to the clock, it would treat E.ON's publishing delay as a fault.

- An empty response raises no alarm.
- If the fetched window has no export, the gap is a lower bound, because export may have stopped earlier.
- Less than 1 Wh per bucket counts as meter noise, not export.
- While the fault lasts, the app warns at most once per 24 hours. When export recovers, it sends a "feed-in resumed" notification.
- Thresholds under a day will fire on normal overnight lulls. Settings mentions this.

### Output drop

The gap check alone misses the most common inverter failure: an inverter that half-dies and keeps trickling a few watts. Every bucket clears the noise floor, so the silence never begins and no alarm fires.

`OutputWatch` asks a different question: is the export still the *size* it used to be? It measures against the site's own recent history, which is the only baseline available without a weather feed.

- The statistic is the **peak 15-minute bucket**, not the daily total. Cloud often halves a daily total. It does not stop a working array from spiking during a break in the weather.
- The recent window is scored by its **best** day, and the baseline by its **median**. One clear hour on any recent day clears the alarm, and a run of cloud cannot drag the reference down.
- The baseline is the 21 days that end just before the recent window, so the reference follows the seasonal decline. With fewer than 7 baseline days, or a normal peak under 0.05 kWh per bucket, the result is inconclusive. Inconclusive is not healthy, and it never raises an alarm.
- Sensitivity is a setting: off, or below 50 / 35 / 20 / 10 % of normal. The default is 20 %.
- An inconclusive verdict says *why*: how many days it had against how many it needs, or how small the normal peak is. Settings and the "Check now" line both show it. If the app showed nothing, you could not tell it from a healthy site.
- The alarm releases only at 1.5× the trigger ratio, so it cannot flap across the threshold.

Weeks of history would be expensive to fetch on every check. Because of the readings cache, only the newest day or two reaches the portal.

### Running it without opening the app

The check runs when the dashboard loads, at most once every three hours. It also runs from a `BGAppRefreshTask` (`hu.randart.EonUsage.feedInCheck`) that requests a slot every six hours.

**Do not rely on the background task.** iOS grants background refresh in proportion to how often you open an app. The alarm exists so that you do not need to open the app, so it is the first thing iOS starves.

The design has no server, so the dependable way is to schedule the check yourself. Create a Shortcuts personal automation (Time of Day, Run Immediately) that runs the **Check feed-in health** action (`CheckFeedInIntent`). It never opens the app, so you see nothing unless something is wrong. Settings lists the steps.

`CheckFeedInIntent` is declared in the app target, not in `EonUsageCore`. Core is also built into the widget extension. An intent resolved there would run in a process that cannot read the app's keychain item, so the check could not sign in.

## App icon

The icon redraws the E.ON mark: the eye with a lightning bolt cut through the crescent above it. It is squared off to fill the tile, not set as a circle inside it, because that looks better after iOS masks it. It has light, dark and tinted variants.

```
swift Tools/make-icon.swift    # redraws all three into the asset catalogue
```

The geometry lives in that script, not in a set of exported PNGs, so you can adjust it. The icon was checked down to 60 px, where the bolt and the pupil still separate.

## Chart colours

Feed-in is green and from-grid is red, in a fixed slot order. The two colours were checked as a categorical pair on both surfaces: Machado severity-1.0 CVD simulation, CIEDE2000, worst case over normal / protan / deutan / tritan. The results are ΔE 21.9 (light) and 28.8 (dark), against a gate of ≥ 8. Both steps have more than 3:1 contrast.

Colour vision deficiency hits red against green harder than any other pair. System red against system green scores 7.9 in dark mode, which is below the gate. So these two colours are far apart in lightness instead, and red is the darker one on both surfaces. When the hue difference collapses, the bars still separate by brightness. That is why the light green is a strong mid green and the dark green is a pale mint. Run the numbers again before you change the colours.

## Balance figures

The tile under the chart shows the window's net position twice: once in kWh, and once against what was drawn. Both figures use the same colour: red for a net import, green for a net export, and no colour when they cancel.

The percentage is `|taken − sent back| / taken`. It is anchored at break-even, not at zero flow:

| | shows |
|---|---|
| nothing fed back | **100%**: the whole draw was net |
| feed-in equals consumption | **0%**, no colour |
| more fed back than drawn | the surplus over break-even: 701 kWh against 544 kWh is **29%** |

`EnergySeries.balance` names the side, so the same magnitude is never ambiguous. "Level" depends on what is displayed: any value that rounds to 0% counts as level. A near-miss cannot claim a direction that the display does not show.

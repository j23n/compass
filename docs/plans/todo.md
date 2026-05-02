### Reconnect / bond persistence

Today every pair attempt does the full handshake from scratch. Once the watch is bonded with iOS, `connect()` should:

- Skip the SMP-pairing step (already handled by iOS automatically — the bond persists)
- Skip `SETUP_WIZARD_*` events (only fire on `mFirstConnect`)
- Send `SYNC_READY` and start syncing immediately

The mFirstConnect-vs-reconnect distinction in Gadgetbridge is
`GarminSupport.mFirstConnect` — see §13 of the doc. We currently send
the `mFirstConnect` events on every pair attempt.

### Sleep msg 274 carries 20-byte blobs, not uint8 level values

The sleep file's msg 274 records contain 20-byte binary payloads (likely actigraphy or HRV
spectral vectors), not the simple `uint8` level (0=unmeasurable, 1=awake, 2=light, 3=deep,
4=REM) documented in the HarryOnline spreadsheet. The current sleep level parser will find no
valid samples. The actual staging mechanism for this firmware is not yet understood.

### decode sleep msg 274 blobs

Need to decode the 20-byte sleep epoch payloads. The last 2 bytes appear to be a timestamp
suffix (increasing by ~60s per record). The preceding 18 bytes could be 9× sint16 or
4× float32 + padding. Cross-reference with Gadgetbridge sleep parser for Instinct Solar (1st gen).


## User testing Observations 
- ble heartbeat for up to date connection status  
- Connection info in navigation bar + sync status  
- Seamless reconnect (app in background + foreground  
- Persistent background ble connection (where’s my phone?)  
- Transfer inconsistencies: do we only mark files as archived once we’ve processed them? Scenario: sync after night. First sync fails. Second sync only includes data SINcE first sync attempt. Overnight data is lost! Do we mark as archived after rx, or processing?  
- Step parsing: correct on today view, incorrect on health view (including details when tapping chit)  
- Active minutes incorrect (shows two for a day with 60min biking)  
- rename resting heart rate: to heart rate  
- health graphs: mouse over shows popout of bar to the left
- health details: add mean and stddev to the "summary" list items. align these over the rows -> table?
- activity details: swap map and "stats". Add section headings.
- activity details: biking is missing altitude. please do a pass over all activity types we support: what metrics does each need to surface?
- activity details: make stats three columns wide instead of two - more dense information
- activity details: biking (and other?) missing altitude graph, speed graph. only HR is shown
- activity details: graphs should use the same popout as the health graphs for details (with timestamp)
- activity details: graphs should have an x-axis of 0 to <end timestamp>. axes should be labeled
- activity details: linking of graph data point to gps trace is broken - works for the "start" and "end" points, but nothing in between (no blue point shown on map)
- courses: "on watch" check is broken - a check for the file being present doesn't work? does the watch not list these files over the BLE interface?
- courses: use same 3 column interface for the stats as in health
- courses: move "sport type" a new edit view where a user can change the name and sport type.
- today: clicking through the vitals chits should open the relevant "health" detail page instead of rolling it's own thing, (with navigation persistance)
- settings: add option to disconnect/reconnect watch manually
- settings: add swipe to delete paired watch (should also remove it from iOS bluetooth devices)
- sync: fix "empty" first sync (logs/2026-05-01_double_sync_and_sleep.log)  
- sync: fix "hanging" transfer if app is not in foreground (same log file), related to implementing persistent BLE connection?
- settings: thread sync "cancel" signal all the way through. Currently, clicking cancel has no effect
- health: sleep is broken. It seems to add 
- harryoverlay.json. This seems to be made up? please generate using https://github.com/harryo/fit-reader/blob/master/scripts/xlsx2json.js as a base (rewrite in python?) and the google doc: https://docs.google.com/spreadsheets/d/1x34eRAZ45nbi3U3GyANotgmoQfj0fR49wBxmL-oLogc/edit?gid=164559909#gid=164559909
-

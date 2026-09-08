# Banner copy

Edit the **Title** and **Body** lines below, save, and tell me to apply it.
Leave the headings and the `id:` lines alone — those are code, not copy.

Every banner shows **Longbrew** as its header line (from `CFBundleName`), so
each one reads as three lines on screen:

```
Longbrew
Lid-closed mode on
Your Mac won’t sleep, even with the lid closed.
```

Keep bodies to one or two short sentences — macOS truncates a banner after about
two lines and puts the rest behind "show more".

---

## Lid-closed mode

`id: lid-closed`

### Turned on

Title: Lid-closed (ON)
Body: Mac won’t sleep with lid closed.

### Turned off by you

Title: Lid-closed (OFF)
Body: Mac sleeps normally.

### Turned off by the auto-off timer

Only this one names Longbrew, because it's the change you didn't ask for.

Title: Lid-closed (OFF)
Body: Longbrew’s timer switched it off. Mac sleeps normally again.

---

## Espresso

`id: espresso`

### Turned on

Title: Espresso
Body: Screen stays awake. Lid has to stay open.

### Turned off

Title: Decaf
Body: Mac sleeps when idle again.

---

## Self-test

`id: self-test`

Fires only from `longbrew --self-test`. Never appears in normal use — it
exists to prove the notification plumbing doesn't crash. Not worth wordsmithing.

Title: Longbrew self-test
Body: Banner plumbing is alive.

---

## Notes

- Apostrophes are typographic (`’`), matching the rest of the app's copy. Type a
  straight `'` if you like — I'll convert it.
- The two real IDs are stable on purpose: toggling twice replaces the first
  banner instead of stacking two. Renaming an ID breaks that.
- Source: `Sources/longbrew/AppController.swift` (`postLidBanner`,
  `toggleEspresso`) and `Sources/longbrew/SleepState.swift` (`runSelfTest`).

# Photo to Event — extraction instruction (v2)

Replaces v1. Three things changed:

1. **Location is now three separate things**, not one. Where the photo was taken,
   which town it belongs to, and where the event actually happens are different
   facts and must never overwrite each other.
2. **The model reports how well it could read the photo.** That signal is what
   triggers the optional crop, instead of guessing or asking every time.
3. **The photo might not be a flyer at all.** Users upload whatever is in their
   camera roll. The model has to be able to say "this isn't an event".

---

## The location model

The single biggest correctness rule in this whole document:

> **Where a flyer was photographed is not where the event happens.**
> A poster in a café window advertises something happening elsewhere.

So we keep three layers, and they are filled by three different sources:

| Layer | Question it answers | Filled by | Trusted for |
|---|---|---|---|
| `photo_latitude` / `photo_longitude` | where was this picture taken | EXIF only, read from the untouched original | never the event pin |
| `city` + `community` | which town and which local scene | reverse-lookup of photo GPS, or text on the flyer | bundles, discovery, defaults |
| `venue_latitude` / `venue_longitude` | where do people actually go | printed coordinates or map pin on the flyer, or the user's own pin | the map pin |

Why this split earns its keep: photo GPS is a **bad source for a pin** and a
**very good hint for a town**. A flyer is nearly always photographed in the same
town it advertises, even if it is a few streets from the venue. So the photo's
location should pre-fill the city, pre-centre the map, and never drop the pin.

`community` is the wider scene the event belongs to — the thing that groups
"Ericeira" and "Mallorca" as places where the app is taking root. It exists for
the app's own sense of where it lives, not for the user. Keep it coarse and
stable: a coastal area, an island, a city and its surroundings. Not a
neighbourhood.

---

## System prompt (copy from here)

You are a data formatting analyst. You read a single uploaded photo and turn it
into structured event records.

The photo is whatever the user had in their camera roll. It may be a printed
flyer or poster photographed at an angle, a screenshot of a social post, a
screenshot of a map pin, a photo of a chalkboard or a handwritten sign, or it may
not be about an event at all. Judge before you extract.

Read everything visible, including text that runs around edges, is rotated, is
handwritten, or sits in the background. Printed flyers photographed on a wall are
the common case: expect perspective distortion, glare, shadow, and surrounding
clutter that is not part of the flyer.

Identify the event or place name, the host or space name, every date, every start
and finish time, any address or printed coordinates, any contact details, and the
type of activity.

**Location rules, in priority order.** Coordinates printed on the flyer, or a
clearly labelled map pin in the image, are the venue location. If none are
present, leave the venue coordinates empty. EXIF GPS supplied with the photo is
never the venue location: it is only where the photo was taken. Use EXIF GPS to
name the town and the wider area, and to sanity-check any place name you read on
the flyer. If the flyer names a town that conflicts with the EXIF town, trust the
flyer and say so in your notes.

**Time rules.** The EXIF capture time is not the event time. A photo taken on 3
June does not mean the event is on 3 June. Use the capture time only to resolve
what "next Sunday" means if it is more recent than today. A bare month and day
with no year means the next upcoming occurrence: this year if that date still
lies ahead, otherwise next year. A weekday with no date means the next occurrence
of that weekday. If a start time is given with no finish and the activity type is
known, assume a session of 45 to 90 minutes; a yoga or fitness class is 60
minutes. A venue opening hour such as "opens 5pm" is a door time, not a session:
leave the finish empty.

**One record per distinct event date.** A flyer listing four dates produces four
records with the shared fields repeated. A weekly recurrence stated as "every
Sunday" produces one record for the next occurrence, with the recurrence noted.

**Never invent.** No coordinates, names, prices or dates that the photo and the
supplied EXIF do not support. Where something is absent and a guess would
mislead, leave it empty. Guessing a plausible venue is worse than leaving it
blank, because a blank field prompts the user and a wrong field does not.

**Judge legibility honestly.** You are also reporting whether this photo was good
enough to read. If text is cut off at the frame edge, too small, too blurred, or
lost to glare, say so and name what you could not read. The app uses this to
offer the user a tighter crop. Do not pretend a difficult photo was easy.

Today's date is {{TODAY}}.

### Fields

Return one object per event in `events`, plus one `read_quality` object.

Per event:

- `event_name` — the title as written
- `venue_latitude`, `venue_longitude` — decimal degrees, south and west
  negative. Only from coordinates or a pin printed in the image. Empty otherwise.
- `date` — YYYY-MM-DD
- `time_start`, `time_finish` — 24 hour HH:MM
- `recurrence` — plain words if the flyer states one, e.g. "every sunday". Empty
  if it is a one-off.
- `city` — the town or village. From text on the flyer if stated, otherwise from
  the supplied EXIF location.
- `community` — the wider local scene, coarse and stable. From the flyer's town
  or the EXIF location.
- `description` — two or three short phrases from the activity type, folding in
  the host, contact or one line of useful context. No dashes of any kind.
- `space_name` — the venue, studio, host or community name
- `price` — number only, empty if free or unstated
- `currency` — ISO code if a price is shown
- `contact` — phone, handle or link exactly as printed
- `location_source` — one of `printed_coordinates`, `printed_address`,
  `venue_name_only`, `none`
- `location_note` — one short line if the flyer's town and the EXIF town
  disagree, otherwise empty

In `read_quality`:

- `is_event` — true or false. False for a photo with no event information.
- `legibility` — `clear`, `partial`, or `poor`
- `unreadable` — short list of what you could not read, e.g. "finish time",
  "bottom line of address". Empty when legibility is clear.
- `crop_would_help` — true when the flyer occupies a small part of the frame, is
  at a steep angle, or is surrounded by clutter that cost you detail.

Return JSON only, matching the supplied schema. No commentary.

---

## How the app uses `read_quality`

This is what removes the crop from the upload step.

- `is_event` false → "that doesn't look like an event. try another photo?"
  Nothing is filled in.
- `legibility` clear → fill the form, say nothing about cropping.
- `legibility` partial or poor, or `crop_would_help` true → fill in what was
  found, then offer, quietly and once: *"couldn't read the finish time. crop
  closer and try again?"*

The user is never asked to crop before we have tried. They are asked only when we
can name what we failed to read, which makes the request feel earned rather than
bureaucratic.

The crop, when taken, replaces the image and the extraction is re-run. The EXIF
location is already banked from the original at pick time, so cropping cannot
lose it.

---

## Notes for the pipeline

- Read EXIF from the original bytes at the moment the file is picked, before any
  resize, crop or re-encode. All three destroy it.
- Strip EXIF from the stored cover. The GPS in a user's photo is personal data
  and none of it needs to survive into the bucket.
- Resize before sending. See the model notes: a full iPhone frame costs roughly
  ten times the tokens of a sensibly sized one and reads no better.
- Rebuild any maps link server side from the venue coordinates. Never trust a
  link the model wrote.
- If venue coordinates come back empty, that is correct and expected for most
  flyers. The user drops the pin. Pre-centre their map on the photo's location so
  the pin is a nudge, not a search.

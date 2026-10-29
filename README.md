# Movie Store — deterministic fake-movie showcase

A single-page Rails application that generates a fictional movie catalogue
**entirely from a seed**. Everything — titles, directors, cast, genres,
posters, and even the video trailers — is a pure function of
`(region, seed, likes, reviews, page)`. The same inputs always produce the
same output, on any machine, on any date.

* 3 regions: **en-US**, **de-DE**, **uk-UA** (locale data lives in YAML files,
  no region-specific content is hardcoded in the views or the API)
* **Table view** with pagination and **Gallery view** with infinite scroll,
  20 items per page in both
* Expandable table rows and a lightbox with server-rendered **video trailers**
  (real footage + animated typographic titles + music)
* Likes / reviews averages from 0 to 10, including fractional averages, spread across the page so no two records look identical
  (probabilistic rounding)
* Optional **ZIP export** of every trailer of the current page, named after
  the movie titles
* No database for generated data: everything is computed on the fly

---

## Quick start

Requirements: **Ruby 3.3.6** (see `.ruby-version`) and **ffmpeg** on `PATH`
(or `FFMPEG_PATH` pointing at the binary).

```bash
bundle install
bin/rails server           # http://127.0.0.1:3000
```

That is it — there is no database to create or migrate
(`--skip-active-record`); the app boots with an empty storage.

### Docker

The `Dockerfile` installs ffmpeg in the base stage, so trailers work out of
the box:

```bash
docker build -t movie_store .
docker run -d -p 80:80 -e RAILS_MASTER_KEY="$(cat config/master.key)" --name movie_store movie_store
```

### Configuration

| Variable | Purpose |
| --- | --- |
| `FFMPEG_PATH` / `FFPROBE_PATH` | Explicit locations of the binaries (otherwise auto-detected on `PATH`). |
| `MS_FFMPEG_TIMEOUT` | Seconds before a single ffmpeg invocation is killed (default `120`). |
| `MS_POSTER_PARALLEL` | Concurrent poster renders (default `4`). |
| `MS_VIDEO_PARALLEL` | Concurrent trailer renders (default `3`). |
| `MS_VIDEO_THREADS` | Threads x264 may use per render (default `cores / MS_VIDEO_PARALLEL`). Without it three renders each grab every core and a 9 s job crawls to ~70 s — measured. |
| `MS_EXPORT_TIMEOUT` | Seconds a ZIP export waits for the queue before shipping what it has (default `360`). |
| `MS_LOG_CMD` | Development aid: dump the exact ffmpeg command to `tmp/last_ffmpeg_cmd.txt`. |

Rendered media is cached in `tmp/trailer_cache` and is safe to delete at any
time — it is rebuilt lazily on demand.

---

## How determinism works

```
seed (uint64) ─┐
region tag ────┼─► SeedMix.mix(...) ─► SeededRng (xoshiro256**) ─► named streams
page / index ──┘                                                 │
                                                                 ├─ "content"      → titles, cast, crew, plot, genres…
                                                                 ├─ "review-texts" → review bodies, authors, star ratings
                                                                 ├─ "<kind>-dist"  → how likes/reviews spread over the page
                                                                 └─ "trailer"      → TrailerPlanner → TrailerRenderer (ffmpeg)
```

* `SeededRng` is a hand-written xoshiro256** so the sequence never depends on
  Ruby's `Random` implementation, the platform, or the Ruby version.
* Each concern gets its own named stream, which is why **changing likes or
  reviews only changes the counts** — titles, posters and trailers stay
  byte-identical — while changing the seed or region regenerates everything.
* `TrailerPlanner` turns the seed into a *plan* (which stock clips, at which
  offsets, with which grade, ken-burns move, transitions, typographic cards,
  music and sound effects). The plan is JSON and is exposed at
  `GET /api/trailers/:key/plan`.
* `TrailerRenderer` executes the plan with ffmpeg. Everything runs on its own
  background threads with a split budget — **4 slots for posters** (a single
  frame, ~0.4 s, twenty arrive per page) and **3 slots for videos** (~10 s
  each, tunable via `MS_POSTER_PARALLEL` /
  `MS_VIDEO_PARALLEL`) — so HTTP requests only ever enqueue and poll; they never wait for
  ffmpeg. Renders also split the CPU between the slots (`MS_VIDEO_THREADS`),
  which takes a cold page of twenty trailers from ~7 min down to ~3.5 min.
  Writes are atomic (`.part-…` + rename) and per-key locks prevent
  duplicate work. Videos are streamed with HTTP range support once ready.
* The seed is transported as a **JSON string** end to end, because JavaScript
  numbers cannot hold a 64-bit integer without losing precision.

Reproducibility check used during development: 400 seeds × 3 regions ×
3 pages × 3 row indexes = 48 582 shot windows, all inside their source clips
(minimum margin 0.051 s).

---

## API

All generation endpoints accept the same query parameters:
`region`, `seed`, `likes`, `reviews` (+ `page` where noted). Values are
clamped server-side; unknown regions fall back to the default.

| Endpoint | Description |
| --- | --- |
| `GET /api/meta` | Regions, page size, slider ranges, UI strings for the current locale, media/capability stats. |
| `GET /api/movies?page=N` | One page of 20 movies, fully generated. Infinite scroll and pagination use the same endpoint. |
| `GET /api/trailers/:key/poster` | JPEG poster frame. Queues a background render; waits up to 0.8 s and otherwise answers `503` + `Retry-After: 1`, which the client retries on the `<img>` with a backoff. Warming starts when `/api/movies` serves the page. |
| `GET /api/trailers/:key/status?quality=hd\|ld` | `rendering` / `ready` / `error`. The client polls this while a video renders. |
| `GET /api/trailers/:key/video?quality=hd\|ld` | MP4 with range support (206 Partial Content). Triggers a background render if needed. |
| `GET /api/trailers/:key/plan` | The deterministic JSON plan behind the trailer. |
| `GET /api/export/progress?page=N` | `{ready, total, render}` — how many trailers of the page are on disk right now. Polled once a second by the export button so it can show `Rendering 7/20` instead of minutes of silence. |
| `GET /api/export?page=N` | ZIP with one MP4 per movie of the current page, named `NN - <Title>.mp4`, download `trailers-page-N-<region>.zip`. Missing trailers are rendered by the shared background queue (3 at a time), so the request only waits — and because the button starts it through a hidden `<a download>` the page never navigates away. |
| `GET /up` | Health check (no database). |

`likes` / `reviews` are **page averages** in `[0, 10]`. The server deals
exactly `average × 20` whole units over the twenty records of the page, so the
sample mean always matches the slider (an average of `0.5` → ten items with 1
and ten with 0), while the individual values are spread with a skewed,
realistic distribution — at an average of 10 a page reads `2 … 25`, never
twenty identical `10`s. Per record the values are capped at 100 likes / 40
reviews, caps that never bind inside the slider range.

---

## Frontend

Vanilla JS SPA (`app/assets/javascripts/application.js`), no build step:

* Toolbar state lives in the URL-less JS store; any change (language, seed,
  likes, reviews) reloads data, **resets pagination to page 1** and restarts
  the gallery scroll.
* The whole toolbar (language, seed, likes, reviews, view, export) stays on
  **one horizontal row**: its natural width is ~1320 px, and below 1420 px the
  brand collapses to its mark, so nothing wraps down to ~1240 px of viewport.
* Infinite scrolling uses the vendored **Infinite Scroll v4.0.1**
  (`app/assets/javascripts/infinite-scroll.pkgd.js`).
* Expanding a table row mounts the trailer player inline; clicking a gallery
  card opens a lightbox with the same player. Keyboard support: `Enter`
  opens, `Escape` closes.
* All UI strings come from `/api/meta` (`config/locales/ui/*.yml`), so the
  interface is fully localized for all three regions.
* Fonts are served as **woff2 unicode subsets** (~960 KB total, only the
  subsets actually used are fetched); the CSS lists woff2 only, because Chrome
  starts downloading every `src` it cannot rule out — listing the TTFs as well
  pulled 1.75 MB of them on every visit. Measured first load: **486 KB over 28
  requests, DOMContentLoaded 166 ms, load 288 ms**.
* Posters are requested at **160 px** in the grid and **640 px** in the
  lightbox from the same deterministic render, so thumbnails weigh ~2 KB.

---

## Requirements checklist

| # | Requirement | Where |
| --- | --- | --- |
| 1 | Rails application | Rails 8.1.4, Puma |
| 2 | 3 regions (en-US, de-DE, uk-UA) | `config/locales/{en-US,de-DE,uk-UA}.yml`, `RegionRegistry` |
| 3 | 48+ bit seed + random-seed button | 64-bit seed, dice button next to the seed field |
| 4 | Toolbar in one row, updates without Enter/button | `home/index.html.erb`, `scheduleReload` |
| 5 | Any param change resets page/scroll | `reload()` sets `page = 1`, gallery instance is rebuilt |
| 6 | Table = pagination, Gallery = infinite scroll, 20 per view, no data cap | `MovieGenerator::PAGE_SIZE = 20`, `hasMore: true`, `current_page` clamped at 100 000 |
| 7 | Likes/reviews change only counts | Independent `<kind>-dist` RNG streams (exact page sum, skewed spread) |
| 8 | Server-side generation from seed + page, no DB | `Api::MoviesController`, `--skip-active-record` |
| 9 | Reproducible across devices/dates | `SeededRng` (xoshiro256**) + `SeedMix` |
| 10 | No hardcoded region content | YAML locale data only |
| 11 | 3rd-party libraries | Faker, rubyzip, Infinite Scroll, ffmpeg |
| 12 | Trailers 5–10 s, real footage, animated titles, variety, reproducible | `TrailerPlanner` + `TrailerRenderer`, 44 stock clips |
| 13 | Sound (optional but graded) | Music bed + whoosh/revcym/impact SFX mixed by ffmpeg: a fast **audio-only probe** pass measures the mix, a **static gain** reaches −16 LUFS, then `alimiter` (limit 0.80) leaves headroom for the AAC encoder — measured result: −16.3 LUFS, true peak −1.8 dBTP, **0 clipped samples**, LRA 2.3 LU |
| 14 | ZIP export named by movie title | `Api::ExportController` |

---

## Project layout

```
app/
  controllers/api/      meta, movies, trailer, export endpoints
  services/
    seed_mix.rb         mixes (seed, region, page, index, stream)
    seeded_rng.rb       xoshiro256** PRNG (platform independent)
    movie_generator.rb  builds one page of movies
    trailer_planner.rb  seed → deterministic trailer plan (pure data)
    trailer_renderer.rb plan → ffmpeg → poster/video (cached, queued)
    region_registry.rb  region definitions from locale files
    media_library.rb    clips / music / sfx / fonts manifest
    ffmpeg_locator.rb   finds ffmpeg & ffprobe
  assets/javascripts/   application.js + vendored infinite-scroll.pkgd.js
  views/                single page (toolbar + table + gallery + lightbox)
config/locales/
  ui/*.yml              interface strings per language
  {en-US,de-DE,uk-UA}.yml  content data (titles, names, genres, words…)
public/media/           44 clips + 10 music tracks + 9 sfx (~103 MB)
public/fonts/           12 OFL fonts used by the typographic cards
```

---

## Third-party assets and licenses

* **Footage** — 44 stock clips from [Coverr](https://coverr.co) (Coverr
  License, free for commercial use).
* **Music** — Kevin MacLeod ([incompetech.com](https://incompetech.com)),
  licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/);
  see `public/media/music/credits.txt`.
* **Fonts** — SIL Open Font License 1.1 (Oranienbaum, PT Serif, Fira Sans,
  and others under `public/fonts/`).
* **Libraries** — Rails (MIT), Faker (MIT), rubyzip (BSD-2),
  Infinite Scroll v4.0.1 (GPL-3.0, vendored).

---

## Quality checks

All green locally (also wired into `.github/workflows/ci.yml`):

```bash
bundle exec rubocop        # 33 files inspected, no offenses
bundle exec brakeman       # 0 warnings
bundle exec bundler-audit  # No vulnerabilities found
node --check app/assets/javascripts/*.js
```

---

## Troubleshooting

* **Posters/videos never appear** — check that `ffmpeg` is installed and
  visible (`bin/rails runner 'puts FfmpegLocator.available?'`); `GET /api/meta`
  reports the render queue (`render.active` / `render.queued`).
* **A render seems stuck** — every ffmpeg call is killed after
  `MS_FFMPEG_TIMEOUT` seconds (default 120) and reported as `error`;
  delete `tmp/trailer_cache` to force a clean re-render.
* **Development server hangs after editing code** — stop the server, delete
  `tmp/pids/server.pid`, start it again.

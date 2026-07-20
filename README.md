# audioout

Drop a video into a folder on your Synology; a moment later the audio track
appears next to it, ready to listen to. Runs as a single small Docker
container (Alpine + ffmpeg) with **no network access at runtime**, so NAS DNS
problems can't affect it.

## How it works

The container polls `inbox/` every 30 seconds. When a new video file has
finished copying, it:

1. extracts the audio track — by default as a lossless stream copy
   (instant, no quality loss; an `.mp4` typically yields an `.m4a`),
   or re-encoded to MP3 if you set `OUTPUT_FORMAT=mp3`;
2. optionally detects silence at the **end** of the file and trims it off
   (`TRIM_SILENCE=true`, on by default);
3. writes the result to `audio/` and moves the source video to `processed/`
   (or deletes it, if `ON_SUCCESS=delete`). Files that fail land in
   `failed/` so nothing is silently lost.

Folder layout on the NAS (created automatically on first run):

```
/volume2/docker/audioout/
├── docker-compose.yml
├── audioout-image.tar.gz     <- downloaded image (see install step 2)
└── watch/
    ├── inbox/                <- drop videos here
    ├── audio/                <- extracted audio appears here
    ├── processed/            <- originals after successful extraction
    └── failed/               <- originals that could not be processed
```

## Installing on a DS920+ (DSM 7, Container Manager)

Because the image is imported from a file, the NAS never contacts a Docker
registry — nothing on the NAS needs working DNS.

1. **Get the image.** On your PC, open this repo's **Actions** tab, click the
   latest successful `build-image` run, and download the `audioout-image`
   artifact. Unzip it to get `audioout-image.tar.gz`.
2. **Copy files to the NAS.** Create `/volume2/docker/audioout/` and put
   `audioout-image.tar.gz` and `docker-compose.yml` (from this repo) in it.
3. **Import the image.** Container Manager → **Image** → **Add** →
   **Add from file** → pick `audioout-image.tar.gz`. It appears as
   `audioout:latest`.
4. **Create the project.** Container Manager → **Project** → **Create**:
   - Project name: `audioout`
   - Path: `/volume2/docker/audioout`
   - Source: *Use existing docker-compose.yml*
   Then start it.
5. **Try it.** Drop a video into `/volume2/docker/audioout/watch/inbox/`
   (via File Station, SMB, or DS File). Within a minute the audio file
   shows up in `watch/audio/`. Progress is visible in the container's log
   (Container Manager → Container → audioout → Log).

**Updating:** download the new artifact, re-import it in step 3 (delete the
old image first), then restart the project.

## Configuration

All settings are environment variables in `docker-compose.yml`:

| Variable | Default | Meaning |
|---|---|---|
| `OUTPUT_FORMAT` | `copy` | `copy` keeps the original audio codec untouched (lossless, near-instant). `mp3` re-encodes everything to MP3 for maximum player compatibility. |
| `MP3_QUALITY` | `2` | MP3 VBR quality when re-encoding: `0` best (~245 kbps) … `9` smallest. `2` ≈ 190 kbps. |
| `TRIM_SILENCE` | `true` | Detect and cut silence at the end of the file. |
| `SILENCE_THRESHOLD` | `-50dB` | Audio quieter than this counts as silence. Use `-40dB` if noisy recordings aren't being trimmed; `-60dB` if quiet endings are being cut too eagerly. |
| `SILENCE_MIN_DURATION` | `2` | Trailing quiet must last at least this many seconds to be trimmed — protects normal pauses. |
| `SILENCE_PADDING` | `0.5` | Seconds of silence kept after the last sound so the ending isn't abrupt. |
| `ON_SUCCESS` | `move` | `move` originals to `processed/`, or `delete` them. |
| `POLL_INTERVAL` | `30` | Seconds between inbox scans. |
| `STABLE_SECONDS` | `10` | A file must be unmodified this long before processing starts (avoids grabbing half-copied files). |
| `PUID` / `PGID` | *(unset)* | Optionally own output files as this DSM user/group id (find yours with `id <username>` over SSH; group `100` is DSM's `users`). |

After changing settings: Container Manager → Project → audioout → **Stop**,
then **Start** (or `docker compose up -d` over SSH).

### Notes on silence trimming

Trimming works by scanning the audio with ffmpeg's `silencedetect` filter and,
if the file *ends* in silence, cutting at the point the silence starts (plus
`SILENCE_PADDING`). The cut works in both `copy` and `mp3` modes and never
re-encodes just to trim — so `copy` stays lossless. Silence in the *middle*
of a file is left alone.

### Notes on `copy` mode

The output container is chosen from the source's audio codec: AAC/ALAC → `.m4a`,
MP3 → `.mp3`, Opus → `.opus`, Vorbis → `.ogg`, FLAC → `.flac`. Codecs with no
sensible standalone file (e.g. AC-3 from a TV recording) are automatically
re-encoded to MP3 instead. Only the first audio track is extracted.

## Building the image yourself

On any machine with Docker (also what CI does):

```sh
docker build -t audioout:latest .
docker save audioout:latest | gzip > audioout-image.tar.gz
```

Copy the tarball to the NAS and import as in step 3 above. The build needs
internet access (Alpine base image + ffmpeg package); the built image never
does.

# LogDesk — Script Description and User Guide

**Author:** Teo Espero  
**Version:** 4.4  
**Updated:** October 13, 2026  
**Script:** `logdesk-bash.sh`

## What it does

LogDesk is a Bash terminal application for viewing Linux logs in one boxed interface. It reads the systemd journal and readable text files from configured folders, converts them into a common table, and lets the user browse, filter, sort, inspect, and export the results.

The default log folder is `/var/log`. Additional application folders and common user log locations can be included. The default collection has no entry cap. The app reads its sources without modifying them.

## Features

- Boxed terminal interface with aligned columns and severity colors.
- Loading dialog during capture and counting, followed by entry-based progress.
- Filters for source, severity, service/file, date, time, and keywords.
- Sort dialog with five fields and ascending or descending order.
- Right-side details window with scrolling and full messages.
- Truncated selected-entry preview that stays inside its border.
- Manual refresh and optional automatic refresh, normally every 15 seconds.
- Journal cursors for incremental refresh and cached results for unchanged text files.
- Disk-based results with an index for loading only the visible page.
- CSV export that creates a new file rather than overwriting an existing one.
- Conditional sudo authentication before opening the interface.
- Collection diagnostics and explanatory code comments with dashed dividers.

## Requirements

Designed for Ubuntu and similar GNU/Linux systems. Requires a modern Bash supporting arrays, associative arrays, and `mapfile`, plus an interactive terminal at least **100 columns by 22 rows**.

| Dependency | Purpose |
|---|---|
| `journalctl` | Collect systemd journal entries; file collection can run without it |
| `awk` | Batch parsing, filtering, counting, and indexing |
| `sort`, `cut`, `tac` | Sorting and table operations |
| `date`, `stat` | Filter dates and source metadata |
| `find`, `cat`, `head`, `tail`, `od`, `tr`, `fold` | File discovery, reading, inspection, and text display |
| `mktemp`, `cksum`, `ln`, `cp`, `mv`, `rm`, `mkdir`, `readlink` | Temporary storage, cache keys, and file operations |
| `tput` | Terminal dimensions |
| `sudo` | Optional access to protected logs |
| `gzip` | Optional compressed rotated logs |

The script checks its listed command dependencies at startup. It does not automatically install missing packages. Most commands are normally available on Ubuntu. Terminal colors and box characters depend on terminal support.

## Running the app

```bash
bash logdesk-bash.sh
```

Alternatively:

```bash
chmod +x logdesk-bash.sh
./logdesk-bash.sh
```

If some sources need elevated access, the app explains why and invokes sudo's normal authentication prompt before opening the interface. Password characters are not displayed. The script does not collect or store the password. If authentication fails, it continues with readable sources.

To disable the elevation check:

```bash
bash logdesk-bash.sh --no-sudo
```

## Command-line options

| Option | Description |
|---|---|
| `--log-dir PATH` | Replace the default `/var/log` folder |
| `--extra-dir PATH` | Add another folder; can be repeated |
| `--user-logs` | Include the user's state and cache folders |
| `--rotated` | Include recognized numbered and gzip rotations |
| `--limit N` | Optional record budget; `0` means all and is the default |
| `--dump` | Write the normalized TSV result to stdout without opening the interface |
| `--no-sudo` | Disable automatic elevation checks |
| `--help` | Show usage |

Example with additional application logs:

```bash
bash logdesk-bash.sh \
    --extra-dir /path/to/application/logs \
    --extra-dir /path/to/another/logs
```

Example including rotated logs:

```bash
bash logdesk-bash.sh --rotated
```

Example using user folders:

```bash
bash logdesk-bash.sh --user-logs
```

The user-folder option uses `${XDG_STATE_HOME:-$HOME/.local/state}` and `$HOME/.cache`. These broad folders can contain unrelated files; use specific application folders when possible. Launch normally so the app resolves your user folders before any elevation.

Example writing a diagnostic table:

```bash
bash logdesk-bash.sh --no-sudo --dump > collected-logs.tsv
```

Dump mode does not automatically request elevation because the startup check requires terminal input and output. Use explicit sudo if a dump needs protected logs. Shell output redirection can overwrite the specified destination; interactive CSV export has a separate no-overwrite check.

## Interface and controls

| Panel | Contents |
|---|---|
| Header | Matching/collected counts, optional limit, active sort, and automatic refresh state |
| Filters | Current source, severity, unit/file, date bounds, and keyword |
| Log entries | Date/time, severity, service/file, and message preview |
| Severity legend | Color meanings and inferred-severity marker |
| Selected entry | A shortened preview ending in `...` when needed |
| Status/progress | Collection phase, counts, progress, or action result |
| Footer | Keyboard shortcuts |

| Key | Action |
|---|---|
| Up / Down | Move selection |
| Page Up / Page Down | Move a page |
| F | Open filters |
| S | Open sorting |
| Enter | Open selected entry details |
| C | Clear filters |
| R | Request refresh |
| A | Toggle automatic refresh |
| E | Export filtered rows to CSV |
| ? | Open diagnostics |
| Esc | Dismiss the loading overlay or close/cancel the current dialog |
| Q | Quit from the main view |

Automatic refresh requests another collection when the interval has elapsed. It does not start overlapping collectors, and dialog interaction can delay the next request.

## Severity colors

| Severity | Color |
|---|---|
| Emergency, Alert, Critical | Magenta |
| Error | Red |
| Warning | Yellow |
| Notice | Cyan |
| Info | Green |
| Debug | Blue |
| Unknown | White |

Journal severity comes from its recorded priority. Text severity is inferred from words such as `error`, `failed`, and `warning`, and is marked with `*`. These guesses can produce false positives; for example, a message saying "no error" still contains `error`.

## Dialogs

### Loading

**[ Information ] Loading logs** appears during capture and counting. It has an animated indicator and available counts. It closes automatically after that phase. Esc dismisses the overlay without cancelling collection.

The percentage bar uses records processed against the counted snapshot total. It does not estimate remaining time. Preliminary journal records may appear before the full count is available.

### Filters

**[ Filters ] Filter logs** shows all filter fields together:

| Field | Meaning |
|---|---|
| Source | All, journal, or file |
| Severity | A recorded or inferred severity; blank means any |
| Log type / file | Part of a service identifier or file path |
| From | Inclusive starting date/time |
| Through | Inclusive ending date/time |
| Keyword | Literal text searched in the message and unit/file |

All enabled conditions combine with **AND**. Text searches are case insensitive. Unrecognized timestamps cannot satisfy a date/time filter.

Example:

```text
Source:   journal
Severity: warning
From:     2026-10-13 08:00:00
Through:  2026-10-13 17:00:00
Keyword:  network
```

Dates use the local timezone unless an explicit offset is entered. A date without a time means midnight. To include a whole day, use an ending time such as `23:59:59`.

Use Tab, Up, or Down to move between fields and buttons. Left/Right/Space changes source and severity choices. Other fields accept text; Backspace deletes and Ctrl+U clears a field. Enter moves to the next field or activates a button. Apply commits changes; Cancel or Esc keeps the old settings. Invalid dates change the title to **[ Error ] Invalid filter**.

### Sorting

**[ Sort ] Sort entries** provides:

| Field | Ordering |
|---|---|
| Date / Time | Numeric timestamp |
| Severity | Priority rank |
| Source | Source name |
| Unit / File | Service identifier or file path |
| Message | Stored message text |

Choose ascending or descending order. Severity ascending runs from emergency through debug, with unknown last. Unknown dates also stay last when sorting by date. Text sorts operate on the normalized stored strings and use case-folded keys; escaped control characters can affect their lexical order.

Tab/Up/Down moves focus. Left/Right/Space changes choices. Apply commits the selection. Cancel or Esc keeps the previous sort. Default order is timestamp descending, followed by source and unit/file for ties.

### Details

Enter opens a window on the right while keeping part of the list visible. It displays the timestamp, source, severity, service/file, inferred-year flag, and full message.

| Title | Used for |
|---|---|
| **[ Error ] Entry details** | Emergency, alert, critical, and error |
| **[ Warning ] Entry details** | Warning |
| **[ Information ] Entry details** | Other severities |

Up/Down and Page Up/Page Down scroll the content. Esc, Enter, or Q closes the details window and returns to the list.

### Diagnostics

**[ Information ] Collection diagnostics** shows collection notes and available errors, including permissions and journal failures. Press Esc, Enter, or Q to return.

## How collection works

1. **Capture journal records.** `journalctl` returns selected JSON fields. A single `awk` process parses them into normalized records and can publish an initial preview.
2. **Reuse journal history on refresh.** The saved cursor requests only new journal records. Sorted new records are merged with cached history. An invalid cursor triggers a full-source retry.
3. **Capture text sources.** Readable regular files are discovered without following symlinks. Recognized binary files and excluded folders are skipped. Unchanged files reuse cached parsed results; changed files are captured again.
4. **Count captured records.** The app calculates the loading total from captured/cached sources rather than rereading the live journal for a separate count.
5. **Parse text in batches.** One `awk` process per changed text file converts supported dates, infers text severity, and escapes string fields.
6. **Merge source batches.** Sorted journal and text batches are merged into the final disk table.
7. **Filter and index.** `awk` creates a matching result and records a byte offset every 256 rows. With no filters and the default order, a hard link shares the snapshot instead of copying it.
8. **Display one page.** The app seeks near the requested block and decodes only visible rows into shell arrays.

Collection runs in a background shell job. Complete snapshots and progress records are published through temporary files followed by rename, so the interface does not read a half-written snapshot. Parsing, filtering, indexing, sorting, and exporting can still take time on large datasets.

The journal cursor and source caches are temporary and last only for the current run. Changed text files are reread rather than incrementally reading only appended bytes.

## Internal data format

Each normalized record has six tab-separated columns:

| Column | Value |
|---:|---|
| 1 | Epoch seconds; `-1` means unknown |
| 2 | Source: `journal` or `file` |
| 3 | Severity; `*` identifies inferred text severity |
| 4 | Escaped, prefixed service identifier or path |
| 5 | `yes` or `no` for inferred year |
| 6 | Escaped, prefixed message |

Strings begin with `x` so an empty value remains a nonempty TSV field. Backslashes, tabs, carriage returns, and newlines are escaped. Display/export decoding removes the prefix and restores those characters.

The journal parser supports multiline strings, Unicode escapes, and byte-array messages. NUL bytes in byte arrays become spaces because shell strings cannot hold NUL. Empty and missing message fields receive explicit labels.

Text timestamp formats include ISO-style dates with optional fractions/offsets, slash-formatted dates, Apache-style dates, and traditional syslog dates. Yearless syslog dates use the source modification time as a reference and are marked as inferred.

## CSV export

Press E and enter a new destination path. Export includes every matching record in the selected order, not just the visible page.

Columns:

```text
 timestamp,source,unit,severity,inferred_year,message
```

Fields are quoted and embedded quotes are doubled. Messages may contain newlines. Existing files are not overwritten. CSV files can be opened in Excel or LibreOffice Calc. Large exports can take time because the current exporter processes rows individually.

## Performance comparisons

These are single-run development measurements using synthetic data. Each pair used the same input, and output was checked for consistency.

| Dataset | Earlier Version | Updated Version | Entries | Before | After | Time Reduction |
|---|---|---|---:|---:|---:|---:|
| Repeated timestamps | v2.3: Per-entry subprocesses | v2.5: Built-in encoding and caching | 1,000 | 2.89 s | 0.22 s | 92.4% |
| Different timestamps | v3.0: Per-entry date conversion | v3.1: Whole-file parsing | 1,000 | 2.08 s | 0.06 s | 97.1% |
| Journal records | v3.2: Shell parsing | v4.0: Batch parsing and disk paging | 20,000 | 3.31 s | 0.51 s | 84.6% |
| Journal records | v4.2: Full final sorting | v4.3: Merge sorted batches | 20,000 | 0.54 s | 0.51 s | 5.6% |

These separate comparisons do not rank every version against one common dataset. The journal comparison changed parsing and paging together. Results do not measure first-entry display time, peak memory, or performance on the user's computer. Version 4.4 has functional checks but no separate timed benchmark.

## Functional verification

| Check | Result |
|---|---|
| Multiline journal messages and tabs | Passed |
| Unicode and byte-array messages | Passed |
| Empty and missing message labels | Passed |
| Supported timestamp formats | Passed |
| Indexed paging beyond 256 records | Passed |
| Details and keyword filters | Passed |
| Cursor refresh adding events without duplicating old records | Passed |
| Five sort fields in both directions | Passed |
| Apply/Cancel in filter and sort dialogs | Passed |
| Loading dialog and Esc dismissal | Passed |
| Clearing filters and switching order without damaging the snapshot | Passed |

## Limits and troubleshooting

- The app does not automatically discover every application's logs. Add specific folders when needed.
- Rotated logs require `--rotated`; recognized binary logs are excluded.
- Unsupported timestamps remain unknown; syslog years and text severity are inferred.
- Duplicate events across journal and files are preserved. Text continuation lines are not universally grouped into one event.
- User state/cache folders can contain unrelated files.
- All-log collection can use substantial time and temporary disk space.
- Active logs may change while sources are captured; snapshots are not a system-wide atomic capture.
- The interface remains interactive during background collection, but large filter, sort, or CSV operations may pause interaction.
- Temporary files are removed and terminal state restored on normal exit and handled interrupts. A forced kill or system failure can leave temporary files or terminal state behind.

If nothing appears, press `?` to inspect collection diagnostics. Check folder paths and permissions. Try a specific known text-log folder with `--log-dir`. If needed, run with explicit sudo:

```bash
sudo bash logdesk-bash.sh
```

If the screen reports that the terminal is too small, enlarge it to at least 100 × 22. If terminal formatting remains wrong after an abnormal exit, run `reset`.

## Revision overview

| Version | Main Change |
|---|---|
| 2.0–2.3 | Shell rewrite, caching/background collection, parser fixes, and conditional sudo |
| 2.4–2.6 | Lower per-entry overhead, progress display, staged entry loading, and bounded preview |
| 2.7–2.9 | Multiline journal handling, uncapped collection, and streaming updates |
| 3.0–3.2 | Entry counting, single-source capture, batch text parsing, and early previews |
| 4.0 | Batch JSON journal parsing, cursor refresh, indexed disk paging, and cached filters |
| 4.1 | Loading dialog |
| 4.2 | Dialog type titles and unbuffered mawk journal streaming |
| 4.3 | Merge sorted batches and bypass inactive filters |
| 4.4 | Field/order sort dialog with Apply and Cancel |

LogDesk is a working learning project. Its performance and parsing behavior should continue to be checked against actual logs as it develops.

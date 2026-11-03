# Telemetry

Turn on **Record telemetry to disk** in Settings to start recording. The default folder is `~/Library/Application Support/GrokBar/Telemetry`. You can choose another folder, and you can open the current one in Finder from the same section.

If an older build left files in `~/Documents/GrokBar Telemetry`, the first launch moves the `grokbar-metrics-*.jsonl` and `grokbar-logs-*.jsonl` files into the Application Support folder, then sets `telemetryFolderMigrated` so later launches don't touch Documents.

Captures start when recording is enabled, then run on the interval you set (default five minutes, anywhere from 1 to 1,440) while GrokBar is running. GrokBar doesn't record while it's closed, and it doesn't backfill the time it missed. The first capture records the token totals already on disk and counts nothing from them. Later captures count only the growth after that.

Use **Apply telemetry settings** to save the interval, retention, and folder. Editing a field doesn't start recording or delete files. Applying a new folder writes the next capture there and applies retention to GrokBar's own files in that folder.

[Bar UI](https://github.com/GordonBeeming/bar-ui) can ask for the same changes by opening `grokbar://telemetry`. GrokBar lists each change and waits for you to confirm. A bad value rejects the whole request. `grokbar://settings` opens Settings. The format those files have to follow is the [Bar Telemetry Spec](https://github.com/GordonBeeming/bar-ui/blob/main/docs/telemetry-spec.md), version 1. This page is the Grok-specific part.

## Files and retention

Each file is UTF-8 OTLP JSON, one object per line:

```text
grokbar-metrics-2026-10-11.jsonl
grokbar-logs-2026-10-11.jsonl
```

The date is the UTC day the line was written. New files are owner-only (`0600`). A folder GrokBar creates is `0700`.

The default retention is 90 UTC days, including today. You can set 1 to 3,650 days, or unlimited. Limited retention deletes expired `grokbar-metrics-*.jsonl` and `grokbar-logs-*.jsonl` files before a write. Other names and symbolic links are left alone. Turning recording off keeps the files and pauses that cleanup.

Resource attributes are `service.name=grokbar`, `service.version` (the marketing version), `host.name`, `os.type=darwin`, and `bar.spec.version=1`. The scope is `com.gordonbeeming.GrokBar.telemetry`.

## Limits

Every limit the CLI returns is a gauge, sampled on the capture interval. Fuel tank mode doesn't change the stored percentage: `bar.limit.utilization` is always how much is used, from 0 to 100.

| Metric | Value |
| --- | --- |
| `bar.limit.utilization` | Used percent |
| `bar.limit.resets_at` | When the current window ends, Unix seconds |

Attributes are `limit.id`, `limit.name`, and `limit.window.duration_minutes` when the length is known.

| `limit.id` | When |
| --- | --- |
| `credits:monthly` | Credit usage percent for a month. That is a period of 20 to 45 days, or a monthly type with no length. The exact length stays in `limit.window.duration_minutes`, because a calendar month is not a fixed number of minutes |
| `credits:<minutes>` | Credit usage percent, and the period has a length outside that month range |
| `credits:weekly` | Percent is present, length isn't, and the type says weekly |
| `credits` | Percent is present and nothing else identifies the window |
| `credits:legacy` | No percent, and `monthlyLimit` is above zero. The percent is `used / monthlyLimit` |
| `on_demand` | `onDemandCap` is above zero. The percent is `onDemandUsed / onDemandCap` |
| `product:<product>` | The CLI forwarded a `productUsage` row. Grok 1.0.70 drops those rows when it re-encodes the response, so this id shows up only if a newer CLI keeps them |

A prepaid balance is not a 0 to 100 limit. When the CLI sends `prepaidBalance`, GrokBar writes `grok.prepaid.balance` in USD (`val` is cents; an empty cent object is zero). Bar UI ignores metrics outside the spec's `bar.*` list, so this gauge is there for anything else reading the files.

The menu can hold a suspicious drop for three readings. The telemetry sample uses the same stabilized limits.

## Local tokens

GrokBar reads `usage.json` under `$GROK_HOME/sessions`, or `~/.grok/sessions` when `GROK_HOME` isn't set. It starts only after you turn recording on.

`bar.tokens` is a cumulative monotonic sum. A point is written only when that model and token type has counted something since recording started.

| `token.type` | What GrokBar counts |
| --- | --- |
| `input` | Input that was neither read from nor written to the cache |
| `cache_read` | Cache reads |
| `cache_write` | Cache writes. Grok doesn't give them a lifetime |
| `output` | Output, reasoning included |
| `reasoning` | The reasoning part of `output`. It is not added on top of `output` |

`inputTokens` in `usage.json` already includes cache reads. When `totalTokens` equals `inputTokens` plus `outputTokens`, cache writes sit inside input too, and those are subtracted from `input` as well. Reasoning stays inside `output`. A missing model is recorded as `unknown`.

The files store running totals. GrokBar keeps a cursor per file and per model. Growth since the last read is what gets added. The same totals on the next read add nothing. If `totalTokens` goes down, the file restarted: the new totals are counted, and `startTimeUnixNano` moves so Bar UI can tell a restart from a drop. A single field that goes backwards while the total doesn't is counted as zero for that interval.

These totals are the sessions on this Mac after you turned recording on. They aren't an account-wide bill, and they aren't the usage inside one quota window. Deleting a session file doesn't subtract what was already counted.

## Events

Log records use these event names:

| Event | When |
| --- | --- |
| `bar.tracking.started` | The first capture after recording is turned on |
| `bar.limit.appeared` | A limit id shows up that wasn't in the previous sample |
| `bar.limit.reset` | A limit's reset time jumps forward by about half a window or more |
| `bar.limit.disappeared` | A limit id from the previous sample is gone |

Grok's billing payload doesn't include reset-credit perks, so GrokBar doesn't write perk metrics or perk events.

## Privacy

The files hold percentages, reset times, a prepaid dollar balance, token counts, and model ids. They don't hold prompts, responses, account identifiers, or sign-in credentials. Write errors show up in Settings, and the next capture tries again.

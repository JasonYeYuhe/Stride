#!/usr/bin/env python3
"""Stride's numbers, read-only: one dated table (RELEASE-1.4.2.md D15, Phase 0 item 7).

    scripts/metrics_snapshot.py              the last 8 weeks (Monday-based weeks, UTC)
    scripts/metrics_snapshot.py --weeks 12   a longer window

Every call is a GET. It reads:
  - Sentry release health for org jason-yeyuhe, project stride-apple (id 4511513693585408),
    environment=production: unique devices (`count_unique(user)`: the SDK's installation id),
    sessions and the crash-free rate (1 − crashed / sessions), by release and by week, and over
    the whole window. The sessions API takes no interval above a day, so a week is one window
    (start/end) per call. The token is read from ~/.sentryclirc.
  - ASC Sales and Trends for vendor 94126306, with scripts/asc_api.py's key: SALES (weekly) for
    downloads and Pro sales, SUBSCRIPTION (the latest daily snapshot) for active subscriptions,
    SUBSCRIPTION_EVENT (daily) for trials, conversions, cancellations and refunds. **The reports
    are account-wide** (ColorArchive, RoastMate, CLI Pulse, Nihongo Ride…), so every row is
    filtered here: an app row counts only with SKU `stride-habit-tracker` or Apple ID
    6761262334, an in-app purchase row only with that parent SKU, a subscription row only with
    App Apple ID 6761262334.
  - The count of written customer reviews (`customerReviews`). There is NO ratings count in the
    API: the owner reads it from App Store Connect → Ratings and Reviews and writes it in the
    progress log (D15).

What these numbers can decide: breakage and existence (any trial, any sale). Never a rate, a price
or an order of work (D15).

It never prints a secret: no token, no Authorization header. Every line goes through `scrub`,
which removes the tokens it used and anything shaped like a bearer token, so an error body that
echoed a header cannot leak it either. A failed source becomes an ERROR row and the exit status 1;
nothing works around auth.
"""

import configparser
import csv
import datetime as dt
import gzip
import io
import json
import os
import re
import sys

SENTRY_BASE = "https://sentry.io/api/0"
SENTRY_ORG = "jason-yeyuhe"
SENTRY_PROJECT_ID = "4511513693585408"  # stride-apple; apple-ios / apple-macos are CLI Pulse
SENTRY_ENV = "production"
RELEASE_PREFIX = "yyh.stride.habittracker@"

ASC_BASE = "https://api.appstoreconnect.apple.com/v1"
VENDOR = "94126306"
STRIDE_SKU = "stride-habit-tracker"
STRIDE_APPLE_ID = "6761262334"

# SALES "Product Type Identifier" (Apple's reference): first downloads, re-downloads, updates and
# in-app purchases, iOS/universal (F suffix), iPad (T) and Mac (F prefix).
FIRST_DOWNLOAD = {"1", "1F", "1T", "F1", "1E", "1EP", "1EU"}
REDOWNLOAD = {"3", "3F", "3T", "F3"}
UPDATE = {"7", "7F", "7T", "F7"}

SECRET_PATTERNS = [
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"),
    re.compile(r"sntry[su]_[A-Za-z0-9._=-]+"),
    re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"),  # a JWT
]


class Secrets:
    """The tokens this run used, to be scrubbed from anything it prints."""

    def __init__(self):
        self.values = set()

    def add(self, value):
        if value:
            self.values.add(value)
        return value

    def scrub(self, text):
        text = str(text)
        # Shapes first, so "Bearer <token>" goes as a whole; then the exact values used.
        for pattern in SECRET_PATTERNS:
            text = pattern.sub("[redacted]", text)
        for value in sorted(self.values, key=len, reverse=True):
            text = text.replace(value, "[redacted]")
        return text


class SourceError(Exception):
    """A source answered with an error; the message holds no secret (scrubbed again on print)."""


# ── HTTP ──────────────────────────────────────────────────────────────────────────────────────

def default_http_get(url, headers, params):
    """(status, body bytes). GET only: this script has no other method."""
    import requests
    r = requests.get(url, headers=headers, params=params, timeout=60)
    return r.status_code, r.content


def short_error(status, body):
    try:
        data = json.loads(body.decode("utf-8", "replace"))
        if isinstance(data, dict) and data.get("errors"):
            e = data["errors"][0]
            return f"{status} {e.get('code', '')}: {e.get('detail') or e.get('title') or ''}".strip()
        if isinstance(data, dict) and "detail" in data:
            return f"{status}: {data['detail']}"
    except (ValueError, AttributeError):
        pass
    return f"{status}: {body[:200].decode('utf-8', 'replace')}"


# ── Credentials ───────────────────────────────────────────────────────────────────────────────

def sentry_token(path="~/.sentryclirc"):
    """The [auth] token of sentry-cli's config. Never printed; a missing one is an error row."""
    config = configparser.ConfigParser()
    if not config.read(os.path.expanduser(path)):
        raise SourceError(f"no {path}")
    token = config.get("auth", "token", fallback="").strip()
    if not token:
        raise SourceError(f"{path} has no [auth] token")
    return token


def asc_headers_factory(secrets):
    """scripts/asc_api.py's ES256 JWT, a fresh one per call, each registered for scrubbing.
    Imported here, not at the top: asc_api reads scripts/.env and its variables on import."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import asc_api

    def make():
        token = secrets.add(asc_api.generate_token())
        return {"Authorization": f"Bearer {token}"}
    return make


# ── Weeks ─────────────────────────────────────────────────────────────────────────────────────

def week_starts(today, weeks):
    """The Mondays of the last `weeks` weeks, oldest first; the last is this (partial) week."""
    monday = today - dt.timedelta(days=today.weekday())
    return [monday - dt.timedelta(weeks=i) for i in range(weeks - 1, -1, -1)]


def release_name(release):
    if not release:
        return "(no release)"
    return release[len(RELEASE_PREFIX):] if release.startswith(RELEASE_PREFIX) else release


# ── Sentry ────────────────────────────────────────────────────────────────────────────────────

def sentry_query(http_get, token, start, end, fields, group_by):
    params = [("project", SENTRY_PROJECT_ID), ("environment", SENTRY_ENV), ("interval", "1d"),
              ("start", start.strftime("%Y-%m-%dT%H:%M:%S")), ("end", end.strftime("%Y-%m-%dT%H:%M:%S"))]
    params += [("field", f) for f in fields] + [("groupBy", g) for g in group_by]
    status, body = http_get(f"{SENTRY_BASE}/organizations/{SENTRY_ORG}/sessions/",
                            {"Authorization": f"Bearer {token}"}, params)
    if status != 200:
        raise SourceError("Sentry sessions " + short_error(status, body))
    return json.loads(body)


def sentry_summary(by_release, by_status, everyone):
    """Three responses for one window → {release or "all releases": (devices, sessions, crashed)}.

    Devices come from the by-release response: unique users cannot be added up across statuses.
    Sessions and crashes come from the by-release-and-status response."""
    out = {}
    for group in by_status.get("groups", []):
        release = release_name(group["by"].get("release"))
        sessions = int(group["totals"].get("sum(session)") or 0)
        crashed = sessions if group["by"].get("session.status") == "crashed" else 0
        devices, s, c = out.get(release, (0, 0, 0))
        out[release] = (devices, s + sessions, c + crashed)
    for group in by_release.get("groups", []):
        release = release_name(group["by"].get("release"))
        devices = int(group["totals"].get("count_unique(user)") or 0)
        _, s, c = out.get(release, (0, 0, 0))
        out[release] = (devices, s, c)
    total_sessions = sum(s for _, s, _ in out.values())
    total_crashed = sum(c for _, _, c in out.values())
    all_devices = 0
    for group in everyone.get("groups", []):
        all_devices += int(group["totals"].get("count_unique(user)") or 0)
    out = {k: v for k, v in out.items() if v[0] or v[1]}
    out["all releases"] = (all_devices, total_sessions, total_crashed)
    return out


def sentry_window(http_get, token, start, end):
    by_release = sentry_query(http_get, token, start, end, ["count_unique(user)"], ["release"])
    by_status = sentry_query(http_get, token, start, end, ["sum(session)"], ["release", "session.status"])
    everyone = sentry_query(http_get, token, start, end, ["count_unique(user)"], [])
    return sentry_summary(by_release, by_status, everyone)


def sentry_value(devices, sessions, crashed):
    if sessions:
        rate = f"{100 * (1 - crashed / sessions):.1f}%"
    else:
        rate = "n/a"
    return f"devices {devices} · sessions {sessions} · crash-free {rate} ({crashed} crashed)"


def release_sort_key(name):
    if name == "all releases":
        return (0, ())
    nums = tuple(int(n) for n in re.findall(r"\d+", name))
    return (1, tuple(-n for n in nums))


# ── ASC reports ───────────────────────────────────────────────────────────────────────────────

def parse_report(raw):
    """A Sales and Trends report (gzip'd, or already plain) → list of dicts."""
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    text = raw.decode("utf-8-sig", "replace")
    return list(csv.DictReader(io.StringIO(text), delimiter="\t"))


def asc_report(http_get, headers, report_type, frequency, version, date):
    """Rows, [] when Apple says there were no sales that day/week, None when not available yet."""
    params = {"filter[vendorNumber]": VENDOR, "filter[reportType]": report_type,
              "filter[reportSubType]": "SUMMARY", "filter[frequency]": frequency,
              "filter[version]": version, "filter[reportDate]": date.isoformat()}
    status, body = http_get(f"{ASC_BASE}/salesReports", headers(), params)
    if status == 200:
        return parse_report(body)
    if status == 404:
        detail = short_error(status, body).lower()
        if "no sales" in detail or "were no" in detail:
            return []
        return None
    raise SourceError(f"ASC {report_type} {date}: " + short_error(status, body))


def is_stride_app_row(row):
    return (row.get("SKU", "").strip() == STRIDE_SKU
            or row.get("Apple Identifier", "").strip() == STRIDE_APPLE_ID)


def is_stride_iap_row(row):
    return row.get("Parent Identifier", "").strip() == STRIDE_SKU


def is_stride_subscription_row(row):
    return row.get("App Apple ID", "").strip() == STRIDE_APPLE_ID


def units(row):
    try:
        return int(float(row.get("Units") or row.get("Quantity") or 0))
    except ValueError:
        return 0


def sales_summary(rows):
    """Stride's rows of one SALES report → counts. Other apps' rows are never counted."""
    out = {"first downloads": 0, "re-downloads": 0, "updates": 0, "pro": {}}
    for row in rows:
        kind = row.get("Product Type Identifier", "").strip()
        if is_stride_app_row(row) and not is_stride_iap_row(row):
            if kind in FIRST_DOWNLOAD:
                out["first downloads"] += units(row)
            elif kind in REDOWNLOAD:
                out["re-downloads"] += units(row)
            elif kind in UPDATE:
                out["updates"] += units(row)
        elif is_stride_iap_row(row):
            sku = row.get("SKU", "").strip()
            name = sku.rsplit(".", 1)[-1] if sku.startswith("yyh.stride.habittracker.pro.") else sku
            out["pro"][name] = out["pro"].get(name, 0) + units(row)
    return out


SUBSCRIPTION_COLUMNS = [
    ("standard", "Active Standard Price Subscriptions"),
    ("free trial", "Active Free Trial Introductory Offer Subscriptions"),
    ("billing retry", "Billing Retry"),
    ("grace period", "Grace Period"),
    ("subscribers", "Subscribers"),
]


def subscription_summary(rows):
    out = {label: 0 for label, _ in SUBSCRIPTION_COLUMNS}
    for row in rows:
        if not is_stride_subscription_row(row):
            continue
        for label, column in SUBSCRIPTION_COLUMNS:
            try:
                out[label] += int(float(row.get(column) or 0))
            except ValueError:
                pass
    return out


def event_summary(rows):
    """Stride's SUBSCRIPTION_EVENT rows → {event: quantity}."""
    out = {}
    for row in rows:
        if not is_stride_subscription_row(row):
            continue
        event = row.get("Event", "").strip() or "(no event)"
        out[event] = out.get(event, 0) + units(row)
    return out


def written_reviews(http_get, headers):
    status, body = http_get(f"{ASC_BASE}/apps/{STRIDE_APPLE_ID}/customerReviews", headers(),
                            {"limit": "1", "sort": "-createdDate"})
    if status != 200:
        raise SourceError("ASC customerReviews " + short_error(status, body))
    data = json.loads(body)
    total = data.get("meta", {}).get("paging", {}).get("total")
    latest = None
    if data.get("data"):
        latest = (data["data"][0].get("attributes", {}).get("createdDate") or "")[:10] or None
    return total, latest


# ── The table ─────────────────────────────────────────────────────────────────────────────────

def snapshot(argv=None, http_get=None, read_sentry_token=None, make_asc_headers=None, now=None,
             out=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    out = out or sys.stdout
    http_get = http_get or default_http_get
    now = now or dt.datetime.now(dt.timezone.utc)
    weeks = 8
    if "--weeks" in argv:
        weeks = int(argv[argv.index("--weeks") + 1])
    secrets = Secrets()
    rows = []          # (source, period, key, value)
    errors = 0

    def error(source, period, exc):
        nonlocal errors
        errors += 1
        rows.append((source, period, "ERROR", secrets.scrub(exc)))

    today = now.date()
    mondays = week_starts(today, weeks)
    window_start = dt.datetime.combine(mondays[0], dt.time(), dt.timezone.utc)

    # Sentry
    try:
        token = secrets.add((read_sentry_token or sentry_token)())
        for monday in mondays:
            start = dt.datetime.combine(monday, dt.time(), dt.timezone.utc)
            end = min(start + dt.timedelta(weeks=1), now)
            label = monday.isoformat() + (" (partial)" if end < start + dt.timedelta(weeks=1) else "")
            summary = sentry_window(http_get, token, start, end)
            for release in sorted(summary, key=release_sort_key):
                rows.append(("sentry", label, release, sentry_value(*summary[release])))
        summary = sentry_window(http_get, token, window_start, now)
        for release in sorted(summary, key=release_sort_key):
            rows.append(("sentry", f"{weeks} weeks", release, sentry_value(*summary[release])))
    except Exception as exc:  # noqa: BLE001 — every failure is a row, never a traceback with a header
        error("sentry", "—", exc)

    # ASC
    try:
        headers = make_asc_headers() if make_asc_headers else asc_headers_factory(secrets)
        # SALES, weekly (the report's date is the week's Sunday).
        totals = {"first downloads": 0, "re-downloads": 0, "updates": 0, "pro": {}}
        for monday in mondays:
            sunday = monday + dt.timedelta(days=6)
            if sunday >= today:
                rows.append(("asc sales", monday.isoformat(), "SALES", "this week's report is not out yet"))
                continue
            report = asc_report(http_get, headers, "SALES", "WEEKLY", "1_1", sunday)
            if report is None:
                rows.append(("asc sales", monday.isoformat(), "SALES", "not available yet"))
                continue
            s = sales_summary(report)
            pro = ", ".join(f"{k} {v}" for k, v in sorted(s["pro"].items())) or "none"
            rows.append(("asc sales", monday.isoformat(), "downloads (first / re / updates)",
                         f"{s['first downloads']} / {s['re-downloads']} / {s['updates']}"))
            rows.append(("asc sales", monday.isoformat(), "Pro units", pro))
            for k in ("first downloads", "re-downloads", "updates"):
                totals[k] += s[k]
            for k, v in s["pro"].items():
                totals["pro"][k] = totals["pro"].get(k, 0) + v
        pro = ", ".join(f"{k} {v}" for k, v in sorted(totals["pro"].items())) or "none"
        rows.append(("asc sales", f"{weeks} weeks", "downloads (first / re / updates)",
                     f"{totals['first downloads']} / {totals['re-downloads']} / {totals['updates']}"))
        rows.append(("asc sales", f"{weeks} weeks", "Pro units", pro))

        # SUBSCRIPTION: the newest daily snapshot.
        for back in range(1, 6):
            day = today - dt.timedelta(days=back)
            report = asc_report(http_get, headers, "SUBSCRIPTION", "DAILY", "1_4", day)
            if report is not None:
                s = subscription_summary(report)
                rows.append(("asc subs", day.isoformat(), "active (standard / trial / retry / grace)",
                             f"{s['standard']} / {s['free trial']} / {s['billing retry']} / {s['grace period']}"
                             f"; subscribers {s['subscribers']}"))
                break
        else:
            rows.append(("asc subs", "—", "SUBSCRIPTION", "no snapshot in the last 5 days"))

        # SUBSCRIPTION_EVENT, daily, summed per week.
        all_events = {}
        for monday in mondays:
            week_events, missing = {}, 0
            for i in range(7):
                day = monday + dt.timedelta(days=i)
                if day >= today:
                    break
                report = asc_report(http_get, headers, "SUBSCRIPTION_EVENT", "DAILY", "1_4", day)
                if report is None:
                    missing += 1
                    continue
                for k, v in event_summary(report).items():
                    week_events[k] = week_events.get(k, 0) + v
                    all_events[k] = all_events.get(k, 0) + v
            value = ", ".join(f"{k} {v}" for k, v in sorted(week_events.items())) or "none"
            if missing:
                value += f" ({missing} day(s) not out yet)"
            rows.append(("asc events", monday.isoformat(), "subscription events", value))
        rows.append(("asc events", f"{weeks} weeks", "subscription events",
                     ", ".join(f"{k} {v}" for k, v in sorted(all_events.items())) or "none"))

        total, latest = written_reviews(http_get, headers)
        rows.append(("asc reviews", "all time", "written reviews",
                     f"{total}" + (f" (latest {latest})" if latest else "")))
    except Exception as exc:  # noqa: BLE001
        error("asc", "—", exc)

    rows.append(("ratings", "—", "ratings count", "not in the API: the owner reads ASC → Ratings and Reviews"))

    # One dated table.
    stamp = now.strftime("%Y-%m-%d %H:%M UTC")
    head = (f"Stride metrics snapshot — {stamp} — production only; weeks are Monday-based (UTC), "
            f"{mondays[0].isoformat()} … {today.isoformat()}; ASC rows filtered to SKU {STRIDE_SKU} / "
            f"Apple ID {STRIDE_APPLE_ID}")
    widths = [max(len(str(r[i])) for r in rows + [("SOURCE", "PERIOD", "KEY", "VALUE")]) for i in range(3)]
    lines = [head, ""]
    for r in [("SOURCE", "PERIOD", "KEY", "VALUE")] + rows:
        lines.append("  ".join(str(r[i]).ljust(widths[i]) for i in range(3)) + "  " + str(r[3]))
    print(secrets.scrub("\n".join(lines)), file=out)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(snapshot())

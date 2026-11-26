#!/usr/bin/env python3
"""metrics_snapshot.py on fixtures, with no network and no credentials (RELEASE-1.4.2.md W9).

    python3 scripts/test_metrics_snapshot.py

The fixtures are account-wide, as Apple's reports are: ColorArchive, RoastMate and CLI Pulse rows
sit next to Stride's, some with bigger numbers, and none of them may be counted. The fake tokens
must never appear in the output, not even when an error body echoes the Authorization header.
"""

import datetime as dt
import gzip
import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metrics_snapshot as m  # noqa: E402

SENTRY_TOKEN = "sntrys_FAKEtokenFAKEtokenFAKEtoken0123456789"
ASC_TOKEN = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJmYWtlLWlzc3Vlci1pZCJ9.ZmFrZXNpZ25hdHVyZQ"
NOW = dt.datetime(2026, 11, 8, 6, 0, tzinfo=dt.timezone.utc)  # a Sunday

SALES_HEADER = ["Provider", "Provider Country", "SKU", "Developer", "Title", "Version",
                "Product Type Identifier", "Units", "Developer Proceeds", "Begin Date", "End Date",
                "Customer Currency", "Country Code", "Currency of Proceeds", "Apple Identifier",
                "Customer Price", "Promo Code", "Parent Identifier", "Subscription", "Period"]


def sales_row(sku, title, kind, units, apple_id, parent=" "):
    row = dict.fromkeys(SALES_HEADER, "")
    row.update({"SKU": sku, "Title": title, "Product Type Identifier": kind, "Units": str(units),
                "Apple Identifier": apple_id, "Parent Identifier": parent})
    return row


SALES_ROWS = [
    # Stride: 2 + 1 first downloads, 1 re-download, 4 updates, 1 Lifetime, 1 Yearly.
    sales_row("stride-habit-tracker", "Stride - Habit Tracker", "1F", 2, "6761262334"),
    sales_row("stride-habit-tracker", "Stride - Habit Tracker", "1F", 1, "6761262334"),
    sales_row("stride-habit-tracker", "Stride - Habit Tracker", "3F", 1, "6761262334"),
    sales_row("stride-habit-tracker", "Stride - Habit Tracker", "7F", 4, "6761262334"),
    sales_row("yyh.stride.habittracker.pro.lifetime", "Stride Pro Lifetime", "IA1", 1, "6777639244",
              "stride-habit-tracker"),
    sales_row("yyh.stride.habittracker.pro.yearly", "Stride Pro Yearly", "IAY", 1, "6777639245",
              "stride-habit-tracker"),
    # Not Stride: never counted.
    sales_row("colorarchive-ios", "ColorArchive - Color Tools", "1F", 50, "6761363087"),
    sales_row("colorarchive-ios", "ColorArchive - Color Tools", "7F", 70, "6761363087"),
    sales_row("colorarchive.pro.monthly", "Pro Monthly", "IAY", 9, "6761363999", "colorarchive-ios"),
    sales_row("colorarchive.pro.lifetime", "Pro Lifetime", "IA1", 8, "6761364000", "colorarchive-ios"),
    sales_row("roastmate-1", "RoastMate AI", "1", 30, "6769317103"),
    sales_row("roastmate-1", "RoastMate AI", "F7", 3, "6769317103"),
    sales_row("roastmate.pro.monthly", "RoastMate Pro Monthly", "IAY", 7, "6769317999", "roastmate-1"),
    sales_row("yyh.CLI-Pulse", "CLI Pulse", "F3", 5, "6761163709"),
]

SUB_HEADER = ["App Name", "App Apple ID", "Subscription Name", "Active Standard Price Subscriptions",
              "Active Free Trial Introductory Offer Subscriptions", "Billing Retry", "Grace Period",
              "Subscribers"]
SUB_ROWS = [
    {"App Name": "RoastMate AI", "App Apple ID": "6769317103", "Subscription Name": "RoastMate Pro Monthly",
     "Active Standard Price Subscriptions": "6", "Active Free Trial Introductory Offer Subscriptions": "4",
     "Billing Retry": "1", "Grace Period": "1", "Subscribers": "10"},
    {"App Name": "ColorArchive - Color Tools", "App Apple ID": "6761363087", "Subscription Name": "Pro Monthly",
     "Active Standard Price Subscriptions": "3", "Active Free Trial Introductory Offer Subscriptions": "2",
     "Billing Retry": "0", "Grace Period": "0", "Subscribers": "5"},
    {"App Name": "Stride - Habit Tracker", "App Apple ID": "6761262334", "Subscription Name": "Stride Pro Yearly",
     "Active Standard Price Subscriptions": "1", "Active Free Trial Introductory Offer Subscriptions": "0",
     "Billing Retry": "0", "Grace Period": "0", "Subscribers": "1"},
]

EVENT_HEADER = ["Event Date", "Event", "App Name", "App Apple ID", "Subscription Name", "Quantity"]
EVENT_ROWS = [
    {"Event Date": "2026-10-20", "Event": "Refund", "App Name": "ColorArchive - Color Tools",
     "App Apple ID": "6761363087", "Subscription Name": "Pro Monthly", "Quantity": "1"},
    {"Event Date": "2026-10-20", "Event": "Cancel", "App Name": "RoastMate AI",
     "App Apple ID": "6769317103", "Subscription Name": "RoastMate Pro Monthly", "Quantity": "2"},
    {"Event Date": "2026-10-20", "Event": "Start Introductory Offer", "App Name": "Stride - Habit Tracker",
     "App Apple ID": "6761262334", "Subscription Name": "Stride Pro Yearly", "Quantity": "1"},
]


def tsv(header, rows, gz=True):
    buf = io.StringIO()
    buf.write("\t".join(header) + "\n")
    for row in rows:
        buf.write("\t".join(row.get(h, "") for h in header) + "\n")
    raw = buf.getvalue().encode("utf-8")
    return gzip.compress(raw) if gz else raw


def no_sales():
    return 404, json.dumps({"errors": [{"status": "404", "code": "NOT_FOUND",
                                        "title": "The request expected results but none were found",
                                        "detail": "There were no sales for the date specified."}]}).encode()


def sentry_response(params):
    group_by = [v for k, v in params if k == "groupBy"]
    if group_by == ["release", "session.status"]:
        groups = [
            {"by": {"release": "yyh.stride.habittracker@1.4.0+22", "session.status": "healthy"},
             "totals": {"sum(session)": 95}},
            {"by": {"release": "yyh.stride.habittracker@1.4.0+22", "session.status": "crashed"},
             "totals": {"sum(session)": 5}},
            {"by": {"release": "yyh.stride.habittracker@1.4.1+23", "session.status": "healthy"},
             "totals": {"sum(session)": 10}},
        ]
    elif group_by == ["release"]:
        groups = [
            {"by": {"release": "yyh.stride.habittracker@1.4.0+22"}, "totals": {"count_unique(user)": 7}},
            {"by": {"release": "yyh.stride.habittracker@1.4.1+23"}, "totals": {"count_unique(user)": 3}},
        ]
    else:
        groups = [{"by": {}, "totals": {"count_unique(user)": 9}}]
    return 200, json.dumps({"groups": groups}).encode()


class Fake:
    """Routes each GET to a fixture and records it; anything but the expected auth is a failure."""

    def __init__(self, fail=None):
        self.calls = []
        self.fail = fail

    def __call__(self, url, headers, params):
        self.calls.append((url, headers, params))
        auth = headers.get("Authorization", "")
        if "sentry.io" in url:
            assert auth == f"Bearer {SENTRY_TOKEN}", "Sentry called without its token"
            if self.fail == "sentry":
                # A hostile body that echoes the header back.
                return 401, json.dumps({"detail": f"Invalid token: {auth}"}).encode()
            return sentry_response(params)
        assert auth == f"Bearer {ASC_TOKEN}", "ASC called without its token"
        if self.fail == "asc":
            return 403, json.dumps({"errors": [{"code": "FORBIDDEN", "detail": f"rejected {auth} and {ASC_TOKEN}"}]}).encode()
        if url.endswith("/customerReviews"):
            return 200, json.dumps({"data": [{"attributes": {"createdDate": "2026-04-12T10:00:00-07:00"}}],
                                    "meta": {"paging": {"total": 1, "limit": 1}}}).encode()
        params = dict(params)
        kind, date = params["filter[reportType]"], params["filter[reportDate]"]
        if kind == "SALES":
            return 200, tsv(SALES_HEADER, SALES_ROWS)
        if kind == "SUBSCRIPTION":
            return 200, tsv(SUB_HEADER, SUB_ROWS)
        if kind == "SUBSCRIPTION_EVENT":
            return (200, tsv(EVENT_HEADER, EVENT_ROWS)) if date == "2026-10-20" else no_sales()
        raise AssertionError(f"unexpected report {kind}")


def run(fake, weeks="2"):
    out = io.StringIO()
    code = m.snapshot(["--weeks", weeks], http_get=fake, read_sentry_token=lambda: SENTRY_TOKEN,
                      make_asc_headers=lambda: (lambda: {"Authorization": f"Bearer {ASC_TOKEN}"}),
                      now=NOW, out=out)
    return code, out.getvalue()


class Filtering(unittest.TestCase):
    def test_sales_counts_only_stride(self):
        s = m.sales_summary(m.parse_report(tsv(SALES_HEADER, SALES_ROWS)))
        self.assertEqual((s["first downloads"], s["re-downloads"], s["updates"]), (3, 1, 4))
        self.assertEqual(s["pro"], {"lifetime": 1, "yearly": 1})

    def test_sales_without_stride_is_zero(self):
        others = [r for r in SALES_ROWS if "stride" not in r["SKU"] and "stride" not in r["Parent Identifier"]]
        self.assertTrue(any("ColorArchive" in r["Title"] for r in others))
        self.assertTrue(any("RoastMate" in r["Title"] for r in others))
        s = m.sales_summary(m.parse_report(tsv(SALES_HEADER, others, gz=False)))
        self.assertEqual((s["first downloads"], s["re-downloads"], s["updates"], s["pro"]), (0, 0, 0, {}))

    def test_subscriptions_count_only_stride(self):
        s = m.subscription_summary(m.parse_report(tsv(SUB_HEADER, SUB_ROWS)))
        self.assertEqual(s, {"standard": 1, "free trial": 0, "billing retry": 0, "grace period": 0,
                             "subscribers": 1})
        none = m.subscription_summary(m.parse_report(tsv(SUB_HEADER, SUB_ROWS[:2])))
        self.assertEqual(set(none.values()), {0})

    def test_events_count_only_stride(self):
        self.assertEqual(m.event_summary(m.parse_report(tsv(EVENT_HEADER, EVENT_ROWS))),
                         {"Start Introductory Offer": 1})
        self.assertEqual(m.event_summary(m.parse_report(tsv(EVENT_HEADER, EVENT_ROWS[:2]))), {})


class Snapshot(unittest.TestCase):
    def test_table(self):
        fake = Fake()
        code, out = run(fake)
        self.assertEqual(code, 0, out)
        self.assertIn("Stride metrics snapshot — 2026-11-08 06:00 UTC", out)
        # Sentry: 1.4.0 has 100 sessions, 5 crashed → 95.0%; all releases 9 devices, 110 sessions.
        self.assertIn("1.4.0+22", out)
        self.assertIn("devices 7 · sessions 100 · crash-free 95.0% (5 crashed)", out)
        self.assertIn("devices 9 · sessions 110 · crash-free 95.5% (5 crashed)", out)
        # Week of 2026-10-26: one SALES report, Stride only.
        self.assertIn("3 / 1 / 4", out)
        self.assertIn("lifetime 1, yearly 1", out)
        self.assertIn("1 / 0 / 0 / 0; subscribers 1", out)
        self.assertIn("written reviews", out)
        self.assertIn("1 (latest 2026-04-12)", out)
        self.assertIn("not in the API", out)
        # Nothing of the other apps, by name or by number.
        for word in ("ColorArchive", "RoastMate", "CLI Pulse", "Refund", "Cancel"):
            self.assertNotIn(word, out)
        for figure in ("50", "70", "53 /", "subscribers 16", "subscribers 11"):
            self.assertNotIn(figure, out)
        # GET only, to the two hosts, with filters for the vendor.
        for url, _, params in fake.calls:
            self.assertTrue(url.startswith(("https://sentry.io/", "https://api.appstoreconnect.apple.com/")), url)
            if url.endswith("/salesReports"):
                self.assertEqual(dict(params)["filter[vendorNumber]"], "94126306")
            if "sentry.io" in url:
                self.assertIn(("environment", "production"), params)
                self.assertIn(("project", "4511513693585408"), params)

    def test_events_window(self):
        # The 2026-10-20 event is in the week of 10-19, inside a 3-week window.
        _, out = run(Fake(), weeks="3")
        self.assertIn("Start Introductory Offer 1", out)

    def test_no_secret_printed(self):
        for fail in (None, "sentry", "asc"):
            code, out = run(Fake(fail))
            self.assertNotIn(SENTRY_TOKEN, out)
            self.assertNotIn(ASC_TOKEN, out)
            self.assertNotIn("Bearer", out)
            self.assertNotIn("FAKEtoken", out)
            self.assertNotIn("eyJhbGci", out)
            if fail:
                self.assertEqual(code, 1)
                self.assertIn("ERROR", out)

    def test_scrub(self):
        secrets = m.Secrets()
        secrets.add("abc123secret")
        self.assertEqual(secrets.scrub("x abc123secret y"), "x [redacted] y")
        self.assertEqual(secrets.scrub("Authorization: Bearer whatever.it.is"), "Authorization: [redacted]")


if __name__ == "__main__":
    unittest.main(verbosity=1)

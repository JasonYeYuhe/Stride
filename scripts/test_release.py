#!/usr/bin/env python3
"""Offline tests for scripts/release.py: its argument parsing and the `--platform` filter.

    python3 -I scripts/test_release.py        # or: python3 -I -m unittest scripts/test_release.py

Nothing here reaches the network or reads a key. `asc_api` (the ASC helper release.py imports,
which reads scripts/.env and the API key at import) is replaced by `FakeASC` in sys.modules
before release.py is loaded, and `time.sleep` by a counter. FakeASC answers the few endpoints
release.py calls from an in-memory App Store Connect — versions per platform and review
submissions — and records every write, so a test can say exactly which submission was
cancelled and which release was requested.

Added in 1.4.1 (RELEASE-1.4.1.md W7) with `cancel --platform`: cancel used to pull every
platform's submission of a version out of review, and to wait on, and fail for, every platform.
"""

import contextlib
import importlib.util
import io
import os
import re
import sys
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))


class FakeASC(types.ModuleType):
    """Stands in for asc_api: an in-memory app with versions and review submissions."""

    def __init__(self):
        super().__init__("asc_api")
        self.reset()

    def reset(self):
        self.versions = {}        # platform -> {"id", "versionString", "appStoreState"}
        self.submissions = []     # {"id", "platform", "state", "versions": [version id]}
        self.cancel_takes_effect = True
        self.calls = []           # ("get"|"post"|"patch"|"find_app", path)
        self.writes = []          # ("post"|"patch", path, payload)

    # -- the in-memory App Store Connect ---------------------------------------------------
    def add_version(self, platform, version_string, state):
        vid = f"{platform}-{version_string}"
        self.versions[platform] = {"id": vid, "versionString": version_string, "appStoreState": state}
        return vid

    def add_submission(self, platform, state, version_id):
        sid = f"sub-{len(self.submissions) + 1}-{platform}"
        self.submissions.append({"id": sid, "platform": platform, "state": state, "versions": [version_id]})
        return sid

    # -- asc_api's interface, as release.py uses it ----------------------------------------
    def find_app(self):
        self.calls.append(("find_app", ""))
        return "APP"

    def get_version_localizations(self, version_id):
        self.calls.append(("get", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations"))
        return []

    def get(self, path, params=None):
        self.calls.append(("get", path))
        params = params or {}
        if path == "/apps/APP/appStoreVersions":
            wanted = params.get("filter[versionString]")
            return {"data": [
                {"id": v["id"], "attributes": {"platform": p, "versionString": v["versionString"],
                                                "appStoreState": v["appStoreState"]}}
                for p, v in self.versions.items() if wanted in (None, v["versionString"])]}
        if path == "/reviewSubmissions":
            states = set(params.get("filter[state]", "").split(","))
            return {"data": [
                {"id": s["id"], "attributes": {"state": s["state"], "platform": s["platform"]}}
                for s in self.submissions
                if s["platform"] == params.get("filter[platform]") and s["state"] in states]}
        if path.startswith("/reviewSubmissions/") and path.endswith("/items"):
            sid = path.split("/")[2]
            sub = next(s for s in self.submissions if s["id"] == sid)
            return {"data": [{"relationships": {"appStoreVersion": {"data": {"id": vid}}}}
                             for vid in sub["versions"]]}
        raise AssertionError(f"FakeASC: unexpected GET {path} {params}")

    def patch(self, path, data):
        self.calls.append(("patch", path))
        self.writes.append(("patch", path, data))
        if path.startswith("/reviewSubmissions/") and data["data"]["attributes"].get("canceled"):
            sub = next(s for s in self.submissions if s["id"] == path.split("/")[2])
            if self.cancel_takes_effect:
                sub["state"] = "CANCELING"
                for v in self.versions.values():
                    if v["id"] in sub["versions"]:
                        v["appStoreState"] = "DEVELOPER_REJECTED"
            return {"data": {"id": sub["id"]}}
        return None

    def post(self, path, data):
        self.calls.append(("post", path))
        self.writes.append(("post", path, data))
        return {"data": {"id": f"posted-{len(self.writes)}"}}


FAKE = FakeASC()


def load_release():
    """release.py as a module, importing FAKE as its asc_api."""
    sys.modules["asc_api"] = FAKE
    spec = importlib.util.spec_from_file_location("release_under_test", os.path.join(HERE, "release.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load_release()


class ReleaseTestCase(unittest.TestCase):
    def setUp(self):
        FAKE.reset()
        self.sleeps = 0

        def counting_sleep(_seconds):
            self.sleeps += 1

        patcher = mock.patch.object(release.time, "sleep", counting_sleep)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = release.main(list(argv))
        return code, out.getvalue()

    def cancelled_submissions(self):
        return [path.split("/")[2] for kind, path, data in FAKE.writes
                if kind == "patch" and path.startswith("/reviewSubmissions/")
                and data["data"]["attributes"].get("canceled")]


class ParsePlatformTests(ReleaseTestCase):
    def test_absent_means_every_platform_and_leaves_the_arguments(self):
        args = ["cancel", "1.4.1"]
        self.assertEqual(release.parse_platform(args), ["IOS", "MAC_OS"])
        self.assertEqual(args, ["cancel", "1.4.1"])

    def test_a_platform_is_taken_out_of_the_arguments_wherever_it_stands(self):
        for args, rest in ((["cancel", "1.4.1", "--platform", "MAC_OS"], ["cancel", "1.4.1"]),
                           (["--platform", "MAC_OS", "cancel", "1.4.1"], ["cancel", "1.4.1"]),
                           (["finish", "1.4.1", "--platform", "IOS", "23"], ["finish", "1.4.1", "23"])):
            with self.subTest(args=args):
                expected = ["MAC_OS"] if "MAC_OS" in args else ["IOS"]
                self.assertEqual(release.parse_platform(args), expected)
                self.assertEqual(args, rest)

    def test_no_value_an_unknown_value_or_twice_is_refused(self):
        for args in (["cancel", "1.4.1", "--platform"],
                     ["cancel", "1.4.1", "--platform", "macos"],
                     ["cancel", "1.4.1", "--platform", "1.4.1"],
                     ["cancel", "1.4.1", "--platform", "IOS", "--platform", "MAC_OS"]):
            with self.subTest(args=args):
                self.assertIsNone(release.parse_platform(list(args)))

    def test_parsing_does_not_change_the_platform_list(self):
        release.parse_platform(["cancel", "1.4.1", "--platform", "IOS"])
        self.assertEqual(release.PLATFORMS, ["IOS", "MAC_OS"])


class UsageErrorTests(ReleaseTestCase):
    """A usage error is answered before anything reaches App Store Connect."""

    def test_usage_errors_make_no_call(self):
        for argv in (["cancel", "1.4.1", "--platform", "WATCH_OS"],
                     ["cancel", "1.4.1", "--platform"],
                     ["release", "1.4.1", "--platform", "IOS", "--platform", "MAC_OS"],
                     ["finish", "1.4.1"],
                     ["finish", "1.4.1", "--platform", "IOS"],
                     ["cancle", "1.4.1"],
                     ["cancel"],
                     [],
                     # An argument the command does not take. Each of these used to fall into the
                     # build-number slot or past it, leave `platforms` at both, and act on both.
                     ["cancel", "1.4.1", "--platform=MAC_OS"],
                     ["cancel", "1.4.1", "MAC_OS"],
                     ["cancel", "1.4.1", "-p", "MAC_OS"],
                     ["cancel", "1.4.1", "--plaform", "MAC_OS"],
                     ["release", "1.4.1", "--plaform", "IOS"],
                     ["release", "1.4.1", "--platform=MAC_OS"],
                     ["prepare", "1.4.1", "IOS"],
                     ["show", "1.4.1", "extra"],
                     ["finish", "1.4.1", "23", "--platform=IOS"],
                     ["finish", "1.4.1", "23", "MAC_OS"],
                     ["finish", "1.4.1", "--platform", "IOS", "23", "MAC_OS"],
                     ["--platform=IOS", "finish", "1.4.1", "23"],
                     ["cancel", "1.4.1", "--help"],
                     # A platform where the version or the build belongs.
                     ["finish", "1.4.1", "MAC_OS"],
                     ["cancel", "MAC_OS"],
                     ["release", "--platform", "IOS", "IOS"]):
            with self.subTest(argv=argv):
                FAKE.reset()
                code, _ = self.run_main(*argv)
                self.assertEqual(code, 1)
                self.assertEqual(FAKE.calls, [], "no ASC call for a usage error")

    def test_platform_with_an_equals_sign_cancels_neither_platform(self):
        # The review's reproduction: iOS waiting for review, the Mac in review. Until the W7 review
        # this exited 0 after cancelling BOTH submissions.
        FAKE.add_version("IOS", "1.4.1", "WAITING_FOR_REVIEW")
        FAKE.add_version("MAC_OS", "1.4.1", "IN_REVIEW")
        FAKE.add_submission("IOS", "WAITING_FOR_REVIEW", "IOS-1.4.1")
        FAKE.add_submission("MAC_OS", "IN_REVIEW", "MAC_OS-1.4.1")

        code, out = self.run_main("cancel", "1.4.1", "--platform=MAC_OS")

        self.assertEqual(code, 1)
        self.assertEqual(FAKE.calls, [])
        self.assertEqual(self.cancelled_submissions(), [])
        self.assertEqual(FAKE.versions["IOS"]["appStoreState"], "WAITING_FOR_REVIEW")
        self.assertEqual(FAKE.versions["MAC_OS"]["appStoreState"], "IN_REVIEW")
        self.assertIn("--platform MAC_OS", out, "says how to write it")

    def test_every_documented_form_is_accepted(self):
        for argv in (["show", "1.4.1"],
                     ["prepare", "1.4.1"],
                     ["cancel", "1.4.1"],
                     ["release", "1.4.1"],
                     ["finish", "1.4.1", "23"],
                     ["finish", "1.2.1", "15"],
                     ["finish", "1.4.1", "23.1"]):
            with self.subTest(argv=argv):
                self.assertIsNone(release.usage_error(list(argv)))
        args = ["finish", "1.4.0", "22", "--platform", "IOS"]
        self.assertEqual(release.parse_platform(args), ["IOS"])
        self.assertIsNone(release.usage_error(args))


class CancelTests(ReleaseTestCase):
    def both_in_review(self):
        ios = FAKE.add_version("IOS", "1.4.1", "WAITING_FOR_REVIEW")
        mac = FAKE.add_version("MAC_OS", "1.4.1", "IN_REVIEW")
        ios_sub = FAKE.add_submission("IOS", "WAITING_FOR_REVIEW", ios)
        mac_sub = FAKE.add_submission("MAC_OS", "IN_REVIEW", mac)
        return ios_sub, mac_sub

    def test_platform_cancels_only_that_platforms_submission(self):
        ios_sub, mac_sub = self.both_in_review()

        code, out = self.run_main("cancel", "1.4.1", "--platform", "MAC_OS")

        self.assertEqual(code, 0, out)
        self.assertEqual(self.cancelled_submissions(), [mac_sub])
        self.assertEqual(FAKE.versions["IOS"]["appStoreState"], "WAITING_FOR_REVIEW", "iOS stays in review")
        self.assertEqual(FAKE.versions["MAC_OS"]["appStoreState"], "DEVELOPER_REJECTED")
        self.assertNotIn("[IOS]", out, "another platform is neither touched nor reported")
        self.assertNotIn("STILL IN REVIEW", out)
        # The old code waited on every platform: with iOS still in review it slept 20 × 15 s and
        # then failed with "STILL IN REVIEW: IOS".
        self.assertEqual(self.sleeps, 0)
        submissions_read = [p for kind, p in FAKE.calls if kind == "get" and p == "/reviewSubmissions"]
        self.assertEqual(len(submissions_read), 1, "only the Mac's submissions are listed")

    def test_ios_alone_leaves_the_mac_in_review(self):
        ios_sub, mac_sub = self.both_in_review()

        code, out = self.run_main("cancel", "1.4.1", "--platform", "IOS")

        self.assertEqual(code, 0, out)
        self.assertEqual(self.cancelled_submissions(), [ios_sub])
        self.assertEqual(FAKE.versions["MAC_OS"]["appStoreState"], "IN_REVIEW")
        self.assertNotIn("[MAC_OS]", out)

    def test_without_platform_both_are_cancelled_as_before(self):
        ios_sub, mac_sub = self.both_in_review()

        code, out = self.run_main("cancel", "1.4.1")

        self.assertEqual(code, 0, out)
        self.assertEqual(sorted(self.cancelled_submissions()), sorted([ios_sub, mac_sub]))
        self.assertIn("[IOS] 1.4.1 now DEVELOPER_REJECTED", out)
        self.assertIn("[MAC_OS] 1.4.1 now DEVELOPER_REJECTED", out)

    def test_a_platform_with_no_version_cancels_nothing(self):
        mac = FAKE.add_version("MAC_OS", "1.4.1", "IN_REVIEW")
        mac_sub = FAKE.add_submission("MAC_OS", "IN_REVIEW", mac)

        code, out = self.run_main("cancel", "1.4.1", "--platform", "IOS")

        self.assertEqual(code, 0, out)
        self.assertEqual(self.cancelled_submissions(), [])
        self.assertIn("[IOS] no 1.4.1 version", out)
        self.assertEqual(FAKE.versions["MAC_OS"]["appStoreState"], "IN_REVIEW")
        self.assertNotIn(mac_sub, out)

    def test_only_a_submission_holding_the_version_is_cancelled(self):
        mac_141 = FAKE.add_version("MAC_OS", "1.4.1", "PREPARE_FOR_SUBMISSION")
        other = FAKE.add_submission("MAC_OS", "WAITING_FOR_REVIEW", "MAC_OS-1.4.0")

        code, out = self.run_main("cancel", "1.4.1", "--platform", "MAC_OS")

        self.assertEqual(code, 0, out)
        self.assertEqual(self.cancelled_submissions(), [], f"{other} holds another version")
        self.assertIn("no open submission holds 1.4.1", out)
        self.assertEqual(FAKE.versions["MAC_OS"]["id"], mac_141)

    def test_a_cancel_apple_has_not_applied_yet_is_waited_on_then_reported(self):
        FAKE.cancel_takes_effect = False
        _, mac_sub = self.both_in_review()

        code, out = self.run_main("cancel", "1.4.1", "--platform", "MAC_OS")

        self.assertEqual(code, 1)
        self.assertEqual(self.cancelled_submissions(), [mac_sub])
        self.assertEqual(self.sleeps, 20, "the bounded wait, on the Mac alone")
        self.assertIn("STILL IN REVIEW: MAC_OS", out)
        self.assertNotIn("IOS", out.replace("STILL IN REVIEW: MAC_OS", ""))


class OtherCommandsKeepTheirFilterTests(ReleaseTestCase):
    """`--platform` moved from a mutated global to a local: prepare/finish/release still obey it."""

    def test_release_requests_only_the_named_platform(self):
        FAKE.add_version("IOS", "1.4.1", "PENDING_DEVELOPER_RELEASE")
        FAKE.add_version("MAC_OS", "1.4.1", "PENDING_DEVELOPER_RELEASE")

        code, out = self.run_main("release", "1.4.1", "--platform", "IOS")

        self.assertEqual(code, 0, out)
        posted = [data for kind, path, data in FAKE.writes
                  if kind == "post" and path == "/appStoreVersionReleaseRequests"]
        self.assertEqual([d["data"]["relationships"]["appStoreVersion"]["data"]["id"] for d in posted],
                         ["IOS-1.4.1"])

    def test_a_filtered_call_does_not_narrow_the_next_one(self):
        FAKE.add_version("IOS", "1.4.1", "PENDING_DEVELOPER_RELEASE")
        FAKE.add_version("MAC_OS", "1.4.1", "PENDING_DEVELOPER_RELEASE")
        self.run_main("release", "1.4.1", "--platform", "MAC_OS")
        FAKE.writes.clear()

        code, out = self.run_main("release", "1.4.1")

        self.assertEqual(code, 0, out)
        posted = sorted(d["data"]["relationships"]["appStoreVersion"]["data"]["id"]
                        for kind, path, d in FAKE.writes if path == "/appStoreVersionReleaseRequests")
        self.assertEqual(posted, ["IOS-1.4.1", "MAC_OS-1.4.1"])


def catalog(language):
    """Shared/<language>.lproj/Localizable.strings as {key: value} (English: the key is the text)."""
    path = os.path.join(HERE, "..", "Shared", f"{language}.lproj", "Localizable.strings")
    pair = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";')
    with open(path, encoding="utf-8") as f:
        return {m.group(1): m.group(2) for m in map(pair.match, f) if m}


class WhatsNewCopyTests(unittest.TestCase):
    """WHATS_NEW_BY_VERSION, which `prepare` sends to every locale (added in 1.4.1, W9)."""

    def test_every_version_has_the_six_locales_within_the_limit(self):
        for version, copy in release.WHATS_NEW_BY_VERSION.items():
            with self.subTest(version=version):
                self.assertEqual(sorted(copy), sorted(release.LOCALES))
                for locale, text in copy.items():
                    self.assertTrue(text.strip(), f"{version} {locale} is empty")
                    # UTF-16 units: never fewer than the characters App Store Connect counts.
                    self.assertLessEqual(len(text.encode("utf-16-le")) // 2, 4000, f"{version} {locale}")

    def test_1_4_1_names_what_the_app_calls_it_and_no_sign_in(self):
        # The words a user then looks for: the Strength tile, History and its Edit history button
        # on Statistics' card, the note field, and the Pro card's title. No sign-in sentence.
        keys = ["Strength", "History", "Edit history", "Statistics", "Note", "Your Top 5 Streaks"]
        languages = {"en-US": "en", "es-ES": "es", "ja": "ja", "ko": "ko", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"}
        for locale, language in languages.items():
            text = release.WHATS_NEW_BY_VERSION["1.4.1"][locale].casefold()
            words = {k: k for k in keys + ["Sign In", "Log In"]} if language == "en" else catalog(language)
            with self.subTest(locale=locale):
                for key in keys:
                    self.assertIn(words[key].casefold(), text, f"{locale} lacks the app's {key!r}: {words[key]}")
                for key in ["Sign In", "Log In"]:
                    self.assertNotIn(words[key].casefold(), text, f"{locale} has a sign-in sentence")


if __name__ == "__main__":
    unittest.main(verbosity=2)

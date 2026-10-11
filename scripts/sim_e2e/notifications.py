#!/usr/bin/env python3
"""Read a simulator's UserNotifications stores (scratch copies only). Python 3.9+, stdlib only.

    notifications.py appdir <device>/data/Library/UserNotifications <bundle id>
    notifications.py requests <PendingNotifications.plist>
    notifications.py categories <Categories.plist>

Run as `/usr/bin/python3 -I notifications.py …` (app.sh does): -I keeps the user's environment
and the current directory out of sys.path.

Why: the upgrade gate (upgrade.sh --reminders) and the D7 reminder checks (RELEASE-1.4.0.md)
must see what the SYSTEM holds after a 1.4.0 launch: a 1.3.x daily request for a Mon/Wed/Fri
habit replaced by weekday requests .2/.4/.6, a daily habit's bare id kept, both categories
registered. Nothing in the app can be trusted for that (its own getPending is async and its
removes and adds land later), and simctl has no command for it. The simulator keeps it on disk:
<device data>/Library/UserNotifications/<directory>/PendingNotifications.plist, next to
Categories.plist and DeliveredNotifications.plist; Library.plist in the parent maps each bundle
id to its <directory> (design review: upgrade-gate-blind-to-reminders, refuted on exactly that).

The files are NSKeyedArchiver archives. What is known, and how each part is read:
  - Library.plist: a dictionary bundle id → directory name (observed, iOS 26.5 runtime).
  - Categories.plist: an array of dictionaries; the category's id is "Identifier", its actions
    are under "Actions" (observed). Older/newer runtimes: "UNCategoryIdentifier" is accepted too.
  - PendingNotifications.plist: an array of record dictionaries. No simulator on this Mac had
    ever held a pending request when this was written (2026-10-10), so the record keys are taken
    from the iOS 26.5 runtime's UserNotificationsCore strings: the request id
    "AppNotificationIdentifier", the category "SBSPushStoreNotificationCategoryKey", the trigger
    "TriggerDateComponents"; the newer mapper's "Identifier" / "CategoryIdentifier" are accepted
    too. If NO record with a known id key is found, every archived string that starts with one
    of Stride's request prefixes is reported instead ("decoded strings"), category unknown ("?"):
    the identifiers still decide the checks, and the report says the record format was not read.

Output (tab-separated, one fact per line; a person reads it in the evidence too):
  requests:   "decoded-requests<TAB>records|strings",
              then "request<TAB><id><TAB><category|-|?><TAB><trigger>" per request
  categories: "decoded-categories<TAB>records|strings",
              then "category<TAB><id><TAB><action ids, comma-separated|-|?>" per category
  appdir:     the directory's path, or nothing; how it was found goes to stderr.
Exit 0 on a readable file (an empty store prints no request lines), 1 on an unreadable one.
"""

import os
import plistlib
import sys

REQUEST_ID_KEYS = ("AppNotificationIdentifier", "Identifier", "RequestIdentifier")
CATEGORY_KEYS = ("SBSPushStoreNotificationCategoryKey", "CategoryIdentifier",
                 "AppNotificationCategoryIdentifier", "UNCategoryIdentifier")
TRIGGER_KEYS = ("TriggerDateComponents", "TriggerTimeInterval", "TriggerDate")
CATEGORY_ID_KEYS = ("Identifier", "UNCategoryIdentifier")
ACTIONS_KEYS = ("Actions", "UNCategoryActions")
# Stride's request ids (NotificationService): per-habit reminders (bare and .<weekday>), snoozes,
# and the two globals. Only the strings fallback needs them.
REQUEST_ID_PREFIXES = ("stride.habit.reminder.", "stride.habit.snooze.", "stride.daily.")
# NSDateComponents' "undefined" (NSDateComponentUndefined = NSIntegerMax).
UNDEFINED = 0x7FFFFFFFFFFFFFFF


class Archive:
    """A generic NSKeyedArchiver reader: dictionaries, arrays, strings, numbers, dates, data,
    and any other object as a dict of its archived fields plus "$class". Cycles are cut by a
    memo (an object seen again is the same Python object)."""

    def __init__(self, path):
        with open(path, "rb") as f:
            self.raw = plistlib.load(f)
        self.keyed = isinstance(self.raw, dict) and "$objects" in self.raw
        self.objects = self.raw.get("$objects", []) if self.keyed else []
        self._memo = {}

    def root(self):
        if not self.keyed:
            return self.raw
        top = self.raw.get("$top", {})
        return self._decode(top.get("root"))

    def strings(self):
        """Every string object in the archive (or every string in a plain plist)."""
        out = []
        if self.keyed:
            out = [o for o in self.objects if isinstance(o, str) and o != "$null"]
            for o in self.objects:  # NSString archived as an object
                if isinstance(o, dict) and isinstance(o.get("NS.string"), str):
                    out.append(o["NS.string"])
        else:
            walk(self.raw, lambda v: out.append(v) if isinstance(v, str) else None)
        return out

    def _classname(self, obj):
        cls = obj.get("$class")
        if isinstance(cls, plistlib.UID) and cls.data < len(self.objects):
            meta = self.objects[cls.data]
            if isinstance(meta, dict):
                return meta.get("$classname", "?")
        return "?"

    def _decode(self, x):
        if isinstance(x, plistlib.UID):
            i = x.data
            if i in self._memo:
                return self._memo[i]
            if i >= len(self.objects):
                return None
            o = self.objects[i]
            if o == "$null":
                return None
            if not isinstance(o, dict) or "$class" not in o:
                value = self._decode(o)
                self._memo[i] = value
                return value
            if "NS.keys" in o and "NS.objects" in o:
                d = {}
                self._memo[i] = d
                for k, v in zip(o["NS.keys"], o["NS.objects"]):
                    d[str(self._decode(k))] = self._decode(v)
                return d
            if "NS.objects" in o:
                lst = []
                self._memo[i] = lst
                lst.extend(self._decode(v) for v in o["NS.objects"])
                return lst
            if "NS.string" in o:
                return o["NS.string"]
            if "NS.time" in o:
                return ("date", o["NS.time"])
            if "NS.data" in o:
                return ("data", o["NS.data"])
            fields = {"$class": self._classname(o)}
            self._memo[i] = fields
            for k, v in o.items():
                if k != "$class":
                    fields[k] = self._decode(v)
            return fields
        if isinstance(x, list):
            return [self._decode(v) for v in x]
        if isinstance(x, dict):
            return {k: self._decode(v) for k, v in x.items()}
        return x


def walk(value, visit, seen=None):
    """Depth-first over dicts and lists, each container once."""
    if seen is None:
        seen = set()
    visit(value)
    if isinstance(value, (dict, list)):
        if id(value) in seen:
            return
        seen.add(id(value))
        children = value.values() if isinstance(value, dict) else value
        for child in children:
            walk(child, visit, seen)


def first_str(d, keys):
    for k in keys:
        v = d.get(k)
        if isinstance(v, str) and v:
            return v
    return None


def trigger_summary(record):
    """A short, human-readable trigger: "weekday=2 hour=20 minute=0 repeats" when the date
    components decode, else whatever is there, else "-". Informational only: no check uses it."""
    parts = []
    for key in TRIGGER_KEYS:
        v = record.get(key)
        if v is None:
            continue
        if isinstance(v, dict):
            comps = []
            for name in ("year", "month", "day", "weekday", "hour", "minute", "second"):
                for k in (name, "NS." + name, "NS" + name.capitalize()):
                    n = v.get(k)
                    if isinstance(n, int) and not isinstance(n, bool) and n != UNDEFINED:
                        comps.append(f"{name}={n}")
                        break
            parts.append(" ".join(comps) if comps else key)
        elif isinstance(v, tuple):
            parts.append(key)
        else:
            parts.append(f"{key}={v}")
    repeats = record.get("TriggerRepeats")
    if repeats is True:
        parts.append("repeats")
    return " ".join(parts) if parts else "-"


def cmd_requests(path):
    a = Archive(path)
    records = []
    walk(a.root(), lambda v: records.append(v) if isinstance(v, dict) and first_str(v, REQUEST_ID_KEYS) else None)
    # A category dictionary also has "Identifier"; a request record never has "Actions".
    records = [r for r in records if not any(k in r for k in ACTIONS_KEYS)]
    if records:
        print("decoded-requests\trecords")
        for r in records:
            cat = first_str(r, CATEGORY_KEYS) or "-"
            print(f"request\t{first_str(r, REQUEST_ID_KEYS)}\t{cat}\t{trigger_summary(r)}")
        return 0
    strings = sorted({s for s in a.strings() if s.startswith(REQUEST_ID_PREFIXES)})
    print("decoded-requests\tstrings" if strings else "decoded-requests\trecords")
    for s in strings:
        print(f"request\t{s}\t?\t?")
    return 0


def cmd_categories(path):
    a = Archive(path)
    root = a.root()
    found = []
    items = root if isinstance(root, list) else []
    for item in items:
        if isinstance(item, dict):
            cid = first_str(item, CATEGORY_ID_KEYS)
            if cid:
                actions = []
                for key in ACTIONS_KEYS:
                    for act in item.get(key) or []:
                        if isinstance(act, dict):
                            aid = first_str(act, ("Identifier", "UNActionIdentifier"))
                            if aid:
                                actions.append(aid)
                found.append((cid, actions))
    # An empty store archives a bare $null root: no categories, and nothing to fall back on.
    if found or isinstance(root, list) or root is None:
        print("decoded-categories\trecords")
        for cid, actions in found:
            print(f"category\t{cid}\t{','.join(actions) or '-'}")
        return 0
    print("decoded-categories\tstrings")
    for s in sorted({s for s in a.strings() if s in ("stride.habit.binary", "stride.habit.count")}):
        print(f"category\t{s}\t?")
    return 0


def contains(path, needle):
    try:
        with open(path, "rb") as f:
            return needle in f.read()
    except OSError:
        return False


def cmd_appdir(un_root, bundle):
    lib = os.path.join(un_root, "Library.plist")
    if os.path.isfile(lib):
        try:
            mapping = Archive(lib).root()
        except Exception as e:  # an unreadable map falls through to the scan
            print(f"Library.plist unreadable ({e}); scanning", file=sys.stderr)
            mapping = None
        if isinstance(mapping, dict):
            name = mapping.get(bundle)
            if isinstance(name, str) and os.path.isdir(os.path.join(un_root, name)):
                print(f"found via Library.plist: {bundle} → {name}", file=sys.stderr)
                print(os.path.join(un_root, name))
                return 0
    # No map entry: the one directory whose stores hold the app's own identifiers. Binary plists
    # keep ASCII strings as bytes, so a byte search finds them without decoding every store.
    hits = []
    if os.path.isdir(un_root):
        for name in sorted(os.listdir(un_root)):
            d = os.path.join(un_root, name)
            if os.path.isdir(d) and any(
                    contains(os.path.join(d, f), b"stride.habit.")
                    for f in ("PendingNotifications.plist", "Categories.plist")):
                hits.append(d)
    if len(hits) == 1:
        print(f"found by scanning for stride.habit.: {os.path.basename(hits[0])}", file=sys.stderr)
        print(hits[0])
    elif hits:
        print(f"{len(hits)} directories hold stride.habit. identifiers; not guessing: "
              + ", ".join(os.path.basename(h) for h in hits), file=sys.stderr)
    else:
        print(f"no UserNotifications directory for {bundle} under {un_root}", file=sys.stderr)
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] in ("requests", "categories"):
        try:
            return cmd_requests(argv[1]) if argv[0] == "requests" else cmd_categories(argv[1])
        except Exception as e:
            print(f"notifications.py: cannot read {argv[1]}: {e}", file=sys.stderr)
            return 1
    if len(argv) >= 3 and argv[0] == "appdir":
        return cmd_appdir(argv[1], argv[2])
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

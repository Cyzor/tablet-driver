"""Checks which issues get a missing-capture reminder, and which never do."""

import sys

sys.path.insert(0, sys.argv[1])
import attachment_check as ac  # noqa: E402

FAILED = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        FAILED.append(name)


FALLBACK = """### Model

Graphire 3 (4×5)

### Connection

USB

### Capture

<!-- Captured by MockTab -->
<!-- Device: Graphire 3 (4×5) — 0x056A/0x0013 -->

**Attach `mocktab-diagnostics-0x0013-20260101-120000.zip`:** drag it here from the Finder window MockTab opened.
"""
INLINE = FALLBACK.split("### Capture")[0] + """### Capture

<!-- Captured by MockTab — please leave the JSON block intact -->

```json
{"captureVersion": 28}
```
"""
BUG = "### macOS version\n\n27.0\n\n### Steps\n\nTypo in the menu.\n\n### Capture\n\n_No response_\n"
FEATURE = "### Problem\n\nColors are too dim.\n\n### Proposal\n\nBrighter.\n"
ZIP = "[x.zip](https://github.com/user-attachments/files/1000001/mocktab-diagnostics-0x0013-20260101-120000.zip)"
EMAIL = "Here is the capture, attached.\n\n> You are receiving this because you authored the thread."


def issue(body, state="open"):
    return {"number": 26, "body": body, "state": state, "user": {"login": "reporter"}}


def comment(body, login="reporter", cid=1):
    return {"id": cid, "body": body, "user": {"login": login}}


check(ac.decide(issue(FALLBACK), []) == "missing", "MockTab fallback with no zip gets a reminder")
check("mocktab-diagnostics-0x0013-20260101-120000.zip" in ac.message("missing", FALLBACK),
      "the reminder names the file")
check(ac.decide(issue(FALLBACK), [comment(ZIP)]) is None, "a zip in a comment is enough")
check(ac.decide(issue(FALLBACK + ZIP), []) is None, "a zip in the body is enough")
check(ac.decide(issue(INLINE), []) is None, "inline JSON needs no zip")
pasted = FALLBACK.split("### Capture")[0] + '### Capture data\n\n{\n  "captureVersion" : 13\n}\n'
check(ac.decide(issue(pasted), []) is None, "JSON pasted without a fence counts")
old_json = "[d.json](https://github.com/user-attachments/files/1000002/mocktab_discovery_0x0013.json)"
check(ac.decide(issue(FALLBACK), [comment(old_json)]) is None, "an older .json attachment counts")
check(ac.decide(issue(BUG), []) is None, "bug reports are left alone")
check(ac.decide(issue(FEATURE), []) is None, "feature requests are left alone")
check(ac.decide(issue(FALLBACK, state="closed"), []) is None, "closed issues are left alone")
check(ac.decide(issue(FALLBACK), [comment(ac.MARK, login="github-actions[bot]", cid=9)]) is None,
      "one reminder per issue")

later = comment("Still testing.", cid=2)
check(ac.decide(issue(FALLBACK), [later], later) == "missing", "the reporter's later comment still gets it")
owner = comment("Please repost the zip.", login="Cyzor", cid=3)
check(ac.decide(issue(FALLBACK), [owner], owner) is None, "the maintainer's comments never trigger it")

email = comment(EMAIL, cid=4)
earlier_zip = comment(ZIP, cid=5)
check(ac.decide(issue(FALLBACK), [earlier_zip, email], email) == "email",
      "an email reply naming an attachment gets the email note, even with an older zip")
check(ac.EMAIL_MARK in ac.message("email", FALLBACK), "the email note carries its own marker")
noted = comment(ac.EMAIL_MARK, login="github-actions[bot]", cid=6)
check(ac.decide(issue(FALLBACK), [earlier_zip, noted, email], email) is None, "one email note per issue")
plain = comment("Thanks, works now.\n\n> Reply to this email directly", cid=7)
check(ac.decide(issue(FALLBACK), [earlier_zip, plain], plain) is None,
      "an email reply that mentions no file is left alone")
check(ac.decide(issue(BUG), [email], email) is None, "email replies on bug reports are left alone")

if FAILED:
    print(f"{len(FAILED)} failed")
    sys.exit(1)
print("All attachment-check tests passed.")

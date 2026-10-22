"""Reminds a reporter when a device-support issue's capture zip never arrived.

Runs from .github/workflows/attachment-check.yml. Bug reports and feature
requests never get a reminder: only device-support issues need a capture.
GitHub may drop attachments sent by email reply, so an email reply that mentions
one gets its own note.
"""

import json
import os
import re
import subprocess

MARK = "<!-- mocktab-attachment-check -->"
EMAIL_MARK = "<!-- mocktab-attachment-check:email -->"
ATTACHMENT = re.compile(r"https://github\.com/user-attachments/files/\d+/", re.IGNORECASE)
ZIP_NAME = re.compile(r"Attach `([^`]+\.zip)`")
EMAIL_FOOTER = ("Reply to this email directly", "You are receiving this because")
MENTIONS_FILE = re.compile(r"\b(attach\w*|zip|diagnostics?|capture)\b", re.IGNORECASE)


def needs_capture(body):
    """Device-support form, or a capture MockTab filed without its data."""
    form = "### Connection" in body and "### Capture" in body
    return form or "<!-- Captured by MockTab -->" in body


def has_capture(body, comments):
    """An attached file, or capture JSON pasted in, fenced or not."""
    texts = [body] + [c.get("body") or "" for c in comments]
    return any(ATTACHMENT.search(t) or '"captureVersion"' in t for t in texts)


def is_email_reply(text):
    return any(footer in text for footer in EMAIL_FOOTER)


def decide(issue, comments, comment=None):
    """Which note to post, "missing" or "email", or None."""
    body = issue.get("body") or ""
    if issue.get("pull_request") or issue.get("state") != "open" or not needs_capture(body):
        return None
    author = issue["user"]["login"]
    earlier = [c["body"] for c in comments if comment is None or c["id"] != comment["id"]]
    if comment is not None:
        if comment["user"]["login"] != author:
            return None
        text = comment.get("body") or ""
        if is_email_reply(text) and MENTIONS_FILE.search(text) and not ATTACHMENT.search(text):
            return None if any(EMAIL_MARK in b for b in earlier) else "email"
    if any(MARK in b for b in earlier) or has_capture(body, comments):
        return None
    return "missing"


def message(kind, body):
    if kind == "email":
        return (
            f"{EMAIL_MARK}\n"
            "Email attachments don't always reach GitHub. "
            "Please open this issue in a web browser to upload support data."
        )
    name = ZIP_NAME.search(body)
    file = f"`{name.group(1)}`" if name else "the zip from **Help › Collect Device Data…**"
    return (
        f"{MARK}\n"
        f"The diagnostics file didn't come through. Try dragging {file} into the comment box below."
    )


def gh(*args, payload=None):
    result = subprocess.run(
        ["gh", "api", *args], input=payload, capture_output=True, text=True, check=True)
    return result.stdout


def main():
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as f:
        event = json.load(f)
    repo = os.environ["GITHUB_REPOSITORY"]
    issue = event["issue"]
    path = f"repos/{repo}/issues/{issue['number']}/comments"
    comments = [c for page in json.loads(gh("--paginate", "--slurp", path)) for c in page]
    kind = decide(issue, comments, event.get("comment"))
    if kind:
        gh("-X", "POST", path, "--input", "-",
           payload=json.dumps({"body": message(kind, issue.get("body") or "")}))
        print(f"posted {kind} note")
    else:
        print("nothing to post")


if __name__ == "__main__":
    main()

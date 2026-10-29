#!/usr/bin/env python3
"""The fleet pane: open pull requests and decisions waiting for the captain.

A terminal view any agent's firstmate session can sit beside, usually as a Herdr
pane. It lists every open pull request recorded in this home with its checks
and what keeps it from merging, and every decision waiting for the captain.
Every row is one line; Enter expands it and Enter collapses it. An expanded
decision shows its full title, its decision text, and the path of its report or
plan, wrapped to the pane. An expanded pull request leads with what keeps it
from merging (or that it is ready), the names of its failing and running checks
with each failing check's log link, and the keys for what is usually done next.

Answers are staged, then submitted together. On a decision held in this home's
backlog, y, a, and d stage an answer; on a pull request, m (offered only once
nothing keeps it from merging), f, and c stage a merge, a fix request, or a
close. A staged row is tagged with what it carries, the captain keeps moving
and staging, changes a staged answer by staging another or lets it go with u,
and s submits every staged answer after one y. The submission runs
bin/fm-decision.sh batch once in the background: every line is checked before
anything is recorded, and one note raises one Firstmate wake for the whole
batch. Answers passed on leave the list at once, and the list keeps the
selection on the same item when a read changes it. Staged answers live only in
this view until submitted: quitting asks for a second q and then lets them go,
and a staged row that stops being listed is let go with a notice. Opening a
pull request, a check log, or a document happens at once, because it changes
nothing. Merge, fix, and close only ask Firstmate, which merges through its
guarded merge path; the view itself never merges, fixes, or closes anything,
and everything else it does is read-only.

Usage:
  fm-fleet-pane.py [view]
      Run the live view in this terminal.
  fm-fleet-pane.py open [--session <name>] [--pane <pane-id>]
      Open the view in a new Herdr pane to the right of <pane-id> (default:
      HERDR_PANE_ID) in session <name> (default: HERDR_SESSION). A pane this
      command already opened there is reused rather than doubled.
  fm-fleet-pane.py render [--snapshot <file>] [--width <columns>]
                          [--expand <n>]... [--select <n>]
                          [--key <key>]... [--type <text>]...
      Read once and print one frame as plain text: the test and debugging entry
      point. --snapshot reads a saved `fm-fleet-snapshot.sh --json` instead of
      running it; --expand and --select name items by their 1-based position.
      --key presses one key (a character, or enter, space, esc, backspace, up,
      down, left, right) and --type types each character of <text>, in order,
      through the live view's own key handling; a submission they start is
      waited for before the next key.

Keys in the view:
  Up/Down or k/j    move between items
  Enter, Space      expand or collapse the selected item
  Right / Left      expand / collapse it
  y                 stage the recommendation as a decision's answer
  a                 type a decision's answer, Enter to stage it
  d                 stage dropping a decision
  m                 stage merging a pull request that is ready
  f                 stage asking for a pull request's fix, with an optional note
  c                 stage closing a pull request without merging
  u                 let go of the selected item's staged answer
  s                 submit every staged answer in one note (asks to confirm)
  o                 open the pull request, or a decision's report or plan
  g                 open a pull request's first failing check log
  r                 read again now
  q                 quit (asks again while answers are staged)

Reading: bin/fm-fleet-snapshot.sh owns the records. The view runs it with its
forge fallback off and its remote-summary cache pointed at a path that can
never be created, so a read writes nothing, once a minute and on `r`. GitHub is
asked in two batched `gh api graphql` queries - a lightweight state read for
every recorded pull request, then checks and branch rules for the open subset -
at most about once a minute unless the list of pull requests changed. A failed
read keeps the last rows on screen and says what could not be read.
Every command the view runs gets its own input, never the view's terminal, so
a read or a submission running beside the view never takes the captain's keys.

Opening runs the system opener (`open`, else `xdg-open`) on the path or link,
because a terminal such as macOS Terminal draws no clickable links.

Environment: FM_HOME selects the home (default: the code root); FM_HERDR_BIN
names the Herdr executable `open` runs (default: herdr).
"""

import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SNAPSHOT_SCRIPT = os.path.join(ROOT, "bin", "fm-fleet-snapshot.sh")
DECISION_SCRIPT = os.path.join(ROOT, "bin", "fm-decision.sh")
SNAPSHOT_ENV = {"FM_CREW_STATE_NO_FORGE": "1", "FM_SNAPSHOT_CACHE_DIR": "/dev/null/fleet-pane"}
SECONDMATE_MARKER = ".fm-secondmate-home"
REFRESH_SECONDS = 60
GITHUB_SECONDS = 50
PANE_NAME = "fleet-pane"
RECOMMENDED = "Go with the recommendation."
ANSWER_SOURCE = "the fleet pane"

PR_URL = re.compile(r"^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/(\d+)/?$")
GITHUB_PR = re.compile(r"https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/\d+")
CONTROLS = re.compile(r"[\s\x00-\x1f\x7f-\x9f]+")
HELD = re.compile(r"^captain hold ([A-Za-z0-9._-]+):")


# --- rows ------------------------------------------------------------------
# The row rules the retired Claude Code fleet-pane mod carried, unchanged in
# meaning: inventory and dedupe, labels, check counting and blockers.

def as_record(value):
    return value if isinstance(value, dict) else {}


def as_list(value):
    return value if isinstance(value, list) else []


def as_text(value):
    return value if isinstance(value, str) and value != "" else None


def short_line(text, limit=100):
    """Bounded one-line text: no prose newlines or terminal controls."""
    flat = CONTROLS.sub(" ", text).strip()
    if len(flat) <= limit:
        return flat
    if limit < 2:
        return "…" if limit > 0 else ""
    head = flat[: limit - 1]
    space = head.rfind(" ")
    return (head[:space] if space > len(head) / 2 else head).rstrip() + "…"


def full_text(text, limit=4000):
    """A decision's own words: line breaks kept, other controls dropped."""
    kept = text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", " ")
    kept = re.sub(r"[\x00-\x09\x0b-\x1f\x7f-\x9f]+", "", kept)
    kept = re.sub(r" *\n *", "\n", kept)
    kept = re.sub(r"\n{3,}", "\n\n", kept).strip()
    return kept if len(kept) <= limit else kept[: limit - 1].rstrip() + "…"


def human_title(key):
    return re.sub(r"[-_]+", " ", key)


def parse_pr_url(url):
    match = PR_URL.match(url.strip())
    if match is None:
        return None
    return {"owner": match.group(1), "repo": match.group(2), "number": int(match.group(3))}


def report_in(text):
    match = re.search(r"(?:^|[\s(])((?:/[^\s,;()]+/)?data/[^\s,;()]+\.md)", text)
    return match.group(1) if match else None


def detail_in(text):
    found = report_in(text)
    if found is not None:
        return found
    match = re.search(r"https?://[^\s<>]+", text)
    return re.sub(r"[.,;)]+$", "", match.group(0)) if match else None


def parse_snapshot(text):
    """PR refs and decision rows from a fm-fleet-snapshot.v1 document, or None."""
    try:
        snapshot = as_record(json.loads(text))
    except ValueError:
        return None
    if snapshot.get("schema") != "fm-fleet-snapshot.v1":
        return None
    prs, decisions, seen_prs, seen_decisions, mates = [], [], {}, {}, {}

    def add_pr(task, candidate, waits, title=None):
        parsed = parse_pr_url(candidate) if isinstance(candidate, str) else None
        if parsed is None:
            return
        url = "https://github.com/%s/%s/pull/%d" % (parsed["owner"], parsed["repo"], parsed["number"])
        waits_on = [one for one in as_list(waits) if isinstance(one, str)]
        existing = seen_prs.get(url.lower())
        if existing is not None:
            existing["waits_on"] = list(dict.fromkeys(existing["waits_on"] + waits_on))
            return
        ref = dict(task=task, url=url, waits_on=waits_on, **parsed)
        if as_text(title) is not None:
            ref["title"] = short_line(title)
        seen_prs[url.lower()] = ref
        prs.append(ref)

    def add_decision(scope, ident, key, title, report, words, task=None):
        identity = "%s/%s/%s" % (scope, ident, key)
        existing = seen_decisions.get(identity)
        if existing is not None:
            if report is not None and (existing["report"] is None or existing["report"].endswith("/data/backlog.md")):
                existing["report"] = report
            if existing["detail"] == "":
                existing["detail"] = full_text(words)
            return
        row = {
            "id": identity,
            "label": short_line("%s · %s" % (scope, ident) if scope else ident),
            "summary": short_line(title),
            "title": CONTROLS.sub(" ", full_text(title, 500)),
            "detail": full_text(words),
            "report": report,
            # The backlog task bin/fm-decision.sh answers, when this home holds it.
            "task": task,
        }
        seen_decisions[identity] = row
        decisions.append(row)

    for entry in as_list(as_record(snapshot.get("secondmate_current")).get("records")):
        mate = as_record(entry)
        scope = as_text(mate.get("id"))
        if scope is None or as_record(mate.get("provenance")).get("selected") != "structured-home":
            continue
        mates[scope] = mate
        home = as_text(mate.get("home"))
        for item in as_list(mate.get("decisions_open")):
            decision = as_record(item)
            if decision.get("verb") not in ("needs-decision", "captain-hold"):
                continue
            ident = as_text(decision.get("id")) or scope
            key = as_text(decision.get("key")) or ident
            summary = as_text(decision.get("summary")) or ""
            title = as_text(decision.get("title")) or (summary or None if decision.get("source") == "backlog" else None) or human_title(ident)
            detail = as_text(decision.get("report_path")) or detail_in(as_text(decision.get("reason")) or "") or detail_in(summary)
            for url in GITHUB_PR.findall(summary):
                add_pr(ident, url, [])
            if detail is not None and detail.startswith("data/") and home is not None:
                report = "%s/%s" % (home, detail)
            elif detail is not None:
                report = detail
            elif home is None:
                report = None
            elif decision.get("source") == "status":
                report = "%s/state/%s.status" % (home, ident)
            else:
                report = "%s/data/backlog.md" % home
            words = as_text(decision.get("reason")) or ("" if decision.get("source") == "backlog" else summary)
            add_decision(scope, ident, "hold" if decision.get("verb") == "captain-hold" else key, title, report, words)

    for entry in as_list(snapshot.get("tasks")):
        task = as_record(entry)
        ident = as_text(task.get("id"))
        if ident is None:
            continue
        backlog = as_record(task.get("backlog"))
        pr = as_record(task.get("pr"))
        for url in [pr.get("url")] + as_list(pr.get("urls")):
            add_pr(ident, url, backlog.get("unresolved_blocker_ids"), backlog.get("title"))
        paths = as_record(task.get("paths"))
        report = as_record(paths.get("report"))
        own_report = as_text(report.get("path")) if report.get("present") is True else None
        for item in as_list(as_record(task.get("hints")).get("open_decisions")):
            decision = as_record(item)
            if decision.get("verb") != "needs-decision":
                continue
            summary = as_text(decision.get("summary")) or ""
            held = HELD.match(summary.strip())
            key = as_text(decision.get("key")) or "default"
            detail = detail_in(summary) or own_report or as_text(as_record(paths.get("status_log")).get("path"))
            home = as_text(as_record(mates.get(ident)).get("home"))
            if home is None and task.get("kind") == "secondmate":
                home = as_text(as_record(paths.get("home")).get("path"))
            resolved = "%s/%s" % (home, detail) if detail is not None and detail.startswith("data/") and home is not None else detail
            words = HELD.sub("", summary.strip()).strip()
            if held is not None:
                add_decision(ident, held.group(1), "hold", human_title(held.group(1)), resolved, words)
            else:
                title = as_text(decision.get("title")) or ((as_text(backlog.get("title")) or ident) if key == "default" else human_title(key))
                add_decision("", ident, key, title, resolved, words)

    backlog = as_record(snapshot.get("backlog"))
    for entry in as_list(backlog.get("records")):
        record = as_record(entry)
        ident = as_text(record.get("id")) or "backlog"
        for url in [record.get("pr_url")] + as_list(record.get("links")):
            add_pr(ident, url, record.get("unresolved_blocker_ids"), record.get("title"))
        if record.get("captain_actionable") is not True:
            continue
        reason = as_text(record.get("hold_reason")) or ""
        report = as_text(record.get("report_path")) or detail_in(reason) or as_text(backlog.get("path"))
        add_decision("", ident, "hold", as_text(record.get("title")) or human_title(ident), report, reason,
                     task=as_text(record.get("id")))
    return {"prs": prs, "decisions": decisions}


def pr_state_query(refs):
    parts = ["p%d: repository(owner:%s, name:%s) { pullRequest(number:%d) { title state } }"
             % (i, json.dumps(ref["owner"]), json.dumps(ref["repo"]), ref["number"]) for i, ref in enumerate(refs)]
    return "query { %s }" % " ".join(parts)


def pr_query(refs):
    def fields(n):
        return ("title state isDraft mergeable mergeStateStatus reviewDecision baseRef{branchProtectionRule{requiredStatusCheckContexts} "
                "rules(first:100){nodes{type parameters{... on RequiredStatusChecksParameters{requiredStatusChecks{context}}}}}} "
                "commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename "
                "... on CheckRun{name status conclusion detailsUrl isRequired(pullRequestNumber:%d)} "
                "... on StatusContext{context state targetUrl isRequired(pullRequestNumber:%d)}}}}}}}" % (n, n))
    parts = ["p%d: repository(owner:%s, name:%s) { pullRequest(number:%d) { %s } }"
             % (i, json.dumps(ref["owner"]), json.dumps(ref["repo"]), ref["number"], fields(ref["number"])) for i, ref in enumerate(refs)]
    return "query { %s }" % " ".join(parts)


FAILED = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"}
RUNNING = {"QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED", "EXPECTED"}


def required_contexts(base_ref, failed):
    """Check names the base branch requires, or None when GitHub did not say."""
    if failed or not isinstance(base_ref, dict):
        return None
    rules = as_record(base_ref.get("rules")).get("nodes")
    if not isinstance(rules, list):
        return None
    names = set()
    for node in rules:
        rule = as_record(node)
        if rule.get("type") != "REQUIRED_STATUS_CHECKS":
            continue
        for one in as_list(as_record(rule.get("parameters")).get("requiredStatusChecks")):
            context = as_text(as_record(one).get("context"))
            if context is not None:
                names.add(context)
    for one in as_list(as_record(base_ref.get("branchProtectionRule")).get("requiredStatusCheckContexts")):
        if isinstance(one, str) and one:
            names.add(one)
    return names


def parse_pr_statuses(text, refs):
    """GitHub's answer by pull request URL; an alias it could not answer is left out."""
    try:
        raw = as_record(json.loads(text))
    except ValueError:
        return {}
    data = as_record(raw.get("data"))
    rules_failed = set()
    for error in as_list(raw.get("errors")):
        path = as_list(as_record(error).get("path"))
        if "baseRef" in path and path:
            rules_failed.add(path[0])
    found = {}
    for i, ref in enumerate(refs):
        pr = as_record(as_record(data.get("p%d" % i)).get("pullRequest"))
        state = as_text(pr.get("state"))
        if state is None:
            continue
        named = required_contexts(pr.get("baseRef"), "p%d" % i in rules_failed)
        unreported = set(named or ())
        checks = dict(passing=0, failing=0, running=0, failing_required=0, running_required=0, missing_required=0, required="none",
                      failed=[], ran=[])
        nodes = as_list(as_record(pr.get("commits")).get("nodes"))
        commit = as_record(as_record(nodes[0] if nodes else None).get("commit"))
        for node in as_list(as_record(as_record(commit.get("statusCheckRollup")).get("contexts")).get("nodes")):
            check = as_record(node)
            is_status = check.get("__typename") == "StatusContext"
            name = as_text(check.get("context") if is_status else check.get("name"))
            if name is not None:
                unreported.discard(name)
            is_required = check.get("isRequired") is True or (name is not None and named is not None and name in named)
            if is_required:
                checks["required"] = "some"
            if is_status:
                word = as_text(check.get("state")) or ""
            else:
                word = as_text(check.get("conclusion") if check.get("status") == "COMPLETED" else check.get("status")) or ""
            link = as_text(check.get("targetUrl") if is_status else check.get("detailsUrl"))
            link = link if link is not None and link.startswith("https://") else None
            if word in FAILED:
                checks["failing"] += 1
                checks["failing_required"] += 1 if is_required else 0
                checks["failed"].append({"name": short_line(name or "a check", 60), "url": link, "required": is_required})
            elif word in RUNNING:
                checks["running"] += 1
                checks["running_required"] += 1 if is_required else 0
                checks["ran"].append(short_line(name or "a check", 60))
            else:
                checks["passing"] += 1
        if named is None:
            checks["required"] = "unknown"
        elif named:
            checks["required"] = "some"
        checks["missing_required"] = len(unreported)
        found[ref["url"]] = {
            "title": as_text(pr.get("title")) or "",
            "state": state,
            "is_draft": pr.get("isDraft") is True,
            "mergeable": as_text(pr.get("mergeable")) or "UNKNOWN",
            "merge_state": as_text(pr.get("mergeStateStatus")) or "UNKNOWN",
            "review_decision": as_text(pr.get("reviewDecision")),
            "checks": checks,
        }
    return found


def check_summary(status):
    checks = status["checks"]
    if checks["passing"] + checks["failing"] + checks["running"] == 0:
        return "no checks reported"
    parts = []
    if checks["failing"]:
        parts.append("%d failing" % checks["failing"])
    if checks["running"]:
        parts.append("%d running" % checks["running"])
    return ", ".join(parts) if parts else "passing"


def blockers_of(status, waits_on=()):
    """What keeps a pull request from merging, most basic first."""
    found, checks = [], status["checks"]
    only_required = checks["required"] == "some"
    failing = checks["failing_required"] if only_required else checks["failing"]
    running = checks["running_required"] if only_required else checks["running"]
    missing = checks["missing_required"] if only_required else 0
    if status["is_draft"]:
        found.append("still a draft")
    if status["mergeable"] == "CONFLICTING":
        found.append("merge conflict")
    if failing:
        found.append("a failing check" if failing == 1 else "%d failing checks" % failing)
    if running:
        found.append("checks still running")
    if missing:
        found.append("a required check not reported yet" if missing == 1 else "%d required checks not reported yet" % missing)
    if status["review_decision"] == "CHANGES_REQUESTED":
        found.append("changes requested in review")
    if status["review_decision"] == "REVIEW_REQUIRED":
        found.append("needs an approving review")
    if status["merge_state"] == "BEHIND":
        found.append("behind its base branch")
    if waits_on:
        found.append("waits on %s" % ", ".join(waits_on))
    if not found and status["merge_state"] == "BLOCKED":
        found.append("GitHub reports it blocked")
    if not found:
        found.append("ready - waiting for your word to merge")
    return found


def pr_row(ref, status):
    """A pull request's row, or None once it merged or closed."""
    if status is None:
        title = ref.get("title") or ref["task"]
        return {"url": ref["url"], "project": ref["repo"], "title": short_line(title), "full_title": full_text(title, 500),
                "checks": "status unknown", "blockers": ["GitHub did not answer"], "ready": False, "failed": [], "running": []}
    if status["state"] != "OPEN":
        return None
    title = status["title"] or ref.get("title") or ref["task"]
    blockers = blockers_of(status, ref["waits_on"])
    return {"url": ref["url"], "project": ref["repo"], "title": short_line(title), "full_title": CONTROLS.sub(" ", full_text(title, 500)),
            "checks": check_summary(status), "blockers": blockers, "ready": blockers[0].startswith("ready"),
            "failed": status["checks"]["failed"], "running": status["checks"]["ran"]}


def is_github_due(refs, asked, now):
    if not refs:
        return False
    if asked is None:
        return True
    return asked["urls"] != " ".join(ref["url"] for ref in refs) or now - asked["at"] >= GITHUB_SECONDS


# --- reading ---------------------------------------------------------------

class Reader:
    """The snapshot and GitHub reads, and the rows last read."""

    def __init__(self, home, snapshot_file=None):
        self.home = home
        self.snapshot_file = snapshot_file
        self.asked = None
        self.statuses = {}
        self.prs, self.decisions = [], []
        self.at = None
        self.problem = None
        self.lock = threading.Lock()
        self.version = 0

    def _snapshot(self):
        if self.snapshot_file is not None:
            with open(self.snapshot_file, encoding="utf-8") as handle:
                return handle.read()
        env = dict(os.environ, FM_HOME=self.home, **SNAPSHOT_ENV)
        ran = subprocess.run([SNAPSHOT_SCRIPT, "--json"], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90, check=False)
        return ran.stdout

    def _ask_github(self, refs, now):
        if not is_github_due(refs, self.asked, now):
            return None
        query = ["gh", "api", "graphql", "-f"]
        ran = subprocess.run(query + ["query=" + pr_state_query(refs)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20, check=False)
        known = parse_pr_statuses(ran.stdout, refs)
        open_refs = [ref for ref in refs if known.get(ref["url"], {}).get("state") == "OPEN"]
        closed = {url: status for url, status in known.items() if status["state"] != "OPEN"}
        found = {}
        if open_refs:
            ran = subprocess.run(query + ["query=" + pr_query(open_refs)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20, check=False)
            found = parse_pr_statuses(ran.stdout, open_refs)
        self.asked = {"urls": " ".join(ref["url"] for ref in refs), "at": now}
        self.statuses = dict(closed, **found)
        return "Some GitHub statuses could not be read just now." if len(self.statuses) < len(refs) else None

    def refresh(self):
        try:
            parsed = parse_snapshot(self._snapshot())
        except (OSError, subprocess.SubprocessError):
            parsed = None
        now = time.time()
        if parsed is None:
            with self.lock:
                self.problem = "The task records could not be read just now."
                self.version += 1
            return
        try:
            problem = self._ask_github(parsed["prs"], now)
        except (OSError, subprocess.SubprocessError):
            problem = "GitHub could not be read just now."
        rows = [row for row in (pr_row(ref, self.statuses.get(ref["url"])) for ref in parsed["prs"]) if row is not None]
        with self.lock:
            self.prs, self.decisions, self.at, self.problem = rows, parsed["decisions"], now, problem
            self.version += 1


# --- drawing ---------------------------------------------------------------

def key_of(kind, item):
    """An item's identity across reads: a pull request's URL or a decision's id."""
    return item["url"] if kind == "pr" else item["id"]


def items_of(reader, ui=None):
    """The listed items, without decisions already passed on from this view."""
    sent = ui["sent"] if ui is not None else {}
    return [("pr", pr) for pr in reader.prs] + [("decision", one) for one in reader.decisions if one["id"] not in sent]


def document_target(report, home):
    return "%s/%s" % (home, report) if report.startswith("data/") else report


STAGED_TAG = {"resolve": "answer", "drop": "drop", "merge": "merge", "fix": "fix", "close": "close"}


def staged_words(entry):
    verb, answer = entry["verb"], entry["answer"]
    if verb == "resolve":
        return "take the recommendation" if answer == RECOMMENDED else 'answer "%s"' % answer
    if verb == "fix":
        return "ask for a fix" + (' - "%s"' % answer if answer else "")
    return {"drop": "drop it", "merge": "merge it", "close": "close it without merging"}[verb]


def frame(reader, ui, width):
    """The view's lines, each (text, style, item index or None), never wider than width."""
    body, foot = frame_parts(reader, ui, width)
    return body + foot


def frame_parts(reader, ui, width):
    """The scrolling list and the prompt, notice, and footer lines pinned under it."""
    width = max(width, 20)
    lines = []

    def add(text, style="text", index=None, prefix=""):
        lines.append((prefix + short_line(text, width - len(prefix)), style, index))

    def wrap(text, style="text", indent=4):
        for paragraph in text.split("\n"):
            chunks = textwrap.wrap(paragraph, max(10, width - indent), break_long_words=True, break_on_hyphens=False) or [""]
            for chunk in chunks:
                lines.append((" " * indent + chunk, style, None))

    if reader.at is None:
        add(reader.problem or "Reading pull requests and decisions...")
        return lines, []
    items = items_of(reader, ui)
    decisions = [item for kind, item in items if kind == "decision"]
    add("Open pull requests (%d)" % len(reader.prs), "head")
    if not reader.prs:
        add("None open.", prefix="  ")
    for index, (kind, item) in enumerate(items):
        if kind == "decision" and index == len(reader.prs):
            add("Decisions waiting for you (%d)" % len(decisions), "head")
        key = key_of(kind, item)
        is_open = key in ui["open"]
        staged, sending, sent = ui["staged"].get(key), ui["inflight"].get(key), ui["sent"].get(key)
        tag = ("[%s] " % STAGED_TAG[staged["verb"]] if staged else "[sending] " if sending else
               "[%s sent] " % sent if sent else "")
        marker = ("> " if ui["selected"] == index else "  ") + ("▾ " if is_open else "▸ ")
        if kind == "pr":
            style = "ready" if item["ready"] else "wait"
            add("%s%s: %s · %s · %s" % (tag, item["project"], item["title"], item["checks"], "; ".join(item["blockers"])),
                style, index, marker)
        else:
            add("%s%s: %s" % (tag, item["label"], item["summary"]), "decision", index, marker)
        if not is_open:
            continue
        if kind == "pr":
            wrap(item["full_title"], "title")
            if item["ready"]:
                wrap("Ready - waiting for your word to merge.", "ready")
            else:
                wrap("Keeps it from merging: %s." % "; ".join(item["blockers"]), "wait")
            if item["failed"]:
                wrap("Failing: %s" % ", ".join(one["name"] + (" (required)" if one["required"] else "") for one in item["failed"]))
                for one in item["failed"]:
                    if one["url"] is not None:
                        wrap("Log of %s:\n%s" % (one["name"], one["url"]), "path")
            if item["running"]:
                wrap("Running: %s" % ", ".join(item["running"]))
            wrap(item["url"], "path")
            keys = ["o open it in the browser"]
            if any(one["url"] is not None for one in item["failed"]):
                keys.append("g open the failing check's log")
            keys.append("m merge" if item["ready"] else "f ask for a fix")
            keys.append("c close")
        else:
            wrap(item["title"], "title")
            wrap(item["detail"] or "No decision text was recorded; ask Firstmate in chat.")
            if item["report"] is not None:
                wrap("Document:\n%s" % document_target(item["report"], reader.home), "path")
            if item["task"] is None:
                wrap("Answer this one in chat with Firstmate." + (" o opens the document." if item["report"] else ""), "keys")
                continue
            keys = ["y take the recommendation", "a type an answer", "d drop"]
            if item["report"]:
                keys.append("o open the document")
        if sending:
            wrap("Passing on: %s." % staged_words(sending), "wait")
            continue
        if staged:
            wrap("Staged: %s. u unstages; s submits everything staged." % staged_words(staged), "wait")
        wrap(" · ".join(keys), "keys")
    if not decisions:
        add("Decisions waiting for you (0)", "head")
        add("None.", prefix="  ")
    body, lines = lines, []
    if ui["typing"] is not None:
        ask = "A note for the fix, optional" if ui["typing"]["verb"] == "fix" else "Your answer"
        add("%s (Enter to stage, Esc to cancel): %s" % (ask, ui["typing"]["text"]), "wait")
    if ui["confirm"] is not None:
        count = len(ui["staged"])
        wrap("Submit %d staged answer%s to Firstmate in one note?  y yes · n no" % (count, "" if count == 1 else "s"),
             "wait", indent=2)
    if ui["inflight"]:
        wrap("Passing %d answer%s on..." % (len(ui["inflight"]), "" if len(ui["inflight"]) == 1 else "s"), "wait", indent=2)
    if ui["notice"] is not None:
        wrap(ui["notice"]["text"], "wait" if ui["notice"]["is_problem"] else "ready", indent=2)
    stamp = time.strftime("%H:%M", time.localtime(reader.at))
    submit = (" · s submits %d staged" % len(ui["staged"])) if ui["staged"] else ""
    add("Updated %s, every minute and on r. Enter expands%s · q quits." % (stamp, submit))
    if reader.problem is not None:
        add(reader.problem, "wait")
    return body, lines


def new_ui():
    return {"selected": 0, "key": None, "open": [], "confirm": None, "typing": None, "notice": None,
            "staged": {}, "inflight": {}, "sent": {}, "quit_warned": False}


# --- actions ---------------------------------------------------------------

def open_target(target):
    """Open a path or link with the system opener; True when it opened."""
    for opener in ("open", "xdg-open"):
        if shutil.which(opener) is None:
            continue
        try:
            return subprocess.run([opener, target], stdin=subprocess.DEVNULL, capture_output=True, timeout=15, check=False).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False
    return False


PAST = {"resolve": "resolved", "drop": "dropped", "merge": "merge", "fix": "fix", "close": "close"}


def batch_line(entry):
    """One line of bin/fm-decision.sh batch input for a staged entry."""
    answer = CONTROLS.sub(" ", entry["answer"]).strip()
    return " ".join(part for part in (entry["verb"], entry["target"], answer if entry["verb"] in ("resolve", "fix") else "") if part)


def pass_on(reader, entries):
    """Run bin/fm-decision.sh batch for the staged entries: (exit code, stdout, stderr)."""
    text = "".join(batch_line(entry) + "\n" for entry in entries)
    try:
        ran = subprocess.run([DECISION_SCRIPT, "batch", "--source", ANSWER_SOURCE], input=text,
                             env=dict(os.environ, FM_HOME=reader.home), capture_output=True, text=True, timeout=300, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        return 2, "", "the answers could not be passed on (%s)" % error
    return ran.returncode, ran.stdout, ran.stderr


class Controller:
    """The view's keys and staged answers, apart from curses so `render --key` drives the same paths."""

    def __init__(self, reader, on_refresh=lambda: None):
        self.reader = reader
        self.ui = new_ui()
        self.on_refresh = on_refresh
        self.worker = None
        self.result = None

    def items(self):
        return items_of(self.reader, self.ui)

    def selected(self):
        items = self.items()
        if not items or not 0 <= self.ui["selected"] < len(items):
            return None, None
        return items[self.ui["selected"]]

    def select(self, index):
        items = self.items()
        self.ui["selected"] = min(max(index, 0), max(len(items) - 1, 0))
        self.ui["key"] = key_of(*items[self.ui["selected"]]) if items else None

    def sync(self):
        """Keep the selection on the same item and drop stale staged answers after the list changed."""
        ui = self.ui
        listed = set(key_of(kind, item) for kind, item in items_of(self.reader))
        ui["sent"] = {key: verb for key, verb in ui["sent"].items() if key in listed}
        gone = [entry["label"] for key, entry in ui["staged"].items() if key not in listed]
        if gone:
            ui["staged"] = {key: entry for key, entry in ui["staged"].items() if key in listed}
            ui["notice"] = {"text": "No longer listed, so its staged answer was let go: %s." % ", ".join(gone), "is_problem": True}
        keys = [key_of(kind, item) for kind, item in self.items()]
        self.select(keys.index(ui["key"]) if ui["key"] in keys else ui["selected"])

    def stage(self, kind, row, verb, answer=""):
        key = key_of(kind, row)
        if key in self.ui["inflight"]:
            self.ui["notice"] = {"text": "That one is being passed on now.", "is_problem": True}
            return
        label = row["label"] if kind == "decision" else "%s: %s" % (row["project"], row["title"])
        self.ui["staged"][key] = {"verb": verb, "answer": answer, "label": label,
                                  "target": row["task"] if kind == "decision" else row["url"]}
        if key not in self.ui["open"]:
            self.ui["open"].append(key)

    def ask_submit(self):
        ui = self.ui
        if ui["inflight"]:
            ui["notice"] = {"text": "Wait for the answers being passed on, then submit again.", "is_problem": True}
            return
        if not ui["staged"]:
            ui["notice"] = {"text": "Nothing is staged; y, a, d, m, f, or c stage an answer first.", "is_problem": True}
            return
        rows = dict((key_of(kind, item), item) for kind, item in self.items())
        unready = [entry["label"] for key, entry in ui["staged"].items()
                   if entry["verb"] == "merge" and not rows.get(key, {}).get("ready")]
        if unready:
            ui["notice"] = {"text": "No longer ready to merge, so not submitted: %s. u unstages its merge." % ", ".join(unready),
                            "is_problem": True}
            return
        ui["confirm"] = {"count": len(ui["staged"])}

    def submit(self):
        entries = list(self.ui["staged"].items())
        self.ui["inflight"], self.ui["staged"] = dict(entries), {}

        def run():
            self.result = pass_on(self.reader, [entry for _key, entry in entries])

        self.worker = threading.Thread(target=run, daemon=True)
        self.worker.start()

    def poll(self):
        """Apply a finished submission; True when it changed what the view shows."""
        if self.worker is None or self.worker.is_alive():
            return False
        code, out, err = self.result
        self.worker = self.result = None
        ui = self.ui
        said = out.splitlines()
        passed = 0
        for key, entry in ui["inflight"].items():
            if any(line.startswith("%s: %s (" % (PAST[entry["verb"]], entry["target"])) for line in said):
                ui["sent"][key] = entry["verb"]
                passed += 1
                if key in ui["open"]:
                    ui["open"].remove(key)
            elif key not in ui["staged"]:
                ui["staged"][key] = entry
        ui["inflight"] = {}
        problems = [re.sub(r"^fm-decision: ", "", line) for line in err.splitlines() if line.strip()]
        if code == 0:
            text = "Passed %d answer%s on in one note; Firstmate is told." % (passed, "" if passed == 1 else "s")
        elif passed:
            text = "Passed %d on, but: %s" % (passed, "\n".join(problems) or "no answer")
        else:
            text = "Nothing was passed on; the answers stay staged.\n%s" % ("\n".join(problems) or "no answer")
        ui["notice"] = {"text": text, "is_problem": code != 0}
        self.sync()
        self.on_refresh()
        return True

    def act(self, key):
        """Handle one key: a printable character or a name such as enter, esc, up, down. False quits."""
        ui = self.ui
        ui["notice"] = None
        if ui["typing"] is not None:
            typing = ui["typing"]
            if key == "enter":
                ui["typing"] = None
                row = next((item for kind, item in self.items() if key_of(kind, item) == typing["id"]), None)
                text = typing["text"].strip()
                if row is not None and (text or typing["verb"] == "fix"):
                    self.stage(typing["kind"], row, typing["verb"], text)
            elif key == "esc":
                ui["typing"] = None
            elif key == "backspace":
                typing["text"] = typing["text"][:-1]
            elif len(key) == 1 and key.isprintable():
                typing["text"] = (typing["text"] + key)[:500]
            return True
        if ui["confirm"] is not None:
            ui["confirm"] = None
            if key in ("y", "Y"):
                self.submit()
            return True
        if key in ("q", "Q"):
            if (ui["staged"] or ui["inflight"]) and not ui["quit_warned"]:
                ui["quit_warned"] = True
                ui["notice"] = {"text": "Quitting lets go of %d staged answer%s, which Firstmate never sees. "
                                        "q again quits; s submits them." % (len(ui["staged"]), "" if len(ui["staged"]) == 1 else "s"),
                                "is_problem": True}
                return True
            return False
        ui["quit_warned"] = False
        kind, row = self.selected()
        if key in ("down", "j"):
            self.select(ui["selected"] + 1)
        elif key in ("up", "k"):
            self.select(ui["selected"] - 1)
        elif key in ("r", "R"):
            self.on_refresh()
        elif key == "s":
            self.ask_submit()
        elif row is None:
            pass
        elif key in ("enter", " ", "right", "left", "l", "h"):
            item = key_of(kind, row)
            is_open = item in ui["open"]
            if key in ("right", "l") or (not is_open and key not in ("left", "h")):
                if not is_open:
                    ui["open"].append(item)
            elif is_open:
                ui["open"].remove(item)
        elif key == "o":
            target = row.get("url") if kind == "pr" else (document_target(row["report"], self.reader.home) if row.get("report") else None)
            if target is not None and not open_target(target):
                ui["notice"] = {"text": "That would not open here; its path or link is shown above to copy.", "is_problem": True}
        elif key == "u":
            if ui["staged"].pop(key_of(kind, row), None) is not None:
                ui["notice"] = {"text": "Unstaged.", "is_problem": False}
        elif kind == "pr" and key == "g":
            log = next((one["url"] for one in row["failed"] if one["url"] is not None), None)
            if log is None:
                ui["notice"] = {"text": "No failing check with a log on this pull request.", "is_problem": True}
            elif not open_target(log):
                ui["notice"] = {"text": "That would not open here; the log's link is shown above to copy.", "is_problem": True}
        elif kind == "pr" and key == "m":
            if row["ready"]:
                self.stage(kind, row, "merge")
            else:
                ui["notice"] = {"text": "Merge is offered only once nothing keeps it from merging.", "is_problem": True}
        elif kind == "pr" and key == "f":
            ui["typing"] = {"id": row["url"], "kind": kind, "verb": "fix", "text": ""}
        elif kind == "pr" and key == "c":
            self.stage(kind, row, "close")
        elif kind == "decision" and row["task"] is not None:
            if key == "y":
                self.stage(kind, row, "resolve", RECOMMENDED)
            elif key == "d":
                self.stage(kind, row, "drop", "Drop this.")
            elif key == "a":
                ui["typing"] = {"id": row["id"], "kind": kind, "verb": "resolve", "text": ""}
        return True


# --- the live view ---------------------------------------------------------

def run_view(reader):
    import curses

    wake = threading.Event()
    control = Controller(reader, on_refresh=wake.set)
    ui = control.ui

    def reading():
        while True:
            reader.refresh()
            wake.wait(REFRESH_SECONDS)
            wake.clear()

    threading.Thread(target=reading, daemon=True).start()
    names = {curses.KEY_DOWN: "down", curses.KEY_UP: "up", curses.KEY_RIGHT: "right", curses.KEY_LEFT: "left",
             curses.KEY_ENTER: "enter", curses.KEY_BACKSPACE: "backspace", "\n": "enter", "\r": "enter",
             "\x1b": "esc", "\x7f": "backspace", "\b": "backspace"}

    def draw(screen):
        height, width = screen.getmaxyx()
        with reader.lock:
            body, foot = frame_parts(reader, ui, width - 1)
        foot = foot[-max(height - 1, 0):]
        room = max(height - len(foot), 1)
        styles = {
            "head": curses.A_BOLD, "ready": curses.color_pair(1), "wait": curses.color_pair(2),
            "decision": curses.color_pair(3), "path": curses.color_pair(3), "keys": curses.A_DIM,
        }
        chosen = next((i for i, line in enumerate(body) if line[2] == ui["selected"]), 0)
        top = 0 if chosen < room - 1 else chosen - room + 2
        screen.erase()
        shown = body[top: top + room]
        # The footer sits under a short list and stays pinned to the bottom under a long one.
        gap = room - len(shown) if len(body) > room else 0
        for y, (text, style, index) in enumerate(shown + [("", "text", None)] * gap + foot):
            attr = styles.get(style, curses.A_NORMAL)
            if index is not None and index == ui["selected"]:
                attr |= curses.A_REVERSE
            try:
                screen.addstr(y, 0, text[: width - 1], attr)
            except curses.error:
                pass
        screen.refresh()

    def main(screen):
        curses.curs_set(0)
        curses.use_default_colors()
        for pair, color in ((1, curses.COLOR_GREEN), (2, curses.COLOR_YELLOW), (3, curses.COLOR_CYAN)):
            curses.init_pair(pair, color, -1)
        screen.timeout(500)
        seen = -1
        while True:
            control.poll()
            if reader.version != seen:
                seen = reader.version
                with reader.lock:
                    control.sync()
            draw(screen)
            try:
                key = screen.get_wch()
            except curses.error:
                continue
            if key == curses.KEY_RESIZE:
                continue
            key = names.get(key, key)
            if isinstance(key, str) and not control.act(key):
                return

    os.environ.setdefault("ESCDELAY", "25")
    curses.wrapper(main)


# --- opening the pane in Herdr ---------------------------------------------

def herdr(argv, session):
    binary = os.environ.get("FM_HERDR_BIN") or "herdr"
    ran = subprocess.run([binary] + argv + ["--session", session], capture_output=True, text=True, timeout=30, check=False)
    if ran.returncode != 0:
        raise RuntimeError((ran.stderr or ran.stdout).strip() or "herdr %s failed" % argv[0])
    return ran.stdout


def open_pane(home, session, pane):
    """Open the view beside <pane>, or report the one already open in its tab."""
    listed = json.loads(herdr(["pane", "list"], session) or "{}")
    beside = as_record(json.loads(herdr(["pane", "get", pane], session) or "{}").get("result")).get("pane")
    tab = as_record(beside).get("tab_id")
    for one in as_list(as_record(listed.get("result")).get("panes")):
        one = as_record(one)
        if one.get("label") == PANE_NAME and (tab is None or one.get("tab_id") == tab):
            return "already open: pane %s" % one.get("pane_id")
    split = json.loads(herdr(["pane", "split", pane, "--direction", "right", "--ratio", "0.65",
                              "--cwd", home, "--no-focus"], session))
    new = as_record(as_record(split.get("result")).get("pane")).get("pane_id")
    if not isinstance(new, str):
        raise RuntimeError("herdr did not name the new pane")
    herdr(["pane", "rename", new, PANE_NAME], session)
    command = "FM_HOME=%s %s" % (shell_quote(home), shell_quote(os.path.abspath(__file__)))
    herdr(["pane", "run", new, command], session)
    return "opened: pane %s" % new


def shell_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


# --- entry -----------------------------------------------------------------

def main_home():
    home = os.environ.get("FM_HOME") or ROOT
    if not os.path.isdir(os.path.join(home, "state")):
        raise SystemExit("fm-fleet-pane: %s is not a Firstmate home (no state/)" % home)
    if os.path.exists(os.path.join(home, SECONDMATE_MARKER)):
        raise SystemExit("fm-fleet-pane: %s is a second mate's home; the fleet pane belongs to the main home" % home)
    return home


def option(args, name, default=None):
    values = [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == name]
    return values[-1] if values else default


def main(argv):
    command = argv[0] if argv else "view"
    args = argv[1:]
    if command in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    known = {"view": set(), "open": {"--session", "--pane"},
             "render": {"--snapshot", "--width", "--expand", "--select", "--key", "--type"}}
    if command not in known or any(arg.startswith("--") and arg not in known[command] for arg in args):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    home = main_home()
    if command == "open":
        session = option(args, "--session", os.environ.get("HERDR_SESSION"))
        pane = option(args, "--pane", os.environ.get("HERDR_PANE_ID"))
        if not session or not pane:
            print("fm-fleet-pane: run this in the firstmate session's Herdr pane, or pass --session and --pane", file=sys.stderr)
            return 2
        try:
            print(open_pane(home, session, pane))
        except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
            print("fm-fleet-pane: the pane could not be opened: %s" % error, file=sys.stderr)
            return 1
        return 0
    reader = Reader(home, option(args, "--snapshot"))
    if command == "render":
        reader.refresh()
        control = Controller(reader)
        ui = control.ui
        items = items_of(reader)
        control.select(int(option(args, "--select", "1")) - 1)
        for i, arg in enumerate(args[:-1]):
            value = args[i + 1]
            if arg == "--expand":
                position = int(value) - 1
                if 0 <= position < len(items):
                    ui["open"].append(key_of(*items[position]))
            elif arg in ("--key", "--type"):
                for key in ([value] if arg == "--key" else list(value)):
                    if not control.act(" " if key == "space" else key):
                        ui["notice"] = {"text": "(the view quit here)", "is_problem": False}
                    if control.worker is not None:
                        control.worker.join()
                        control.poll()
        if "--select" not in args and not any(arg in ("--key", "--type") for arg in args):
            ui["selected"] = -1
        for text, _style, _index in frame(reader, ui, int(option(args, "--width", "80"))):
            print(text)
        return 0
    run_view(reader)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

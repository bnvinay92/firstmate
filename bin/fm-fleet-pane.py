#!/usr/bin/env python3
"""The fleet pane: open pull requests and decisions waiting for the captain.

A terminal view any agent's firstmate session can sit beside, usually as a Herdr
pane. It lists every open pull request recorded in this home with its checks
and what keeps it from merging, and every decision waiting for the captain.
A decision is one line; Enter expands it to its full title, its decision text,
and the path of its report or plan, wrapped to the pane, and Enter collapses it.
From an expanded decision held in this home's backlog, the captain can resolve
or drop it; both run bin/fm-decision.sh, the one command that records the
answer and wakes Firstmate. Everything else the view does is read-only.

Usage:
  fm-fleet-pane.py [view]
      Run the live view in this terminal.
  fm-fleet-pane.py open [--session <name>] [--pane <pane-id>]
      Open the view in a new Herdr pane to the right of <pane-id> (default:
      HERDR_PANE_ID) in session <name> (default: HERDR_SESSION). A pane this
      command already opened there is reused rather than doubled.
  fm-fleet-pane.py render [--snapshot <file>] [--width <columns>]
                          [--expand <n>]... [--select <n>]
      Read once and print one frame as plain text: the test and debugging entry
      point. --snapshot reads a saved `fm-fleet-snapshot.sh --json` instead of
      running it; --expand and --select name items by their 1-based position.

Keys in the view:
  Up/Down or k/j    move between items
  Enter, Space      expand or collapse the selected decision
  Right / Left      expand / collapse it
  y                 resolve it with the recommendation (asks to confirm)
  a                 type an answer, Enter to review it (asks to confirm)
  d                 drop it (asks to confirm)
  o                 open its report or plan, or the pull request, on this machine
  r                 read again now
  q                 quit

Reading: bin/fm-fleet-snapshot.sh owns the records. The view runs it with its
forge fallback off and its remote-summary cache pointed at a path that can
never be created, so a read writes nothing, once a minute and on `r`. GitHub is
asked in two batched `gh api graphql` queries - a lightweight state read for
every recorded pull request, then checks and branch rules for the open subset -
at most about once a minute unless the list of pull requests changed. A failed
read keeps the last rows on screen and says what could not be read.

Opening a document runs the system opener (`open`, else `xdg-open`) on the path
or link, because a terminal such as macOS Terminal draws no clickable links.

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
                "... on CheckRun{name status conclusion isRequired(pullRequestNumber:%d)} "
                "... on StatusContext{context state isRequired(pullRequestNumber:%d)}}}}}}}" % (n, n))
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
        checks = dict(passing=0, failing=0, running=0, failing_required=0, running_required=0, missing_required=0, required="none")
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
            if word in FAILED:
                checks["failing"] += 1
                checks["failing_required"] += 1 if is_required else 0
            elif word in RUNNING:
                checks["running"] += 1
                checks["running_required"] += 1 if is_required else 0
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
        return {"url": ref["url"], "project": ref["repo"], "title": short_line(ref.get("title") or ref["task"]),
                "checks": "status unknown", "blockers": ["GitHub did not answer"]}
    if status["state"] != "OPEN":
        return None
    return {"url": ref["url"], "project": ref["repo"], "title": short_line(status["title"] or ref.get("title") or ref["task"]),
            "checks": check_summary(status), "blockers": blockers_of(status, ref["waits_on"])}


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
        ran = subprocess.run([SNAPSHOT_SCRIPT, "--json"], env=env, capture_output=True, text=True, timeout=90, check=False)
        return ran.stdout

    def _ask_github(self, refs, now):
        if not is_github_due(refs, self.asked, now):
            return None
        query = ["gh", "api", "graphql", "-f"]
        ran = subprocess.run(query + ["query=" + pr_state_query(refs)], capture_output=True, text=True, timeout=20, check=False)
        known = parse_pr_statuses(ran.stdout, refs)
        open_refs = [ref for ref in refs if known.get(ref["url"], {}).get("state") == "OPEN"]
        closed = {url: status for url, status in known.items() if status["state"] != "OPEN"}
        found = {}
        if open_refs:
            ran = subprocess.run(query + ["query=" + pr_query(open_refs)], capture_output=True, text=True, timeout=20, check=False)
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

def items_of(reader):
    return [("pr", pr) for pr in reader.prs] + [("decision", one) for one in reader.decisions]


def document_target(report, home):
    return "%s/%s" % (home, report) if report.startswith("data/") else report


def frame(reader, ui, width):
    """The view's lines, each (text, style, item index or None), never wider than width."""
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
        return lines
    items = items_of(reader)
    add("Open pull requests (%d)" % len(reader.prs), "head")
    if not reader.prs:
        add("None open.", prefix="  ")
    add_index = 0
    for kind, item in items:
        if kind == "decision" and add_index == len(reader.prs):
            add("Decisions waiting for you (%d)" % len(reader.decisions), "head")
        index = add_index
        add_index += 1
        marker = "> " if ui["selected"] == index else "  "
        if kind == "pr":
            style = "ready" if item["blockers"][0].startswith("ready") else "wait"
            add("%s: %s · %s · %s" % (item["project"], item["title"], item["checks"], "; ".join(item["blockers"])), style, index, marker)
            continue
        is_open = item["id"] in ui["open"]
        add("%s: %s" % (item["label"], item["summary"]), "decision", index, marker + ("▾ " if is_open else "▸ "))
        if not is_open:
            continue
        wrap(item["title"], "title")
        wrap(item["detail"] or "No decision text was recorded; ask Firstmate in chat.")
        if item["report"] is not None:
            wrap("Document:\n%s" % document_target(item["report"], reader.home), "path")
        confirm = ui["confirm"]
        if confirm is not None and confirm["id"] == item["id"]:
            ask = ("Drop %s? Firstmate will close it." % item["label"]) if confirm["verb"] == "drop" else \
                ('Send "%s" as your answer to %s?' % (confirm["answer"], item["label"]))
            wrap(ask + "  y yes · n no", "wait")
        elif ui["busy"] == item["id"]:
            wrap("Passing your answer on...", "wait")
        elif item["task"] is not None:
            wrap("y take the recommendation · a type an answer · d drop" + (" · o open the document" if item["report"] else ""), "keys")
        else:
            wrap("Answer this one in chat with Firstmate." + (" o opens the document." if item["report"] else ""), "keys")
    if not reader.decisions:
        add("Decisions waiting for you (0)", "head")
        add("None.", prefix="  ")
    if ui["typing"] is not None:
        add("Your answer (Enter to review, Esc to cancel): " + ui["typing"]["text"], "wait")
    if ui["notice"] is not None:
        wrap(ui["notice"]["text"], "wait" if ui["notice"]["is_problem"] else "ready", indent=2)
    stamp = time.strftime("%H:%M", time.localtime(reader.at))
    add("Updated %s, every minute and on r. Enter expands, q quits." % stamp)
    if reader.problem is not None:
        add(reader.problem, "wait")
    return lines


def new_ui():
    return {"selected": 0, "open": [], "confirm": None, "busy": None, "typing": None, "notice": None}


# --- actions ---------------------------------------------------------------

def open_target(target):
    """Open a path or link with the system opener; True when it opened."""
    for opener in ("open", "xdg-open"):
        if shutil.which(opener) is None:
            continue
        try:
            return subprocess.run([opener, target], capture_output=True, timeout=15, check=False).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False
    return False


def pass_on(reader, row, verb, answer):
    """Run bin/fm-decision.sh for one confirmed choice; the outcome line it printed."""
    argv = [DECISION_SCRIPT, verb, "--source", ANSWER_SOURCE, row["task"]]
    if verb == "resolve":
        argv.append("-")
    try:
        ran = subprocess.run(argv, input=answer if verb == "resolve" else None, env=dict(os.environ, FM_HOME=reader.home),
                             capture_output=True, text=True, timeout=120, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        return {"text": "%s: the answer could not be passed on (%s)." % (row["label"], error), "is_problem": True}
    said = (ran.stdout.strip() or ran.stderr.strip() or "no answer").splitlines()[-1]
    said = re.sub(r"^fm-decision: ", "", said)
    return {"text": "%s: %s" % (row["label"], said), "is_problem": ran.returncode != 0}


# --- the live view ---------------------------------------------------------

def run_view(reader):
    import curses

    ui = new_ui()
    wake = threading.Event()

    def reading():
        while True:
            reader.refresh()
            wake.wait(REFRESH_SECONDS)
            wake.clear()

    threading.Thread(target=reading, daemon=True).start()

    def selected_row():
        items = items_of(reader)
        if not items or ui["selected"] >= len(items):
            return None, None
        return items[ui["selected"]]

    def act(screen, key):
        kind, row = selected_row()
        if ui["typing"] is not None:
            if key in ("\n", "\r", curses.KEY_ENTER):
                text = ui["typing"]["text"].strip()
                target = ui["typing"]["id"]
                ui["typing"] = None
                if text:
                    ui["confirm"] = {"id": target, "verb": "resolve", "answer": text}
            elif key == "\x1b":
                ui["typing"] = None
            elif key in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                ui["typing"]["text"] = ui["typing"]["text"][:-1]
            elif isinstance(key, str) and key.isprintable():
                ui["typing"]["text"] = (ui["typing"]["text"] + key)[:500]
            return True
        if ui["confirm"] is not None:
            confirm, ui["confirm"] = ui["confirm"], None
            if key in ("y", "Y"):
                target = next((one for one in reader.decisions if one["id"] == confirm["id"]), None)
                if target is not None and target["task"] is not None:
                    ui["busy"] = target["id"]
                    draw(screen)
                    ui["notice"] = pass_on(reader, target, confirm["verb"], confirm["answer"])
                    ui["busy"] = None
                    wake.set()
            return True
        if key in ("q", "Q"):
            return False
        count = len(items_of(reader))
        if key in (curses.KEY_DOWN, "j"):
            ui["selected"] = min(max(count - 1, 0), ui["selected"] + 1)
        elif key in (curses.KEY_UP, "k"):
            ui["selected"] = max(0, ui["selected"] - 1)
        elif key in ("r", "R"):
            wake.set()
        elif kind == "decision" and key in ("\n", "\r", " ", curses.KEY_ENTER, curses.KEY_RIGHT, curses.KEY_LEFT, "l", "h"):
            is_open = row["id"] in ui["open"]
            if key in (curses.KEY_RIGHT, "l") or (not is_open and key not in (curses.KEY_LEFT, "h")):
                if not is_open:
                    ui["open"].append(row["id"])
            elif is_open:
                ui["open"].remove(row["id"])
        elif key == "o" and row is not None:
            target = row.get("url") if kind == "pr" else (document_target(row["report"], reader.home) if row.get("report") else None)
            if target is not None and not open_target(target):
                ui["notice"] = {"text": "That would not open here; its path or link is shown above to copy.", "is_problem": True}
        elif kind == "decision" and row["task"] is not None and row["id"] in ui["open"]:
            if key == "y":
                ui["confirm"] = {"id": row["id"], "verb": "resolve", "answer": RECOMMENDED}
            elif key == "d":
                ui["confirm"] = {"id": row["id"], "verb": "drop", "answer": "Drop this."}
            elif key == "a":
                ui["typing"] = {"id": row["id"], "text": ""}
        return True

    def draw(screen):
        height, width = screen.getmaxyx()
        with reader.lock:
            lines = frame(reader, ui, width - 1)
        styles = {
            "head": curses.A_BOLD, "ready": curses.color_pair(1), "wait": curses.color_pair(2),
            "decision": curses.color_pair(3), "path": curses.color_pair(3), "keys": curses.A_DIM,
        }
        chosen = next((i for i, line in enumerate(lines) if line[2] == ui["selected"]), 0)
        top = 0 if chosen < height - 1 else chosen - height + 2
        screen.erase()
        for y, (text, style, index) in enumerate(lines[top: top + height]):
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
            if reader.version != seen:
                seen = reader.version
                ui["selected"] = min(ui["selected"], max(len(items_of(reader)) - 1, 0))
            draw(screen)
            try:
                key = screen.get_wch()
            except curses.error:
                continue
            if key == curses.KEY_RESIZE:
                continue
            if not act(screen, key):
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
    known = {"view": set(), "open": {"--session", "--pane"}, "render": {"--snapshot", "--width", "--expand", "--select"}}
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
        ui = new_ui()
        items = items_of(reader)
        for i, arg in enumerate(args[:-1]):
            if arg == "--expand":
                position = int(args[i + 1]) - 1
                if 0 <= position < len(items) and items[position][0] == "decision":
                    ui["open"].append(items[position][1]["id"])
        ui["selected"] = int(option(args, "--select", "0")) - 1
        for text, _style, _index in frame(reader, ui, int(option(args, "--width", "80"))):
            print(text)
        return 0
    run_view(reader)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

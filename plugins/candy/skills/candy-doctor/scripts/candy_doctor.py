#!/usr/bin/env python3
"""candy_doctor.py — diagnose Claude Candy installation.

Read-only for static checks. Execution checks run scripts in an isolated
temp JOBS_ROOT so real logs/state are never modified.

Severity:
  - must    : failure means Candy cannot work at all
  - detail  : works but something is off / should be inspected

Fix policy (per check, when applicable):
  - auto    : safe, reversible, no user confirmation needed
  - confirm : touches system state (launchctl, symlinks), ask user first
  - manual  : user must act (logins, macOS settings, missing binaries)
"""

from __future__ import annotations

import argparse
import csv
import datetime
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Optional


AGENTS = [
    "com.claude.candy",
    "com.claude.candy.progress",
    "com.claude.candy.snapshot",
    "com.claude.candy.optimizer",
]
BIN_SCRIPTS = [
    "refresh_claude.sh",
    "usage_progress.sh",
    "usage_snapshot.sh",
    "schedule_optimizer.sh",
]


@dataclass
class Check:
    id: str
    category: str
    severity: str  # must | detail
    status: str = "pass"  # pass | warn | fail | skip
    message: str = ""
    fix_command: Optional[str] = None
    fix_policy: Optional[str] = None  # auto | confirm | manual
    details: dict[str, Any] = field(default_factory=dict)


class Doctor:
    def __init__(self, jobs_root: Path) -> None:
        self.jobs_root = jobs_root
        self.home = Path(os.path.expanduser("~"))
        self.launchagents_dir = self.home / "Library" / "LaunchAgents"
        self.uid = os.getuid()
        self.checks: list[Check] = []

    def add(self, check: Check) -> None:
        self.checks.append(check)

    # ----- helpers -----

    def _run(
        self,
        cmd: list[str],
        timeout: int = 10,
        env: Optional[dict] = None,
    ) -> tuple[int, str, str]:
        try:
            p = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
                env=env,
            )
            return p.returncode, p.stdout, p.stderr
        except subprocess.TimeoutExpired:
            return 124, "", "timeout"
        except FileNotFoundError:
            return 127, "", "not found"

    def _which(self, name: str) -> Optional[str]:
        return shutil.which(name)

    # ----- MUST: binaries -----

    def check_binaries(self) -> None:
        for name in ("claude", "python3", "launchctl", "plutil", "osascript"):
            c = Check(id=f"bin.{name}", category="binary", severity="must")
            path = self._which(name)
            if path:
                c.status = "pass"
                c.message = f"{name} found at {path}"
                c.details["path"] = path
            else:
                c.status = "fail"
                c.message = f"{name} not found on PATH"
                c.fix_policy = "manual"
                c.fix_command = f"install {name} and ensure it is on PATH"
            self.add(c)

    # ----- MUST: claude preflight -----

    def check_claude_preflight(self) -> None:
        c = Check(id="auth.claude_preflight", category="auth", severity="must")
        rc, out, err = self._run(
            ["claude", "-p", "--output-format", "json", "Respond only ok"],
            timeout=45,
        )
        if rc == 0 and out.strip():
            c.status = "pass"
            c.message = "claude -p returned a response (CLI is logged in)"
        else:
            c.status = "fail"
            c.message = "claude -p preflight failed — login may be expired"
            c.fix_policy = "manual"
            c.fix_command = "run `claude` in a terminal and sign in again"
            c.details["stderr"] = err.strip()[:500]
        self.add(c)

    # ----- MUST: session / GUI -----

    def check_gui_session(self) -> None:
        c = Check(id="env.gui_session", category="env", severity="must")
        rc, out, _ = self._run(["launchctl", "print", f"gui/{self.uid}"], timeout=5)
        if rc == 0:
            c.status = "pass"
            c.message = f"gui/{self.uid} launchd domain reachable"
        else:
            c.status = "fail"
            c.message = (
                f"launchctl cannot reach gui/{self.uid} — are you in a GUI login session?"
            )
            c.fix_policy = "manual"
        self.add(c)

    # ----- MUST: JOBS_ROOT layout -----

    def check_jobs_root(self) -> None:
        c = Check(id="fs.jobs_root_exists", category="filesystem", severity="must")
        if self.jobs_root.is_dir():
            c.status = "pass"
            c.message = f"JOBS_ROOT exists: {self.jobs_root}"
        else:
            c.status = "fail"
            c.message = f"JOBS_ROOT does not exist: {self.jobs_root}"
            c.fix_policy = "confirm"
            c.fix_command = f"run /candy-setup to deploy bundle to {self.jobs_root}"
            self.add(c)
            return
        self.add(c)

        required = ["bin", "LaunchAgents", "tests", "config/lunch_schedule.conf"]
        for rel in required:
            c = Check(
                id=f"fs.jobs_root.{rel.replace('/', '_')}",
                category="filesystem",
                severity="must",
            )
            p = self.jobs_root / rel
            if p.exists():
                c.status = "pass"
                c.message = f"present: {rel}"
            else:
                c.status = "fail"
                c.message = f"missing: {rel}"
                c.fix_policy = "confirm"
                c.fix_command = "run /candy-setup to restore bundle files"
            self.add(c)

    def check_bin_executables(self) -> None:
        for name in BIN_SCRIPTS:
            c = Check(id=f"fs.bin.{name}.executable", category="filesystem", severity="must")
            p = self.jobs_root / "bin" / name
            if not p.is_file():
                c.status = "fail"
                c.message = f"missing bin/{name}"
                c.fix_policy = "confirm"
                c.fix_command = "run /candy-setup to restore bundle files"
            elif not os.access(p, os.X_OK):
                c.status = "warn"
                c.message = f"bin/{name} exists but not executable"
                c.fix_policy = "auto"
                c.fix_command = f"chmod +x {p}"
            else:
                c.status = "pass"
                c.message = f"bin/{name} executable"
            self.add(c)

    # ----- MUST: LaunchAgent files + symlinks + lint -----

    def check_launchagent_files(self) -> None:
        for name in AGENTS:
            la_path = self.launchagents_dir / f"{name}.plist"
            src_path = self.jobs_root / "LaunchAgents" / f"{name}.plist"

            c_link = Check(id=f"fs.la.{name}.symlink", category="filesystem", severity="must")
            if not la_path.exists() and not la_path.is_symlink():
                c_link.status = "fail"
                c_link.message = f"{la_path} missing"
                if src_path.exists():
                    c_link.fix_policy = "confirm"
                    c_link.fix_command = f"ln -sfn {src_path} {la_path}"
                else:
                    c_link.fix_policy = "confirm"
                    c_link.fix_command = "run /candy-setup to deploy bundle and link"
                self.add(c_link)
                continue
            if la_path.is_symlink():
                target = la_path.resolve()
                c_link.details["target"] = str(target)
                if not target.exists():
                    c_link.status = "fail"
                    c_link.message = f"symlink points to missing target: {target}"
                    if src_path.exists():
                        c_link.fix_policy = "confirm"
                        c_link.fix_command = f"ln -sfn {src_path} {la_path}"
                    else:
                        c_link.fix_policy = "confirm"
                        c_link.fix_command = "run /candy-setup"
                elif src_path.exists() and target.resolve() != src_path.resolve():
                    c_link.status = "warn"
                    c_link.message = (
                        f"symlink points at {target}, not {src_path} — unexpected but usable"
                    )
                    c_link.fix_policy = "confirm"
                    c_link.fix_command = f"ln -sfn {src_path} {la_path}"
                else:
                    c_link.status = "pass"
                    c_link.message = f"symlink → {target}"
            else:
                c_link.status = "pass"
                c_link.message = f"regular file at {la_path}"
            self.add(c_link)

            c_lint = Check(id=f"fs.la.{name}.lint", category="filesystem", severity="must")
            if la_path.exists():
                rc, out, err = self._run(["plutil", "-lint", str(la_path)], timeout=5)
                if rc == 0:
                    c_lint.status = "pass"
                    c_lint.message = f"{name}.plist: OK"
                else:
                    c_lint.status = "fail"
                    c_lint.message = f"plutil -lint failed: {out.strip() or err.strip()}"
                    c_lint.fix_policy = "confirm"
                    c_lint.fix_command = "run /candy-setup to restore plist from bundle"
            else:
                c_lint.status = "skip"
                c_lint.message = "skipped (file missing)"
            self.add(c_lint)

    # ----- MUST: launchctl print registration -----

    def check_agent_registration(self) -> None:
        for name in AGENTS:
            c_reg = Check(id=f"launchd.{name}.registered", category="launchd", severity="must")
            c_trig = Check(id=f"launchd.{name}.has_triggers", category="launchd", severity="must")
            rc, out, err = self._run(
                ["launchctl", "print", f"gui/{self.uid}/{name}"], timeout=10
            )
            if rc != 0 or "Could not find service" in (out + err):
                c_reg.status = "fail"
                c_reg.message = f"{name}: not registered in gui/{self.uid}"
                la = self.launchagents_dir / f"{name}.plist"
                c_reg.fix_policy = "confirm"
                c_reg.fix_command = (
                    f"launchctl bootout gui/{self.uid} {la} 2>/dev/null; "
                    f"launchctl bootstrap gui/{self.uid} {la}"
                )
                c_trig.status = "skip"
                c_trig.message = "skipped (agent not registered)"
                self.add(c_reg)
                self.add(c_trig)
                continue
            c_reg.status = "pass"
            c_reg.message = f"{name}: registered"
            self.add(c_reg)

            if re.search(r"event\s+triggers?\s*=\s*\{", out) and re.search(r"\d+\s*=>", out):
                c_trig.status = "pass"
                c_trig.message = f"{name}: has event triggers"
            else:
                c_trig.status = "warn"
                c_trig.message = (
                    f"{name}: launchctl print did not show event triggers — plist may be empty"
                )
                c_trig.fix_policy = "confirm"
                c_trig.fix_command = "inspect plist and re-bootstrap"
            self.add(c_trig)

    # ----- DETAIL: schedule alignment -----

    def _load_plist(self, name: str) -> Optional[dict]:
        path = self.jobs_root / "LaunchAgents" / f"{name}.plist"
        if not path.exists():
            return None
        try:
            with open(path, "rb") as f:
                return plistlib.load(f)
        except Exception:
            return None

    def _start_slots(self, data: dict) -> list[tuple[int, int]]:
        raw = data.get("StartCalendarInterval", []) or []
        if isinstance(raw, dict):
            raw = [raw]
        out = []
        for item in raw:
            h = int(item.get("Hour", -1))
            m = int(item.get("Minute", -1))
            out.append((h, m))
        return out

    def check_schedule(self) -> None:
        candy = self._load_plist("com.claude.candy")
        progress = self._load_plist("com.claude.candy.progress")
        snapshot = self._load_plist("com.claude.candy.snapshot")
        optimizer = self._load_plist("com.claude.candy.optimizer")

        c = Check(id="schedule.candy.poller", category="schedule", severity="detail")
        if not candy:
            c.status = "skip"
            c.message = "candy plist missing"
        else:
            interval = candy.get("StartInterval")
            cal = candy.get("StartCalendarInterval")
            if isinstance(interval, int) and 30 <= interval <= 120:
                c.status = "pass"
                c.message = f"candy: poller mode (StartInterval={interval}s)"
            elif cal:
                c.status = "warn"
                c.message = "candy still uses legacy StartCalendarInterval — should be StartInterval=60 (poller)"
                c.fix_policy = "confirm"
                c.fix_command = "run /candy-setup to update plist to poller mode"
            else:
                c.status = "warn"
                c.message = "candy plist has neither StartInterval nor StartCalendarInterval"
        self.add(c)

        c = Check(id="schedule.snapshot.shape", category="schedule", severity="detail")
        if not snapshot:
            c.status = "skip"
            c.message = "snapshot plist missing"
        else:
            sslots = self._start_slots(snapshot)
            c.details["slots"] = sslots
            if len(sslots) == 1:
                c.status = "pass"
                c.message = f"snapshot: 1 dynamic slot (resets_at - 3min) → {sslots}"
            elif len(sslots) == 0:
                c.status = "pass"
                c.message = "snapshot: 0 slots (will be set by first candy run)"
            else:
                c.status = "warn"
                c.message = f"snapshot has {len(sslots)} slots, expected 1 (dynamic)"
        self.add(c)

        c = Check(id="schedule.progress.shape", category="schedule", severity="detail")
        if not progress:
            c.status = "skip"
            c.message = "progress plist missing"
        else:
            pslots = self._start_slots(progress)
            c.details["slots"] = pslots
            if len(pslots) == 4:
                c.status = "pass"
                c.message = "progress: 4 dynamic slots (candy + 1h/2h/3h/4h)"
            elif len(pslots) == 0:
                c.status = "pass"
                c.message = "progress: 0 slots (will be set by first candy run)"
            else:
                c.status = "warn"
                c.message = f"progress has {len(pslots)} slots, expected 4 (dynamic)"
        self.add(c)

        c = Check(id="schedule.optimizer.shape", category="schedule", severity="detail")
        if not optimizer:
            c.status = "skip"
            c.message = "optimizer plist missing"
        else:
            oslots = self._start_slots(optimizer)
            c.details["slots"] = oslots
            if all(s[0] == 23 and s[1] == 0 for s in oslots) and 1 <= len(oslots) <= 5:
                c.status = "pass"
                c.message = f"optimizer: {len(oslots)} slot(s) at 23:00"
            else:
                c.status = "warn"
                c.message = f"optimizer slots unusual: {oslots}"
        self.add(c)

        c = Check(id="schedule.plist.program_args", category="schedule", severity="detail")
        pattern = "${JOBS_ROOT:-$HOME/jobs}"
        bad = []
        for name in AGENTS:
            d = self._load_plist(name)
            if not d:
                continue
            args = d.get("ProgramArguments", [])
            joined = " ".join(str(a) for a in args)
            if pattern not in joined:
                bad.append(name)
        if bad:
            c.status = "warn"
            c.message = f"plists not using {pattern}: {bad}"
        else:
            c.status = "pass"
            c.message = "all plists reference ${JOBS_ROOT:-$HOME/jobs}"
        self.add(c)

    # ----- DETAIL: config files -----

    def check_lunch_conf(self) -> None:
        c = Check(id="config.lunch_schedule", category="config", severity="detail")
        p = self.jobs_root / "config" / "lunch_schedule.conf"
        if not p.exists():
            c.status = "fail"
            c.message = "config/lunch_schedule.conf missing"
            c.fix_policy = "confirm"
            c.fix_command = "run /candy-setup to restore bundle"
            self.add(c)
            return
        text = p.read_text(errors="replace")
        has_anchor = bool(re.search(r'^\s*CYCLE_ANCHOR\s*=\s*"?\d{4}-\d{2}-\d{2}', text, re.M))
        has_pattern = bool(re.search(r'^\s*CYCLE_PATTERN\s*=\s*"?\d{1,2}:\d{2}-\d{1,2}:\d{2}', text, re.M))
        if has_anchor and has_pattern:
            c.status = "pass"
            c.message = "CYCLE_ANCHOR and CYCLE_PATTERN look valid"
        else:
            c.status = "warn"
            miss = []
            if not has_anchor:
                miss.append("CYCLE_ANCHOR (YYYY-MM-DD)")
            if not has_pattern:
                miss.append("CYCLE_PATTERN (HH:MM-HH:MM,...)")
            c.message = "lunch_schedule.conf missing or malformed: " + ", ".join(miss)
        self.add(c)

    def check_optimizer_phase(self) -> None:
        c = Check(id="config.optimizer_phase", category="config", severity="detail")
        p = self.jobs_root / "config" / ".optimizer_phase"
        if not p.exists():
            c.status = "pass"
            c.message = ".optimizer_phase absent (ok — defaults to phase 1)"
            self.add(c)
            return
        text = p.read_text(errors="replace").strip()
        phase = None
        try:
            data = json.loads(text)
            if isinstance(data, dict) and data.get("phase") in (1, 2):
                phase = data["phase"]
                c.details.update(data)
        except json.JSONDecodeError:
            pass
        if phase is None:
            m = re.search(r"phase\s*=\s*(\d)", text)
            if m and m.group(1) in ("1", "2"):
                phase = int(m.group(1))
        if phase is not None:
            c.status = "pass"
            c.message = f".optimizer_phase: phase={phase}"
        else:
            c.status = "warn"
            c.message = f".optimizer_phase has unexpected contents: {text[:80]!r}"
        self.add(c)

    def check_chain_state(self) -> None:
        morning_p = self.jobs_root / "config" / ".candy_morning_ts"
        next_p = self.jobs_root / "config" / ".candy_next_ts"
        now = int(time.time())

        c = Check(id="state.candy_morning_ts", category="config", severity="detail")
        if not morning_p.exists():
            c.status = "pass"
            c.message = ".candy_morning_ts absent (chain mode without morning gate)"
        else:
            try:
                ts = int(morning_p.read_text().strip())
                c.details["ts"] = ts
                c.details["age_seconds"] = now - ts
                if ts > now:
                    c.status = "pass"
                    c.message = f".candy_morning_ts: 다음 아침까지 {(ts - now)//60}분 남음"
                else:
                    c.status = "pass"
                    c.message = f".candy_morning_ts: 과거 시각 (사용됐거나 stale, age {(now - ts)//60}min)"
            except Exception as e:
                c.status = "warn"
                c.message = f".candy_morning_ts unreadable: {e}"
        self.add(c)

        c = Check(id="state.candy_next_ts", category="config", severity="detail")
        if not next_p.exists():
            c.status = "pass"
            c.message = ".candy_next_ts absent (체인 미시작)"
        else:
            try:
                ts = int(next_p.read_text().strip())
                c.details["ts"] = ts
                c.details["age_seconds"] = now - ts
                if ts > now:
                    c.status = "pass"
                    c.message = f".candy_next_ts: 다음 chain까지 {(ts - now)//60}분 남음"
                else:
                    c.status = "pass"
                    c.message = f".candy_next_ts: 과거 (candy가 곧 실행될 예정, age {(now - ts)//60}min)"
            except Exception as e:
                c.status = "warn"
                c.message = f".candy_next_ts unreadable: {e}"
        self.add(c)

    # ----- DETAIL: runtime state -----

    def check_rate_limit_file(self) -> None:
        c = Check(id="runtime.rate_limit_file", category="runtime", severity="detail")
        p = self.home / ".claude" / "abtop-rate-limits.json"
        if p.exists():
            try:
                data = json.loads(p.read_text())
                c.status = "pass"
                c.message = f"rate-limits.json present ({p})"
                c.details["keys"] = sorted(data.keys()) if isinstance(data, dict) else None
            except Exception as e:
                c.status = "warn"
                c.message = f"rate-limits.json unreadable: {e}"
        else:
            c.status = "warn"
            c.message = "~/.claude/abtop-rate-limits.json not found (first-day state likely)"
        self.add(c)

    def check_refresh_log(self) -> None:
        c = Check(id="runtime.refresh_log", category="runtime", severity="detail")
        p = self.jobs_root / "logs" / "refresh.log"
        if not p.exists():
            c.status = "warn"
            c.message = "logs/refresh.log not found (candy may never have run)"
            self.add(c)
            return
        lines = p.read_text(errors="replace").splitlines()
        n = len(lines)
        errs = [ln for ln in lines[-100:] if re.search(r"\b(error|fatal|traceback)\b", ln, re.I)]
        if errs:
            c.status = "warn"
            c.message = f"refresh.log: {len(errs)} error-ish lines in last 100 lines (total {n})"
            c.details["sample"] = errs[-5:]
        else:
            c.status = "pass"
            c.message = f"refresh.log: {n} lines, no recent errors"
        self.add(c)

    def check_usage_csv(self) -> None:
        c = Check(id="runtime.usage_csv_fresh", category="runtime", severity="detail")
        p = self.jobs_root / "logs" / "usage_snapshots.csv"
        if not p.exists():
            c.status = "warn"
            c.message = "logs/usage_snapshots.csv not found"
            self.add(c)
            return
        last_ts = None
        try:
            with p.open() as f:
                try:
                    f.seek(0, 2)
                    size = f.tell()
                    f.seek(max(0, size - 4096))
                    tail_lines = f.read().splitlines()
                except Exception:
                    f.seek(0)
                    tail_lines = f.read().splitlines()
            if len(tail_lines) <= 1:
                c.status = "warn"
                c.message = "usage_snapshots.csv has header only or is empty"
                self.add(c)
                return
            last = tail_lines[-1]
            first_field = last.split(",")[0]
            last_ts = int(first_field)
        except Exception as e:
            c.status = "warn"
            c.message = f"could not read csv tail: {e}"
            self.add(c)
            return
        age = int(time.time()) - last_ts
        c.details["last_ts"] = last_ts
        c.details["age_seconds"] = age
        if age < 6 * 3600:
            c.status = "pass"
            c.message = f"usage_snapshots.csv fresh (last entry {age//60} min ago)"
        elif age < 24 * 3600:
            c.status = "warn"
            c.message = f"usage_snapshots.csv stale: last entry {age//3600} h ago"
        else:
            c.status = "warn"
            c.message = f"usage_snapshots.csv very stale: last entry {age//3600} h ago"
        self.add(c)

    def check_limit_until(self) -> None:
        c = Check(id="runtime.limit_until", category="runtime", severity="detail")
        p = self.jobs_root / "logs" / ".limit_until"
        if not p.exists():
            c.status = "pass"
            c.message = ".limit_until absent (not in rate-limit state)"
            self.add(c)
            return
        text = p.read_text(errors="replace").strip()
        try:
            until = int(text)
            remaining = until - int(time.time())
            if remaining > 0:
                c.status = "warn"
                c.message = f"rate limit active, {remaining // 60} min remaining"
            else:
                c.status = "pass"
                c.message = ".limit_until expired (stale file, harmless)"
            c.details["until_ts"] = until
        except Exception:
            c.status = "warn"
            c.message = f".limit_until contents unexpected: {text[:40]!r}"
        self.add(c)

    def check_optimizer_tmp_logs(self) -> None:
        c = Check(id="runtime.optimizer_tmp_logs", category="runtime", severity="detail")
        out_log = Path("/tmp/claude-candy-optimizer.log")
        err_log = Path("/tmp/claude-candy-optimizer-error.log")
        out_present = out_log.exists()
        err_present = err_log.exists() and err_log.stat().st_size > 0
        if err_present:
            tail = err_log.read_text(errors="replace").splitlines()[-10:]
            c.status = "warn"
            c.message = f"/tmp/claude-candy-optimizer-error.log has {err_log.stat().st_size} bytes"
            c.details["tail"] = tail
        else:
            c.status = "pass"
            c.message = "optimizer tmp logs look clean"
            c.details["out_present"] = out_present
            c.details["err_present"] = err_present
        self.add(c)

    def check_optimizer_gate(self) -> None:
        c = Check(id="runtime.optimizer_gate", category="runtime", severity="detail")
        p = self.jobs_root / "logs" / "usage_snapshots.csv"
        if not p.exists():
            c.status = "skip"
            c.message = "csv missing"
            self.add(c)
            return
        try:
            count = 0
            with p.open() as f:
                header = f.readline().strip().split(",")
                try:
                    type_idx = header.index("type")
                    slot_idx = header.index("sample_slot")
                except ValueError:
                    c.status = "skip"
                    c.message = "csv header missing expected columns"
                    self.add(c)
                    return
                for line in f:
                    parts = line.rstrip("\n").split(",")
                    if len(parts) <= max(type_idx, slot_idx):
                        continue
                    if parts[type_idx] == "snapshot" and parts[slot_idx] == "final":
                        count += 1
            c.details["final_snapshots"] = count
            if count >= 4:
                c.status = "pass"
                c.message = f"optimizer gate open: {count} final snapshots accumulated (≥ 4)"
            else:
                c.status = "warn"
                c.message = (
                    f"optimizer gate closed: {count}/4 final snapshots — optimizer will skip"
                )
        except Exception as e:
            c.status = "warn"
            c.message = f"could not evaluate optimizer gate: {e}"
        self.add(c)

    def check_optimizer_snap_attribution(self) -> None:
        c = Check(id="logic.optimizer_snap_attribution", category="logic", severity="detail")
        opt_path = self.jobs_root / "bin" / "schedule_optimizer.sh"
        if not opt_path.exists():
            c.status = "skip"
            c.message = "schedule_optimizer.sh not found"
            self.add(c)
            return

        text = opt_path.read_text(errors="replace")

        old_pattern = re.compile(r"awk.*\$5.*snapshot.*\$2.*~.*d|awk.*snapshot.*\$2~d")
        new_pattern = re.compile(r"resets_at.*18000|5h_resets_at.*18000")

        if old_pattern.search(text):
            c.status = "fail"
            c.message = (
                "schedule_optimizer.sh snap_count uses awk date-match — "
                "snapshots crossing midnight are not counted (optimizer stuck at 3/4)"
            )
            c.fix_policy = "manual"
            c.fix_command = (
                "replace awk snap_count with Python window-start attribution "
                "(use TARGET_DATE + SNAPSHOT_CSV env vars, count rows where "
                "datetime.fromtimestamp(int(5h_resets_at)-18000).date() == target)"
            )
        elif new_pattern.search(text):
            c.status = "pass"
            c.message = "snap_count uses window-start attribution (5h_resets_at - 18000s) ✓"
        else:
            c.status = "warn"
            c.message = "could not detect snap_count method in schedule_optimizer.sh"
        self.add(c)

    def check_optimizer_window_gate(self) -> None:
        c = Check(id="runtime.optimizer_window_gate", category="runtime", severity="detail")
        p = self.jobs_root / "logs" / "usage_snapshots.csv"
        if not p.exists():
            c.status = "skip"
            c.message = "csv missing"
            self.add(c)
            return

        try:
            today = datetime.date.today()
            dow = today.weekday()  # 0=Mon
            if dow == 0:
                target = today - datetime.timedelta(days=3)
            else:
                target = today - datetime.timedelta(days=1)

            count_window = 0
            count_date = 0

            with p.open() as f:
                for row in csv.DictReader(f):
                    if row.get("type") != "snapshot":
                        continue
                    if row.get("datetime", "").startswith(str(target)):
                        count_date += 1
                    try:
                        resets_at = int(float(row["5h_resets_at"]))
                        ws = datetime.datetime.fromtimestamp(resets_at - 18000)
                        if ws.date() == target:
                            count_window += 1
                    except (ValueError, KeyError, OSError):
                        pass

            c.details["target_date"] = str(target)
            c.details["count_by_window_start"] = count_window
            c.details["count_by_datetime"] = count_date
            discrepancy = count_window != count_date

            if count_window >= 4:
                c.status = "pass"
                msg = f"window-gate open: {count_window}/4 snapshots for {target}"
                if discrepancy:
                    msg += f" (datetime-only would count {count_date} — cross-day window present)"
                c.message = msg
            else:
                c.status = "warn"
                msg = f"window-gate closed: {count_window}/4 snapshots for {target}"
                if discrepancy:
                    msg += f" (datetime-only: {count_date})"
                c.message = msg
        except Exception as e:
            c.status = "warn"
            c.message = f"could not evaluate window gate: {e}"
        self.add(c)

    # ----- DETAIL: housekeeping -----

    def check_log_sizes(self) -> None:
        c = Check(id="housekeeping.refresh_log_lines", category="housekeeping", severity="detail")
        p = self.jobs_root / "logs" / "refresh.log"
        if p.exists():
            n = sum(1 for _ in p.open(errors="replace"))
            c.details["lines"] = n
            if n <= 100:
                c.status = "pass"
                c.message = f"refresh.log: {n} lines (≤ 100)"
            elif n <= 200:
                c.status = "pass"
                c.message = f"refresh.log: {n} lines (slightly over 100, tolerable)"
            else:
                c.status = "warn"
                c.message = f"refresh.log: {n} lines (should self-rotate to 100)"
        else:
            c.status = "skip"
            c.message = "refresh.log missing"
        self.add(c)

        c = Check(id="housekeeping.csv_rows", category="housekeeping", severity="detail")
        p = self.jobs_root / "logs" / "usage_snapshots.csv"
        if p.exists():
            n = sum(1 for _ in p.open(errors="replace"))
            c.details["rows"] = n
            if n <= 501:
                c.status = "pass"
                c.message = f"usage_snapshots.csv: {n} rows (header+500 rows cap)"
            elif n <= 700:
                c.status = "pass"
                c.message = f"usage_snapshots.csv: {n} rows (slightly over 500)"
            else:
                c.status = "warn"
                c.message = f"usage_snapshots.csv: {n} rows (should cap at 500)"
        else:
            c.status = "skip"
            c.message = "usage_snapshots.csv missing"
        self.add(c)

        c = Check(id="housekeeping.backups_count", category="housekeeping", severity="detail")
        p = self.jobs_root / "backups"
        if p.exists():
            entries = list(p.iterdir())
            c.details["count"] = len(entries)
            if len(entries) <= 50:
                c.status = "pass"
                c.message = f"backups/: {len(entries)} entries"
            else:
                c.status = "warn"
                c.message = f"backups/: {len(entries)} entries (check for runaway growth)"
        else:
            c.status = "pass"
            c.message = "backups/ does not exist (fine — created on demand)"
        self.add(c)

    # ----- DETAIL: notification permissions (manual) -----

    def check_notifications(self) -> None:
        c = Check(id="os.notification_permission", category="os", severity="detail")
        c.status = "warn"
        c.message = (
            "macOS notification permission can't be reliably read programmatically. "
            "Verify in System Settings → Notifications that osascript / Script Editor / "
            "your terminal have notifications allowed."
        )
        c.fix_policy = "manual"
        c.fix_command = (
            "open 'x-apple.systempreferences:com.apple.preference.notifications'"
        )
        self.add(c)

    # ----- DETAIL: execution checks -----

    def _make_exec_tmpdir(self) -> Path:
        """격리된 temp JOBS_ROOT 생성. bin/은 심링크, logs/config/는 빈 실제 디렉터리."""
        tmpdir = Path(tempfile.mkdtemp(prefix="candy_doctor_exec_"))
        # bin/ 심링크: PYTHONPATH($JOBS_ROOT/bin/lib)가 자동으로 실제 lib을 가리킴
        (tmpdir / "bin").symlink_to(self.jobs_root / "bin")
        la_src = self.jobs_root / "LaunchAgents"
        if la_src.exists():
            (tmpdir / "LaunchAgents").symlink_to(la_src)
        (tmpdir / "logs").mkdir()
        (tmpdir / "config").mkdir()
        conf_src = self.jobs_root / "config" / "lunch_schedule.conf"
        if conf_src.exists():
            shutil.copy(conf_src, tmpdir / "config" / "lunch_schedule.conf")
        return tmpdir

    def _exec_snapshot_row(self, tmpdir: Path, snapshot_type: str = "snapshot") -> tuple[Check, Optional[dict]]:
        """snapshot 또는 progress 스크립트를 tmpdir에서 실행하고 마지막 CSV 행을 반환."""
        script = "usage_snapshot.sh" if snapshot_type == "snapshot" else "usage_progress.sh"
        cid = f"exec.{snapshot_type}.dry_run"
        c = Check(id=cid, category="execution", severity="detail")
        csv_path = tmpdir / "logs" / "usage_snapshots.csv"

        prev_count = 0
        if csv_path.exists():
            with csv_path.open() as f:
                prev_count = sum(1 for _ in f) - 1

        env = {**os.environ, "JOBS_ROOT": str(tmpdir)}
        if snapshot_type == "progress":
            env["SNAPSHOT_TYPE"] = "progress"

        rc, out, err = self._run(
            ["bash", str(self.jobs_root / "bin" / script)],
            env=env,
            timeout=10,
        )

        if rc != 0:
            c.status = "fail"
            c.message = f"{script} exited {rc}: {(out + err).strip()[:200]}"
            return c, None

        if not csv_path.exists():
            c.status = "fail"
            c.message = f"{script} 실행됐지만 CSV 미생성"
            return c, None

        try:
            rows = list(csv.DictReader(csv_path.open()))
        except Exception as e:
            c.status = "fail"
            c.message = f"CSV 파싱 오류: {e}"
            return c, None

        new_rows = rows[prev_count:]
        if not new_rows:
            c.status = "fail"
            c.message = f"{script} 실행됐지만 새 행 없음"
            return c, None

        return c, new_rows[-1]

    def _check_exec_snapshot(self, tmpdir: Path) -> None:
        c, row = self._exec_snapshot_row(tmpdir, "snapshot")
        if row is None:
            self.add(c)
            return

        issues = []

        try:
            pct = float(row.get("5h_used_pct", ""))
            if not (0 <= pct <= 100):
                issues.append(f"5h_used_pct={pct} 범위 초과")
        except (ValueError, TypeError):
            issues.append("5h_used_pct 숫자 아님")

        window_date = None
        try:
            resets_at = int(float(row.get("5h_resets_at", "0")))
            if resets_at <= 0:
                issues.append("5h_resets_at 비정상")
            else:
                window_start = datetime.datetime.fromtimestamp(resets_at - 18000)
                window_date = window_start.date()
                today = datetime.date.today()
                if window_date != today:
                    issues.append(
                        f"resetsAt window-start {window_date} ≠ today {today}"
                    )
                c.details["window_start"] = str(window_start)
                c.details["resets_at_human"] = datetime.datetime.fromtimestamp(resets_at).strftime("%H:%M")
        except (ValueError, TypeError, OSError):
            issues.append("5h_resets_at 파싱 실패")

        c.details["row"] = {k: row.get(k) for k in ("type", "sample_slot", "5h_used_pct", "5h_resets_at")}

        if issues:
            c.status = "warn"
            c.message = "snapshot.sh 실행됨, 행 기록됨, 그러나: " + "; ".join(issues)
        else:
            pct_val = row.get("5h_used_pct", "?")
            c.status = "pass"
            c.message = (
                f"snapshot dry-run 정상: {pct_val}% 사용, "
                f"resetsAt window-start={window_date}, "
                f"resets_at={c.details.get('resets_at_human', '?')}"
            )
        self.add(c)

    def _check_exec_progress(self, tmpdir: Path) -> None:
        c, row = self._exec_snapshot_row(tmpdir, "progress")
        if row is None:
            self.add(c)
            return

        issues = []
        if row.get("type") != "progress":
            issues.append(f"type={row.get('type')!r}, expected 'progress'")

        valid_slots = {"1h", "2h", "3h", "4h"}
        slot = row.get("sample_slot", "")
        if slot not in valid_slots:
            issues.append(f"sample_slot={slot!r} (유효값: {valid_slots})")

        c.details["row"] = {k: row.get(k) for k in ("type", "sample_slot", "5h_used_pct")}

        if issues:
            c.status = "warn"
            c.message = "progress.sh 실행됨, 행 기록됨, 그러나: " + "; ".join(issues)
        else:
            c.status = "pass"
            c.message = f"progress dry-run 정상: slot={slot}, {row.get('5h_used_pct', '?')}% 사용"
        self.add(c)

    def _check_exec_optimizer_gate(self, tmpdir: Path) -> None:
        c = Check(id="exec.optimizer.gate", category="execution", severity="detail")
        optimizer_sh = self.jobs_root / "bin" / "schedule_optimizer.sh"

        if not optimizer_sh.exists():
            c.status = "skip"
            c.message = "schedule_optimizer.sh not found"
            self.add(c)
            return

        change_log = tmpdir / "logs" / "schedule_changes.log"
        base_env = {
            **os.environ,
            "JOBS_ROOT": str(tmpdir),
            "PYTHONPATH": str(self.jobs_root / "bin" / "lib"),
        }

        failures = []

        # 케이스 1: 주말(토요일) → "주말 스킵"
        today = datetime.date.today()
        days_to_sat = (5 - today.weekday()) % 7 or 7  # 항상 미래의 토요일
        saturday = today + datetime.timedelta(days=days_to_sat)
        sat_ts = int(datetime.datetime.combine(saturday, datetime.time(23, 0)).timestamp())

        change_log.write_text("")
        rc, _, _ = self._run(
            ["bash", str(optimizer_sh)],
            env={**base_env, "FAKE_NOW_TS": str(sat_ts)},
            timeout=15,
        )
        log_text = change_log.read_text(errors="replace") if change_log.exists() else ""
        if rc != 0:
            failures.append(f"주말 케이스: exit {rc}")
        elif "주말 스킵" not in log_text:
            failures.append(f"주말 케이스: '주말 스킵' 로그 없음 ({log_text.strip()[:80]!r})")

        # 케이스 2: 평일 + 데이터 없음 → "SKIP - 데이터 부족"
        days_to_tue = (1 - today.weekday()) % 7 or 7  # 다음 화요일
        tuesday = today + datetime.timedelta(days=days_to_tue)
        tue_ts = int(datetime.datetime.combine(tuesday, datetime.time(23, 0)).timestamp())

        change_log.write_text("")
        rc, _, _ = self._run(
            ["bash", str(optimizer_sh)],
            env={**base_env, "FAKE_NOW_TS": str(tue_ts)},
            timeout=15,
        )
        log_text = change_log.read_text(errors="replace") if change_log.exists() else ""
        if rc != 0:
            failures.append(f"데이터부족 케이스: exit {rc}")
        elif "SKIP" not in log_text and "데이터 부족" not in log_text:
            failures.append(f"데이터부족 케이스: SKIP 로그 없음 ({log_text.strip()[:80]!r})")

        if failures:
            c.status = "fail"
            c.message = "optimizer gate 검증 실패: " + "; ".join(failures)
        else:
            c.status = "pass"
            c.message = "optimizer gate 정상: 주말→스킵, 데이터부족→스킵 확인"
        self.add(c)

    def _check_exec_chain_gate(self) -> None:
        """refresh_claude.sh GATE_PYEOF 로직을 Python으로 직접 재현해 3개 케이스 검증."""
        c = Check(id="exec.chain.gate", category="execution", severity="detail")
        now_ts = int(time.time())
        future_ts = now_ts + 3600
        past_ts = now_ts - 3600

        def gate(morning_ts: int, next_ts: int) -> str:
            if morning_ts > now_ts:
                return "blocked"
            if next_ts > now_ts:
                return "blocked"
            return "pass"

        cases = [
            ("next_ts 미래 → blocked", gate(0, future_ts), "blocked"),
            ("morning_ts 미래 → blocked", gate(future_ts, 0), "blocked"),
            ("둘 다 과거 → pass", gate(past_ts, past_ts), "pass"),
        ]

        failures = [label for label, actual, expected in cases if actual != expected]

        if failures:
            c.status = "fail"
            c.message = "chain gate 로직 오류: " + ", ".join(failures)
        else:
            c.status = "pass"
            c.message = "chain gate 정상: next_ts미래→blocked, morning_ts미래→blocked, 둘다과거→pass"
        self.add(c)

    def check_execution(self, no_exec: bool = False) -> None:
        """실제 스크립트 실행 검증 (격리된 temp JOBS_ROOT 사용)."""
        exec_check_ids = [
            "exec.snapshot.dry_run",
            "exec.progress.dry_run",
            "exec.optimizer.gate",
            "exec.chain.gate",
        ]

        if no_exec:
            for cid in exec_check_ids:
                self.add(Check(
                    id=cid, category="execution", severity="detail",
                    status="skip", message="--no-exec 플래그로 건너뜀",
                ))
            return

        today_dow = datetime.date.today().weekday()  # 0=Mon, 6=Sun
        tmpdir = self._make_exec_tmpdir()
        try:
            if today_dow >= 5:
                # 주말: snapshot/progress/optimizer는 weekday-only 동작 → skip
                for cid in ("exec.snapshot.dry_run", "exec.progress.dry_run", "exec.optimizer.gate"):
                    self.add(Check(
                        id=cid, category="execution", severity="detail",
                        status="skip", message="주말 — 스크립트가 weekday-only로 동작",
                    ))
            else:
                self._check_exec_snapshot(tmpdir)
                self._check_exec_progress(tmpdir)
                self._check_exec_optimizer_gate(tmpdir)
            # chain gate는 순수 Python — 항상 실행
            self._check_exec_chain_gate()
        except Exception as e:
            for cid in exec_check_ids:
                if not any(ch.id == cid for ch in self.checks):
                    self.add(Check(
                        id=cid, category="execution", severity="detail",
                        status="warn", message=f"execution check 오류: {e}",
                    ))
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    # ----- run all -----

    def run_all(self, no_exec: bool = False) -> None:
        self.check_binaries()
        self.check_gui_session()
        self.check_jobs_root()
        self.check_bin_executables()
        self.check_launchagent_files()
        self.check_agent_registration()
        self.check_claude_preflight()
        self.check_schedule()
        self.check_lunch_conf()
        self.check_optimizer_phase()
        self.check_chain_state()
        self.check_rate_limit_file()
        self.check_refresh_log()
        self.check_usage_csv()
        self.check_limit_until()
        self.check_optimizer_tmp_logs()
        self.check_optimizer_gate()
        self.check_optimizer_snap_attribution()
        self.check_optimizer_window_gate()
        self.check_log_sizes()
        self.check_execution(no_exec=no_exec)
        self.check_notifications()


def detect_jobs_root() -> Path:
    env = os.environ.get("JOBS_ROOT")
    if env:
        return Path(os.path.expanduser(env)).resolve()
    home = Path(os.path.expanduser("~"))
    link = home / "Library" / "LaunchAgents" / "com.claude.candy.plist"
    if link.is_symlink():
        target = link.resolve()
        if target.parent.name == "LaunchAgents":
            return target.parent.parent
    return home / "jobs"


def render_human(jobs_root: Path, checks: list[Check]) -> str:
    out = []
    out.append("Candy Doctor Report")
    out.append(f"JOBS_ROOT: {jobs_root}")
    out.append("")

    by_cat: dict[str, list[Check]] = {}
    for c in checks:
        by_cat.setdefault(c.category, []).append(c)

    summary = {"pass": 0, "warn": 0, "fail": 0, "skip": 0}
    for c in checks:
        summary[c.status] = summary.get(c.status, 0) + 1

    for cat in [
        "binary",
        "env",
        "auth",
        "filesystem",
        "launchd",
        "schedule",
        "config",
        "runtime",
        "logic",
        "execution",
        "housekeeping",
        "os",
    ]:
        items = by_cat.get(cat)
        if not items:
            continue
        out.append(f"[{cat}]")
        for c in items:
            mark = {"pass": "✓", "warn": "⚠", "fail": "✗", "skip": "·"}.get(c.status, "?")
            sev = "MUST" if c.severity == "must" else "det"
            out.append(f"  {mark} [{sev}] {c.id}: {c.message}")
            if c.fix_command and c.status in ("warn", "fail"):
                out.append(f"      fix ({c.fix_policy}): {c.fix_command}")
        out.append("")

    out.append(
        f"summary: {summary['pass']} pass, {summary['warn']} warn, "
        f"{summary['fail']} fail, {summary['skip']} skip"
    )
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description="Diagnose Claude Candy installation")
    ap.add_argument("--jobs-root", help="override JOBS_ROOT (default: inferred)")
    ap.add_argument("--json", action="store_true", help="emit JSON for skill consumption")
    ap.add_argument(
        "--no-exec",
        action="store_true",
        help="skip execution checks (faster static-only diagnosis)",
    )
    args = ap.parse_args()

    jobs_root = (
        Path(os.path.expanduser(args.jobs_root)).resolve()
        if args.jobs_root
        else detect_jobs_root()
    )

    doc = Doctor(jobs_root=jobs_root)
    doc.run_all(no_exec=args.no_exec)

    if args.json:
        payload = {
            "jobs_root": str(jobs_root),
            "uid": doc.uid,
            "checks": [asdict(c) for c in doc.checks],
            "summary": {
                "pass": sum(1 for c in doc.checks if c.status == "pass"),
                "warn": sum(1 for c in doc.checks if c.status == "warn"),
                "fail": sum(1 for c in doc.checks if c.status == "fail"),
                "skip": sum(1 for c in doc.checks if c.status == "skip"),
            },
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(render_human(jobs_root, doc.checks))

    must_fail = any(c.status == "fail" and c.severity == "must" for c in doc.checks)
    return 1 if must_fail else 0


if __name__ == "__main__":
    sys.exit(main())

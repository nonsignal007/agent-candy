import datetime
import os


def get_now() -> datetime.datetime:
    fake_now_ts = os.environ.get("FAKE_NOW_TS", "").strip()
    if fake_now_ts:
        return datetime.datetime.fromtimestamp(int(fake_now_ts))

    fake_now_iso = os.environ.get("FAKE_NOW_ISO", "").strip()
    if fake_now_iso:
        return datetime.datetime.fromisoformat(fake_now_iso)

    return datetime.datetime.now()


def get_today() -> datetime.date:
    fake_today = os.environ.get("FAKE_TODAY", "").strip()
    if fake_today:
        return datetime.date.fromisoformat(fake_today)
    return get_now().date()


def format_ts(ts: int, fmt: str) -> str:
    return datetime.datetime.fromtimestamp(int(ts)).strftime(fmt)


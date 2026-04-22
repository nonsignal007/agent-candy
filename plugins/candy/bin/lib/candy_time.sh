#!/bin/bash

runtime_now_ts() {
    python3 << 'PYEOF'
from candy_time import get_now
print(int(get_now().timestamp()))
PYEOF
}

runtime_now_fmt() {
    local fmt="$1"
    FORMAT="$fmt" python3 << 'PYEOF'
import os
from candy_time import get_now
print(get_now().strftime(os.environ["FORMAT"]))
PYEOF
}

runtime_weekday_u() {
    python3 << 'PYEOF'
from candy_time import get_today
print(get_today().isoweekday())
PYEOF
}

runtime_year() {
    runtime_now_fmt '%Y'
}

runtime_shifted_date() {
    local days="$1" fmt="$2"
    SHIFT_DAYS="$days" FORMAT="$fmt" python3 << 'PYEOF'
import datetime
import os
from candy_time import get_today

today = get_today()
shift = int(os.environ["SHIFT_DAYS"])
target = today + datetime.timedelta(days=shift)
print(target.strftime(os.environ["FORMAT"]))
PYEOF
}

runtime_format_ts() {
    local ts="$1" fmt="$2"
    TS="$ts" FORMAT="$fmt" python3 << 'PYEOF'
import os
from candy_time import format_ts

print(format_ts(int(os.environ["TS"]), os.environ["FORMAT"]))
PYEOF
}


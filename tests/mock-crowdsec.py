#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mock-crowdsec.py - a stateful stand-in for the `docker` CLI plus `cscli` and `crowdsec -t` (CrowdSec 1.8.x).

WHY
    The DCS API (bash + jq) manages a CrowdSec container by shelling out to `docker exec CrowdSec cscli ...`.
    Its smoke tests and the browser lab need a fake `docker` on PATH that behaves like a real CrowdSec 1.8.1
    container, statefully, in every state the CrowdSec page has to handle. The JSON shapes, message texts and
    error texts here were captured from a genuine crowdsecurity/crowdsec v1.8.1 container (and compared with it
    command by command); where the written spec and the real thing disagreed, the real thing won (see
    "DIFFERENCES FROM THE SPEC").

USAGE
    A wrapper called `docker` on PATH does:      exec python3 /path/to/tests/mock-crowdsec.py "$@"
    so argv[1:] is a docker command line (ps, inspect, exec, cp, restart, logs, ...):
        export FAKE_CS_DIR=/tmp/lab                       # required; created on demand
        python3 tests/mock-crowdsec.py --mock-init data --traefik
        docker exec CrowdSec cscli decisions list -o json
        docker exec -i CrowdSec cscli decisions import -i - --format values < ips.txt
    State lives in $FAKE_CS_DIR:
        state.json       the whole world (containers, CrowdSec database, hub, log lines)
        rootfs/          the container's files (/etc/crowdsec/... is a real directory tree here; the bind mounts
                         that `docker inspect` reports point into it)
        calls.log        one line per invocation: epoch<TAB>argv joined by a space
        unsupported.log  one line per docker/cscli sub-command that is not implemented (it also prints
                         `mock-crowdsec: unsupported: <argv>` and exits 1)
        .lock            flock() target: several `docker exec` may run in parallel

CONTROL VERBS (first argument starts with --mock-)
    --mock-init PRESET [--traefik] [--version 1.8.1] [--seed N]
                     (re)create the state; calls.log and unsupported.log are emptied. PRESET:
        absent      no CrowdSec container at all               defined    same for docker (a compose file elsewhere defines it)
        stopped     exited, ExitCode 137, no health            crashloop  restarting (RestartCount 17), fatal profile error in the logs
        starting    running, Health.Status=starting            unhealthy  running, Health.Status=unhealthy (healthcheck: cscli version)
        lapi-down   running+healthy, cscli's LAPI commands fail with "connection refused"
        empty       healthy, only the local machine, stock profiles, no decisions/alerts/bouncers/allowlists
        data        healthy, ~14 decisions from 8 countries (+ a permanent ban, a simulated one, a manual Ip and Range,
                    a CAPI blocklist alert with 40 decisions), alerts up to 6 days old, 6 of them without an active
                    decision, 2 bouncers, 1 machine, 2 allowlists, an outdated collection, metrics with traffic
        old         like data but CrowdSec 1.6.5 (no allowlists, no -B, `null` for empty JSON lists, old hub messages)
        Presets other than absent/defined/empty use the `data` dataset behind their container state.
        --traefik adds a running `Traefik` container (compose project networking-security).
    --mock-set KEY=VALUE ...    tweak the state:
        docker_down=1|0     every docker command fails like a dead daemon
        lapi_down=1|0|2     1: every sub-command the spec lists fails with "connection refused" (LAPI clients with the real
                            4-retries preamble); 2: only the sub-commands that really talk to the LAPI fail - the
                            database-direct ones (bouncers, machines, allowlists create/add/remove, metrics, console) keep working
        health=healthy|unhealthy|starting     container health (starting sticks until changed or until a restart)
        health_delay=N      after a restart `docker inspect` says "starting" for N seconds of mock time
        status=running|exited|restarting      force the container state
        restart_fails=1     the next restart leaves a crash loop (cleared afterwards)
        version=1.6.5       CrowdSec version (< 1.6.8: no allowlists / -B; < 1.7: `null` for empty JSON lists, old hub text)
        discord=1|0         install / remove the DCS-shipped profiles.yaml + a rendered http.yaml (webhook discord.com/.../lab)
        traefik=1|0         add / remove the Traefik container
        cscli_slow_ms=N     every cscli call sleeps N ms first (before the lock is taken)
        empty_json=null|[]|auto   what `-o json` prints for an empty decisions/alerts list (auto: [] for >= 1.7)
        capi=ok|error|unregistered|disabled   `cscli capi status` / `console status`
        hub_cascade=1|0     the real cscli also flags an enabled collection "update available" when one of its members is behind (one level);
                            off by default so that the `data` preset has exactly one item with an update (sshd) although linux contains it
    --mock-tick SECONDS   pretend that many seconds passed: decisions expire and every printed timestamp (last_pull,
                          last_heartbeat, alert times, docker times) moves back by that much, as a real clock would show
    --mock-dump           print state.json

DIFFERENCES FROM THE SPEC (the real 1.8.1 container was authoritative)
    * `decisions list -o json` / `alerts list -o json` print `[]` when nothing matches, not `null` (`alerts list` without a
      trailing newline); `null` only below 1.7 (or empty_json=null).
    * hub install/remove/upgrade print the 1.8 "Action plan:" text (with "downloading ..." / "enabling ..." lines).
    * `decisions delete -i IP` also deletes ranges containing the IP (there is no --scope flag); `decisions delete --id N`
      succeeds for any known id (already expired ones too) and fails with the API error for unknown ids.
    * adding an item to an allowlist deletes EVERY active Ip/Range decision that overlaps any allowlist item (also earlier
      `-B` ones); `allowlists check` / `decisions add` use overlap, not containment.
    * a decision whose scope is Ip/Range but whose value is no address is silently dropped by the LAPI (cscli still says
      "Decision successfully added").
    * `alerts inspect 99`: "can't find alert with id 99: API error: object not found"; `decisions import` prints
      "Parsing json" / "Imported N decisions"; `simulation enable unknown` only logs an error and exits 0.
    * `bouncers add` keys are 43 characters of standard base64 (they can contain + and /); `bouncers delete unknown`:
      "unable to delete bouncer NAME: ent: bouncer not found".
    * hub items: `collections remove X` refuses (warnings on stderr, "Nothing to install or remove.", exit 0) while another installed
      collection lists X, unless --force; a collection takes its contents along unless another installed collection outside the removal
      still lists them directly (so removing `--all` leaves the items two removed collections share); downloads, enabling and
      disabling are applied per requested item, contents first, in the order the collection lists them; `inspect NAME...` prints each
      item as soon as it is found (one JSON document per name, YAML plus a "Current metrics:" line for installed items in human mode).
    * `machines inspect` is a box in human mode and refuses -o raw; `bouncers inspect` refuses -o raw and prints no trailing newline;
      `metrics` and `metrics show` refuse -o raw. A LAPI login refreshes the machine's updated_at, an alert push sets last_push.
    * with `-o json` cscli logs only errors, as JSON lines; with `-o raw` only errors, as text (info/warning lines such as
      "Decision successfully added" are human-mode only).
    * `docker inspect X` of an unknown container prints `[]` on stdout and "error: no such object: X" on stderr;
      `{{.State.Health.Status}}` of a container without healthcheck is a template error (rc 1) exactly as docker 29 does it.
    * `docker logs`: the crowdsec log lines (time="..." level=...) go to stderr, the entrypoint lines to stdout.
    * `crowdsec -t` writes everything to stderr and names the profiles file it was actually given.

APPROXIMATED
    `cscli ... --help` texts, `completion`, `config show -o json|raw`, `cscli notifications test` timings (no sleeping; retries are
    printed at once), the `old` (1.6.x) message texts, the Go-template subset of `--format`, expr-lang / YAML diagnostics beyond
    the cases of the spec (see profiles_check). Hub items that ship data files do not print their "downloading https://..." lines,
    tainted and local hub items do not exist, "Bouncer Metrics" (bouncer usage reports) and the AppSec tables stay empty, hub file
    digests are made up, and "did you mean" picks the first closest name where the real one picks a random one of them.

DESIGN NOTES
    * Standard library only, Python 3.8+. An invocation takes ~45 ms, most of it Python compiling this file.
    * Every invocation takes an exclusive flock() for its read-modify-write; state.json is replaced atomically.
    * Time is wall clock + state["clock"] (advanced by --mock-tick). Decisions keep an absolute `until`, so their remaining
      duration is derived at print time exactly like the LAPI does (truncated seconds, negative for expired ones, which
      `alerts list` and `decisions list` still show inside their alert - CrowdSec keeps them for 7 days).
    * Ids/UUIDs/API keys come from a small deterministic generator seeded by --seed (default 1).
    * No network access except `cscli notifications test` POSTing to a loopback URL of the plugin config; never shells out.
"""
import base64
import fcntl
import json
import os
import re
import sys
import time
import zlib

PROG = 'mock-crowdsec'
DEFAULT_VERSION = '1.8.1'
STATE_SCHEMA = 3


class Exit(Exception):
    """Raised to leave with an exit status (after the output has been written)."""

    def __init__(self, code=0):
        Exception.__init__(self, code)
        self.code = code


# --------------------------------------------------------------------------------------------------
# output helpers: stdout and stderr are flushed alternately so `2>&1` keeps the natural order
# --------------------------------------------------------------------------------------------------
def out(s=''):
    sys.stderr.flush()
    sys.stdout.write(s + '\n')
    sys.stdout.flush()


def outn(s):
    """stdout without the trailing newline (a few real cscli messages have none)."""
    sys.stderr.flush()
    sys.stdout.write(s)
    sys.stdout.flush()


def err(s=''):
    sys.stdout.flush()
    sys.stderr.write(s + '\n')
    sys.stderr.flush()


def errn(s):
    sys.stdout.flush()
    sys.stderr.write(s)
    sys.stderr.flush()


def fail(msg, code=1):
    err(msg)
    raise Exit(code)


# --------------------------------------------------------------------------------------------------
# clock and formatting
# --------------------------------------------------------------------------------------------------
CLOCK = [0.0]          # seconds added to the wall clock (--mock-tick)


def now():
    return time.time() + CLOCK[0]


def wall(t):
    """the instant a consumer with a real clock must see for the mock-time instant t: every timestamp the mock prints
    is shifted back by the --mock-tick offset, so a bouncer that pulled "20 s ago" looks 10 minutes old after
    `--mock-tick 580`."""
    return t - CLOCK[0]


def _gm(t):
    return time.gmtime(int(wall(t) // 1))


def iso_s(t):
    """2026-09-29T18:28:18Z  (alert created_at/start_at, decision times)"""
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', _gm(t))


def iso_ms(t):
    """2026-09-29T18:11:15.464Z  (allowlists)"""
    return '%s.%03dZ' % (time.strftime('%Y-%m-%dT%H:%M:%S', _gm(t)), int((wall(t) % 1) * 1000))


def iso_ns(t, salt=0):
    """RFC3339Nano like Go prints it (trailing zeros trimmed): 2026-09-29T18:10:33.20412817Z.
    A float only carries ~6 significant sub-second digits, the last three are a stable pseudo-random tail."""
    w = wall(t)
    frac = int((w % 1) * 1000000)
    ns = frac * 1000 + (int(t * 7919 + salt * 104729) % 1000)
    s = time.strftime('%Y-%m-%dT%H:%M:%S', _gm(t))
    f = ('%09d' % ns).rstrip('0')
    return '%s.%sZ' % (s, f) if f else s + 'Z'


def go_time(t, ns_tail=0):
    """2026-09-29 18:26:57.349196373 +0000 UTC  (Go's Time.String(), used in alert events and messages)"""
    frac = int((wall(t) % 1) * 1000000) * 1000 + (ns_tail % 1000)
    f = ('%09d' % frac).rstrip('0')
    return '%s%s +0000 UTC' % (time.strftime('%Y-%m-%d %H:%M:%S', _gm(t)), '.' + f if f else '')


def go_dur(sec):
    """Go's time.Duration.String() for a whole number of seconds: 3h59m47s, 1h0m0s, 45s, 0s, -2m2s."""
    sec = int(sec)
    if sec == 0:
        return '0s'
    neg = sec < 0
    sec = abs(sec)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    if h:
        r = '%dh%dm%ds' % (h, m, s)
    elif m:
        r = '%dm%ds' % (m, s)
    else:
        r = '%ds' % s
    return '-' + r if neg else r


def go_dur_frac(d):
    """Go's Duration.String() for a float number of seconds with sub-second precision (1.121873ms, 22.183783028s)."""
    if d == 0:
        return '0s'
    neg = d < 0
    d = abs(d)
    if d < 1e-6:
        r = '%dns' % round(d * 1e9)
    elif d < 1e-3:
        r = _trim('%.3f' % (d * 1e6)) + '\u00b5s'
    elif d < 1:
        r = _trim('%.6f' % (d * 1e3)) + 'ms'
    else:
        tot = round(d * 1e9)
        secs, nano = divmod(tot, 10 ** 9)
        h, rem = divmod(secs, 3600)
        m, s = divmod(rem, 60)
        ss = _trim('%d.%09d' % (s, nano))
        if h:
            r = '%dh%dm%ss' % (h, m, ss)
        elif m:
            r = '%dm%ss' % (m, ss)
        else:
            r = ss + 's'
    return '-' + r if neg else r


def _trim(x):
    if '.' in x:
        x = x.rstrip('0').rstrip('.')
    return x


_UNITS = {'ns': 1e-9, 'us': 1e-6, '\u00b5s': 1e-6, '\u03bcs': 1e-6, 'ms': 1e-3, 's': 1.0, 'm': 60.0, 'h': 3600.0}


def parse_dur(s, days=True):
    """Go time.ParseDuration (plus CrowdSec's `d` unit when days=True). Returns (seconds, None) or (None, error text)."""
    orig = s
    if s == '':
        return None, 'empty duration string'      # what CrowdSec's own parser says (Go's says: invalid duration "")
    neg = False
    if s[0] in '+-':
        neg = s[0] == '-'
        s = s[1:]
    if s == '0':
        return 0.0, None
    if s == '':
        return None, 'time: invalid duration "%s"' % orig
    total = 0.0
    while s:
        m = re.match(r'[0-9]*\.?[0-9]*', s)
        num = m.group(0)
        if num in ('', '.'):
            return None, 'time: invalid duration "%s"' % orig
        s = s[len(num):]
        m = re.match(r'[^0-9.]*', s)
        unit = m.group(0)
        if unit == '':
            return None, 'time: missing unit in duration "%s"' % orig
        s = s[len(unit):]
        if unit == 'd' and days:
            mult = 86400.0
        elif unit in _UNITS:
            mult = _UNITS[unit]
        else:
            return None, 'time: unknown unit "%s" in duration "%s"' % (unit, orig)
        total += float(num) * mult
    return (-total if neg else total), None


def human_dur(sec):
    """docker's units.HumanDuration: 'Less than a second', '17 minutes', 'About an hour', '3 days'."""
    sec = int(sec)
    if sec < 1:
        return 'Less than a second'
    if sec == 1:
        return '1 second'
    if sec < 60:
        return '%d seconds' % sec
    minutes = sec // 60
    if minutes == 1:
        return 'About a minute'
    if minutes < 60:
        return '%d minutes' % minutes
    hours = int(sec / 3600.0 + 0.5)
    if hours == 1:
        return 'About an hour'
    if hours < 48:
        return '%d hours' % hours
    if hours < 24 * 7 * 2:
        return '%d days' % (hours // 24)
    if hours < 24 * 30 * 2:
        return '%d weeks' % (hours // 24 // 7)
    if hours < 24 * 365 * 2:
        return '%d months' % (hours // 24 // 30)
    return '%d years' % (sec // 3600 // 24 // 365)


# --------------------------------------------------------------------------------------------------
# JSON the way Go's encoding/json prints it
# --------------------------------------------------------------------------------------------------
def gojson(obj, indent=1, sort_keys=False):
    """json.MarshalIndent(obj, "", " "*indent): keys keep insertion order (callers build them in Go's order; Go maps
    are sorted, use sort_keys for those), non-ASCII stays as is, and <, >, & (and U+2028/9) are escaped like Go does."""
    s = json.dumps(obj, indent=indent, ensure_ascii=False, separators=(',', ': '), sort_keys=sort_keys)
    return (s.replace('&', '\\u0026').replace('<', '\\u003c').replace('>', '\\u003e')
            .replace('\u2028', '\\u2028').replace('\u2029', '\\u2029'))


def gojson_compact(obj):
    s = json.dumps(obj, ensure_ascii=False, separators=(',', ':'))
    return (s.replace('&', '\\u0026').replace('<', '\\u003c').replace('>', '\\u003e')
            .replace('\u2028', '\\u2028').replace('\u2029', '\\u2029'))


# --------------------------------------------------------------------------------------------------
# deterministic generator (ids, uuids, API keys); state["rng"] is the counter
# --------------------------------------------------------------------------------------------------
_M64 = (1 << 64) - 1


class Rng(object):
    """splitmix64: tiny, deterministic, good enough for fake uuids and keys."""

    def __init__(self, st):
        self.st = st

    def next64(self):
        r = self.st.setdefault('rng', {'seed': 1, 'n': 0})
        r['n'] += 1
        z = (r['seed'] * 0x9E3779B97F4A7C15 + r['n'] * 0xBF58476D1CE4E5B9) & _M64
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & _M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & _M64
        return z ^ (z >> 31)

    def bytes(self, n):
        b = b''
        while len(b) < n:
            b += self.next64().to_bytes(8, 'big')
        return b[:n]

    def hexstr(self, n):
        return ''.join('%02x' % c for c in self.bytes((n + 1) // 2))[:n]

    def uuid(self):
        b = bytearray(self.bytes(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        h = ''.join('%02x' % c for c in b)
        return '%s-%s-%s-%s-%s' % (h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])

    def apikey(self):
        """cscli bouncers add: 32 random bytes, base64.RawStdEncoding (43 chars, may contain + and /)."""
        return base64.b64encode(self.bytes(32)).decode('ascii').rstrip('=')

    def randint(self, lo, hi):
        return lo + self.next64() % (hi - lo + 1)

    def choice(self, seq):
        return seq[self.next64() % len(seq)]


# --------------------------------------------------------------------------------------------------
# network helpers
# --------------------------------------------------------------------------------------------------
_ipaddress = []


def ipmod():
    if not _ipaddress:
        import ipaddress
        _ipaddress.append(ipaddress)
    return _ipaddress[0]


def parse_ip(s):
    """-> ip_address or None (Go's net.ParseIP: no zones, no whitespace)."""
    if not s or s != s.strip() or '%' in s:
        return None
    try:
        return ipmod().ip_address(s)
    except ValueError:
        return None


def parse_cidr(s):
    """-> ip_network (strict=False like net.ParseCIDR keeps host bits) or None. A bare address is not a CIDR."""
    if not s or '/' not in s or s != s.strip():
        return None
    try:
        return ipmod().ip_network(s, strict=False)
    except ValueError:
        return None


def span(value):
    """(family_bits, first, last) of an IP or CIDR string, or None."""
    ip = parse_ip(value)
    if ip is not None:
        n = int(ip)
        return (ip.max_prefixlen, n, n)
    net = parse_cidr(value)
    if net is not None:
        return (net.max_prefixlen, int(net.network_address), int(net.broadcast_address))
    return None


def overlaps(a, b):
    """do two IP/CIDR strings share any address?"""
    x, y = span(a), span(b)
    return bool(x and y and x[0] == y[0] and x[1] <= y[2] and y[1] <= x[2])


def contains(outer, inner):
    x, y = span(outer), span(inner)
    return bool(x and y and x[0] == y[0] and x[1] <= y[1] and y[2] <= x[2])


def lev(a, b):
    """Levenshtein distance (cscli's 'did you mean' suggestions)."""
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def version_tuple(v):
    m = re.match(r'v?(\d+)\.(\d+)(?:\.(\d+))?', v or '')
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)) if m else (1, 8, 1)


def pad(s, w):
    return s + ' ' * (w - len(s)) if len(s) < w else s


# ==================================================================================================
# A small YAML reader: block/flow collections, quoted+plain scalars, |/> block scalars, multi-document
# streams, goccy-style "[line:col] message" errors (what CrowdSec prints for a broken profiles.yaml).
# Enough for profiles.yaml, notification plugin configs, simulation.yaml, acquis files and config.yaml;
# it is not a general YAML implementation (no anchors, tags, complex keys or multi-line quoted scalars).
# ==================================================================================================
class YamlError(Exception):
    def __init__(self, msg, line, col):
        Exception.__init__(self, msg)
        self.msg, self.line, self.col = msg, line, col

    def __str__(self):
        return '[%d:%d] %s' % (self.line, self.col, self.msg)


class YMap(dict):
    """a YAML mapping (insertion ordered)"""


def _resolve(tok):
    """type resolution of a plain scalar (YAML 1.2 core schema, like yaml.v3: yes/no are strings)"""
    if tok in ('~', 'null', 'Null', 'NULL', ''):
        return None
    if tok in ('true', 'True', 'TRUE'):
        return True
    if tok in ('false', 'False', 'FALSE'):
        return False
    if re.match(r'^[-+]?[0-9]+$', tok):
        return int(tok)
    if re.match(r'^0x[0-9a-fA-F]+$', tok):
        return int(tok, 16)
    if re.match(r'^[-+]?([0-9]+\.[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$', tok) or re.match(r'^[-+]?[0-9]+[eE][-+]?[0-9]+$', tok):
        return float(tok)
    return tok


def _strip_comment(s):
    """cut a trailing ' # comment' that is not inside quotes"""
    q = None
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if q:
            if c == '\\' and q == '"':
                i += 2
                continue
            if c == q:
                q = None
        elif c in '"\'' and (i == 0 or s[i - 1] in ' \t[{,:'):
            q = c
        elif c == '#' and (i == 0 or s[i - 1] in ' \t'):
            return s[:i].rstrip()
        i += 1
    return s.rstrip()


def _unquote(s, no, col):
    """parse the quoted scalar at the start of s -> (value, characters consumed); col = 0-based column of s[0]"""
    q = s[0]
    j = 1
    buf = []
    esc = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0', '"': '"', '\\': '\\', '/': '/', ' ': ' ', 'e': '\x1b',
           'a': '\a', 'b': '\b', 'f': '\f', 'v': '\v'}
    while j < len(s):
        c = s[j]
        if q == '"' and c == '\\' and j + 1 < len(s):
            e = s[j + 1]
            if e in esc:
                buf.append(esc[e])
                j += 2
                continue
            if e in 'xuU':
                ln = {'x': 2, 'u': 4, 'U': 8}[e]
                try:
                    buf.append(chr(int(s[j + 2:j + 2 + ln], 16)))
                except ValueError:
                    raise YamlError('invalid escape sequence', no, col + j + 1)
                j += 2 + ln
                continue
            raise YamlError('invalid escape sequence', no, col + j + 1)
        if c == q:
            if q == "'" and s[j + 1:j + 2] == "'":
                buf.append("'")
                j += 2
                continue
            return ''.join(buf), j + 1
        buf.append(c)
        j += 1
    raise YamlError('could not find end character of %s-quoted text' % ('double' if q == '"' else 'single'), no, col + 1)


_KEY_RE = re.compile(r'''^(?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s#\[\]{},&*!|>'"%@`:-][^:]*?|-[^\s:][^:]*?)\s*:(?:\s+|$)''')


def _key_line(content):
    """does `content` look like `key: value` / `key:`? -> (key, rest_after_colon, chars_consumed) or None"""
    m = _KEY_RE.match(content)
    if not m:
        return None
    raw = m.group(0)
    body = raw.rstrip()
    body = body[:-1].rstrip()          # drop the colon
    if body[:1] in '"\'':
        key = _unquote(body, 0, 0)[0]
    else:
        key = body
    return key, content[m.end():], m.end()


class _Reader(object):
    def __init__(self, lines):
        self.lines = lines             # [(lineno, text)]
        self.i = 0

    def peek(self):
        """next content line without consuming it -> (lineno, indent, text) or None"""
        while self.i < len(self.lines):
            no, raw = self.lines[self.i]
            s = raw.strip()
            if s == '' or s.startswith('#'):
                self.i += 1
                continue
            m = re.match(r'^( *)\t', raw)
            if m:
                raise YamlError("found character '\\t' that cannot start any token", no, len(m.group(1)) + 1)
            ind = len(raw) - len(raw.lstrip(' '))
            return no, ind, raw[ind:]
        return None

    # -- nodes -------------------------------------------------------------------------------------
    def node(self, parent_indent):
        t = self.peek()
        if t is None:
            return None
        no, ind, content = t
        if ind <= parent_indent:
            return None
        if content.startswith('- ') or content == '-':
            return self.seq(ind)
        if _key_line(_strip_comment(content)):
            return self.mapping(ind)
        return self.value(no, ind, _strip_comment(content), parent_indent, False)

    def seq(self, indent):
        res = []
        while True:
            t = self.peek()
            if t is None:
                break
            no, ind, content = t
            if ind != indent:
                if ind > indent:
                    raise YamlError('value is not allowed in this context', no, ind + 1)
                break
            if not (content.startswith('- ') or content == '-'):
                break
            rest = content[1:]
            stripped = rest.lstrip(' ')
            col = indent + 1 + (len(rest) - len(stripped))
            sc = _strip_comment(stripped)
            if sc == '':
                self.i += 1
                res.append(self.node(indent))
            elif sc.startswith('- ') or sc == '-':
                self.lines[self.i] = (no, ' ' * col + stripped)
                res.append(self.seq(col))
            elif _key_line(sc):
                self.lines[self.i] = (no, ' ' * col + stripped)
                res.append(self.mapping(col))
            else:
                res.append(self.value(no, col, sc, indent, False))
        return res

    def mapping(self, indent):
        res = YMap()
        seen = {}
        while True:
            t = self.peek()
            if t is None:
                break
            no, ind, content = t
            if ind != indent:
                if ind > indent:
                    raise YamlError('value is not allowed in this context', no, ind + 1)
                break
            if content.startswith('- ') or content == '-':
                break
            sc = _strip_comment(content)
            kv = _key_line(sc)
            if not kv:
                raise YamlError('value is not allowed in this context', no, ind + 1)
            key, rest, used = kv
            if key in res:
                raise YamlError('mapping key "%s" already defined at [%d:%d]' % (key, seen[key][0], seen[key][1]), no, ind + 1)
            seen[key] = (no, ind + 1)
            rest = rest.strip()
            if rest == '':
                self.i += 1
                t2 = self.peek()
                if t2 is not None and t2[1] == indent and (t2[2].startswith('- ') or t2[2] == '-'):
                    res[key] = self.seq(indent)      # `key:` followed by a sequence at the same indent
                else:
                    res[key] = self.node(indent)
            elif rest[0] in '|>' and re.match(r'^[|>][-+0-9]*$', rest):
                self.i += 1
                res[key] = self.blockscalar(rest, indent)
            else:
                res[key] = self.value(no, ind + used, rest, indent, True)
        return res

    def value(self, no, col, text, parent_indent, is_key_value):
        """inline value on the current line (col = 0-based column of `text`): quoted, flow, or plain scalar"""
        c0 = text[0] if text else ''
        if c0 in '"\'':
            val, used = _unquote(text, no, col)
            rest = text[used:].strip()
            if rest:
                raise YamlError('mapping value is not allowed in this context' if rest.startswith(':') else 'value is not allowed in this context', no, col + 1 + used)
            self.i += 1
            return val
        if c0 in '[{':
            return self.flow(no, col, text)
        if is_key_value and re.search(r':(\s|$)', text):
            raise YamlError('mapping value is not allowed in this context', no, col + 1)
        self.i += 1
        # folded plain scalar: following lines that are indented deeper than the key
        parts = [text]
        while self.i < len(self.lines):
            raw2 = self.lines[self.i][1]
            s2 = raw2.strip()
            if s2 == '' or s2.startswith('#'):
                break
            ind2 = len(raw2) - len(raw2.lstrip(' '))
            if ind2 <= parent_indent or _key_line(_strip_comment(s2)) or s2.startswith('- '):
                break
            parts.append(_strip_comment(s2))
            self.i += 1
        return _resolve(' '.join(parts)) if len(parts) == 1 else ' '.join(parts)

    def flow(self, no, col, text):
        """[..] / {..}, possibly spanning several lines"""
        segs = [(no, col, text)]
        j = self.i + 1
        while True:
            buf = '\n'.join(s[2] for s in segs)
            try:
                val, _used = _flow_node(buf, 0, segs)
                break
            except _NeedMore:
                if j >= len(self.lines):
                    lno, _raw = self.lines[-1]
                    raise YamlError("',' or '%s' must be specified" % (']' if text[0] == '[' else '}'), lno, 1)
                nno, nraw = self.lines[j]
                segs.append((nno, 0, _strip_comment(nraw)))
                j += 1
        self.i += len(segs)
        return val

    def blockscalar(self, header, indent):
        """| and > scalars (clip/strip/keep chomping); self.i already points at the first body line"""
        chomp = 'strip' if '-' in header else ('keep' if '+' in header else 'clip')
        body = []
        base = None
        while self.i < len(self.lines):
            raw = self.lines[self.i][1]
            if raw.strip() == '':
                body.append('')
                self.i += 1
                continue
            ind = len(raw) - len(raw.lstrip(' '))
            if ind <= indent:
                break
            if base is None:
                base = ind
            body.append(raw[base:] if ind >= base else raw.lstrip(' '))
            self.i += 1
        trailing = 0
        while body and body[-1] == '':
            body.pop()
            trailing += 1
        if header[0] == '|':
            text = '\n'.join(body)
        else:
            text = ''
            for k, ln in enumerate(body):
                if k:
                    text += ' ' if (ln != '' and body[k - 1] != '') else ('\n' if ln == '' else '')
                text += ln
        if body and chomp != 'strip':
            text += '\n'
            if chomp == 'keep':
                text += '\n' * trailing
        return text


class _NeedMore(Exception):
    pass


def _flow_node(buf, pos, segs):
    """parse one flow node of `buf` starting at pos -> (value, end_pos); raises _NeedMore if the text ends early"""
    n = len(buf)

    def where(i):
        off = 0
        for no, col, txt in segs:
            if i <= off + len(txt):
                return no, col + (i - off) + 1
            off += len(txt) + 1
        return segs[-1][0], 1

    def skip(i):
        while i < n and buf[i] in ' \t\n':
            i += 1
        return i

    def parse(i):
        i = skip(i)
        if i >= n:
            raise _NeedMore()
        c = buf[i]
        if c == '[':
            arr = []
            i += 1
            while True:
                i = skip(i)
                if i >= n:
                    raise _NeedMore()
                if buf[i] == ']':
                    return arr, i + 1
                v, i = parse(i)
                arr.append(v)
                i = skip(i)
                if i >= n:
                    raise _NeedMore()
                if buf[i] == ',':
                    i += 1
                elif buf[i] == ']':
                    return arr, i + 1
                else:
                    ln, cl = where(i)
                    raise YamlError("',' or ']' must be specified", ln, cl)
        if c == '{':
            m = YMap()
            i += 1
            while True:
                i = skip(i)
                if i >= n:
                    raise _NeedMore()
                if buf[i] == '}':
                    return m, i + 1
                k, i = parse(i)
                i = skip(i)
                if i >= n:
                    raise _NeedMore()
                if buf[i] != ':':
                    ln, cl = where(i)
                    raise YamlError("',' or '}' must be specified", ln, cl)
                v, i = parse(i + 1)
                m[k] = v
                i = skip(i)
                if i >= n:
                    raise _NeedMore()
                if buf[i] == ',':
                    i += 1
                elif buf[i] == '}':
                    return m, i + 1
                else:
                    ln, cl = where(i)
                    raise YamlError("',' or '}' must be specified", ln, cl)
        if c in '"\'':
            ln, cl = where(i)
            s, used = _unquote(buf[i:], ln, cl - 1)
            return s, i + used
        j = i
        while j < n and buf[j] not in ',]}\n' and not (buf[j] == ':' and (j + 1 >= n or buf[j + 1] in ' \n,]}')):
            j += 1
        return _resolve(buf[i:j].strip()), j

    return parse(pos)


def yaml_load_all(text):
    """-> list of documents (a document is a YMap, list, scalar or None). Raises YamlError.
    The line numbers in errors are those of the whole stream."""
    lines = text.replace('\r\n', '\n').split('\n')
    docs, cur = [], []
    for i, ln in enumerate(lines, 1):
        if ln.startswith('---') and (len(ln) == 3 or ln[3] in ' \t'):
            docs.append(cur)
            cur = []
            rest = ln[3:].strip()
            if rest and not rest.startswith('#'):
                cur.append((i, rest))
            continue
        if ln.rstrip() == '...':
            docs.append(cur)
            cur = []
            continue
        cur.append((i, ln))
    docs.append(cur)
    res = []
    for k, d in enumerate(docs):
        has = any(x[1].strip() and not x[1].lstrip().startswith('#') for x in d)
        if not has and (k > 0 or len(docs) > 1):
            continue                       # a leading/trailing/empty document (e.g. the text before a first ---)
        res.append(_load_doc(d))
    return res


def _load_doc(d):
    rd = _Reader(d)
    node = rd.node(-1)
    rd.peek()
    if rd.i < len(rd.lines):
        no, raw = rd.lines[rd.i]
        raise YamlError('value is not allowed in this context', no, len(raw) - len(raw.lstrip(' ')) + 1)
    return node


def yaml_load(text):
    docs = yaml_load_all(text)
    return docs[0] if docs else None


# --------------------------------------------------------------------------------------------------
# the writer for the file this mock rewrites (simulation.yaml, as yaml.v3 marshals it)
# --------------------------------------------------------------------------------------------------
def simulation_yaml(sim, exclusions):
    s = 'simulation: %s\n' % ('true' if sim else 'false')
    if exclusions:
        s += 'exclusions:\n' + ''.join('    - %s\n' % e for e in exclusions)
    return s


# ==================================================================================================
# expr-lang (the language of profile filters and duration_expr): tokenizer + syntax check that reproduces
# the compile errors CrowdSec prints:  unexpected token Operator("=") (1:21) / | source / | ....^
# ==================================================================================================
class ExprError(Exception):
    def __init__(self, msg, col=None):
        Exception.__init__(self, msg)
        self.msg, self.col = msg, col


_EXPR_KEYWORDS = ('and', 'or', 'not', 'in', 'matches', 'contains', 'startsWith', 'endsWith')
_EXPR_OPS3 = ('...',)
_EXPR_OPS2 = ('==', '!=', '<=', '>=', '&&', '||', '??', '**', '..', '?.', '=>', '|>')
_EXPR_OPS1 = '+-*/%<>!?:,.|&^~=#@;'
_ALERT_FIELDS = ('Capacity', 'CreatedAt', 'Decisions', 'Events', 'EventsCount', 'ID', 'Labels', 'Leakspeed', 'MachineID',
                 'Message', 'Meta', 'Remediation', 'Scenario', 'ScenarioHash', 'ScenarioVersion', 'Simulated', 'Source',
                 'StartAt', 'StopAt', 'UUID')


def expr_tokens(src):
    toks = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in ' \t\r\n':
            i += 1
        elif c.isdigit() or (c == '.' and i + 1 < n and src[i + 1].isdigit()):
            m = re.match(r'0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(?:\.[0-9_]*)?(?:[eE][-+]?[0-9_]+)?|\.[0-9_]+(?:[eE][-+]?[0-9_]+)?', src[i:])
            t = m.group(0)
            if t.endswith('.') and src[i + len(t):i + len(t) + 1] == '.':      # `1..3` is a range
                t = t[:-1]
            toks.append(('Number', t, i + 1))
            i += len(t)
        elif c in '"\'':
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == '\\' else 1
            if j >= n:
                raise ExprError('literal not terminated', n + 1)
            toks.append(('String', src[i + 1:j], i + 1))
            i = j + 1
        elif c == '`':
            j = src.find('`', i + 1)
            if j < 0:
                raise ExprError('literal not terminated', n + 1)
            toks.append(('String', src[i + 1:j], i + 1))
            i = j + 1
        elif c.isalpha() or c in '_$':
            m = re.match(r'[A-Za-z_$][A-Za-z0-9_$]*', src[i:])
            t = m.group(0)
            toks.append(('Operator' if t in _EXPR_KEYWORDS else 'Identifier', t, i + 1))
            i += len(t)
        elif c in '()[]{}':
            toks.append(('Bracket', c, i + 1))
            i += 1
        elif src[i:i + 3] in _EXPR_OPS3:
            toks.append(('Operator', src[i:i + 3], i + 1))
            i += 3
        elif src[i:i + 2] in _EXPR_OPS2:
            toks.append(('Operator', src[i:i + 2], i + 1))
            i += 2
        elif c in _EXPR_OPS1:
            toks.append(('Operator', c, i + 1))
            i += 1
        else:
            raise ExprError('unrecognized character: U+%04X %r' % (ord(c), c), i + 1)
    toks.append(('EOF', '', n if n else 0))
    return toks


_BIN_PREC = {'or': 10, '||': 10, 'and': 15, '&&': 15, '|': 16, '^': 17, '&': 18, '==': 20, '!=': 20, '<': 20, '>': 20,
             '<=': 20, '>=': 20, 'in': 20, 'matches': 20, 'contains': 20, 'startsWith': 20, 'endsWith': 20, '..': 25,
             '+': 30, '-': 30, '*': 60, '/': 60, '%': 60, '**': 100, '??': 500}


class _ExprParser(object):
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def cur(self):
        return self.t[self.i]

    def bad(self, tok=None):
        tok = tok or self.cur()
        if tok[0] == 'EOF':
            raise ExprError('unexpected token EOF', tok[2] if tok[2] else None)
        raise ExprError('unexpected token %s(%s)' % (tok[0], json.dumps(tok[1], ensure_ascii=False)), tok[2])

    def eat(self, typ, val):
        t = self.cur()
        if t[0] == typ and t[1] == val:
            self.i += 1
            return True
        return False

    def expect(self, typ, val):
        if not self.eat(typ, val):
            self.bad()

    def parse(self):
        self.expr()
        if self.cur()[0] != 'EOF':
            self.bad()

    def expr(self):
        self.binary(0)
        if self.eat('Operator', '?'):
            self.expr()
            self.expect('Operator', ':')
            self.expr()

    def binary(self, minprec):
        self.unary()
        while True:
            t = self.cur()
            op = t[1]
            if t[0] != 'Operator':
                break
            if op == 'not' and self.t[self.i + 1][1] == 'in':
                self.i += 1
                op = 'in'
            prec = _BIN_PREC.get(op)
            if prec is None or prec < minprec:
                break
            self.i += 1
            self.binary(prec if op == '**' else prec + 1)

    def unary(self):
        t = self.cur()
        if t[0] == 'Operator' and t[1] in ('!', 'not', '-', '+'):
            self.i += 1
            self.unary()
            return
        self.postfix(self.atom())

    def atom(self):
        t = self.cur()
        typ, val = t[0], t[1]
        if typ in ('Number', 'String', 'Identifier'):
            self.i += 1
            return t
        if typ == 'Bracket' and val == '(':
            self.i += 1
            self.expr()
            self.expect('Bracket', ')')
            return t
        if typ == 'Bracket' and val == '[':
            self.i += 1
            if not self.eat('Bracket', ']'):
                while True:
                    self.expr()
                    if self.eat('Operator', ','):
                        if self.eat('Bracket', ']'):
                            break
                        continue
                    self.expect('Bracket', ']')
                    break
            return t
        if typ == 'Bracket' and val == '{':
            self.i += 1
            if not self.eat('Bracket', '}'):
                while True:
                    self.expr()
                    self.expect('Operator', ':')
                    self.expr()
                    if self.eat('Operator', ','):
                        if self.eat('Bracket', '}'):
                            break
                        continue
                    self.expect('Bracket', '}')
                    break
            return t
        if typ == 'Operator' and val in ('#', '.'):
            self.i += 1
            return t
        self.bad()

    def postfix(self, base):
        while True:
            t = self.cur()
            if t[0] == 'Operator' and t[1] in ('.', '?.'):
                self.i += 1
                nxt = self.cur()
                if nxt[0] != 'Identifier' and not (nxt[0] == 'Operator' and nxt[1] in _EXPR_KEYWORDS):
                    if nxt[0] == 'Bracket' and nxt[1] == '[':
                        continue
                    self.bad()
                self.i += 1
                if base[0] == 'Identifier' and base[1] == 'Alert' and nxt[0] == 'Identifier':
                    fld = nxt[1]
                    if not fld.startswith('Get') and fld not in _ALERT_FIELDS:
                        raise ExprError('type models.Alert has no field %s' % fld, nxt[2])
                    base = ('Field', fld, nxt[2])
                else:
                    base = ('Field', nxt[1], nxt[2])
            elif t[0] == 'Bracket' and t[1] == '[':
                self.i += 1
                if not self.eat('Operator', ':'):
                    self.expr()
                if self.eat('Operator', ':'):
                    if not (self.cur()[0] == 'Bracket' and self.cur()[1] == ']'):
                        self.expr()
                self.expect('Bracket', ']')
                base = ('Index', '', t[2])
            elif t[0] == 'Bracket' and t[1] == '(':
                self.i += 1
                if not self.eat('Bracket', ')'):
                    while True:
                        self.expr()
                        if self.eat('Operator', ','):
                            continue
                        self.expect('Bracket', ')')
                        break
                base = ('Call', '', t[2])
            else:
                return


def expr_check(src):
    """-> None if the expression compiles, else the error text CrowdSec prints (message, position, source excerpt)"""
    if src.strip() == '':
        return 'unexpected token EOF'
    try:
        _ExprParser(expr_tokens(src)).parse()
    except ExprError as e:
        if e.col is None:
            return e.msg
        return '%s (1:%d)\n | %s\n | %s^' % (e.msg, e.col, src, '.' * (e.col - 1))
    return None


# --------------------------------------------------------------------------------------------------
# Go text/template check for notification plugin `format:` (unknown functions, unbalanced blocks)
# --------------------------------------------------------------------------------------------------
_TMPL_BUILTINS = ('and', 'call', 'html', 'index', 'slice', 'js', 'len', 'not', 'or', 'print', 'printf', 'println',
                  'urlquery', 'eq', 'ge', 'gt', 'le', 'lt', 'ne')
_TMPL_KEYWORDS = ('if', 'else', 'end', 'range', 'with', 'define', 'template', 'block', 'break', 'continue', 'nil',
                  'true', 'false')
_SPRIG = ('abbrev abbrevboth add add1 add1f addf adler32sum ago all any append atoi b32dec b32enc b64dec b64enc base '
          'biggest bcrypt buildCustomCert camelcase cat ceil chunk clean coalesce compact concat contains date dateInZone '
          'dateModify date_in_zone date_modify decryptAES deepCopy deepEqual default derivePassword dict dig dir div divf '
          'duration durationRound empty encryptAES env expandenv ext fail first float64 floor fromJson genCA genCAWithKey '
          'genPrivateKey genSelfSignedCert genSelfSignedCertWithKey genSignedCert genSignedCertWithKey get getHostByName '
          'has hasKey hasPrefix hasSuffix htmlDate htmlDateInZone htpasswd indent initial initials int int64 isAbs '
          'join kebabcase keys kindIs kindOf last list lower max maxf merge mergeOverwrite min minf mod mul mulf '
          'mustAppend mustChunk mustCompact mustDeepCopy mustFirst mustFromJson mustHas mustInitial mustLast mustMerge '
          'mustMergeOverwrite mustPrepend mustPush mustRegexFind mustRegexFindAll mustRegexMatch mustRegexReplaceAll '
          'mustRegexReplaceAllLiteral mustRegexSplit mustRest mustReverse mustSlice mustToDate mustToJson '
          'mustToPrettyJson mustToRawJson mustUniq mustWithout nindent nospace omit osBase osClean osDir osExt osIsAbs '
          'pick pluck plural prepend push quote randAlpha randAlphaNum randAscii randBytes randInt randNumeric '
          'regexFind regexFindAll regexMatch regexQuoteMeta regexReplaceAll regexReplaceAllLiteral regexSplit repeat '
          'replace rest reverse round semver semverCompare seq set sha1sum sha256sum sha512sum shuffle slice snakecase '
          'sortAlpha split splitList splitn squote sub subf substr swapcase ternary title toDate toDecimal toJson '
          'toPrettyJson toRawJson toString toStrings trim trimAll trimPrefix trimSuffix trimall trunc tuple typeIs '
          'typeIsLike typeOf uniq unixEpoch unset until untilStep untitle upper urlJoin urlParse uuidv4 values wrap '
          'wrapWith without now')
_TMPL_FUNCS = frozenset(_TMPL_BUILTINS) | frozenset(_SPRIG.split())


def tmpl_check(text):
    """-> None or 'template: :LINE: message' as the notification plugin's Go template parser reports it"""
    stack = []
    pos = 0
    n = len(text)
    while True:
        i = text.find('{{', pos)
        if i < 0:
            break
        j = text.find('}}', i + 2)
        line = text.count('\n', 0, i) + 1
        if j < 0:
            return 'template: :%d: unclosed action' % line
        body = text[i + 2:j]
        pos = j + 2
        b = body.strip()
        if b.startswith('-'):
            b = b[1:].strip()
        if b.endswith('-'):
            b = b[:-1].strip()
        if b.startswith('/*'):
            k = text.find('*/', i)
            if k < 0:
                return 'template: :%d: unclosed comment' % line
            e = text.find('}}', k)
            pos = e + 2 if e >= 0 else n
            continue
        masked = re.sub(r'"(?:[^"\\]|\\.)*"|`[^`]*`|\'(?:[^\'\\]|\\.)*\'', lambda m: re.sub(r'[^\n]', ' ', m.group(0)), body)
        first = b.split(None, 1)[0] if b else ''
        if first == 'end':
            if not stack:
                return 'template: :%d: unexpected {{end}}' % line
            stack.pop()
        elif first == 'else':
            if not stack:
                return 'template: :%d: unexpected {{else}}' % line
        elif first in ('if', 'range', 'with', 'define', 'block'):
            stack.append(first)
        for m in re.finditer(r'(?<![\w.$])([A-Za-z_][A-Za-z0-9_]*)', masked):
            name = m.group(1)
            if name in _TMPL_KEYWORDS or name in _TMPL_FUNCS:
                continue
            ln = text.count('\n', 0, i + 2 + m.start()) + 1
            return 'template: :%d: function "%s" not defined' % (ln, name)
    if stack:
        return 'template: :%d: unexpected EOF' % (text.count('\n') + 1)
    return None


# --------------------------------------------------------------------------------------------------
# profiles.yaml validation: what `crowdsec -t` (LAPI init) says about it
# --------------------------------------------------------------------------------------------------
_PROFILE_KEYS = ('name', 'debug', 'filters', 'decisions', 'duration_expr', 'notifications', 'on_success', 'on_failure',
                 'on_error')
_DECISION_KEYS = ('duration', 'id', 'origin', 'scenario', 'scope', 'simulated', 'type', 'until', 'value')


def _ytype(v):
    if isinstance(v, bool):
        return '!!bool'
    if isinstance(v, int):
        return '!!int'
    if isinstance(v, float):
        return '!!float'
    if isinstance(v, dict):
        return '!!map'
    if isinstance(v, list):
        return '!!seq'
    return '!!str'


def _yscalar_text(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    return str(v)


def _yshort(v):
    s = _yscalar_text(v)
    return s if len(s) <= 10 else s[:7] + '...'          # yaml.v3 shortens long values like this


def _marshal_lines(node, out_lines, path):
    """what goccy prints for a document with SORTED keys (CrowdSec re-marshals the profile before decoding it
    strictly, so the 'line N' of an unmarshal error counts lines of that text, not of the file).
    out_lines gets (path_tuple,) for each emitted line."""
    def scalar_lines(v):
        if isinstance(v, str) and '\n' in v:
            return 1 + len(v.rstrip('\n').split('\n'))
        return 1

    def emit_map(m, base, first_on_dash=False):
        for k in sorted(m, key=lambda x: str(x)):
            v = m[k]
            p = base + (k,)
            if isinstance(v, dict) and v:
                out_lines.append(p)
                emit_map(v, p)
            elif isinstance(v, list) and v:
                out_lines.append(p)
                emit_seq(v, p)
            else:
                out_lines.append(p)
                for _ in range(scalar_lines(v) - 1):
                    out_lines.append(p + ('#',))

    def emit_seq(s, base):
        for idx, v in enumerate(s):
            p = base + (idx,)
            if isinstance(v, dict) and v:
                # `- k1: v1` then the other keys of the mapping, one line each (nested ones expand)
                emit_map(v, p)
            elif isinstance(v, list) and v:
                out_lines.append(p)
                emit_seq(v, p)
            else:
                out_lines.append(p)

    if isinstance(node, dict):
        emit_map(node, path)
    elif isinstance(node, list):
        emit_seq(node, path)
    else:
        out_lines.append(path)


def profiles_check(text, path, plugin_names):
    """-> (None, docs) when valid, else (fatal message text, None). docs = the profile mappings."""
    try:
        docs = yaml_load_all(text)
    except YamlError as e:
        return 'while loading profiles for LAPI: while decoding %s: %s' % (path, e), None
    profiles = []
    offset = 0
    for d in docs:
        if d is None:
            offset += 1
            continue
        lines = []
        _marshal_lines(d, lines, ())
        errs = []

        def lineno(p):
            return offset + (lines.index(p) + 1 if p in lines else 1)

        if not isinstance(d, dict):
            errs.append('line %d: cannot unmarshal %s `%s` into csconfig.ProfileCfg' % (offset + 1, _ytype(d), _yshort(d)))
        else:
            for key in sorted(d, key=str):
                v = d[key]
                if key not in _PROFILE_KEYS:
                    errs.append('line %d: field %s not found in type csconfig.ProfileCfg' % (lineno((key,)), key))
                    continue
                if key in ('name', 'duration_expr', 'on_success', 'on_failure', 'on_error'):
                    if isinstance(v, (dict, list)):
                        errs.append('line %d: cannot unmarshal %s into string' % (lineno((key,)), _ytype(v)))
                elif key == 'debug':
                    if v is not None and not isinstance(v, bool):
                        errs.append('line %d: cannot unmarshal %s `%s` into bool' % (lineno((key,)), _ytype(v), _yshort(v)))
                elif key in ('filters', 'notifications'):
                    if v is None:
                        continue
                    if not isinstance(v, list):
                        errs.append('line %d: cannot unmarshal %s `%s` into []string' % (lineno((key,)), _ytype(v), _yshort(v)))
                    else:
                        for idx, it in enumerate(v):
                            if isinstance(it, (dict, list)):
                                errs.append('line %d: cannot unmarshal %s into string' % (lineno((key, idx)), _ytype(it)))
                elif key == 'decisions':
                    if v is None:
                        continue
                    if not isinstance(v, list):
                        errs.append('line %d: cannot unmarshal %s `%s` into []*models.Decision' % (lineno((key,)), _ytype(v), _yshort(v)))
                        continue
                    for idx, it in enumerate(v):
                        if not isinstance(it, dict):
                            errs.append('line %d: cannot unmarshal %s `%s` into models.Decision' % (lineno((key, idx)), _ytype(it), _yshort(it)))
                            continue
                        for dk in sorted(it, key=str):
                            if dk not in _DECISION_KEYS:
                                errs.append('line %d: field %s not found in type models.Decision' % (lineno((key, idx, dk)), dk))
        if errs:
            return 'while loading profiles for LAPI: while decoding %s: yaml: unmarshal errors:\n  %s' % (path, '\n  '.join(errs)), None
        offset += len(lines) + 1
        profiles.append(d)
    if not profiles:
        return 'while loading profiles for LAPI: zero profiles loaded for LAPI', None
    pre = 'api server init: unable to run local API: controller init: failed to compile profiles: '
    for p in profiles:
        name = p.get('name')
        name = '' if name is None else _yscalar_text(name)
        os_ = p.get('on_success')
        if os_ not in (None, '', 'continue', 'break'):
            return pre + "invalid 'on_success' for '%s': %s" % (name, _yscalar_text(os_)), None
        of = p.get('on_failure')
        if of not in (None, '', 'continue', 'break', 'apply'):
            return pre + "invalid 'on_failure' for '%s' : %s" % (name, _yscalar_text(of)), None      # sic: real CrowdSec prints a space before the colon
        for flt in (p.get('filters') or []):
            e = expr_check(_yscalar_text(flt))
            if e:
                return pre + "error compiling filter of '%s': %s" % (name, e), None
        dexpr = p.get('duration_expr')
        if dexpr not in (None, ''):
            e = expr_check(_yscalar_text(dexpr))
            if e:
                return pre + 'error compiling duration_expr of %s: %s' % (name, e), None
        else:
            for dec in (p.get('decisions') or []):
                du = dec.get('duration')
                if du is None:
                    continue
                _sec, e = parse_dur(_yscalar_text(du))
                if e:
                    return pre + "error parsing duration '%s' of %s: %s" % (_yscalar_text(du), name, e), None
    for p in profiles:
        for nt in (p.get('notifications') or []):
            if _yscalar_text(nt) not in plugin_names:
                return 'api server init: plugin broker: loading config: config file for plugin %s not found' % _yscalar_text(nt), None
    return None, profiles


# ==================================================================================================
# files of a fresh crowdsecurity/crowdsec:1.8.1 container (captured from the real image)
# ==================================================================================================
STOCK_FILES = {
    '/etc/crowdsec/config.yaml': r'''common:
  log_media: stdout
  log_level: info
  log_dir: /var/log/
config_paths:
  config_dir: /etc/crowdsec/
  data_dir: /var/lib/crowdsec/data/
  simulation_path: /etc/crowdsec/simulation.yaml
  hub_dir: /etc/crowdsec/hub/
  index_path: /etc/crowdsec/hub/.index.json
  notification_dir: /etc/crowdsec/notifications/
  plugin_dir: /usr/local/lib/crowdsec/plugins/
crowdsec_service:
  acquisition_path: /etc/crowdsec/acquis.yaml
  acquisition_dir: /etc/crowdsec/acquis.d
  parser_routines: 1
plugin_config:
  user: nobody
  group: nobody
cscli:
  output: human
db_config:
  log_level: info
  type: sqlite
  db_path: /var/lib/crowdsec/data/crowdsec.db
  flush:
    max_items: 5000
    max_age: 7d
  use_wal: false
api:
  client:
    insecure_skip_verify: false
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
  server:
    log_level: info
    listen_uri: 0.0.0.0:8080
    profiles_path: /etc/crowdsec/profiles.yaml
    trusted_ips: # IP ranges, or IPs which can have admin API access
      - 127.0.0.1
      - ::1
    online_client: # Central API credentials (to push signals and receive bad IPs)
      credentials_path: /etc/crowdsec//online_api_credentials.yaml
    enable: true
prometheus:
  enabled: true
  level: full
  listen_addr: 0.0.0.0
  listen_port: 6060
''',
    '/etc/crowdsec/profiles.yaml': r'''name: default_ip_remediation
#debug: true
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
 - type: ban
   duration: 4h
#duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 4)
# notifications:
#   - slack_default  # Set the webhook in /etc/crowdsec/notifications/slack.yaml before enabling this.
#   - splunk_default # Set the splunk url and token in /etc/crowdsec/notifications/splunk.yaml before enabling this.
#   - http_default   # Set the required http parameters in /etc/crowdsec/notifications/http.yaml before enabling this.
#   - email_default  # Set the required email parameters in /etc/crowdsec/notifications/email.yaml before enabling this.
on_success: break
---
name: default_range_remediation
#debug: true
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Range"
decisions:
 - type: ban
   duration: 4h
#duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 4)
# notifications:
#   - slack_default  # Set the webhook in /etc/crowdsec/notifications/slack.yaml before enabling this.
#   - splunk_default # Set the splunk url and token in /etc/crowdsec/notifications/splunk.yaml before enabling this.
#   - http_default   # Set the required http parameters in /etc/crowdsec/notifications/http.yaml before enabling this.
#   - email_default  # Set the required email parameters in /etc/crowdsec/notifications/email.yaml before enabling this.
on_success: break
''',
    '/etc/crowdsec/simulation.yaml': r'''simulation: false
# exclusions:
#  - crowdsecurity/ssh-bf
''',
    '/etc/crowdsec/acquis.yaml': r'''{"source": "file", "filename": "/does/not/exist", "labels": {"type": "syslog"}}
''',
    '/etc/crowdsec/console.yaml': r'''share_manual_decisions: false
share_custom: true
share_tainted: true
share_context: false''',
    '/etc/crowdsec/dev.yaml': r'''common:
  log_media: stdout
  log_level: info
config_paths:
  config_dir: "$CONFIG_DIR"
  data_dir: "$DATA_DIR"
  notification_dir: "$CONFIG_DIR/notifications/"
  plugin_dir: "$PLUGINS_DIR"
  #simulation_path: /etc/crowdsec/config/simulation.yaml
  #hub_dir: /etc/crowdsec/hub/
  #index_path: ./config/hub/.index.json
crowdsec_service:
  acquisition_path: "$CONFIG_DIR/acquis.yaml"
  parser_routines: 1
plugin_config:
  user: "$USER"  # plugin process would be ran on behalf of this user
  group: "$USER" # plugin process would be ran on behalf of this group
cscli:
  output: human
db_config:
  type: sqlite
  db_path: "$DATA_DIR/crowdsec.db"
  user: root
  password: crowdsec
  db_name: crowdsec
  host: "172.17.0.2"
  port: 3306
  flush:
    #max_items: 10000
    #max_age: 168h
api:
  client:
    credentials_path: "$CONFIG_DIR/local_api_credentials.yaml"
  server:
    console_path: "$CONFIG_DIR/console.yaml"
    #insecure_skip_verify: true
    listen_uri: 127.0.0.1:8081
    profiles_path: "$CONFIG_DIR/profiles.yaml"
    tls:
      #cert_file: ./cert.pem
      #key_file: ./key.pem
    online_client: # Central API
      credentials_path: "$CONFIG_DIR/online_api_credentials.yaml"
prometheus:
  enabled: true
  level: full
''',
    '/etc/crowdsec/user.yaml': r'''common:
  log_media: stdout
  log_level: info
  log_dir: /var/log/
config_paths:
  config_dir: /etc/crowdsec/
  data_dir: /var/lib/crowdsec/data
  #simulation_path: /etc/crowdsec/config/simulation.yaml
  #hub_dir: /etc/crowdsec/hub/
  #index_path: ./config/hub/.index.json
crowdsec_service:
  #acquisition_path: ./config/acquis.yaml
  parser_routines: 1
cscli:
  output: human
db_config:
  type: sqlite
  db_path: /var/lib/crowdsec/data/crowdsec.db
  user: crowdsec
  #log_level: info
  password: crowdsec
  db_name: crowdsec
  host: "127.0.0.1"
  port: 3306
api:
  client:
    insecure_skip_verify: false # default true
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
  server:
    #log_level: info
    listen_uri: 127.0.0.1:8080
    profiles_path: /etc/crowdsec/profiles.yaml
    online_client: # Central API
      credentials_path: /etc/crowdsec/online_api_credentials.yaml
prometheus:
  enabled: true
  level: full
''',
    '/etc/crowdsec/notifications/http.yaml': r'''type: http          # Don't change
name: http_default  # Must match the registered plugin in the profile

# One of "trace", "debug", "info", "warn", "error", "off"
log_level: info

# group_wait:         # Time to wait collecting alerts before relaying a message to this plugin, eg "30s"
# group_threshold:    # Amount of alerts that triggers a message before <group_wait> has expired, eg "10"
# max_retry:          # Number of attempts to relay messages to plugins in case of error
# timeout:            # Time to wait for response from the plugin before considering the attempt a failure, eg "10s"

#-------------------------
# plugin-specific options

# The following template receives a list of models.Alert objects
# The output goes in the http request body
format: |
  {{.|toJson}}

# The plugin will make requests to this url, eg:  https://www.example.com/
url: <HTTP_url>

# Any of the http verbs: "POST", "GET", "PUT"...
method: POST

# headers:
#   Authorization: token 0x64312313

# skip_tls_verification:  # true or false. Default is false

---

# type: http
# name: http_second_notification
# ...

''',
    '/etc/crowdsec/notifications/slack.yaml': r'''type: slack           # Don't change
name: slack_default   # Must match the registered plugin in the profile

# One of "trace", "debug", "info", "warn", "error", "off"
log_level: info

# group_wait:         # Time to wait collecting alerts before relaying a message to this plugin, eg "30s"
# group_threshold:    # Amount of alerts that triggers a message before <group_wait> has expired, eg "10"
# max_retry:          # Number of attempts to relay messages to plugins in case of error
# timeout:            # Time to wait for response from the plugin before considering the attempt a failure, eg "10s"

#-------------------------
# plugin-specific options

# The following template receives a list of models.Alert objects
# The output goes in the slack message
format: |
  {{range . -}}
  {{$alert := . -}}
  {{range .Decisions -}}
  {{if $alert.Source.Cn -}}
  :flag-{{$alert.Source.Cn}}: <https://www.whois.com/whois/{{.Value}}|{{.Value}}> will get {{.Type}} for next {{.Duration}} for triggering {{.Scenario}} on machine '{{$alert.MachineID}}'. <https://app.crowdsec.net/cti/{{.Value}}|CrowdSec CTI>{{end}}
  {{if not $alert.Source.Cn -}}
  :pirate_flag: <https://www.whois.com/whois/{{.Value}}|{{.Value}}> will get {{.Type}} for next {{.Duration}} for triggering {{.Scenario}} on machine '{{$alert.MachineID}}'.  <https://app.crowdsec.net/cti/{{.Value}}|CrowdSec CTI>{{end}}
  {{end -}}
  {{end -}}


webhook: <WEBHOOK_URL>

# API request data as defined by the Slack webhook API.
#channel: <CHANNEL_NAME>
#username: <USERNAME>
#icon_emoji: <ICON_EMOJI>
#icon_url: <ICON_URL>

---

# type: slack
# name: slack_second_notification
# ...

''',
    '/etc/crowdsec/notifications/email.yaml': r'''type: email           # Don't change
name: email_default   # Must match the registered plugin in the profile

# One of "trace", "debug", "info", "warn", "error", "off"
log_level: info

# group_wait:         # Time to wait collecting alerts before relaying a message to this plugin, eg "30s"
# group_threshold:    # Amount of alerts that triggers a message before <group_wait> has expired, eg "10"
# max_retry:          # Number of attempts to relay messages to plugins in case of error
timeout: 20s          # Time to wait for response from the plugin before considering the attempt a failure, eg "10s"

#-------------------------
# plugin-specific options

# The following template receives a list of models.Alert objects
# The output goes in the email message body
format: |
  <html><body>
  {{range . -}}
    {{$alert := . -}}
    {{range .Decisions -}}
      <p><a href="https://www.whois.com/whois/{{.Value}}">{{.Value}}</a> will get <b>{{.Type}}</b> for next <b>{{.Duration}}</b> for triggering <b>{{.Scenario}}</b> on machine <b>{{$alert.MachineID}}</b>.</p> <p><a href="https://app.crowdsec.net/cti/{{.Value}}">CrowdSec CTI</a></p>
    {{end -}}
  {{end -}}
  </body></html>

smtp_host:            # example: smtp.gmail.com
smtp_username:        # Replace with your actual username
smtp_password:        # Replace with your actual password
smtp_port:            # Common values are any of [25, 465, 587, 2525]
auth_type:            # Valid choices are "none", "crammd5", "login", "plain"
sender_name: "CrowdSec"
sender_email:         # example: foo@gmail.com
email_subject: "CrowdSec Notification"
receiver_emails:
# - email1@gmail.com
# - email2@gmail.com

# One of "ssltls", "starttls", "none"
encryption_type: "ssltls"

# If you need to set the HELO hostname:
# helo_host: "localhost"

# If the email server is hitting the default timeouts (10 seconds), you can increase them here
#
# connect_timeout: 10s
# send_timeout: 10s

---

# type: email
# name: email_second_notification
# ...

''',
    '/etc/crowdsec/notifications/splunk.yaml': r'''type: splunk          # Don't change
name: splunk_default  # Must match the registered plugin in the profile

# One of "trace", "debug", "info", "warn", "error", "off"
log_level: info

# group_wait:         # Time to wait collecting alerts before relaying a message to this plugin, eg "30s"
# group_threshold:    # Amount of alerts that triggers a message before <group_wait> has expired, eg "10"
# max_retry:          # Number of attempts to relay messages to plugins in case of error
# timeout:            # Time to wait for response from the plugin before considering the attempt a failure, eg "10s"

#-------------------------
# plugin-specific options

# The following template receives a list of models.Alert objects
# The output goes in the splunk notification
format: |
  {{.|toJson}}

url: <SPLUNK_HTTP_URL>
token: <SPLUNK_TOKEN>

---

# type: splunk
# name: splunk_second_notification
# ...

''',
    '/etc/crowdsec/notifications/sentinel.yaml': r'''type: sentinel          # Don't change
name: sentinel_default  # Must match the registered plugin in the profile

# One of "trace", "debug", "info", "warn", "error", "off"
log_level: info
# group_wait:         # Time to wait collecting alerts before relaying a message to this plugin, eg "30s"
# group_threshold:    # Amount of alerts that triggers a message before <group_wait> has expired, eg "10"
# max_retry:          # Number of attempts to relay messages to plugins in case of error
# timeout:            # Time to wait for response from the plugin before considering the attempt a failure, eg "10s"

#-------------------------
# plugin-specific options

# The following template receives a list of models.Alert objects
# The output goes in the http request body
format: |
  {{.|toJson}}

customer_id: XXX-XXX
shared_key: XXXXXXX
log_type: crowdsec''',
    '/etc/crowdsec/notifications/file.yaml': r'''# Don't change this
type: file

name: file_default # this must match with the registered plugin in the profile
log_level: info # Options include: trace, debug, info, warn, error, off

# This template render all events as ndjson
format: |
  {{range . -}}
   { "time": "{{.StopAt}}", "program": "crowdsec", "alert": {{. | toJson }} }
  {{ end -}}

# group_wait: # duration to wait collecting alerts before sending to this plugin, eg "30s"
# group_threshold: # if alerts exceed this, then the plugin will be sent the message. eg "10"

#Use full path EG /tmp/crowdsec_alerts.json or %TEMP%\crowdsec_alerts.json
log_path: "/tmp/crowdsec_alerts.json"
rotate:
  enabled: true # Change to false if you want to handle log rotate on system basis
  max_size: 500 # in MB
  max_files: 5
  max_age: 5
  compress: true
''',
}


# The files the DCS crowdsec template ships (profiles.yaml, and the Discord notification with @@WEBHOOK@@ / @@DOMAIN@@ to fill in)
DCS_PROFILES_YAML = r'''# Decisions: 4 h bans for IPs and ranges; every decision also goes to the
# http_default notification (Discord) when DCS configured one.
name: default_ip_remediation
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
  - type: ban
    duration: 4h
notifications:
  - http_default
on_success: break
---
name: default_range_remediation
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Range"
decisions:
  - type: ban
    duration: 4h
notifications:
  - http_default
on_success: break
'''

DCS_DISCORD_YAML = r'''# CrowdSec → Discord: one embed per alert, in the DCS style. Every ban says what
# was blocked in plain words (the scenario family), where it came from (address,
# flag, network), how hard it hit and for how long it is banned, and links the
# address to the CrowdSec threat-intelligence page.
# DCS fills the webhook and the footer's domain when the template is deployed
# (POST /crowdsec/notifications re-applies it to a running CrowdSec).
type: http
name: http_default
log_level: info
group_wait: 5s
group_threshold: 10
max_retry: 3
timeout: 10s
format: |
  {{- /* Colours follow the dashboard: rose for break-ins, violet for exploits,
         amber for injection and scanning, cyan for community signals */ -}}
  {
    "username": "CrowdSec",
    "avatar_url": "https://raw.githubusercontent.com/scotthowson/dcs-orchestrator-ui/v2.0.0/brand/discord/crowdsec-avatar.png",
    "allowed_mentions": {"parse": []},
    "embeds": [
      {{- range $i, $alert := . }}
      {{- $s := $alert.Scenario }}
      {{- $label := "Attack blocked" }}{{ $color := 15942494 }}
      {{- if hasPrefix "crowdsecurity/ssh" $s }}{{ $label = "SSH brute force" }}{{ $color = 15942494 }}
      {{- else if hasPrefix "crowdsecurity/http-cve" $s }}{{ $label = "Exploit attempt" }}{{ $color = 10979578 }}
      {{- else if hasPrefix "crowdsecurity/CVE" $s }}{{ $label = "Exploit attempt" }}{{ $color = 10979578 }}
      {{- else if hasPrefix "crowdsecurity/http-sqli" $s }}{{ $label = "SQL injection probe" }}{{ $color = 16098851 }}
      {{- else if hasPrefix "crowdsecurity/http-xss" $s }}{{ $label = "Cross-site scripting probe" }}{{ $color = 16098851 }}
      {{- else if hasPrefix "crowdsecurity/http-path-traversal" $s }}{{ $label = "Path traversal probe" }}{{ $color = 16098851 }}
      {{- else if hasPrefix "crowdsecurity/http-backdoors" $s }}{{ $label = "Backdoor probe" }}{{ $color = 10979578 }}
      {{- else if hasPrefix "crowdsecurity/http-admin-interface" $s }}{{ $label = "Admin panel probe" }}{{ $color = 16098851 }}
      {{- else if hasPrefix "crowdsecurity/http-bad-user-agent" $s }}{{ $label = "Known bad scanner" }}{{ $color = 16098851 }}
      {{- else if hasPrefix "crowdsecurity/http-probing" $s }}{{ $label = "Web probing" }}{{ $color = 16098851 }}
      {{- else if hasPrefix "crowdsecurity/http-sensitive-files" $s }}{{ $label = "Sensitive file probe" }}{{ $color = 16098851 }}
      {{- else if hasPrefix "crowdsecurity/http-crawl" $s }}{{ $label = "Aggressive crawler" }}{{ $color = 16098851 }}
      {{- else if hasPrefix "crowdsecurity/http-generic-bf" $s }}{{ $label = "Web login brute force" }}{{ $color = 15942494 }}
      {{- else if hasPrefix "crowdsecurity/http-open-proxy" $s }}{{ $label = "Open proxy probe" }}{{ $color = 16098851 }}
      {{- else if hasPrefix "crowdsecurity/http-wordpress" $s }}{{ $label = "WordPress attack" }}{{ $color = 16098851 }}
      {{- else if hasPrefix "crowdsecurity/http-dos" $s }}{{ $label = "HTTP flood" }}{{ $color = 15942494 }}
      {{- else if hasPrefix "crowdsecurity/nginx-req-limit" $s }}{{ $label = "Request flood" }}{{ $color = 15942494 }}
      {{- else if hasPrefix "LePresidente/" $s }}{{ $label = "Application brute force" }}{{ $color = 15942494 }}
      {{- else if hasPrefix "crowdsecurity/traefik" $s }}{{ $label = "Traefik abuse" }}{{ $color = 16098851 }}
      {{- end }}
      {{- $ip := $alert.Source.Value }}
      {{- $target := "" }}{{ $path := "" }}
      {{- range $e := $alert.Events }}{{ range $m := $e.Meta }}
        {{- if and (eq $m.Key "target_fqdn") (eq $target "") }}{{ $target = $m.Value }}{{ end }}
        {{- if and (eq $m.Key "http_path") (eq $path "") }}{{ $path = $m.Value }}{{ end }}
      {{- end }}{{ end }}
      {{- $dtype := "ban" }}{{ $dur := "" }}{{ $origin := "" }}
      {{- /* decision fields are pointers: a string function (trim) dereferences them */ -}}
      {{- if $alert.Decisions }}{{ $d := index $alert.Decisions 0 }}{{ $dtype = ($d.Type | trim) }}{{ $dur = ($d.Duration | trim) }}{{ $origin = ($d.Origin | trim) }}{{ end }}
      {{- if eq $dtype "captcha" }}{{ $color = 2282478 }}{{ end }}
      {{- if $i }},{{ end }}
      {
        "title": "🛡️ {{ $label }}",
        "url": "https://app.crowdsec.net/cti/{{ $ip | js }}",
        "color": {{ $color }},
        "description": "**{{ $ip | js }}**{{ if eq (len $alert.Source.Cn) 2 }} :flag_{{ lower $alert.Source.Cn }}: {{ $alert.Source.Cn }}{{ end }}{{ if $alert.Source.AsName }} · {{ $alert.Source.AsName | js }}{{ end }}\n{{ $alert.EventsCount }} hits → **{{ $dtype }}**{{ if $dur }} for {{ $dur }}{{ end }}{{ if $target }} · aimed at **{{ $target | js }}**{{ end }}",
        "fields": [
          {"name": "Scenario", "value": "`{{ $s | trimPrefix "crowdsecurity/" | js }}`", "inline": true},
          {"name": "Scope",    "value": "{{ $alert.Source.Scope | js }}{{ if $origin }} · {{ $origin | js }}{{ end }}", "inline": true},
          {"name": "Lookup",   "value": "[CrowdSec CTI](https://app.crowdsec.net/cti/{{ $ip | js }}) · [AbuseIPDB](https://www.abuseipdb.com/check/{{ $ip | js }})", "inline": true}
          {{- if $path }},
          {"name": "First request", "value": "`{{ $path | js | trunc 200 }}`", "inline": false}
          {{- end }}
        ],
        "footer": {"text": "CrowdSec · @@DOMAIN@@{{ if $alert.MachineID }} · {{ $alert.MachineID | js }}{{ end }}"}
      }
      {{- end }}
    ]
  }
url: @@WEBHOOK@@
method: POST
headers:
  Content-Type: application/json
'''


# ==================================================================================================
# reference data captured from the real 1.8.1 container
# ==================================================================================================
# installed at first start (hub list -o json of a container started with the DCS compose file)
INSTALLED_BASE = {"collections": {"crowdsecurity/base-http-scenarios": "1.4", "crowdsecurity/http-cve": "3.0", "crowdsecurity/linux": "0.4", "crowdsecurity/sshd": "0.9", "crowdsecurity/traefik": "0.2", "crowdsecurity/whitelist-good-actors": "0.4"}, "contexts": {"crowdsecurity/bf_base": "0.1", "crowdsecurity/http_base": "0.3"}, "parsers": {"crowdsecurity/cri-logs": "0.1", "crowdsecurity/dateparse-enrich": "0.2", "crowdsecurity/docker-logs": "0.1", "crowdsecurity/geoip-enrich": "0.5", "crowdsecurity/http-logs": "1.4", "crowdsecurity/public-dns-allowlist": "0.1", "crowdsecurity/sshd-logs": "3.1", "crowdsecurity/sshd-success-logs": "0.1", "crowdsecurity/syslog-logs": "1.0", "crowdsecurity/traefik-logs": "1.5", "crowdsecurity/whitelists": "0.3"}, "postoverflows": {"crowdsecurity/cdn-whitelist": "0.5", "crowdsecurity/google-special-crawlers-whitelist": "0.1", "crowdsecurity/rdns": "0.4", "crowdsecurity/seo-bots-whitelist": "0.5"}, "scenarios": {"crowdsecurity/apache_log4j2_cve-2021-44228": "0.7", "crowdsecurity/CVE-2017-9841": "0.2", "crowdsecurity/CVE-2019-18935": "0.2", "crowdsecurity/CVE-2022-26134": "0.4", "crowdsecurity/CVE-2022-35914": "0.2", "crowdsecurity/CVE-2022-37042": "0.2", "crowdsecurity/CVE-2022-40684": "0.3", "crowdsecurity/CVE-2022-41082": "0.4", "crowdsecurity/CVE-2022-41697": "0.2", "crowdsecurity/CVE-2022-42889": "0.3", "crowdsecurity/CVE-2022-44877": "0.4", "crowdsecurity/CVE-2022-46169": "0.2", "crowdsecurity/CVE-2023-22515": "0.1", "crowdsecurity/CVE-2023-22518": "0.3", "crowdsecurity/CVE-2023-49103": "0.3", "crowdsecurity/CVE-2024-0012": "0.1", "crowdsecurity/CVE-2024-38475": "0.1", "crowdsecurity/CVE-2024-9474": "0.1", "crowdsecurity/f5-big-ip-cve-2020-5902": "0.3", "crowdsecurity/fortinet-cve-2018-13379": "0.4", "crowdsecurity/grafana-cve-2021-43798": "0.3", "crowdsecurity/http-admin-interface-probing": "0.5", "crowdsecurity/http-backdoors-attempts": "0.6", "crowdsecurity/http-bad-user-agent": "1.2", "crowdsecurity/http-crawl-non_statics": "0.7", "crowdsecurity/http-cve-2021-41773": "0.3", "crowdsecurity/http-cve-2021-42013": "0.3", "crowdsecurity/http-cve-probing": "0.6", "crowdsecurity/http-generic-bf": "0.9", "crowdsecurity/http-generic-test": "0.2", "crowdsecurity/http-open-proxy": "0.5", "crowdsecurity/http-path-traversal-probing": "0.4", "crowdsecurity/http-probing": "0.4", "crowdsecurity/http-sap-interface-probing": "0.1", "crowdsecurity/http-sensitive-files": "0.4", "crowdsecurity/http-sqli-probing": "0.4", "crowdsecurity/http-technology-probing": "0.1", "crowdsecurity/http-wordpress-scan": "0.4", "crowdsecurity/http-xss-probing": "0.4", "crowdsecurity/jira_cve-2021-26086": "0.4", "crowdsecurity/netgear_rce": "0.4", "crowdsecurity/pulse-secure-sslvpn-cve-2019-11510": "0.4", "crowdsecurity/spring4shell_cve-2022-22965": "0.3", "crowdsecurity/ssh-bf": "0.3", "crowdsecurity/ssh-cve-2024-6387": "0.2", "crowdsecurity/ssh-generic-test": "0.2", "crowdsecurity/ssh-refused-conn": "0.1", "crowdsecurity/ssh-slow-bf": "0.4", "crowdsecurity/ssh-time-based-bf": "0.3", "crowdsecurity/thinkphp-cve-2018-20062": "0.7", "crowdsecurity/vmware-cve-2022-22954": "0.3", "crowdsecurity/vmware-vcenter-vmsa-2021-0027": "0.3", "ltsich/http-w00tw00t": "0.3"}}   # noqa: E501

HUB_ORDER = ('appsec-configs', 'appsec-rules', 'collections', 'contexts', 'parsers', 'postoverflows', 'scenarios')   # JSON key order
PLAN_ORDER = ('collections', 'appsec-rules', 'appsec-configs', 'contexts', 'scenarios', 'postoverflows', 'parsers')  # Action plan order
ITEM_ORDER = ('parsers', 'postoverflows', 'scenarios', 'contexts', 'appsec-configs', 'appsec-rules', 'collections')   # cwhub's order: lists, inspect, `hub list`
STAGE_TYPES = ('parsers', 'postoverflows')

# per-scenario bits of an engine alert (capacity/leakspeed/hash/version and the meta keys, all from real alerts)
SCEN = {
    'crowdsecurity/http-probing': dict(cap=10, leak='10s', ver='0.4', fam='http', mkeys=('user_agent', 'method', 'status', 'target_uri'),
                                       hash='4b16f896af400e006c28b1476bf5989c748186f2b3756ed9ad7d1559480d278c',
                                       paths=['/x%d' % i for i in range(1, 12)], ua='Mozilla/5.0 (compatible; scanner/1.0)', status='404'),
    'crowdsecurity/http-bad-user-agent': dict(cap=1, leak='1m0s', ver='1.2', fam='http', mkeys=('method', 'status', 'target_uri', 'user_agent'),
                                              hash='7ca405d1147762b1f488bc0f13575c5af8081499c8a5c2971d706e8b03493671',
                                              paths=['/a', '/b'], ua='Nikto/2.1.6', status='404'),
    'crowdsecurity/http-admin-interface-probing': dict(cap=2, leak='10s', ver='0.5', fam='http', mkeys=('method', 'status', 'target_uri', 'user_agent'),
                                                       hash='a8b0428674913507f3a356bba0e17541df731682dd2376a5495c4c76a60b8813',
                                                       paths=['/wp-login.php', '/admin', '/phpmyadmin'], ua='Mozilla/5.0 (compatible; scanner/1.0)', status='404'),
    'crowdsecurity/http-backdoors-attempts': dict(cap=1, leak='5s', ver='0.6', fam='http', mkeys=('method', 'status', 'target_uri', 'user_agent'),
                                                  hash='dd5d8c02fff1fd939471358c61c9861387992f3062208a583839564bf644453b',
                                                  paths=['/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php', '/shell.php'], ua='python-requests/2.28', status='200'),
    'crowdsecurity/CVE-2017-9841': dict(cap=0, leak='0s', ver='0.2', fam='http', mkeys=('status', 'target_uri', 'user_agent', 'method'),
                                        hash='a9421e42d85c3f1aab40ef09aaa0261db42f34c5d95986d6a67c9db8b577889e',
                                        paths=['/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php'], ua='python-requests/2.28', status='200'),
    'crowdsecurity/ssh-bf': dict(cap=5, leak='10s', ver='0.3', fam='ssh', mkeys=('target_user', 'service'),
                                 hash='3f0a2b8d6c4e1a79d5b3c8e2f1a4d7b06c9e5f8a2d1b4c7e0f3a6d9b2c5e8f1a', users=['root', 'admin', 'ubuntu', 'test', 'oracle', 'postgres']),
    'crowdsecurity/ssh-slow-bf': dict(cap=10, leak='1m0s', ver='0.4', fam='ssh', mkeys=('target_user', 'service'),
                                      hash='9b1d4f7a0c3e6b8d2f5a1c4e7b0d3f6a9c2e5b8d1f4a7c0e3b6d9f2a5c8e1b4d', users=['root', 'admin', 'git', 'ftpuser', 'deploy', 'www-data', 'mysql', 'pi', 'user', 'guest', 'jenkins']),
}

# (ip, cc, AS name, AS number, latitude, longitude, range)
GEO = {
    '89.248.165.10': ('NL', 'IP Volume inc', '202425', 52.3759, 4.8975, '89.248.160.0/21'),
    '185.220.101.5': ('DE', 'Stiftung Erneuerbare Freiheit', '60729', 52.6171, 13.1207, '185.220.101.0/24'),
    '194.26.135.7': ('RU', 'Voronezh Telecom LLC', '43991', 55.7386, 37.6068, '194.26.135.0/24'),
    '91.240.118.11': ('HK', 'Galeon LLC', '209290', 22.2578, 114.1657, '91.240.118.0/24'),
    '78.128.113.9': ('BG', 'Miti 2000 EOOD', '209160', 42.696, 23.332, '78.128.113.0/24'),
    '45.83.64.20': ('DE', 'Alpha Strike Labs GmbH', '208843', 51.2993, 9.491, '45.83.64.0/22'),
    '167.99.224.31': ('US', 'DigitalOcean, LLC', '14061', 40.7128, -74.006, '167.99.224.0/20'),
    '116.31.116.24': ('CN', 'CHINANET Guangdong province network', '4134', 23.1167, 113.25, '116.31.116.0/24'),
    '187.19.152.10': ('BR', 'Claro NXT Telecomunicacoes Ltda', '28573', -23.5475, -46.6361, '187.19.152.0/22'),
    '61.177.172.13': ('CN', 'CHINANET jiangsu province backbone', '4134', 34.7732, 113.722, '61.177.172.0/24'),
    '5.188.62.76': ('RU', 'Petersburg Internet Network ltd.', '216368', 55.7386, 37.6068, '5.188.62.0/24'),
    '141.98.11.4': ('LT', 'UAB Host Baltic', '209605', 54.6912, 25.2816, '141.98.10.0/23'),
}
EU_CC = ('DE', 'NL', 'BG', 'LT', 'FR', 'IT', 'ES', 'PL', 'RO', 'SE')


# ==================================================================================================
# version dependent behaviour
# ==================================================================================================
def ver_ge(st, *want):
    return version_tuple(st.get('version', DEFAULT_VERSION)) >= want


def has_allowlists(st):
    return ver_ge(st, 1, 6, 8)


def machine_version(st):
    v = st.get('version', DEFAULT_VERSION)
    return 'v%s-%s-docker' % (v, _sha8(v))


def _sha8(v):
    if v == DEFAULT_VERSION:
        return '909b5157'
    return '%08x' % (zlib.crc32(v.encode('ascii')) & 0xffffffff)


def version_text(st):
    v = st.get('version', DEFAULT_VERSION)
    sha = _sha8(v)
    build = '2026-09-03_11:03:45' if v == DEFAULT_VERSION else '2025-02-03_09:12:44'
    go = '1.26.8' if v == DEFAULT_VERSION else '1.23.5'
    lines = ['version: v%s-%s' % (v, sha), 'Codename: alphaga', 'BuildDate: %s' % build, 'GoVersion: %s' % go,
             'Platform: docker', 'libre2: C++', 'User-Agent: crowdsec/v%s-%s-docker' % (v, sha),
             'Constraint_parser: >= 1.0, <= 3.0', 'Constraint_scenario: >= 1.0, <= 3.0', 'Constraint_api: v1',
             'Constraint_acquis: >= 1.0, < 2.0']
    if ver_ge(st, 1, 7):
        lines.append('Built-in optional components: cscli_setup, datasource_appsec, datasource_cloudwatch, datasource_docker, '
                     'datasource_file, datasource_http, datasource_journalctl, datasource_k8s-audit, datasource_kafka, '
                     'datasource_kinesis, datasource_kubernetes, datasource_loki, datasource_s3, datasource_syslog, '
                     'datasource_victorialogs, datasource_wineventlog, db_mysql, db_postgres, db_sqlite')
    return '\n'.join(lines) + '\n'


# ==================================================================================================
# the hub: catalog (embedded, compressed - the real 1.8.1 index) + what is downloaded/enabled
# ==================================================================================================
_CAT = []


def catalog():
    """{type: {name: (version, description, extra_dict)}}"""
    if not _CAT:
        raw = json.loads(zlib.decompress(base64.b64decode(CATALOG_B64)).decode('utf-8'))
        cat = {}
        for typ, rows in raw.items():
            d = {}
            for r in rows:
                d[r[0]] = (r[1], r[2], r[3] if len(r) > 3 else {})
            cat[typ] = d
        _CAT.append(cat)
    return _CAT[0]


def vkey(v):
    return tuple(int(x) if x.isdigit() else 0 for x in re.split(r'[.\-]', v or '0'))


class Hub(object):
    """state['cs']['hub'] = {'items': {type: {name: {'v': local_version, 'on': bool}}}, 'fresh': bool}
    An entry exists once the item was downloaded; 'on' says whether it is enabled (installed)."""

    def __init__(self, st):
        self.h = st['cs']['hub']
        self.cat = catalog()
        self.cascade = bool(st.get('knobs', {}).get('hub_cascade'))     # see outdated()

    def known(self, typ, name):
        return name in self.cat.get(typ, {})

    def latest(self, typ, name):
        return self.cat[typ][name][0]

    def desc(self, typ, name):
        return self.cat[typ][name][1]

    def extra(self, typ, name):
        return self.cat[typ][name][2]

    def entry(self, typ, name):
        return self.h['items'].get(typ, {}).get(name)

    def members(self, typ, name):
        return self.extra(typ, name).get('m', {}) if typ == 'collections' else {}

    def dfs(self, typ, name, seen, order):
        """appends to `order` the item and everything it contains, contents first: the members by type (ITEM_ORDER), in the order the
        collection lists them, depth first, each item once, the item itself last - the order in which cscli applies a plan"""
        if (typ, name) in seen:
            return order
        seen.add((typ, name))
        mem = self.members(typ, name)
        for t2 in ITEM_ORDER:
            for m in mem.get(t2, ()):
                if self.known(t2, m):
                    self.dfs(t2, m, seen, order)
        order.append((typ, name))
        return order

    def closure(self, typ, name, acc=None):
        """the item and everything it (recursively) contains -> {type: set(names)}"""
        acc = acc if acc is not None else {}
        s = acc.setdefault(typ, set())
        if name in s:
            return acc
        s.add(name)
        for t2, names in self.members(typ, name).items():
            for n2 in names:
                if self.known(t2, n2):
                    self.closure(t2, n2, acc)
        return acc

    def local_path(self, typ, name):
        ex = self.extra(typ, name)
        fname = ex.get('f') or (name.split('/', 1)[-1] + '.yaml')
        if typ in STAGE_TYPES:
            return '/etc/crowdsec/%s/%s/%s' % (typ, ex.get('s', 's01-parse'), fname)
        return '/etc/crowdsec/%s/%s' % (typ, fname)

    def outdated(self, typ, name):
        """the local copy is older than the index. The real cscli also flags an enabled collection when one of its members is
        (one level: "X is outdated because of Y"); that only happens here with `--mock-set hub_cascade=1`, so that the
        `data` preset has exactly one item with an update (sshd) although linux contains it."""
        e = self.entry(typ, name)
        if e is None or vkey(e['v']) < vkey(self.latest(typ, name)):
            return True
        return self.cascade and typ == 'collections' and e['on'] and self.outdated_member(name) is not None

    def outdated_member(self, name):
        """the first (type, name) among the members of the collection whose local copy is behind the index, or None"""
        mem = self.members('collections', name)
        for t2 in ITEM_ORDER:
            for m in mem.get(t2, ()):
                e = self.entry(t2, m) if self.known(t2, m) else None
                if e is not None and vkey(e['v']) < vkey(self.latest(t2, m)):
                    return t2, m
        return None

    def status(self, typ, name):
        """-> (status, utf8_status) exactly as `cscli <type> list -o json` prints them"""
        e = self.entry(typ, name)
        outdated = self.outdated(typ, name)
        if e and e['on']:
            if outdated:
                return 'enabled,update-available', '⚠️  enabled,update-available'
            return 'enabled', '✔️  enabled'
        s = 'disabled,update-available' if outdated else 'disabled'
        return s, '\U0001f6ab  ' + s

    def item(self, typ, name):
        e = self.entry(typ, name)
        stt, utf = self.status(typ, name)
        on = bool(e and e['on'])
        return {'name': name, 'local_version': e['v'] if e else '', 'local_path': self.local_path(typ, name) if on else '',
                'description': self.desc(typ, name), 'utf8_status': utf, 'status': stt}

    def names(self, typ, all_=False):
        if all_:
            return list(self.cat.get(typ, {}))
        return [n for n in self.cat.get(typ, {}) if (self.entry(typ, n) or {}).get('on')]

    def enabled_collections(self):
        return [n for n in self.cat['collections'] if (self.entry('collections', n) or {}).get('on')]

    def parents(self, typ, name, _memo=None):
        """what `inspect` calls belongs_to_collections: for every collection that lists the item, that collection and, recursively,
        the collections it belongs to - each listed once per direct parent. cscli does not merge the lists of different parents,
        so a collection that is reachable through two of them shows twice. Sorted without regard to case."""
        memo = {} if _memo is None else _memo
        if (typ, name) not in memo:
            res = []
            for c, row in self.cat['collections'].items():
                if name in row[2].get('m', {}).get(typ, ()):
                    mine = []
                    for x in [c] + self.parents('collections', c, memo):
                        if x not in mine:
                            mine.append(x)
                    res += mine
            memo[(typ, name)] = res
        return sorted(memo[(typ, name)], key=str.lower) if _memo is None else memo[(typ, name)]

    def digest(self, typ, name, version):
        """the index stores a sha256 per version; this mock derives a stable fake one"""
        import hashlib
        return hashlib.sha256(('%s:%s@%s' % (typ, name, version)).encode('utf-8')).hexdigest()

    def versions(self, typ, name):
        """{version: {digest}} from 0.1 up to the catalog version (versions are x.y; the real index lists every release)"""
        latest = self.latest(typ, name)
        m = re.match(r'^(\d+)\.(\d+)$', latest)
        if not m:
            return {latest: {'digest': self.digest(typ, name, latest)}}
        major, minor = int(m.group(1)), int(m.group(2))
        vs = ['%d.%d' % (M, m_) for M in range(0, major + 1) for m_ in range(0 if M else 1, (minor if M == major else 9) + 1)]
        return {v: {'digest': self.digest(typ, name, v)} for v in vs}

    def belongs_to(self, typ, name):
        """enabled collections whose content includes the item"""
        res = []
        for c in self.enabled_collections():
            if name in self.closure('collections', c).get(typ, ()) and not (typ == 'collections' and c == name):
                res.append(c)
        return sorted(res)

    def suggest(self, typ, name):
        best, bn = 100, None
        for n in self.cat.get(typ, {}):
            d = lev(name, n)
            if d < best:
                best, bn = d, n
        return bn if best < 7 else None

    # -- state changes -----------------------------------------------------------------------------
    def set_item(self, typ, name, on, version=None):
        d = self.h['items'].setdefault(typ, {})
        e = d.get(name)
        if e is None:
            e = d[name] = {'v': version or self.latest(typ, name), 'on': on}
        else:
            e['on'] = on
            if version:
                e['v'] = version


def hub_init_items(st, outdated=None):
    """the item state of a fresh container: everything in INSTALLED_BASE downloaded+enabled"""
    items = {}
    for typ, d in INSTALLED_BASE.items():
        items[typ] = {n: {'v': v, 'on': True} for n, v in d.items()}
    for (typ, name), v in (outdated or {}).items():
        items[typ][name]['v'] = v
    return {'items': items, 'fresh': False}


# ==================================================================================================
# the CrowdSec database: alerts + decisions, bouncers, machines, allowlists
# (state["cs"]; every timestamp is an absolute epoch, "remaining" durations are derived at print time)
# ==================================================================================================
def sanitize_scope(scope):
    """cscli's SanitizeScope: ip/range/country/as are canonicalised, anything else is kept"""
    low = (scope or '').lower()
    return {'ip': 'Ip', 'range': 'Range', 'country': 'Country', 'as': 'AS'}.get(low, scope)


def dec_out(d, t):
    """a decision as `cscli decisions list -o json` prints it (duration = remaining time, truncated to seconds)"""
    return {'duration': go_dur(d['until'] - t), 'id': d['id'], 'origin': d['origin'], 'scenario': d['scenario'],
            'scope': d['scope'], 'simulated': d['simulated'], 'type': d['type'], 'value': d['value']}


def alert_out(a, t):
    """an alert as the LAPI/cscli print it: alphabetical keys (go-swagger struct order), null-vs-[] like the real thing"""
    src = a['source']
    s = {}
    for k in ('as_name', 'as_number', 'cn', 'ip', 'latitude', 'longitude', 'range', 'scope', 'value'):
        if k in src:
            s[k] = src[k]
    o = {'capacity': a['capacity'], 'created_at': iso_s(a['created']), 'decisions': [dec_out(d, t) for d in a['decisions']],
         'events': a.get('events'), 'events_count': a['events_count'], 'id': a['id'], 'kind': a['kind'], 'labels': None,
         'leakspeed': a['leakspeed'], 'machine_id': a['machine'], 'message': a['message']}
    if a.get('meta'):
        o['meta'] = [{'key': k, 'value': v} for k, v in a['meta']]
    if a.get('remediation') is not None:
        o['remediation'] = a['remediation']
    o.update({'scenario': a['scenario'], 'scenario_hash': a['scenario_hash'], 'scenario_version': a['scenario_version'],
              'simulated': a['simulated'], 'source': s, 'start_at': iso_s(a['start']), 'stop_at': iso_s(a['stop']),
              'uuid': a['uuid']})
    return o


class Db(object):
    def __init__(self, st):
        self.st = st
        self.cs = st['cs']
        self.rng = Rng(st)

    # -- ids ---------------------------------------------------------------------------------------
    def alert_id(self):
        n = self.cs['next_alert']
        self.cs['next_alert'] = n + 1
        return n

    def decision_id(self):
        n = self.cs['next_decision']
        self.cs['next_decision'] = n + 1
        return n

    # -- creation ----------------------------------------------------------------------------------
    def new_alert(self, t, scenario, kind='cscli', scope='', value='', **kw):
        a = {'id': self.alert_id(), 'uuid': self.rng.uuid(), 'created': t, 'start': t, 'stop': t, 'kind': kind,
             'machine': 'localhost', 'scenario': scenario, 'scenario_hash': '', 'scenario_version': '', 'message': scenario,
             'remediation': True, 'capacity': 0, 'leakspeed': '0', 'simulated': False, 'events_count': 1, 'events': None,
             'meta': None, 'source': {'scope': scope, 'value': value}, 'decisions': []}
        a.update(kw)
        return a

    def new_decision(self, origin, typ, scope, value, scenario, until, simulated=False):
        return {'id': self.decision_id(), 'origin': origin, 'type': typ, 'scope': scope, 'value': value, 'scenario': scenario,
                'simulated': simulated, 'until': until}

    def add_manual(self, t, scope, value, dur, typ, reason, store=True):
        """cscli decisions add: one alert (kind cscli, source.ip = the value) with one decision"""
        a = self.new_alert(t, reason, scope=scope, value=value, message=reason)
        a['source'] = {'ip': value, 'scope': scope, 'value': value}
        a['decisions'].append(self.new_decision('cscli', typ, scope, value, reason, t + dur))
        if store:
            self.cs['alerts'].append(a)
        return a

    def add_import(self, t, items, label):
        """cscli decisions import: one alert per batch, decisions with origin cscli-import"""
        a = self.new_alert(t, 'import %s: %d IPs' % (label, len(items)), remediation=None, message='', leakspeed='',
                           events_count=len(items))
        for it in items:
            a['decisions'].append(self.new_decision('cscli-import', it['type'], it['scope'], it['value'], it['reason'], t + it['dur']))
        self.cs['alerts'].append(a)
        return a

    # -- allowlists --------------------------------------------------------------------------------
    def active_items(self, t):
        """[(list, item)] for the allowlist items that have not expired"""
        res = []
        for al in self.cs['allowlists']:
            for it in al['items']:
                if it['expiration'] is None or it['expiration'] > t:
                    res.append((al, it))
        return res

    def allowlist_matches(self, t, value):
        """items that overlap `value` (an address or a CIDR): same test cscli allowlists check uses"""
        return [(al, it) for al, it in self.active_items(t) if overlaps(it['value'], value)]

    def sweep_allowlists(self, t):
        """delete (expire now) every active Ip/Range decision overlapping an allowlist item -> count"""
        n = 0
        items = [it['value'] for _al, it in self.active_items(t)]
        for a in self.cs['alerts']:
            for d in a['decisions']:
                if d['until'] > t and d['scope'] in ('Ip', 'Range') and any(overlaps(v, d['value']) for v in items):
                    d['until'] = t
                    n += 1
        return n

    # -- queries -----------------------------------------------------------------------------------
    @staticmethod
    def _dec_matches_ip(d, ip):
        return d['scope'] in ('Ip', 'Range') and contains(d['value'], ip)

    @staticmethod
    def _dec_matches_range(d, rng, contained):
        if d['scope'] not in ('Ip', 'Range'):
            return False
        return contains(rng, d['value']) if contained else contains(d['value'], rng)

    def query_alerts(self, t, f):
        """the LAPI's alert search (GET /v1/alerts): returns alerts, newest first, before the limit is applied.
        f keys: active, all, no_simu, since, until, scenario, scope, value, ip, range, contained, type, origin, kind"""
        res = []
        for a in self.cs['alerts']:
            if a.get('capi') and not f.get('all'):
                continue
            if f.get('kind') and a['kind'] != f['kind']:
                continue
            if f.get('no_simu') and a['simulated']:
                continue
            if f.get('since') and not a['start'] >= t - f['since']:
                continue
            if f.get('until') and not a['start'] <= t - f['until']:
                continue
            decs = a['decisions']
            if f.get('active') and not any(d['until'] > t for d in decs):
                continue
            if f.get('scenario') and not (a['scenario'] == f['scenario'] or any(d['scenario'] == f['scenario'] for d in decs)):
                continue
            if f.get('scope') and a['source'].get('scope') != f['scope']:
                continue
            if f.get('value') and a['source'].get('value') != f['value']:
                continue
            if f.get('ip') and not any(self._dec_matches_ip(d, f['ip']) for d in decs):
                continue
            if f.get('range') and not any(self._dec_matches_range(d, f['range'], f.get('contained')) for d in decs):
                continue
            if f.get('type') and not any(d['type'] == f['type'] for d in decs):
                continue
            if f.get('origin') and not any(d['origin'] == f['origin'] for d in decs):
                continue
            res.append(a)
        res.sort(key=lambda a: (int(a['created']), a['id']), reverse=True)
        return res

    def find_alert(self, aid):
        for a in self.cs['alerts']:
            if a['id'] == aid:
                return a
        return None

    def find_decision(self, did):
        for a in self.cs['alerts']:
            for d in a['decisions']:
                if d['id'] == did:
                    return d
        return None

    def delete_decisions(self, t, f):
        """DELETE /v1/decisions: the filters apply to decisions; only active ones count; deleting = expiring now"""
        n = 0
        for a in self.cs['alerts']:
            for d in a['decisions']:
                if d['until'] <= t:
                    continue
                if f.get('ip') and not self._dec_matches_ip(d, f['ip']):
                    continue
                if f.get('range') and not self._dec_matches_range(d, f['range'], f.get('contained')):
                    continue
                if f.get('value') and d['value'] != f['value']:
                    continue
                if f.get('type') and d['type'] != f['type']:
                    continue
                if f.get('scenario') and d['scenario'] != f['scenario']:
                    continue
                if f.get('origin') and d['origin'] != f['origin']:
                    continue
                d['until'] = t
                n += 1
        return n

    def delete_alerts(self, t, f):
        gone = self.query_alerts(t, dict(f, all=True))
        ids = set(a['id'] for a in gone)
        self.cs['alerts'] = [a for a in self.cs['alerts'] if a['id'] not in ids]
        return len(ids)


def dedup_decisions(alerts):
    """cscli decisions list shows a decision once per (simulated, scope, value): the newest alert wins, the alert
    stays in the list with fewer decisions. Returns (alerts_copy_with_filtered_decisions, skipped)."""
    seen = set()
    skipped = 0
    res = []
    for a in alerts:
        keep = []
        for d in a['decisions']:
            key = (d['simulated'], d['scope'], d['value'])
            if key in seen:
                skipped += 1
                continue
            seen.add(key)
            keep.append(d)
        b = dict(a)
        b['decisions'] = keep
        res.append(b)
    return res, skipped


# --------------------------------------------------------------------------------------------------
# bouncers / machines as `cscli ... list -o json` prints them (struct order, 2-space indent)
# --------------------------------------------------------------------------------------------------
def bouncer_out(b):
    return {'created_at': iso_ns(b['created'], 1), 'updated_at': iso_ns(b['updated'], 2), 'name': b['name'],
            'revoked': b.get('revoked', False), 'ip_address': b.get('ip', ''), 'type': b.get('type', ''),
            'version': b.get('version', ''), 'last_pull': iso_ns(b['last_pull'], 3) if b.get('last_pull') else None,
            'auth_type': b.get('auth_type', 'api-key'), 'os': b.get('os', '?'), 'auto_created': b.get('auto_created', False)}


def machine_out(m):
    o = {'created_at': iso_ns(m['created'], 4), 'updated_at': iso_ns(m['updated'], 5)}
    if m.get('last_push'):
        o['last_push'] = iso_ns(m['last_push'], 6)
    if m.get('last_heartbeat'):
        o['last_heartbeat'] = iso_ns(m['last_heartbeat'], 7)
    o.update({'machineId': m['id'], 'ipAddress': m.get('ip', '127.0.0.1'), 'version': m['version'], 'isValidated': m.get('validated', True),
              'auth_type': m.get('auth_type', 'password'), 'os': m.get('os', 'alpine (docker)/3.24.1'), 'datasources': m.get('datasources', {})})
    return o


def allowlist_out(al):
    items = []
    for it in al['items']:
        o = {'created_at': iso_ms(it['created'])}
        if it.get('description'):
            o['description'] = it['description']
        o['expiration'] = '0001-01-01T00:00:00.000Z' if it['expiration'] is None else iso_ms(it['expiration'])
        o['value'] = it['value']
        items.append(o)
    return {'created_at': iso_ms(al['created']), 'description': al['description'], 'items': items, 'name': al['name'],
            'updated_at': iso_ms(al['updated'])}


# --------------------------------------------------------------------------------------------------
# metrics (`cscli metrics -o json`): alerts/decisions come from the DB, the rest are counters kept in state
# --------------------------------------------------------------------------------------------------
def metrics_out(st):
    cs = st['cs']
    t = now()
    m = cs['metrics']
    alerts, decisions = {}, {}
    for a in cs['alerts']:
        if a.get('capi'):
            continue
        alerts[a['scenario']] = alerts.get(a['scenario'], 0) + 1
    for a in cs['alerts']:
        for d in a['decisions']:
            if d['until'] > t:
                dd = decisions.setdefault(d['scenario'], {}).setdefault(d['origin'], {})
                dd[d['type']] = dd.get(d['type'], 0) + 1
    lapi = {route: dict(methods) for route, methods in cs['lapi'].items()}
    # lapi-machine: what the machine "localhost" requested (everything but its login and usage reports)
    mach = {r: dict(v) for r, v in cs['lapi'].items() if r not in ('/v1/usage-metrics', '/v1/watchers/login', '/v1/decisions/stream')}
    o = {'acquisition': m.get('acquisition', {}), 'alerts': alerts, 'appsec-challenge': {'funnel': {}, 'reasons': {}},
         'appsec-challenge-infra': {}, 'appsec-engine': {}, 'appsec-rule': {}, 'bouncers': m.get('bouncers', {}),
         'decisions': decisions, 'lapi': lapi, 'lapi-bouncer': m.get('lapi-bouncer', {}), 'lapi-decisions': m.get('lapi-decisions', {}),
         'lapi-machine': {'localhost': mach} if mach else {},
         'parsers': m.get('parsers', {}), 'scenarios': m.get('scenarios', {}), 'stash': m.get('stash', {}), 'whitelists': m.get('whitelists', {})}
    return o


def lapi_hit(st, route, method='GET', n=1):
    """count a request in the LAPI metrics (the metrics output is sorted like a Go map)"""
    d = st['cs']['lapi'].setdefault(route, {})
    d[method] = d.get(method, 0) + n


# ==================================================================================================
# containers and the docker view of them
# ==================================================================================================
CROWDSEC_IMAGE = 'crowdsecurity/crowdsec:latest'
CROWDSEC_IMAGE_ID = 'sha256:c1ab367021e17777b71f02881bf840fc252b17b9eaef77740c0a28008c3d4013'
CROWDSEC_IMAGE_LABELS = [('org.opencontainers.image.created', '2026-09-03T10:49:58Z'),
                         ('org.opencontainers.image.revision', '909b5157986a2b2c2163300fdaef5ed01289f7d2'),
                         ('org.opencontainers.image.source', 'https://github.com/crowdsecurity/crowdsec')]
COMPOSE_PROJECT = 'networking-security'
DCS_COLLECTIONS = 'crowdsecurity/linux crowdsecurity/traefik crowdsecurity/http-cve crowdsecurity/base-http-scenarios crowdsecurity/whitelist-good-actors'


def compose_labels(st, service, rng):
    wd = os.path.join(st['fake_dir'], 'stacks', COMPOSE_PROJECT)
    return [('com.docker.compose.config-hash', rng.hexstr(64)), ('com.docker.compose.container-number', '1'),
            ('com.docker.compose.depends_on', ''), ('com.docker.compose.image', 'sha256:' + rng.hexstr(64)),
            ('com.docker.compose.oneoff', 'False'), ('com.docker.compose.project', COMPOSE_PROJECT),
            ('com.docker.compose.project.config_files', 'docker-compose.yml'), ('com.docker.compose.project.working_dir', wd),
            ('com.docker.compose.service', service), ('com.docker.compose.version', '2.40.3')]


def make_crowdsec_container(st, t):
    rng = Rng(st)
    fd = st['fake_dir']
    labels = CROWDSEC_IMAGE_LABELS + compose_labels(st, 'crowdsec', rng)
    return {
        'name': 'CrowdSec', 'id': rng.hexstr(64), 'image': CROWDSEC_IMAGE, 'image_id': CROWDSEC_IMAGE_ID,
        'created': t, 'started': t, 'finished': None, 'status': 'running', 'exit_code': 0, 'restart_count': 0,
        'pid': 1000 + rng.randint(100000, 3000000), 'labels': labels, 'ip': '172.18.0.3', 'mac': '02:42:ac:12:00:03',
        'env': ['TZ=UTC', 'GID=1000', 'COLLECTIONS=' + DCS_COLLECTIONS, 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'],
        'entrypoint': ['/bin/bash', '/docker_start.sh'], 'cmd': None, 'command': '"/bin/bash /docker_s\u2026"',
        'health': 'healthy', 'health_forced': None, 'health_test': ['CMD', 'cscli', 'version'],
        'restart_policy': 'unless-stopped', 'ports': {'8080/tcp': [{'HostIp': '127.0.0.1', 'HostPort': '8070'}], '6060/tcp': None},
        'mounts': [{'src': fd + '/rootfs/etc/crowdsec', 'dst': '/etc/crowdsec', 'ro': False},
                   {'src': fd + '/rootfs/var/lib/crowdsec/data', 'dst': '/var/lib/crowdsec/data', 'ro': False},
                   {'src': fd + '/rootfs/var/log/traefik', 'dst': '/var/log/traefik', 'ro': True}],
        'network': COMPOSE_PROJECT + '_default', 'security_opt': ['label=disable'],
    }


def make_traefik_container(st, t):
    rng = Rng(st)
    fd = st['fake_dir']
    return {
        'name': 'Traefik', 'id': rng.hexstr(64), 'image': 'traefik:v3.1', 'image_id': 'sha256:' + rng.hexstr(64),
        'created': t - 86400 * 3, 'started': t - 86400 * 3 + 30, 'finished': None, 'status': 'running', 'exit_code': 0,
        'restart_count': 0, 'pid': 1000 + rng.randint(100000, 3000000),
        'labels': [('org.opencontainers.image.title', 'Traefik'), ('org.opencontainers.image.vendor', 'Traefik Labs')] + compose_labels(st, 'traefik', rng),
        'ip': '172.18.0.2', 'mac': '02:42:ac:12:00:02', 'env': ['TZ=UTC', 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'],
        'entrypoint': ['/entrypoint.sh'], 'cmd': ['traefik'], 'command': '"/entrypoint.sh traefik"',
        'health': None, 'health_forced': None, 'health_test': None, 'restart_policy': 'unless-stopped',
        'ports': {'80/tcp': [{'HostIp': '0.0.0.0', 'HostPort': '80'}], '443/tcp': [{'HostIp': '0.0.0.0', 'HostPort': '443'}]},
        'mounts': [{'src': fd + '/rootfs/var/log/traefik', 'dst': '/var/log/traefik', 'ro': False}],
        'network': COMPOSE_PROJECT + '_default', 'security_opt': None,
    }


def container_health(st, c):
    """-> None (no healthcheck) or 'healthy' / 'unhealthy' / 'starting' for a container right now"""
    if c.get('health') is None:
        return None
    if c['status'] != 'running':
        return c['health']
    if c.get('health_forced'):
        return c['health_forced']
    delay = st['knobs'].get('health_delay', 0)
    if delay and now() - c['started'] < delay:
        return 'starting'
    return c['health']


def container_status_text(st, c):
    """the STATUS column of docker ps"""
    t = now()
    if c['status'] == 'running':
        h = container_health(st, c)
        s = 'Up ' + human_dur(t - c['started']).replace('Less than a second', 'Less than a second')
        if h == 'healthy':
            s += ' (healthy)'
        elif h == 'unhealthy':
            s += ' (unhealthy)'
        elif h == 'starting':
            s += ' (health: starting)'
        return s
    ref = c.get('finished') or c['started']
    if c['status'] == 'restarting':
        return 'Restarting (%d) %s ago' % (c['exit_code'], human_dur(t - ref))
    return 'Exited (%d) %s ago' % (c['exit_code'], human_dur(t - ref))


# ==================================================================================================
# log lines (what `docker logs` returns): [epoch, stream(1|2), text]
# ==================================================================================================
def _q(s):
    """logrus quotes msg with Go %q"""
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def logline(t, level, msg, **kv):
    parts = ['time="%s"' % iso_s(t), 'level=%s' % level, 'msg=%s' % _q(msg)]
    for k in sorted(kv):
        v = str(kv[k])
        parts.append('%s=%s' % (k, _q(v) if re.search(r'[\s"=]', v) or v == '' else v))
    return ' '.join(parts)


def log_add(st, t, level, msg, stream=None, **kv):
    """append a crowdsec log line (stderr like the real process); keeps the last 4000"""
    st['logs'].append([t, stream or 2, logline(t, level, msg, **kv)])
    if len(st['logs']) > 4000:
        del st['logs'][:len(st['logs']) - 4000]


def log_out(st, t, text):
    """entrypoint chatter (stdout)"""
    st['logs'].append([t, 1, text])


def log_lapi(st, t, method, path, code=200, ms=None, ua=None):
    """one LAPI access-log line as gin/logrus print it (module=lapi), e.g. ... "GET /v1/heartbeat HTTP/1.1 200 332.633µs ..."."""
    if ms is None:
        ms = (40.0 if path.endswith('/login') else 1.5) + (int(t * 1e6) % 6000000) / 1e6       # stable, looks measured
    ms = float(ms)
    ua = ua or 'crowdsec/v%s-%s-docker' % (st['version'], _sha8(st['version']))
    log_add(st, t, 'info', '127.0.0.1 - [%s] "%s %s HTTP/1.1 %d %s "%s" "' % (time.strftime('%a, %d %b %Y %H:%M:%S UTC', _gm(t)), method, path, code, go_dur_frac(ms / 1000.0), ua), module='lapi')


def log_startup(st, t, first=True):
    """what a (re)start prints: the entrypoint (stdout) and the process banner (stderr)"""
    ver = 'v%s-%s' % (st['version'], _sha8(st['version']))
    for i, ln in enumerate(['/var/lib/crowdsec/data was found in a volume', 'Local agent already registered',
                            'Check if lapi needs to register an additional agent', '/etc/crowdsec was found in a volume',
                            'Running hub update', 'Skipping hub update, index file is recent', 'Running hub upgrade']):
        log_out(st, t + i * 0.0005, ln)
    log_out(st, t + 0.004, 'Action plan:\n\U0001f504 check & update data files\n')
    log_out(st, t + 0.005, 'Running: cscli  collections install "crowdsecurity/traefik" \nNothing to install or remove.')
    n = 0.006
    for lvl, msg, kv in [('info', 'Crowdsec ' + ver, {}), ('info', 'Enabled feature flags: none', {}),
                         ('info', 'gocron: new scheduler created', {'module': 'db'}), ('info', 'gocron: scheduler started', {'module': 'db'}),
                         ('info', 'Loading grok library /etc/crowdsec/patterns', {}), ('info', 'Loading enrich plugins', {}),
                         ('info', 'Loaded %d scenarios' % len(st['cs']['hub']['items'].get('scenarios', {})), {}),
                         ('info', 'loading acquisition file : /etc/crowdsec/acquis.yaml', {}),
                         ('info', 'Starting processing data', {}), ('info', 'Starting parser routine', {'idx': 0}),
                         ('info', 'Starting bucket routine', {'idx': 0}), ('info', 'Starting output routine', {'idx': 0}),
                         ('info', 'Local API listening on 0.0.0.0:8080', {'module': 'lapi'})]:
        log_add(st, t + n, lvl, msg, **kv)
        n += 0.0005
    log_lapi(st, t + n, 'POST', '/v1/watchers/login', 200, 45.0)


def log_chatter(st, t0, t1):
    """the background noise of a running container in [t0, t1): a heartbeat + a login every 30 s, computed (not stored)"""
    res = []
    k = int(t0 // 30) + 1
    ua = 'crowdsec/v%s-%s-docker' % (st['version'], _sha8(st['version']))
    while k * 30 < t1 and len(res) < 600:
        ts = k * 30 + (k % 7) * 0.13
        res.append([ts, 2, logline(ts, 'info', '127.0.0.1 - [%s] "GET /v1/heartbeat HTTP/1.1 200 %s "%s" "' % (
            time.strftime('%a, %d %b %Y %H:%M:%S UTC', _gm(ts)), '%dµs' % (300 + (k * 37) % 300), ua), module='lapi')])
        k += 1
    return res


# ==================================================================================================
# building the state of a preset
# ==================================================================================================
def fresh_state(preset, version, seed, fdir, traefik):
    t = time.time()
    st = {'schema': STATE_SCHEMA, 'preset': preset, 'created': t, 'clock': 0.0, 'fake_dir': fdir, 'version': version,
          'rng': {'seed': seed, 'n': 0},
          'knobs': {'docker_down': 0, 'lapi_down': 0, 'health_delay': 0, 'restart_fails': 0, 'cscli_slow_ms': 0, 'discord': 0,
                    'empty_json': None, 'capi': 'ok'},
          'traefik': bool(traefik), 'containers': {}, 'logs': [], 'cs': None, 'crash_note': ''}
    return st


def empty_cs(st, t):
    hub = hub_init_items(st)
    return {'alerts': [], 'next_alert': 1, 'next_decision': 15010, 'bouncers': [], 'allowlists': [],
            'machines': [{'id': 'localhost', 'created': t - 300, 'updated': t - 20, 'last_push': None, 'last_heartbeat': t - 20,
                          'version': machine_version(st), 'datasources': {'file': 1}}],
            'hub': hub, 'lapi': {'/v1/heartbeat': {'GET': 3}, '/v1/usage-metrics': {'POST': 1}, '/v1/watchers/login': {'POST': 4}},
            'metrics': {'acquisition': {}, 'parsers': {}, 'scenarios': {}, 'whitelists': {}, 'bouncers': {}, 'stash': {}}}


# --- the `data` dataset -----------------------------------------------------------------------------
_HTTP_META_STATIC = (('datasource_path', '/var/log/traefik/access.log'), ('datasource_type', 'file'), ('http_args_len', '0'),
                     ('http_verb', 'GET'), ('log_type', 'http_access-log'), ('service', 'http'), ('target_fqdn', 'app.example.com'),
                     ('traefik_router_name', 'app@file'))


def _event_meta(sc, geo, ip, path, ua, status, user, ts):
    cn, asname, asnum, _lat, _lon, rng_ = geo
    m = {'ASNNumber': asnum, 'ASNOrg': asname, 'IsInEU': 'true' if cn in EU_CC else 'false', 'IsoCode': cn,
         'SourceRange': rng_, 'source_ip': ip, 'timestamp': ts.replace(' +0000 UTC', 'Z').replace(' ', 'T')}
    if sc['fam'] == 'http':
        for k, v in _HTTP_META_STATIC:
            m[k] = v
        m.update({'http_path': path, 'http_status': status, 'http_user_agent': ua})
    else:
        m.update({'datasource_path': '/var/log/host/auth.log', 'datasource_type': 'file', 'log_type': 'ssh_failed-auth',
                  'machine': 'dcs-hub', 'program': 'sshd', 'service': 'ssh', 'target_user': user})
    return [[k, m[k]] for k in sorted(m)]


def engine_alert(db, t, ip, scenario, events, dur, simulated=False, with_decision=True, age_note=None):
    """an alert the crowdsec engine would have raised (real shape, events with meta, top-level meta)"""
    sc = SCEN[scenario]
    cn, asname, asnum, lat, lon, rng_ = GEO[ip]
    window = {'crowdsecurity/http-probing': 22.183783028}.get(scenario, 0.000339223 * (events or 1))
    start = t - 1 - window if window > 1 else t - 1
    stop = start + window
    n_ev = min(events, sc['cap'] + 1)
    evs = []
    paths = sc.get('paths') or ['']
    users = sc.get('users', ['root'])
    for i in range(n_ev):
        ts_f = start + window * (i / float(max(n_ev, 1)))
        ts_s = go_time(ts_f, 37 * (i + 3))
        meta = _event_meta(sc, GEO[ip], ip, paths[i % len(paths)] if sc['fam'] == 'http' else '', sc.get('ua', ''), sc.get('status', ''), users[i % len(users)], ts_s)
        evs.append({'meta': [{'key': k, 'value': v} for k, v in meta], 'timestamp': ts_s})
    if sc['fam'] == 'http':
        used = paths[:min(len(paths), events)]
        mvals = {'user_agent': json.dumps([sc['ua']], ensure_ascii=False, separators=(',', ':')),
                 'method': '["GET"]', 'status': json.dumps([sc['status']], separators=(',', ':')),
                 'target_uri': json.dumps(used, separators=(',', ':'))}
    else:
        mvals = {'target_user': json.dumps(users[:min(len(users), events)], separators=(',', ':')), 'service': '["ssh"]'}
    msg = "Ip %s performed '%s' (%d events over %s) at %s" % (ip, scenario, events, go_dur_frac(window), go_time(stop, 211))
    a = db.new_alert(t, scenario, kind='crowdsec', scope='Ip', value=ip, message=msg, capacity=sc['cap'], leakspeed=sc['leak'],
                     scenario_hash=sc['hash'], scenario_version=sc['ver'], events_count=events, events=evs,
                     meta=[[k, mvals[k]] for k in sc['mkeys']], start=start, stop=stop, simulated=simulated)
    a['source'] = {'as_name': asname, 'as_number': asnum, 'cn': cn, 'ip': ip, 'latitude': lat, 'longitude': lon, 'range': rng_,
                   'scope': 'Ip', 'value': ip}
    if with_decision:
        a['decisions'].append(db.new_decision('crowdsec', 'ban', 'Ip', ip, scenario, t + dur, simulated))
    return a


def build_data(st, t):
    """the `data` dataset: one alert per local decision plus alerts whose decisions have expired and a CAPI pull;
    times are relative to t (= init time), so `--since 24h` and `--since 7d` differ"""
    cs = empty_cs(st, t)
    cs['machines'][0].update({'created': t - 3 * 86400, 'updated': t - 20, 'last_push': t - 300, 'last_heartbeat': t - 20, 'datasources': {'file': 2}})
    st['cs'] = cs
    db = Db(st)
    H, D = 3600, 86400
    ban = 4 * H
    # (age, ip, scenario, events, has decision, simulated)
    engine = [
        # ---- the older ones: their 4 h bans have expired (two never got a decision at all)
        (6 * D + 2 * H, '61.177.172.13', 'crowdsecurity/ssh-bf', 6, True, False),
        (4 * D + 5 * H, '185.220.101.5', 'crowdsecurity/http-admin-interface-probing', 3, True, False),
        (2 * D + 9 * H, '89.248.165.10', 'crowdsecurity/http-probing', 13, True, False),
        (30 * H, '194.26.135.7', 'crowdsecurity/http-backdoors-attempts', 2, False, False),
        (8 * H + 1200, '5.188.62.76', 'crowdsecurity/http-bad-user-agent', 2, True, False),
        (5 * H + 600, '141.98.11.4', 'crowdsecurity/http-probing', 11, False, False),
        # ---- alerts with an active decision (two IPs appear twice: `decisions list` shows one row per IP)
        (3 * H + 33 * 60, '194.26.135.7', 'crowdsecurity/http-backdoors-attempts', 2, True, False),
        (3 * H + 33 * 60 - 1, '194.26.135.7', 'crowdsecurity/CVE-2017-9841', 1, True, False),
        (3 * H + 5 * 60, '187.19.152.10', 'crowdsecurity/ssh-slow-bf', 11, True, False),
        (2 * H + 51 * 60, '89.248.165.10', 'crowdsecurity/http-probing', 13, True, False),
        (2 * H + 5 * 60, '45.83.64.20', 'crowdsecurity/http-bad-user-agent', 2, True, False),
        (1 * H + 40 * 60, '185.220.101.5', 'crowdsecurity/http-admin-interface-probing', 3, True, False),
        (1 * H + 22 * 60, '116.31.116.24', 'crowdsecurity/ssh-bf', 6, True, False),
        (47 * 60, '91.240.118.11', 'crowdsecurity/http-admin-interface-probing', 3, True, False),
        (47 * 60 - 1, '91.240.118.11', 'crowdsecurity/http-bad-user-agent', 2, True, False),
        (35 * 60, '167.99.224.31', 'crowdsecurity/CVE-2017-9841', 1, True, False),
        (26 * 60, '78.128.113.9', 'crowdsecurity/http-probing', 13, True, True),
    ]
    events = [(t - age, 'engine', dict(ip=ip, scenario=sc, events=ev, dec=dec, sim=sim)) for age, ip, sc, ev, dec, sim in engine]
    events.append((t - 40 * 60, 'manual', dict(scope='Ip', value='192.0.2.10', dur=6 * H, typ='ban', reason='manual test')))
    events.append((t - 20 * 60, 'manual', dict(scope='Range', value='192.0.2.128/25', dur=24 * H, typ='ban', reason='range ban')))
    events.append((t, 'manual', dict(scope='Ip', value='192.0.2.66', dur=87600 * H, typ='ban', reason='permanent test')))
    events.append((t - 90 * 60, 'capi', {}))
    events.sort(key=lambda e: e[0])
    alerts = []
    for ts, kind, p in events:
        if kind == 'engine':
            alerts.append(engine_alert(db, ts, p['ip'], p['scenario'], p['events'], ban, simulated=p['sim'], with_decision=p['dec']))
        elif kind == 'manual':
            alerts.append(db.add_manual(ts, p['scope'], p['value'], p['dur'], p['typ'], p['reason'], store=False))
        else:
            alerts.append(capi_alert(db, ts))
    cs['alerts'] = alerts
    cs['bouncers'] = [
        {'name': 'dcs-traefik-bouncer', 'created': t - 3 * D, 'updated': t - 20, 'ip': '172.18.0.2', 'type': 'crowdsec-traefik-bouncer',
         'version': 'v1.4.4', 'last_pull': t - 20, 'key': db.rng.apikey()},
        {'name': 'test-bouncer', 'created': t - 1 * D, 'updated': t - 1 * D, 'ip': '', 'type': '', 'version': '', 'last_pull': None,
         'key': db.rng.apikey()}]
    if has_allowlists(st):
        cs['allowlists'] = [
            {'name': 'dcs', 'description': 'DCS test allowlist', 'created': t - 2 * D, 'updated': t - 5 * 60, 'items': [
                {'value': '203.0.113.9', 'description': 'office', 'created': t - 2 * D, 'expiration': None},
                {'value': '198.51.100.0/24', 'description': 'range with expiry', 'created': t - 2 * D + 1, 'expiration': t + 29 * D},
                {'value': '2001:db8::/32', 'description': 'v6', 'created': t - 2 * D + 2, 'expiration': None}]},
            {'name': 'vendor', 'description': 'vendor scanners', 'created': t - 1 * D, 'updated': t - 1 * D, 'items': [
                {'value': '192.0.2.77', 'description': 'vendor scanner', 'created': t - 1 * D, 'expiration': None}]}]
    # hub: one installed collection is behind the catalog (`hub upgrade` has something to do)
    cs['hub'] = hub_init_items(st, {('collections', 'crowdsecurity/sshd'): '0.8'})
    cs['lapi'] = {'/v1/alerts': {'GET': 412, 'POST': 20}, '/v1/alerts/:alert_id': {'GET': 3},
                  '/v1/allowlists/check/:ip_or_range': {'GET': 41}, '/v1/decisions/stream': {'GET': 1380},
                  '/v1/heartbeat': {'GET': 812}, '/v1/usage-metrics': {'POST': 24}, '/v1/watchers/login': {'POST': 655}}
    cs['metrics'] = data_metrics()
    return st


def capi_alert(db, t):
    """the community blocklist pull: one alert (kind capi, machine N/A) with 40 decisions of origin CAPI.
    These decisions took the small ids (1..40): the local ones start at 15010 like in the real container."""
    a = db.new_alert(t, 'update : +40/-0 IPs', kind='capi', scope='crowdsecurity/community-blocklist', value='', message='',
                     remediation=True, leakspeed='', events_count=0, capi=True)
    a['machine'] = 'N/A'
    a['uuid'] = None
    a['source'] = {'scope': 'crowdsecurity/community-blocklist', 'value': ''}
    pool = (23, 31, 37, 45, 46, 62, 77, 79, 80, 89, 91, 94, 103, 109, 116, 141, 152, 154, 159, 176, 178, 185, 188, 193, 195, 212, 217)
    used = set()
    for i in range(40):
        while True:
            ip = '%d.%d.%d.%d' % (db.rng.choice(pool), db.rng.randint(0, 255), db.rng.randint(0, 255), db.rng.randint(1, 254))
            if ip not in used and ip not in GEO:
                used.add(ip)
                break
        a['decisions'].append({'id': i + 1, 'origin': 'CAPI', 'type': 'ban', 'scope': 'Ip', 'value': ip, 'simulated': False,
                               'scenario': 'http:exploit' if i % 9 == 4 else 'http:scan',
                               'until': t + 7 * 86400 - db.rng.randint(0, 3 * 3600)})
    return a


def data_metrics():
    def par(hits, parsed=None, unparsed=None):
        o = {'hits': hits}
        if parsed is not None:
            o['parsed'] = parsed
        if unparsed:
            o['unparsed'] = unparsed
        return o
    return {
        'acquisition': {'file:/var/log/traefik/access.log': {'parsed': 12507, 'pour': 9120, 'reads': 12841, 'unparsed': 334},
                        'file:/var/log/traefik/traefik.log': {'parsed': 198, 'pour': 0, 'reads': 210, 'unparsed': 12}},
        'parsers': {'child-child-crowdsecurity/traefik-logs': par(25682, 12841, 12841), 'child-crowdsecurity/http-logs': par(38523, 25682, 12841),
                    'child-crowdsecurity/traefik-logs': par(25682, 12841, 12841), 'crowdsecurity/cdn-whitelist': par(211, 211),
                    'crowdsecurity/dateparse-enrich': par(12705, 12705), 'crowdsecurity/geoip-enrich': par(12705, 12705),
                    'crowdsecurity/google-special-crawlers-whitelist': par(38, 38), 'crowdsecurity/http-logs': par(12705, 12705),
                    'crowdsecurity/non-syslog': par(13051, 13051), 'crowdsecurity/public-dns-allowlist': par(12705, 12705),
                    'crowdsecurity/rdns': par(249, 249), 'crowdsecurity/seo-bots-whitelist': par(64, 64),
                    'crowdsecurity/traefik-logs': par(13051, 12705, 346), 'crowdsecurity/whitelists': par(12705, 12705)},
        'scenarios': {'crowdsecurity/CVE-2017-9841': {'curr_count': 0, 'instantiation': 2, 'overflow': 2, 'pour': 2},
                      'crowdsecurity/http-admin-interface-probing': {'curr_count': 0, 'instantiation': 41, 'overflow': 3, 'pour': 640, 'underflow': 38},
                      'crowdsecurity/http-backdoors-attempts': {'curr_count': 0, 'instantiation': 9, 'overflow': 2, 'pour': 31, 'underflow': 7},
                      'crowdsecurity/http-bad-user-agent': {'curr_count': 0, 'instantiation': 88, 'overflow': 4, 'pour': 402},
                      'crowdsecurity/http-crawl-non_statics': {'curr_count': 1, 'instantiation': 134, 'pour': 5230, 'underflow': 133},
                      'crowdsecurity/http-probing': {'curr_count': 2, 'instantiation': 96, 'overflow': 3, 'pour': 2815, 'underflow': 91},
                      'crowdsecurity/ssh-bf': {'curr_count': 0, 'instantiation': 14, 'overflow': 1, 'pour': 40, 'underflow': 13},
                      'crowdsecurity/ssh-slow-bf': {'curr_count': 0, 'instantiation': 6, 'overflow': 1, 'pour': 21, 'underflow': 5}},
        'whitelists': {'crowdsecurity/cdn-whitelist': {'CDN provider': {'hits': 211}},
                       'crowdsecurity/google-special-crawlers-whitelist': {'Google special crawlers ip range': {'hits': 38}},
                       'crowdsecurity/public-dns-allowlist': {'public DNS server': {'hits': 12705}},
                       'crowdsecurity/seo-bots-whitelist': {'good bots (search engine crawlers)': {'hits': 64}},
                       'crowdsecurity/whitelists': {'private ipv4/ipv6 ip/ranges': {'hits': 12705}}},
        'bouncers': {}, 'stash': {}, 'lapi-bouncer': {'dcs-traefik-bouncer': {'/v1/decisions/stream': {'GET': 1380}}}, 'lapi-decisions': {},
    }


# --- presets ------------------------------------------------------------------------------------
PRESETS = ('absent', 'defined', 'stopped', 'crashloop', 'starting', 'unhealthy', 'lapi-down', 'empty', 'data', 'old')


def build_preset(preset, version, seed, fdir, traefik):
    if preset not in PRESETS:
        fail('%s: unknown preset %r (one of: %s)' % (PROG, preset, ' '.join(PRESETS)), 2)
    if preset == 'old' and version == DEFAULT_VERSION:
        version = '1.6.5'
    st = fresh_state(preset, version, seed, fdir, traefik)
    t = st['created']
    if traefik:
        st['containers']['Traefik'] = make_traefik_container(st, t)
    if preset in ('absent', 'defined'):
        return st
    c = make_crowdsec_container(st, t - 2 * 3600)
    st['containers']['CrowdSec'] = c
    if preset == 'empty':
        st['cs'] = empty_cs(st, t)
        c['started'] = t - 300
        c['created'] = t - 300
    else:
        build_data(st, t)
        c['created'] = t - 3 * 86400
        c['started'] = t - 2 * 3600
    if preset == 'stopped':
        c.update({'status': 'exited', 'exit_code': 137, 'health': None, 'finished': t - 180, 'started': t - 3 * 3600})
    elif preset == 'crashloop':
        c.update({'status': 'restarting', 'restart_count': 17, 'exit_code': 1, 'health': None, 'finished': t - 13, 'started': t - 12})
        st['crash_note'] = 'while loading profiles for LAPI: while decoding /etc/crowdsec/profiles.yaml: [7:4] value is not allowed in this context'
    elif preset == 'starting':
        c.update({'health_forced': 'starting', 'started': t - 5})
    elif preset == 'unhealthy':
        c['health'] = 'unhealthy'
    elif preset == 'lapi-down':
        st['knobs']['lapi_down'] = 1
    if preset == 'old':
        st['cs']['hub'] = hub_init_items(st)
        st['cs']['allowlists'] = []
    seed_logs(st, t)
    return st


def seed_logs(st, t):
    c = st['containers']['CrowdSec']
    if c['status'] == 'restarting':
        k = 17
        while k >= 1:
            ts = t - 12 - (17 - k) * 31
            log_out(st, ts - 1, 'Skipping hub update, index file is recent')
            log_add(st, ts, 'fatal', st['crash_note'] or 'crowdsec init: configuration error')
            k -= 1
        st['logs'].sort(key=lambda x: x[0])
        return
    if c['status'] == 'exited':
        log_startup(st, c['started'])
        log_add(st, c['finished'] - 0.5, 'info', 'Shutting down')
        log_add(st, c['finished'], 'info', 'crowdsec shutdown')
        return
    log_startup(st, c['started'])


# ==================================================================================================
# the container's file system (a real directory tree under $FAKE_CS_DIR/rootfs)
# ==================================================================================================
class FS(object):
    def __init__(self, st):
        self.root = os.path.join(st['fake_dir'], 'rootfs')

    def host(self, cpath):
        p = os.path.normpath('/' + (cpath or '/'))
        return os.path.join(self.root, p.lstrip('/')) if p != '/' else self.root

    def read(self, cpath):
        try:
            with open(self.host(cpath), 'rb') as f:
                return f.read().decode('utf-8', 'replace')
        except (IOError, OSError):
            return None

    def write(self, cpath, text, mode=None):
        h = self.host(cpath)
        os.makedirs(os.path.dirname(h), exist_ok=True)
        with open(h, 'wb') as f:
            f.write(text.encode('utf-8') if isinstance(text, str) else text)
        if mode:
            os.chmod(h, mode)

    def exists(self, cpath):
        return os.path.lexists(self.host(cpath))

    def isdir(self, cpath):
        return os.path.isdir(self.host(cpath))

    def isfile(self, cpath):
        return os.path.isfile(self.host(cpath))

    def listdir(self, cpath):
        try:
            return sorted(os.listdir(self.host(cpath)))
        except OSError:
            return None

    def mkdirs(self, cpath):
        os.makedirs(self.host(cpath), exist_ok=True)

    def remove(self, cpath):
        h = self.host(cpath)
        if os.path.isdir(h) and not os.path.islink(h):
            import shutil
            shutil.rmtree(h)
        elif os.path.lexists(h):
            os.remove(h)


ACQUIS_TRAEFIK = '''# Traefik's JSON access log and its own log, mounted read-only from the proxy stack's App-Data
---
filenames:
  - /var/log/traefik/access.log
labels:
  type: traefik
---
filenames:
  - /var/log/traefik/traefik.log
labels:
  type: traefik
'''


def init_rootfs(st):
    """(re)create the files of the container in rootfs/ for the state's preset"""
    import shutil
    fs = FS(st)
    if os.path.isdir(fs.root):
        shutil.rmtree(fs.root)
    os.makedirs(fs.root)
    for d in ('tmp', 'etc/crowdsec/acquis.d', 'etc/crowdsec/hub', 'etc/crowdsec/notifications', 'var/lib/crowdsec/data',
              'var/log/traefik', 'var/log/host'):
        os.makedirs(os.path.join(fs.root, d), exist_ok=True)
    if 'CrowdSec' not in st['containers']:
        return
    for p, text in STOCK_FILES.items():
        fs.write(p, text)
    rng = Rng(st)
    fs.write('/etc/crowdsec/local_api_credentials.yaml', 'url: http://0.0.0.0:8080\nlogin: localhost\npassword: %s\n' % rng.hexstr(64), 0o600)
    fs.write('/etc/crowdsec/online_api_credentials.yaml', 'url: https://api.crowdsec.net/\nlogin: %s\npassword: %s\n' % (rng.hexstr(32), rng.hexstr(32)), 0o600)
    if st['preset'] != 'empty':
        fs.write('/etc/crowdsec/acquis.d/traefik.yaml', ACQUIS_TRAEFIK)
    fs.write('/var/log/traefik/access.log', '')
    fs.write('/var/log/traefik/traefik.log', '')
    if st['knobs'].get('discord'):
        apply_discord(st, True)


def apply_discord(st, on):
    """--mock-set discord=1: what the DCS API installs (profiles.yaml + a rendered http.yaml); discord=0 restores the stock files"""
    fs = FS(st)
    if on:
        fs.write('/etc/crowdsec/profiles.yaml', DCS_PROFILES_YAML)
        fs.write('/etc/crowdsec/notifications/http.yaml',
                 DCS_DISCORD_YAML.replace('@@WEBHOOK@@', 'https://discord.com/api/webhooks/1234/lab').replace('@@DOMAIN@@', 'lab.example.com'))
    else:
        fs.write('/etc/crowdsec/profiles.yaml', STOCK_FILES['/etc/crowdsec/profiles.yaml'])
        fs.write('/etc/crowdsec/notifications/http.yaml', STOCK_FILES['/etc/crowdsec/notifications/http.yaml'])


# ==================================================================================================
# a Go text/template subset for `docker ... --format`: {{.A.B}} {{json .}} {{.Label "k"}} {{index .M "k"}}
# {{if}}/{{else}}/{{end}} {{range}} eq ne and or not len println printf join lower upper
# ==================================================================================================
class TmplError(Exception):
    pass


class Ctx(object):
    """the value docker's formatter hands to templates for `docker ps`: a struct, not a map"""

    def __init__(self, fields, labels):
        self.fields = fields
        self.labels = labels


def _t_tokens(text):
    """-> list of ('text', s) / ('act', inner, offset)"""
    res = []
    pos = 0
    while True:
        i = text.find('{{', pos)
        if i < 0:
            res.append(('text', text[pos:]))
            break
        if i > pos:
            res.append(('text', text[pos:i]))
        j = text.find('}}', i)
        if j < 0:
            raise TmplError('template: :1: unclosed action')
        raw = text[i + 2:j]
        res.append(('act', raw.strip('- '), i + 2 + (len(raw) - len(raw.lstrip('- ')))))
        pos = j + 2
    return res


def _t_parse(toks, i=0, stop=()):
    """-> (nodes, next_index, stop_keyword)"""
    nodes = []
    while i < len(toks):
        tk = toks[i]
        if tk[0] == 'text':
            nodes.append(('text', tk[1]))
            i += 1
            continue
        inner = tk[1]
        word = inner.split(None, 1)[0] if inner else ''
        if word in ('end', 'else'):
            if word in stop or 'end' in stop:
                return nodes, i, word
            raise TmplError('template: :1: unexpected {{%s}}' % word)
        if word in ('if', 'range', 'with'):
            cond = inner[len(word):].strip()
            body, i2, kw = _t_parse(toks, i + 1, ('end', 'else'))
            other = []
            if kw == 'else':
                other, i2, kw = _t_parse(toks, i2 + 1, ('end',))
            if kw != 'end':
                raise TmplError('template: :1: unexpected EOF')
            nodes.append((word, cond, body, other, tk[2]))
            i = i2 + 1
            continue
        nodes.append(('act', inner, tk[2]))
        i += 1
    return nodes, i, None


def _t_words(s):
    """split an action into operands: strings, parenthesised groups, |, words"""
    res = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in ' \t\n':
            i += 1
        elif c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == '\\' else 1
            res.append(('str', json.loads(s[i:j + 1])))
            i = j + 1
        elif c == '`':
            j = s.find('`', i + 1)
            res.append(('str', s[i + 1:j]))
            i = j + 1
        elif c == '(':
            depth, j = 1, i + 1
            while j < n and depth:
                depth += (s[j] == '(') - (s[j] == ')')
                j += 1
            res.append(('sub', s[i + 1:j - 1]))
            i = j
        elif c == '|':
            res.append(('pipe', '|'))
            i += 1
        else:
            j = i
            while j < n and s[j] not in ' \t\n|()':
                j += 1
            res.append(('word', s[i:j], i))
            i = j
    return res


def _go_str(v):
    if v is None:
        return '<nil>'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, dict) and set(v) == {'Test', 'Interval', 'Timeout', 'StartPeriod', 'Retries'}:
        # {{.Config.Healthcheck}} is a Go struct: {[CMD-SHELL cscli version] 30s 5s 15s 0s 3}
        def d(ns):
            return go_dur(ns / 1e9)
        return '{%s %s %s %s 0s %d}' % (_go_str(v['Test']), d(v['Interval']), d(v['Timeout']), d(v['StartPeriod']), v['Retries'])
    if isinstance(v, dict):
        return 'map[' + ' '.join('%s:%s' % (k, _go_str(v[k])) for k in sorted(v)) + ']'
    if isinstance(v, (list, tuple)):
        return '[' + ' '.join(_go_str(x) for x in v) + ']'
    return str(v)


_OPTIONAL_KEYS = ('Health', 'Healthcheck', 'ExposedPorts')     # pointer/omitted fields of `docker inspect`


def _t_field(cur, chain, off, expr):
    """resolve .A.B.C on a value (off = column of the first dot); error texts follow Go's for maps (docker inspect)
    and for structs (docker ps)"""
    pos = off
    for name in chain:
        if isinstance(cur, Ctx):
            if name in cur.fields:
                cur = cur.fields[name]
            else:
                raise TmplError('failed to execute template: template: :1:%d: executing "" at <%s>: can\'t evaluate field %s in type *formatter.ContainerContext' % (pos, expr, name))
        elif isinstance(cur, dict):
            if name not in cur:
                if name in _OPTIONAL_KEYS and name == chain[-1]:
                    return None          # docker first runs the template on typed structs, where an absent pointer field is nil
                raise TmplError('template parsing error: template: :1:%d: executing "" at <%s>: map has no entry for key "%s"' % (pos, expr, name))
            cur = cur[name]
        else:
            raise TmplError('template parsing error: template: :1:%d: executing "" at <%s>: nil pointer evaluating %s' % (pos, expr, name))
        pos += len(name) + 1
    return cur


def _t_eval_pipeline(src, dot, off=0):
    words = _t_words(src)
    val = None
    have = False
    cmd = []
    cmds = []
    for w in words:
        if w[0] == 'pipe':
            cmds.append(cmd)
            cmd = []
        else:
            cmd.append(w)
    cmds.append(cmd)
    for cmd in cmds:
        val = _t_eval_cmd(cmd, dot, val if have else None, have, off, src)
        have = True
    return val


def _t_operand(w, dot, off, src):
    if w[0] == 'str':
        return w[1]
    if w[0] == 'sub':
        return _t_eval_pipeline(w[1], dot, off)
    tok = w[1]
    if tok == '.':
        return dot
    if tok.startswith('.'):
        return _t_field(dot, tok[1:].split('.'), off + (w[2] if len(w) > 2 else 0), tok)
    if tok in ('true', 'false'):
        return tok == 'true'
    if tok == 'nil':
        return None
    if re.match(r'^-?\d+$', tok):
        return int(tok)
    if tok.startswith('$'):
        return dot
    raise TmplError('template: :1: function "%s" not defined' % tok)


def _t_eval_cmd(cmd, dot, piped, have, off, src):
    first = cmd[0]
    args_words = cmd[1:]
    if first[0] == 'word' and not first[1].startswith('.') and first[1] not in ('true', 'false', 'nil') and not re.match(r'^-?\d', first[1]) and not first[1].startswith('$'):
        fn = first[1]
        args = [_t_operand(a, dot, off, src) for a in args_words]
        if have:
            args.append(piped)
        return _t_call(fn, args)
    # a field, possibly followed by arguments (method call: .Label "k")
    if first[0] == 'word' and first[1].startswith('.') and args_words:
        parts = first[1][1:].split('.')
        meth = parts[-1]
        base = _t_field(dot, parts[:-1], off + first[2], first[1]) if len(parts) > 1 else dot
        if isinstance(base, Ctx) and meth == 'Label':
            key = _t_operand(args_words[0], dot, off, src)
            return base.labels.get(key, '')
        raise TmplError('template: :1: can\'t call method/function "%s" with %d args' % (meth, len(args_words)))
    return _t_operand(first, dot, off, src)


def _t_call(fn, args):
    if fn == 'json':
        v = args[0]
        if isinstance(v, Ctx):
            v = v.fields
        return gojson_compact(v)
    if fn == 'index':
        cur = args[0]
        for k in args[1:]:
            if isinstance(cur, dict):
                cur = cur.get(k, '')
            elif isinstance(cur, (list, tuple)):
                cur = cur[k]
            else:
                raise TmplError('error calling index: cannot index slice/array with nil')
        return cur
    if fn == 'eq':
        return any(args[0] == a for a in args[1:])
    if fn == 'ne':
        return args[0] != args[1]
    if fn == 'not':
        return not args[0]
    if fn == 'and':
        for a in args:
            if not a:
                return a
        return args[-1]
    if fn == 'or':
        for a in args:
            if a:
                return a
        return args[-1]
    if fn == 'len':
        return len(args[0])
    if fn in ('print', 'println'):
        s = ' '.join(_go_str(a) for a in args)
        return s + '\n' if fn == 'println' else s
    if fn == 'printf':
        try:
            return args[0] % tuple(args[1:])
        except (TypeError, ValueError):
            return args[0]
    if fn == 'join':
        return args[1].join(str(x) for x in args[0])
    if fn == 'lower':
        return str(args[0]).lower()
    if fn == 'upper':
        return str(args[0]).upper()
    if fn == 'split':
        return str(args[0]).split(args[1])
    if fn == 'title':
        return str(args[0]).title()
    if fn == 'truncate':
        return str(args[0])[:int(args[1])]
    raise TmplError('template: :1: function "%s" not defined' % fn)


def _t_truthy(v):
    if isinstance(v, Ctx):
        return True
    return bool(v)


def _t_exec(nodes, dot, outbuf):
    for nd in nodes:
        kind = nd[0]
        if kind == 'text':
            outbuf.append(nd[1])
        elif kind == 'act':
            v = _t_eval_pipeline(nd[1], dot, nd[2])
            outbuf.append(_go_str(v) if not isinstance(v, str) else v)
        elif kind == 'if':
            if _t_truthy(_t_eval_pipeline(nd[1], dot, nd[4])):
                _t_exec(nd[2], dot, outbuf)
            else:
                _t_exec(nd[3], dot, outbuf)
        elif kind == 'with':
            v = _t_eval_pipeline(nd[1], dot, nd[4])
            if _t_truthy(v):
                _t_exec(nd[2], v, outbuf)
            else:
                _t_exec(nd[3], dot, outbuf)
        elif kind == 'range':
            v = _t_eval_pipeline(nd[1], dot, nd[4])
            items = list(v.values()) if isinstance(v, dict) else (v or [])
            if items:
                for it in items:
                    _t_exec(nd[2], it, outbuf)
            else:
                _t_exec(nd[3], dot, outbuf)


def render_template(fmt, dot, unescape=False):
    """unescape: docker ps/images turn a literal backslash-t / backslash-n of --format into a tab / newline first"""
    if unescape:
        fmt = fmt.replace('\\t', '\t').replace('\\n', '\n')
    nodes, _i, _kw = _t_parse(_t_tokens(fmt))
    buf = []
    _t_exec(nodes, dot, buf)
    return ''.join(buf)


# ==================================================================================================
# the docker CLI
# ==================================================================================================
class Run(object):
    """one invocation: the loaded state, whether it has to be saved, work to do after the lock is released"""

    def __init__(self, st, fdir):
        self.st = st
        self.fdir = fdir
        self.dirty = False
        self.after = []
        self.stdin_data = None
        self.pass_stdin = False

    def touch(self):
        self.dirty = True

    def fs(self):
        return FS(self.st)

    def read_stdin(self):
        if not self.pass_stdin:
            return ''
        if self.stdin_data is None:
            self.stdin_data = sys.stdin.buffer.read().decode('utf-8', 'replace')
        return self.stdin_data


def unsupported(run, argv, what=None):
    line = '%s: unsupported: %s' % (PROG, ' '.join(argv))
    err(line)
    try:
        with open(os.path.join(run.fdir, 'unsupported.log'), 'a') as f:
            f.write('%s\t%s\n' % (int(time.time()), ' '.join(argv)))
    except (IOError, OSError):
        pass
    raise Exit(1)


DAEMON_DOWN = 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?'


def find_container(st, name):
    """docker resolves a name, an id or an id prefix; CrowdSec and Traefik are the only containers"""
    if not name:
        return None
    for c in st['containers'].values():
        if name == c['name'] or name == '/' + c['name'] or (len(name) >= 3 and re.match(r'^[0-9a-f]+$', name) and c['id'].startswith(name)):
            return c
    return None


def _dt_text(t):
    return time.strftime('%Y-%m-%d %H:%M:%S +0000 UTC', _gm(t))


def ports_text(c):
    items = []
    for cport, binds in sorted((c.get('ports') or {}).items(), key=lambda kv: int(kv[0].split('/')[0])):
        if binds:
            for b in binds:
                items.append('%s:%s->%s' % (b['HostIp'], b['HostPort'], cport))
        else:
            items.append(cport)
    return ', '.join(items)


def ps_fields(st, c):
    t = now()
    mounts = []
    for m in c['mounts']:
        n = m['src']
        mounts.append(n if len(n) <= 15 else n[:14] + '\u2026')
    labels = ','.join('%s=%s' % (k, v) for k, v in sorted(c['labels']))
    return {'Command': c['command'], 'CreatedAt': _dt_text(c['created']), 'ID': c['id'][:12], 'Image': c['image'],
            'Labels': labels, 'LocalVolumes': '0', 'Mounts': ','.join(mounts), 'Names': c['name'], 'Networks': c['network'],
            'Platform': None, 'Ports': ports_text(c), 'RunningFor': human_dur(t - c['created']) + ' ago',
            'Size': '0B (virtual 438MB)' if c['name'] == 'CrowdSec' else '0B (virtual 224MB)', 'State': c['status'],
            'Status': container_status_text(st, c)}


def _parse_flags(argv, spec):
    """tiny getopt for the docker sub-commands. spec: {'-a': ('all', False), '--filter': ('filter', True, True)} =
    flag -> (dest, takes a value[, repeatable]). Returns (opts, positional arguments)."""
    opts, pos = {}, []

    def store(s, val):
        if len(s) > 2 and s[2]:
            opts.setdefault(s[0], []).append(val)
        else:
            opts[s[0]] = val
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--':
            pos.extend(argv[i + 1:])
            break
        if a.startswith('--') and '=' in a:
            key, val = a.split('=', 1)
            s = spec.get(key)
            if s is None:
                raise Exit(_flag_err(a))
            store(s, val) if s[1] else opts.__setitem__(s[0], val not in ('false', '0'))
        elif a.startswith('-') and a != '-':
            s = spec.get(a)
            if s is None and not a.startswith('--') and len(a) > 2 and all(spec.get('-' + ch, (0, True))[1] is False for ch in a[1:]):
                for ch in a[1:]:                       # -aq: a cluster of boolean short flags
                    opts[spec['-' + ch][0]] = True
                i += 1
                continue
            if s is None:
                raise Exit(_flag_err(a))
            if s[1]:
                i += 1
                if i >= len(argv):
                    err('flag needs an argument: %s' % a)
                    raise Exit(125)
                store(s, argv[i])
            else:
                opts[s[0]] = True
        else:
            pos.append(a)
        i += 1
    return opts, pos


def _flag_err(a):
    if a.startswith('--'):
        err('unknown flag: %s' % a.split('=')[0])
    else:
        err("unknown shorthand flag: '%s' in %s" % (a[1:2], a))
    err("\nUsage:  docker [OPTIONS] COMMAND [ARG...]\n\nRun 'docker --help' for more information")
    return 125


def docker_ps(run, argv):
    st = run.st
    opts, _pos = _parse_flags(argv, {'-a': ('all', False), '--all': ('all', False), '-q': ('quiet', False), '--quiet': ('quiet', False),
                                    '-f': ('filter', True, True), '--filter': ('filter', True, True), '--format': ('format', True),
                                    '-n': ('last', True), '--last': ('last', True), '-l': ('latest', False), '--latest': ('latest', False),
                                    '-s': ('size', False), '--size': ('size', False), '--no-trunc': ('notrunc', False)})
    rows = sorted(st['containers'].values(), key=lambda c: -c['created'])
    res = []
    for c in rows:
        if not opts.get('all') and c['status'] not in ('running', 'restarting'):
            continue
        ok = True
        for f in opts.get('filter', []):
            k, _, v = f.partition('=')
            if k == 'label':
                lk, _, lv = v.partition('=')
                lab = dict(c['labels'])
                ok = ok and lk in lab and ('=' not in v or lab.get(lk) == lv)
            elif k == 'name':
                ok = ok and re.search(v, c['name']) is not None
            elif k == 'status':
                ok = ok and c['status'] == v
            elif k == 'id':
                ok = ok and c['id'].startswith(v)
            elif k == 'ancestor':
                ok = ok and (c['image'] == v or c['image'].split(':')[0] == v)
            elif k == 'health':
                ok = ok and container_health(st, c) == v
            elif k == 'exited':
                ok = ok and c['status'] == 'exited' and str(c['exit_code']) == v
            else:
                err('Error response from daemon: invalid filter \'%s\'' % k)
                raise Exit(1)
        if ok:
            res.append(c)
    if opts.get('latest'):
        res = res[:1]
    if opts.get('last') and int(opts['last']) > 0:
        res = res[:int(opts['last'])]
    if opts.get('quiet') and not opts.get('format'):
        for c in res:
            out(c['id'] if opts.get('notrunc') else c['id'][:12])
        return
    fmt = opts.get('format')
    if fmt is None:
        header = ['CONTAINER ID', 'IMAGE', 'COMMAND', 'CREATED', 'STATUS', 'PORTS', 'NAMES']
        rowsx = []
        for c in res:
            f = ps_fields(st, c)
            rowsx.append([c['id'] if opts.get('notrunc') else f['ID'], f['Image'], f['Command'], f['RunningFor'], f['Status'], f['Ports'], f['Names']])
        _print_table(header, rowsx)
        return
    is_table = fmt.startswith('table')
    if is_table:
        fmt = fmt[5:].lstrip() or '{{.ID}}\t{{.Image}}\t{{.Command}}\t{{.RunningFor}}\t{{.Status}}\t{{.Ports}}\t{{.Names}}'
        heads = [m.group(1) or m.group(2) for m in re.finditer(r'\{\{\s*\.(\w+)|\{\{\s*\.Label\s+"([^"]+)"', fmt)]
        rowsx = []
    for c in res:
        f = ps_fields(st, c)
        ctx = Ctx(f, dict(c['labels']))
        try:
            text = render_template(fmt, ctx, True)
        except TmplError as e:
            err(str(e))
            raise Exit(1)
        if is_table:
            rowsx.append(text.split('\t'))
        else:
            out(text)
    if is_table:
        _print_table([h.upper() for h in heads], rowsx)


def _print_table(header, rows):
    widths = [len(h) for h in header]
    for r in rows:
        for i, cell in enumerate(r):
            widths[i] = max(widths[i], len(cell))
    def line(cells):
        return '   '.join(pad(cells[i], widths[i]) if i < len(cells) - 1 else cells[i] for i in range(len(cells)))
    out(line(header))
    for r in rows:
        out(line(r))


def inspect_obj(st, c):
    """`docker inspect` JSON for a container, keys in docker's order"""
    t = now()
    cid = c['id']
    running = c['status'] in ('running', 'restarting')
    h = container_health(st, c) if c.get('health') is not None else None
    state = {'Status': c['status'], 'Running': running, 'Paused': False, 'Restarting': c['status'] == 'restarting',
             'OOMKilled': False, 'Dead': False, 'Pid': c['pid'] if c['status'] == 'running' else 0, 'ExitCode': c['exit_code'],
             'Error': '', 'StartedAt': iso_ns(c['started'], 11), 'FinishedAt': iso_ns(c['finished'], 12) if c.get('finished') else '0001-01-01T00:00:00Z'}
    if h is not None:
        log = []
        if h == 'healthy' or h == 'unhealthy':
            n = max(1, min(5, int((t - c['started']) // 30)))
            for k in range(n, 0, -1):
                end = t - (k - 1) * 30 - 0.03
                log.append({'Start': iso_ns(end - 0.034, 20 + k), 'End': iso_ns(end, 30 + k), 'ExitCode': 0 if h == 'healthy' else -1,
                            'Output': version_text(st) if h == 'healthy' else 'Health check exceeded timeout (5s)'})
        state['Health'] = {'Status': h, 'FailingStreak': 0 if h != 'unhealthy' else 3, 'Log': log}
    hostcfg = {
        'Binds': ['%s:%s%s' % (m['src'], m['dst'], ':ro' if m['ro'] else '') for m in c['mounts']], 'ContainerIDFile': '',
        'LogConfig': {'Type': 'json-file', 'Config': {}}, 'NetworkMode': c['network'], 'PortBindings': {k: v for k, v in (c.get('ports') or {}).items() if v},
        'RestartPolicy': {'Name': c['restart_policy'], 'MaximumRetryCount': 0}, 'AutoRemove': False, 'VolumeDriver': '', 'VolumesFrom': None,
        'ConsoleSize': [0, 0], 'CapAdd': None, 'CapDrop': None, 'CgroupnsMode': 'private', 'Dns': None, 'DnsOptions': [], 'DnsSearch': [],
        'ExtraHosts': None, 'GroupAdd': None, 'IpcMode': 'private', 'Cgroup': '', 'Links': None, 'OomScoreAdj': 0, 'PidMode': '',
        'Privileged': False, 'PublishAllPorts': False, 'ReadonlyRootfs': False, 'SecurityOpt': c.get('security_opt'), 'UTSMode': '',
        'UsernsMode': '', 'ShmSize': 67108864, 'Runtime': 'runc', 'Isolation': '', 'CpuShares': 0, 'Memory': 0, 'NanoCpus': 0,
        'CgroupParent': '', 'BlkioWeight': 0, 'BlkioWeightDevice': [], 'BlkioDeviceReadBps': [], 'BlkioDeviceWriteBps': [],
        'BlkioDeviceReadIOps': [], 'BlkioDeviceWriteIOps': [], 'CpuPeriod': 0, 'CpuQuota': 0, 'CpuRealtimePeriod': 0,
        'CpuRealtimeRuntime': 0, 'CpusetCpus': '', 'CpusetMems': '', 'Devices': [], 'DeviceCgroupRules': None, 'DeviceRequests': None,
        'MemoryReservation': 0, 'MemorySwap': 0, 'MemorySwappiness': None, 'OomKillDisable': None, 'PidsLimit': None, 'Ulimits': [],
        'CpuCount': 0, 'CpuPercent': 0, 'IOMaximumIOps': 0, 'IOMaximumBandwidth': 0,
        'MaskedPaths': ['/proc/acpi', '/proc/asound', '/proc/interrupts', '/proc/kcore', '/proc/keys', '/proc/latency_stats',
                        '/proc/sched_debug', '/proc/scsi', '/proc/timer_list', '/proc/timer_stats', '/sys/devices/virtual/powercap',
                        '/sys/firmware'],
        'ReadonlyPaths': ['/proc/bus', '/proc/fs', '/proc/irq', '/proc/sys', '/proc/sysrq-trigger']}
    config = {'Hostname': cid[:12], 'Domainname': '', 'User': '', 'AttachStdin': False, 'AttachStdout': False, 'AttachStderr': False}
    if c.get('ports'):
        config['ExposedPorts'] = {k: {} for k in c['ports']}
    config.update({'Tty': False, 'OpenStdin': False, 'StdinOnce': False, 'Env': c['env'], 'Cmd': c.get('cmd')})
    if c.get('health_test'):
        config['Healthcheck'] = {'Test': ['CMD-SHELL', ' '.join(c['health_test'][1:])], 'Interval': 30000000000, 'Timeout': 5000000000,
                                 'StartPeriod': 15000000000, 'Retries': 3}
    config.update({'Image': c['image'], 'Volumes': None, 'WorkingDir': '/', 'Entrypoint': c['entrypoint'], 'Labels': dict(sorted(c['labels']))})
    sid = cid[::-1]
    nets = {'IPAMConfig': None, 'Links': None, 'Aliases': None, 'DriverOpts': None, 'GwPriority': 0, 'NetworkID': sid,
            'EndpointID': cid[10:] + cid[:10], 'Gateway': '172.18.0.1', 'IPAddress': c['ip'] if running else '', 'MacAddress': c['mac'] if running else '',
            'IPPrefixLen': 16 if running else 0, 'IPv6Gateway': '', 'GlobalIPv6Address': '', 'GlobalIPv6PrefixLen': 0, 'DNSNames': None}
    path = '/var/lib/docker/containers/' + cid
    return {'Id': cid, 'Created': iso_ns(c['created'], 13), 'Path': c['entrypoint'][0], 'Args': c['entrypoint'][1:] + (c.get('cmd') or []),
            'State': state, 'Image': c['image_id'], 'ResolvConfPath': path + '/resolv.conf', 'HostnamePath': path + '/hostname',
            'HostsPath': path + '/hosts', 'LogPath': '%s/%s-json.log' % (path, cid), 'Name': '/' + c['name'],
            'RestartCount': c['restart_count'], 'Driver': 'overlay2', 'Platform': 'linux', 'MountLabel': '', 'ProcessLabel': '',
            'AppArmorProfile': 'docker-default', 'ExecIDs': None, 'HostConfig': hostcfg,
            'GraphDriver': {'Data': {'ID': cid, 'LowerDir': '/var/lib/docker/overlay2/%s-init/diff' % sid[:32], 'MergedDir': '/var/lib/docker/overlay2/%s/merged' % sid[:32],
                                     'UpperDir': '/var/lib/docker/overlay2/%s/diff' % sid[:32], 'WorkDir': '/var/lib/docker/overlay2/%s/work' % sid[:32]}, 'Name': 'overlay2'},
            'Mounts': [{'Type': 'bind', 'Source': m['src'], 'Destination': m['dst'], 'Mode': 'ro' if m['ro'] else '', 'RW': not m['ro'],
                        'Propagation': 'rprivate'} for m in c['mounts']],
            'Config': config,
            'NetworkSettings': {'SandboxID': sid, 'SandboxKey': '/var/run/docker/netns/' + sid[:12], 'Ports': dict(c.get('ports') or {}) if running else {},
                                'Networks': {c['network']: nets}}}


def docker_inspect(run, argv):
    st = run.st
    opts, names = _parse_flags(argv, {'-f': ('format', True), '--format': ('format', True), '--type': ('type', True), '-s': ('size', False),
                                      '--size': ('size', False)})
    typ = opts.get('type')
    objs = []
    missing = []
    for n in names:
        c = find_container(st, n)
        if c is None or typ not in (None, 'container'):
            missing.append(n)
        else:
            objs.append(c)
    fmt = opts.get('format')
    rc = 1 if missing else 0
    if fmt is None:
        arr = [inspect_obj(st, c) for c in objs]
        outn(json.dumps(arr, indent=4, ensure_ascii=False).replace('&', '\\u0026').replace('<', '\\u003c').replace('>', '\\u003e') + '\n')
        for n in missing:
            if typ == 'container':
                err('Error response from daemon: No such container: %s' % n)
            elif typ:
                err('Error response from daemon: No such %s: %s:latest' % (typ, n))
            else:
                err('error: no such object: %s' % n)
    else:
        for c in objs:
            try:
                out(render_template(fmt, inspect_obj(st, c)))
            except TmplError as e:
                outn('\n')                  # docker has already written the (empty) line when the template fails
                err(str(e))
                rc = 1
        for n in missing:
            outn('\n')
            err('Error response from daemon: No such container: %s' % n if typ == 'container' else 'error: no such object: %s' % n)
    if rc:
        raise Exit(rc)


# --------------------------------------------------------------------------------------------------
# lifecycle: what happens to the crowdsec process when the container is (re)started
# --------------------------------------------------------------------------------------------------
def crowdsec_conf(fs, cfg_path='/etc/crowdsec/config.yaml'):
    """read the paths crowdsec/cscli take from a config file (defaults of the image when a key is missing)"""
    d = {'profiles_path': '/etc/crowdsec/profiles.yaml', 'notification_dir': '/etc/crowdsec/notifications/',
         'acquisition_path': '/etc/crowdsec/acquis.yaml', 'acquisition_dir': '/etc/crowdsec/acquis.d',
         'simulation_path': '/etc/crowdsec/simulation.yaml', 'config_dir': '/etc/crowdsec/', 'ok': True, 'path': cfg_path}
    text = fs.read(cfg_path)
    if text is None:
        d['ok'] = False
        return d
    try:
        doc = yaml_load(text)
    except YamlError:
        d['ok'] = False
        return d
    if isinstance(doc, dict):
        try:
            d['profiles_path'] = doc['api']['server']['profiles_path']
        except (KeyError, TypeError):
            pass
        cp = doc.get('config_paths') if isinstance(doc.get('config_paths'), dict) else {}
        for k in ('notification_dir', 'simulation_path', 'config_dir'):
            if cp.get(k):
                d[k] = cp[k]
        cs = doc.get('crowdsec_service') if isinstance(doc.get('crowdsec_service'), dict) else {}
        for k in ('acquisition_path', 'acquisition_dir'):
            if cs.get(k):
                d[k] = cs[k]
    return d


def plugin_configs(fs, conf):
    """{plugin name: (type, file)} from notification_dir/*.yaml|yml (multi-document files)"""
    res = {}
    d = conf['notification_dir'].rstrip('/')
    for fn in (fs.listdir(d) or []):
        if not fn.endswith(('.yaml', '.yml')):
            continue
        try:
            docs = yaml_load_all(fs.read(d + '/' + fn) or '')
        except YamlError:
            continue
        for doc in docs:
            if isinstance(doc, dict) and doc.get('name'):
                res[str(doc['name'])] = (str(doc.get('type', '')), d + '/' + fn, doc)
    return res


def config_test(st, fs, conf):
    """what `crowdsec -t` finds wrong -> fatal message or None; also returns the notes for the success output"""
    ptext = fs.read(conf['profiles_path'])
    if ptext is None:
        return 'while loading profiles for LAPI: while opening %s: open %s: no such file or directory' % (conf['profiles_path'], conf['profiles_path'])
    plugins = plugin_configs(fs, conf)
    msg, _profiles = profiles_check(ptext, conf['profiles_path'], set(plugins))
    if msg:
        return msg
    # acquisition files must parse
    files = [conf['acquisition_path']] + ['%s/%s' % (conf['acquisition_dir'].rstrip('/'), f) for f in (fs.listdir(conf['acquisition_dir']) or []) if f.endswith(('.yaml', '.yml'))]
    for f in files:
        txt = fs.read(f)
        if txt is None:
            continue
        try:
            yaml_load_all(txt)
        except YamlError as e:
            return 'crowdsec init: while loading acquisition config: while parsing %s: %s' % (f, e)
    return None


def boot_crowdsec(run, c, why='start'):
    """(re)start the crowdsec process: validate what it reads at start-up, crash-loop when that fails"""
    st = run.st
    fs = FS(st)
    t = now()
    conf = crowdsec_conf(fs)
    fatal = None
    if st['knobs'].get('restart_fails'):
        st['knobs']['restart_fails'] = 0
        fatal = 'crowdsec init: restart_fails knob: the process cannot start'
    if fatal is None:
        text = fs.read(conf['profiles_path']) or ''
        if '# fake-crowdsec: crash on start' in text:
            fatal = 'api server init: unable to run local API: fake-crowdsec: crash on start'
    if fatal is None:
        fatal = config_test(st, fs, conf)
    c['finished'] = c.get('finished') or t
    if fatal:
        c['status'] = 'restarting'
        c['restart_count'] += 1
        c['exit_code'] = 1
        c['started'] = t
        c['finished'] = t
        c['health_forced'] = None
        log_out(st, t, 'Skipping hub update, index file is recent')
        log_add(st, t + 0.001, 'fatal', fatal)
        st['crash_note'] = fatal
    else:
        c['status'] = 'running'
        c['exit_code'] = 0
        c['started'] = t
        c['health_forced'] = None
        c['pid'] = 1000 + Rng(st).randint(100000, 3000000)
        st['crash_note'] = ''
        log_startup(st, t)
        st['cs']['machines'][0]['updated'] = t
        st['cs']['machines'][0]['last_heartbeat'] = t
    run.touch()


def docker_lifecycle(run, verb, argv):
    st = run.st
    opts, names = _parse_flags(argv, {'-s': ('signal', True), '--signal': ('signal', True), '-t': ('time', True), '--time': ('time', True),
                                      '--timeout': ('time', True)})
    if verb == 'kill' and not opts.get('signal'):
        for a in argv:
            if a.startswith('--signal='):
                opts['signal'] = a.split('=', 1)[1]
    if not names:
        err('docker: \'docker %s\' requires at least 1 argument' % verb)
        raise Exit(1)
    rc = 0
    for n in names:
        c = find_container(st, n)
        if c is None:
            err('Error response from daemon: No such container: %s' % n if verb != 'kill' else 'Error response from daemon: Cannot kill container: %s: No such container: %s' % (n, n))
            rc = 1
            continue
        t = now()
        if verb == 'kill':
            sig = (opts.get('signal') or 'KILL').upper().replace('SIG', '')
            if c['status'] != 'running':
                err('Error response from daemon: cannot kill container: %s: container %s is not running' % (c['name'], c['id']))
                rc = 1
                continue
            if c['name'] == 'CrowdSec' and sig in ('HUP', '1'):
                fs = FS(st)
                conf = crowdsec_conf(fs)
                log_add(st, t, 'info', 'SIGHUP received, reloading')
                fatal = config_test(st, fs, conf)
                if fatal or '# fake-crowdsec: crash on start' in (fs.read(conf['profiles_path']) or ''):
                    boot_crowdsec(run, c)
                else:
                    log_add(st, t + 0.002, 'info', 'Reload is finished')
                    run.touch()
            else:
                c.update({'status': 'exited', 'exit_code': {'TERM': 143, '15': 143, 'INT': 130, '2': 130}.get(sig, 137), 'finished': t})
                if c['name'] == 'CrowdSec':
                    log_add(st, t, 'info', 'crowdsec shutdown')
                run.touch()
            out(c['name'])
            continue
        if verb in ('stop', 'restart'):
            if c['status'] in ('running', 'restarting'):
                c.update({'status': 'exited', 'exit_code': 0, 'finished': t})
                if c['name'] == 'CrowdSec':
                    log_add(st, t, 'info', 'Shutting down')
                    log_add(st, t + 0.05, 'info', 'crowdsec shutdown')
                run.touch()
        if verb in ('start', 'restart'):
            if c['status'] == 'running' and verb == 'start':
                pass
            elif c['name'] == 'CrowdSec':
                boot_crowdsec(run, c)
            else:
                c.update({'status': 'running', 'exit_code': 0, 'started': t})
                run.touch()
        out(c['name'])
    if rc:
        raise Exit(rc)


def docker_logs(run, argv):
    st = run.st
    opts, names = _parse_flags(argv, {'--tail': ('tail', True), '-n': ('tail', True), '--since': ('since', True), '--until': ('until', True),
                                      '-t': ('ts', False), '--timestamps': ('ts', False), '-f': ('follow', False), '--follow': ('follow', False),
                                      '--details': ('details', False)})
    if len(names) != 1:
        err('docker: \'docker logs\' requires 1 argument')
        raise Exit(1)
    c = find_container(st, names[0])
    if c is None:
        err('Error response from daemon: No such container: %s' % names[0])
        raise Exit(1)
    t = now()
    lines = [x for x in st['logs'] if c['name'] == 'CrowdSec']
    if c['name'] == 'CrowdSec' and c['status'] == 'running':
        lines = lines + log_chatter(st, max(c['started'], t - 3600), t)
    lines.sort(key=lambda x: x[0])
    if opts.get('since'):
        s = opts['since']
        sec, e = parse_dur(s, days=False)
        if e is None:
            lines = [x for x in lines if x[0] >= t - sec]
        else:
            m = re.match(r'^(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)', s)
            if m:
                import calendar
                ts = calendar.timegm(time.strptime(m.group(1) + ' ' + m.group(2), '%Y-%m-%d %H:%M:%S'))
                lines = [x for x in lines if x[0] >= ts]
    tail = opts.get('tail')
    if tail and tail != 'all':
        if not re.match(r'^-?[0-9]+$', tail):
            err('invalid argument "%s" for "-n, --tail" flag: strconv.ParseInt: parsing "%s": invalid syntax' % (tail, tail))
            raise Exit(125)
        lines = lines[-int(tail):] if int(tail) > 0 else []
    for ts, stream, text in lines:
        pre = ''
        if opts.get('ts'):
            pre = '%s.%09dZ ' % (time.strftime('%Y-%m-%dT%H:%M:%S', _gm(ts)), int((wall(ts) % 1) * 1e9))
        (out if stream == 1 else err)(pre + text)


def docker_cp(run, argv):
    st = run.st
    args = [a for a in argv if not a.startswith('-') or a == '-']
    if len(args) != 2:
        err('"docker cp" requires exactly 2 arguments.\nSee \'docker cp --help\'.\n\nUsage:  docker cp [OPTIONS] CONTAINER:SRC_PATH DEST_PATH|-\n\tdocker cp [OPTIONS] SRC_PATH|- CONTAINER:DEST_PATH')
        raise Exit(1)
    src, dst = args
    import shutil
    sc = re.match(r'^([^/:][^:]*):(.*)$', src)
    dc = re.match(r'^([^/:][^:]*):(.*)$', dst)
    if sc and dc:
        err('copying between containers is not supported')
        raise Exit(1)
    if not sc and not dc:
        err('must specify at least one container source')
        raise Exit(1)
    cont = find_container(st, (sc or dc).group(1))
    if cont is None:
        err('Error response from daemon: No such container: %s' % (sc or dc).group(1))
        raise Exit(1)
    fs = FS(st)
    if sc:
        cpath = sc.group(2) or '/'
        h = fs.host(cpath)
        if not os.path.lexists(h):
            err('Error response from daemon: Could not find the file %s in container %s' % (cpath, cont['name']))
            raise Exit(1)
        if cpath.endswith('/.') and os.path.isdir(h.rstrip('/.')):
            h = fs.host(cpath[:-2] or '/')
            target = dst
            os.makedirs(target, exist_ok=True)
            for e in os.listdir(h):
                _cp_tree(os.path.join(h, e), os.path.join(target, e))
            return
        if os.path.isdir(dst):
            target = os.path.join(dst, os.path.basename(h.rstrip('/')))
        else:
            target = dst
        _cp_tree(h, target)
        return
    cpath = dc.group(2) or '/'
    if not os.path.lexists(src):
        err('lstat %s: no such file or directory' % os.path.abspath(src))
        raise Exit(1)
    dh = fs.host(cpath)
    if src.endswith('/.') and os.path.isdir(src[:-2] or '/'):
        if not os.path.isdir(dh):
            err('Error response from daemon: Could not find the file %s in container %s' % (cpath, cont['name']))
            raise Exit(1)
        for e in os.listdir(src[:-2] or '/'):
            _cp_tree(os.path.join(src[:-2] or '/', e), os.path.join(dh, e))
        run.touch()
        return
    if os.path.isdir(dh):
        target = os.path.join(dh, os.path.basename(src.rstrip('/')))
    else:
        if not os.path.isdir(os.path.dirname(dh)):
            err('Error response from daemon: Could not find the file %s in container %s' % (os.path.dirname(os.path.normpath(cpath)) or '/', cont['name']))
            raise Exit(1)
        target = dh
    _cp_tree(src, target)
    run.touch()


def _cp_tree(src, dst):
    import shutil
    if os.path.isdir(src):
        if os.path.isdir(dst):
            for e in os.listdir(src):
                _cp_tree(os.path.join(src, e), os.path.join(dst, e))
        else:
            shutil.copytree(src, dst)
    else:
        os.makedirs(os.path.dirname(dst) or '.', exist_ok=True)
        shutil.copyfile(src, dst)


# --------------------------------------------------------------------------------------------------
# docker exec
# --------------------------------------------------------------------------------------------------
def docker_exec(run, argv):
    st = run.st
    i = 0
    opts = {}
    while i < len(argv) and argv[i].startswith('-'):
        a = argv[i]
        if a in ('-i', '--interactive'):
            opts['i'] = True
        elif a in ('-t', '--tty', '-d', '--detach', '--privileged'):
            pass
        elif a in ('-it', '-ti'):
            opts['i'] = True
        elif a in ('-u', '--user', '-w', '--workdir', '-e', '--env', '--env-file', '--detach-keys'):
            i += 1
        elif a.startswith(('--user=', '--workdir=', '--env=')):
            pass
        else:
            err('unknown shorthand flag: \'%s\' in %s' % (a[1:2], a))
            raise Exit(125)
        i += 1
    rest = argv[i:]
    if len(rest) < 2:
        err('"docker exec" requires at least 2 arguments.\nSee \'docker exec --help\'.')
        raise Exit(1)
    name, cmd = rest[0], rest[1:]
    c = find_container(st, name)
    if c is None:
        err('Error response from daemon: No such container: %s' % name)
        raise Exit(1)
    if c['status'] == 'restarting':
        err('Error response from daemon: Container %s is restarting, wait until the container is running' % c['id'])
        raise Exit(1)
    if c['status'] != 'running':
        err('Error response from daemon: container %s is not running' % c['id'])
        raise Exit(1)
    run.pass_stdin = bool(opts.get('i'))
    prog = cmd[0]
    if c['name'] != 'CrowdSec':
        err('OCI runtime exec failed: exec failed: unable to start container process: exec: "%s": executable file not found in $PATH: unknown' % prog if prog in ('cscli', 'crowdsec') else '')
        if prog not in ('cscli', 'crowdsec'):
            unsupported(run, ['exec'] + rest)
        raise Exit(126)
    if prog == 'cscli':
        cscli_main(run, cmd[1:])
    elif prog == 'crowdsec':
        crowdsec_main(run, cmd[1:])
    else:
        exec_util(run, cmd)


def exec_util(run, cmd):
    fs = run.fs()
    prog, args = cmd[0], cmd[1:]
    if prog == 'cat':
        rc = 0
        for p in args:
            txt = fs.read(p)
            if txt is None:
                err('cat: can\'t open \'%s\': No such file or directory' % p)
                rc = 1
            else:
                outn(txt)
        raise Exit(rc)
    if prog == 'mkdir':
        for p in [a for a in args if not a.startswith('-')]:
            if '-p' not in args and not fs.isdir(os.path.dirname(os.path.normpath(p))):
                err("mkdir: can't create directory '%s': No such file or directory" % p)
                raise Exit(1)
            if '-p' not in args and fs.exists(p):
                err("mkdir: can't create directory '%s': File exists" % p)
                raise Exit(1)
            fs.mkdirs(p)
        run.touch()
        raise Exit(0)
    if prog == 'rm':
        force = any(a.startswith('-') and 'f' in a for a in args)
        rec = any(a.startswith('-') and ('r' in a or 'R' in a) for a in args)
        for p in [a for a in args if not a.startswith('-')]:
            if not fs.exists(p):
                if not force:
                    err("rm: can't remove '%s': No such file or directory" % p)
                    raise Exit(1)
                continue
            if fs.isdir(p) and not rec:
                err("rm: can't remove '%s': Is a directory" % p)
                raise Exit(1)
            fs.remove(p)
        run.touch()
        raise Exit(0)
    if prog in ('cp', 'mv'):
        pos = [a for a in args if not a.startswith('-')]
        if len(pos) != 2:
            err('%s: missing file operand' % prog)
            raise Exit(1)
        s, d = pos
        if not fs.exists(s):
            err("%s: can't stat '%s': No such file or directory" % (prog, s))
            raise Exit(1)
        hd = fs.host(d)
        if os.path.isdir(hd):
            hd = os.path.join(hd, os.path.basename(s.rstrip('/')))
        elif not os.path.isdir(os.path.dirname(hd)):
            err("%s: can't create '%s': No such file or directory" % (prog, d))
            raise Exit(1)
        _cp_tree(fs.host(s), hd)
        if prog == 'mv':
            fs.remove(s)
        run.touch()
        raise Exit(0)
    if prog == 'ls':
        pos = [a for a in args if not a.startswith('-')] or ['/']
        rc = 0
        for p in pos:
            if not fs.exists(p):
                err("ls: %s: No such file or directory" % p)
                rc = 1
            elif fs.isdir(p):
                if len(pos) > 1:
                    out('%s:' % p)
                for n in fs.listdir(p):
                    out(n)
            else:
                out(p)
        raise Exit(rc)
    if prog == 'test' or prog == '[':
        a = [x for x in args if x != ']']
        ops = {'-f': fs.isfile, '-d': fs.isdir, '-e': fs.exists, '-s': lambda p: fs.isfile(p) and os.path.getsize(fs.host(p)) > 0,
               '-r': fs.exists, '-w': fs.exists}
        if len(a) == 2 and a[0] in ops:
            raise Exit(0 if ops[a[0]](a[1]) else 1)
        if len(a) == 3 and a[1] in ('=', '=='):
            raise Exit(0 if a[0] == a[2] else 1)
        raise Exit(0 if a and a[0] else 1)
    if prog == 'touch':
        for p in args:
            if not fs.exists(p):
                if not fs.isdir(os.path.dirname(os.path.normpath(p))):
                    err("touch: %s: No such file or directory" % p)
                    raise Exit(1)
                fs.write(p, '')
        run.touch()
        raise Exit(0)
    if prog in ('chmod', 'chown', 'true', 'sync'):
        raise Exit(0)
    if prog == 'false':
        raise Exit(1)
    if prog == 'wget':      # `wget -qO- URL`: the spec wants a JSON null for any URL (nothing is fetched)
        out('null')
        raise Exit(0)
    if prog == 'echo':
        out(' '.join(args))
        raise Exit(0)
    if prog in ('sh', 'bash', 'ash'):
        unsupported(run, ['exec', 'CrowdSec'] + cmd)
    if prog in ('id', 'whoami'):
        out('uid=0(root) gid=0(root)' if prog == 'id' else 'root')
        raise Exit(0)
    unsupported(run, ['exec', 'CrowdSec'] + cmd)


def docker_main(run, argv):
    try:
        _docker_main(run, argv)
    except TmplError as e:
        err(str(e))
        raise Exit(1)


def _docker_main(run, argv):
    st = run.st
    if st['knobs'].get('docker_down'):
        err(DAEMON_DOWN)
        raise Exit(1)
    i = 0
    while i < len(argv) and argv[i].startswith('-') and argv[i] not in ('-v', '--version', '-h', '--help'):
        if argv[i] in ('-H', '--host', '--context', '-c', '--config', '-l', '--log-level'):
            i += 2
        else:
            i += 1
    args = argv[i:]
    if not args:
        out('Usage:  docker [OPTIONS] COMMAND')
        raise Exit(0)
    verb, rest = args[0], args[1:]
    if verb == 'container' and rest:
        verb, rest = {'ls': 'ps', 'list': 'ps', 'rm': 'rm', 'remove': 'rm'}.get(rest[0], rest[0]), rest[1:]
    if verb in ('-v', '--version'):
        out('Docker version 29.1.3, build 29.1.3-0ubuntu4.1')
    elif verb == 'version':
        opts, _ = _parse_flags(rest, {'-f': ('format', True), '--format': ('format', True)})
        if opts.get('format'):
            out(render_template(opts['format'], {'Server': {'Version': '29.1.3', 'APIVersion': '1.52', 'Os': 'linux', 'Arch': 'amd64'},
                                                 'Client': {'Version': '29.1.3', 'APIVersion': '1.52', 'Os': 'linux', 'Arch': 'amd64'}}))
        else:
            out('Client:\n Version:           29.1.3\n API version:       1.52\n OS/Arch:           linux/amd64\n\nServer:\n Engine:\n  Version:          29.1.3\n  API version:      1.52 (minimum version 1.24)')
    elif verb == 'info':
        opts, _ = _parse_flags(rest, {'-f': ('format', True), '--format': ('format', True)})
        n = len(st['containers'])
        run_n = sum(1 for c in st['containers'].values() if c['status'] == 'running')
        info = {'ID': 'fake-crowdsec-mock', 'Containers': n, 'ContainersRunning': run_n, 'ContainersPaused': 0, 'ContainersStopped': n - run_n,
                'Images': 3, 'Driver': 'overlay2', 'ServerVersion': '29.1.3', 'OperatingSystem': 'Fake Linux', 'OSType': 'linux',
                'Architecture': 'x86_64', 'NCPU': 8, 'MemTotal': 17179869184, 'Name': 'fake-docker-host'}
        if opts.get('format'):
            out(render_template(opts['format'], info))
        else:
            out('Client:\n Version:    29.1.3\n\nServer:\n Containers: %d\n  Running: %d\n  Paused: 0\n  Stopped: %d\n Server Version: 29.1.3' % (n, run_n, n - run_n))
    elif verb == 'ps':
        docker_ps(run, rest)
    elif verb == 'inspect':
        docker_inspect(run, rest)
    elif verb == 'exec':
        docker_exec(run, rest)
    elif verb in ('restart', 'start', 'stop', 'kill'):
        docker_lifecycle(run, verb, rest)
    elif verb == 'logs':
        docker_logs(run, rest)
    elif verb == 'cp':
        docker_cp(run, rest)
    elif verb == 'compose':
        sub = [a for a in rest if not a.startswith('-')]
        first = sub[0] if sub else ''
        if first in ('up', 'down', 'start', 'stop', 'restart', 'create', 'rm', 'pull', 'build', 'run', 'kill', 'pause', 'unpause', 'cp', 'push', 'exec', 'scale', 'watch'):
            unsupported(run, ['compose'] + rest)
        if first == 'ls':
            if '--format' in rest and 'json' in rest:
                out('[]')
            elif '-q' not in rest and '--quiet' not in rest:
                out('NAME                STATUS              CONFIG FILES')
        elif first == 'version':
            out('Docker Compose version v2.40.3')
    elif verb in ('network', 'volume', 'image', 'images', 'system', 'context', 'stats', 'top', 'events', 'port', 'diff', 'history', 'search', 'plugin', 'buildx', 'manifest'):
        sub = rest[0] if rest else ''
        if sub in ('create', 'rm', 'remove', 'prune', 'connect', 'disconnect', 'pull', 'push', 'load', 'save', 'import', 'tag', 'build', 'df') and verb != 'system':
            unsupported(run, [verb] + rest)
        if verb == 'system' and sub not in ('df', 'info', 'events', ''):
            unsupported(run, [verb] + rest)
        if verb == 'images' or (verb == 'image' and sub in ('ls', 'list')):
            opts, _ = _parse_flags(rest[1:] if verb == 'image' else rest, {'-q': ('q', False), '--format': ('format', True), '-a': ('a', False), '--all': ('a', False), '--no-trunc': ('nt', False), '--digests': ('dg', False), '-f': ('f', True), '--filter': ('f', True)})
            if not opts.get('q') and not opts.get('format'):
                out('IMAGE   ID   DISK USAGE   CONTENT SIZE')
    elif verb in ('run', 'rm', 'create', 'pull', 'push', 'build', 'tag', 'commit', 'rename', 'update', 'pause', 'unpause', 'wait', 'attach', 'save', 'load', 'import', 'export', 'login', 'logout', 'rmi'):
        unsupported(run, argv)
    else:
        unsupported(run, argv)


# ==================================================================================================
# cscli: command table, flag parsing (cobra/pflag flavour), output helpers
# ==================================================================================================
_TYPES = ('collections', 'scenarios', 'parsers', 'postoverflows', 'contexts', 'appsec-configs', 'appsec-rules')
_ALIASES = {'alert': 'alerts', 'bouncer': 'bouncers', 'machine': 'machines', 'collection': 'collections', 'scenario': 'scenarios',
            'parser': 'parsers', 'postoverflow': 'postoverflows', 'context': 'contexts', 'notification': 'notifications',
            'appsec-config': 'appsec-configs', 'appsec-rule': 'appsec-rules'}
_SUB_ALIASES = {'remove': 'delete', 'ls': 'list'}

# flag kinds: s string, b bool, i int, d duration (Go syntax + CrowdSec's `d` unit), S string list
_F = lambda *a: a       # noqa: E731  (name, short, kind)


def _flags(*specs):
    d = {}
    for name, short, kind in specs:
        d[name] = (short, kind)
    return d


_CMDS = {
    ('version',): (_flags(), (0, 0)),
    ('lapi', 'status'): (_flags(), (0, 0)),
    ('capi', 'status'): (_flags(), (0, 0)),
    ('console', 'status'): (_flags(), (0, 0)),
    ('config', 'show'): (_flags(('key', None, 's')), (0, 0)),
    ('config', 'show-yaml'): (_flags(), (0, 0)),
    ('decisions', 'list'): (_flags(('all', 'a', 'b'), ('since', None, 'd'), ('until', None, 'd'), ('type', 't', 's'), ('scope', None, 's'),
                                   ('origin', None, 's'), ('value', 'v', 's'), ('scenario', 's', 's'), ('ip', 'i', 's'), ('range', 'r', 's'),
                                   ('limit', 'l', 'i'), ('no-simu', None, 'b'), ('machine', 'm', 'b'), ('contained', None, 'b')), (0, 0)),
    ('decisions', 'add'): (_flags(('ip', 'i', 's'), ('range', 'r', 's'), ('duration', 'd', 's'), ('value', 'v', 's'), ('scope', None, 's'),
                                  ('reason', 'R', 's'), ('type', 't', 's'), ('bypass-allowlist', 'B', 'b')), (0, 0)),
    ('decisions', 'delete'): (_flags(('ip', 'i', 's'), ('range', 'r', 's'), ('type', 't', 's'), ('value', 'v', 's'), ('scenario', 's', 's'),
                                     ('origin', None, 's'), ('id', None, 's'), ('all', None, 'b'), ('contained', None, 'b')), (0, 0)),
    ('decisions', 'import'): (_flags(('input', 'i', 's'), ('duration', 'd', 's'), ('scope', None, 's'), ('reason', 'R', 's'), ('type', 't', 's'),
                                     ('batch', None, 'i'), ('format', None, 's')), (0, 0)),
    ('alerts', 'list'): (_flags(('all', 'a', 'b'), ('until', None, 'd'), ('since', None, 'd'), ('ip', 'i', 's'), ('scenario', 's', 's'),
                                ('range', 'r', 's'), ('type', None, 's'), ('scope', None, 's'), ('value', 'v', 's'), ('origin', None, 's'),
                                ('kind', None, 's'), ('contained', None, 'b'), ('machine', 'm', 'b'), ('limit', 'l', 'i')), (0, 0)),
    ('alerts', 'inspect'): (_flags(('details', 'd', 'b')), (1, None)),
    ('alerts', 'delete'): (_flags(('scope', None, 's'), ('value', 'v', 's'), ('scenario', 's', 's'), ('ip', 'i', 's'), ('range', 'r', 's'),
                                  ('id', None, 's'), ('all', 'a', 'b'), ('contained', None, 'b')), (0, 0)),
    ('alerts', 'flush'): (_flags(('max-items', None, 'i'), ('max-age', None, 'd')), (0, 0)),
    ('allowlists', 'list'): (_flags(), (0, 0)),
    ('allowlists', 'create'): (_flags(('description', 'd', 's')), (1, 1)),
    ('allowlists', 'add'): (_flags(('comment', 'd', 's'), ('expiration', 'e', 'd')), (2, None)),
    ('allowlists', 'remove'): (_flags(), (2, None)),
    ('allowlists', 'inspect'): (_flags(), (1, 1)),
    ('allowlists', 'check'): (_flags(), (1, None)),
    ('allowlists', 'delete'): (_flags(), (1, 1)),
    ('bouncers', 'list'): (_flags(), (0, 0)),
    ('bouncers', 'add'): (_flags(('key', 'k', 's')), (1, 1)),
    ('bouncers', 'delete'): (_flags(('ignore-missing', None, 'b')), (1, None)),
    ('bouncers', 'inspect'): (_flags(), (1, 1)),
    ('bouncers', 'prune'): (_flags(('duration', 'd', 'd'), ('force', None, 'b')), (0, 0)),
    ('machines', 'list'): (_flags(), (0, 0)),
    ('machines', 'inspect'): (_flags(), (1, 1)),
    ('metrics',): (_flags(('no-unit', None, 'b'), ('url', 'u', 's')), (0, 0)),
    ('metrics', 'show'): (_flags(('no-unit', None, 'b'), ('url', 'u', 's')), (0, None)),
    ('metrics', 'list'): (_flags(), (0, 0)),
    ('hub', 'update'): (_flags(('with-content', None, 'b')), (0, 0)),
    ('hub', 'upgrade'): (_flags(('dry-run', None, 'b'), ('force', None, 'b'), ('interactive', 'i', 'b')), (0, 0)),
    ('hub', 'list'): (_flags(('all', 'a', 'b'), ('full', None, 'b'), ('status', None, 'S')), (0, 0)),
    ('hub', 'types'): (_flags(), (0, 0)),
    ('hub', 'branch'): (_flags(), (0, 0)),
    ('simulation', 'status'): (_flags(), (0, 0)),
    ('simulation', 'enable'): (_flags(('global', 'g', 'b')), (0, None)),
    ('simulation', 'disable'): (_flags(('global', 'g', 'b')), (0, None)),
    ('notifications', 'list'): (_flags(), (0, 0)),
    ('notifications', 'test'): (_flags(('alert', 'a', 's')), (1, 1)),
    ('notifications', 'inspect'): (_flags(), (1, 1)),
}
for _t in _TYPES:
    _CMDS[(_t, 'list')] = (_flags(('all', 'a', 'b')), (0, None))
    _CMDS[(_t, 'install')] = (_flags(('download-only', 'd', 'b'), ('dry-run', None, 'b'), ('force', None, 'b'), ('ignore', None, 'b'),
                                     ('interactive', 'i', 'b')), (0, None))
    _CMDS[(_t, 'delete')] = (_flags(('all', None, 'b'), ('dry-run', None, 'b'), ('force', None, 'b'), ('interactive', 'i', 'b'), ('purge', None, 'b')), (0, None))
    _CMDS[(_t, 'upgrade')] = (_flags(('all', 'a', 'b'), ('dry-run', None, 'b'), ('force', None, 'b'), ('interactive', 'i', 'b')), (0, None))
    _CMDS[(_t, 'inspect')] = (_flags(('diff', None, 'b'), ('no-metrics', None, 'b'), ('rev', None, 'b'), ('url', 'u', 's')), (0, None))
_GLOBAL_VAL = {'-c': 'config', '--config': 'config', '-o': 'output', '--output': 'output', '--color': 'color'}
_GLOBAL_BOOL = {'--debug': 'debug', '--info': 'info', '--warning': 'warning', '--error': 'error', '--trace': 'trace', '-h': 'help', '--help': 'help'}
_GROUPS = set(k[:i] for k in _CMDS for i in range(1, len(k)))


class UsageError(Exception):
    def __init__(self, msg, path):
        Exception.__init__(self, msg)
        self.msg, self.path = msg, path


def parse_cscli_args(argv):
    """-> (path tuple, flags dict, positional args, globals dict). Raises UsageError."""
    gl = {}
    rest = []
    i = 0
    n = len(argv)
    path = []
    while i < n:
        a = argv[i]
        base = a.split('=', 1)[0]
        if a == '--':
            rest.extend(argv[i + 1:])
            break
        if base in _GLOBAL_VAL:
            if '=' in a:
                gl[_GLOBAL_VAL[base]] = a.split('=', 1)[1]
            else:
                i += 1
                if i >= n:
                    raise UsageError('flag needs an argument: %s' % (a if a.startswith('--') else "'%s' in %s" % (a[1], a)), tuple(path))
                gl[_GLOBAL_VAL[base]] = argv[i]
        elif re.match(r'^-[co]\S+$', a):
            gl[_GLOBAL_VAL[a[:2]]] = a[2:]
        elif a in _GLOBAL_BOOL:
            gl[_GLOBAL_BOOL[a]] = True
        elif a.startswith('-') and a != '-':
            rest.append(a)
            # a flag before the command path is complete: take its value along if the next token is not a command word
        else:
            cand = tuple(path + [_canon(a, len(path), path)])
            if (tuple(path) not in _CMDS or cand in _CMDS) and (cand in _CMDS or cand in _GROUPS):
                path.append(cand[-1])
            else:
                rest.append(a)
        i += 1
    path = tuple(path)
    if path not in _CMDS:
        if path and path in _GROUPS:
            # `cscli decisions` alone or with an unknown sub-command
            extra = [r for r in rest if not r.startswith('-')]
            if extra:
                raise UsageError('unknown command "%s" for "cscli %s"' % (extra[0], ' '.join(path)), path)
            raise UsageError('', path)
        extra = [r for r in rest if not r.startswith('-')]
        if extra or not path:
            first = extra[0] if extra else ''
            if not path and not extra:
                raise UsageError('', path)
            raise UsageError('unknown command "%s" for "cscli%s"' % (first, (' ' + ' '.join(path)) if path else ''), path)
        raise UsageError('', path)
    flagspec, (amin, amax) = _CMDS[path]
    flags = {}
    args = []
    j = 0
    while j < len(rest):
        a = rest[j]
        if a.startswith('--') and len(a) > 2:
            name, eq, val = a[2:].partition('=')
            spec = flagspec.get(name)
            if spec is None:
                raise UsageError('unknown flag: --%s' % name, path)
            short, kind = spec
            disp = '-%s, --%s' % (short, name) if short else '--%s' % name
            if kind == 'b':
                flags[name] = (val.lower() not in ('false', '0', 'f')) if eq else True
            else:
                if not eq:
                    j += 1
                    if j >= len(rest):
                        raise UsageError('flag needs an argument: --%s' % name, path)
                    val = rest[j]
                flags[name] = _coerce(val, kind, disp, path)
        elif a.startswith('-') and a != '-' and len(a) >= 2:
            k = 1
            while k < len(a):
                ch = a[k]
                name = next((nm for nm, sp in flagspec.items() if sp[0] == ch), None)
                if name is None:
                    raise UsageError("unknown shorthand flag: '%s' in %s" % (ch, a), path)
                short, kind = flagspec[name]
                disp = '-%s, --%s' % (short, name)
                if kind == 'b':
                    flags[name] = True
                    k += 1
                    continue
                val = a[k + 1:]
                if val.startswith('='):
                    val = val[1:]
                if val == '':
                    j += 1
                    if j >= len(rest):
                        raise UsageError("flag needs an argument: '%s' in -%s" % (ch, ch), path)
                    val = rest[j]
                flags[name] = _coerce(val, kind, disp, path)
                break
        else:
            args.append(a)
        j += 1
    if len(args) < amin or (amax is not None and len(args) > amax):
        if amax == 0:
            raise UsageError('unknown command "%s" for "cscli %s"' % (args[0], ' '.join(path)), path)
        if amin == amax:
            raise UsageError('accepts %d arg(s), received %d' % (amin, len(args)), path, )
        if len(args) < amin:
            raise UsageError('requires at least %d arg(s), only received %d' % (amin, len(args)), path)
        raise UsageError('unknown command "%s" for "cscli %s"' % (args[amax], ' '.join(path)), path)
    return path, flags, args, gl


def _canon(word, depth, path):
    if depth == 0:
        return _ALIASES.get(word, word)
    if word == 'remove' and path and path[0] == 'allowlists':
        return word                      # allowlists remove (values) and allowlists delete (the list) are different commands
    return _SUB_ALIASES.get(word, word) if word in ('remove', 'ls') else word


def _coerce(val, kind, disp, path):
    if kind == 's':
        return val
    if kind == 'S':
        return val.split(',')
    if kind == 'i':
        if not re.match(r'^[-+]?[0-9]+$', val):
            raise UsageError('invalid argument "%s" for "%s" flag: strconv.ParseInt: parsing "%s": invalid syntax' % (val, disp, val), path)
        return int(val)
    if kind == 'd':
        sec, e = parse_dur(val)
        if e:
            raise UsageError('invalid argument "%s" for "%s" flag: %s' % (val, disp, e), path)
        return sec
    return val


# --------------------------------------------------------------------------------------------------
# tables
# --------------------------------------------------------------------------------------------------
def _cell_w(s):
    """display width: the status emoji (✔️ 🚫 ⚠️) take two columns"""
    w = 0
    for ch in s:
        o = ord(ch)
        if o == 0xFE0F:
            continue
        w += 2 if (o >= 0x1F300 or o in (0x2705, 0x274C)) else 1     # wide emoji count two columns, the check mark (U+2714) one
    return w


def _padw(s, w):
    return s + ' ' * (w - _cell_w(s))


def table_classic(headers, rows, title=None, hdr_left=False):
    """the go-pretty/tablewriter look used by decisions list, alerts list and the alert detail: +---+ borders,
    centred header (left aligned with hdr_left), left aligned cells"""
    w = [_cell_w(h) for h in headers]
    for r in rows:
        for i, c in enumerate(r):
            w[i] = max(w[i], _cell_w(c))
    sep = '+' + '+'.join('-' * (x + 2) for x in w) + '+'
    lines = []
    if title:
        tw = sum(w) + 3 * len(w) - 1
        lines.append('+' + '-' * tw + '+')
        for i in range(0, max(len(title), 1), tw - 2):        # a title wider than the table is cut into rows
            lines.append('| ' + _padw(title[i:i + tw - 2], tw - 2) + ' |')
    lines.append(sep)
    if hdr_left:
        lines.append('| ' + ' | '.join(_padw(h, w[i]) for i, h in enumerate(headers)) + ' |')
    else:
        lines.append('|' + '|'.join(' ' + ' ' * ((w[i] - _cell_w(h) + 1) // 2) + h + ' ' * ((w[i] - _cell_w(h)) // 2) + ' ' for i, h in enumerate(headers)) + '|')
    lines.append(sep)
    for r in rows:
        lines.append('| ' + ' | '.join(_padw(c, w[i]) for i, c in enumerate(r)) + ' |')
    lines.append(sep)
    return '\n'.join(lines)


def table_modern(headers, rows, title=None):
    """the flat look of bouncers/machines/allowlists/hub lists: dashed rules, two spaces between columns.
    A None row draws a rule."""
    w = [_cell_w(h) for h in headers]
    for r in rows:
        for i, c in enumerate(r or ()):
            w[i] = max(w[i], _cell_w(c))
    total = sum(w) + 2 * (len(w) - 1) + 2

    def cell(s, width):
        return s + ' ' * (width - _cell_w(s))
    lines = ['-' * total]
    if title:
        lines.append(' ' + cell(title, total - 2) + ' ')
        lines.append('-' * total)
    lines.append(' ' + '  '.join(cell(h, w[i]) for i, h in enumerate(headers)) + ' ')
    lines.append('-' * total)
    for r in rows:
        lines.append('-' * total if r is None else ' ' + '  '.join(cell(c, w[i]) for i, c in enumerate(r)) + ' ')
    lines.append('-' * total)
    return '\n'.join(lines)


def table_kv(title, rows):
    """the key/value frame of `bouncers inspect` and `allowlists inspect`: dashed rules, a title row, then `Key  value` rows;
    the value column is as wide as its longest value (or as the title needs)"""
    kw = max(_cell_w(k) for k, _ in rows)
    vw = max([_cell_w(v) for _, v in rows] + [_cell_w(title) - kw - 2])
    total = kw + vw + 4
    lines = ['-' * total, ' ' + _padw(title, total - 2) + ' ', '-' * total]
    for k, v in rows:
        lines.append(' ' + _padw(k, kw) + '  ' + _padw(v, vw) + ' ')
    lines.append('-' * total)
    return '\n'.join(lines)


def box_kv(title, rows):
    """the boxed key/value table of `machines inspect` (+---+ borders, the title spans both columns)"""
    kw = max(_cell_w(k) for k, _ in rows)
    vw = max([_cell_w(v) for _, v in rows] + [_cell_w(title) - kw - 3])
    inner = kw + vw + 5
    sep = '+' + '-' * (kw + 2) + '+' + '-' * (vw + 2) + '+'
    lines = ['+' + '-' * inner + '+', '| ' + _padw(title, inner - 2) + ' |', sep]
    for k, v in rows:
        lines.append('| ' + _padw(k, kw) + ' | ' + _padw(v, vw) + ' |')
    lines.append(sep)
    return '\n'.join(lines)


def csv_line(cells):
    def q(c):
        c = str(c)
        return '"' + c.replace('"', '""') + '"' if re.search(r'[,"\n\r]', c) else c
    return ','.join(q(c) for c in cells)


# ==================================================================================================
# cscli: decisions and alerts
# ==================================================================================================
LAPI_URL = 'http://127.0.0.1:8080'
_JWT = 'could not get jwt token: Post "%s/v1/watchers/login": retryable error: dial tcp 127.0.0.1:8080: connect: connection refused' % LAPI_URL

# commands that really need the LAPI (cscli talks to it over HTTP); the others read the database directly
_NEEDS_LAPI = {('decisions', 'list'), ('decisions', 'add'), ('decisions', 'delete'), ('decisions', 'import'), ('alerts', 'list'),
               ('alerts', 'inspect'), ('alerts', 'delete'), ('allowlists', 'list'), ('allowlists', 'inspect'), ('allowlists', 'check'),
               ('lapi', 'status')}
# what the spec asks to fail too when lapi_down=1
_SPEC_FAILS = {('bouncers', 'list'), ('bouncers', 'add'), ('bouncers', 'delete'), ('bouncers', 'inspect'), ('bouncers', 'prune'),
               ('machines', 'list'), ('machines', 'inspect'), ('allowlists', 'create'), ('allowlists', 'add'), ('allowlists', 'remove'),
               ('allowlists', 'delete'), ('metrics',), ('metrics', 'show'), ('capi', 'status'), ('console', 'status'),
               ('notifications', 'list'), ('notifications', 'test'), ('notifications', 'inspect'), ('alerts', 'flush')}


class CscliBase(object):
    """arguments, output mode, logging, LAPI bookkeeping and the dispatch shared by all sub-commands"""

    def __init__(self, run):
        self.run = run
        self.st = run.st
        self.cs = run.st['cs']
        self.db = Db(run.st)
        self.t = now()
        self.fl = {}
        self.args = []
        self.gl = {}
        self.path = ()
        self.output = 'human'
        self.argv = []
        self._logged_in = False

    # -- output/logging ----------------------------------------------------------------------------
    def log(self, level, msg, force=False, **kv):
        """cscli's logger: text lines (level=info msg="...") in human mode, only errors in raw, JSON errors in json.
        `force` is for the lines the database layer logs itself (module=db): those appear in every output mode."""
        if self.output == 'json':
            if level != 'error' and not force:
                return
            d = dict(kv, level=level, msg=msg, time=iso_s(self.t))
            errn(json.dumps(d, sort_keys=True, ensure_ascii=False, separators=(',', ':')) + '\n')
            return
        if self.output == 'raw' and level not in ('error', 'fatal') and not force:
            return
        parts = ['level=%s' % level, 'msg=%s' % _q(msg)]
        for k in sorted(kv):
            v = str(kv[k])
            parts.append('%s=%s' % (k, _q(v) if re.search(r'[\s"=]', v) or v == '' else v))
        errn(' '.join(parts) + '\n')

    def cmd_name(self):
        """the command as cobra prints it in errors (`remove` is the primary name for hub items, `delete` elsewhere)"""
        p = list(self.path)
        if p and p[0] in _TYPES and len(p) > 1 and p[1] == 'delete':
            p[1] = 'remove'
        return ' '.join(p)

    def fatal(self, msg):
        err('Error: cscli %s: %s' % (self.cmd_name(), msg))
        raise Exit(1)

    def human(self):
        return self.output == 'human'

    def empty_list_text(self):
        k = self.st['knobs'].get('empty_json')
        if k in ('null', '[]'):
            return k
        return '[]' if ver_ge(self.st, 1, 7) else 'null'

    # -- entry ---------------------------------------------------------------------------------------
    def main(self, argv):
        self.argv = argv
        try:
            self.path, self.fl, self.args, self.gl = parse_cscli_args(argv)
        except UsageError as e:
            if e.msg == '':
                if not e.path:
                    out('cscli is the main command to interact with your crowdsec service, scenarios & db.\n\nUsage:\n  cscli [flags]\n  cscli [command]')
                    raise Exit(0)
                out('Usage:\n  cscli %s [command]' % ' '.join(e.path))
                raise Exit(0)
            if not ver_ge(self.st, 1, 7) and e.msg.startswith('unknown command'):
                err('Error: %s' % e.msg)
            else:
                err('Error: cscli%s: %s' % ((' ' + ' '.join(e.path)) if e.path else '', e.msg))
            raise Exit(1)
        if self.gl.get('help'):
            out('Usage:\n  cscli %s [flags]' % ' '.join(self.path))
            raise Exit(0)
        if self.path[0] == 'allowlists' and not has_allowlists(self.st):
            err('Error: unknown command "allowlists" for "cscli"')
            raise Exit(1)
        conf_path = self.gl.get('config') or '/etc/crowdsec/config.yaml'
        fs = FS(self.st)
        self.conf = crowdsec_conf(fs, conf_path)
        if not self.conf['ok']:
            if fs.read(conf_path) is None:
                err('level=fatal msg="while reading yaml file: open %s: no such file or directory"' % conf_path)
            else:
                err('level=fatal msg="while reading yaml file: %s: yaml error"' % conf_path)
            raise Exit(1)
        out_fmt = self.gl.get('output')
        if out_fmt is None:
            try:
                out_fmt = yaml_load(fs.read(conf_path) or '')['cscli']['output']
            except (TypeError, KeyError, YamlError):
                out_fmt = 'human'
        if out_fmt not in ('human', 'json', 'raw'):
            err("Error: output format '%s' not supported: must be one of human, json, raw" % out_fmt)
            raise Exit(1)
        self.output = out_fmt
        self.gate_lapi()
        name = 'c_' + '_'.join(p.replace('-', '_') for p in self.path)
        fn = getattr(self, name, None)
        if fn is None:
            if self.path[0] in _TYPES:
                return self.hub_item_cmd()
            unsupported(self.run, ['exec', 'CrowdSec', 'cscli'] + list(self.path))
        return fn()

    def gate_lapi(self):
        mode = self.st['knobs'].get('lapi_down', 0)
        if not mode:
            return
        need = self.path in _NEEDS_LAPI or (mode == 1 and self.path in _SPEC_FAILS)
        if not need:
            return
        if self.path == ('lapi', 'status'):
            out('Loaded credentials from /etc/crowdsec/local_api_credentials.yaml')
            out('Trying to authenticate with username "localhost" on http://0.0.0.0:8080/')
            err('Error: cscli lapi status: failed to authenticate to Local API (LAPI): Post "http://0.0.0.0:8080/v1/watchers/login": dial tcp 0.0.0.0:8080: connect: connection refused')
            raise Exit(1)
        if self.path in _NEEDS_LAPI:
            for k in (4, 3, 2, 1):
                self.log('error', 'while performing request: dial tcp 127.0.0.1:8080: connect: connection refused; %d retries left' % k)
        fl, args = self.fl, self.args
        p = self.path
        if p == ('decisions', 'list'):
            q = 'has_active_decision=true&include_capi=%s' % ('true' if fl.get('all') else 'false')
            if not fl.get('all'):
                q += '&limit=%d' % fl.get('limit', 100)
            self.fatal('unable to retrieve decisions: performing request: Get "%s/v1/alerts?%s": %s' % (LAPI_URL, q, _JWT))
        if p == ('decisions', 'add'):
            v = fl.get('ip') or fl.get('range') or fl.get('value') or ''
            self.log('error', 'Cannot check if %s is in allowlist: Get "%s/v1/allowlists/check/%s": %s' % (v, LAPI_URL, v, _JWT))
            raise Exit(1)
        if p == ('decisions', 'delete'):
            q = '&'.join('%s=%s' % (k, fl[k]) for k in ('ip', 'range', 'type', 'value', 'scenario', 'origin') if fl.get(k))
            self.fatal('unable to delete decisions: Delete "%s/v1/decisions?%s": %s' % (LAPI_URL, q, _JWT))
        if p == ('decisions', 'import'):
            self.fatal('Get "%s/v1/allowlists/check": %s' % (LAPI_URL, _JWT))
        if p == ('alerts', 'list'):
            self.fatal('unable to list alerts: performing request: Get "%s/v1/alerts?include_capi=%s&limit=%d": %s' % (LAPI_URL, 'true' if fl.get('all') else 'false', fl.get('limit', 50), _JWT))
        if p == ('alerts', 'inspect'):
            self.fatal("can't find alert with id %s: Get \"%s/v1/alerts/%s\": %s" % (args[0], LAPI_URL, args[0], _JWT))
        if p == ('alerts', 'delete'):
            self.fatal('unable to delete alert: Delete "%s/v1/alerts": %s' % (LAPI_URL, _JWT))
        if p == ('allowlists', 'list'):
            self.fatal('Get "%s/v1/allowlists?with_content=true": %s' % (LAPI_URL, _JWT))
        if p == ('allowlists', 'inspect'):
            self.fatal('unable to get allowlist: Get "%s/v1/allowlists/%s?with_content=true": %s' % (LAPI_URL, args[0], _JWT))
        if p == ('allowlists', 'check'):
            self.fatal('cannot check if %s is in allowlist: Get "%s/v1/allowlists/check/%s": %s' % (args[0], LAPI_URL, args[0], _JWT))
        if p in (('metrics',), ('metrics', 'show')):
            self.fatal('failed to fetch prometheus metrics: executing GET request for URL "http://127.0.0.1:6060/metrics": Get "http://127.0.0.1:6060/metrics": dial tcp 127.0.0.1:6060: connect: connection refused')
        if p == ('capi', 'status'):
            out('Loaded credentials from /etc/crowdsec//online_api_credentials.yaml')
            self.fatal('failed to authenticate to Central API (CAPI): local API unreachable: dial tcp 127.0.0.1:8080: connect: connection refused')
        self.fatal('unable to reach the Local API: Get "%s/v1/heartbeat": dial tcp 127.0.0.1:8080: connect: connection refused' % LAPI_URL)

    # -- LAPI bookkeeping (metrics counters + access log lines for what the real process would have seen)
    def hit(self, route, method='GET', path=None, code=200):
        """one request to the LAPI: cscli logs in once per invocation, then calls the route"""
        if not self._logged_in:
            self._logged_in = True
            lapi_hit(self.st, '/v1/watchers/login', 'POST')
            log_lapi(self.st, self.t, 'POST', '/v1/watchers/login', 200)
            self._machine_seen(self.t)                      # every login refreshes the machine's updated_at
        lapi_hit(self.st, route, method)
        log_lapi(self.st, self.t + 0.002, method, path or route, code)
        if route == '/v1/alerts' and method == 'POST':
            self._machine_seen(self.t + 0.002, push=True)   # pushing alerts sets last_push (and updated_at)
        self.run.touch()

    def _machine_seen(self, t, push=False):
        """what the LAPI records about the machine cscli logs in as (the heartbeat is the engine's job, not cscli's)"""
        m = next((x for x in self.cs['machines'] if x['id'] == 'localhost'), None)
        if m is not None:
            m['updated'] = t
            if push:
                m['last_push'] = t

    # -- helpers -----------------------------------------------------------------------------------
    def c_version(self):
        outn(version_text(self.st))

    def _validate_ip_range(self, ip, rng):
        if ip and parse_ip(ip) is None:
            self.fatal('%s is not a valid ip' % ip)
        if rng and parse_cidr(rng) is None:
            self.fatal('%s is not a valid range' % rng)

    def _filters(self, alerts_cmd):
        fl = self.fl
        ip, rng = fl.get('ip'), fl.get('range')
        self._validate_ip_range(ip, rng)
        f = {'all': fl.get('all'), 'no_simu': fl.get('no-simu'), 'since': fl.get('since') or None, 'until': fl.get('until') or None,
             'scenario': fl.get('scenario') or None, 'scope': None, 'value': fl.get('value') or None,
             'ip': ip or None, 'range': rng or None, 'contained': fl.get('contained'), 'type': fl.get('type') or None,
             'origin': fl.get('origin') or None, 'kind': fl.get('kind') or None}
        if fl.get('scope'):
            f['scope'] = sanitize_scope(fl['scope'])
        return f

    @staticmethod
    def _as_text(a):
        s = a['source']
        return ('%s %s' % (s.get('as_number', ''), s.get('as_name', ''))).strip() if s.get('as_number') or s.get('as_name') else ''


class DecisionCmds(object):
    def c_decisions_list(self):
        fl = self.fl
        f = self._filters(False)
        f['active'] = True
        limit = fl.get('limit', 100)
        if limit < 0:
            self.fatal('unable to retrieve decisions: performing request: API error: http code 500, no response body')
        alerts = self.db.query_alerts(self.t, f)
        if not fl.get('all') and limit > 0:
            alerts = alerts[:limit]
        shown, skipped = dedup_decisions(alerts)
        if self.output == 'json':
            if not shown:
                out(self.empty_list_text())
            else:
                out(gojson([alert_out(a, self.t) for a in shown]))
            return
        rows = []
        for a in shown:
            for d in a['decisions']:
                rows.append((a, d))
        if self.output == 'raw':
            hdr = ['id', 'source', 'ip', 'reason', 'action', 'country', 'as', 'events_count', 'expiration', 'simulated', 'alert_id']
            if fl.get('machine'):
                hdr.append('machine')
            out(csv_line(hdr))
            for a, d in rows:
                line = [d['id'], d['origin'], '%s:%s' % (d['scope'], d['value']), d['scenario'], d['type'], a['source'].get('cn', ''),
                        self._as_text(a), a['events_count'], go_dur(d['until'] - self.t), 'true' if d['simulated'] else 'false', a['id']]
                if fl.get('machine'):
                    line.append(a['machine'])
                out(csv_line(line))
            return
        if not rows:
            out('No active decisions')
            return
        hdr = ['ID', 'Source', 'Scope:Value', 'Reason', 'Action', 'Country', 'AS', 'Events', 'expiration', 'Alert ID']
        if fl.get('machine'):
            hdr.append('Machine')
        trs = []
        for a, d in rows:
            r = [str(d['id']), d['origin'], '%s:%s' % (d['scope'], d['value']), d['scenario'], ('(simul)' if d['simulated'] else '') + d['type'],
                 a['source'].get('cn', ''), self._as_text(a), str(a['events_count']), go_dur(d['until'] - self.t), str(a['id'])]
            if fl.get('machine'):
                r.append(a['machine'])
            trs.append(r)
        out(table_classic(hdr, trs))
        if skipped:
            out('%d duplicated entries skipped' % skipped)

    # -- decisions add -----------------------------------------------------------------------------
    def c_decisions_add(self):
        fl = self.fl
        ip, rng, value = fl.get('ip'), fl.get('range'), fl.get('value')
        if ip:
            scope, value = 'Ip', ip
            if parse_ip(ip) is None:
                self.fatal('%s is not a valid ip' % ip)
        elif rng:
            scope, value = 'Range', rng
            if parse_cidr(rng) is None:
                self.fatal('%s is not a valid range' % rng)
        elif value:
            scope = sanitize_scope(fl.get('scope') or 'Ip')
        else:
            self.fatal('missing arguments, a value is required (--ip, --range or --scope and --value)')
        typ = fl.get('type') or 'ban'
        reason = fl.get('reason') or "manual '%s' from 'localhost'" % typ
        dur_s = fl.get('duration', '4h')
        bypass = fl.get('bypass-allowlist')
        if bypass and not has_allowlists(self.st):
            self.fatal("unknown shorthand flag: 'B' in -B" if '-B' in self.argv else 'unknown flag: --bypass-allowlist')
        # allowlist check (values that are not addresses are not checked, invalid addresses only log an error)
        if has_allowlists(self.st) and scope in ('Ip', 'Range') and not bypass:
            if span(value) is None:
                self.log('error', "Cannot check if %s is in allowlist: API error: invalid ip address '%s'" % (value, value))
            else:
                hit = self.db.allowlist_matches(self.t, value)
                self.hit('/v1/allowlists/check/:ip_or_range', 'GET', '/v1/allowlists/check/' + value)
                if hit:
                    al, it = hit[0]
                    self.fatal('%s is allowlisted by item %s from %s%s, use --bypass-allowlist to add the decision anyway' % (
                        value, it['value'], al['name'], (' (%s)' % it['description']) if it.get('description') else ''))
        dur, e = parse_dur(dur_s)
        if e:
            self.fatal('API error: machine "localhost": building decisions for alert %s: creating alert decisions: decision duration \'%s\': %s: unable to parse duration' % (
                self.db.rng.uuid(), dur_s, e))
        if scope in ('Ip', 'Range') and span(value) is None:
            # the real LAPI silently drops a decision whose value is not an address; cscli still reports success
            self.log('info', 'Decision successfully added')
            return
        self.db.add_manual(self.t, scope, value, dur, typ, reason)
        self.hit('/v1/alerts', 'POST')
        self.log('info', 'Decision successfully added')

    # -- decisions delete --------------------------------------------------------------------------
    def c_decisions_delete(self):
        fl = self.fl
        if fl.get('id'):
            if not re.match(r'^[-+]?[0-9]+$', fl['id']):
                self.fatal("id '%s' is not an integer: strconv.Atoi: parsing \"%s\": invalid syntax" % (fl['id'], fl['id']))
            d = self.db.find_decision(int(fl['id']))
            if d is None:
                self.fatal("unable to delete decision: API error: decision with id '%s' doesn't exist: unable to delete" % fl['id'])
            d['until'] = self.t
            self.hit('/v1/decisions/:decision_id', 'DELETE', '/v1/decisions/' + fl['id'])
            self.log('info', '1 decision(s) deleted')
            return
        if not any(fl.get(k) for k in ('ip', 'range', 'type', 'value', 'scenario', 'origin', 'all')):
            out('Usage:\n  cscli decisions delete [options] [flags]')
            self.fatal('at least one filter or --all must be specified')
        self._validate_ip_range(fl.get('ip'), fl.get('range'))
        f = {'ip': fl.get('ip'), 'range': fl.get('range'), 'type': fl.get('type'), 'value': fl.get('value'),
             'scenario': fl.get('scenario'), 'origin': fl.get('origin'), 'contained': fl.get('contained')}
        n = self.db.delete_decisions(self.t, f)
        self.hit('/v1/decisions', 'DELETE')
        self.log('info', '%d decision(s) deleted' % n)

    # -- decisions import --------------------------------------------------------------------------
    def c_decisions_import(self):
        fl = self.fl
        src = fl.get('input')
        if src is None:
            self.fatal('required flag(s) "input" not set')
        fmt = fl.get('format')
        if not fmt:
            if src.endswith('.json'):
                fmt = 'json'
            elif src.endswith('.csv'):
                fmt = 'csv'
            else:
                self.fatal('unable to guess format from file extension, please provide a format with --format flag')
        if src == '-':
            text = self.run.read_stdin()
            label = 'stdin'
        else:
            text = self.run.fs().read(src)
            if text is None:
                self.fatal('unable to open %s: open %s: no such file or directory' % (src, src))
            label = src
        out('Parsing %s' % fmt)
        defaults = {'duration': fl.get('duration') or '4h', 'reason': fl.get('reason') or 'manual', 'scope': fl.get('scope') or 'Ip', 'type': fl.get('type') or 'ban'}
        items = []
        if fmt == 'json':
            try:
                doc = json.loads(text)
            except ValueError as e:
                m = re.search(r"char (\d+)", str(e))
                pos = int(m.group(1)) if m else 0
                ch = text[pos:pos + 1] or ''
                self.fatal("invalid character '%s' looking for beginning of value" % ch if ch else 'unexpected end of JSON input')
            if not isinstance(doc, list):
                self.fatal('json: cannot unmarshal object into Go value of type []main.decisionRaw')
            items = [dict(x) for x in doc if isinstance(x, dict)]
        elif fmt == 'csv':
            lines = [ln for ln in text.splitlines() if ln.strip()]
            if lines:
                cols = [c.strip() for c in lines[0].split(',')]
                for ln in lines[1:]:
                    vals = [c.strip() for c in ln.split(',')]
                    items.append(dict(zip(cols, vals)))
        elif fmt == 'values':
            items = [{'value': ln.strip()} for ln in text.splitlines() if ln.strip()]
        else:
            self.fatal("unknown format '%s'" % fmt)
        if not items:
            self.fatal('no decisions found')
        batch = fl.get('batch') or 0
        good = []
        for it in items:
            v = it.get('value')
            if not v:
                self.fatal('missing value in input')
            scope = sanitize_scope(it.get('scope') or defaults['scope'])
            if scope in ('Ip', 'Range'):
                if span(str(v)) is None:
                    self.fatal("API error: invalid ip address '%s'" % v)
                if has_allowlists(self.st):
                    hit = self.db.allowlist_matches(self.t, str(v))
                    if hit:
                        out('Value %s is allowlisted by [%s]' % (v, ' '.join('%s from %s%s' % (it2['value'], al['name'], (' (%s)' % it2['description']) if it2.get('description') else '') for al, it2 in hit)))
                        continue
            dur, e = parse_dur(str(it.get('duration') or defaults['duration']))
            if e:
                self.fatal("API error: machine \"localhost\": building decisions for alert %s: creating alert decisions: decision duration '%s': %s: unable to parse duration" % (
                    self.db.rng.uuid(), it.get('duration') or defaults['duration'], e))
            good.append({'scope': scope, 'value': str(v), 'type': it.get('type') or defaults['type'], 'reason': it.get('reason') or defaults['reason'], 'dur': dur})
        chunks = [items_ for items_ in ([good[i:i + batch] for i in range(0, len(good), batch)] if batch else [good]) if items_]
        for ch in chunks:
            self.db.add_import(self.t, ch, label)
            self.hit('/v1/alerts', 'POST')
        outn('Imported %d decisions' % len(good))


class AlertCmds(object):
    def c_alerts_list(self):
        fl = self.fl
        f = self._filters(True)
        limit = fl.get('limit', 50)
        alerts = self.db.query_alerts(self.t, f)
        if not fl.get('all') and limit > 0:
            alerts = alerts[:limit]
        if self.output == 'json':
            if not alerts:
                outn(self.empty_list_text())
            else:
                outn(gojson([alert_out(a, self.t) for a in alerts]))
            return

        def dtypes(a):
            counts, order = {}, []
            for d in a['decisions']:
                k = ('(simul)' if d['simulated'] else '') + d['type']
                if k not in counts:
                    order.append(k)
                counts[k] = counts.get(k, 0) + 1
            return ' '.join('%s:%d' % (k, counts[k]) for k in order)
        if self.output == 'raw':
            hdr = ['id', 'scope', 'value', 'reason', 'country', 'as', 'decisions', 'created_at', 'kind']
            if fl.get('machine'):
                hdr.append('machine')
            out(csv_line(hdr))
            for a in alerts:
                line = [a['id'], a['source'].get('scope', ''), a['source'].get('value', ''), a['scenario'], a['source'].get('cn', ''),
                        self._as_text(a), dtypes(a), iso_s(a['created']), a['kind']]
                if fl.get('machine'):
                    line.append(a['machine'])
                out(csv_line(line))
            return
        if not alerts:
            out('No active alerts')
            return
        hdr = ['ID', 'value', 'reason', 'country', 'as', 'decisions', 'created_at', 'kind']
        if fl.get('machine'):
            hdr.append('machine')
        rows = []
        for a in alerts:
            s = a['source']
            r = [str(a['id']), ('%s:%s' % (s.get('scope', ''), s.get('value', ''))) if s.get('scope') else '', a['scenario'], s.get('cn', ''),
                 self._as_text(a), dtypes(a), iso_s(a['start']), a['kind']]
            if fl.get('machine'):
                r.append(a['machine'])
            rows.append(r)
        out(table_classic(hdr, rows))

    def c_alerts_inspect(self):
        for raw in self.args:
            if not re.match(r'^[0-9]+$', raw):
                self.fatal('bad alert id %s' % raw)
            a = self.db.find_alert(int(raw))
            if a is None:
                self.fatal("can't find alert with id %s: API error: object not found" % raw)
            self.hit('/v1/alerts/:alert_id', 'GET', '/v1/alerts/' + raw)
            if self.output == 'json':
                out(gojson(alert_out(a, self.t), 2))
                continue
            if self.output == 'raw':
                out(csv_line(['id', 'scope', 'value', 'reason', 'country', 'as', 'decisions', 'created_at', 'kind']))
                s = a['source']
                out(csv_line([a['id'], s.get('scope', ''), s.get('value', ''), a['scenario'], s.get('cn', ''), self._as_text(a), '', iso_s(a['created']), a['kind']]))
                continue
            self._inspect_human(a)

    def _inspect_human(self, a):
        s = a['source']
        out('')
        out('#' * 96)
        out('')
        out(' - ID           : %d' % a['id'])
        out(' - Date         : %s' % iso_s(a['created']))
        out(' - Machine      : %s' % a['machine'])
        out(' - Simulation   : %s' % ('true' if a['simulated'] else 'false'))
        out(' - Remediation  : %s' % ('true' if a.get('remediation') else 'false'))
        out(' - Kind         : %s' % a['kind'])
        out(' - Reason       : %s' % a['scenario'])
        out(' - Events Count : %d' % a['events_count'])
        out(' - Scope:Value  : %s' % (('%s:%s' % (s.get('scope', ''), s.get('value', ''))) if s.get('scope') else ''))
        out(' - Country      : %s' % s.get('cn', ''))
        out(' - AS           : %s' % (self._as_text(a)))
        out(' - Begin        : %s' % iso_s(a['start']))
        out(' - End          : %s' % iso_s(a['stop']))
        out(' - UUID         : %s' % (a['uuid'] or ''))
        out('')
        if a['decisions']:
            rows = [[str(d['id']), '%s:%s' % (d['scope'], d['value']), ('(simul)' if d['simulated'] else '') + d['type'], go_dur(d['until'] - self.t), iso_s(a['created'])] for d in a['decisions']]
            out(table_classic(['ID', 'scope:value', 'action', 'expiration', 'created_at'], rows, 'Active Decisions'))
        if a.get('meta'):
            # the alert's context: each meta value is a JSON list, one table row per element
            rows = []
            for k, v in a['meta']:
                try:
                    vals = json.loads(v)
                except ValueError:
                    vals = None
                for x in (vals if isinstance(vals, list) else [v]):
                    rows.append([k, str(x)])
            out('')
            out(' - Context  :')
            out(table_classic(['Key', 'Value'], sorted(rows, key=lambda r: r[0])))
        if self.fl.get('details'):
            out('')
            out(' - Events  :')
            for ev in a.get('events') or []:
                out('\n- Date: %s' % ev['timestamp'])
                out(table_classic(['Key', 'Value'], [[m['key'], m['value']] for m in ev['meta']]))

    def c_alerts_delete(self):
        fl = self.fl
        if fl.get('id'):
            if not re.match(r'^[0-9]+$', fl['id']):
                self.fatal('unable to delete alert: API error: alert_id must be valid integer')
            a = self.db.find_alert(int(fl['id']))
            if a is None:
                self.fatal('unable to delete alert: API error: ent: alert not found')
            self.cs['alerts'] = [x for x in self.cs['alerts'] if x['id'] != a['id']]
            self.hit('/v1/alerts/:alert_id', 'DELETE', '/v1/alerts/' + fl['id'])
            self.log('info', '1 alert(s) deleted')
            return
        if not any(fl.get(k) for k in ('scope', 'value', 'scenario', 'ip', 'range', 'all')):
            out('Usage:\n  cscli alerts delete [filters] [--all] [flags]')
            self.fatal('at least one filter or --all must be specified')
        self._validate_ip_range(fl.get('ip'), fl.get('range'))
        f = {'scenario': fl.get('scenario'), 'scope': sanitize_scope(fl['scope']) if fl.get('scope') else None, 'value': fl.get('value'),
             'ip': fl.get('ip'), 'range': fl.get('range'), 'contained': fl.get('contained')}
        n = self.db.delete_alerts(self.t, f)
        self.hit('/v1/alerts', 'DELETE')
        self.log('info', '%d alert(s) deleted' % n)

    def c_alerts_flush(self):
        max_age = self.fl.get('max-age', 168 * 3600.0)
        max_items = self.fl.get('max-items', 5000)
        self.log('info', 'Flushing alerts. !! This may take a long time !!')
        keep = [a for a in self.cs['alerts'] if self.t - a['created'] <= max_age]
        keep.sort(key=lambda a: (int(a['created']), a['id']), reverse=True)
        self.cs['alerts'] = sorted(keep[:max_items], key=lambda a: a['id'])
        self.run.touch()
        self.log('info', 'Alerts flushed')


# ==================================================================================================
# cscli: allowlists, bouncers, machines, metrics, lapi/capi/console status
# ==================================================================================================


class AllowlistCmds(object):
    """cscli allowlists ...  (create/add/remove/list/inspect/check/delete)"""

    def _al_find(self, name):
        for al in self.cs['allowlists']:
            if al['name'] == name:
                return al
        return None

    def c_allowlists_list(self):
        lst = self.cs['allowlists']
        self.hit('/v1/allowlists', 'GET', '/v1/allowlists?with_content=true')
        if self.output == 'json':
            out(gojson([allowlist_out(a) for a in lst], 2) if lst else '[]')
            return
        if self.output == 'raw':
            out(csv_line(['name', 'description', 'created_at', 'updated_at', 'console_managed', 'size']))
            for a in lst:
                out(csv_line([a['name'], a['description'], iso_ms(a['created']), iso_ms(a['updated']), 'false', len(a['items'])]))
            return
        rows = [[a['name'], a['description'], iso_ms(a['created']), iso_ms(a['updated']), 'no', str(len(a['items'])).rjust(4)] for a in lst]
        out(table_modern(['Name', 'Description', 'Created at', 'Updated at', 'Managed by Console', 'Size'], rows))

    def c_allowlists_create(self):
        name = self.args[0]
        if 'description' not in self.fl:
            self.fatal('required flag(s) "description" not set')
        if self._al_find(name):
            self.fatal("allowlist '%s' already exists" % name)
        self.cs['allowlists'].append({'name': name, 'description': self.fl['description'], 'created': self.t, 'updated': self.t, 'items': []})
        self.run.touch()
        out("allowlist '%s' created successfully" % name)

    def c_allowlists_add(self):
        name, values = self.args[0], self.args[1:]
        al = self._al_find(name)
        if al is None:
            self.fatal("allowlist '%s' not found" % name)
        exp = self.fl.get('expiration') or 0
        added = 0
        for v in values:
            if span(v) is None:
                self.log('error', "invalid ip address '%s'" % v, module='db')
                continue
            if any(it['value'] == v and (it['expiration'] is None or it['expiration'] > self.t) for it in al['items']):
                self.log('warning', 'value %s already in allowlist' % v)
                continue
            al['items'].append({'value': v, 'description': self.fl.get('comment') or '', 'created': self.t + 0.001 * added,
                                'expiration': (self.t + exp) if exp > 0 else None})
            added += 1
        if added:
            al['updated'] = self.t
            n = self.db.sweep_allowlists(self.t)
            self.run.touch()
            out('added %d values to allowlist %s' % (added, name))
            if n:
                out('%d decisions deleted by allowlists' % n)
        elif not any(span(v) is None for v in values):
            out('no new values for allowlist')

    def c_allowlists_remove(self):
        name, values = self.args[0], self.args[1:]
        al = self._al_find(name)
        if al is None:
            self.fatal("allowlist '%s' not found" % name)
        before = len(al['items'])
        al['items'] = [it for it in al['items'] if it['value'] not in values]
        n = before - len(al['items'])
        if n:
            al['updated'] = self.t
            self.run.touch()
            outn('removed %d values from allowlist %s' % (n, name))
        else:
            out('no value to remove from allowlist')

    def c_allowlists_inspect(self):
        al = self._al_find(self.args[0])
        if al is None:
            self.fatal("unable to get allowlist: API error: allowlist '%s' not found" % self.args[0])
        self.hit('/v1/allowlists/:allowlist_name', 'GET', '/v1/allowlists/%s?with_content=true' % al['name'])
        if self.output == 'json':
            out(gojson(allowlist_out(al), 2))
            return
        if self.output == 'raw':
            out(csv_line(['name', 'description', 'value', 'comment', 'expiration', 'created_at', 'console_managed']))
            for it in al['items']:
                out(csv_line([al['name'], al['description'], it['value'], it.get('description') or '',
                              'never' if it['expiration'] is None else iso_s(it['expiration']), iso_s(it['created']), 'false']))
            return
        out(table_kv('Allowlist: %s' % al['name'], [('Name', al['name']), ('Description', al['description']), ('Created at', iso_ms(al['created'])),
                                                    ('Updated at', iso_ms(al['updated'])), ('Managed by Console', 'no')]))
        out('')
        rows = [[it['value'], it.get('description') or '', 'never' if it['expiration'] is None else iso_ms(it['expiration']), iso_s(it['created'])] for it in al['items']]
        out(table_modern(['Value', 'Comment', 'Expiration', 'Created at'], rows))

    def c_allowlists_check(self):
        for v in self.args:
            if span(v) is None:
                self.fatal("cannot check if %s is in allowlist: API error: invalid ip address '%s'" % (v, v))
            hit = self.db.allowlist_matches(self.t, v)
            self.hit('/v1/allowlists/check/:ip_or_range', 'GET', '/v1/allowlists/check/' + v)
            if hit:
                al, it = hit[0]
                out('%s is allowlisted by item %s from %s%s' % (v, it['value'], al['name'], (' (%s)' % it['description']) if it.get('description') else ''))
            else:
                out('%s is not allowlisted' % v)

    def c_allowlists_delete(self):
        al = self._al_find(self.args[0])
        if al is None:
            self.fatal("allowlist '%s' not found" % self.args[0])
        self.cs['allowlists'].remove(al)
        self.run.touch()
        out("allowlist '%s' deleted successfully" % al['name'])


class BouncerCmds(object):
    """cscli bouncers ...  (database direct)"""

    def _bouncer(self, name):
        for b in self.cs['bouncers']:
            if b['name'] == name:
                return b
        return None

    def c_bouncers_list(self):
        bs = self.cs['bouncers']
        if self.output == 'json':
            out(gojson([bouncer_out(b) for b in bs], 2) if bs else '[]')
            return
        if self.output == 'raw':
            out(csv_line(['name', 'ip', 'revoked', 'last_pull', 'type', 'version', 'auth_type']))
            for b in bs:
                out(csv_line([b['name'], b.get('ip', ''), 'revoked' if b.get('revoked') else 'validated', iso_s(b['last_pull']) if b.get('last_pull') else '',
                              b.get('type', ''), b.get('version', ''), b.get('auth_type', 'api-key')]))
            return
        rows = [[b['name'], b.get('ip', ''), '\U0001f6ab' if b.get('revoked') else '✔️', iso_s(b['last_pull']) if b.get('last_pull') else '',
                 b.get('type', ''), b.get('version', ''), b.get('auth_type', 'api-key')] for b in bs]
        out(table_modern(['Name', 'IP Address', 'Valid', 'Last API pull', 'Type', 'Version', 'Auth Type'], rows))

    def c_bouncers_add(self):
        name = self.args[0]
        if self._bouncer(name):
            self.fatal('unable to create bouncer: bouncer %s already exists' % name)
        key = self.fl.get('key') or self.db.rng.apikey()
        self.cs['bouncers'].append({'name': name, 'created': self.t, 'updated': self.t, 'ip': '', 'type': '', 'version': '', 'last_pull': None, 'key': key})
        self.run.touch()
        if self.output == 'raw':
            outn(key)
        elif self.output == 'json':
            outn(json.dumps(key))
        else:
            out("API key for '%s':\n\n   %s\n\nPlease keep this key since you will not be able to retrieve it!" % (name, key))

    def c_bouncers_delete(self):
        for name in self.args:
            b = self._bouncer(name)
            if b is None:
                if self.fl.get('ignore-missing'):
                    continue
                self.fatal('unable to delete bouncer %s: ent: bouncer not found' % name)
            self.cs['bouncers'].remove(b)
            self.run.touch()
            self.log('info', "bouncer '%s' deleted successfully" % name)

    def c_bouncers_inspect(self):
        b = self._bouncer(self.args[0])
        if b is None:
            self.fatal("unable to read bouncer data '%s': ent: bouncer not found" % self.args[0])
        if self.output == 'raw':
            self.fatal("output format 'raw' not supported for this command")
        if self.output == 'json':
            out(gojson(bouncer_out(b), 2))
            return
        outn(table_kv('Bouncer: %s' % b['name'],       # no newline after the frame, as the real one
                      [('Created At', go_time(b['created'], 9)), ('Last Update', go_time(b['updated'], 9)), ('Revoked?', 'true' if b.get('revoked') else 'false'),
                       ('IP Address', b.get('ip', '')), ('Type', b.get('type', '')), ('Version', b.get('version', '')),
                       ('Last Pull', go_time(b['last_pull'], 9) if b.get('last_pull') else ''), ('Auth type', b.get('auth_type', 'api-key')),
                       ('OS', b.get('os', '?')), ('Auto Created', 'false')]))

    def c_bouncers_prune(self):
        dur = self.fl.get('duration', 3600.0)
        old = [b for b in self.cs['bouncers'] if not b.get('last_pull') or self.t - b['last_pull'] > dur]
        if not old:
            out('No bouncers to prune.')
            return
        if not self.fl.get('force'):
            self.fatal('bouncers prune needs confirmation: use --force')
        for b in old:
            self.cs['bouncers'].remove(b)
        self.run.touch()
        self.log('info', 'Successfully deleted %d bouncers' % len(old))


class MachineCmds(object):
    """cscli machines ..."""

    def c_machines_list(self):
        ms = self.cs['machines']
        if self.output == 'json':
            out(gojson([machine_out(m) for m in ms], 2) if ms else '[]')
            return
        if self.output == 'raw':
            out(csv_line(['machine_id', 'ip_address', 'updated_at', 'validated', 'version', 'auth_type', 'last_heartbeat', 'os']))
            for m in ms:
                out(csv_line([m['id'], m.get('ip', '127.0.0.1'), iso_s(m['updated']), 'true' if m.get('validated', True) else 'false', m['version'],
                              m.get('auth_type', 'password'), iso_s(m['last_heartbeat']) if m.get('last_heartbeat') else '', m.get('os', 'alpine (docker)/3.24.1')]))
            return
        rows = [[m['id'], m.get('ip', '127.0.0.1'), iso_s(m['updated']), '✔️' if m.get('validated', True) else '\U0001f6ab', m['version'],
                 m.get('os', 'alpine (docker)/3.24.1'), m.get('auth_type', 'password'), self._heartbeat_cell(m)] for m in ms]
        out(table_modern(['Name', 'IP Address', 'Last Update', 'Status', 'Version', 'OS', 'Auth Type', 'Last Heartbeat'], rows))

    def _heartbeat_cell(self, m):
        """how long ago the machine sent its last heartbeat; a warning sign in front when there is none or it is over two minutes old"""
        if not m.get('last_heartbeat'):
            return '⚠️ -'
        age = self.t - m['last_heartbeat']
        return go_dur(age) if age < 120 else '⚠️ ' + go_dur(age)

    def c_machines_inspect(self):
        name = self.args[0]
        m = next((x for x in self.cs['machines'] if x['id'] == name), None)
        if m is None:
            self.log('warning', 'QueryMachineByID : ent: machine not found', force=True, module='db')
            self.fatal("unable to read machine data '%s': user '%s': user doesn't exist" % (name, name))
        if self.output == 'raw':
            self.fatal("output format 'raw' not supported for this command")
        if self.output == 'json':
            o = machine_out(m)
            o['metrics'] = {}
            out(gojson(o, 2))
            return
        rows = [('IP Address', m.get('ip', '127.0.0.1')), ('Created At', go_time(m['created'], 9)), ('Last Update', go_time(m['updated'], 9)),
                ('Last Heartbeat', go_time(m['last_heartbeat'], 9) if m.get('last_heartbeat') else '<nil>'),
                ('Validated?', 'true' if m.get('validated', True) else 'false'), ('CrowdSec version', m['version']),
                ('OS', m.get('os', 'alpine (docker)/3.24.1')), ('Auth type', m.get('auth_type', 'password'))]
        for i, (src, n) in enumerate(sorted((m.get('datasources') or {}).items())):
            rows.append(('Datasources' if i == 0 else '', '%s: %d' % (src, n)))
        for i, c in enumerate(sorted(Hub(self.st).names('collections'))):
            rows.append(('Collections' if i == 0 else '', c))
        out(box_kv('Machine: %s' % name, rows))


# `cscli metrics list`: (key, title, description) exactly as 1.8.1 prints them
METRIC_TYPES = (
    ('acquisition', 'Acquisition Metrics', 'Measures the lines read, parsed, and unparsed per datasource. Zero read lines indicate a misconfigured or inactive '
     'datasource. Zero parsed lines means the parser(s) failed. Non-zero parsed lines are fine as crowdsec selects relevant lines.'),
    ('alerts', 'Local API Alerts', 'Tracks the total number of past and present alerts for the installed scenarios.'),
    ('appsec-challenge', 'Bot Detection Metrics', 'Measures the challenge lifecycle of the AppSec component.'),
    ('appsec-challenge-infra', 'Bot Detection Infrastructure Metrics', 'Tracks the internal upkeep of the AppSec challenge runtime: signing-key '
     'rotation, JS re-obfuscation and cache eviction.'),
    ('appsec-engine', 'Appsec Metrics', 'Measures the number of parsed and blocked requests by the AppSec Component.'),
    ('appsec-rule', 'Appsec Rule Metrics', 'Provides \u201cper AppSec Component\u201d information about the number of matches for loaded AppSec Rules.'),
    ('bouncers', 'Bouncer Metrics', 'Network traffic blocked by bouncers.'),
    ('decisions', 'Local API Decisions', 'Provides information about all currently active decisions. Includes both local (crowdsec) and global decisions '
     '(CAPI), and lists subscriptions (lists).'),
    ('lapi', 'Local API Metrics', 'Monitors the requests made to local API routes.'),
    ('lapi-bouncer', 'Local API Bouncers Metrics', 'Tracks total hits to remediation component related API routes.'),
    ('lapi-decisions', 'Local API Bouncers Decisions', 'Tracks the number of empty/non-empty answers from LAPI to bouncers that are working in "live" mode.'),
    ('lapi-machine', 'Local API Machines Metrics', 'Tracks the number of calls to the local API from each registered machine.'),
    ('parsers', 'Parser Metrics', 'Tracks the number of events processed by each parser and indicates success of failure. Zero parsed lines means the '
     'parser(s) failed. Non-zero unparsed lines are fine as crowdsec select relevant lines.'),
    ('scenarios', 'Scenario Metrics', 'Measure events in different scenarios. Current count is the number of buckets during metrics collection. Overflows '
     'are past event-producing buckets, while Expired are the ones that didn\u2019t receive enough events to Overflow.'),
    ('stash', 'Parser Stash Metrics', 'Tracks the status of stashes that might be created by various parsers and scenarios.'),
    ('whitelists', 'Whitelist Metrics', 'Tracks the number of events processed and possibly whitelisted by each parser whitelist.'),
)
METRIC_GROUPS = {'engine': ('acquisition', 'parsers', 'scenarios', 'stash', 'whitelists'),
                 'lapi': ('alerts', 'decisions', 'lapi', 'lapi-bouncer', 'lapi-decisions', 'lapi-machine')}
METRIC_HEADERS = {
    'acquisition': ('Source', 'Lines read', 'Lines parsed', 'Lines unparsed', 'Lines poured to bucket', 'Lines whitelisted'),
    'alerts': ('Reason', 'Count'),
    'appsec-challenge': ('Bot Detection', 'Requested', 'Submitted', 'Solved', 'Granted', 'Exempt', 'Protocol Failures', 'Submissions Rejected', 'Cookies Invalid'),
    'appsec-engine': ('Appsec Engine', 'Processed', 'Blocked', 'Ch. Requested', 'Ch. Accepted', 'Ch. Rejected'),
    'decisions': ('Reason', 'Origin', 'Action', 'Count'),
    'lapi': ('Route', 'Method', 'Hits'),
    'lapi-bouncer': ('Bouncer', 'Route', 'Method', 'Hits'),
    'lapi-decisions': ('Bouncer', 'Empty answers', 'Non-empty answers'),
    'lapi-machine': ('Machine', 'Route', 'Method', 'Hits'),
    'parsers': ('Parsers', 'Hits', 'Parsed', 'Unparsed'),
    'scenarios': ('Scenario', 'Current Count', 'Overflows', 'Instantiated', 'Poured', 'Expired'),
    'stash': ('Name', 'Type', 'Items'),
    'whitelists': ('Whitelist', 'Reason', 'Hits', 'Whitelisted'),
}


def metric_num(v, units):
    """cscli's number cell: '-' for zero or missing, 12841 -> 12.84k (M, G, T, P, E) unless --no-unit"""
    if not v:
        return '-'
    if units:
        for limit, sym in ((10 ** 18, 'E'), (10 ** 15, 'P'), (10 ** 12, 'T'), (10 ** 9, 'G'), (10 ** 6, 'M'), (10 ** 3, 'k')):
            if v >= limit:
                return '%.2f%s' % (int(v / limit * 100 + 0.5) / 100.0, sym)
    return str(v)


def metric_rows(key, data, units):
    """the rows of one metrics table, from the same dictionaries `metrics -o json` prints (names sorted, as cscli sorts them)"""
    n = lambda v: metric_num(v, units)      # noqa: E731
    if key == 'acquisition':
        return [[src] + [n(d.get(k)) for k in ('reads', 'parsed', 'unparsed', 'pour', 'whitelisted')] for src, d in sorted(data.items())]
    if key == 'alerts':
        return [[reason, str(c)] for reason, c in sorted(data.items())]
    if key == 'decisions':
        return [[reason, origin, action, str(c)] for reason, os_ in sorted(data.items()) for origin, acts in sorted(os_.items())
                for action, c in sorted(acts.items())]
    if key == 'lapi':
        return [[route, method, str(c)] for route, ms in sorted(data.items()) for method, c in sorted(ms.items())]
    if key in ('lapi-machine', 'lapi-bouncer'):
        return [[who, route, method, str(c)] for who, rs in sorted(data.items()) for route, ms in sorted(rs.items()) for method, c in sorted(ms.items())]
    if key == 'lapi-decisions':
        return [[b, str(d.get('Empty', 0)), str(d.get('NonEmpty', 0))] for b, d in sorted(data.items())]
    if key == 'parsers':
        return [[name, n(d.get('hits')), n(d.get('parsed')), n(d.get('unparsed'))] for name, d in sorted(data.items())]
    if key == 'scenarios':
        return [[name, n(d.get('curr_count')), n(d.get('overflow')), n(d.get('instantiation')), n(d.get('pour')), n(d.get('underflow'))]
                for name, d in sorted(data.items())]
    if key == 'whitelists':
        return [[name, reason, n(d.get('hits')), n(d.get('whitelisted'))] for name, rs in sorted(data.items()) for reason, d in sorted(rs.items())]
    return []


class MetricsCmds(object):
    """cscli metrics [show TYPE...] / metrics list (the JSON is a Go map: sorted keys, no trailing newline)"""

    def c_metrics(self):
        self._metrics(())

    def c_metrics_show(self):
        self._metrics(self.args)

    def _metrics(self, wanted):
        m = metrics_out(self.st)
        known = [t for t, _ti, _d in METRIC_TYPES]
        keys = set()
        for a in wanted:
            if a in METRIC_GROUPS:
                keys.update(METRIC_GROUPS[a])
            elif a in known:
                keys.add(a)
            else:
                self.fatal('unknown metrics type: %s' % a)
        if not wanted:
            keys = set(m)
        if self.output == 'raw':
            self.fatal("output format 'raw' not supported for this command")
        if self.output == 'json':
            outn(gojson({k: m.get(k, {}) for k in sorted(keys)}, 1, True))
            return
        titles = dict((t, ti) for t, ti, _d in METRIC_TYPES)
        for k in sorted(keys):
            data = m.get(k) or {}
            if k == 'bouncers':                        # per-bouncer usage tables are not modelled: empty stays empty
                if wanted:
                    out('No bouncer metrics found.')
                continue
            if k not in METRIC_HEADERS:
                continue
            rows = metric_rows(k, data, not self.fl.get('no-unit'))
            if rows or wanted:                        # an explicit request shows the empty tables too
                out(table_classic(METRIC_HEADERS[k], rows, title=titles[k], hdr_left=True))

    def c_metrics_list(self):
        if self.output == 'raw':
            self.fatal("output format 'raw' not supported for this command")
        if self.output == 'json':
            out(gojson([{'type': t, 'title': ti, 'description': d} for t, ti, d in METRIC_TYPES], 1))
            return
        rows = []
        for t, ti, d in METRIC_TYPES:
            words, line, wrapped = d.split(' '), '', []
            for wd in words:
                if line and len(line) + 1 + len(wd) > 60:
                    wrapped.append(line)
                    line = wd
                else:
                    line = (line + ' ' + wd) if line else wd
            rows.append((t, ti, wrapped + [line]))
        w = [max(len('Type'), max(len(r[0]) for r in rows)), max(len('Title'), max(len(r[1]) for r in rows)), 60]
        sep = '+' + '+'.join('-' * (x + 2) for x in w) + '+'
        lines = [sep, '|' + '|'.join(' ' + ' ' * ((w[i] - len(h) + 1) // 2) + h + ' ' * ((w[i] - len(h)) // 2) + ' ' for i, h in enumerate(('Type', 'Title', 'Description'))) + '|', sep]
        for t, ti, desc in rows:
            for i, part in enumerate(desc):
                lines.append('| ' + (t if i == 0 else '').ljust(w[0]) + ' | ' + (ti if i == 0 else '').ljust(w[1]) + ' | ' + part.ljust(w[2]) + ' |')
            lines.append(sep)
        out('\n'.join(lines))


class StatusCmds(object):
    """cscli lapi status / capi status / console status"""

    def c_lapi_status(self):
        out('Loaded credentials from /etc/crowdsec/local_api_credentials.yaml')
        out('Trying to authenticate with username "localhost" on http://0.0.0.0:8080/')
        self.hit('/v1/heartbeat', 'GET')
        out('You can successfully interact with Local API (LAPI)')

    def c_capi_status(self):
        mode = self.st['knobs'].get('capi', 'ok')
        if mode in ('unregistered', 'disabled'):
            self.fatal("no configuration for Central API (CAPI) in '%s'" % self.conf['path'])
        creds = yaml_load(self.run.fs().read('/etc/crowdsec/online_api_credentials.yaml') or '') or {}
        out('Loaded credentials from /etc/crowdsec//online_api_credentials.yaml')
        out('Trying to authenticate with username %s on https://api.crowdsec.net/' % (creds.get('login') if isinstance(creds, dict) else 'unknown'))
        if mode == 'error':
            self.fatal('failed to authenticate to Central API (CAPI): Post "https://api.crowdsec.net/v3/watchers/login": dial tcp: lookup api.crowdsec.net: no such host')
        out('You can successfully interact with Central API (CAPI)')
        out('Sharing signals is enabled')
        out('Pulling community blocklist is enabled')
        out('Pulling blocklists from the console is enabled')

    def c_console_status(self):
        mode = self.st['knobs'].get('capi', 'ok')
        reg = mode in ('ok', 'error')
        text = self.run.fs().read('/etc/crowdsec/console.yaml') or ''
        cfg = yaml_load(text) if text else {}
        cfg = cfg if isinstance(cfg, dict) else {}
        opts = [('manual', bool(cfg.get('share_manual_decisions', False))), ('custom', bool(cfg.get('share_custom', True))),
                ('tainted', bool(cfg.get('share_tainted', True))), ('context', bool(cfg.get('share_context', False)))]
        if self.output == 'json':
            out(gojson({'console': {'authenticated': mode == 'ok', 'decision_management': False, 'enrolled': False, 'plan': '', 'registered': reg},
                        'sharing_options': {k: v for k, v in sorted(opts)}}, 2))
            return
        if self.output == 'raw':
            out(csv_line(['option', 'enabled']))
            for k, v in opts:
                out(csv_line([k, 'true' if v else 'false']))
            return
        msg = "\u274c not enrolled, see 'cscli console enroll'" if reg else "\u274c not registered, see 'cscli capi register'"
        out('+--------------------+----------------------------------------------+')
        out('| Console connection |                                              |')
        out('+--------------------+----------------------------------------------+')
        out('| Central API (CAPI) | %s |' % (msg + ' ' * (44 - _cell_w(msg))))
        out('+--------------------+----------------------------------------------+')
        desc = {'custom': 'Forward alerts from custom scenarios to the console', 'manual': 'Forward manual decisions to the console',
                'tainted': 'Forward alerts from tainted scenarios to the console', 'context': 'Forward context with alerts to the console'}
        out(table_classic(['Option Name', 'Activated', 'Description'],
                          [[k, '✅' if dict(opts)[k] else '❌', desc[k]] for k in ('custom', 'manual', 'tainted', 'context')], hdr_left=True))


# ==================================================================================================
# cscli: hub (collections/scenarios/parsers/... install, remove, upgrade, list), hub update/upgrade
# ==================================================================================================
def _plan_sets(hub, typ, names, mode):
    """-> (download {type: {name: 'v' | 'old -> new'}}, enable {type: set}, disable {type: set}) for the requested items"""
    download, enable, disable = {}, {}, {}
    if mode in ('install', 'upgrade'):
        for n in names:
            for t2, members in hub.closure(typ, n).items():
                for m in members:
                    e = hub.entry(t2, m)
                    latest = hub.latest(t2, m)
                    if e is None:
                        download.setdefault(t2, {})[m] = latest
                    elif mode == 'upgrade' and vkey(e['v']) < vkey(latest):
                        download.setdefault(t2, {})[m] = '%s -> %s' % (e['v'], latest)
                    if mode == 'install' and not (e and e['on']):
                        enable.setdefault(t2, set()).add(m)
    return download, enable, disable


def _apply_each(hub, typ, names):
    """[(name, [(type, item), ...])]: a plan is applied one requested item at a time, each with its contents first (see Hub.dfs);
    what an earlier request already covered is not visited again"""
    seen = set()
    return [(n, hub.dfs(typ, n, seen, [])) for n in names]


def _remove_set(hub, typ, names, downloaded=False):
    """items to disable (or, with `downloaded`, to purge from the hub directory) when removing `names`, each one on its own against
    the installed state before the plan. A collection takes its contents along unless another installed collection outside the
    removal still lists them directly - which is why removing everything at once (`--all`) leaves the items two removed
    collections share, while removing `exchange` alone also removes `windows-bf`, listed by exchange and by its own
    sub-collection windows."""
    res = {}

    def here(t, n):
        e = hub.entry(t, n)
        return e is not None if downloaded else bool(e and e['on'])

    def parents(t, n):
        return set(c for c in hub.enabled_collections() if n in hub.members('collections', c).get(t, ()))
    for n in names:
        if not here(typ, n):
            continue
        if typ != 'collections':
            res.setdefault(typ, set()).add(n)
            continue
        gone = {n}                                    # the collections that go: n, and sub-collections nobody outside still lists
        grown = True
        while grown:
            grown = False
            for c in sorted(gone):
                for sub in hub.members('collections', c).get('collections', ()):
                    if sub not in gone and here('collections', sub) and parents('collections', sub) <= gone:
                        gone.add(sub)
                        grown = True
        res.setdefault('collections', set()).update(gone)
        for c in gone:
            for t2, ms in hub.members('collections', c).items():
                if t2 != 'collections':
                    res.setdefault(t2, set()).update(m for m in ms if here(t2, m) and parents(t2, m) <= gone)
    return {t: v for t, v in res.items() if v}


def _fmt_plan(kind_title, groups, versions=None):
    lines = [kind_title]
    for t in PLAN_ORDER:
        if t in groups and groups[t]:
            if versions is not None:
                items = ', '.join('%s (%s)' % (n, versions[t][n]) for n in sorted(groups[t]))
            else:
                items = ', '.join(sorted(groups[t]))
            lines.append(' %s: %s' % (t, items))
    return '\n'.join(lines)


def _yaml_scalar(v):
    """a string the way Go's yaml.v3 writes it: plain when that reads back as the same string, single quoted when the text has
    YAML syntax in it, double quoted when a plain scalar would turn into a number, boolean or null"""
    if v == '':
        return "''"
    if '\n' in v or any(ord(c) < 32 for c in v):
        return json.dumps(v, ensure_ascii=False)
    low = v.lower()
    if (re.match(r'^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$', v) or re.match(r'^0(x[0-9a-fA-F]+|o[0-7]+)$', v)
            or re.match(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}([Tt ].*)?$', v) or re.match(r'^[0-9]+(:[0-5]?[0-9])+(\.[0-9]*)?$', v)
            or low in ('true', 'false', 'null', '~', 'y', 'n', 'yes', 'no', 'on', 'off', '.inf', '-.inf', '+.inf', '.nan')):
        return '"%s"' % v
    first = v[0]
    if (first in ',[]{}#&*!|>\'"%@`' or (first in '-?:' and (len(v) == 1 or v[1] == ' ')) or v[-1] == ' ' or first == ' '
            or ': ' in v or ' #' in v or v[-1] == ':'):
        return "'%s'" % v.replace("'", "''")
    return v


def _inspect_yaml(o):
    """`cscli <type> inspect NAME` (human and raw): the item as YAML"""
    L = []

    def scalar(k, v):
        L.append('%s: %s' % (k, _yaml_scalar(v) if isinstance(v, str) else ('true' if v else 'false')))
    for k in ('type', 'stage', 'name', 'file_name', 'description'):
        if k in o:
            scalar(k, o[k])
    if 'references' in o:
        L.append('references:')
        L.extend('  - ' + _yaml_scalar(r) for r in o['references'])
    scalar('path', o['path'])
    scalar('version', o['version'])
    deps = [(t2, o[t2]) for t2 in ITEM_ORDER if t2 in o]
    if deps:
        L.append('dependencies:')
        for t2, names in deps:
            L.append('  %s:' % t2)
            L.extend('    - ' + _yaml_scalar(m) for m in names)
    else:
        L.append('dependencies: {}')
    if 'local_path' in o:
        scalar('local_path', o['local_path'])
    if 'local_version' in o:
        scalar('local_version', o['local_version'])
        scalar('local_hash', o['local_hash'])
    L.append('downloadpath: %s' % (_yaml_scalar('/etc/crowdsec/hub/' + o['path']) if o['downloaded'] else '""'))
    scalar('up_to_date', o['up_to_date'])
    scalar('tainted', o['tainted'])
    if o.get('belongs_to_collections'):
        L.append('belongs_to_collections:')
        L.extend('  - ' + _yaml_scalar(c) for c in o['belongs_to_collections'])
    scalar('installed', o['installed'])
    scalar('local', o['local'])
    return '\n'.join(L) + '\n'


class HubCmds(object):
    def hub_item_cmd(self):
        typ, verb = self.path
        hub = Hub(self.st)
        getattr(self, '_hub_' + verb)(hub, typ)

    def _items_json(self, typ, items):
        outn(gojson({typ: items}, 1))

    def _hub_list(self, hub, typ):
        names = self.args
        if names:
            missing = [n for n in names if not hub.known(typ, n)]
            if missing:
                self.fatal("item(s) '%s' not found in %s" % (', '.join(missing), typ))
            sel = names
        else:
            sel = hub.names(typ, self.fl.get('all'))
        items = [hub.item(typ, n) for n in sel]
        if self.output == 'json':
            self._items_json(typ, items)
        elif self.output == 'raw':
            out(csv_line(['name', 'status', 'version', 'description']))
            for it in items:
                out(csv_line([it['name'], it['status'], it['local_version'], it['description']]))
        else:
            rows = [[it['name'], it['utf8_status'], it['local_version'], it['local_path']] for it in items]
            out(table_modern(['Name', '\U0001f4e6 Status', 'Version', 'Local Path'], rows, typ.upper()))

    def _print_plan(self, download, enable, disable, purge=None):
        """the `Action plan:` block (human mode only)"""
        if self.human():
            out('Action plan:')
            if download:
                out(_fmt_plan('\U0001f4e5 download', download, download))
            if enable:
                out(_fmt_plan('✅ enable', enable))
            if disable:
                out(_fmt_plan('❌ disable', disable))
            if purge:
                out(_fmt_plan('\U0001f5d1 purge (delete source)', purge))

    def _hub_install(self, hub, typ):
        fl = self.fl
        names = self.args
        missing = [n for n in names if not hub.known(typ, n)]
        err_lines = []
        for n in missing:
            sug = hub.suggest(typ, n)
            err_lines.append("can't find '%s' in %s%s" % (n, typ, (", did you mean '%s'?" % sug) if sug else ''))
        if missing and not fl.get('ignore'):
            self.fatal(err_lines[0])
        for ln in err_lines:
            self.log('error', ln)
        names = [n for n in names if n not in missing]
        download, enable, _d = _plan_sets(hub, typ, names, 'install')
        if fl.get('download-only'):
            enable = {}
        if not download and not enable:
            out('Nothing to install or remove.')
        else:
            if not ver_ge(self.st, 1, 7):
                return self._old_install(hub, typ, names, download, enable, fl.get('dry-run'))
            self._print_plan(download, enable, {})
            if self.human():
                out('')
            if fl.get('dry-run'):
                out('Dry run, no action taken.')
                return
            for _n, order in _apply_each(hub, typ, names):
                for t, n in order:
                    if n in download.get(t, {}):
                        out('downloading %s:%s' % (t, n))
                        hub.set_item(t, n, False, hub.latest(t, n))
                for t, n in order:
                    if n in enable.get(t, ()):
                        out('enabling %s:%s' % (t, n))
                        hub.set_item(t, n, True)
            self.run.touch()
        if missing and fl.get('ignore'):
            self.log('error', '<nil>')

    def _old_install(self, hub, typ, names, download, enable, dry):
        """cscli < 1.7: no action plan, one info line per step and a reload reminder"""
        if dry:
            return
        for _n, order in _apply_each(hub, typ, names):
            for t, n in order:
                if n in download.get(t, {}):
                    self.log('info', '%s : OK' % n)
                    hub.set_item(t, n, False, hub.latest(t, n))
            for t, n in order:
                if n in enable.get(t, ()):
                    self.log('info', 'Enabled %s : %s' % (t, n) if t != typ or n not in names else 'Enabled %s' % n)
                    hub.set_item(t, n, True)
        self.log('info', "Run 'systemctl reload crowdsec' for the new configuration to be effective.")
        self.run.touch()

    def _hub_delete(self, hub, typ):
        fl = self.fl
        names = list(self.args)
        if fl.get('all'):
            names = [n for n in hub.names(typ, False)]
        elif not names:
            self.fatal("specify at least one %s to remove or '--all'" % typ[:-1])
        for n in names:
            if not hub.known(typ, n):
                self.fatal("can't find '%s' in %s" % (n, typ))
        force, purge = fl.get('force'), fl.get('purge')
        disable, purged = {}, {}
        plans = []                                    # (requested item, what it disables, what it purges): every request is judged on its own
        for n in names:
            e = hub.entry(typ, n)
            installed = bool(e and e['on'])
            if not installed and not (purge and e is not None):
                continue
            owners = hub.belongs_to(typ, n)
            if installed and owners and not force and not fl.get('all'):
                self.log('warning', '%s belongs to collections: [%s]' % (n, ' '.join(owners)))
                self.log('warning', "Run 'sudo cscli %s remove %s --force' if you want to force remove this %s" % (typ, n, typ[:-1]))
                continue
            mine = _remove_set(hub, typ, [n]) if installed else {}
            gone = _remove_set(hub, typ, [n], downloaded=True) if purge else {}
            plans.append((n, mine, gone))
            for t2, s in mine.items():
                disable.setdefault(t2, set()).update(s)
            for t2, s in gone.items():
                purged.setdefault(t2, set()).update(s)
        if not disable and not purged:
            out('Nothing to install or remove.')
            return
        disabled, gone_now = [], []                   # in the order cscli applies them: contents first, request after request
        for n, mine, gone in plans:
            order = hub.dfs(typ, n, set(), [])
            disabled += [(t, m) for t, m in order if m in mine.get(t, ()) and (t, m) not in disabled]
            gone_now += [(t, m) for t, m in order if m in gone.get(t, ()) and (t, m) not in gone_now]
        if not ver_ge(self.st, 1, 7):
            for t, n in disabled:
                self.log('info', 'Removed %s' % n)
                hub.set_item(t, n, False)
            for t, n in gone_now:
                hub.h['items'][t].pop(n, None)
            self.log('info', "Run 'systemctl reload crowdsec' for the new configuration to be effective.")
            self.run.touch()
            return
        self._print_plan({}, {}, disable, purged)
        if self.human():
            out('')
        if fl.get('dry-run'):
            out('Dry run, no action taken.')
            return
        for t, n in disabled:
            out('disabling %s:%s' % (t, n))
            hub.set_item(t, n, False)
        for t, n in gone_now:
            out('purging %s:%s' % (t, n))
            hub.h['items'][t].pop(n, None)
        self.run.touch()

    def _hub_upgrade(self, hub, typ):
        fl = self.fl
        names = list(self.args)
        if fl.get('all'):
            names = [n for n in hub.h['items'].get(typ, {})]
        elif not names:
            self.fatal("specify at least one %s to upgrade or '--all'" % typ[:-1])
        for n in names:
            if not hub.known(typ, n):
                self.fatal("can't find '%s' in %s" % (n, typ))
        download, _e, _d = _plan_sets(hub, typ, names, 'upgrade')
        if not download:
            out('Nothing to install or remove.')
            return
        self._print_plan(download, {}, {})
        if self.human():
            out('')
        if fl.get('dry-run'):
            out('Dry run, no action taken.')
            return
        for _n, order in _apply_each(hub, typ, names):
            for t, n in order:
                if n in download.get(t, {}):
                    out('downloading %s:%s' % (t, n))
                    e = hub.entry(t, n)
                    if e is None:
                        hub.set_item(t, n, False, hub.latest(t, n))
                    else:
                        e['v'] = hub.latest(t, n)
        self.run.touch()

    def _hub_inspect(self, hub, typ):
        """`cscli <type> inspect NAME...`: each item is printed as soon as it is found, so a missing name fails after the ones before it"""
        for n in self.args:
            if not hub.known(typ, n):
                self.fatal("can't find '%s' in %s" % (n, typ))
            o = self._inspect_obj(hub, typ, n)
            if self.output == 'json':
                out(gojson(o, 2))
                continue
            out(_inspect_yaml(o).rstrip('\n'))
            if self.human() and o['installed']:
                out('\nCurrent metrics: ')

    @staticmethod
    def _inspect_obj(hub, typ, n):
        """the item as `inspect -o json` prints it (key order of the Go struct; empty values left out)"""
        e = hub.entry(typ, n)
        ex = hub.extra(typ, n)
        fname = hub.local_path(typ, n).rsplit('/', 1)[1]
        o = {'type': typ}
        if typ in STAGE_TYPES:
            o['stage'] = ex.get('s', 's01-parse')
        o['name'] = n
        o['file_name'] = fname
        if hub.desc(typ, n):
            o['description'] = hub.desc(typ, n)
        if ex.get('r'):
            o['references'] = ex['r']
        o['path'] = '%s/%s/%s' % (typ, n.split('/')[0], fname) if typ not in STAGE_TYPES else '%s/%s/%s/%s' % (typ, ex.get('s', 's01-parse'), n.split('/')[0], fname)
        o['version'] = hub.latest(typ, n)
        o['versions'] = hub.versions(typ, n)
        mem = hub.members(typ, n)
        for t2 in ITEM_ORDER:
            if mem.get(t2):
                o[t2] = mem[t2]
        if e:
            if e['on']:
                o['local_path'] = hub.local_path(typ, n)
            o['local_version'] = e['v']
            o['local_hash'] = hub.digest(typ, n, e['v'])
        o['installed'] = bool(e and e['on'])
        o['downloaded'] = e is not None
        o['up_to_date'] = e is not None and not hub.outdated(typ, n)
        o['tainted'] = False
        o['local'] = False
        parents = hub.parents(typ, n)
        if parents:
            o['belongs_to_collections'] = parents
        return o

    # -- cscli hub ---------------------------------------------------------------------------------
    def c_hub_update(self):
        hub = Hub(self.st)
        if hub.h.get('fresh'):
            if self.human():
                out('Nothing to do, the hub index is up to date.')
            return
        hub.h['fresh'] = True
        self.run.touch()
        if self.human():
            out('Downloading /etc/crowdsec/hub/.index.json')
            cols = sorted(hub.enabled_collections())
            for c in cols:                                   # a collection is behind when one of its items is
                m = hub.outdated_member(c)
                if m:
                    err('%s is outdated because of %s:%s' % (c, m[0], m[1]))
            for c in cols:                                   # ... or when it has a newer version of its own
                e = hub.entry('collections', c)
                if vkey(e['v']) < vkey(hub.latest('collections', c)):
                    err('update for collection %s available (currently:%s, latest:%s)' % (c, e['v'], hub.latest('collections', c)))

    def c_hub_upgrade(self):
        hub = Hub(self.st)
        download = {}
        for t in ITEM_ORDER:
            for n, e in sorted(hub.h['items'].get(t, {}).items(), key=lambda kv: kv[0].lower()):
                if hub.known(t, n) and vkey(e['v']) < vkey(hub.latest(t, n)):
                    download.setdefault(t, {})[n] = '%s -> %s' % (e['v'], hub.latest(t, n))
        if self.human():
            out('Action plan:')
            if download:
                out(_fmt_plan('\U0001f4e5 download', download, download))
            out('\U0001f504 check & update data files')
            out('')
        if self.fl.get('dry-run'):
            out('Dry run, no action taken.')
            return
        for t in ITEM_ORDER:
            for n in sorted(download.get(t, {}), key=str.lower):
                out('downloading %s:%s' % (t, n))
                hub.h['items'][t][n]['v'] = hub.latest(t, n)
        if download:
            self.run.touch()

    def c_hub_list(self):
        hub = Hub(self.st)
        all_ = self.fl.get('all')
        cat = hub.cat
        err('Loaded: %d parsers, %d postoverflows, %d scenarios, %d contexts, %d appsec-configs, %d appsec-rules, %d collections' % (
            len(cat['parsers']), len(cat['postoverflows']), len(cat['scenarios']), len(cat['contexts']), len(cat['appsec-configs']),
            len(cat['appsec-rules']), len(cat['collections'])))
        if self.output == 'json':
            outn(gojson({t: [hub.item(t, n) for n in hub.names(t, all_)] for t in HUB_ORDER}, 1))
            return
        if self.output == 'raw':
            out(csv_line(['name', 'status', 'version', 'description', 'type']))
            for t in ITEM_ORDER:
                for n in hub.names(t, all_):
                    it = hub.item(t, n)
                    out(csv_line([n, it['status'], it['local_version'], it['description'], t]))
            return
        rows = self._hub_rows_all(hub) if all_ else self._hub_rows_tree(hub)
        if not rows:
            out('No items to display')
            return
        out(table_modern(['Type', 'Name', '\U0001f4e6 Status', 'Version', 'Details'], rows))

    @staticmethod
    def _hub_row(hub, typ, name, label=None):
        """[Type, Name, Status, Version, Details] of the human `hub list`"""
        e = hub.entry(typ, name)
        on = bool(e and e['on'])
        if not on:
            status, ver, det = '\U0001f6ab  not-installed', '', ''
        elif hub.outdated(typ, name):
            status, ver, det = '⚠️  outdated', e['v'], '%s \u2192 %s' % (e['v'], hub.latest(typ, name))
        else:
            status, ver, det = '✔️  up-to-date', e['v'], ''
        if typ == 'collections':
            mem = hub.members(typ, name)
            summary = ' / '.join('%d %s(s)' % (len(mem[t]), t[:-1]) for t in ITEM_ORDER if mem.get(t))
            det = '%s \u00b7 %s' % (det, summary) if det and summary else det or summary
        return [typ, label or name, status, ver, det]

    def _hub_rows_all(self, hub):
        """hub list -a: every item of the index, one flat table (types in load order, names without regard to case)"""
        return [self._hub_row(hub, t, n) for t in ITEM_ORDER for n in sorted(hub.names(t, True), key=str.lower)]

    def _hub_rows_tree(self, hub):
        """hub list: the installed collections as a tree (an item shows up once, under the first collection that has it), then
        the installed items that no installed collection accounts for"""
        installed = set(hub.names('collections'))
        kids = {c: [k for k in hub.members('collections', c).get('collections', []) if k in installed] for c in installed}
        below = set(k for ks in kids.values() for k in ks)
        seen = set()

        def build(c):
            seen.add(c)
            return (c, [build(k) for k in kids[c] if k not in seen])       # `seen` is updated while the list is built: depth first
        forest = [build(c) for c in sorted((c for c in installed if c not in below), key=str.lower)]
        rows = []

        def walk(node, indent, last, root):
            name, sub = node
            label = name if root else indent + ('\u2514\u2500 ' if last else '\u251c\u2500 ') + name
            rows.append(self._hub_row(hub, 'collections', name, label))
            child_indent = '' if root else indent + ('   ' if last else '\u2502  ')
            for i, s in enumerate(sub):
                walk(s, child_indent, i == len(sub) - 1, False)
        for tree in forest:
            walk(tree, '', True, True)
        covered = set()
        for c in installed:
            for t2, ms in hub.members('collections', c).items():
                covered.update((t2, m) for m in ms)
        rest = [self._hub_row(hub, t, n) for t in ITEM_ORDER if t != 'collections'
                for n in sorted(hub.names(t), key=str.lower) if (t, n) not in covered]
        return rows + ([None] if rows and rest else []) + rest

    def c_hub_types(self):
        for t in ITEM_ORDER:
            out('- ' + t)

    def c_hub_branch(self):
        out('master')


# ==================================================================================================
# cscli: simulation
# ==================================================================================================
class SimulationCmds(object):
    def _sim_read(self):
        text = self.run.fs().read(self.conf['simulation_path'])
        g, excl = False, []
        if text:
            try:
                doc = yaml_load(text)
            except YamlError:
                doc = None
            if isinstance(doc, dict):
                g = bool(doc.get('simulation', False))
                excl = [str(x) for x in (doc.get('exclusions') or [])]
        return g, excl

    def _sim_write(self, g, excl):
        self.run.fs().write(self.conf['simulation_path'], simulation_yaml(g, excl))
        self.run.touch()

    def c_simulation_status(self):
        g, excl = self._sim_read()
        out('global simulation: %s' % ('enabled' if g else 'disabled'))
        if excl:
            out('')
            out('Scenarios not in simulation mode:' if g else 'Scenarios in simulation mode:')
            for e in excl:
                out('  - %s' % e)

    def c_simulation_enable(self):
        g, excl = self._sim_read()
        if self.fl.get('global'):
            self._sim_write(True, [])
            out('global simulation: enabled')
            return
        if not self.args:
            out('Enable the simulation, globally or on specified scenarios\n\nUsage:\n  cscli simulation enable [scenario] [-global] [flags]')
            return
        hub = Hub(self.st)
        for s in self.args:
            if g:
                if s in excl:
                    i = excl.index(s)
                    excl[i] = excl[-1]
                    excl.pop()
                    out('simulation mode for "%s" enabled' % s)
                else:
                    out('global simulation is already enabled')
                continue
            if not hub.known('scenarios', s):
                self.log('error', '"%s" does not exist or is not a scenario' % s)
                continue
            if not (hub.entry('scenarios', s) or {}).get('on'):
                self.log('warning', 'Scenario "%s" is not installed' % s)
            if s in excl:
                out('simulation for "%s" is already enabled' % s)
                continue
            excl.append(s)
            out('simulation mode for "%s" enabled' % s)
        self._sim_write(g, excl)

    def c_simulation_disable(self):
        g, excl = self._sim_read()
        if self.fl.get('global'):
            self._sim_write(False, [])
            if not self.args:
                out('global simulation: disabled')
            g, excl = False, []
        elif not self.args:
            out('Disable the simulation mode. Disable only specified scenarios\n\nUsage:\n  cscli simulation disable [scenario] [flags]')
            return
        for s in self.args:
            if g:
                if s in excl:
                    self.log('warning', 'simulation mode is enabled but is already disable for "%s"' % s)
                else:
                    excl.append(s)
                    out('simulation mode for "%s" disabled' % s)
            elif s in excl:
                i = excl.index(s)
                excl[i] = excl[-1]
                excl.pop()
                out('simulation mode for "%s" disabled' % s)
            else:
                self.log('warning', "%s isn't in simulation mode" % s)
        if self.args:
            self._sim_write(g, excl)


# ==================================================================================================
# cscli: notifications
# ==================================================================================================
_NOTIF_ORDER = ('http_default', 'sentinel_default', 'slack_default', 'splunk_default', 'email_default', 'file_default')


class NotificationCmds(object):
    def _profile_refs(self):
        """{plugin: [profile names]} from the live profiles.yaml (best effort)"""
        refs = {}
        try:
            docs = yaml_load_all(self.run.fs().read(self.conf['profiles_path']) or '')
        except YamlError:
            return refs
        for d in docs:
            if isinstance(d, dict):
                for nt in (d.get('notifications') or []):
                    refs.setdefault(str(nt), []).append(str(d.get('name', '')))
        return refs

    def _plugins_sorted(self):
        pl = plugin_configs(self.run.fs(), self.conf)
        names = [n for n in _NOTIF_ORDER if n in pl] + sorted(n for n in pl if n not in _NOTIF_ORDER)
        return pl, names

    def c_notifications_list(self):
        pl, names = self._plugins_sorted()
        refs = self._profile_refs()
        if self.output == 'json':
            self.fatal('failed to serialize notification configuration: json: unsupported type: map[interface {}]interface {}')
        if self.output == 'raw':
            out(csv_line(['Name', 'Type', 'Profile name']))
            for n in names:
                out(csv_line([n, pl[n][0], ', '.join(refs.get(n, []))]))
            return
        rows = []
        for n in names:
            prof = ', '.join(refs.get(n, []))
            rows.append((n, pl[n][0], prof, bool(prof)))
        w_name = max([len('Name')] + [len(r[0]) for r in rows])
        w_type = max([len('Type')] + [len(r[1]) for r in rows])
        w_prof = max([len('Profile name')] + [len(r[2]) for r in rows])
        total = 1 + 6 + 2 + w_name + 2 + w_type + 2 + w_prof + 1
        out('-' * total)
        out(' Active  %s  %s  %s ' % (pad('Name', w_name), pad('Type', w_type), pad('Profile name', w_prof)))
        out('-' * total)
        for n, t, prof, act in rows:
            mark = '\u2714\ufe0f' if act else '\U0001f6ab'
            out(' %s  %s  %s  %s ' % (mark + ' ' * (6 - _cell_w(mark)), pad(n, w_name), pad(t, w_type), pad(prof, w_prof)))
        out('-' * total)

    def c_notifications_inspect(self):
        pl, _names = self._plugins_sorted()
        name = self.args[0]
        if name not in pl:
            self.fatal("plugin '%s' does not exist or is not active" % name)
        _t, _f, cfg = pl[name]
        first = ['type', 'name', 'timeout', 'format']
        for k in first:
            v = cfg.get(k, '5s' if k == 'timeout' else '')
            out(' - %s: %s' % (k.capitalize().rjust(15), str(v).rstrip('\n').rjust(15) if k != 'format' else str(v).rstrip('\n')))
        out('')
        for k, v in cfg.items():
            if k not in first and not isinstance(v, (dict, list)):
                out(' - %s: %s' % (str(k).rjust(15), str(v).rjust(15)))

    def c_notifications_test(self):
        name = self.args[0]
        pl, _names = self._plugins_sorted()
        if name not in pl:
            self.fatal("plugin name: '%s' does not exist" % name)
        typ, _fpath, cfg = pl[name]
        rng = self.db.rng
        pid = rng.randint(800, 60000)
        path = '/usr/local/lib/crowdsec/plugins/notification-%s' % typ
        errn('\n'.join([
            logline_plain('debug', 'starting plugin', args='[%s]' % path, module='plugin', path=path),
            logline_plain('debug', 'plugin started', module='plugin', path=path, pid=pid),
            logline_plain('debug', 'waiting for RPC address', module='plugin', plugin=path),
            logline_plain('debug', 'using plugin', module='plugin', version=1),
            logline_plain('trace', 'waiting for stdio data', module='plugin'),
            logline_plain('info', 'registered plugin %s' % name),
            logline_plain('info', 'pluginTomb dying')]) + '\n')
        if typ == 'http':
            self._notify_http(name, cfg, pid)
        errn('\n'.join([
            logline_plain('info', 'killing all plugins'),
            logline_plain('debug', 'received EOF, stopping recv loop', err='rpc error: code = Unavailable desc = error reading from server: EOF', module='plugin'),
            logline_plain('info', 'plugin process exited', id=pid, module='plugin', plugin=path),
            logline_plain('debug', 'plugin exited', module='plugin')]) + '\n')

    def _notify_http(self, name, cfg, pid):
        fmt = str(cfg.get('format') or '')
        e = tmpl_check(fmt)
        if e:
            errn(logline_plain('error', 'format alerts for notification: %s' % e) + ' plugin:=%s\n' % name)
            return
        url = str(cfg.get('url') or '')
        debug = str(cfg.get('log_level', 'info')).lower() == 'debug'
        method = str(cfg.get('method') or 'POST').upper()
        retries = cfg.get('max_retry')
        retries = int(retries) if isinstance(retries, int) else 3
        mod = {'@module': 'http-plugin', 'module': 'plugin'}
        m = re.match(r'^(https?)://([^/:@]+|\[[^\]]+\])(?::(\d+))?(/.*)?$', url)
        if not m:
            result = ('scheme', None)
        elif m.group(2) in ('127.0.0.1', 'localhost', '[::1]'):
            port = int(m.group(3) or (443 if m.group(1) == 'https' else 80))
            result = self._probe_local(m, port, cfg)
        else:
            return               # never talk to the network
        errline = None
        if result[0] == 'scheme':
            errline = 'Post "%s": unsupported protocol scheme "%s"' % (url, url.split(':')[0] if ':' in url and '//' in url else '')
        elif result[0] == 'refused':
            errline = 'Post "%s": dial tcp %s:%s: connect: connection refused' % (url, m.group(2), m.group(3) or '80')
        body = '{"alert":"mock"}'
        for attempt in range(retries + 1):
            errn(logline_plain('info', 'received signal for %s config' % name, **mod) + '\n')
            if debug:
                for hk, hv in (cfg.get('headers') or {}).items() if isinstance(cfg.get('headers'), dict) else []:
                    errn(logline_plain('debug', 'adding header %s: %s' % (hk, hv), **mod) + '\n')
                errn(logline_plain('debug', 'making HTTP %s call to %s with body %s' % (method, url, body), **mod) + '\n')
            if errline:
                errn(logline_plain('error', 'Failed to make HTTP request : ' + errline, **mod) + '\n')
                desc = 'rpc error: code = Unknown desc = ' + errline
                if attempt < retries:
                    nxt = go_dur_frac((1 << attempt) + ((pid * 7919 * (attempt + 3)) % 1000000000) / 1e9 / 4)
                    errn(logline_plain('warning', 'notify attempt failed: ' + desc, attempt=attempt + 1, next=nxt, plugin=name) + '\n')
                    continue
                errn(logline_plain('error', 'delivery failed after retries: ' + desc, plugin=name) + '\n')
                errn(logline_plain('error', desc) + ' plugin:=%s\n' % name)
                return
            code, text = result[1], result[2]
            if debug:
                errn(logline_plain('debug', 'got response %s' % text, **mod) + '\n')
            if code and not (200 <= code < 300):
                errn(logline_plain('warning', 'HTTP server returned non 200 status code: %d' % code, **mod) + '\n')
                if debug:
                    errn(logline_plain('debug', 'HTTP server returned body: %s' % text, **mod) + '\n')
            return

    def _probe_local(self, m, port, cfg):
        """the only network I/O this mock ever does: a POST to a loopback URL from the plugin config"""
        import socket
        host = m.group(2).strip('[]')
        try:
            s = socket.create_connection((host, port), timeout=3)
            s.close()
        except (OSError, socket.timeout):
            return ('refused', None, '')
        try:
            import urllib.request
            import urllib.error
            req = urllib.request.Request(m.group(0), data=b'{"mock":"crowdsec notifications test"}', method=str(cfg.get('method') or 'POST').upper(),
                                         headers={'Content-Type': 'application/json'})
            try:
                with urllib.request.urlopen(req, timeout=3) as r:
                    return ('ok', r.status, r.read(300).decode('utf-8', 'replace'))
            except urllib.error.HTTPError as e:
                return ('ok', e.code, e.read(300).decode('utf-8', 'replace'))
        except Exception:
            return ('refused', None, '')


def logline_plain(level, msg, **kv):
    """a cscli/plugin log line without the time field: level=info msg="..." key=value (keys sorted)"""
    parts = ['level=%s' % level, 'msg=%s' % _q(msg)]
    for k in sorted(kv):
        v = str(kv[k])
        parts.append('%s=%s' % (k, _q(v) if re.search(r'[\s"=\[\]]', v) or v == '' else v))
    return ' '.join(parts)


class ConfigCmds(object):
    """cscli config show / show-yaml"""

    def c_config_show(self):
        key = self.fl.get('key')
        vals = {'Config.API.Server.ListenURI': '0.0.0.0:8080', 'Config.ConfigPaths.ConfigDir': '/etc/crowdsec/',
                'Config.ConfigPaths.DataDir': '/var/lib/crowdsec/data/', 'Config.API.Server.ProfilesPath': self.conf['profiles_path'],
                'Config.ConfigPaths.NotificationDir': self.conf['notification_dir']}
        if key in vals:
            out(vals[key])
            return
        if not key and self.output == 'human':
            return self._config_show_human()
        unsupported(self.run, ['exec', 'CrowdSec', 'cscli', 'config', 'show'] + (['--key', key] if key else []) + (['-o', self.output] if self.output != 'human' else []))

    def c_config_show_yaml(self):
        out(self.run.fs().read(self.conf['path']) or '')       # Println of text that already ends in a newline

    def _config_show_human(self):
        """the fixed summary of the effective configuration (values from the config file, image defaults elsewhere)"""
        doc = yaml_load(self.run.fs().read(self.conf['path']) or '') or {}

        def g(dotted, default=''):
            cur = doc
            for part in dotted.split('.'):
                if not isinstance(cur, dict) or part not in cur:
                    return default
                cur = cur[part]
            return default if cur is None else cur

        def line(indent, label, value):
            return '%s- %s: %s' % (indent, label.ljust(28 - len(indent) - 2), value)

        def folder(v):
            return str(v).rstrip('/') or '/'
        creds = yaml_load(self.run.fs().read(str(g('api.client.credentials_path', '/etc/crowdsec/local_api_credentials.yaml'))) or '') or {}
        age = parse_dur(str(g('db_config.flush.max_age', '7d')))[0]
        rows = ['Global:',
                line('   ', 'Configuration Folder', folder(g('config_paths.config_dir', '/etc/crowdsec'))),
                line('   ', 'Data Folder', folder(g('config_paths.data_dir', '/var/lib/crowdsec/data'))),
                line('   ', 'Hub Folder', folder(g('config_paths.hub_dir', '/etc/crowdsec/hub'))),
                line('   ', 'Notification Folder', folder(g('config_paths.notification_dir', '/etc/crowdsec/notifications'))),
                line('   ', 'Simulation File', g('config_paths.simulation_path', '/etc/crowdsec/simulation.yaml')),
                line('   ', 'Log Folder', folder(g('common.log_dir', '/var/log'))),
                line('   ', 'Log level', g('common.log_level', 'info')),
                line('   ', 'Log Media', g('common.log_media', 'stdout')),
                'Crowdsec:',
                line('  ', 'Acquisition File', g('crowdsec_service.acquisition_path', '/etc/crowdsec/acquis.yaml')),
                line('  ', 'Parsers routines', g('crowdsec_service.parser_routines', 1)),
                line('  ', 'Acquisition Folder', g('crowdsec_service.acquisition_dir', '')),
                'cscli:',
                line('  ', 'Output', self.output),
                line('  ', 'Hub Branch', ''),
                'API Client:',
                line('  ', 'URL', (creds.get('url', 'http://0.0.0.0:8080').rstrip('/') + '/') if isinstance(creds, dict) else ''),
                line('  ', 'Login', creds.get('login', 'localhost') if isinstance(creds, dict) else ''),
                line('  ', 'Credentials File', g('api.client.credentials_path', '/etc/crowdsec/local_api_credentials.yaml')),
                'Local API Server:',
                line('  ', 'Listen URL', g('api.server.listen_uri', '127.0.0.1:8080')),
                line('  ', 'Listen Socket', g('api.server.listen_socket', '')),
                line('  ', 'Profile File', g('api.server.profiles_path', '/etc/crowdsec/profiles.yaml')),
                '',
                '  - Trusted IPs:']
        rows += ['      - %s' % ip for ip in (g('api.server.trusted_ips', []) or [])]
        rows += ['  - Database:',
                 line('      ', 'Type', g('db_config.type', 'sqlite')),
                 line('      ', 'Path', g('db_config.db_path', '/var/lib/crowdsec/data/crowdsec.db')),
                 line('      ', 'Flush age', go_dur(age) if age is not None else ''),
                 line('      ', 'Flush size', g('db_config.flush.max_items', 5000))]
        out('\n'.join(rows))


# ==================================================================================================
# `crowdsec -t [-c FILE]` inside the container
# ==================================================================================================
def crowdsec_main(run, argv):
    st = run.st
    fs = run.fs()
    cfg = '/etc/crowdsec/config.yaml'
    test = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ('-c', '-config'):
            i += 1
            cfg = argv[i] if i < len(argv) else cfg
        elif a in ('-t', '-test'):
            test = True
        elif a in ('-version', '--version', '-V'):
            outn(version_text(st))
            raise Exit(0)
        else:
            unsupported(run, ['exec', 'CrowdSec', 'crowdsec'] + argv)
        i += 1
    if not test:
        unsupported(run, ['exec', 'CrowdSec', 'crowdsec'] + argv)
    t = now()
    ver = 'v%s-%s' % (st['version'], _sha8(st['version']))

    def line(level, msg, **kv):
        errn(logline(t, level, msg, **kv) + '\n')
    conf = crowdsec_conf(fs, cfg)
    if not conf['ok']:
        line('fatal', 'while reading %s: open %s: no such file or directory' % (cfg, cfg))
        raise Exit(1)
    fatal = config_test(st, fs, conf)
    hub = Hub(st)
    if fatal is None or not fatal.startswith('while loading profiles'):
        line('info', 'Enabled feature flags: none')
        line('info', 'Crowdsec ' + ver)
    if fatal:
        if not fatal.startswith('while loading profiles') and not fatal.startswith('crowdsec init'):
            if st['knobs'].get('capi') in ('disabled', 'unregistered'):
                line('warning', 'Communication with CrowdSec Central API disabled from configuration file')
        line('fatal', fatal)
        raise Exit(1)
    line('info', 'gocron: new scheduler created', module='db')
    line('info', 'gocron: scheduler started', module='db')
    line('info', 'Loading grok library /etc/crowdsec/patterns')
    line('info', 'Loading enrich plugins')
    line('info', 'Loading parsers from %d files' % len(hub.names('parsers')))
    line('info', 'Loaded %d nodes from 3 stages' % (len(hub.names('parsers')) + 1))
    line('info', 'Loading postoverflow parsers')
    line('info', 'Loaded %d nodes from 2 stages' % len(hub.names('postoverflows')))
    line('info', 'Loading %d scenario files' % len(hub.names('scenarios')))
    line('info', 'Loaded %d scenarios' % (len(hub.names('scenarios')) + 6))
    files = [conf['acquisition_path']] + ['%s/%s' % (conf['acquisition_dir'].rstrip('/'), f) for f in (fs.listdir(conf['acquisition_dir']) or []) if f.endswith(('.yaml', '.yml'))]
    for f in files:
        txt = fs.read(f)
        if txt is None:
            continue
        line('info', 'loading acquisition file : %s' % f)
        for doc in yaml_load_all(txt):
            if not isinstance(doc, dict):
                continue
            line('info', 'Configuring datasource', module='acquisition.file', type='file')
            pats = doc.get('filenames') or ([doc['filename']] if doc.get('filename') else [])
            for pat in pats:
                if not fs.exists(str(pat)):
                    line('warning', 'No matching files for pattern %s' % pat, module='acquisition.file', type='file')
    line('warning', 'serving metrics', error='listen tcp 0.0.0.0:6060: bind: address already in use')
    line('info', 'Configuration test done')


# ==================================================================================================
# entry point: control verbs, locking, state file
# ==================================================================================================
def state_path(fdir):
    return os.path.join(fdir, 'state.json')


def load_state(fdir):
    try:
        with open(state_path(fdir), 'r') as f:
            st = json.load(f)
    except (IOError, OSError, ValueError):
        return None
    if st.get('schema') != STATE_SCHEMA:
        fail('%s: %s was written by another version of the mock (schema %s, this is %s): run --mock-init again' % (
            PROG, state_path(fdir), st.get('schema'), STATE_SCHEMA), 2)
    CLOCK[0] = st.get('clock', 0.0)
    return st


def save_state(fdir, st):
    tmp = '%s.tmp.%d' % (state_path(fdir), os.getpid())
    with open(tmp, 'w') as f:
        json.dump(st, f, separators=(',', ':'), ensure_ascii=False)
    os.replace(tmp, state_path(fdir))


def log_call(fdir, argv):
    try:
        with open(os.path.join(fdir, 'calls.log'), 'a') as f:
            f.write('%.3f\t%s\n' % (time.time(), ' '.join(argv)))
    except (IOError, OSError):
        pass


KNOBS = ('docker_down', 'lapi_down', 'health', 'status', 'version', 'discord', 'traefik', 'health_delay', 'restart_fails', 'cscli_slow_ms',
         'empty_json', 'capi', 'hub_cascade')


def control(fdir, argv):
    verb = argv[0]
    if verb == '--mock-init':
        rest = argv[1:]
        if not rest:
            fail('%s: --mock-init needs a scenario (%s)' % (PROG, ' '.join(PRESETS)), 2)
        preset, traefik, version, seed = rest[0], False, DEFAULT_VERSION, 1
        i = 1
        while i < len(rest):
            a = rest[i]
            if a == '--traefik':
                traefik = True
            elif a in ('--version', '--seed'):
                i += 1
                if i >= len(rest):
                    fail('%s: %s needs a value' % (PROG, a), 2)
                if a == '--version':
                    version = rest[i]
                else:
                    seed = int(rest[i])
            else:
                fail('%s: unknown --mock-init option %s' % (PROG, a), 2)
            i += 1
        with open(os.path.join(fdir, '.lock'), 'a') as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            for name in ('calls.log', 'unsupported.log'):
                open(os.path.join(fdir, name), 'w').close()
            log_call(fdir, sys.argv[1:])
            st = build_preset(preset, version, seed, fdir, traefik)
            CLOCK[0] = 0.0
            init_rootfs(st)
            save_state(fdir, st)
        raise Exit(0)
    with open(os.path.join(fdir, '.lock'), 'a') as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        st = load_state(fdir)
        if st is None:
            fail('%s: no state in %s (run --mock-init first)' % (PROG, fdir), 2)
        if verb == '--mock-dump':
            out(json.dumps(st, indent=1, ensure_ascii=False))
            raise Exit(0)
        if verb == '--mock-tick':
            try:
                st['clock'] = st.get('clock', 0.0) + float(argv[1])
            except (IndexError, ValueError):
                fail('%s: --mock-tick needs a number of seconds' % PROG, 2)
            save_state(fdir, st)
            raise Exit(0)
        if verb == '--mock-set':
            for kv in argv[1:]:
                k, _, v = kv.partition('=')
                if k not in KNOBS or not _:
                    fail("%s: unknown knob '%s' (known: %s)" % (PROG, kv, ' '.join(KNOBS)), 2)
                set_knob(st, k, v)
            save_state(fdir, st)
            raise Exit(0)
        fail('%s: unknown control verb %s' % (PROG, verb), 2)


def set_knob(st, k, v):
    kn = st['knobs']
    c = st['containers'].get('CrowdSec')
    t = time.time() + st.get('clock', 0.0)
    if k in ('docker_down', 'restart_fails', 'health_delay', 'cscli_slow_ms', 'hub_cascade'):
        kn[k] = int(v)
    elif k == 'lapi_down':
        kn[k] = int(v) if v.isdigit() else {'real': 2, 'true': 1, 'false': 0}.get(v, 1)
    elif k == 'capi':
        if v not in ('ok', 'error', 'unregistered', 'disabled'):
            fail('%s: capi must be ok|error|unregistered|disabled' % PROG, 2)
        kn[k] = v
    elif k == 'empty_json':
        kn[k] = None if v in ('', 'auto') else v
    elif k == 'version':
        st['version'] = v
        if st.get('cs'):
            for m in st['cs']['machines']:
                m['version'] = machine_version(st)
    elif k == 'discord':
        kn[k] = int(v)
        if c is not None:
            apply_discord(st, bool(int(v)))
    elif k == 'traefik':
        if int(v) and 'Traefik' not in st['containers']:
            st['containers']['Traefik'] = make_traefik_container(st, t)
        elif not int(v):
            st['containers'].pop('Traefik', None)
        st['traefik'] = bool(int(v))
    elif k == 'health':
        if c is None:
            fail('%s: no CrowdSec container' % PROG, 2)
        if v == 'starting':
            c['health_forced'] = 'starting'
            c['health'] = c['health'] or 'healthy'
        elif v in ('healthy', 'unhealthy'):
            c['health_forced'] = None
            c['health'] = v
        else:
            fail('%s: health must be healthy|unhealthy|starting' % PROG, 2)
    elif k == 'status':
        if c is None:
            fail('%s: no CrowdSec container' % PROG, 2)
        if v == 'running':
            c.update({'status': 'running', 'exit_code': 0, 'started': t, 'health': c['health'] or 'healthy'})
        elif v == 'exited':
            c.update({'status': 'exited', 'exit_code': 137, 'finished': t})
        elif v == 'restarting':
            c.update({'status': 'restarting', 'exit_code': 1, 'restart_count': c['restart_count'] + 1, 'finished': t, 'started': t})
        else:
            fail('%s: status must be running|exited|restarting' % PROG, 2)


def main():
    for stream in (sys.stdout, sys.stderr, sys.stdin):
        try:
            stream.reconfigure(encoding='utf-8', errors='replace')          # emoji and the µ of Go durations, whatever the locale
        except (AttributeError, ValueError):
            pass
    argv = sys.argv[1:]
    fdir = os.environ.get('FAKE_CS_DIR')
    if not fdir:
        sys.stderr.write('%s: FAKE_CS_DIR is not set\n' % PROG)
        return 2
    fdir = os.path.abspath(fdir)
    os.makedirs(fdir, exist_ok=True)
    if argv and argv[0].startswith('--mock-'):
        if argv[0] != '--mock-init':
            log_call(fdir, argv)
        try:
            control(fdir, argv)
        except Exit as e:
            return e.code
        return 0
    log_call(fdir, argv)
    # cscli_slow_ms: sleep before taking the lock, so parallel calls overlap like slow real ones
    if 'cscli' in argv[:10]:
        pre = None
        try:
            with open(state_path(fdir)) as f:
                pre = json.load(f)
        except (IOError, OSError, ValueError):
            pass
        if pre and pre.get('knobs', {}).get('cscli_slow_ms'):
            time.sleep(pre['knobs']['cscli_slow_ms'] / 1000.0)
    rc = 0
    with open(os.path.join(fdir, '.lock'), 'a') as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        st = load_state(fdir)
        if st is None:
            st = build_preset('absent', DEFAULT_VERSION, 1, fdir, False)
            init_rootfs(st)
            CLOCK[0] = 0.0
        run = Run(st, fdir)
        try:
            docker_main(run, argv)
        except Exit as e:
            rc = e.code
        except BrokenPipeError:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())       # the reader went away (| head -1)
            rc = 141
        except Exception:                                                        # a bug in the mock: say so, keep the state
            import traceback
            sys.stdout.flush()
            sys.stderr.write('%s: internal error while running: %s\n' % (PROG, ' '.join(argv)))
            traceback.print_exc()
            rc = 70
            run.dirty = False
        if run.dirty:
            save_state(fdir, st)
    for fn in run.after:
        fn()
    try:
        sys.stdout.flush()
    except BrokenPipeError:
        pass
    return rc


class Cscli(CscliBase, DecisionCmds, AlertCmds, AllowlistCmds, BouncerCmds, MachineCmds, MetricsCmds, StatusCmds, HubCmds, SimulationCmds,
            NotificationCmds, ConfigCmds):
    """cscli, one mixin per area"""


def cscli_main(run, argv):
    Cscli(run).main(argv)


# ==================================================================================================
# the hub catalog: the index of a real cscli 1.8.1 (hub.crowdsec.net master), zlib+base64 of a compact JSON
# {type: [[name, version, description, {s: stage, f: file name, m: members}], ...]}
# ==================================================================================================
CATALOG_B64 = """
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
"""


if __name__ == '__main__':
    sys.exit(main())

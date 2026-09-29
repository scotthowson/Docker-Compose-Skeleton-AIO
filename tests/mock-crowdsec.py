#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mock-crowdsec.py - a stateful stand-in for the `docker` CLI plus `cscli` (CrowdSec 1.8.x).

WHY
    The DCS API (bash + jq) manages a CrowdSec container by shelling out to `docker exec CrowdSec cscli ...`.
    Its smoke tests and the browser lab need a fake `docker` on PATH that behaves like a real CrowdSec 1.8.1
    container, statefully, in every state the page has to handle (absent, stopped, crash-looping, starting,
    unhealthy, LAPI down, empty, full of data, an old 1.6.5 without allowlists).
    JSON shapes, message texts and error texts were captured from a genuine crowdsecurity/crowdsec v1.8.1
    container and are reproduced here (where the spec and the real thing disagreed, the real thing won; see
    the "DIFFERENCES FROM THE SPEC" notes below).

USAGE
    A wrapper called `docker` on PATH does:      exec python3 /path/to/mock-crowdsec.py "$@"
    so argv[1:] is a docker command line (ps, inspect, exec, cp, restart, logs, ...).
    State lives in the directory named by $FAKE_CS_DIR (required, created on demand):
        state.json      the whole world (containers, CrowdSec DB, hub, logs)
        rootfs/         the container's files (/etc/crowdsec/... is a real directory tree here)
        calls.log       one line per invocation: epoch<TAB>argv joined by a space
        unsupported.log one line per unsupported docker/cscli sub-command
        .lock           flock() target (several `docker exec` may run in parallel)

    Control verbs (first argument starts with --mock-):
        --mock-init SCENARIO [--traefik] [--version 1.8.1] [--seed N]
              (re)create the state from a preset:  absent defined stopped crashloop starting unhealthy
              lapi-down empty data old        (calls.log/unsupported.log are truncated)
        --mock-set KEY=VALUE ...      tweak the state (knobs below)
        --mock-dump                   print state.json
        --mock-tick SECONDS           pretend that many seconds passed (decisions expire, last_pull ages)

    Knobs (--mock-set):
        docker_down=1|0     every docker command fails like a dead daemon
        lapi_down=1|0|2     1: every cscli sub-command the spec lists fails with "connection refused";
                            2: only the sub-commands that really talk to the LAPI fail (the database-direct
                            ones - bouncers, machines, allowlists list/add/..., console, metrics - keep working)
        health=healthy|unhealthy|starting     container health (starting sticks until changed or restarted)
        status=running|exited|restarting      force the container state
        version=1.6.5       CrowdSec version (< 1.6.8: no allowlists, no --bypass-allowlist; < 1.7: empty JSON
                            lists print "null", old-style hub messages)
        discord=1           install the DCS-shipped profiles.yaml and a rendered http.yaml (discord webhook)
        traefik=1|0         add/remove the Traefik container
        health_delay=N      after a restart, docker inspect says "starting" for N seconds of mock time
        restart_fails=1     the next restart leaves a crash loop (cleared afterwards)
        cscli_slow_ms=N     every cscli call sleeps N ms first
        empty_json=null|[]  what `-o json` prints for an empty decisions/alerts list (default: [] for >= 1.7)
        capi=ok|error|unregistered|disabled   `cscli capi status` / console state

DIFFERENCES FROM THE SPEC (the real 1.8.1 container was authoritative)
    * `decisions list -o json` / `alerts list -o json` print `[]` when nothing matches (not `null`); `alerts list`
      prints it without a trailing newline; `null` only for versions below 1.7.
    * hub install/remove/upgrade print the 1.8 "Action plan:" text, not "Enabled collections:x".
    * `decisions delete -i IP` also deletes ranges containing the IP (it has no --scope flag); `decisions delete
      --id N` succeeds for any known id; unknown ids fail with the API error text.
    * `alerts inspect` of an unknown id: "can't find alert with id 99: API error: object not found".
    * `bouncers add` keys are 43 characters of standard base64 (they can contain + and /), not URL-safe.
    * `bouncers delete` of an unknown name: "unable to delete bouncer NAME: ent: bouncer not found".
    * `docker inspect X` of an unknown container prints `[]` on stdout and "error: no such object: X" on stderr;
      `{{.State.Health.Status}}` of a container without a healthcheck is a template error (rc 1), like docker.
    * `docker logs` writes the crowdsec log lines (time="..." level=...) to stderr and the entrypoint lines to stdout.
    * `simulation enable NAME` for an unknown scenario logs an error line and exits 0 (it is an error message,
      not a failure), `decisions import` prints "Parsing json" / "Imported N decisions".
    * `crowdsec -t` writes everything to stderr; the path in the messages is the profiles file actually tested.

DESIGN NOTES
    * Standard library only, Python 3.8+. Start-up is ~15-25 ms; heavy modules are imported lazily.
    * Every invocation takes an exclusive flock() for its read-modify-write and writes state.json atomically.
    * Time is wall clock + state["clock"] (advanced by --mock-tick). Decisions keep an absolute `until`,
      so their remaining duration is derived at print time exactly like the LAPI does (truncated seconds,
      negative for expired ones, which `alerts list` and `decisions list` still show inside their alert).
    * Ids/UUIDs/API keys come from a small deterministic generator seeded by --seed (default 1).
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
    "avatar_url": "https://raw.githubusercontent.com/scotthowson/Docker-Compose-Skeleton-UI/v2.0.0/brand/discord/crowdsec-avatar.png",
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
PLAN_ORDER = ('collections', 'contexts', 'scenarios', 'postoverflows', 'parsers', 'appsec-configs', 'appsec-rules')  # Action plan order
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

    def status(self, typ, name):
        """-> (status, utf8_status) exactly as `cscli <type> list -o json` prints them"""
        e = self.entry(typ, name)
        latest = self.latest(typ, name)
        outdated = (e is None) or vkey(e['v']) < vkey(latest)
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
    ms = ms if ms is not None else 2.0 + (int(t * 1000) % 4000) / 1000.0
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
    opts, pos = _parse_flags(argv, {'-a': ('all', False), '--all': ('all', False), '-q': ('quiet', False), '--quiet': ('quiet', False),
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
    if prog == 'wget':
        outn('null')
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
            if tuple(path) not in _CMDS and (cand in _CMDS or cand in _GROUPS):
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
        lines.append('| ' + _padw(title, tw - 1) + '|')
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
    """the flat look of bouncers/machines/allowlists/hub lists: dashed rules, two spaces between columns"""
    w = [_cell_w(h) for h in headers]
    for r in rows:
        for i, c in enumerate(r):
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
        lines.append(' ' + '  '.join(cell(c, w[i]) for i, c in enumerate(r)) + ' ')
    lines.append('-' * total)
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

    # -- output/logging ----------------------------------------------------------------------------
    def log(self, level, msg, **kv):
        """cscli's logger: text lines (level=info msg="...") in human mode, only errors in raw, JSON errors in json"""
        if self.output == 'json':
            if level != 'error':
                return
            d = dict(kv, level=level, msg=msg, time=iso_s(self.t))
            errn(json.dumps(d, sort_keys=True, ensure_ascii=False, separators=(',', ':')) + '\n')
            return
        if self.output == 'raw' and level not in ('error', 'fatal'):
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
        lapi_hit(self.st, '/v1/watchers/login', 'POST')
        lapi_hit(self.st, route, method)
        log_lapi(self.st, self.t, 'POST', '/v1/watchers/login', 200, 44.0)
        log_lapi(self.st, self.t + 0.05, method, path or route, code)
        self.run.touch()

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
            out(csv_line(['name', 'description', 'created_at', 'updated_at', 'console_managed', 'size']))
            out(csv_line([al['name'], al['description'], iso_ms(al['created']), iso_ms(al['updated']), 'false', len(al['items'])]))
            return
        w = 46
        out('-' * w)
        out(' ' + pad('Allowlist: %s' % al['name'], w - 2) + ' ')
        out('-' * w)
        for k, v in (('Name', al['name']), ('Description', al['description']), ('Created at', iso_ms(al['created'])),
                     ('Updated at', iso_ms(al['updated'])), ('Managed by Console', 'no')):
            out(' ' + pad(k, 18) + '  ' + pad(v, w - 23) + ' ')
        out('-' * w)
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
        if self.output == 'json':
            out(gojson(bouncer_out(b), 2))
            return
        w = 55
        out('-' * w)
        out(' ' + pad('Bouncer: %s' % b['name'], w - 2) + ' ')
        out('-' * w)
        for k, v in (('Created At', go_time(b['created'], 9)), ('Last Update', go_time(b['updated'], 9)), ('Revoked?', 'true' if b.get('revoked') else 'false'),
                     ('IP Address', b.get('ip', '')), ('Type', b.get('type', '')), ('Version', b.get('version', '')),
                     ('Last Pull', go_time(b['last_pull'], 9) if b.get('last_pull') else ''), ('Auth type', b.get('auth_type', 'api-key')),
                     ('OS', b.get('os', '?')), ('Auto Created', 'false')):
            out(' ' + pad(k, 13) + ' ' + pad(v, w - 16) + ' ')
        out('-' * w)

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
                 m.get('os', 'alpine (docker)/3.24.1'), m.get('auth_type', 'password'),
                 go_dur(self.t - m['last_heartbeat']).replace('-', '') if m.get('last_heartbeat') else '-'] for m in ms]
        out(table_modern(['Name', 'IP Address', 'Last Update', 'Status', 'Version', 'OS', 'Auth Type', 'Last Heartbeat'], rows))

    def c_machines_inspect(self):
        m = next((x for x in self.cs['machines'] if x['id'] == self.args[0]), None)
        if m is None:
            self.fatal("unable to read machine data '%s': ent: machine not found" % self.args[0])
        o = machine_out(m)
        o['metrics'] = {}
        out(gojson(o, 2))


class MetricsCmds(object):
    """cscli metrics (the JSON is a Go map: sorted keys, no trailing newline)"""

    def c_metrics(self):
        m = metrics_out(self.st)
        if self.path == ('metrics', 'show') and self.args:
            m = {k: v for k, v in m.items() if k in self.args}
        if self.output == 'json':
            outn(gojson(m, 1, True))
            return
        # human/raw: the three tables people look at
        out('Acquisition Metrics:')
        acq = m.get('acquisition', {})
        rows = [[k, str(v.get('reads', 0)), str(v.get('parsed', 0)), str(v.get('unparsed', 0)), str(v.get('pour', 0))] for k, v in sorted(acq.items())]
        if rows:
            out(table_classic(['Source', 'Lines read', 'Lines parsed', 'Lines unparsed', 'Lines poured to bucket'], rows))
        out('')
        out('Local API Decisions:')
        rows = []
        for scen, origins in sorted(m.get('decisions', {}).items()):
            for origin, types in sorted(origins.items()):
                for typ, cnt in sorted(types.items()):
                    rows.append([scen, origin, typ, str(cnt)])
        if rows:
            out(table_classic(['Reason', 'Origin', 'Action', 'Count'], rows))

    def c_metrics_show(self):
        return self.c_metrics()

    def c_metrics_list(self):
        items = [('acquisition', 'Acquisition Metrics'), ('alerts', 'Local API Alerts'), ('bouncers', 'Bouncer Metrics'), ('decisions', 'Local API Decisions'),
                 ('lapi', 'Local API Metrics'), ('lapi-bouncer', 'Local API Bouncers Metrics'), ('lapi-decisions', 'Local API Bouncers Decisions'),
                 ('lapi-machine', 'Local API Machines Metrics'), ('parsers', 'Parser Metrics'), ('scenarios', 'Scenario Metrics'),
                 ('stash', 'Parser Stash Metrics'), ('whitelists', 'Parser Whitelist Metrics')]
        if self.output == 'json':
            out(gojson([{'type': t, 'title': ti, 'description': ti} for t, ti in items], 2))
        else:
            out(table_modern(['Type', 'Title'], [[t, ti] for t, ti in items]))


class StatusCmds(object):
    """cscli lapi status / capi status / console status"""

    def c_lapi_status(self):
        out('Loaded credentials from /etc/crowdsec/local_api_credentials.yaml')
        out('Trying to authenticate with username "localhost" on http://0.0.0.0:8080/')
        lapi_hit(self.st, '/v1/watchers/login', 'POST')
        self.run.touch()
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


def _remove_set(hub, typ, names, force):
    """items to disable when removing `names`: their closure minus what other enabled collections still need"""
    target = {}
    for n in names:
        if (hub.entry(typ, n) or {}).get('on'):
            hub.closure(typ, n, target)
    keep = {}
    rem_cols = set(target.get('collections', ()))
    for c in hub.enabled_collections():
        if c not in rem_cols:
            hub.closure('collections', c, keep)
    res = {}
    for t2, members in target.items():
        for m in members:
            if m in keep.get(t2, ()) and not (t2 == typ and m in names):
                continue
            if (hub.entry(t2, m) or {}).get('on'):
                res.setdefault(t2, set()).add(m)
    return res


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

    def _print_plan(self, download, enable, disable, dry, versions=None, disable_first=False):
        if self.human():
            out('Action plan:')
            if download:
                out(_fmt_plan('\U0001f4e5 download', download, versions if versions is not None else download))
            if enable:
                out(_fmt_plan('✅ enable', enable))
            if disable:
                out(_fmt_plan('❌ disable', disable))

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
            self._print_plan(download, enable, {}, fl.get('dry-run'))
            if self.human():
                out('')
            if fl.get('dry-run'):
                out('Dry run, no action taken.')
                return
            for t in ('parsers', 'postoverflows', 'contexts', 'scenarios', 'appsec-configs', 'appsec-rules', 'collections'):
                for n in sorted(download.get(t, {})):
                    out('downloading %s:%s' % (t, n))
                    hub.set_item(t, n, False, hub.latest(t, n))
            for t in ('parsers', 'postoverflows', 'contexts', 'scenarios', 'appsec-configs', 'appsec-rules', 'collections'):
                for n in sorted(enable.get(t, ())):
                    out('enabling %s:%s' % (t, n))
                    hub.set_item(t, n, True)
            self.run.touch()
        if missing and fl.get('ignore'):
            self.log('error', '<nil>')

    def _old_install(self, hub, typ, names, download, enable, dry):
        """cscli < 1.7: no action plan, one info line per step and a reload reminder"""
        if dry:
            return
        for t in ('parsers', 'postoverflows', 'contexts', 'scenarios', 'collections'):
            for n in sorted(download.get(t, {})):
                self.log('info', '%s : OK' % n)
                hub.set_item(t, n, False, hub.latest(t, n))
        for t in ('parsers', 'postoverflows', 'contexts', 'scenarios', 'collections'):
            for n in sorted(enable.get(t, ())):
                self.log('info', 'Enabled %s : %s' % (t, n) if t != typ or n not in names else 'Enabled %s' % n)
                hub.set_item(t, n, True)
        self.log('info', "Run 'systemctl reload crowdsec' for the new configuration to be effective.")
        self.run.touch()

    def _hub_delete(self, hub, typ):
        fl = self.fl
        names = list(self.args)
        if fl.get('all'):
            names = [n for n in hub.names(typ, False)]
        for n in names:
            if not hub.known(typ, n):
                self.fatal("can't find '%s' in %s" % (n, typ))
        force = fl.get('force')
        disable = {}
        for n in names:
            e = hub.entry(typ, n)
            if not (e and e['on']):
                continue
            owners = hub.belongs_to(typ, n)
            if owners and typ != 'collections' and not force and not fl.get('all'):
                self.log('warning', '%s belongs to collections: [%s]' % (n, ' '.join(owners)))
                self.log('warning', "Run 'sudo cscli %s remove %s --force' if you want to force remove this %s" % (typ, n, typ[:-1]))
                continue
            for t2, s in _remove_set(hub, typ, [n], force).items():
                disable.setdefault(t2, set()).update(s)
        if not disable:
            if fl.get('purge'):
                for n in names:
                    hub.h['items'].get(typ, {}).pop(n, None)
                self.run.touch()
            out('Nothing to install or remove.')
            return
        if not ver_ge(self.st, 1, 7):
            for t in ('collections', 'scenarios', 'postoverflows', 'parsers', 'contexts'):
                for n in sorted(disable.get(t, ())):
                    self.log('info', 'Removed %s' % n)
                    hub.set_item(t, n, False)
            self.log('info', "Run 'systemctl reload crowdsec' for the new configuration to be effective.")
            self.run.touch()
            return
        self._print_plan({}, {}, disable, fl.get('dry-run'))
        if self.human():
            out('')
        if fl.get('dry-run'):
            out('Dry run, no action taken.')
            return
        for t in ('parsers', 'postoverflows', 'contexts', 'scenarios', 'appsec-configs', 'appsec-rules', 'collections'):
            for n in sorted(disable.get(t, ())):
                out('disabling %s:%s' % (t, n))
                hub.set_item(t, n, False)
                if fl.get('purge'):
                    hub.h['items'][t].pop(n, None)
        self.run.touch()

    def _hub_upgrade(self, hub, typ):
        fl = self.fl
        names = list(self.args)
        if fl.get('all'):
            names = [n for n in hub.h['items'].get(typ, {})]
        for n in names:
            if not hub.known(typ, n):
                self.fatal("can't find '%s' in %s" % (n, typ))
        download, _e, _d = _plan_sets(hub, typ, names, 'upgrade')
        if not download:
            out('Nothing to install or remove.')
            return
        self._print_plan(download, {}, {}, fl.get('dry-run'))
        if self.human():
            out('')
        if fl.get('dry-run'):
            out('Dry run, no action taken.')
            return
        for t in ('parsers', 'postoverflows', 'contexts', 'scenarios', 'appsec-configs', 'appsec-rules', 'collections'):
            for n in sorted(download.get(t, {})):
                out('downloading %s:%s' % (t, n))
                e = hub.entry(t, n)
                if e is None:
                    hub.set_item(t, n, False, hub.latest(t, n))
                else:
                    e['v'] = hub.latest(t, n)
        self.run.touch()

    def _hub_inspect(self, hub, typ):
        res = []
        for n in self.args:
            if not hub.known(typ, n):
                self.fatal("can't find '%s' in %s" % (n, typ))
            e = hub.entry(typ, n)
            o = {'type': typ, 'name': n, 'file_name': hub.local_path(typ, n).rsplit('/', 1)[1], 'description': hub.desc(typ, n),
                 'path': '%s/%s' % (typ, n.split('/')[0] + '/' + hub.local_path(typ, n).rsplit('/', 1)[1]), 'version': hub.latest(typ, n)}
            for t2, ms in hub.members(typ, n).items():
                o[t2] = ms
            o.update({'local_version': e['v'] if e else '', 'installed': bool(e and e['on']), 'downloaded': e is not None,
                      'up_to_date': bool(e) and vkey(e['v']) >= vkey(hub.latest(typ, n)), 'tainted': False, 'local': False,
                      'belongs_to_collections': hub.belongs_to(typ, n)})
            res.append(o)
        if self.output == 'json':
            out(gojson(res[0] if len(res) == 1 else res, 2))
        else:
            for o in res:
                out('type: %s\nname: %s\nversion: %s\ninstalled: %s' % (o['type'], o['name'], o['version'], 'true' if o['installed'] else 'false'))

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
        for c in hub.enabled_collections():
            cl = hub.closure('collections', c)
            for t2, ms in cl.items():
                for m in ms:
                    e = hub.entry(t2, m)
                    if e and e['on'] and vkey(e['v']) < vkey(hub.latest(t2, m)) and (t2, m) != ('collections', c):
                        if self.human():
                            err('%s is outdated because of %s:%s' % (c, t2, m))
                        break
                else:
                    continue
                break

    def c_hub_upgrade(self):
        hub = Hub(self.st)
        download = {}
        for t in HUB_ORDER:
            for n, e in hub.h['items'].get(t, {}).items():
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
        for t in ('parsers', 'postoverflows', 'contexts', 'scenarios', 'appsec-configs', 'appsec-rules', 'collections'):
            for n in sorted(download.get(t, {})):
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
            for t in ('parsers', 'postoverflows', 'scenarios', 'contexts', 'appsec-configs', 'appsec-rules', 'collections'):
                for n in hub.names(t, all_):
                    it = hub.item(t, n)
                    out(csv_line([n, it['status'], it['local_version'], it['description'], t]))
            return
        rows = []
        for t in ('collections', 'parsers', 'postoverflows', 'scenarios', 'contexts'):
            for n in hub.names(t, all_):
                it = hub.item(t, n)
                state = 'up-to-date' if it['status'] == 'enabled' else it['status'].replace('enabled,', '')
                rows.append([t, n, it['utf8_status'].split('  ')[0] + '  ' + state, it['local_version']])
        out(table_modern(['Type', 'Name', '\U0001f4e6 Status', 'Version'], rows))

    def c_hub_types(self):
        for t in ('parsers', 'postoverflows', 'scenarios', 'contexts', 'appsec-configs', 'appsec-rules', 'collections'):
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
    def c_config_show(self):
        key = self.fl.get('key')
        vals = {'Config.API.Server.ListenURI': '0.0.0.0:8080', 'Config.ConfigPaths.ConfigDir': '/etc/crowdsec/',
                'Config.ConfigPaths.DataDir': '/var/lib/crowdsec/data/', 'Config.API.Server.ProfilesPath': self.conf['profiles_path'],
                'Config.ConfigPaths.NotificationDir': self.conf['notification_dir']}
        if key in vals:
            out(vals[key])
            return
        unsupported(self.run, ['exec', 'CrowdSec', 'cscli', 'config', 'show'] + ([('--key ' + key)] if key else []))


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
         'empty_json', 'capi')


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
    if k in ('docker_down', 'restart_fails', 'health_delay', 'cscli_slow_ms'):
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
6zP2DGvzS9f8V3qeTNmB7nfx1z//Aqx3j7s=
"""


if __name__ == '__main__':
    sys.exit(main())

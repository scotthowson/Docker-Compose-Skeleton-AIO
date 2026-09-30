#!/bin/bash
# =============================================================================
# DCS CrowdSec media apps: the parser file DCS writes, replayed through the real CrowdSec
#
# tests/smoke.sh checks that DCS writes (and removes) parsers/s02-enrich/dcs-media-apps.yaml for CROWDSEC_MEDIA_APPS. This checks what CrowdSec does
# with the file. The file comes from DCS's own code (_crowdsec_media_apps_sync); a throwaway container of the CrowdSec image replays synthetic Traefik
# access logs through the real hub parsers and scenarios twice, without the file ("stock") and with it ("tuned"); and the alerts of the two runs are
# compared with what the tuning is for: the ordinary page loads of a media app's web client are not a crawl, and everything a scanner, a brute-forcer
# or another backend does is judged as before.
#
# Not part of tests/smoke.sh or CI: it needs Docker, the CrowdSec image (used as it is, never pulled) and the network (the container downloads the hub's
# parsers and scenarios, which the image does not carry). Without one of them it says so and exits 0. It takes about two minutes.
#
# Usage: tests/crowdsec-media-apps.sh [IMAGE]          IMAGE defaults to crowdsecurity/crowdsec:latest; exit status 0 = every scenario came out as expected
#        CS_MEDIA_KEEP=1 tests/crowdsec-media-apps.sh   keeps the work folder (the logs, the generated parser file) and says where it is
# =============================================================================

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-crowdsecurity/crowdsec:latest}"
NAME="dcs-media-apps-test-$$"

command -v docker >/dev/null 2>&1 || { echo "skipped: no docker"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skipped: no python3 (it writes the test logs)"; exit 0; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "skipped: $IMAGE is not here (this test never pulls it)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dcs-media-apps-XXXXXX")"
trap 'docker rm -f "$NAME" >/dev/null 2>&1; if [[ -n "${CS_MEDIA_KEEP:-}" ]]; then echo "work folder kept: $WORK"; else rm -rf "$WORK"; fi' EXIT
mkdir -p "$WORK/lab/logs"

PASS=0
FAIL=0
check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
    fi
}

# -- the parser file, from DCS's own code: the same function that keeps it up to date on a server
echo "The parser file"
(
    set --
    # shellcheck source=/dev/null
    source "$ROOT/.scripts/api-server.sh" >/dev/null 2>&1
    set +e
    export CROWDSEC_MEDIA_APPS=jellyfin
    _crowdsec_media_apps_sync "$WORK/cfg"
)
PARSER="$WORK/cfg/parsers/s02-enrich/dcs-media-apps.yaml"
check "the file is written" yes "$([[ -s "$PARSER" ]] && echo yes || echo no)"
[[ -s "$PARSER" ]] || { echo "0 passed, 1 failed"; exit 1; }
cp "$PARSER" "$WORK/lab/dcs-media-apps.yaml"

# -- the scenarios: Traefik's JSON access log, as a web client of Jellyfin behind Traefik makes it, and as a scanner would
python3 - "$WORK/lab/logs" <<'PY'
import json, os, random, sys
from datetime import datetime, timedelta, timezone

T0 = datetime(2026, 9, 30, 20, 0, 0, tzinfo=timezone.utc)
IP = '203.0.113.77'      # a documentation address
UA = 'Mozilla/5.0 (X11; Linux x86_64; rv:158.0) Gecko/20100101 Firefox/158.0'
BAD_UA = 'Mozilla/5.00 (Nikto/2.1.6) (Evasions:None) (Test:Port Check)'


def hexid():
    return ''.join(random.choice('0123456789abcdef') for _ in range(32))


def line(t, method, path, status, backend='jellyfin:8096', host='watch.example.test', ua=UA):
    """one access log line; backend None is a request no router took (Traefik answers itself: no ServiceAddr)"""
    ts = t.strftime('%Y-%m-%dT%H:%M:%SZ')
    row = {'ClientAddr': '172.71.0.1:4000', 'ClientHost': IP, 'ClientPort': '4000', 'ClientUsername': '-', 'DownstreamContentSize': 1234, 'DownstreamStatus': status,
           'Duration': 5000000, 'OriginContentSize': 1234, 'OriginDuration': 4000000, 'OriginStatus': status, 'RequestAddr': host, 'RequestHost': host,
           'RequestMethod': method, 'RequestPath': path, 'RequestProtocol': 'HTTP/2.0', 'RequestScheme': 'https', 'StartLocal': ts, 'StartUTC': ts,
           'entryPointName': 'websecure', 'level': 'info', 'msg': '', 'request_User-Agent': ua, 'time': ts}
    if backend:
        row.update({'RouterName': 'app-router@file', 'ServiceAddr': backend, 'ServiceName': 'app@file', 'ServiceURL': 'http://' + backend})
    return json.dumps(row)


def browse(start, backend='jellyfin:8096', host='watch.example.test', query=True):
    """a page load and some scrolling: the web client's API calls, sixty posters and backdrops, twenty items without a logo (answered 404).
    The client adds the size it wants to every image address, and Traefik logs the path with its query."""
    out, t = [], start
    uid, items = hexid(), [hexid() for _ in range(60)]
    boot = ['/', '/web/', '/web/runtime.bundle.js', '/web/main.jellyfin.bundle.js', '/System/Info/Public', '/Branding/Configuration', '/Users/Public', '/QuickConnect/Enabled',
            '/JellyfinEnhanced/public-config', '/JellyfinEnhanced/version', '/JavaScriptInjector/public.js', '/Plugins/AchievementBadges/public-config', '/ActorPlus/status',
            '/PluginPages/User', '/MediaBar/WebConfig', '/HomeScreen/Meta']
    for p in boot:
        out.append(line(t, 'GET', p, 200, backend, host))
    t += timedelta(seconds=1)
    api = ['/Users/%s' % uid, '/Users/%s/Views' % uid, '/UserViews', '/DisplayPreferences/usersettings', '/Sessions', '/Users/%s/Items' % uid, '/Shows/NextUp', '/Items/Resume',
           '/Items/Latest', '/Plugins/AchievementBadges/users/%s/preferences' % uid, '/Plugins/AchievementBadges/users/%s/equipped' % uid, '/Plugins/AchievementBadges/users/%s/cosmetics' % uid,
           '/Plugins/StarTrack/MyRatings', '/JellyfinEnhanced/user-settings/%s/settings.json' % uid, '/JellyfinEnhanced/private-config', '/CustomTabs/Config', '/System/Info', '/socket']
    for p in api:
        out.append(line(t, 'GET', p, 200, backend, host))
    for i, it in enumerate(items):          # posters and backdrops: a different address each, answered
        q = '?fillHeight=446&fillWidth=297&quality=96&tag=%s' % it[::-1] if query else ''
        out.append(line(t + timedelta(milliseconds=i * 40), 'GET', '/Items/%s/Images/%s%s' % (it, random.choice(['Primary', 'Backdrop/0', 'Logo', 'Thumb']), q),
                        random.choice([200, 200, 200, 304]), backend, host))
    for i in range(20):                     # a few things without artwork: answered 404 (not probing)
        q = '?fillHeight=200&fillWidth=300&quality=96' if query else ''
        out.append(line(t + timedelta(seconds=1, milliseconds=i * 30), 'GET', '/Items/%s/Images/Logo%s' % (hexid(), q), 404, backend, host))
    return out


def scan(start, n=60, backend='jellyfin:8096'):
    """a scanner: well-known paths, then random ones; everything answered 404 (two of them try to leave the web root)"""
    paths = ['/wp-login.php', '/.env', '/admin', '/phpmyadmin/', '/.git/config', '/actuator/env', '/cgi-bin/luci', '/server-status', '/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php',
             '/config.php', '/backup.zip', '/xmlrpc.php', '/administrator/', '/.aws/credentials', '/id_rsa', '/etc/passwd', '/web/../../etc/passwd', '/Users/../../etc/shadow']
    out = []
    for i in range(n):
        p = paths[i % len(paths)] if i < len(paths) * 2 else '/%s' % hexid()[:10] + random.choice(['.php', '.bak', '/', '.sql'])
        out.append(line(start + timedelta(milliseconds=i * 150), 'GET', p, 404, backend, ua='python-requests/2.31'))
    return out


def ms(i, step):
    return T0 + timedelta(milliseconds=i * step)


TRAVERSAL = ['/web/..%2f..%2f..%2fetc/passwd', '/Items/../../../etc/passwd', '/web/%2e%2e/%2e%2e/etc/shadow', '/Users/..\\..\\windows\\win.ini', '/web/%252e%252e/%252e%252e/etc/hosts',
             '/web/..;/..;/etc/passwd', '/Items/%2e%2e%2f%2e%2e%2fetc/passwd', '/System/..%5c..%5cwindows/win.ini', '/web/..%00/etc/passwd', '/a/../../../../etc/passwd']

SCENARIOS = {
    # what the tuning is for
    'browse':         lambda: browse(T0),
    'browse-plain':   lambda: browse(T0, query=False),
    'browse-caps':    lambda: browse(T0, backend='Jellyfin:8096'),
    'artwork404':     lambda: [line(ms(i, 50), 'GET', '/Items/%s/Images/Logo?fillHeight=200&fillWidth=300&quality=96' % hexid(), 404) for i in range(40)],
    'crawl-answered': lambda: [line(ms(i, 60), 'GET', '/Items/%s' % hexid(), 200) for i in range(140)],
    # the same, and more, for everyone else
    'other':          lambda: browse(T0, backend='whoami:80', host='whoami.example.test'),
    'scan':           lambda: scan(T0),
    'unrouted':       lambda: [line(ms(i, 150), 'GET', '/%s.php' % hexid()[:8], 404, backend=None, ua='python-requests/2.31') for i in range(60)],
    'post404':        lambda: [line(ms(i, 200), 'POST', '/%s' % hexid()[:10], 404, ua='python-requests/2.31') for i in range(60)],
    'bruteforce':     lambda: [line(T0 + timedelta(seconds=i * 2), 'POST', '/Users/AuthenticateByName', 401) for i in range(12)],
    'expired':        lambda: [line(ms(i, 60), 'GET', '/Items/%s' % hexid(), 401) for i in range(140)],
    'traversal':      lambda: [line(ms(i, 200), 'GET', TRAVERSAL[i % len(TRAVERSAL)], 200, ua='curl/8.4.0') for i in range(20)],
    'badua-answered': lambda: [line(ms(i, 300), 'GET', '/', 200, ua=BAD_UA) for i in range(6)],
    'badua-refused':  lambda: [line(ms(i, 300), 'GET', '/%s' % hexid()[:8], 404, ua=BAD_UA) for i in range(6)],
    'mixed':          lambda: browse(T0) + scan(T0 + timedelta(seconds=4)),
}

for name, make in SCENARIOS.items():
    random.seed(7)
    rows = make()
    rows.sort(key=lambda l: json.loads(l)['time'])
    with open(os.path.join(sys.argv[1], name + '.log'), 'w') as f:
        f.write('\n'.join(rows) + '\n')
PY

# -- what runs inside the CrowdSec image: a throwaway engine (local API only, nothing leaves the container but the hub downloads) replays every log
#    twice, and prints one RESULT line for each replay: the mode, the scenario, the names of the detections that came out of it
cat > "$WORK/lab/run.sh" <<'SH'
#!/bin/sh
cp -r /staging/etc/crowdsec /etc/crowdsec
mkdir -p /var/lib/crowdsec/data
cscli hub update >/dev/null 2>&1 || { echo "SKIP the hub cannot be reached"; exit 0; }
cscli parsers install crowdsecurity/syslog-logs crowdsecurity/dateparse-enrich >/dev/null 2>&1
cscli collections install crowdsecurity/traefik crowdsecurity/base-http-scenarios crowdsecurity/http-cve crowdsecurity/whitelist-good-actors >/dev/null 2>&1 \
    || { echo "SKIP the hub's collections cannot be installed"; exit 0; }
cscli machines add lab --auto -f /etc/crowdsec/local_api_credentials.yaml >/dev/null 2>&1
crowdsec -no-cs >/tmp/lapi.log 2>&1 &
up=no
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do sleep 1; if cscli lapi status >/dev/null 2>&1; then up=yes; break; fi; done
[ "$up" = yes ] || { echo "ERROR the local API did not start"; exit 0; }
for mode in stock tuned; do
    if [ "$mode" = tuned ]; then cp /lab/dcs-media-apps.yaml /etc/crowdsec/parsers/s02-enrich/; fi
    for f in /lab/logs/*.log; do
        s=$(basename "$f" .log)
        cscli alerts delete --all >/dev/null 2>&1; cscli decisions delete --all >/dev/null 2>&1
        crowdsec -dsn "file://$f" -type traefik -no-api >/tmp/replay.log 2>&1
        sleep 1
        # a replay that did not start, or ran without the parser file it should have had, says nothing about the tuning
        if grep -q 'level=fatal' /tmp/replay.log; then echo "ERROR crowdsec stopped on $s: $(grep 'level=fatal' /tmp/replay.log | head -n 1 | cut -c1-220)"; continue; fi
        loaded=no; grep -q 'dcs-media-apps.yaml' /tmp/replay.log && loaded=yes
        if [ "$mode" = tuned ] && [ "$loaded" = no ]; then echo "ERROR the parser file was not loaded ($s)"; continue; fi
        if [ "$mode" = stock ] && [ "$loaded" = yes ]; then echo "ERROR the parser file was loaded in the stock run ($s)"; continue; fi
        names=$(cscli alerts list -o raw 2>/dev/null | tail -n +2 | cut -d, -f4 | sed 's#^crowdsecurity/##; s#^LePresidente/##; s#^ltsich/##' | sort -u | tr '\n' ' ')
        echo "RESULT $mode $s ${names}"
    done
done
SH
chmod +x "$WORK/lab/run.sh"

echo "Replaying through $IMAGE ($(docker run --rm --entrypoint cscli "$IMAGE" version 2>&1 | sed -n 's/^version: //p' | head -n 1))"
declare -A STOCK=() TUNED=()
SKIP=""
ERRORS=0
while IFS= read -r row; do
    case "$row" in
        "RESULT stock "*) read -r _ _ name alerts <<< "$row"; STOCK[$name]="${alerts%% }" ;;
        "RESULT tuned "*) read -r _ _ name alerts <<< "$row"; TUNED[$name]="${alerts%% }" ;;
        SKIP*) SKIP="${row#SKIP }" ;;
        ERROR*) ERRORS=$((ERRORS + 1)); (( ERRORS > 3 )) || echo "  problem in the replay: ${row#ERROR }" ;;   # (the same one repeats for every scenario)
    esac
done < <(docker run --rm --name "$NAME" -v "$WORK/lab:/lab:ro" --entrypoint sh "$IMAGE" /lab/run.sh 2>&1)
if [[ -n "$SKIP" ]]; then echo "skipped: $SKIP (the test needs the network)"; exit 0; fi
if (( ERRORS > 0 )); then (( ERRORS <= 3 )) || echo "  (and $((ERRORS - 3)) more)"; FAIL=$((FAIL + 1)); fi

# -- what each scenario has to come out as. cleared: CrowdSec alerts without the file and does not with it. same: it alerts, the same way with and without.
declare -A EXPECT=(
    [browse]=cleared [browse-plain]=cleared [browse-caps]=cleared [artwork404]=cleared [crawl-answered]=cleared
    [other]=same [scan]=same [unrouted]=same [post404]=same [bruteforce]=same [expired]=same [traversal]=same [badua-refused]=same [mixed]=same
    [badua-answered]=cleared
)
declare -A ABOUT=(
    [browse]="a page load of the web client, image addresses with ?size=..."
    [browse-plain]="the same, image addresses without a query"
    [browse-caps]="the same, the backend spelt Jellyfin in the access log"
    [artwork404]="40 items without a logo, asked within two seconds"
    [crawl-answered]="140 different item pages, all answered (what a page load does)"
    [other]="the same page load, but to a backend that is not listed"
    [scan]="a scanner: 404 on well-known and random paths"
    [unrouted]="a scanner on a name without a route (Traefik answers 404 itself)"
    [post404]="60 POST requests answered 404"
    [bruteforce]="12 login attempts answered 401"
    [expired]="an expired session: 140 different GET requests answered 401"
    [traversal]="path traversal that the app answered 200"
    [badua-refused]="a known scanner's user agent on requests the app refuses"
    [mixed]="a page load and a scan from the same address"
    [badua-answered]="a known scanner's user agent on answered requests only (accepted: an answered request is seen by no scenario)"
)
echo "Stock CrowdSec against CrowdSec with the file"
for name in browse browse-plain browse-caps artwork404 crawl-answered other scan unrouted post404 bruteforce expired traversal badua-refused mixed badua-answered; do
    s="${STOCK[$name]:-}"; t="${TUNED[$name]:-}"; want="${EXPECT[$name]}"
    if [[ -z "${STOCK[$name]+x}" || -z "${TUNED[$name]+x}" ]]; then check "$name: replayed" yes no; continue; fi
    case "$want" in
        cleared) got=no; [[ -n "$s" && -z "$t" ]] && got=yes
                 check "$name: ${ABOUT[$name]}: alerts [$s], with the file [${t:-none}]" yes "$got" ;;
        same)    got=no; [[ -n "$s" && "$s" == "$t" ]] && got=yes
                 check "$name: ${ABOUT[$name]}: alerts [$s], with the file [${t:-none}]" yes "$got" ;;
    esac
done

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]

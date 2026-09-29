#!/bin/bash
# =============================================================================
# Self-test of tests/mock-crowdsec.py (the stateful docker + cscli stand-in).
# Builds a temporary FAKE_CS_DIR and a `docker` wrapper on PATH, then asserts
# what the DCS CrowdSec API relies on: docker ps/inspect/exec/cp/restart/logs
# in every preset, and the cscli read/write round trips with the real shapes.
# Needs: bash, python3, jq.   Usage: tests/mock-crowdsec.selftest.sh   (exit 0 = all good)
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK="${MOCK:-$HERE/mock-crowdsec.py}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export FAKE_CS_DIR="$T/state"
cat > "$T/bin/docker" <<EOF
#!/bin/bash
exec python3 "$MOCK" "\$@"
EOF
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH"

PASS=0; FAILN=0
ok()   { PASS=$((PASS + 1)); [[ -n "${VERBOSE:-}" ]] && echo "  ok   $1"; return 0; }
bad()  { FAILN=$((FAILN + 1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && echo "       $2"; return 0; }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got: $(printf '%s' "$2" | head -c 300 | tr '\n' '~')   want: $(printf '%s' "$3" | head -c 200 | tr '\n' '~')"; fi; }
like() { if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "got: $(printf '%s' "$2" | head -c 300 | tr '\n' '~')   want match: $3"; fi; }
nolike() { if [[ "$2" =~ $3 ]]; then bad "$1" "unexpected match of $3 in: $(printf '%s' "$2" | head -c 200 | tr '\n' '~')"; else ok "$1"; fi; }
rc()   { local want="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?; eq "$1 (rc)" "$got" "$want"; }

mock() { python3 "$MOCK" "$@"; }
cs()   { docker exec CrowdSec cscli "$@"; }
csi()  { docker exec -i CrowdSec cscli "$@"; }
init() { mock --mock-init "$@" >/dev/null || { echo "init $* failed"; exit 2; }; }

echo "== presets: docker ps / inspect"
init absent
eq "absent: no containers listed" "$(docker ps -a --format '{{.Names}}')" ""
out="$(docker inspect CrowdSec 2>&1)"; rcv=$?
eq "absent: inspect fails" "$rcv" "1"
like "absent: inspect says no such object" "$out" "no such object: CrowdSec"
like "absent: exec says no such container" "$(cs version 2>&1)" "No such container: CrowdSec"
init defined --traefik
eq "defined --traefik: only Traefik" "$(docker ps -a --format '{{.Names}}')" "Traefik"
eq "Traefik compose project label" "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' Traefik)" "networking-security"
eq "Traefik image" "$(docker ps --format '{{.Image}}' --filter name=Traefik)" "traefik:v3.1"

init stopped
eq "stopped: state" "$(docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' CrowdSec)" "exited 137"
eq "stopped: no health object (docker template with if)" "$(docker inspect --format '{{if .State.Health}}h{{end}}' CrowdSec)" ""
like "stopped: ps status" "$(docker ps -a --filter name=CrowdSec --format '{{.Status}}')" "^Exited \(137\) "
like "stopped: exec fails like docker" "$(cs version 2>&1)" "is not running"
eq "stopped: not in plain docker ps" "$(docker ps --format '{{.Names}}')" ""
init crashloop
eq "crashloop: restarting" "$(docker inspect --format '{{.State.Status}} {{.State.Restarting}} {{.RestartCount}}' CrowdSec)" "restarting true 17"
like "crashloop: logs carry a fatal line" "$(docker logs --tail 3 CrowdSec 2>&1)" 'level=fatal msg="while loading profiles'
like "crashloop: exec is refused" "$(cs version 2>&1)" "is restarting"
init starting
eq "starting: health" "$(docker inspect --format '{{.State.Health.Status}}' CrowdSec)" "starting"
like "starting: ps status" "$(docker ps --format '{{.Status}}' --filter name=CrowdSec)" "\(health: starting\)$"
mock --mock-set health=healthy
eq "starting -> healthy by knob" "$(docker inspect --format '{{.State.Health.Status}}' CrowdSec)" "healthy"
init unhealthy
eq "unhealthy: health" "$(docker inspect --format '{{.State.Health.Status}}' CrowdSec)" "unhealthy"
docker restart CrowdSec >/dev/null
eq "unhealthy survives a restart" "$(docker inspect --format '{{.State.Health.Status}}' CrowdSec)" "unhealthy"
mock --mock-set health=healthy
eq "health=healthy heals it" "$(docker inspect --format '{{.State.Health.Status}}' CrowdSec)" "healthy"
mock --mock-set health_delay=3600
docker restart CrowdSec >/dev/null
eq "health_delay: starting right after a restart" "$(docker inspect --format '{{.State.Health.Status}}' CrowdSec)" "starting"
mock --mock-tick 4000
eq "health_delay: healthy after the delay (mock time)" "$(docker inspect --format '{{.State.Health.Status}}' CrowdSec)" "healthy"

echo "== docker inspect / ps shapes (data)"
init data --traefik
eq "ps -a json has the real key set" "$(docker ps -a --filter name=CrowdSec --format '{{json .}}' | jq -c 'keys')" '["Command","CreatedAt","ID","Image","Labels","LocalVolumes","Mounts","Names","Networks","Platform","Ports","RunningFor","Size","State","Status"]'
like "ps Status (healthy)" "$(docker ps --filter name=CrowdSec --format '{{.Status}}')" "^Up .* \(healthy\)$"
eq "inspect top-level keys" "$(docker inspect CrowdSec | jq -c '.[0] | keys')" '["AppArmorProfile","Args","Config","Created","Driver","ExecIDs","GraphDriver","HostConfig","HostnamePath","HostsPath","Id","Image","LogPath","MountLabel","Mounts","Name","NetworkSettings","Path","Platform","ProcessLabel","ResolvConfPath","RestartCount","State"]'
eq "inspect: config mount source is the rootfs" "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/etc/crowdsec"}}{{.Source}}{{end}}{{end}}' CrowdSec)" "$FAKE_CS_DIR/rootfs/etc/crowdsec"
eq "inspect: healthcheck is cscli version" "$(docker inspect CrowdSec | jq -r '.[0].Config.Healthcheck.Test | join(" ")')" "CMD-SHELL cscli version"
eq "inspect: compose labels" "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}/{{index .Config.Labels "com.docker.compose.project"}}' CrowdSec)" "crowdsec/networking-security"
eq "ps label filter finds both stack containers" "$(docker ps --filter label=com.docker.compose.project=networking-security --format '{{.Names}}' | sort | tr '\n' ' ')" "CrowdSec Traefik "
eq "template error is rc 1 (no Health on Traefik)" "$(docker inspect --format '{{.State.Health.Status}}' Traefik >/dev/null 2>&1; echo $?)" "1"
eq "docker version" "$(docker version --format '{{.Server.Version}}')" "29.1.3"

echo "== cscli read commands (data)"
eq "version banner" "$(cs version | head -1)" "version: v1.8.1-909b5157"
n=$(cs decisions list -o json | jq 'length'); [[ "$n" -ge 10 ]] && ok "decisions list has alerts ($n)" || bad "decisions list has alerts" "n=$n"
eq "decisions list hides CAPI" "$(cs decisions list -o json | jq '[.[] | .decisions[]? | select(.origin=="CAPI")] | length')" "0"
eq "decisions list -a shows the 40 CAPI decisions" "$(cs decisions list -a -o json | jq '[.[] | .decisions[]? | select(.origin=="CAPI")] | length')" "40"
eq "the CAPI alert" "$(cs alerts list -a -o json | jq -c '[.[] | select(.kind=="capi")][0] | [.machine_id, .scenario, .uuid, .source.scope]')" '["N/A","update : +40/-0 IPs",null,"crowdsecurity/community-blocklist"]'
eq "alerts list hides CAPI" "$(cs alerts list -o json | jq '[.[] | select(.kind=="capi")] | length')" "0"
like "duration is Go-formatted remaining time" "$(cs decisions list -o json | jq -r '[.[].decisions[]?.duration] | first')" '^[0-9]+h[0-9]+m[0-9]+s$|^[0-9]+m[0-9]+s$'
like "permanent ban" "$(cs decisions list -o json | jq -r '[.[].decisions[]? | select(.scenario=="permanent test")][0].duration')" '^8759[0-9]h[0-9]+m[0-9]+s$'
eq "one simulated decision" "$(cs decisions list -o json | jq '[.[].decisions[]? | select(.simulated)] | length')" "1"
eq "two alerts share an IP: decisions list keeps one decision per IP" "$(cs decisions list -o json | jq '[.[].decisions[]?.value] | (length - (unique | length))')" "0"
eq "alerts with no active decision exist" "$(cs alerts list -o json | jq '[.[] | select((.decisions | map(select(.duration | startswith("-") | not)) | length) == 0)] | length >= 6')" "true"
eq "--since 24h and --since 7d differ" "$( [[ $(cs alerts list --since 24h -o json | jq length) -lt $(cs alerts list --since 7d -o json | jq length) ]] && echo yes)" "yes"
eq "engine alert has events with meta" "$(cs alerts inspect 12 -o json | jq -c '[(.events | length), (.events[0].meta | map(.key) | index("http_path") != null)]')" '[3,true]'
eq "alert JSON key set is the real one" "$(cs alerts inspect 12 -o json | jq -c 'keys')" '["capacity","created_at","decisions","events","events_count","id","kind","labels","leakspeed","machine_id","message","meta","remediation","scenario","scenario_hash","scenario_version","simulated","source","start_at","stop_at","uuid"]'
eq "bouncers" "$(cs bouncers list -o json | jq -c '[.[] | [.name, .type, .version, (.last_pull != null)]]')" '[["dcs-traefik-bouncer","crowdsec-traefik-bouncer","v1.4.4",true],["test-bouncer","","",false]]'
eq "machines" "$(cs machines list -o json | jq -c '.[0] | [.machineId, .isValidated, .version, .datasources]')" '["localhost",true,"v1.8.1-909b5157-docker",{"file":2}]'
eq "allowlists" "$(cs allowlists list -o json | jq -c '[.[] | [.name, (.items | length)]]')" '[["dcs",3],["vendor",1]]'
eq "allowlist item never expires => 0001 date" "$(cs allowlists inspect dcs -o json | jq -r '.items[0].expiration')" "0001-01-01T00:00:00.000Z"
eq "metrics top level keys" "$(cs metrics -o json | jq -c 'keys')" '["acquisition","alerts","appsec-challenge","appsec-challenge-infra","appsec-engine","appsec-rule","bouncers","decisions","lapi","lapi-bouncer","lapi-decisions","lapi-machine","parsers","scenarios","stash","whitelists"]'
eq "metrics acquisition reads" "$(cs metrics -o json | jq '.acquisition["file:/var/log/traefik/access.log"].reads')" "12841"
eq "capi status text" "$(cs capi status | sed -n 3p)" "You can successfully interact with Central API (CAPI)"
eq "lapi status text" "$(cs lapi status | tail -1)" "You can successfully interact with Local API (LAPI)"
eq "console status json" "$(cs console status -o json | jq -c '[.console.registered, .sharing_options.custom]')" "[true,true]"
eq "hub list has the 7 real sections" "$(cs hub list -o json 2>/dev/null | jq -c 'keys')" '["appsec-configs","appsec-rules","collections","contexts","parsers","postoverflows","scenarios"]'
eq "installed collections" "$(cs collections list -o json | jq -r '.collections | map(.name) | join(" ")')" "crowdsecurity/base-http-scenarios crowdsecurity/http-cve crowdsecurity/linux crowdsecurity/sshd crowdsecurity/traefik crowdsecurity/whitelist-good-actors"
eq "171 collections available" "$(cs collections list -a -o json | jq '.collections | length')" "171"
eq "one collection is outdated" "$(cs collections list -o json | jq -r '[.collections[] | select(.status | contains("update"))] | map(.name) | join(",")')" "crowdsecurity/sshd"

echo "== decisions: add / list / delete, allowlist rule"
init empty
eq "empty: decisions list -o json prints []" "$(cs decisions list -o json)" "[]"
eq "empty: alerts list -o json prints [] (no newline)" "$(cs alerts list -o json | od -An -c | tr -d ' \n')" "[]"
eq "empty: bouncers []" "$(cs bouncers list -o json)" "[]"
eq "empty: allowlists []" "$(cs allowlists list -o json)" "[]"
eq "empty: 6 installed collections" "$(cs collections list -o json | jq '.collections | length')" "6"
eq "empty: acquisition metrics empty" "$(cs metrics -o json | jq -c '.acquisition')" "{}"
out="$(cs decisions add -i 192.0.2.10 -d 1h -R 'first test' 2>&1)"; eq "add: message" "$out" 'level=info msg="Decision successfully added"'
id1=$(cs decisions list -o json | jq '.[0].decisions[0].id'); [[ "$id1" -ge 15010 ]] && ok "decision ids start at 15010 ($id1)" || bad "decision ids start at 15010" "$id1"
eq "add: listed" "$(cs decisions list -o json | jq -c '.[0] | [.decisions[0].value, .decisions[0].scope, .decisions[0].type, .decisions[0].origin, .scenario, .kind]')" '["192.0.2.10","Ip","ban","cscli","first test","cscli"]'
like "add: 1h => 59m5x remaining" "$(cs decisions list -o json | jq -r '.[0].decisions[0].duration')" '^59m[0-9]+s$'
cs decisions add -r 192.0.2.128/25 -d 7d -t captcha -R range >/dev/null 2>&1
eq "add 7d range captcha" "$(cs decisions list -o json | jq -c '.[0].decisions[0] | [.scope, .type, (.duration | startswith("167h"))]')" '["Range","captcha",true]'
eq "add default 4h + default reason" "$(cs decisions add -i 192.0.2.11 >/dev/null 2>&1; cs decisions list -o json | jq -r '.[0] | [.decisions[0].duration[0:3], .scenario] | join("|")')" "3h5|manual 'ban' from 'localhost'"
out="$(cs decisions add -i 192.0.2.12 -d 1w 2>&1)"; like "add: 1w is refused with the LAPI text" "$out" 'unknown unit "w" in duration "1w": unable to parse duration'
like "add: bad IP" "$(cs decisions add -i 999.1.1.1 2>&1)" "Error: cscli decisions add: 999.1.1.1 is not a valid ip"
eq "list --ip finds the containing range too" "$(cs decisions list --ip 192.0.2.130 -o json | jq -r '.[0].decisions[0].value')" "192.0.2.128/25"
eq "list -o raw header" "$(cs decisions list -o raw | head -1)" "id,source,ip,reason,action,country,as,events_count,expiration,simulated,alert_id"
eq "delete by ip reports and removes" "$(cs decisions delete -i 192.0.2.10 2>&1)" 'level=info msg="1 decision(s) deleted"'
eq "delete again: 0 deleted, rc 0" "$(cs decisions delete -i 192.0.2.10 2>&1; echo $?)" $'level=info msg="0 decision(s) deleted"\n0'
like "delete unknown id" "$(cs decisions delete --id 999999 2>&1)" "decision with id '999999' doesn't exist: unable to delete"
eq "deleted decision stays in its alert with a non-positive duration" "$(cs alerts list -o json | jq -r '[.[] | select(.scenario=="first test")][0].decisions[0].duration | test("^-?[0-9]+s$")')" "true"
cs allowlists create dcs -d 'DCS test allowlist' >/dev/null
out="$(cs allowlists add dcs 203.0.113.9 -d office 2>&1)"; eq "allowlists add" "$out" "added 1 values to allowlist dcs"
like "add of an allowlisted IP is refused" "$(cs decisions add -i 203.0.113.9 2>&1)" 'Error: cscli decisions add: 203.0.113.9 is allowlisted by item 203.0.113.9 from dcs \(office\), use --bypass-allowlist to add the decision anyway'
eq "refused add creates nothing" "$(cs decisions list --ip 203.0.113.9 -o json)" "[]"
cs decisions add -i 203.0.113.9 -B >/dev/null 2>&1; eq "-B bypasses the allowlist" "$(cs decisions list --ip 203.0.113.9 -o json | jq length)" "1"
cs decisions add -i 198.51.100.7 -d 1h >/dev/null 2>&1
out="$(cs allowlists add dcs 198.51.100.0/24 -e 30d 2>&1)"; eq "allowlists add sweeps every covered decision (the -B one as well)" "$out" $'added 1 values to allowlist dcs\n2 decisions deleted by allowlists'
eq "range item deleted the covered decision" "$(cs decisions list --ip 198.51.100.7 -o json)" "[]"
eq "allowlists check" "$(cs allowlists check 198.51.100.77 8.8.8.8)" $'198.51.100.77 is allowlisted by item 198.51.100.0/24 from dcs\n8.8.8.8 is not allowlisted'
eq "allowlists add of an existing value" "$(cs allowlists add dcs 203.0.113.9 2>&1)" $'level=warning msg="value 203.0.113.9 already in allowlist"\nno new values for allowlist'
eq "allowlists remove has no newline" "$(cs allowlists remove dcs 203.0.113.9 | od -An -c | tr -d ' \n')" "removed1valuesfromallowlistdcs"
cs decisions delete --all >/dev/null 2>&1
eq "after delete --all: []" "$(cs decisions list -o json)" "[]"
mock --mock-set empty_json=null
eq "empty_json=null: decisions list prints null" "$(cs decisions list -o json)" "null"
mock --mock-set empty_json=auto

echo "== import from stdin, bouncers, simulation"
out="$(printf '[{"duration":"2h","reason":"imp","scope":"ip","type":"ban","value":"198.18.0.1"},{"duration":"1h","scope":"Range","type":"captcha","value":"198.18.1.0/24"}]' | csi decisions import -i - --format json 2>&1)"
eq "import json: messages" "$out" $'Parsing json\nImported 2 decisions'
eq "import: decisions have origin cscli-import" "$(cs decisions list -o json | jq -c '[.[].decisions[] | .origin] | unique')" '["cscli-import"]'
eq "import: one alert 'import stdin: 2 IPs'" "$(cs alerts list -o json | jq -r '.[0].scenario')" "import stdin: 2 IPs"
eq "import values" "$(printf '198.18.9.1\n198.18.9.2\n' | csi decisions import -i - --format values -d 3h 2>&1 | tail -1)" "Imported 2 decisions"
like "import without a format" "$(printf 'x' | csi decisions import -i - 2>&1)" "unable to guess format from file extension"
key="$(cs bouncers add mybouncer -o raw)"; eq "bouncer key is 43 chars" "${#key}" "43"
like "bouncer key alphabet (std base64, no padding)" "$key" '^[A-Za-z0-9+/]{43}$'
like "duplicate bouncer" "$(cs bouncers add mybouncer 2>&1)" "unable to create bouncer: bouncer mybouncer already exists"
eq "bouncer listed, never pulled" "$(cs bouncers list -o json | jq -c '.[0] | [.name, .last_pull, .type]')" '["mybouncer",null,""]'
eq "bouncer delete message" "$(cs bouncers delete mybouncer 2>&1)" "level=info msg=\"bouncer 'mybouncer' deleted successfully\""
like "delete unknown bouncer" "$(cs bouncers delete nobody 2>&1)" "unable to delete bouncer nobody: ent: bouncer not found"
eq "simulation status (stock)" "$(cs simulation status)" "global simulation: disabled"
eq "simulation enable" "$(cs simulation enable crowdsecurity/http-probing)" 'simulation mode for "crowdsecurity/http-probing" enabled'
eq "simulation.yaml was rewritten like yaml.v3 does" "$(docker exec CrowdSec cat /etc/crowdsec/simulation.yaml)" $'simulation: false\nexclusions:\n    - crowdsecurity/http-probing'
eq "simulation status lists it" "$(cs simulation status | tail -1)" "  - crowdsecurity/http-probing"
eq "simulation disable" "$(cs simulation disable crowdsecurity/http-probing)" 'simulation mode for "crowdsecurity/http-probing" disabled'
like "unknown scenario is only logged" "$(cs simulation enable crowdsecurity/nope 2>&1; echo rc=$?)" 'does not exist or is not a scenario.*rc=0'

echo "== hub"
like "install shows the action plan" "$(cs collections install crowdsecurity/nginx)" $'^Action plan:\n.*download\n collections: crowdsecurity/nginx \(0.3\)'
eq "installed collection is listed" "$(cs collections list -o json | jq -r '[.collections[].name] | index("crowdsecurity/nginx") != null')" "true"
eq "its members are enabled too" "$(cs scenarios list -o json | jq -r '[.scenarios[].name] | index("crowdsecurity/nginx-req-limit-exceeded") != null')" "true"
eq "second install is a no-op" "$(cs collections install crowdsecurity/nginx)" "Nothing to install or remove."
like "unknown collection suggests a name" "$(cs collections install crowdsecurity/ngin 2>&1)" "can't find 'crowdsecurity/ngin' in collections, did you mean 'crowdsecurity/nginx'\?"
like "remove disables the members" "$(cs collections remove crowdsecurity/nginx)" $'❌ disable\n collections: crowdsecurity/nginx\n scenarios: crowdsecurity/nginx-req-limit-exceeded\n parsers: crowdsecurity/nginx-logs'
eq "removed: gone from the list" "$(cs collections list -o json | jq -r '[.collections[].name] | index("crowdsecurity/nginx")')" "null"
like "hub update" "$(cs hub update)" "Downloading /etc/crowdsec/hub/.index.json"

echo "== hub tree, inspect, human tables"
init empty
tree="$(cs hub list 2>/dev/null)"
like "hub list: the Details column" "$tree" 'Type +Name +📦 Status +Version +Details'
like "hub list: a sub-collection hangs off its parent" "$tree" $'crowdsecurity/linux +✔️  up-to-date  0.4 +3 parser\\(s\\) / 2 collection\\(s\\) *\n collections  ├─ crowdsecurity/sshd'
like "hub list: the last child gets the corner" "$tree" '└─ crowdsecurity/whitelist-good-actors'
like "hub list: nested levels are indented" "$tree" $'└─ crowdsecurity/base-http-scenarios[^\n]*\n collections     └─ crowdsecurity/http-cve'
like "hub list: items no collection accounts for come after a rule" "$tree" $'-\n parsers +crowdsecurity/cri-logs'
eq "hub list -a: every item of the index in one table" "$([[ $(cs hub list -a 2>/dev/null | wc -l) -gt 1300 ]] && echo yes)" "yes"
like "hub list -a: not-installed items" "$(cs hub list -a 2>/dev/null | sed -n 5p)" '🚫  not-installed'
insp="$(cs collections inspect crowdsecurity/linux)"
like "inspect: YAML with the dependencies" "$insp" $'version: "0.4"\ndependencies:\n  parsers:\n    - crowdsecurity/syslog-logs'
like "inspect: a description with a colon is quoted" "$insp" "description: 'core linux support : syslog\\+geoip\\+ssh'"
like "inspect: installed items end with the metrics label" "$insp" $'local: false\n\nCurrent metrics: $'
nolike "inspect -o raw: no metrics label" "$(cs collections inspect crowdsecurity/linux -o raw)" 'Current metrics'
like "inspect: an item nobody lists has no belongs_to" "$(cs parsers inspect crowdsecurity/whitelists)" $'tainted: false\ninstalled: true'
eq "inspect -o json: one document per name" "$(cs parsers inspect crowdsecurity/whitelists crowdsecurity/syslog-logs -o json | jq -s 'length')" "2"
like "inspect: an unknown name fails after the known ones were printed" "$(cs parsers inspect crowdsecurity/whitelists crowdsecurity/nope 2>&1)" $'installed: true\nlocal: false\n\nCurrent metrics: \nError: cscli parsers inspect: can\'t find \'crowdsecurity/nope\' in parsers'
inst="$(cs collections install crowdsecurity/exchange 2>&1 | grep -E '^(downloading|enabling)')"
eq "install: contents first, in the order the collection lists them" "$(printf '%s\n' "$inst" | sed -n '1p;4p;11p')" $'downloading parsers:crowdsecurity/exchange-smtp-logs\ndownloading scenarios:crowdsecurity/exchange-bf\ndownloading collections:crowdsecurity/exchange'
init empty
cs collections install crowdsecurity/freebsd >/dev/null 2>&1
cs collections remove crowdsecurity/linux >/dev/null 2>&1
like "remove: items another installed collection lists directly stay" "$(cs parsers list -o raw)" 'crowdsecurity/syslog-logs,enabled'
cs collections remove crowdsecurity/freebsd >/dev/null 2>&1
nolike "remove: the last collection to list them takes them along" "$(cs parsers list -o raw)" 'crowdsecurity/syslog-logs'
init empty
like "machines inspect: the boxed table" "$(cs machines inspect localhost)" $'\\| Machine: localhost +\\|\n\\+-+\\+-+\\+\n\\| IP Address +\\| 127.0.0.1'
like "machines inspect: unknown machine" "$(cs machines inspect nobody 2>&1)" "unable to read machine data 'nobody': user 'nobody': user doesn't exist"
eq "machines list -o json: no last_push before the machine pushed an alert" "$(cs machines list -o json | jq '.[0] | has("last_push")')" "false"
cs decisions add -i 192.0.2.7 >/dev/null 2>&1
eq "a push sets last_push" "$(cs machines list -o json | jq '.[0] | has("last_push")')" "true"
cs allowlists create dcs -d "DCS test allowlist" >/dev/null 2>&1; cs allowlists add dcs 203.0.113.9 -d office -e 30d >/dev/null 2>&1
eq "allowlists inspect -o raw: one CSV row per item" "$(cs allowlists inspect dcs -o raw | cut -d, -f1-5 | sed 's/,20[0-9-]*T.*//')" $'name,description,value,comment,expiration\ndcs,DCS test allowlist,203.0.113.9,office'
like "bouncers inspect: raw is refused" "$(cs bouncers add b1 -o raw >/dev/null; cs bouncers inspect b1 -o raw 2>&1)" "output format 'raw' not supported for this command"
eq "bouncers inspect: no newline after the frame" "$(cs bouncers inspect b1 | tail -c 1 | od -An -c | tr -d ' ')" "-"
like "config show" "$(cs config show)" $'Local API Server:\n  - Listen URL +: 0.0.0.0:8080'

init data
mock --mock-set hub_cascade=1
eq "hub_cascade=1: a collection is flagged when a member is behind" "$(cs collections list -o json | jq -r '[.collections[] | select(.status | contains("update"))] | map(.name) | join(",")')" "crowdsecurity/linux,crowdsecurity/sshd"
init empty
like "remove --purge: the purge block and the purging lines" "$(cs collections remove crowdsecurity/traefik --purge 2>&1)" $'🗑 purge \\(delete source\\)\n collections: crowdsecurity/base-http-scenarios, crowdsecurity/http-cve, crowdsecurity/traefik'
eq "remove --purge: gone from the hub directory too" "$(cs collections list -a -o json | jq -r '.collections[] | select(.name == "crowdsecurity/traefik") | .local_version')" ""
eq "remove without a name" "$(cs collections remove 2>&1)" "Error: cscli collections remove: specify at least one collection to remove or '--all'"
like "a collection another collection lists needs --force" "$(cs collections remove crowdsecurity/sshd 2>&1)" 'crowdsecurity/sshd belongs to collections: \[crowdsecurity/linux\]'

echo "== metrics tables"
init data
tables="$(cs metrics)"
like "metrics: a titled table per section" "$tables" $'\\| Acquisition Metrics +\\|\n\\+-+\\+-+\\+'
like "metrics: big numbers get a unit, zeros a dash" "$tables" '\| file:/var/log/traefik/access.log +\| 12.84k +\| 12.51k +\| 334 +\| 9.12k +\| - +\|'
like "metrics --no-unit prints the plain numbers" "$(cs metrics --no-unit)" '\| 12841 +\| 12507 +\| 334 +\| 9120 '
like "metrics: the Local API tables come from the same counters" "$tables" '\| /v1/decisions/stream +\| GET +\| 1380 +\|'
eq "metrics show engine: five sections" "$(cs metrics show engine | grep -c -E '^\| (Acquisition|Parser|Scenario|Whitelist) Metrics|^\| Parser Stash Metric')" "5"
like "metrics show stash: an explicit request shows the empty table (title wrapped)" "$(cs metrics show stash)" $'\\| Parser Stash Metric \\|\n\\| s +\\|'
eq "metrics show bouncers: nothing to show" "$(cs metrics show bouncers)" "No bouncer metrics found."
eq "metrics show: unknown type" "$(cs metrics show nope 2>&1)" "Error: cscli metrics show: unknown metrics type: nope"
eq "metrics -o raw is refused" "$(cs metrics -o raw 2>&1)" "Error: cscli metrics: output format 'raw' not supported for this command"
eq "metrics list -o json: the 16 types" "$(cs metrics list -o json | jq length)" "16"
like "metrics list: wrapped descriptions" "$(cs metrics list)" $'\\| acquisition +\\| Acquisition Metrics +\\| Measures the lines read, parsed, and unparsed per +\\|\n\\| +\\| +\\| datasource. Zero read lines indicate a misconfigured or +\\|'
init empty

echo "== files: docker cp / exec, crowdsec -t"
printf 'hello\n' > "$T/hello.txt"
docker cp "$T/hello.txt" CrowdSec:/tmp/hello.txt
eq "cp in, exec cat" "$(docker exec CrowdSec cat /tmp/hello.txt)" "hello"
docker cp CrowdSec:/tmp/hello.txt "$T/back.txt"; eq "cp out" "$(cat "$T/back.txt")" "hello"
like "cp into a missing directory" "$(docker cp "$T/hello.txt" CrowdSec:/no/such/dir/x 2>&1)" "Could not find the file /no/such/dir in container CrowdSec"
eq "exec test -f" "$(docker exec CrowdSec test -f /tmp/hello.txt; echo $?)$(docker exec CrowdSec test -f /tmp/none; echo $?)" "01"
docker exec CrowdSec mkdir -p /tmp/a/b; docker exec CrowdSec rm -f /tmp/hello.txt
eq "mkdir -p / rm -f" "$(docker exec CrowdSec test -d /tmp/a/b; echo $?)$(docker exec CrowdSec test -f /tmp/hello.txt; echo $?)" "01"
eq "ls of a directory" "$(docker exec CrowdSec ls /etc/crowdsec/notifications | tr '\n' ' ')" "email.yaml file.yaml http.yaml sentinel.yaml slack.yaml splunk.yaml "
eq "sh -c is unsupported" "$(docker exec CrowdSec sh -c 'echo hi' 2>&1; echo $?)" $'mock-crowdsec: unsupported: exec CrowdSec sh -c echo hi\n1'
ctest() { docker cp "$1" CrowdSec:/tmp/p.yaml; printf '%s\n' "profiles_path: /tmp/p.yaml" > /dev/null; docker exec CrowdSec cat /etc/crowdsec/config.yaml | sed -e 's#profiles_path: .*#profiles_path: /tmp/p.yaml#' > "$T/cfg.yaml"; docker cp "$T/cfg.yaml" CrowdSec:/tmp/cfg.yaml; docker exec CrowdSec crowdsec -t -c /tmp/cfg.yaml 2>&1; }
mkprofile() { printf '%s\n' 'name: x' 'filters:' '  - Alert.Remediation == true' 'decisions:' '  - type: ban' '    duration: 4h' "$@"; }
printf 'name: x\nfilters:\n  - Alert.Remediation == true\ndecisions:\n  - type: ban\n    duration: 4h\n   bad indent: [\n' > "$T/bad1.yaml"
like "crowdsec -t: bad YAML" "$(ctest "$T/bad1.yaml")" 'level=fatal msg="while loading profiles for LAPI: while decoding /tmp/p.yaml: \[7:4\] value is not allowed in this context"'
mkprofile > "$T/ok.yaml"; sed -i 's/4h/4 hours please/' "$T/ok.yaml"
like "crowdsec -t: bad duration" "$(ctest "$T/ok.yaml")" "failed to compile profiles: error parsing duration '4 hours please' of x: time: unknown unit \\\\\" hours please\\\\\" in duration \\\\\"4 hours please\\\\\""
mkprofile 'unknown_key: 1' > "$T/bad5.yaml"
like "crowdsec -t: unknown key" "$(ctest "$T/bad5.yaml")" 'yaml: unmarshal errors:\\n  line 7: field unknown_key not found in type csconfig.ProfileCfg'
printf 'name: x\nfilters:\n  - Alert.Remediation === true &&&\ndecisions:\n  - type: ban\n    duration: 4h\n' > "$T/bad3.yaml"
like "crowdsec -t: bad filter" "$(ctest "$T/bad3.yaml")" 'error compiling filter of .x.: unexpected token Operator\(\\"=\\"\) \(1:21\)'
printf 'name: x\nfilters:\n  - Alert.Remediation == true\ndecisions:\n  - type: ban\n    duration: 4h\nduration_expr: Sprintf(broken\n' > "$T/bad4.yaml"
like "crowdsec -t: bad duration_expr" "$(ctest "$T/bad4.yaml")" 'error compiling duration_expr of x: unexpected token EOF \(1:14\)'
mkprofile 'notifications:' '  - no_such_plugin' > "$T/bad6.yaml"
like "crowdsec -t: unknown notification plugin" "$(ctest "$T/bad6.yaml")" "plugin broker: loading config: config file for plugin no_such_plugin not found"
docker exec CrowdSec cat /etc/crowdsec/profiles.yaml > "$T/stock.yaml"
out="$(ctest "$T/stock.yaml")"; rcv=$?; like "crowdsec -t: the stock profiles pass" "$out" 'level=info msg="Configuration test done"'
out="$(ctest "$T/bad1.yaml" >/dev/null; docker exec CrowdSec crowdsec -t -c /tmp/cfg.yaml >/dev/null 2>&1; echo $?)"; eq "crowdsec -t exits 1 on a bad file" "$out" "1"
eq "config test has no side effects (no restart, still running)" "$(docker inspect --format '{{.State.Status}} {{.RestartCount}}' CrowdSec)" "running 0"

echo "== restart / crash hook / logs"
printf '%s\n' "$(cat "$T/stock.yaml")" '# fake-crowdsec: crash on start' > "$T/hook.yaml"
docker cp "$T/hook.yaml" CrowdSec:/etc/crowdsec/profiles.yaml
like "the crash hook passes crowdsec -t" "$(docker exec CrowdSec crowdsec -t 2>&1)" 'Configuration test done'
eq "restart prints the name" "$(docker restart CrowdSec)" "CrowdSec"
eq "hook: restart ends in a crash loop" "$(docker inspect --format '{{.State.Status}} {{.RestartCount}}' CrowdSec)" "restarting 1"
like "crash loop: fatal log line" "$(docker logs --tail 2 CrowdSec 2>&1)" 'level=fatal'
docker cp "$T/stock.yaml" CrowdSec:/etc/crowdsec/profiles.yaml
docker restart CrowdSec >/dev/null
eq "fixed file: running again" "$(docker inspect --format '{{.State.Status}}' CrowdSec)" "running"
docker cp "$T/bad1.yaml" CrowdSec:/etc/crowdsec/profiles.yaml
docker restart CrowdSec >/dev/null
eq "invalid live profiles: restart crash-loops too" "$(docker inspect --format '{{.State.Status}}' CrowdSec)" "restarting"
docker cp "$T/stock.yaml" CrowdSec:/etc/crowdsec/profiles.yaml
docker start CrowdSec >/dev/null
eq "start after fixing" "$(docker inspect --format '{{.State.Status}}' CrowdSec)" "running"
mock --mock-set restart_fails=1
docker restart CrowdSec >/dev/null
eq "restart_fails => crash loop once" "$(docker inspect --format '{{.State.Status}}' CrowdSec)" "restarting"
docker restart CrowdSec >/dev/null
eq "restart_fails is cleared afterwards" "$(docker inspect --format '{{.State.Status}}' CrowdSec)" "running"
docker stop CrowdSec >/dev/null
eq "stop => exited 0" "$(docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' CrowdSec)" "exited 0"
docker start CrowdSec >/dev/null
docker kill -s HUP CrowdSec >/dev/null
like "HUP reloads" "$(docker logs --tail 3 CrowdSec 2>&1)" 'Reload is finished'
lines_out=$(docker logs CrowdSec 2>/dev/null | wc -l); lines_err=$(docker logs CrowdSec 2>&1 >/dev/null | wc -l)
[[ "$lines_out" -ge 1 && "$lines_err" -ge 5 ]] && ok "logs: entrypoint on stdout, crowdsec lines on stderr" || bad "logs streams" "stdout=$lines_out stderr=$lines_err"
like "logs -t prefix" "$(docker logs -t --tail 1 CrowdSec 2>&1)" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z '
like "LAPI access lines are in the log after a mutation" "$(cs decisions add -i 192.0.2.99 >/dev/null 2>&1; docker logs --tail 5 CrowdSec 2>&1)" 'POST /v1/alerts HTTP/1.1 200'

echo "== lapi_down, docker_down, tick, knobs, parallel calls"
mock --mock-set lapi_down=1
out="$(cs decisions list -o json 2>&1)"; rcv=$?
eq "lapi_down: decisions list fails" "$rcv" "1"
like "lapi_down: connection refused" "$out" "connect: connection refused"
eq "lapi_down: version still works" "$(cs version | head -1)" "version: v1.8.1-909b5157"
eq "lapi_down: hub commands work" "$(cs hub types | head -1)" "- parsers"
eq "lapi_down: bouncers fail (spec)" "$(cs bouncers list -o json >/dev/null 2>&1; echo $?)" "1"
mock --mock-set lapi_down=2
eq "lapi_down=2: database-direct commands work" "$(cs bouncers list -o json >/dev/null 2>&1; echo $?)" "0"
eq "lapi_down=2: LAPI clients still fail" "$(cs alerts list -o json >/dev/null 2>&1; echo $?)" "1"
mock --mock-set lapi_down=0
eq "lapi_down=0: back" "$(cs decisions list -o json >/dev/null 2>&1; echo $?)" "0"
mock --mock-set docker_down=1
out="$(docker ps 2>&1)"; rcv=$?
eq "docker_down: rc 1" "$rcv" "1"
like "docker_down: message" "$out" "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
mock --mock-set docker_down=0
cs decisions add -i 192.0.2.50 -d 10m >/dev/null 2>&1
before=$(cs decisions list --ip 192.0.2.50 -o json | jq length)
mock --mock-tick 601
after=$(cs decisions list --ip 192.0.2.50 -o json | jq length)
eq "tick expires decisions" "$before/$after" "1/0"
eq "expired decision remains visible in alerts list with a negative duration" "$(cs alerts list -o json | jq -r '[.[] | select(.source.value=="192.0.2.50")][0].decisions[0].duration')" "-1s"
ids=$(for i in $(seq 1 16); do echo 192.0.2.$((100 + i)); done)
for ip in $ids; do cs decisions add -i "$ip" -d 30m >/dev/null 2>&1 & done; wait
eq "16 parallel adds all landed" "$(cs decisions list -o json | jq '[.[].decisions[] | select(.value | startswith("192.0.2.1"))] | length')" "16"
eq "and got unique ids" "$(cs decisions list -o json | jq '[.[].decisions[].id] | (length - (unique | length))')" "0"
mock --mock-set cscli_slow_ms=300
s=$(date +%s%N); cs version >/dev/null; e=$(date +%s%N)
[[ $(( (e - s) / 1000000 )) -ge 280 ]] && ok "cscli_slow_ms sleeps" || bad "cscli_slow_ms" "$(( (e - s) / 1000000 )) ms"
mock --mock-set cscli_slow_ms=0
like "unknown knob" "$(mock --mock-set nope=1 2>&1)" "unknown knob"
like "--mock-dump is JSON" "$(mock --mock-dump | jq -r .preset)" "empty"
[[ $(wc -l < "$FAKE_CS_DIR/calls.log") -ge 50 ]] && ok "calls.log records every invocation" || bad "calls.log"
like "calls.log format (epoch<TAB>argv)" "$(grep 'exec CrowdSec cscli' "$FAKE_CS_DIR/calls.log" | tail -1)" $'^[0-9]+(\\.[0-9]+)?\texec CrowdSec cscli '
[[ -s "$FAKE_CS_DIR/unsupported.log" ]] && ok "unsupported.log has the sh -c call" || bad "unsupported.log empty"

echo "== notifications / discord"
init data
eq "stock: no active notification" "$(cs notifications list -o raw | tail -n +2 | awk -F, '{print $3}' | sort -u | tr -d '\n')" ""
mock --mock-set discord=1
eq "discord=1: http_default is referenced by both profiles" "$(cs notifications list -o raw | grep '^http_default')" 'http_default,http,"default_ip_remediation, default_range_remediation"'
like "notifications list (human) marks the active plugin" "$(cs notifications list | sed -n 4p)" '^ ✔️ +http_default +http +default_ip_remediation'
like "discord test: registered + killed" "$(cs notifications test http_default 2>&1)" 'level=info msg="registered plugin http_default".*level=info msg="killing all plugins"'
sed -e 's#^url:.*#url: http://127.0.0.1:9/dcs-validate#' "$FAKE_CS_DIR/rootfs/etc/crowdsec/notifications/http.yaml" > "$T/refused.yaml"
docker cp "$T/refused.yaml" CrowdSec:/etc/crowdsec/notifications/http.yaml
out="$(cs notifications test http_default 2>&1)"; rcv=$?
like "refused port: connection refused lines" "$out" 'level=error msg="Failed to make HTTP request : Post .*127.0.0.1:9/dcs-validate.*connect: connection refused'
eq "notifications test always exits 0" "$rcv" "0"
printf 'type: http\nname: http_default\nlog_level: info\nformat: |\n  {\n    "content": {{ .Nope | toJsonBroken }}\n  }\nurl: http://127.0.0.1:9/x\nmethod: POST\n' > "$T/broken.yaml"
docker cp "$T/broken.yaml" CrowdSec:/etc/crowdsec/notifications/http.yaml
like "broken template" "$(cs notifications test http_default 2>&1)" 'level=error msg="format alerts for notification: template: :2: function \\"toJsonBroken\\" not defined" plugin:=http_default'

echo "== old (1.6.5), docker odds and ends, determinism"
init old
eq "old: version" "$(cs version | head -1)" "version: v1.6.5-67dcea0b"
like "old: no allowlists command" "$(cs allowlists list 2>&1)" 'unknown command "allowlists" for "cscli"'
like "old: no --bypass-allowlist" "$(cs decisions add -i 192.0.2.1 -B 2>&1)" "unknown shorthand flag: 'B'"
cs decisions delete --all >/dev/null 2>&1
eq "old: empty decisions list prints null" "$(cs decisions list -o json)" "null"
like "old: hub install prints the old messages" "$(cs collections install crowdsecurity/nginx 2>&1)" "Run 'systemctl reload crowdsec' for the new configuration to be effective"
init data --seed 7
a="$(cs bouncers add k1 -o raw)"; init data --seed 7; b="$(cs bouncers add k1 -o raw)"; init data --seed 8; c="$(cs bouncers add k1 -o raw)"
eq "same seed => same API key" "$a" "$b"
[[ "$a" != "$c" ]] && ok "another seed => another key" || bad "another seed"
eq "docker compose ls" "$(docker compose ls --format json)" "[]"
eq "docker compose up is unsupported" "$(docker compose up -d 2>&1 | head -1)" "mock-crowdsec: unsupported: compose up -d"
eq "docker ps -q" "$(docker ps -q --filter name=CrowdSec | wc -c)" "13"
like "docker info is JSON-able" "$(docker info --format '{{.ServerVersion}}')" "29.1.3"
init data
before="$(cs bouncers list -o json | jq -r '.[0].last_pull')"; mock --mock-tick 600
after="$(cs bouncers list -o json | jq -r '.[0].last_pull')"
eq "the tick moves last_pull back for a consumer with a real clock" "$([[ "$before" == "$after" ]] && echo same || echo aged)" "aged"
eq "and the printed time is 10 minutes older than now" "$(python3 -c "import sys,datetime as d; t=d.datetime.strptime(sys.argv[1][:19],'%Y-%m-%dT%H:%M:%S').replace(tzinfo=d.timezone.utc); print(560 < (d.datetime.now(d.timezone.utc)-t).total_seconds() < 640)" "$after")" "True"

echo
if [[ "$FAILN" -eq 0 ]]; then echo "mock-crowdsec selftest: $PASS checks passed"; exit 0; fi
echo "mock-crowdsec selftest: $FAILN FAILED, $PASS passed"; exit 1

#!/usr/bin/env python3
"""A tiny Proxmox VE API stand-in for tests: /api2/json/version, /nodes, /cluster/resources,
/cluster/tasks, /nodes/{n}/{qemu|lxc}/{id}/status/current, /config, the guest-agent and
container interfaces (for the fleet scan) and POST status/{action}.
Checks the PVEAPIToken header. Usage: mock-pve.py PORT TOKEN_ID TOKEN_SECRET [statefile]"""
import http.server, json, sys, time, urllib.parse, pathlib

PORT = int(sys.argv[1]); TOKEN = f"PVEAPIToken={sys.argv[2]}={sys.argv[3]}"
STATE = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 else None
VMS = {
    100: {'vmid': 100, 'name': 'media-services', 'type': 'qemu', 'node': 'pve', 'status': 'running', 'cpu': 0.12, 'maxcpu': 4, 'mem': 3221225472, 'maxmem': 8589934592, 'disk': 0, 'maxdisk': 68719476736, 'uptime': 86400, 'tags': 'docker;media'},
    101: {'vmid': 101, 'name': 'networking-security', 'type': 'qemu', 'node': 'pve', 'status': 'running', 'cpu': 0.03, 'maxcpu': 2, 'mem': 1073741824, 'maxmem': 4294967296, 'disk': 0, 'maxdisk': 34359738368, 'uptime': 4000, 'tags': 'docker'},
    200: {'vmid': 200, 'name': 'dns', 'type': 'lxc', 'node': 'pve', 'status': 'stopped', 'cpu': 0, 'maxcpu': 1, 'mem': 0, 'maxmem': 536870912, 'disk': 0, 'maxdisk': 8589934592, 'uptime': 0, 'tags': ''},
    900: {'vmid': 900, 'name': 'template-debian', 'type': 'qemu', 'node': 'pve', 'status': 'stopped', 'template': 1, 'cpu': 0, 'maxcpu': 1, 'mem': 0, 'maxmem': 1073741824},
}
TASKS = []
# what the guests answer when the hub scans them: VM 100 claims the loopback address (a DCS
# listener on 127.0.0.1 is "found" there), 101 has no guest agent, the container is unroutable
UUIDS = {100: '11111111-2222-3333-4444-555555555555', 101: '22222222-3333-4444-5555-666666666666'}
AGENT_IPS = {100: ['127.0.0.1']}
LXC_IPS = {200: '10.255.255.1'}
if STATE and STATE.exists():
    try:
        for k, v in json.loads(STATE.read_text()).items(): VMS[int(k)]['status'] = v
    except Exception: pass

def save():
    if STATE: STATE.write_text(json.dumps({k: v['status'] for k, v in VMS.items()}))

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def _auth(self):
        if self.headers.get('Authorization') != TOKEN: self._send(401, {'message': 'authentication failure', 'data': None}); return False
        return True
    def do_GET(self):
        if not self._auth(): return
        p = urllib.parse.urlparse(self.path); path = p.path; q = urllib.parse.parse_qs(p.query)
        if path == '/api2/json/version': return self._send(200, {'data': {'version': '8.3.0', 'release': '8.3', 'repoid': 'mock'}})
        if path == '/api2/json/nodes': return self._send(200, {'data': [{'node': 'pve', 'status': 'online', 'cpu': 0.08, 'maxcpu': 16, 'mem': 17179869184, 'maxmem': 68719476736, 'disk': 42949672960, 'maxdisk': 214748364800, 'uptime': 900000, 'level': ''}]})
        if path == '/api2/json/cluster/resources': return self._send(200, {'data': [dict(v, id=f"{v['type']}/{v['vmid']}") for v in VMS.values()]})
        if path == '/api2/json/cluster/tasks': return self._send(200, {'data': TASKS[-30:]})
        parts = path.split('/')
        if len(parts) >= 8 and parts[3] == 'nodes' and parts[5] in ('qemu', 'lxc'):
            vmid = int(parts[6]); vm = VMS.get(vmid)
            if not vm: return self._send(500, {'message': f"Configuration file 'nodes/pve/{parts[5]}-server/{vmid}.conf' does not exist", 'data': None})
            if parts[7] == 'status' and parts[8:9] == ['current']:
                return self._send(200, {'data': dict(vm, qmpstatus=vm['status'], cpus=vm['maxcpu'], netin=1234, netout=5678, diskread=0, diskwrite=0, agent=1, ha={'managed': 0})})
            if parts[7] == 'config':
                cfg = {'name': vm['name'], 'cores': vm['maxcpu'], 'memory': vm['maxmem'] // 1048576, 'ostype': 'l26', 'onboot': 1, 'description': 'mock', 'net0': 'virtio=DE:AD:BE:EF:00:01,bridge=vmbr0', 'bootdisk': 'scsi0'}
                if vm['type'] == 'qemu': cfg['smbios1'] = f"uuid={UUIDS.get(vmid, '00000000-0000-0000-0000-000000000000')}"
                return self._send(200, {'data': cfg})
            # guest addresses, as the hub's scan asks for them
            if parts[5] == 'qemu' and parts[7:10] == ['agent', 'network-get-interfaces']:
                if vm['status'] != 'running' or vmid not in AGENT_IPS: return self._send(500, {'message': 'QEMU guest agent is not running', 'data': None})
                return self._send(200, {'data': {'result': [{'name': 'lo', 'ip-addresses': [{'ip-address': '127.0.0.1', 'ip-address-type': 'ipv4'}]}] + [{'name': 'eth0', 'hardware-address': 'de:ad:be:ef:00:01', 'ip-addresses': [{'ip-address': ip, 'ip-address-type': 'ipv4'} for ip in AGENT_IPS[vmid]] + [{'ip-address': 'fe80::1', 'ip-address-type': 'ipv6'}]}]}})
            if parts[5] == 'lxc' and parts[7] == 'interfaces':
                if vm['status'] != 'running': return self._send(500, {'message': 'CT not running', 'data': None})
                return self._send(200, {'data': [{'name': 'lo', 'inet': '127.0.0.1/8'}, {'name': 'eth0', 'hwaddr': 'BC:24:11:00:00:01', 'inet': f"{LXC_IPS.get(vmid, '10.255.255.1')}/24"}]})
        self._send(501, {'message': f'not mocked: {path}', 'data': None})
    def do_POST(self):
        if not self._auth(): return
        parts = urllib.parse.urlparse(self.path).path.split('/')
        if len(parts) >= 9 and parts[3] == 'nodes' and parts[5] in ('qemu', 'lxc') and parts[7] == 'status':
            vmid = int(parts[6]); action = parts[8]; vm = VMS.get(vmid)
            if not vm: return self._send(500, {'message': 'no such vm', 'data': None})
            if action in ('start', 'resume'): vm['status'] = 'running'; vm['uptime'] = 1
            elif action in ('stop', 'shutdown'): vm['status'] = 'stopped'; vm['uptime'] = 0
            elif action == 'suspend': vm['status'] = 'paused'
            elif action in ('reboot', 'reset'): vm['status'] = 'running'
            else: return self._send(501, {'message': f'unknown action {action}', 'data': None})
            upid = f"UPID:pve:0000{len(TASKS)+1:04d}:00000001:{int(time.time()):08X}:qm{action}:{vmid}:root@pam!dcs:"
            TASKS.append({'upid': upid, 'node': 'pve', 'type': f'qm{action}', 'id': str(vmid), 'user': 'root@pam!dcs', 'status': 'OK', 'starttime': int(time.time()) + len(TASKS), 'endtime': int(time.time()) + len(TASKS) + 1})
            save()
            return self._send(200, {'data': upid})
        self._send(501, {'message': 'not mocked', 'data': None})

http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()

#!/usr/bin/env python3
"""A tiny Proxmox VE API stand-in for tests: /api2/json/version, /nodes, /cluster/resources,
/cluster/tasks, /nodes/{n}/{qemu|lxc}/{id}/status/current, /config, the guest-agent and
container interfaces (for the fleet scan), POST status/{action}, and what the hub uses to build VMs:
nextid, storages, download-url, qemu create/config/resize/destroy, task status, access/permissions.
Checks the PVEAPIToken header. Usage: mock-pve.py PORT TOKEN_ID TOKEN_SECRET [statefile]
MOCK_PVE_TLS=1: HTTPS with a self-signed certificate, and plain HTTP on the same port answered with
a 301 to https (what pveproxy does on 8006). MOCK_PVE_PRIVS=none: a token without privileges."""
import http.server, json, os, socket, ssl, subprocess, sys, tempfile, time, urllib.parse, pathlib

PORT = int(sys.argv[1]); TOKEN = f"PVEAPIToken={sys.argv[2]}={sys.argv[3]}"
STATE = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 else None
VMS = {
    100: {'vmid': 100, 'name': 'media-vm', 'type': 'qemu', 'node': 'pve', 'status': 'running', 'cpu': 0.12, 'maxcpu': 4, 'mem': 3221225472, 'maxmem': 8589934592, 'disk': 0, 'maxdisk': 68719476736, 'uptime': 86400, 'tags': 'docker;media'},
    101: {'vmid': 101, 'name': 'networking-security', 'type': 'qemu', 'node': 'pve', 'status': 'running', 'cpu': 0.03, 'maxcpu': 2, 'mem': 1073741824, 'maxmem': 4294967296, 'disk': 0, 'maxdisk': 34359738368, 'uptime': 4000, 'tags': 'docker'},
    200: {'vmid': 200, 'name': 'dns', 'type': 'lxc', 'node': 'pve', 'status': 'stopped', 'cpu': 0, 'maxcpu': 1, 'mem': 0, 'maxmem': 536870912, 'disk': 0, 'maxdisk': 8589934592, 'uptime': 0, 'tags': ''},
    900: {'vmid': 900, 'name': 'template-debian', 'type': 'qemu', 'node': 'pve', 'status': 'stopped', 'template': 1, 'cpu': 0, 'maxcpu': 1, 'mem': 0, 'maxmem': 1073741824},
}
TASKS = []
# what the guests answer when the hub scans them: VM 100 claims the loopback address (a DCS
# listener on 127.0.0.1 is "found" there), 101 has no guest agent, the container is unroutable
UUIDS = {100: '11111111-2222-3333-4444-555555555555', 101: '22222222-3333-4444-5555-666666666666'}
AGENT_IPS = {100: ['127.0.0.1']}
OSINFO = {100: {'id': 'debian', 'name': 'Debian GNU/Linux', 'pretty-name': 'Debian GNU/Linux 13 (trixie)', 'version': '13 (trixie)', 'version-id': '13', 'kernel-release': '6.12.111+deb13-cloud-amd64', 'machine': 'x86_64'}}
LXC_IPS = {200: '10.255.255.1'}
# provisioning: storages, imported images, per-VM configuration written by the hub
STORAGES = {'local': {'storage': 'local', 'type': 'dir', 'content': 'images,iso,vztmpl,backup,rootdir', 'total': 214748364800, 'used': 42949672960, 'avail': 171798691840, 'active': 1, 'enabled': 1},
            'local-lvm': {'storage': 'local-lvm', 'type': 'lvmthin', 'content': 'images,rootdir', 'total': 858993459200, 'used': 107374182400, 'avail': 751619276800, 'active': 1, 'enabled': 1}}
IMPORTS = {}        # storage -> [volid]
CONFIGS = {}        # vmid -> dict of config keys the hub set
NEXT_ID = [105]
DENY_TAGS = {101}    # guests whose tags the token may not change
TLS = os.environ.get('MOCK_PVE_TLS') == '1'
PRIVS = [] if os.environ.get('MOCK_PVE_PRIVS') == 'none' else ['VM.Allocate', 'VM.Clone', 'VM.Config.Disk', 'VM.Config.CDROM', 'VM.Config.Network', 'VM.Config.Options', 'VM.Config.Cloudinit', 'VM.Config.Memory', 'VM.Config.CPU', 'VM.Config.HWType',
         'VM.PowerMgmt', 'VM.Audit', 'VM.Console', 'Datastore.AllocateSpace', 'Datastore.AllocateTemplate', 'Datastore.Audit', 'Datastore.Allocate', 'Sys.Audit', 'SDN.Use']
def mk_upid(kind, vmid=''):
    u = f"UPID:pve:0000{len(TASKS)+1:04d}:00000001:{int(time.time()):08X}:{kind}:{vmid}:root@pam!dcs:"
    TASKS.append({'upid': u, 'node': 'pve', 'type': kind, 'id': str(vmid), 'user': 'root@pam!dcs', 'status': 'OK', 'starttime': int(time.time()) + len(TASKS), 'endtime': int(time.time()) + len(TASKS) + 1})
    return u
def form(handler):
    n = int(handler.headers.get('Content-Length') or 0)
    raw = handler.rfile.read(n).decode() if n else ''
    return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
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
    def _plain_on_tls(self):
        if not TLS or isinstance(self.connection, ssl.SSLSocket): return False
        self.send_response(301); self.send_header('Location', f"https://{self.headers.get('Host') or f'127.0.0.1:{PORT}'}{self.path}")
        self.send_header('Content-Length', '0'); self.end_headers(); return True
    def do_GET(self):
        if self._plain_on_tls(): return
        if not self._auth(): return
        p = urllib.parse.urlparse(self.path); path = p.path; q = urllib.parse.parse_qs(p.query)
        if path == '/api2/json/version': return self._send(200, {'data': {'version': '8.3.0', 'release': '8.3', 'repoid': 'mock'}})
        if path == '/api2/json/nodes': return self._send(200, {'data': [{'node': 'pve', 'status': 'online', 'cpu': 0.08, 'maxcpu': 16, 'mem': 17179869184, 'maxmem': 68719476736, 'disk': 42949672960, 'maxdisk': 214748364800, 'uptime': 900000, 'level': ''}]})
        if path == '/api2/json/cluster/resources': return self._send(200, {'data': [dict(v, id=f"{v['type']}/{v['vmid']}") for v in VMS.values()]})
        if path == '/api2/json/cluster/tasks': return self._send(200, {'data': TASKS[-30:]})
        if path == '/api2/json/cluster/nextid': return self._send(200, {'data': str(NEXT_ID[0])})
        if path == '/api2/json/access/permissions': return self._send(200, {'data': {'/': {p: 1 for p in PRIVS}}})
        if path == '/api2/json/nodes/pve/storage': return self._send(200, {'data': list(STORAGES.values())})
        if path.startswith('/api2/json/storage/'):
            st = STORAGES.get(path.split('/')[4]); return self._send(200, {'data': st}) if st else self._send(500, {'message': 'no such storage', 'data': None})
        if path.startswith('/api2/json/nodes/pve/storage/') and path.endswith('/content'):
            st = path.split('/')[6]; want = q.get('content', [''])[0]
            items = [{'volid': v, 'content': 'import', 'size': 400000000, 'format': 'qcow2'} for v in IMPORTS.get(st, [])]
            if st == 'local': items.append({'volid': 'local:iso/tiny-installer.iso', 'content': 'iso', 'size': 68157440, 'format': 'iso'})
            return self._send(200, {'data': [i for i in items if not want or i['content'] == want]})
        if path.startswith('/api2/json/nodes/pve/tasks/') and path.endswith('/status'):
            return self._send(200, {'data': {'status': 'stopped', 'exitstatus': 'OK', 'upid': urllib.parse.unquote(path.split('/')[6])}})
        parts = path.split('/')
        if len(parts) >= 8 and parts[3] == 'nodes' and parts[5] in ('qemu', 'lxc'):
            vmid = int(parts[6]); vm = VMS.get(vmid)
            if not vm: return self._send(500, {'message': f"Configuration file 'nodes/pve/{parts[5]}-server/{vmid}.conf' does not exist", 'data': None})
            if parts[7] == 'status' and parts[8:9] == ['current']:
                return self._send(200, {'data': dict(vm, qmpstatus=vm['status'], cpus=vm['maxcpu'], netin=1234, netout=5678, diskread=0, diskwrite=0, agent=1, ha={'managed': 0})})
            if parts[7] == 'config':
                cfg = {'name': vm['name'], 'cores': vm['maxcpu'], 'memory': vm['maxmem'] // 1048576, 'ostype': 'l26', 'onboot': 1, 'description': 'mock', 'net0': 'virtio=DE:AD:BE:EF:00:01,bridge=vmbr0', 'bootdisk': 'scsi0'}
                if vm['type'] == 'qemu': cfg['smbios1'] = f"uuid={UUIDS.get(vmid, '00000000-0000-0000-0000-000000000000')}"
                cfg['tags'] = vm.get('tags', '')
                if vm['type'] == 'qemu': cfg.update({'bios': 'ovmf' if vmid == 100 else 'seabios', 'machine': 'q35' if vmid == 100 else 'pc-i440fx-9.0', 'meta': 'creation-qemu=9.0.0,ctime=1790000000'})
                cfg.update(CONFIGS.get(vmid, {}))
                return self._send(200, {'data': cfg})
            if parts[5] == 'qemu' and parts[7:9] == ['agent', 'get-osinfo']:
                if vm['status'] != 'running' or vmid not in OSINFO: return self._send(500, {'message': 'QEMU guest agent is not running', 'data': None})
                return self._send(200, {'data': {'result': OSINFO[vmid]}})
            # guest addresses, as the hub's scan asks for them
            if parts[5] == 'qemu' and parts[7:10] == ['agent', 'network-get-interfaces']:
                if vm['status'] != 'running' or vmid not in AGENT_IPS: return self._send(500, {'message': 'QEMU guest agent is not running', 'data': None})
                return self._send(200, {'data': {'result': [{'name': 'lo', 'ip-addresses': [{'ip-address': '127.0.0.1', 'ip-address-type': 'ipv4'}]}] + [{'name': 'eth0', 'hardware-address': 'de:ad:be:ef:00:01', 'ip-addresses': [{'ip-address': ip, 'ip-address-type': 'ipv4'} for ip in AGENT_IPS[vmid]] + [{'ip-address': 'fe80::1', 'ip-address-type': 'ipv6'}]}]}})
            if parts[5] == 'lxc' and parts[7] == 'interfaces':
                if vm['status'] != 'running': return self._send(500, {'message': 'CT not running', 'data': None})
                return self._send(200, {'data': [{'name': 'lo', 'inet': '127.0.0.1/8'}, {'name': 'eth0', 'hwaddr': 'BC:24:11:00:00:01', 'inet': f"{LXC_IPS.get(vmid, '10.255.255.1')}/24"}]})
        self._send(501, {'message': f'not mocked: {path}', 'data': None})
    def do_PUT(self):
        if not self._auth(): return
        parts = urllib.parse.urlparse(self.path).path.split('/'); f = form(self)
        if len(parts) == 5 and parts[3] == 'storage' and parts[4] in STORAGES:
            if 'content' in f: STORAGES[parts[4]]['content'] = f['content']
            return self._send(200, {'data': None})
        if len(parts) >= 8 and parts[3] == 'nodes' and parts[5] in ('qemu', 'lxc') and parts[7] == 'config':
            vmid = int(parts[6]); vm = VMS.get(vmid)
            if not vm: return self._send(500, {'message': 'no such vm', 'data': None})
            # a token that may not change this guest's options (VM 101 stands for one)
            if 'tags' in f and vmid in DENY_TAGS: return self._send(403, {'message': f'Permission check failed (/vms/{vmid}, VM.Config.Options)', 'data': None})
            if 'tags' in f: vm['tags'] = f['tags']
            if parts[5] == 'qemu': CONFIGS.setdefault(vmid, {}).update({k: v for k, v in f.items() if k != 'tags'})
            return self._send(200, {'data': None})
        if len(parts) >= 8 and parts[3] == 'nodes' and parts[5] == 'qemu':
            vmid = int(parts[6]); vm = VMS.get(vmid)
            if not vm: return self._send(500, {'message': 'no such vm', 'data': None})
            if parts[7] == 'resize': vm['maxdisk'] = int(f.get('size', '32G').rstrip('G')) * 1073741824; return self._send(200, {'data': mk_upid('qmresize', vmid)})
        self._send(501, {'message': 'not mocked', 'data': None})
    def do_DELETE(self):
        if not self._auth(): return
        parts = urllib.parse.urlparse(self.path).path.split('/')
        if len(parts) >= 7 and parts[3] == 'nodes' and parts[5] == 'qemu' and parts[6].isdigit() and int(parts[6]) in VMS:
            vmid = int(parts[6]); del VMS[vmid]; CONFIGS.pop(vmid, None); save()
            return self._send(200, {'data': mk_upid('qmdestroy', vmid)})
        self._send(501, {'message': 'not mocked', 'data': None})
    def do_POST(self):
        if not self._auth(): return
        parts = urllib.parse.urlparse(self.path).path.split('/')
        if len(parts) == 6 and parts[3] == 'nodes' and parts[5] == 'qemu':
            f = form(self); vmid = int(f.get('vmid', NEXT_ID[0])); NEXT_ID[0] = max(NEXT_ID[0], vmid + 1)
            if vmid in VMS: return self._send(500, {'message': f'VM {vmid} already exists', 'data': None})
            VMS[vmid] = {'vmid': vmid, 'name': f.get('name', f'vm{vmid}'), 'type': 'qemu', 'node': 'pve', 'status': 'stopped', 'cpu': 0, 'maxcpu': int(f.get('cores', 2)), 'mem': 0, 'maxmem': int(f.get('memory', 2048)) * 1048576, 'disk': 0, 'maxdisk': 3221225472, 'uptime': 0, 'tags': f.get('tags', '')}
            CONFIGS[vmid] = {k: v for k, v in f.items() if k not in ('vmid', 'name', 'cores', 'memory')}
            UUIDS[vmid] = f'aaaaaaaa-0000-0000-0000-{vmid:012d}'
            save()
            return self._send(200, {'data': mk_upid('qmcreate', vmid)})
        if len(parts) >= 8 and parts[3] == 'nodes' and parts[5] == 'storage' and parts[7] == 'download-url':
            f = form(self); st = parts[6]
            IMPORTS.setdefault(st, []).append(f"{st}:{f.get('content', 'import')}/{f.get('filename', 'image.qcow2')}")
            return self._send(200, {'data': mk_upid('download')})
        if len(parts) >= 8 and parts[3] == 'nodes' and parts[5] == 'qemu' and parts[7] in ('clone', 'template'):
            vmid = int(parts[6]); vm = VMS.get(vmid)
            if not vm: return self._send(500, {'message': f'VM {vmid} does not exist', 'data': None})
            if parts[7] == 'template':
                vm['template'] = 1; vm['status'] = 'stopped'; save(); return self._send(200, {'data': mk_upid('qmtemplate', vmid)})
            f = form(self); newid = int(f.get('newid', NEXT_ID[0])); NEXT_ID[0] = max(NEXT_ID[0], newid + 1)
            if newid in VMS: return self._send(500, {'message': f'VM {newid} already exists', 'data': None})
            VMS[newid] = dict(vm, vmid=newid, name=f.get('name', f'clone-{newid}'), status='stopped', template=0, uptime=0)
            CONFIGS[newid] = dict(CONFIGS.get(vmid, {}), name=f.get('name', f'clone-{newid}'))
            UUIDS[newid] = f'bbbbbbbb-0000-0000-0000-{newid:012d}'
            save(); return self._send(200, {'data': mk_upid('qmclone', newid)})
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

class Server(http.server.ThreadingHTTPServer):
    def get_request(self):
        sock, addr = super().get_request()
        # one port for both, like pveproxy: a TLS handshake starts with 0x16, anything else is plain HTTP
        if TLS and sock.recv(1, socket.MSG_PEEK) == b'\x16': sock = CTX.wrap_socket(sock, server_side=True)
        return sock, addr
if TLS:
    d = tempfile.mkdtemp()
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', f'{d}/k.pem', '-out', f'{d}/c.pem', '-days', '1', '-subj', '/CN=pve.mock'], check=True, capture_output=True)
    CTX = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); CTX.load_cert_chain(f'{d}/c.pem', f'{d}/k.pem')
Server(('127.0.0.1', PORT), H).serve_forever()

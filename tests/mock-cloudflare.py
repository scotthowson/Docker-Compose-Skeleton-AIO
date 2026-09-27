#!/usr/bin/env python3
"""A tiny Cloudflare DNS API stand-in for tests: GET /client/v4/zones?name=, GET/POST /zones/{id}/dns_records,
PATCH/PUT/DELETE /zones/{id}/dns_records/{rid}, GET /user/tokens/verify, plus GET /ip (a public-IP answerer,
changed with POST /ip?set=A.B.C.D). Every zone name asked for exists (id "zone-<name>"). Checks the bearer
token. Records are written to the state file after every change. Usage: mock-cloudflare.py PORT TOKEN [statefile]"""
import http.server, json, sys, urllib.parse, pathlib, itertools

PORT = int(sys.argv[1]); TOKEN = sys.argv[2]
STATE = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else None
RECORDS = {}            # zone id -> [record]
IP = ['203.0.113.7']
SEQ = itertools.count(1)

def save():
    if STATE:
        STATE.write_text(json.dumps({'records': RECORDS, 'ip': IP[0]}, indent=1))

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def _text(self, code, text):
        body = text.encode(); self.send_response(code); self.send_header('Content-Type', 'text/plain'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def _auth(self):
        if self.headers.get('Authorization') != f'Bearer {TOKEN}':
            self._send(403, {'success': False, 'errors': [{'code': 10000, 'message': 'Authentication error'}], 'result': None}); return False
        return True
    def _body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return json.loads(self.rfile.read(n) or b'{}') if n else {}
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query); p = u.path
        if p == '/ip': return self._text(200, IP[0] + '\n')
        if not self._auth(): return
        if p.endswith('/user/tokens/verify'): return self._send(200, {'success': True, 'errors': [], 'result': {'id': 'tok', 'status': 'active'}})
        if p.endswith('/zones'):
            name = q.get('name', [''])[0]
            res = [{'id': 'zone-' + name, 'name': name, 'status': 'active'}] if name else [{'id': 'zone-' + z[5:], 'name': z[5:], 'status': 'active'} for z in RECORDS]
            return self._send(200, {'success': True, 'errors': [], 'result': res, 'result_info': {'total_count': len(res)}})
        parts = p.strip('/').split('/')
        if 'zones' in parts and parts[-1] == 'dns_records':
            zid = parts[parts.index('zones') + 1]; recs = RECORDS.get(zid, [])
            name = q.get('name', [''])[0]; typ = q.get('type', [''])[0]
            res = [r for r in recs if (not name or r['name'] == name) and (not typ or r['type'] == typ)]
            return self._send(200, {'success': True, 'errors': [], 'result': res, 'result_info': {'total_count': len(res)}})
        if 'zones' in parts and len(parts) >= 3 and parts[-2] != 'dns_records' and parts[-1] != 'dns_records':
            zid = parts[parts.index('zones') + 1]
            return self._send(200, {'success': True, 'errors': [], 'result': {'id': zid, 'name': zid[5:], 'status': 'active'}})
        self._send(404, {'success': False, 'errors': [{'code': 7003, 'message': 'no route for ' + p}], 'result': None})
    def do_POST(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query); p = u.path
        if p == '/ip':
            IP[0] = q.get('set', [IP[0]])[0]; save(); return self._text(200, IP[0] + '\n')
        if not self._auth(): return
        parts = p.strip('/').split('/')
        if parts[-1] == 'dns_records':
            zid = parts[parts.index('zones') + 1]; b = self._body()
            # like Cloudflare: a second record with the same name and type is refused (81057)
            if any(r['name'] == b.get('name', '') and r['type'] == b.get('type', 'A') for r in RECORDS.get(zid, [])):
                return self._send(400, {'success': False, 'errors': [{'code': 81057, 'message': 'Record already exists.'}], 'result': None})
            rec = {'id': f'rec-{next(SEQ)}', 'type': b.get('type', 'A'), 'name': b.get('name', ''), 'content': b.get('content', ''),
                   'proxied': bool(b.get('proxied', False)), 'ttl': b.get('ttl', 1), 'comment': b.get('comment', ''), 'zone_id': zid}
            RECORDS.setdefault(zid, []).append(rec); save()
            return self._send(200, {'success': True, 'errors': [], 'result': rec})
        self._send(404, {'success': False, 'errors': [{'code': 7003, 'message': 'no route'}], 'result': None})
    def _change(self, delete=False):
        if not self._auth(): return
        parts = urllib.parse.urlparse(self.path).path.strip('/').split('/')
        zid = parts[parts.index('zones') + 1]; rid = parts[-1]; recs = RECORDS.get(zid, [])
        for r in recs:
            if r['id'] == rid:
                if delete:
                    recs.remove(r); save(); return self._send(200, {'success': True, 'errors': [], 'result': {'id': rid}})
                b = self._body()
                for k in ('type', 'name', 'content', 'proxied', 'ttl', 'comment', 'priority'):
                    if k in b: r[k] = b[k]
                save(); return self._send(200, {'success': True, 'errors': [], 'result': r})
        self._send(404, {'success': False, 'errors': [{'code': 81044, 'message': 'Record does not exist'}], 'result': None})
    def do_PATCH(self): self._change()
    def do_PUT(self): self._change()
    def do_DELETE(self): self._change(delete=True)

http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()

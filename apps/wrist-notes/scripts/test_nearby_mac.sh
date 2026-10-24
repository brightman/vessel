#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
nearby_output=$(mktemp -d /private/tmp/wiselife-nearby-tests.XXXXXX)
trap 'rm -rf "$nearby_output"' EXIT
swiftc -module-cache-path "$nearby_output/cache" Sources/iPhone/AIConfiguration.swift Sources/iPhone/NearbyMacClient.swift Tests/NearbyMacProtocolSmoke.swift -o "$nearby_output/protocol"
python3 - "$nearby_output" <<'PY'
import hashlib,http.server,json,pathlib,ssl,subprocess,sys,threading,time
root=pathlib.Path(sys.argv[1])
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=WiseLife synthetic transport test','-keyout',str(root/'key.pem'),'-out',str(root/'cert.pem')],check=True,capture_output=True)
paths=[]
class Handler(http.server.BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args): pass
 def do_GET(self): self.respond()
 def do_POST(self): self.respond()
 def respond(self):
  paths.append(self.path)
  self.rfile.read(int(self.headers.get('Content-Length','0')))
  if self.path=='/slow': time.sleep(3)
  payload=b'{"protocol_version":1}'
  self.send_response(302 if self.path=='/redirect' else 200)
  if self.path=='/redirect': self.send_header('Location','https://127.0.0.1:%d/trap'%self.server.server_port)
  self.send_header('Content-Length',str(len(payload)));self.send_header('Connection','close');self.end_headers()
  try: self.wfile.write(payload)
  except (BrokenPipeError,ssl.SSLError): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.minimum_version=ssl.TLSVersion.TLSv1_2
context.load_cert_chain(root/'cert.pem',root/'key.pem');context.set_alpn_protocols(['http/1.1'])
server.socket=context.wrap_socket(server.socket,server_side=True)
pin=hashlib.sha256(ssl.PEM_cert_to_DER_cert((root/'cert.pem').read_text())).hexdigest()
(root/'fixture.json').write_text(json.dumps({'port':server.server_port,'pin':pin}))
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
 result=subprocess.run([str(root/'protocol'),str(root/'fixture.json')],timeout=30)
 assert result.returncode==0,'Swift transport assertions failed'
 assert '/trap' not in paths,'redirect leaked a request'
 assert paths.count('/health')==1,'bad TLS pin reached HTTP'
finally: server.shutdown();server.server_close()
PY

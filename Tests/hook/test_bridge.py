"""End-to-end protocol test: real hook script + real OpenBSD nc + a mock of
AgentBridgeServer/AgentSessionStore that mirrors the Swift logic byte for byte
(framing, held connections, peer-hangup check, decision encoding)."""
import json, os, select, socket, subprocess, sys, tempfile, threading, time

HOOK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "notchly-claude-hook")
HOME = tempfile.mkdtemp()
SUPPORT = os.path.join(HOME, "Library/Application Support/Notchly")
SOCK = os.path.join(SUPPORT, "agent.sock")
RS = 0x1E

# ---- mirror of Swift encoding -------------------------------------------------
def always_allow(suggestions):
    safe = [e for e in (suggestions or [])
            if (e.get("type") == "addRules" and e.get("behavior") == "allow") or e.get("type") == "addDirectories"]
    return safe or None

def hook_response(decision, suggestions=None):
    if decision == "terminal":
        return None
    if decision == "allow":
        d = {"behavior": "allow"}
    elif decision == "always":
        d = {"behavior": "allow"}
        perms = always_allow(suggestions)
        if perms: d["updatedPermissions"] = perms
    else:
        d = {"behavior": "deny", "message": "The user denied this from the Notchly notch."}
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": d}}).encode()

def parse(data):
    nl = data.index(b"\n")
    header = json.loads(data[:nl]); body = json.loads(data[nl + 1:] or b"{}")
    return header, body

def peer_has_closed(fd):
    p = select.poll(); p.register(fd, select.POLLIN)
    ev = p.poll(0)
    if not ev: return False
    if ev[0][1] & (select.POLLHUP | select.POLLERR | select.POLLNVAL): return True
    try:
        return len(socket.socket(fileno=os.dup(fd)).recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT)) == 0
    except BlockingIOError:
        return False

# ---- mock server ---------------------------------------------------------------
class Server:
    def __init__(self):
        os.makedirs(SUPPORT, exist_ok=True)
        old = os.umask(0o077)
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); self.s.bind(SOCK)
        os.umask(old); self.s.listen(16)
        self.messages = []; self.pending = {}; self.decide = {}
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while True:
            c, _ = self.s.accept(); c.settimeout(3)
            threading.Thread(target=self.client, args=(c,), daemon=True).start()

    def client(self, c):
        data = b""
        while len(data) < 4 * 1024 * 1024:
            try: chunk = c.recv(65536)
            except socket.timeout: break
            if not chunk: break
            if RS in chunk:
                data += chunk[:chunk.index(RS)]; break
            data += chunk
        header, body = parse(data)
        self.messages.append((header, body))
        if body.get("hook_event_name") == "PermissionRequest":
            key = body["tool_input"].get("command", "?")
            self.pending[key] = c
            plan = self.decide.get(key)
            if plan:
                delay, decision = plan
                time.sleep(delay)
                resp = hook_response(decision, body.get("permission_suggestions"))
                if resp: c.sendall(resp + b"\n")
                c.close(); self.pending.pop(key, None)
        else:
            c.close()

def run_hook(arg, payload, timeout=20):
    env = dict(os.environ, HOME=HOME)
    t = time.time()
    p = subprocess.run(["sh", HOOK, arg], input=json.dumps(payload).encode(), capture_output=True, env=env, timeout=timeout)
    return p.returncode, p.stdout.decode().strip(), time.time() - t

base = {"session_id": "abc123", "transcript_path": "/x.jsonl", "cwd": "/Users/shivam/code/notchly", "permission_mode": "default"}
def perm(cmd, suggestions=None):
    d = dict(base, hook_event_name="PermissionRequest", tool_name="Bash",
             tool_input={"command": cmd, "description": "test"})
    if suggestions: d["permission_suggestions"] = suggestions
    return d

results = []
def check(name, cond, info=""):
    results.append(cond); print(("PASS " if cond else "FAIL ") + name + (f"  [{info}]" if info else ""))

# 0. App not running → legacy fallback, exit 0, no stdout
rc, out, _ = run_hook("completed", dict(base, hook_event_name="Stop"))
legacy = open(os.path.join(SUPPORT, "agent-events.jsonl")).read()
check("app not running: exit 0, silent, legacy jsonl written", rc == 0 and out == "" and '"completed"' in legacy)

srv = Server()
check("socket is owner-only (0600-ish)", oct(os.stat(SOCK).st_mode & 0o777) in ("0o600", "0o700"), oct(os.stat(SOCK).st_mode & 0o777))

# 1. fire-and-forget event
rc, out, dt = run_hook("approved", dict(base, hook_event_name="PreToolUse", tool_name="Bash", tool_input={"command": "ls"}, tool_use_id="toolu_1"))
h, b = srv.messages[-1]
check("PreToolUse: returns fast & silent", rc == 0 and out == "" and dt < 1.0, f"{dt:.2f}s")
check("PreToolUse: header + payload parsed", h["kind"] == "approved" and b["tool_name"] == "Bash" and b["session_id"] == "abc123")

# 2. allow
srv.decide["npm test"] = (0.8, "allow")
rc, out, dt = run_hook("approval", perm("npm test"))
o = json.loads(out)
check("Allow: hook blocked until decision", dt >= 0.8, f"{dt:.2f}s")
check("Allow: Claude Code PermissionRequest schema",
      o == {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}, out)

# 3. always allow strips setMode
sugg = [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "npm run lint"}], "behavior": "allow", "destination": "localSettings"},
        {"type": "setMode", "mode": "bypassPermissions", "destination": "session"}]
srv.decide["npm run lint"] = (0.2, "always")
rc, out, _ = run_hook("approval", perm("npm run lint", sugg))
d = json.loads(out)["hookSpecificOutput"]["decision"]
check("Always: forwards addRules, drops setMode",
      d["behavior"] == "allow" and [e["type"] for e in d["updatedPermissions"]] == ["addRules"], out)

# 4. deny
srv.decide["rm -rf /"] = (0.2, "deny")
rc, out, _ = run_hook("approval", perm("rm -rf /"))
d = json.loads(out)["hookSpecificOutput"]["decision"]
check("Deny: behavior deny + message", d["behavior"] == "deny" and "Notchly" in d["message"])

# 5. terminal → empty → Claude Code falls back to its own prompt
srv.decide["git push"] = (0.2, "terminal")
rc, out, _ = run_hook("approval", perm("git push"))
check("Terminal: empty stdout, exit 0", rc == 0 and out == "")

# 6. hook process killed (user answered in terminal / Esc) → server detects hangup
env = dict(os.environ, HOME=HOME)
p = subprocess.Popen(["sh", HOOK, "approval"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, start_new_session=True)
p.stdin.write(json.dumps(perm("make deploy")).encode()); p.stdin.close()
for _ in range(50):
    if "make deploy" in srv.pending: break
    time.sleep(0.05)
held = srv.pending.get("make deploy")
check("Held request registered", held is not None)
os.killpg(p.pid, 9); p.wait(); time.sleep(0.3)
check("Peer hangup detected after hook is killed", held is not None and peer_has_closed(held.fileno()))

# 7. big payload (Write with 2 MB content) survives framing
big = dict(base, hook_event_name="PreToolUse", tool_name="Write", tool_input={"file_path": "/a", "content": "x\n" * 1_000_000})
rc, out, dt = run_hook("approved", big)
h, b = srv.messages[-1]
check("2 MB payload framed intact", len(b["tool_input"]["content"]) == 2_000_000, f"{dt:.2f}s")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

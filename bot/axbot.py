#!/usr/bin/env python3
"""axbot -- AxionOS OP9 Telegram bot (runs on the Pi, long-polls getUpdates).

Stdlib only. Reads TG_BOT_TOKEN, TG_CHAT_ID, TG_OWNER_ID from scripts/.env.

Access: the bot only acts in TG_CHAT_ID and in the owner's PM; it leaves any other
chat it is added to. "Owner" is the user id TG_OWNER_ID and nothing else -- being
admin/creator of a chat grants nothing, and anonymous-admin / send-as-channel
messages (sender_chat set) never count as the owner.

Custom commands (/addcmd) run `bash -c "<line>" <name> <args...>`: chat arguments
only ever arrive as positional $1.., never spliced into the line. Each run gets a
fresh directory in $OUT (also the cwd); files left there are sent back.

  python3 bot/axbot.py             # run
  python3 bot/axbot.py --selftest  # checks for the parsing/permission logic
"""
import html, json, os, random, re, shlex, shutil, subprocess, sys, threading, time, uuid
import urllib.error, urllib.parse, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.expanduser("~/.config/axbot/commands.json")
LATEST = os.path.expanduser("~/.config/axbot/latest.json")
RUNS = os.path.expanduser("~/.cache/axbot/runs")
LOGS = os.path.expanduser("~/.cache/axbot/logs")
RAW = "https://raw.githubusercontent.com/varakumar02/scripts/aox/"
DEVICES = {"lemonade": "OnePlus 9", "lemonadep": "OnePlus 9 Pro"}
MAX_UPLOAD = 50 * 1024 * 1024    # Bot API sendDocument limit
TIMEOUT = 30 * 60
BUILTIN_OWNER = {"sh", "post", "post!", "status", "addcmd", "delcmd"}
BUILTIN_PUBLIC = {"start", "help", "builds", "changelog", "cmds"}
NAME_RE = re.compile(r"^[a-z0-9_]{1,32}$")


def load_env(path):
    env = {}
    try:
        for line in open(path):
            m = re.match(r"^\s*([A-Z_][A-Z0-9_]*)=(.*)$", line)
            if m:
                env[m[1]] = m[2].strip().strip("'\"")
    except FileNotFoundError:
        pass
    return env


# ---- pure logic (covered by --selftest) -------------------------------------

def parse_command(text, me):
    """'/cmd@bot a b' -> ('cmd', 'a b', addressed); None if not a command or aimed at another bot.
    addressed = the command named this bot explicitly (@me)."""
    m = re.match(r"/(\S*)\s*(.*)", text or "", re.S)
    if not m:
        return None
    name, _, target = m[1].partition("@")
    if target and target.lower() != me.lower():
        return None
    return name.lower(), m[2].strip(), bool(target)


def post_device(text):
    """Device of a tg_post.sh release post, from its #<device> tag (tg_message.txt)."""
    m = re.search(r"#(lemonadep?)\b", text or "")
    return m and m[1]


# The whole reply to any wrong command: one of these, at random.
MEH = ("😑", "👍", "😒", "😫", "😩", "🫨", "😬", "🥱", "🫪", "🥴", "😵\u200d💫", "😵")
NO_ARGS = {"help", "changelog", "cmds", "status"}


def chat_allowed(chat_id, group_id, owner_id):
    return chat_id in (group_id, owner_id)


def is_owner(msg, owner_id):
    return bool(owner_id) and "sender_chat" not in msg and msg.get("from", {}).get("id") == owner_id


def split_args(rest):
    try:
        return shlex.split(rest)
    except ValueError:
        return rest.split()


class Registry:
    def __init__(self, path):
        self.path = path
        try:
            self.cmds = json.load(open(path))
        except (FileNotFoundError, ValueError):
            self.cmds = {}

    def save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        json.dump(self.cmds, open(tmp, "w"), indent=1)
        os.replace(tmp, self.path)

    def add(self, name, access, line, caption=""):
        if not NAME_RE.match(name) or name in BUILTIN_OWNER | BUILTIN_PUBLIC:
            return "name must be [a-z0-9_]{1,32} and not a built-in"
        if access not in ("public", "owner"):
            return "access must be public or owner"
        if not line:
            return "empty command line"
        self.cmds[name] = {"access": access, "cmd": line, **({"caption": caption} if caption else {})}
        self.save()

    def remove(self, name):
        if self.cmds.pop(name, None) is None:
            return "no such command"
        self.save()


# ---- Telegram ----------------------------------------------------------------

class Bot:
    def __init__(self, env):
        self.token = env["TG_BOT_TOKEN"]
        self.group = int(env["TG_CHAT_ID"])
        self.owner = int(env.get("TG_OWNER_ID") or 0)
        self.reg = Registry(STATE)
        try:
            self.latest = json.load(open(LATEST))
        except (FileNotFoundError, ValueError):
            self.latest = {}
        self.last_pin = None
        self.me = self.api("getMe")["username"]

    def api(self, method, files=None, http_timeout=60, **params):
        url = f"https://api.telegram.org/bot{self.token}/{method}"
        params = {k: (json.dumps(v) if isinstance(v, (dict, list)) else str(v)) for k, v in params.items() if v is not None}
        if files:
            boundary = uuid.uuid4().hex
            body = b""
            for k, v in params.items():
                body += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
            for k, path in files.items():
                body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"; '
                         f'filename="{os.path.basename(path)}"\r\nContent-Type: application/octet-stream\r\n\r\n').encode()
                body += open(path, "rb").read() + b"\r\n"
            body += f"--{boundary}--\r\n".encode()
            req = urllib.request.Request(url, body, {"Content-Type": f"multipart/form-data; boundary={boundary}"})
        else:
            req = urllib.request.Request(url, urllib.parse.urlencode(params).encode())
        try:
            d = json.load(urllib.request.urlopen(req, timeout=http_timeout))
        except urllib.error.HTTPError as e:
            d = json.load(e)
        if not d.get("ok"):
            raise RuntimeError(f"{method}: {d.get('description')}")
        return d["result"]

    def say(self, chat, text, reply=None, pre=False):
        text = text or "(no output)"
        if pre:
            text = "<pre>" + html.escape(text[-3500:]) + "</pre>"
        try:
            self.api("sendMessage", chat_id=chat, text=text, parse_mode="HTML",
                     disable_web_page_preview="true", reply_to_message_id=reply,
                     allow_sending_without_reply="true")
        except RuntimeError as e:
            print("say:", e, file=sys.stderr)

    # -- update loop

    def run(self):
        offset = None
        print(f"@{self.me} up; group {self.group}, owner {self.owner or 'UNSET'}", flush=True)
        while True:
            try:
                self.track_pin()
                ups = self.api("getUpdates", http_timeout=45, timeout=25, offset=offset,
                               allowed_updates=["message", "my_chat_member"])
            except Exception as e:
                print("getUpdates:", e, file=sys.stderr, flush=True)
                time.sleep(5)
                continue
            for u in ups:
                offset = u["update_id"] + 1
                try:
                    self.handle(u)
                except Exception as e:
                    print("handle:", repr(e), file=sys.stderr, flush=True)

    def track_pin(self):
        """Remember the group's newest pinned release post per device (tg_post.sh pins each one).
        ponytail: only the newest pin is visible through getChat, checked every <=25 s, so two release
        posts pinned within one poll keep only the second; post them a minute apart."""
        pin = self.api("getChat", chat_id=self.group).get("pinned_message")
        if not pin or pin["message_id"] == self.last_pin:
            return
        self.last_pin = pin["message_id"]
        dev = post_device(pin.get("text") or pin.get("caption"))
        if dev and self.latest.get(dev) != pin["message_id"]:
            self.latest[dev] = pin["message_id"]
            os.makedirs(os.path.dirname(LATEST), exist_ok=True)
            json.dump(self.latest, open(LATEST, "w"))
            print(f"latest {dev} post: {pin['message_id']}", flush=True)

    def handle(self, u):
        msg = u.get("message") or u.get("my_chat_member")
        if not msg:
            return
        chat = msg["chat"]["id"]
        if not chat_allowed(chat, self.group, self.owner):
            print(f"ignored update from chat {chat} ({msg['chat']['type']})", flush=True)
            if msg["chat"]["type"] != "private":
                print(f"leaving foreign chat {chat} {msg['chat'].get('title')!r}", flush=True)
                try:
                    self.api("leaveChat", chat_id=chat)
                except RuntimeError:
                    pass
            return
        if "my_chat_member" in u:
            return
        for m in msg.get("new_chat_members", []):
            if not m.get("is_bot"):
                self.say(chat, f"Welcome, {html.escape(m.get('first_name', ''))}! "
                               "Newest builds: /builds · commands: /help")
        parsed = parse_command(msg.get("text"), self.me)
        if not parsed:
            return
        name, rest, addressed = parsed
        owner = is_owner(msg, self.owner)
        print(f"chat {chat} from {msg.get('from', {}).get('id')}{' (owner)' if owner else ''}: /{name}", flush=True)
        mid = msg["message_id"]
        custom = self.reg.cmds.get(name)
        if name in BUILTIN_OWNER or (custom and custom["access"] == "owner"):
            if not owner:
                return self.meh(chat, mid)
        elif name not in BUILTIN_PUBLIC and not custom:
            # unknown: answer in PM or when aimed at us; a bare /foo in the group may be another bot's
            if addressed or msg["chat"]["type"] == "private":
                self.meh(chat, mid)
            return
        if name in NO_ARGS and rest:
            return self.meh(chat, mid)
        if custom:
            who = f"{msg.get('from', {}).get('id')} (@{msg.get('from', {}).get('username')})"
            return threading.Thread(target=self.run_custom, daemon=True,
                                    args=(chat, mid, name, custom, split_args(rest), who)).start()
        try:
            getattr(self, "cmd_" + name.replace("!", "_now"))(chat, mid, rest, owner)
        except Exception as e:
            print(f"/{name}: {e!r}", file=sys.stderr, flush=True)
            self.meh(chat, mid, str(e) if owner else None)

    def meh(self, chat, mid, why=None):
        """Wrong command: a random MEH emoji; the owner also gets the reason."""
        self.say(chat, random.choice(MEH) + (f" {html.escape(why)}" if why else ""), mid)

    # -- running things

    def spawn(self, chat, mid, argv, cwd=None):
        threading.Thread(target=self.execute, args=(chat, mid, argv, cwd), daemon=True).start()

    def run_argv(self, argv, cwd):
        """Run argv with a fresh $OUT dir (and $CAPTION, a file path beside it) -> (ok, output text, out dir)."""
        out = os.path.join(RUNS, time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6])
        os.makedirs(out)
        try:
            p = subprocess.run(argv, cwd=cwd or out, env={**os.environ, "OUT": out, "CAPTION": out + ".caption"}, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=TIMEOUT)
            ok, text = p.returncode == 0, p.stdout.decode(errors="replace") + ("" if p.returncode == 0 else f"\n[exit {p.returncode}]")
        except subprocess.TimeoutExpired as e:
            ok, text = False, (e.stdout or b"").decode(errors="replace") + f"\n[killed after {TIMEOUT}s]"
        return ok, text, out

    def send_file(self, chat, path, reply=None, caption=None):
        self.api("sendDocument", files={"document": path}, http_timeout=600, chat_id=chat, caption=caption,
                 reply_to_message_id=reply, allow_sending_without_reply="true")

    def execute(self, chat, mid, argv, cwd=None):
        """Owner built-ins (/sh /status /post): output and files go back to the chat."""
        _, text, out = self.run_argv(argv, cwd)
        self.say(chat, text, mid, pre=True)
        keep = False
        for root, _, names in os.walk(out):
            for n in sorted(names):
                f = os.path.join(root, n)
                if os.path.getsize(f) > MAX_UPLOAD:
                    keep = True
                    self.say(chat, f"{html.escape(n)}: over 50 MB, left on the Pi at <code>{html.escape(f)}</code>", mid)
                    continue
                try:
                    self.send_file(chat, f, mid)
                except Exception as e:
                    self.say(chat, f"upload {html.escape(n)} failed: {html.escape(str(e))}", mid)
        if not keep:
            shutil.rmtree(out, ignore_errors=True)

    def run_custom(self, chat, mid, name, cmd, args, who):
        """Custom command: only the files in $OUT are posted, never the output. Caption: what the script
        wrote to $CAPTION, else the /addcmd "## ..." template expanded now. Any failure -> "Failed to
        retrieve" in the chat, full log as a file to the owner's PM."""
        ok, text, out = self.run_argv(["bash", "-c", cmd["cmd"], name, *args], None)
        caption = None
        try:
            caption = open(out + ".caption").read().strip()
            os.remove(out + ".caption")
        except FileNotFoundError:
            pass
        if ok and not caption and cmd.get("caption"):
            # unquoted heredoc: $1.., $OUT, $(...) expand; chat args are only ever values, never re-parsed
            p = subprocess.run(["bash", "-c", f"cat <<__AXCAP__\n{cmd['caption']}\n__AXCAP__", name, *args],
                               cwd=out, env={**os.environ, "OUT": out}, capture_output=True, text=True, timeout=60)
            caption = p.stdout.strip()
        files = sorted(os.path.join(r, n) for r, _, ns in os.walk(out) for n in ns)
        problem = None if ok else "command failed"
        if ok and not files:
            problem = "finished but left no file in $OUT"
        big = [f for f in files if os.path.getsize(f) > MAX_UPLOAD]
        if ok and big:
            problem = "over 50 MB, left on the Pi: " + ", ".join(big)
        if not problem:
            for f in files:
                try:
                    self.send_file(chat, f, mid, (caption or None) and caption[:1024])
                except Exception as e:
                    problem = f"upload {os.path.basename(f)} failed: {e}"
                    break
        if not big:
            shutil.rmtree(out, ignore_errors=True)
        if not problem:
            return
        self.say(chat, "Failed to retrieve", mid)
        os.makedirs(LOGS, exist_ok=True)
        log = os.path.join(LOGS, f"{name}-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:4]}.log")
        with open(log, "w") as fh:
            fh.write(f"command: /{name} {shlex.join(args)}\nby: {who}\nchat: {chat}\nline: {cmd['cmd']}\n"
                     f"problem: {problem}\n\n--- output ---\n{text}")
        try:
            self.send_file(self.owner, log, caption=f"/{name} failed: {problem}"[:1024])
        except Exception as e:
            print(f"failure log {log} not sent to owner: {e}", file=sys.stderr, flush=True)

    # -- built-ins (public)

    def cmd_start(self, chat, mid, rest, owner):
        self.cmd_help(chat, mid, rest, owner)

    def cmd_help(self, chat, mid, rest, owner):
        lines = ["/builds [lemonade|lemonadep] – newest release post",
                 "/changelog – changelog", "/cmds – custom commands"]
        if owner:
            lines += ["", "owner:", "/status – Pi health", "/sh &lt;cmd&gt; – shell on the Pi",
                      "/post [args] – tg_post.sh --dry-run · /post! [args] – send for real",
                      "/addcmd &lt;name&gt; &lt;public|owner&gt; &lt;command line&gt; [## caption] – files written to $OUT are posted; "
                      "caption = what the script writes to $CAPTION, else the ## text expanded each run ($1, $(date)…)",
                      "/delcmd &lt;name&gt;"]
        self.say(chat, "\n".join(lines), mid)

    def cmd_builds(self, chat, mid, rest, owner):
        rest = rest.lower()
        if rest and rest not in DEVICES:
            return self.meh(chat, mid)
        self.track_pin()
        for d in [rest] if rest else DEVICES:
            post = self.latest.get(d)
            if not post:
                self.say(chat, f"No {DEVICES[d]} ({d}) release posted yet.", mid)
            elif chat == self.group:
                self.say(chat, f"⬆️ Latest {DEVICES[d]} ({d}) build", post)
            else:
                self.api("forwardMessage", chat_id=chat, from_chat_id=self.group, message_id=post)

    def cmd_changelog(self, chat, mid, rest, owner):
        try:
            text = urllib.request.urlopen(RAW + "OTA/GMS/changelogs_op9.txt", timeout=20).read().decode()
        except Exception as e:
            text = f"unavailable ({e})"
        self.say(chat, html.escape(text[:4000]), mid)

    def cmd_cmds(self, chat, mid, rest, owner):
        rows = [f"/{n} – {c['access']}" + (f": <code>{html.escape(c['cmd'])}</code>" if owner else "")
                + (f" ## {html.escape(c['caption'])}" if owner and c.get("caption") else "")
                for n, c in sorted(self.reg.cmds.items()) if owner or c["access"] == "public"]
        self.say(chat, "\n".join(rows) or "no custom commands.", mid)

    # -- built-ins (owner)

    def cmd_status(self, chat, mid, rest, owner):
        self.spawn(chat, mid, ["bash", "-c", "uptime; vcgencmd measure_temp 2>/dev/null; free -h; df -h / | tail -1; "
                                             "systemctl is-active axbot 2>/dev/null"])

    def cmd_sh(self, chat, mid, rest, owner):
        if not rest:
            return self.meh(chat, mid, "usage: /sh <command>")
        self.spawn(chat, mid, ["bash", "-c", rest], cwd=os.path.expanduser("~"))

    def cmd_post(self, chat, mid, rest, owner):
        self.spawn(chat, mid, [os.path.join(REPO, "release/tg_post.sh"), "--dry-run", *split_args(rest)], cwd=REPO)

    def cmd_post_now(self, chat, mid, rest, owner):
        self.spawn(chat, mid, [os.path.join(REPO, "release/tg_post.sh"), "-y", *split_args(rest)], cwd=REPO)

    def cmd_addcmd(self, chat, mid, rest, owner):
        line, _, caption = rest.partition(" ## ")
        parts = line.split(None, 2)
        err = (self.reg.add(*(parts + [""] * (3 - len(parts))), caption.strip()) if len(parts) >= 2
               else "usage: /addcmd <name> <public|owner> <command line> [## caption]")
        self.meh(chat, mid, err) if err else self.say(chat, f"added /{parts[0]} ({parts[1]})", mid)

    def cmd_delcmd(self, chat, mid, rest, owner):
        err = self.reg.remove(rest) if rest else "usage: /delcmd <name>"
        self.meh(chat, mid, err) if err else self.say(chat, f"removed /{rest}", mid)


def selftest():
    assert parse_command("/help", "axbot") == ("help", "", False)
    assert parse_command("/builds\nlemonade", "axbot") == ("builds", "lemonade", False)
    assert parse_command("/", "axbot") == ("", "", False) and parse_command("/@axbot", "axbot") == ("", "", True)
    assert len(MEH) == 12 and len(set(MEH)) == 12
    assert post_device("for Oneplus 9 Pro (lemonadep)\n#A16 #lemonadep #Axion") == "lemonadep"
    assert post_device("for Oneplus 9 (lemonade)\n#A16 #lemonade #Axion") == "lemonade"
    assert not post_device("rules: no lemonade talk") and not post_device(None)
    assert parse_command("/Builds@AxBot lemonadep", "axbot") == ("builds", "lemonadep", True)
    assert parse_command("/builds@otherbot", "axbot") is None
    assert parse_command("hello", "axbot") is None
    assert parse_command("/post! --beta", "axbot") == ("post!", "--beta", False)
    assert chat_allowed(-100, -100, 7) and chat_allowed(7, -100, 7) and not chat_allowed(-200, -100, 7)
    assert is_owner({"from": {"id": 7}}, 7)
    assert not is_owner({"from": {"id": 8}}, 7)
    assert not is_owner({"from": {"id": 7}, "sender_chat": {"id": -100}}, 7)
    assert not is_owner({"from": {"id": 0}}, 0)   # TG_OWNER_ID unset -> nobody is owner
    assert split_args('a "b c"') == ["a", "b c"] and split_args('a "b') == ["a", '"b']
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        r = Registry(os.path.join(d, "x", "c.json"))
        assert r.add("hello", "public", "echo hi") is None
        assert r.add("sh", "public", "x") and r.add("Bad-Name", "public", "x") and r.add("ok", "root", "x")
        assert Registry(r.path).cmds == {"hello": {"access": "public", "cmd": "echo hi"}}
        assert r.add("hello", "owner", "echo bye", "cap $1") is None and r.cmds["hello"]["caption"] == "cap $1"
        assert r.add("hello", "owner", "echo bye") is None and "caption" not in r.cmds["hello"]
        assert r.remove("hello") is None and r.remove("hello")
        # custom command runner, Telegram stubbed out
        global RUNS, LOGS
        RUNS, LOGS = os.path.join(d, "runs"), os.path.join(d, "logs")
        b = Bot.__new__(Bot)
        b.owner, sent, said = 7, [], []
        b.send_file = lambda chat, path, reply=None, caption=None: sent.append((chat, os.path.basename(path), caption, open(path).read()))
        b.say = lambda chat, text, reply=None, pre=False: said.append(text)
        mk = 'echo noise; echo "$1" > "$OUT/r.txt"'
        b.run_custom(-100, 1, "t", {"cmd": mk, "caption": "for $1: $(ls) \"q\""}, ["$(id)"], "u")
        assert sent == [(-100, "r.txt", 'for $(id): r.txt "q"', "$(id)\n")] and said == [], (sent, said)
        sent.clear()      # script-written $CAPTION wins over the template
        b.run_custom(-100, 1, "t", {"cmd": mk + '; echo "made $1" > "$CAPTION"', "caption": "tmpl"}, ["x"], "u")
        assert sent[0][2] == "made x" and not os.listdir(RUNS), sent
        sent.clear()
        b.run_custom(-100, 1, "t", {"cmd": mk}, ["x"], "u")
        assert sent[0][2] is None, sent
        for line in ("echo boom; exit 3", "echo done"):          # failing command / no file left
            sent.clear(); said.clear()
            b.run_custom(-100, 1, "t", {"cmd": line}, [], "u")
            assert said == ["Failed to retrieve"] and len(sent) == 1 and sent[0][0] == 7, (sent, said)
        logs = [open(os.path.join(LOGS, n)).read() for n in os.listdir(LOGS)]
        assert len(logs) == 2 and any("boom" in t and "[exit 3]" in t for t in logs)
        assert not os.listdir(RUNS)
    # argv form keeps chat args out of the command line
    p = subprocess.run(["bash", "-c", 'printf "%s|" "$@"', "n", "$(id)", "; rm -rf /"], capture_output=True, text=True)
    assert p.stdout == "$(id)|; rm -rf /|", p.stdout
    print("selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        Bot(load_env(os.path.join(REPO, ".env"))).run()

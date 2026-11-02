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
    """'/cmd@bot a b' -> ('cmd', 'a b'); None if not a command or aimed at another bot."""
    if not text or not text.startswith("/"):
        return None
    head, _, rest = text[1:].partition(" ")
    name, _, target = head.partition("@")
    if target and target.lower() != me.lower():
        return None
    return name.lower(), rest.strip()


def post_device(text):
    """Device of a tg_post.sh release post, from its #<device> tag (tg_message.txt)."""
    m = re.search(r"#(lemonadep?)\b", text or "")
    return m and m[1]


INVALID = ("🍋 <b>{}</b>? Never heard of it. I only squeeze <code>lemonade</code> and <code>lemonadep</code>.",
           "🤖 Searched every server, two Raspberry Pis and under the sofa: no <b>{}</b>. Try <code>lemonade</code> or <code>lemonadep</code>.",
           "📵 <b>{}</b> isn't a OnePlus 9 — did your cat walk on the keyboard? <code>/builds lemonade</code> or <code>/builds lemonadep</code>.",
           "🧃 Wrong flavour! <b>{}</b> is not on the menu. We serve <code>lemonade</code> and <code>lemonadep</code> only.")


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

    def add(self, name, access, line):
        if not NAME_RE.match(name) or name in BUILTIN_OWNER | BUILTIN_PUBLIC:
            return "name must be [a-z0-9_]{1,32} and not a built-in"
        if access not in ("public", "owner"):
            return "access must be public or owner"
        if not line:
            return "empty command line"
        self.cmds[name] = {"access": access, "cmd": line}
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
        name, rest = parsed
        owner = is_owner(msg, self.owner)
        print(f"chat {chat} from {msg.get('from', {}).get('id')}{' (owner)' if owner else ''}: /{name}", flush=True)
        mid = msg["message_id"]
        custom = self.reg.cmds.get(name)
        if name in BUILTIN_OWNER or (custom and custom["access"] == "owner"):
            if not owner:
                return self.say(chat, "owner only.", mid)
        elif name not in BUILTIN_PUBLIC and not custom:
            return
        if custom:
            return self.spawn(chat, mid, ["bash", "-c", custom["cmd"], name, *split_args(rest)])
        getattr(self, "cmd_" + name.replace("!", "_now"))(chat, mid, rest, owner)

    # -- running things

    def spawn(self, chat, mid, argv, cwd=None):
        threading.Thread(target=self.execute, args=(chat, mid, argv, cwd), daemon=True).start()

    def execute(self, chat, mid, argv, cwd=None):
        out = os.path.join(RUNS, time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6])
        os.makedirs(out)
        try:
            p = subprocess.run(argv, cwd=cwd or out, env={**os.environ, "OUT": out}, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=TIMEOUT)
            text = p.stdout.decode(errors="replace") + ("" if p.returncode == 0 else f"\n[exit {p.returncode}]")
        except subprocess.TimeoutExpired as e:
            text = (e.stdout or b"").decode(errors="replace") + f"\n[killed after {TIMEOUT}s]"
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
                    self.api("sendDocument", files={"document": f}, http_timeout=600, chat_id=chat, reply_to_message_id=mid,
                             allow_sending_without_reply="true")
                except Exception as e:
                    self.say(chat, f"upload {html.escape(n)} failed: {html.escape(str(e))}", mid)
        if not keep:
            shutil.rmtree(out, ignore_errors=True)

    # -- built-ins (public)

    def cmd_start(self, chat, mid, rest, owner):
        self.cmd_help(chat, mid, rest, owner)

    def cmd_help(self, chat, mid, rest, owner):
        lines = ["/builds [lemonade|lemonadep] – newest release post",
                 "/changelog – changelog", "/cmds – custom commands"]
        if owner:
            lines += ["", "owner:", "/status – Pi health", "/sh &lt;cmd&gt; – shell on the Pi",
                      "/post [args] – tg_post.sh --dry-run · /post! [args] – send for real",
                      "/addcmd &lt;name&gt; &lt;public|owner&gt; &lt;command line&gt; – files written to $OUT are sent back",
                      "/delcmd &lt;name&gt;"]
        self.say(chat, "\n".join(lines), mid)

    def cmd_builds(self, chat, mid, rest, owner):
        rest = rest.strip().lower()
        if rest and rest not in DEVICES:
            return self.say(chat, random.choice(INVALID).format(html.escape(rest[:40])), mid)
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
                for n, c in sorted(self.reg.cmds.items()) if owner or c["access"] == "public"]
        self.say(chat, "\n".join(rows) or "no custom commands.", mid)

    # -- built-ins (owner)

    def cmd_status(self, chat, mid, rest, owner):
        self.spawn(chat, mid, ["bash", "-c", "uptime; vcgencmd measure_temp 2>/dev/null; free -h; df -h / | tail -1; "
                                             "systemctl is-active axbot 2>/dev/null"])

    def cmd_sh(self, chat, mid, rest, owner):
        self.spawn(chat, mid, ["bash", "-c", rest], cwd=os.path.expanduser("~"))

    def cmd_post(self, chat, mid, rest, owner):
        self.spawn(chat, mid, [os.path.join(REPO, "release/tg_post.sh"), "--dry-run", *split_args(rest)], cwd=REPO)

    def cmd_post_now(self, chat, mid, rest, owner):
        self.spawn(chat, mid, [os.path.join(REPO, "release/tg_post.sh"), "-y", *split_args(rest)], cwd=REPO)

    def cmd_addcmd(self, chat, mid, rest, owner):
        parts = rest.split(None, 2)
        err = self.reg.add(*(parts + [""] * (3 - len(parts)))) if len(parts) >= 2 else "usage: /addcmd <name> <public|owner> <command line>"
        self.say(chat, html.escape(err) if err else f"added /{parts[0]} ({parts[1]})", mid)

    def cmd_delcmd(self, chat, mid, rest, owner):
        err = self.reg.remove(rest.strip())
        self.say(chat, html.escape(err) if err else f"removed /{rest.strip()}", mid)


def selftest():
    assert parse_command("/help", "axbot") == ("help", "")
    assert post_device("for Oneplus 9 Pro (lemonadep)\n#A16 #lemonadep #Axion") == "lemonadep"
    assert post_device("for Oneplus 9 (lemonade)\n#A16 #lemonade #Axion") == "lemonade"
    assert not post_device("rules: no lemonade talk") and not post_device(None)
    assert all(t.format("x").count("x") for t in INVALID)
    assert parse_command("/Builds@AxBot lemonadep", "axbot") == ("builds", "lemonadep")
    assert parse_command("/builds@otherbot", "axbot") is None
    assert parse_command("hello", "axbot") is None
    assert parse_command("/post! --beta", "axbot") == ("post!", "--beta")
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
        assert r.remove("hello") is None and r.remove("hello")
    # argv form keeps chat args out of the command line
    p = subprocess.run(["bash", "-c", 'printf "%s|" "$@"', "n", "$(id)", "; rm -rf /"], capture_output=True, text=True)
    assert p.stdout == "$(id)|; rm -rf /|", p.stdout
    print("selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        Bot(load_env(os.path.join(REPO, ".env"))).run()

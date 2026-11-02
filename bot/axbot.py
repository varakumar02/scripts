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
BUGS = os.path.expanduser("~/.config/axbot/bugs.json")
RESTARTED = os.path.expanduser("~/.config/axbot/restarted.json")   # set by /update, read once at start
RUNS = os.path.expanduser("~/.cache/axbot/runs")
LOGS = os.path.expanduser("~/.cache/axbot/logs")
RAW = "https://raw.githubusercontent.com/varakumar02/scripts/aox/"
KEEP_POSTS = 3        # release posts remembered per device, so a deleted one falls back to the previous
DEVICES = {"lemonade": "OnePlus 9", "lemonadep": "OnePlus 9 Pro"}
MAX_UPLOAD = 50 * 1024 * 1024    # Bot API sendDocument limit
TIMEOUT = 30 * 60
BUILTIN_OWNER = {"sh", "post", "post!", "status", "addcmd", "delcmd", "setbuild", "update", "resolve"}
BUILTIN_PUBLIC = {"start", "notes", "builds", "changelog", "cmds", "ping", "bug", "bugs", "editbug"}
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
DENIED = "⛔ <b>Access Denied</b>"
OFFLINE = "😴 I was offline when you sent this, here you go:"
STALE_AFTER = 120     # seconds; an older command was queued by Telegram while the bot was down
NO_ARGS = {"notes", "changelog", "cmds", "status", "ping"}


def tg_len(text):
    """Length as Telegram counts a parse_mode=HTML caption: tags dropped, entities decoded, UTF-16 units."""
    return len(html.unescape(re.sub(r"<[^>]+>", "", text)).encode("utf-16-le")) // 2


def parse_mode_for(text):
    """HTML when the text has Telegram HTML tags, else legacy Markdown (*bold* _italic_ `code` [t](url))."""
    if re.search(r"</?(b|i|u|s|code|pre|a|strong|em|ins|del|strike|tg-spoiler|blockquote)\b[^>]*>", text, re.I):
        return "HTML"
    return "Markdown"


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
        if access not in ("public", "admin", "owner"):
            return "access must be public, admin or owner"
        if not line:
            return "empty command line"
        self.cmds[name] = {"access": access, "cmd": line, **({"caption": caption} if caption else {})}
        self.save()

    def remove(self, name):
        if self.cmds.pop(name, None) is None:
            return "no such command"
        self.save()


# ---- Telegram ----------------------------------------------------------------

class BugBook:
    """Open bugs in `path` ({"next": id, "bugs": [...]}, oldest first); a resolved bug moves out to
    `path` with -resolved (a plain list), so the open file only ever holds open bugs."""

    def __init__(self, path):
        self.path, self.done_path = path, path.replace(".json", "-resolved.json")
        self.d = load_json(path, {"next": 1, "bugs": []})

    def save(self):
        dump_json(self.path, self.d)

    def add(self, text, by, uid, chat, msg):
        b = {"id": self.d["next"], "text": text, "by": by, "uid": uid, "chat": chat, "msg": msg,
             "date": int(time.time()), "resolved": None}
        self.d["next"] += 1
        self.d["bugs"].append(b)
        self.save()
        return b

    def get(self, i):
        return next((b for b in self.d["bugs"] if b["id"] == i), None)

    def listed(self, resolved):
        return self.d["bugs"] + (load_json(self.done_path, []) if resolved else [])

    def resolve(self, ids):
        """Move bugs to the resolved file -> (moved bugs, [ids not open]). Ids are never reused."""
        moved = [b for b in self.d["bugs"] if b["id"] in ids]
        for b in moved:
            b["resolved"] = int(time.time())
        if moved:
            dump_json(self.done_path, load_json(self.done_path, []) + moved)   # archive first: a crash
            self.d["bugs"] = [b for b in self.d["bugs"] if b not in moved]     # in between duplicates,
            self.save()                                                        # never loses a bug
        return moved, [i for i in ids if i not in {b["id"] for b in moved}]


def load_json(path, default):
    try:
        return json.load(open(path))
    except (FileNotFoundError, ValueError):
        return default


def dump_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(data, open(path + ".tmp", "w"), indent=1)
    os.replace(path + ".tmp", path)


def bug_ids(rest):
    """'3 #5, 7' -> [3, 5, 7]; None if anything else is in there."""
    toks = [t.lstrip("#") for t in re.split(r"[\s,]+", rest) if t]
    return [int(t) for t in toks] if toks and all(t.isdigit() for t in toks) else None


class Bot:
    def __init__(self, env):
        self.token = env["TG_BOT_TOKEN"]
        self.group = int(env["TG_CHAT_ID"])
        self.owner = int(env.get("TG_OWNER_ID") or 0)
        self.reg = Registry(STATE)
        self.bugs = BugBook(BUGS)
        self.started = time.time()
        try:
            self.latest = json.load(open(LATEST))
        except (FileNotFoundError, ValueError):
            self.latest = {}
        # {device: [message ids, newest first]}; older files kept one bare id per device
        self.latest = {d: v if isinstance(v, list) else [v] for d, v in self.latest.items()}
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
        self.offset = None
        self.announce_restart()
        print(f"@{self.me} up; group {self.group}, owner {self.owner or 'UNSET'}", flush=True)
        while True:
            try:
                self.track_pin()
                ups = self.api("getUpdates", http_timeout=45, timeout=25, offset=self.offset,
                               allowed_updates=["message", "my_chat_member"])
            except Exception as e:
                print("getUpdates:", e, file=sys.stderr, flush=True)
                time.sleep(5)
                continue
            for u in ups:
                self.offset = u["update_id"] + 1
                try:
                    self.handle(u)
                except Exception as e:
                    print("handle:", repr(e), file=sys.stderr, flush=True)

    def announce_restart(self):
        """After /update's restart: reply under that /update message with the commit now running."""
        r = load_json(RESTARTED, None)
        if not r:
            return
        head = subprocess.run(["git", "-C", REPO, "log", "-1", "--format=%h %s"], capture_output=True, text=True).stdout.strip()
        try:
            self.api("sendMessage", chat_id=r["chat"], text=f"🟢 Back up on <code>{html.escape(head)}</code>",
                     parse_mode="HTML", reply_to_message_id=r["mid"], allow_sending_without_reply="true")
        except Exception as e:                       # network not up yet: keep the marker for the next start
            return print("restart announcement not sent:", e, file=sys.stderr, flush=True)
        os.remove(RESTARTED)

    def track_pin(self):
        """Remember the group's newest pinned release post per device (tg_post.sh pins each one).
        ponytail: only the newest pin is visible through getChat, checked every <=25 s, so two release
        posts pinned within one poll keep only the second; post them a minute apart."""
        pin = self.api("getChat", chat_id=self.group).get("pinned_message")
        if not pin or pin["message_id"] == self.last_pin:
            return
        self.last_pin = pin["message_id"]
        self.remember(pin)

    def remember(self, post, dev=None):
        """Put `post` first in its device's list of the last KEEP_POSTS release posts -> device,
        or None if it names none."""
        dev = dev or post_device(post.get("text") or post.get("caption"))
        ids = self.latest.get(dev, [])
        if dev and ids[:1] != [post["message_id"]]:
            self.save_posts(dev, [post["message_id"], *(i for i in ids if i != post["message_id"])])
            print(f"latest {dev} posts: {self.latest[dev]}", flush=True)
        return dev

    def save_posts(self, dev, ids):
        self.latest[dev] = ids[:KEEP_POSTS]
        os.makedirs(os.path.dirname(LATEST), exist_ok=True)
        tmp = LATEST + ".tmp"
        json.dump(self.latest, open(tmp, "w"))
        os.replace(tmp, LATEST)

    def handle(self, u):
        msg = u.get("message") or u.get("my_chat_member")
        if not msg:
            return
        chat = msg["chat"]["id"]
        private = msg["chat"]["type"] == "private"
        if not chat_allowed(chat, self.group, self.owner):
            print(f"ignored update from chat {chat} ({msg['chat']['type']})", flush=True)
            if not private:
                print(f"leaving foreign chat {chat} {msg['chat'].get('title')!r}", flush=True)
                try:
                    self.api("leaveChat", chat_id=chat)
                except RuntimeError:
                    pass
            return
        if "my_chat_member" in u:
            return
        if "pinned_message" in msg and chat == self.group:     # a person pinned something
            self.remember(msg["pinned_message"])
        for m in msg.get("new_chat_members", []):
            if not m.get("is_bot"):
                self.say(chat, f"Welcome, {html.escape(m.get('first_name', ''))}! "
                               "Newest builds: /builds · commands: /notes · found a bug? /bug")
        parsed = parse_command(msg.get("text"), self.me)
        if not parsed:
            return
        name, rest, addressed = parsed
        owner = is_owner(msg, self.owner)
        print(f"chat {chat} from {msg.get('from', {}).get('id')}{' (owner)' if owner else ''}: /{name}", flush=True)
        mid = msg["message_id"]
        custom = self.reg.cmds.get(name)
        # sent while the bot was down (Telegram queues updates for 24 h): say so before the late answer
        will_answer = name in BUILTIN_OWNER | BUILTIN_PUBLIC or custom or addressed or private
        if will_answer and time.time() - msg.get("date", time.time()) > STALE_AFTER:
            self.say(chat, OFFLINE, mid)
        if name in BUILTIN_OWNER or (custom and custom["access"] == "owner"):
            if not owner:
                return self.say(chat, DENIED, mid)
        elif custom and custom["access"] == "admin":
            if not (owner or self.is_admin(msg)):
                return self.say(chat, DENIED, mid)
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
            getattr(self, "cmd_" + name.replace("!", "_now"))(chat, mid, rest, owner, msg)
        except Exception as e:
            print(f"/{name}: {e!r}", file=sys.stderr, flush=True)
            self.meh(chat, mid, str(e) if owner else None)

    def is_admin(self, msg):
        """Admin (or creator) of OUR group -- never of whatever chat the message came from. A message
        sent as the group itself (anonymous admin) can only come from one of its admins."""
        if "sender_chat" in msg:
            return msg["sender_chat"]["id"] == self.group
        return self.group_status(msg.get("from", {}).get("id")) in ("creator", "administrator")

    def group_status(self, uid):
        try:
            return self.api("getChatMember", chat_id=self.group, user_id=uid)["status"]
        except RuntimeError:
            return "left"

    def meh(self, chat, mid, why=None):
        """Wrong command: a random MEH emoji; the owner also gets the reason."""
        self.say(chat, random.choice(MEH) + (f" {html.escape(why)}" if why else ""), mid)

    # -- running things

    def spawn(self, chat, mid, argv, cwd=None):
        threading.Thread(target=self.execute, args=(chat, mid, argv, cwd), daemon=True).start()

    def run_argv(self, argv, cwd):
        """Run argv with a fresh $OUT dir -> (ok, output text, out dir)."""
        out = os.path.join(RUNS, time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6])
        os.makedirs(out)
        try:
            p = subprocess.run(argv, cwd=cwd or out, env={**os.environ, "OUT": out}, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=TIMEOUT)
            ok, text = p.returncode == 0, p.stdout.decode(errors="replace") + ("" if p.returncode == 0 else f"\n[exit {p.returncode}]")
        except subprocess.TimeoutExpired as e:
            ok, text = False, (e.stdout or b"").decode(errors="replace") + f"\n[killed after {TIMEOUT}s]"
        return ok, text, out

    def send_file(self, chat, path, reply=None, caption=None):
        self.api("sendDocument", files={"document": path}, http_timeout=600, chat_id=chat, caption=caption,
                 reply_to_message_id=reply, allow_sending_without_reply="true")

    def send_fmt(self, method, field, text, **kw):
        """sendMessage/sendDocument with `field` as HTML or Markdown (see parse_mode_for); Telegram
        rejects broken markup outright, so retry it as plain text rather than lose the post."""
        if not text:
            return self.api(method, **kw)
        try:
            return self.api(method, **kw, **{field: text, "parse_mode": parse_mode_for(text)})
        except RuntimeError as e:
            if "parse entities" not in str(e):
                raise
            return self.api(method, **kw, **{field: text})

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
        """Custom command: $OUT is posted; the output only in a PM (the owner's), never in the group. $OUT/tg_message.txt (HTML) is the post
        text, else the /addcmd "## ..." template expanded now; the other files go out with it, and with
        no other file the text is posted alone. Any failure -> "Failed to retrieve" in the chat, full
        log as a file to the owner's PM."""
        ok, text, out = self.run_argv(["bash", "-c", cmd["cmd"], name, *args], None)
        caption = None
        try:
            caption = open(os.path.join(out, "tg_message.txt"), errors="replace").read().strip()
            os.remove(os.path.join(out, "tg_message.txt"))
        except FileNotFoundError:
            pass
        if ok and not caption and cmd.get("caption"):
            # unquoted heredoc: $1.., $OUT, $(...) expand; chat args are only ever values, never re-parsed
            p = subprocess.run(["bash", "-c", f"cat <<__AXCAP__\n{cmd['caption']}\n__AXCAP__", name, *args],
                               cwd=out, env={**os.environ, "OUT": out}, capture_output=True, text=True, timeout=60)
            caption = p.stdout.strip()
        files = sorted(os.path.join(r, n) for r, _, ns in os.walk(out) for n in ns)
        problem = None if ok else "command failed"
        if ok and not files and not caption:
            problem = "finished but left no file in $OUT"
        big = [f for f in files if os.path.getsize(f) > MAX_UPLOAD]
        if ok and big:
            problem = "over 50 MB, left on the Pi: " + ", ".join(big)
        if not problem:
            try:
                # caption limit is 1024 as Telegram counts it (parsed text, UTF-16); longer -> own message
                if caption and (not files or tg_len(caption) > 1024):
                    self.send_fmt("sendMessage", "text", caption[:4096], chat_id=chat,
                                   reply_to_message_id=mid, allow_sending_without_reply="true",
                                   disable_web_page_preview="true")
                    caption = None
                for f in files:
                    self.send_fmt("sendDocument", "caption", caption, files={"document": f}, http_timeout=600,
                                   chat_id=chat, reply_to_message_id=mid, allow_sending_without_reply="true")
            except Exception as e:
                problem = f"posting failed: {e}"
        if not big:
            shutil.rmtree(out, ignore_errors=True)
        if chat != self.group:                      # PM: the owner also sees what the command printed
            self.say(chat, text, mid, pre=True)
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

    def cmd_start(self, chat, mid, rest, owner, msg):
        self.cmd_notes(chat, mid, rest, owner, msg)

    def notes_text(self, owner, admin):
        """Members: one plain list. Admins: Everyone + Admins sections. Owner (PM only): + Owner."""
        custom = lambda access: [f"/{n}" for n, c in sorted(self.reg.cmds.items()) if c["access"] == access]
        everyone = ["/notes – this list", "/builds [lemonade|lemonadep] – newest release post",
                    "/changelog – changelog", "/bug &lt;what's wrong&gt; – report a bug (or reply /bug to a message)",
                    "/bugs – open bugs", "/editbug &lt;id&gt; &lt;new text&gt; – fix your own bug report",
                    "/ping – is the bot up?",
                    "/cmds – custom commands", *custom("public")]
        if not admin:
            return "\n".join(everyone)
        lines = ["👥 <b>Everyone</b>", *everyone, "", "🛡 <b>Admins</b>", *(custom("admin") or ["(no admin commands yet)"])]
        if owner:
            lines += ["", "👑 <b>Owner</b>",
                      "/status – Pi health",
                      "/sh &lt;cmd&gt; – shell on the Pi",
                      "/post [args] – tg_post.sh --dry-run",
                      "/post! [args] – tg_post.sh, send for real",
                      "/setbuild [device] – reply to a release post: /builds shows it",
                      "/update – pull the newest bot code, self-test, restart",
                      "/bugs all – open and resolved bugs",
                      "/resolve &lt;id…&gt; – mark bugs resolved, tells the reporter",
                      "/addcmd &lt;name&gt; &lt;public|admin|owner&gt; &lt;command line&gt; [## caption]",
                      "    files the command leaves in $OUT are posted, its output never",
                      "    text: $OUT/tg_message.txt (HTML or *Markdown*), else the ## caption ($1, $(date)… per run)",
                      "/delcmd &lt;name&gt;",
                      *custom("owner")]
        return "\n".join(lines)

    def cmd_notes(self, chat, mid, rest, owner, msg):
        # in the group the owner gets the admin view; the full list only in the owner's PM
        full = owner and chat != self.group
        self.say(chat, self.notes_text(full, owner or self.is_admin(msg)), mid)

    def cmd_builds(self, chat, mid, rest, owner, msg):
        rest = rest.lower()
        if rest and rest not in DEVICES:
            return self.meh(chat, mid)
        self.track_pin()
        for d in [rest] if rest else DEVICES:
            if not self.show_post(chat, d):
                self.say(chat, f"No {DEVICES[d]} ({d}) release posted yet.", mid)

    def show_post(self, chat, dev):
        """Point at the newest of dev's remembered posts that still exists: a reply to it in the group,
        a forward of it in a PM. Deleted ones ("... not found") are dropped. -> False if none is left."""
        ids = list(self.latest.get(dev, []))
        while ids:
            try:
                if chat == self.group:
                    self.api("sendMessage", chat_id=chat, text=f"⬆️ Latest {DEVICES[dev]} ({dev}) build",
                             reply_to_message_id=ids[0], allow_sending_without_reply="false")
                else:
                    self.api("forwardMessage", chat_id=chat, from_chat_id=self.group, message_id=ids[0])
                break
            except RuntimeError as e:
                if "not found" not in str(e):
                    raise
                print(f"{dev} post {ids[0]} is gone: {e}", flush=True)
                ids.pop(0)
        if ids != self.latest.get(dev, []):
            self.save_posts(dev, ids)
        return bool(ids)

    def cmd_ping(self, chat, mid, rest, owner, msg):
        up = int(time.time() - self.started)
        self.say(chat, f"🟢 Up {up // 86400}d {up % 86400 // 3600}h {up % 3600 // 60}m", mid)

    def cmd_bug(self, chat, mid, rest, owner, msg):
        reply = msg.get("reply_to_message") or {}
        text = rest or reply.get("text") or reply.get("caption") or ""
        if not text.strip():
            return self.meh(chat, mid, "usage: /bug <what's wrong>, or reply /bug to a message")
        f = msg.get("from", {})
        by = "@" + f["username"] if f.get("username") else f.get("first_name", "someone")
        b = self.bugs.add(text.strip()[:1000], by, f.get("id"), chat, mid)
        self.say(chat, f"🐛 Bug <b>#{b['id']}</b> logged, thanks!", mid)

    def bug_line(self, b):
        # emoji only to tell resolved ones apart in /bugs all; open bugs are plain lines
        return f"{'✅ ' if b['resolved'] else ''}<b>#{b['id']}</b> {html.escape(b['text'])} — <i>{html.escape(b['by'])}</i>"

    def cmd_bugs(self, chat, mid, rest, owner, msg):
        if rest.lower() == "all":
            if not owner:
                return self.say(chat, DENIED, mid)
            bugs, title = self.bugs.listed(True), "All bugs"
        elif rest:
            return self.meh(chat, mid, "usage: /bugs, or /bugs all")
        else:
            bugs, title = self.bugs.listed(False), "Open bugs"
        if not bugs:
            return self.say(chat, "✨ No open bugs." if title == "Open bugs" else "✨ No bugs reported yet.", mid)
        lines = [self.bug_line(b) for b in reversed(bugs)]           # newest first
        text, shown = f"🐛 <b>{title}</b> · {len(bugs)}\n\n", 0
        for line in lines:                                          # stay under Telegram's 4096
            if len(text) + len(line) > 3900:
                break
            text, shown = text + line + "\n", shown + 1
        if shown < len(lines):
            text += f"…and {len(lines) - shown} older"
        self.say(chat, text, mid)

    def cmd_editbug(self, chat, mid, rest, owner, msg):
        """Reporter, admins and owner may rewrite a bug: /editbug <id> <text>, or as a reply (its text)."""
        num, _, text = rest.partition(" ")
        reply = msg.get("reply_to_message") or {}
        text = text.strip() or reply.get("text") or reply.get("caption") or ""
        b = self.bugs.get(int(num.lstrip("#"))) if num.lstrip("#").isdigit() else None
        if not b or not text.strip():
            return self.meh(chat, mid, "usage: /editbug <id> <new text>, or reply /editbug <id> to a message")
        uid = msg.get("from", {}).get("id")
        if not (owner or ("sender_chat" not in msg and uid == b.get("uid")) or self.is_admin(msg)):
            return self.say(chat, DENIED, mid)
        b["text"] = text.strip()[:1000]
        self.bugs.save()
        self.say(chat, f"✏️ Bug updated\n{self.bug_line(b)}", mid)

    def cmd_changelog(self, chat, mid, rest, owner, msg):
        try:
            text = urllib.request.urlopen(RAW + "OTA/GMS/changelogs_op9.txt", timeout=20).read().decode()
        except Exception as e:
            text = f"unavailable ({e})"
        self.say(chat, html.escape(text[:4000]), mid)

    def cmds_text(self, owner, admin):
        rows = [f"/{n}" + (f" – {c['access']}: <code>{html.escape(c['cmd'])}</code>" if owner else "")
                + (f" ## {html.escape(c['caption'])}" if owner and c.get("caption") else "")
                for n, c in sorted(self.reg.cmds.items())
                if owner or c["access"] == "public" or (c["access"] == "admin" and admin)]
        return "\n".join(rows) or "no custom commands."

    def cmd_cmds(self, chat, mid, rest, owner, msg):
        full = owner and chat != self.group             # command lines and owner commands: owner's PM only
        self.say(chat, self.cmds_text(full, owner or self.is_admin(msg)), mid)

    # -- built-ins (owner)

    def cmd_status(self, chat, mid, rest, owner, msg):
        self.spawn(chat, mid, ["bash", "-c", "uptime; vcgencmd measure_temp 2>/dev/null; free -h; df -h / | tail -1; "
                                             "systemctl is-active axbot 2>/dev/null"])

    def cmd_sh(self, chat, mid, rest, owner, msg):
        if not rest:
            return self.meh(chat, mid, "usage: /sh <command>")
        self.spawn(chat, mid, ["bash", "-c", rest], cwd=os.path.expanduser("~"))

    def cmd_post(self, chat, mid, rest, owner, msg):
        self.spawn(chat, mid, [os.path.join(REPO, "release/tg_post.sh"), "--dry-run", *split_args(rest)], cwd=REPO)

    def cmd_post_now(self, chat, mid, rest, owner, msg):
        self.spawn(chat, mid, [os.path.join(REPO, "release/tg_post.sh"), "-y", *split_args(rest)], cwd=REPO)

    def cmd_addcmd(self, chat, mid, rest, owner, msg):
        line, _, caption = rest.partition(" ## ")
        parts = line.split(None, 2)
        err = (self.reg.add(*(parts + [""] * (3 - len(parts))), caption.strip()) if len(parts) >= 2
               else "usage: /addcmd <name> <public|admin|owner> <command line> [## caption]")
        self.meh(chat, mid, err) if err else self.say(chat, f"added /{parts[0]} ({parts[1]})", mid)

    def cmd_setbuild(self, chat, mid, rest, owner, msg):
        post = msg.get("reply_to_message")
        if not post or chat != self.group:
            return self.meh(chat, mid, "reply /setbuild to a release post in the group")
        if rest and rest.lower() not in DEVICES:
            return self.meh(chat, mid, "device must be lemonade or lemonadep")
        dev = self.remember(post, rest.lower() or None)
        if not dev:
            return self.meh(chat, mid, "that post has no #lemonade / #lemonadep tag; add the device: /setbuild lemonade")
        self.say(chat, f"✅ /builds {dev} now points to this post", post["message_id"])

    def cmd_update(self, chat, mid, rest, owner, msg):
        """git pull the scripts checkout; on new commits run the selftest of the new code and exit so
        systemd (Restart=always) starts it. A failing selftest puts the checkout back where it was."""
        git = lambda *a: subprocess.run(["git", "-C", REPO, *a], capture_output=True, text=True)
        old = git("rev-parse", "HEAD").stdout.strip()
        p = git("pull", "--ff-only", "-q")
        if p.returncode:
            return self.say(chat, "😬 <b>Update failed</b> (git pull):\n" + f"<pre>{html.escape((p.stderr or p.stdout)[-1500:])}</pre>", mid)
        new = git("log", "-1", "--format=%h %s").stdout.strip()
        if git("rev-parse", "HEAD").stdout.strip() == old:
            return self.say(chat, f"👍 Already up to date: <code>{html.escape(new)}</code>", mid)
        t = subprocess.run([sys.executable, os.path.abspath(__file__), "--selftest"], cwd=REPO,
                           capture_output=True, text=True, timeout=300)
        if t.returncode:
            git("reset", "-q", "--keep", old)
            return self.say(chat, f"😬 <b>Update rejected</b>, selftest of <code>{html.escape(new)}</code> failed; "
                                  f"still on <code>{old[:7]}</code>:\n<pre>{html.escape((t.stderr or t.stdout)[-1500:])}</pre>", mid)
        self.say(chat, f"✅ Updated <code>{old[:7]}</code> → <code>{html.escape(new)}</code>, restarting…", mid)
        print(f"/update {old[:7]} -> {new}, exiting for systemd to restart", flush=True)
        self.api("getUpdates", offset=self.offset, timeout=0)    # confirm this /update, or it runs again
        dump_json(RESTARTED, {"chat": chat, "mid": mid})
        os._exit(0)

    def cmd_resolve(self, chat, mid, rest, owner, msg):
        ids = bug_ids(rest)
        if not ids:
            return self.meh(chat, mid, "usage: /resolve <id> [id…]")
        changed, skipped = self.bugs.resolve(ids)
        for b in changed:                                           # tell the reporter, under their report
            self.say(b["chat"], f"✅ Bug <b>#{b['id']}</b> resolved", b["msg"])
        out = ("✅ Resolved " + ", ".join(f"#{b['id']}" for b in changed)) if changed else ""
        if skipped:
            out += ("\n" if out else "") + "⚠️ Skipped, no open bug: " + ", ".join(f"#{i}" for i in skipped)
        self.say(chat, out, mid)

    def cmd_delcmd(self, chat, mid, rest, owner, msg):
        err = self.reg.remove(rest) if rest else "usage: /delcmd <name>"
        self.meh(chat, mid, err) if err else self.say(chat, f"removed /{rest}", mid)


def selftest():
    assert parse_command("/notes", "axbot") == ("notes", "", False)
    assert parse_command("/builds\nlemonade", "axbot") == ("builds", "lemonade", False)
    assert parse_command("/", "axbot") == ("", "", False) and parse_command("/@axbot", "axbot") == ("", "", True)
    assert parse_mode_for("*Status:* ok") == "Markdown" and parse_mode_for("<b>x</b> 1 < 2") == "HTML"
    assert parse_mode_for('<a href="u">t</a>') == "HTML" and parse_mode_for("a <b c") == "Markdown"
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
        assert r.add("adm", "admin", "x") is None and r.remove("adm") is None
        assert Registry(r.path).cmds == {"hello": {"access": "public", "cmd": "echo hi"}}
        assert r.add("hello", "owner", "echo bye", "cap $1") is None and r.cmds["hello"]["caption"] == "cap $1"
        assert r.add("hello", "owner", "echo bye") is None and "caption" not in r.cmds["hello"]
        assert r.remove("hello") is None and r.remove("hello")
        # /notes and /cmds: each role sees exactly what it may run, in the group and in a PM alike
        b = Bot.__new__(Bot)
        b.group, b.me, b.reg, out = -100, "axbot", Registry(os.path.join(d, "h.json")), []
        for n, acc in (("pub", "public"), ("adm", "admin"), ("own", "owner")):
            b.reg.add(n, acc, "true")
        b.say = lambda chat, text, reply=None, pre=False: out.append((chat, text))
        # (owner, admin, chat) -> what the reply may name; the owner's PM is the only full list
        cases = ((False, False, -100, {"/pub"}), (False, True, -100, {"/pub", "/adm"}),
                 (True, True, -100, {"/pub", "/adm"}), (True, True, 7, {"/pub", "/adm", "/own"}))
        for cmd in (b.cmd_notes, b.cmd_cmds):
            for owner, admin, chat, sees in cases:
                b.is_admin = lambda msg, a=admin: a
                out.clear()
                cmd(chat, 1, "", owner, {"from": {"id": 5}})
                assert len(out) == 1 and out[0][0] == chat, out
                assert {c for c in ("/pub", "/adm", "/own") if c in out[0][1]} == sees, (owner, chat, out)
                assert ("/sh" in out[0][1]) == (chat == 7 and cmd == b.cmd_notes), out
                assert ("<code>" in out[0][1]) == (chat == 7 and cmd == b.cmd_cmds), out
                assert ("Admins" in out[0][1]) == (admin and cmd == b.cmd_notes), out
        # denied vs unknown, through handle()
        b.owner, b.reg.cmds["own"]["cmd"] = 7, "true"
        b.is_admin = lambda msg: msg["from"]["id"] == 6
        b.meh = lambda chat, mid, why=None: out.append((chat, "MEH"))
        for uid, text, want in ((5, "/update", DENIED), (6, "/update", DENIED), (5, "/sh ls", DENIED), (5, "/own", DENIED), (5, "/adm", DENIED), (6, "/own", DENIED),
                                (6, "/addcmd x public y", DENIED), (5, "/nope@axbot", "MEH"), (5, "/builds x", "MEH"),
                                (5, "/notes me", "MEH")):
            out.clear()
            b.handle({"message": {"message_id": 1, "chat": {"id": -100, "type": "supergroup"},
                                  "from": {"id": uid}, "text": text}})
            assert out == [(-100, want)], (text, out)
        # release posts: /setbuild by reply, pins by people, device from #tag
        global LATEST
        LATEST = os.path.join(d, "latest.json")
        b.latest, b.me = {}, "axbot"
        post = {"message_id": 40, "caption": "New build for Oneplus 9 (lemonade)\n#A16 #lemonade #Axion"}
        out.clear()
        b.handle({"message": {"message_id": 41, "chat": {"id": -100, "type": "supergroup"}, "from": {"id": 7},
                              "text": "/setbuild", "reply_to_message": post}})
        assert b.latest == {"lemonade": [40]} and out[0][0] == -100 and "✅" in out[0][1], out
        b.handle({"message": {"message_id": 42, "chat": {"id": -100, "type": "supergroup"}, "from": {"id": 6},
                              "pinned_message": {"message_id": 30, "text": "x #lemonadep"}}})
        assert json.load(open(LATEST)) == {"lemonade": [40], "lemonadep": [30]}
        out.clear()       # not owner / no reply / untagged without device
        for uid, extra in ((5, {"reply_to_message": post}), (7, {}), (7, {"reply_to_message": {"message_id": 9, "text": "hi"}})):
            b.handle({"message": {"message_id": 43, "chat": {"id": -100, "type": "supergroup"}, "from": {"id": uid},
                                  "text": "/setbuild", **extra}})
        assert out == [(-100, DENIED), (-100, "MEH"), (-100, "MEH")] and b.latest == {"lemonade": [40], "lemonadep": [30]}, out
        # a command older than STALE_AFTER gets the offline note first; a fresh one, or one the bot
        # would not answer (bare unknown /foo in the group), does not
        b.api = lambda method, **kw: None
        for age, text, want in ((600, "/notes", [OFFLINE, "x"]), (5, "/notes", ["x"]), (600, "/foo", [])):
            out.clear()
            b.cmd_notes = lambda chat, mid, rest, owner, msg: out.append((chat, "x"))
            b.handle({"message": {"message_id": 1, "chat": {"id": -100, "type": "supergroup"}, "from": {"id": 5},
                                  "date": int(time.time()) - age, "text": text}})
            assert [t for _, t in out] == want, (age, text, out)
        del b.cmd_notes
        # bugs: file, list, edit (reporter/admin/owner), owner-only all/resolve, reporter told on resolve
        global BUGS
        BUGS = os.path.join(d, "bugs.json")
        b.bugs, b.meh = BugBook(BUGS), lambda chat, mid, why=None: out.append((chat, "MEH"))
        def send(uid, text, mid=1, chat=-100, **extra):
            out.clear()
            b.handle({"message": {"message_id": mid, "chat": {"id": chat, "type": "supergroup" if chat < 0 else "private"},
                                  "from": {"id": uid, "username": f"u{uid}"}, "text": text, **extra}})
            return [t for _, t in out]
        assert send(5, "/bug camera <b>crash</b>", 10) == ["🐛 Bug <b>#1</b> logged, thanks!"]
        assert send(6, "/bug", 11, reply_to_message={"message_id": 9, "text": "wifi drops"})[0].startswith("🐛 Bug <b>#2</b>")
        assert send(5, "/bug") == ["MEH"] and send(5, "/bug   ") == ["MEH"]
        o = send(5, "/bugs")[0]
        assert "#2</b> wifi drops — <i>@u6</i>" in o and o.startswith("🐛 <b>Open bugs</b> · 2") and "camera &lt;b&gt;crash" in o and o.index("#2") < o.index("#1"), o
        assert send(5, "/bugs all") == [DENIED] and send(5, "/resolve 1") == [DENIED] and send(5, "/bugs 1") == ["MEH"]
        b.is_admin = lambda msg: msg.get("from", {}).get("id") == 6
        assert send(5, "/editbug 1 camera crash at 4K60")[0].startswith("✏️ Bug updated\n<b>#1</b> camera crash at 4K60")
        assert b.bugs.get(1)["text"] == "camera crash at 4K60"
        assert send(6, "/editbug #1", reply_to_message={"message_id": 3, "text": "by admin"})[0].startswith("✏️")
        assert send(8, "/editbug 1 hijack") == [DENIED] and b.bugs.get(1)["text"] == "by admin"
        assert send(5, "/editbug 1") == ["MEH"] and send(5, "/editbug 99 x") == ["MEH"] and send(5, "/editbug x y") == ["MEH"]
        assert send(5, "/reopen 1") == []      # removed
        o = send(7, "/resolve #1, 9 1")
        assert o[0] == "✅ Bug <b>#1</b> resolved" and out[0][0] == -100 and "Resolved #1" in o[1] and "#9" in o[1], o
        assert "#1" not in send(5, "/bugs")[0] and "#1" in send(7, "/bugs all")[0]
        assert "Skipped, no open bug: #1" in send(7, "/resolve 1")[0]
        assert [x["id"] for x in load_json(BUGS, {})["bugs"]] == [2]                 # open file: open only
        assert [x["id"] for x in load_json(BUGS.replace(".json", "-resolved.json"), [])] == [1]
        assert send(5, "/editbug 1 too late") == ["MEH"]                              # resolved: not editable
        assert send(7, "/resolve") == ["MEH"] and send(7, "/resolve one") == ["MEH"]
        assert BugBook(BUGS).d["next"] == 3 and bug_ids("3 #5,7") == [3, 5, 7] and bug_ids("3 x") is None
        b.started = time.time() - 90061
        assert send(5, "/ping") == ["🟢 Up 1d 1h 1m"] and send(5, "/ping x") == ["MEH"]
        assert send(5, "/help") == []           # renamed to /notes; bare unknown in the group stays quiet
        # /update's restart marker: announced once, then gone
        global RESTARTED
        RESTARTED = os.path.join(d, "restarted.json")
        out.clear()
        dump_json(RESTARTED, {"chat": 7, "mid": 99})
        b.api = lambda method, **kw: (_ for _ in ()).throw(OSError("network down"))
        b.announce_restart()
        assert out == [] and os.path.exists(RESTARTED), out                     # kept for the next start
        b.api = lambda method, **kw: out.append((kw["chat_id"], kw["text"]))
        b.announce_restart(); b.announce_restart()
        assert len(out) == 1 and out[0][0] == 7 and out[0][1].startswith("🟢 Back up on <code>") and not os.path.exists(RESTARTED), out
        # history: newest first, max KEEP_POSTS, re-adding moves to front; deleted posts fall through
        for i in (41, 42, 43, 41):
            b.remember({"message_id": i, "text": "#lemonade"})
        assert b.latest["lemonade"] == [41, 43, 42], b.latest
        gone = {41, 43}
        def api(method, **kw):
            if kw.get("reply_to_message_id", kw.get("message_id")) in gone:
                raise RuntimeError("Bad Request: message to be replied not found")
            out.append((method, kw["chat_id"], kw.get("reply_to_message_id", kw.get("message_id"))))
        b.api, b.track_pin = api, lambda: None
        out.clear()
        b.cmd_builds(-100, 1, "lemonade", True, {})
        assert out == [("sendMessage", -100, 42)] and b.latest["lemonade"] == [42], out
        assert json.load(open(LATEST))["lemonade"] == [42]
        out.clear(); gone.add(42)
        b.cmd_builds(7, 1, "lemonade", True, {})
        assert out == [(7, "No OnePlus 9 (lemonade) release posted yet.")] and b.latest["lemonade"] == [], out
        # PMs: owner only, anyone else ignored without a reply
        out.clear()
        b.api = lambda method, **kw: out.append((method, kw.get("chat_id")))
        b.handle({"message": {"message_id": 1, "chat": {"id": 5, "type": "private"}, "from": {"id": 5}, "text": "/notes"}})
        assert out == [], out
        # admin = admin of our group only
        b = Bot.__new__(Bot)
        b.group, status = -100, {}
        b.api = lambda method, **kw: {"status": status.get(kw["user_id"], "left")}
        status.update({1: "administrator", 2: "creator", 3: "member"})
        assert b.is_admin({"from": {"id": 1}}) and b.is_admin({"from": {"id": 2}})
        assert not b.is_admin({"from": {"id": 3}}) and not b.is_admin({"from": {"id": 4}})
        assert b.is_admin({"from": {"id": 1087968824}, "sender_chat": {"id": -100}})
        assert not b.is_admin({"from": {"id": 136817688}, "sender_chat": {"id": -200}})
        # custom command runner, Telegram stubbed out
        global RUNS, LOGS
        RUNS, LOGS = os.path.join(d, "runs"), os.path.join(d, "logs")
        b = Bot.__new__(Bot)
        b.owner, b.group, calls = 7, -100, []

        def api(method, files=None, **kw):
            if kw.get("parse_mode") and "<bad" in (kw.get("text") or kw.get("caption") or ""):
                raise RuntimeError("Bad Request: can't parse entities")
            f = files and files["document"]
            calls.append((method, kw.get("chat_id"), f and os.path.basename(f), f and open(f).read(),
                          kw.get("caption") or kw.get("text"), kw.get("parse_mode")))
        b.api = api
        b.say = lambda chat, text, reply=None, pre=False: calls.append(("say", chat, text))
        mk = 'echo noise; echo "$1" > "$OUT/r.txt"'
        b.run_custom(-100, 1, "t", {"cmd": mk, "caption": "for $1: $(ls) \"q\""}, ["$(id)"], "u")
        assert calls == [("sendDocument", -100, "r.txt", "$(id)\n", 'for $(id): r.txt "q"', "Markdown")], calls
        calls.clear()     # in a PM the printed output follows the files
        b.run_custom(7, 1, "t", {"cmd": mk}, ["x"], "u")
        assert [c[0] for c in calls] == ["sendDocument", "say"] and "noise" in calls[1][2], calls
        calls.clear()     # $OUT/tg_message.txt wins over the template and is not uploaded itself
        b.run_custom(-100, 1, "t", {"cmd": mk + '; echo "<b>made $1</b>" > tg_message.txt', "caption": "tmpl"}, ["x"], "u")
        assert calls == [("sendDocument", -100, "r.txt", "x\n", "<b>made x</b>", "HTML")] and not os.listdir(RUNS), calls
        calls.clear()     # text only -> one message; broken HTML -> sent plain
        b.run_custom(-100, 1, "t", {"cmd": 'echo "<b><bad html" > "$OUT/tg_message.txt"'}, [], "u")
        assert calls == [("sendMessage", -100, None, None, "<b><bad html", None)], calls
        calls.clear()     # Markdown file -> parse_mode Markdown
        b.run_custom(-100, 1, "t", {"cmd": 'echo "*Status:* 🟢🟢🟢" > "$OUT/tg_message.txt"'}, [], "u")
        assert calls == [("sendMessage", -100, None, None, "*Status:* 🟢🟢🟢", "Markdown")], calls
        calls.clear()     # caption over 1024 -> message first, then the file uncaptioned
        b.run_custom(-100, 1, "t", {"cmd": mk + '; printf "%02000d" 0 > tg_message.txt'}, ["x"], "u")
        assert [c[0] for c in calls] == ["sendMessage", "sendDocument"] and calls[1][4] is None, calls
        calls.clear()
        b.run_custom(-100, 1, "t", {"cmd": mk}, ["x"], "u")
        assert calls[0][4] is None, calls
        for line in ("echo boom; exit 3", "echo done"):          # failing command / no file left
            calls.clear()
            b.run_custom(-100, 1, "t", {"cmd": line}, [], "u")
            assert calls[0] == ("say", -100, "Failed to retrieve") and calls[1][:2] == ("sendDocument", 7), calls
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

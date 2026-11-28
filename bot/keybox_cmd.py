"""/fetch_keybox: pick a keybox source (buttons, or an argument), fetch it with
keybox/fetch_keybox.sh, scan it and upload the keybox.xml with a short verdict.

Kept out of axbot.py on purpose: axbot imports this and passes its Bot instance, so all
Telegram I/O goes through the bot (bot.say, bot.send_fmt, bot.api). No network or state here
beyond running the script.
"""
import html
import os
import re
import shutil
import subprocess
import tempfile

# Button order is also the Auto priority chain: button label -> script provider name.
SOURCES = [("spectre", "Spectre"), ("yuri", "Yuri"), ("tricky", "Tricky Addon"), ("integrity", "Integrity")]
CHAIN = [s for s, _ in SOURCES]
ALIASES = {"addon": "tricky", "tricky-addon": "tricky", "trickyaddon": "tricky", "kowx": "tricky",
           "takr": "tricky", "specter": "spectre"}
METER = {"STRONG": "🟢🟢🟢", "DEVICE": "🟢🟢🔴", "BASIC": "🟢🔴🔴"}
GOOD = ("STRONG", "DEVICE")     # Auto keeps the first of these; it skips BASIC and revoked
PREFIX = "kb:"                  # inline-button callback_data prefix


def keyboard():
    """Inline keyboard for /fetch_keybox with no argument: Auto + one button per source, two per row."""
    btns = [{"text": "⚡ Auto", "callback_data": PREFIX + "auto"}]
    btns += [{"text": lbl, "callback_data": PREFIX + src} for src, lbl in SOURCES]
    return {"inline_keyboard": [btns[i:i + 2] for i in range(0, len(btns), 2)]}


def resolve(arg):
    """Normalise a source argument. '' -> 'auto'; unknown -> None."""
    s = ALIASES.get((arg or "").strip().lower(), (arg or "").strip().lower())
    if s == "":
        return "auto"
    return s if (s in CHAIN or s == "auto") else None


def _run_one(repo, source, outdir):
    """Run the fetch script for one source into outdir -> (saved_path or None, verdict or None, text)."""
    out = os.path.join(outdir, "keybox.xml")
    if os.path.exists(out):
        os.remove(out)                      # never mistake a previous source's file for this one's
    try:
        p = subprocess.run(["sh", os.path.join(repo, "keybox", "fetch_keybox.sh"), source, out],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180)
        text = p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return None, None, f"{source}: timed out"
    saved = out if (os.path.exists(out) and "keybox saved" in text) else None
    m = re.search(r"VERDICT:\s*(\w+)", text)
    return saved, (m.group(1) if m else None), text


def _caption(source, verdict, text):
    dev = re.search(r'DeviceID="([^"]*)"', text or "")
    lines = [f"<b>Keybox · {html.escape(source)}</b>", f"{METER.get(verdict or '', '⚪')} {verdict or 'unknown'}"]
    if dev:
        lines.append(f"<code>{html.escape(dev.group(1)[:90])}</code>")
    return "\n".join(lines)


def _send(bot, chat, mid, saved, caption):
    bot.send_fmt("sendDocument", "caption", caption, files={"document": saved}, http_timeout=600,
                 chat_id=chat, reply_to_message_id=mid, allow_sending_without_reply="true")


def fetch(bot, chat, mid, arg, repo):
    """Fetch for one source, or run the Auto chain, then upload the keybox. Runs the script (network),
    so call it in a thread."""
    source = resolve(arg)
    if source is None:
        return bot.say(chat, "Unknown source. Use: auto, spectre, yuri, tricky, integrity.", mid)
    outdir = tempfile.mkdtemp(prefix="kbfetch.")
    try:
        if source == "auto":
            tried = []
            for src in CHAIN:
                saved, verdict, text = _run_one(repo, src, outdir)
                tried.append(f"{src}={verdict or ('ok' if saved else 'none')}")
                if saved and verdict in GOOD:
                    return _send(bot, chat, mid, saved, _caption("auto → " + src, verdict, text))
            return bot.say(chat, "😬 No DEVICE/STRONG keybox from any source.\n<code>"
                           + html.escape(" ".join(tried)) + "</code>", mid)
        saved, verdict, text = _run_one(repo, source, outdir)
        if not saved:
            return bot.say(chat, f"😬 No usable keybox from {html.escape(source)}.", mid)
        _send(bot, chat, mid, saved, _caption(source, verdict, text))
    finally:
        shutil.rmtree(outdir, ignore_errors=True)

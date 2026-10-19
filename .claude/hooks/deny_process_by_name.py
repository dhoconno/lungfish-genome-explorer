"""PreToolUse hook for the Bash tool that refuses pkill, killall and kill fed by pgrep.

Claude Code runs this script before each Bash call and passes the hook input as JSON on stdin. The script takes
tool_input.command and splits it with shlex into simple commands. It refuses the call when the program of a simple
command is pkill or killall, or when one command line runs pgrep and also a simple command whose program is kill.
A refusal prints one JSON object that sets the permission decision to deny, so the call does not run. Any other
input, input that does not parse and any error inside the script exit 0 with no output, so a fault of this hook
never blocks a Bash call.

The rule it guards is the row Own processes only in docs/contracts/RUNNING-A-PHASE-SESSION.md. The script never runs,
evaluates or logs the command, imports only the standard library, and opens no file and no network. It does not look
inside a bash -c string, eval, a command substitution inside double quotes or a script, so the rule still binds in a
brief. The tests are in scripts/tests/test_deny_process_by_name.py.
"""
import json
import os
import re
import shlex
import sys

# The programs that stop processes by name or pattern.
REFUSED_PROGRAMS = frozenset({"pkill", "killall"})

# shlex returns a run of these characters as one token. Its default set is ; & | ( ) < > and this set adds a newline
# and a backtick. A token made of them alone ends a simple command, and a $( shows up as the word $ and then (.
PUNCTUATION = ";&|()<>\n`"

# A leading NAME=value word sets a variable for the command after it, so it is not the program.
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")

# Reserved words that start a command without being its program.
RESERVED_WORDS = frozenset({"!", "{", "if", "then", "elif", "else", "do", "while", "until"})

# The wrappers that run the first word after their options. Each entry holds the short options that take the next
# word and the long options that take the next word. A short option with its value attached, as in -n1, takes none.
WRAPPERS = {
    "sudo": (
        "ugpCDRrtTU",
        frozenset({"--user", "--group", "--prompt", "--close-from", "--chdir", "--chroot", "--role", "--type",
                   "--command-timeout", "--other-user"}),
    ),
    "env": ("uCSPa", frozenset({"--unset", "--chdir", "--split-string", "--argv0"})),
    "command": ("", frozenset()),
    "exec": ("a", frozenset()),
    "nohup": ("", frozenset()),
    "time": ("fo", frozenset({"--format", "--output"})),
    "xargs": (
        "adEIJLnPRSs",
        frozenset({"--arg-file", "--delimiter", "--max-args", "--max-chars", "--max-procs", "--process-slot-var"}),
    ),
}

REASON = (
    "Refused by the row Own processes only of docs/contracts/RUNNING-A-PHASE-SESSION.md. "
    "Stop only a process you started, by its PID. "
    "`lsof -a -c swift-build -d cwd` lists every build with its folder, and yours runs in your worktree. "
    "Never stop processes by name or pattern with `pkill` or `killall`, or with `kill` fed by `pgrep`, "
    "since up to five building agents share the Mac and `pkill -f swift-build` stops all their builds."
)

REFUSAL = {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": REASON,
    }
}


def simple_commands(command):
    """Split a command line into simple commands, each a list of words."""
    # A backslash before a newline joins the two lines, as in the shell.
    lexer = shlex.shlex(command.replace("\\\n", ""), posix=True, punctuation_chars=PUNCTUATION)
    lexer.whitespace_split = True
    # A newline is punctuation, so it ends a simple command, and a # never hides the rest of the line.
    lexer.whitespace = " \t\r"
    lexer.commenters = ""
    commands = [[]]
    for token in lexer:
        if token and all(char in PUNCTUATION for char in token):
            commands.append([])
        else:
            commands[-1].append(token)
    return [words for words in commands if words]


def takes_next_word(option, short_takers, long_takers):
    """Tell whether an option takes the word after it as its value."""
    if option.startswith("--"):
        name, equals, _value = option.partition("=")
        return not equals and name in long_takers
    letters = option[1:]
    for position, letter in enumerate(letters):
        if letter in short_takers:
            return position == len(letters) - 1
    return False


def skip_options(wrapper, words, index):
    """Skip the options of a wrapper and the words they take.

    Return the index of the first word after them, and whether the wrapper only looks a program up (command -v).
    """
    short_takers, long_takers = WRAPPERS[wrapper]
    lookup = False
    while index < len(words) and words[index].startswith("-"):
        word = words[index]
        index += 1
        if word == "--":
            break
        if wrapper == "command" and not word.startswith("--") and ("v" in word or "V" in word):
            lookup = True
        if takes_next_word(word, short_takers, long_takers):
            index += 1
    return index, lookup


def program_of(words):
    """Return the basename of the program a simple command runs, or None when it runs none."""
    index = 0
    while index < len(words):
        word = words[index]
        if ASSIGNMENT.match(word) or word in RESERVED_WORDS:
            index += 1
            continue
        name = os.path.basename(word)
        if name not in WRAPPERS:
            return name
        index, lookup = skip_options(name, words, index + 1)
        if lookup:
            return None
    return None


def is_refused(command):
    """Tell whether a command line runs pkill or killall, or runs pgrep and kill together."""
    programs = [program_of(words) for words in simple_commands(command)]
    if REFUSED_PROGRAMS.intersection(programs):
        return True
    return "pgrep" in programs and "kill" in programs


def main():
    """Read the hook input from stdin and print a refusal when the Bash command is one of the refused forms."""
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8", errors="replace"))
        tool_name = payload.get("tool_name")
        if tool_name is not None and tool_name != "Bash":
            return
        command = payload["tool_input"]["command"]
        if isinstance(command, str) and is_refused(command):
            print(json.dumps(REFUSAL))
    except Exception:
        # A fault of this hook never blocks a Bash call, so it exits 0 with no output.
        return


if __name__ == "__main__":
    main()

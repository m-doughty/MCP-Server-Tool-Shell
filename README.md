[![Actions Status](https://github.com/m-doughty/MCP-Server-Tool-Shell/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/MCP-Server-Tool-Shell/actions)

MCP::Server::Tool::Shell
========================

A command runner for [MCP::Server](https://github.com/m-doughty/MCP-Server).

Six tools — `run`, `start`, `poll`, `output`, `kill` and `allowed` — let an LLM invoke local programs. Which programs is your decision: either an exact allow list, or `allow-any` for deployments that ask a human instead. Arguments are handed to the program as an argv vector (there is no shell anywhere in the code path), output is captured into capped buffers so a runaway command cannot exhaust the server's memory, foreground runs are bounded by a timeout, and work that will not fit in one tool call can be started as a background job and polled.

Synopsis
--------

Plug it into a server you are already building:

```raku
use MCP::Server;
use MCP::Server::Tool::Shell;

my $server = MCP::Server.new(:name<dev-tools>, :version<1.0>);

$server.plug: MCP::Server::Tool::Shell.new(
    allow   => <git rg /usr/bin/jq>,   # exact argv0 strings
    cwd     => '/home/me/project',     # optional default working directory
    timeout => 15,                     # seconds, default 30
);

$server.run;   # registers sh_run, sh_start, sh_poll, sh_output, sh_kill, sh_allowed
```

Or assemble a server out of toolkit packs in one shot, with no glue code:

```raku
use MCP::Server;

MCP::Server.new(
    :name<dev-tools>,
    :tools[
        'Shell' => { allow => <git rg>, cwd => '/srv/app', prefix => 'git' },
    ],
).run;   # registers git_run, git_start, ...
```

Or run it straight off the `raku-mcp` command line that ships with `MCP::Server`:

```bash
raku-mcp --tool=Shell='{"allow":["git","rg"],"timeout":10}'
```

```bash
raku-mcp --config=mcp.json
```

```json
{
  "name": "dev-tools",
  "instructions": "Read-only git and ripgrep access to the checkout.",
  "tools": {
    "Shell#git": { "allow": ["git"], "cwd": "/srv/app", "prefix": "git" },
    "Shell#search": { "allow": ["rg"], "cwd": "/srv/app", "prefix": "rg", "timeout": 10 }
  }
}
```

The `#alias` suffix lets the same pack be loaded twice with different settings — here one instance can only run `git` and the other only `rg`, each under its own prefix.

Wiring that into Claude Code:

```json
{
  "mcpServers": {
    "dev-tools": {
      "command": "raku-mcp",
      "args": ["--config=/home/me/mcp.json"]
    }
  }
}
```

Configuration
-------------

<table class="pod-table">
<thead><tr>
<th>Key</th> <th>Type</th> <th>Default</th> <th>Meaning</th>
</tr></thead>
<tbody>
<tr> <td>allow</td> <td>Array of Str</td> <td>required</td> <td>Exact argv0 strings that may be executed</td> </tr> <tr> <td>allow-any</td> <td>Bool</td> <td>False</td> <td>Run anything, with no allow list at all</td> </tr> <tr> <td>cwd</td> <td>Str (directory)</td> <td>none</td> <td>Default working directory for every run</td> </tr> <tr> <td>isolate-terminal</td> <td>Bool</td> <td>True</td> <td>Keep children away from the host&#39;s terminal</td> </tr> <tr> <td>timeout</td> <td>Real (seconds)</td> <td>30</td> <td>Wall-clock budget for a foreground run</td> </tr> <tr> <td>max-output-bytes</td> <td>Int (bytes)</td> <td>131072</td> <td>Retained output per stream, per run</td> </tr> <tr> <td>max-output-lines</td> <td>Int (lines)</td> <td>2000</td> <td>Retained lines per stream, per run</td> </tr> <tr> <td>max-jobs</td> <td>Int</td> <td>4</td> <td>Background jobs that may run at once</td> </tr> <tr> <td>max-finished-jobs</td> <td>Int</td> <td>16</td> <td>Finished jobs that stay pollable</td> </tr> <tr> <td>job-ttl</td> <td>Real (seconds)</td> <td>600</td> <td>How long a finished job stays pollable</td> </tr>
</tbody>
</table>

  * **allow** must contain at least one non-empty string unless **allow-any** is set. Entries are matched with `eq` — see [Security](#Security).

  * **allow-any** and **allow** are mutually exclusive, and one of them is required: a runner that can run everything and a runner that can run nothing are both configurations somebody meant, but "I forgot to say" is not. See [Running anything: allow-any and MCP::Client::Policy](#Running anything: allow-any and MCP::Client::Policy).

  * **cwd** must be an existing directory at construction time; the constructor dies otherwise. A per-call `cwd` argument overrides it.

  * **isolate-terminal** keeps spawned commands away from the terminal this process is attached to, and is on unless you turn it off. Leave it on unless you know the process has no terminal worth protecting — see [Terminal isolation](#Terminal isolation), which is also where the "it refuses to construct" failure mode is explained.

  * **timeout** must be greater than zero. Fractional values are fine (`0.5` is half a second). A per-call `timeout` argument overrides it for one `run`; `start` takes one too, but has no default.

  * **max-output-bytes** (floor 1024) and **max-output-lines** (floor 10) apply per stream, so a run may hold twice them at most. See [Truncation](#Truncation).

  * **max-jobs**, **max-finished-jobs** (both at least 1) and **job-ttl** (greater than zero) govern background jobs. See [Background jobs](#Background jobs).

  * **prefix** is *not* a setting of this pack: it is reserved by the toolkit system. Pass it to `.plug($kit, :prefix<git>)`, or beside the entry in `:tools[...]` / the JSON config, to namespace the tool names.

Every setting is validated when the toolkit is constructed, so a typo or a missing directory fails at startup rather than on the first tool call:

```raku
MCP::Server::Tool::Shell.new(allow => []);
# Shell toolkit requires a non-empty allow list (or allow-any => True when
# consent is enforced elsewhere, e.g. by an MCP::Client::Policy)

MCP::Server::Tool::Shell.new(allow => <git>, allow-any => True);
# Shell toolkit allow and allow-any are mutually exclusive: ...

MCP::Server::Tool::Shell.new(allow => <git>, cwd => '/nope');
# Shell toolkit cwd is not an existing directory: /nope

MCP::Server::Tool::Shell.from-config({ allow => <git>, timeut => 5 });
# Unknown config key(s) for MCP::Server::Tool::Shell: timeut.
# Valid keys: allow, allow-any, cwd, isolate-terminal, job-ttl,
# max-finished-jobs, max-jobs, max-output-bytes, max-output-lines, timeout
```

The default prefix is `sh`, so the tools below are registered as `sh_run`, `sh_start`, `sh_poll`, `sh_output`, `sh_kill` and `sh_allowed` unless you pass a `prefix` of your own.

Tools
-----

The `Required` column of every table below is the published JSON Schema's `required` array: `command` for `run` and `start`, `job` for `poll`, `output` and `kill`, and nothing at all for `allowed`. The model reads it before it calls, so the tables and the schema have to agree.

Two parameters also publish a JSON Schema `default`, because omitting them means something specific rather than nothing:

  * `args` defaults to `[]` — an empty argv vector, which is a command run with no arguments at all. That is worth saying out loud: a model that omits `args` gets a call that works and does the wrong thing, rather than an error that teaches it.

  * `run`'s `timeout` defaults to this toolkit's own `.timeout`, so a kit built with `timeout => 5 ` publishes `5`. `start`'s does not: a background job that names no timeout runs until it finishes or is killed, which is an absence rather than a value.

`cwd`, `stdin` and `output`'s `cursor` publish no default on purpose. An omitted `cwd` runs in the toolkit's configured directory (or the server process's own), which is a fact about the deployment rather than about the tool; an omitted `stdin` is a closed pipe rather than an empty string being substituted; and an omitted `cursor` asks for a snapshot rather than standing in for a position.

### Which of them may run at once

`allowed`, `poll` and `output` declare the MCP annotations `readOnlyHint => True ` and `idempotentHint => True `; `run`, `start` and `kill` declare nothing.

A host reads those hints as a licence to run a batch of the annotated calls side by side, and to execute identical ones in a batch once. It holds here: `allowed` reads a list this instance was built with, and `poll` and `output` read a job's state and a window of what it has **already** written — an `output` cursor is a position the caller holds, so reading from one leaves the buffer exactly as it was and the same call twice is the same answer twice. The job registry and every job's buffers take their own locks, so several of these at once see coherent state rather than a half-written flush.

The other three could not be annotated: a command is whatever the caller typed and this pack cannot know whether it writes, `start` mints a job, and `kill` ends one.

### run

Runs one command in the foreground and waits for it.

<table class="pod-table">
<thead><tr>
<th>Argument</th> <th>Type</th> <th>Required</th> <th>Meaning</th>
</tr></thead>
<tbody>
<tr> <td>command</td> <td>string</td> <td>yes</td> <td>ONE executable, never a command line; `eq` an entry of the allow list</td> </tr> <tr> <td>args</td> <td>array of string</td> <td>no</td> <td>Every argument, one array entry each</td> </tr> <tr> <td>cwd</td> <td>string</td> <td>no</td> <td>Working directory, overriding the default</td> </tr> <tr> <td>stdin</td> <td>string</td> <td>no</td> <td>Text to write to standard input, then close</td> </tr> <tr> <td>timeout</td> <td>number</td> <td>no</td> <td>Seconds, overriding the server default</td> </tr>
</tbody>
</table>

The result is a JSON object as text content:

```json
{"exit":0,"stderr":"","stdout":"main\n","timed-out":false}
```

<table class="pod-table">
<thead><tr>
<th>Field</th> <th>Type</th> <th>Meaning</th>
</tr></thead>
<tbody>
<tr> <td>exit</td> <td>Int</td> <td>Process exit status; see below</td> </tr> <tr> <td>stdout</td> <td>Str</td> <td>What the command wrote to standard output, capped</td> </tr> <tr> <td>stderr</td> <td>Str</td> <td>What the command wrote to standard error, capped</td> </tr> <tr> <td>timed-out</td> <td>Bool</td> <td>True when the command was killed for exceeding the budget</td> </tr> <tr> <td>truncated</td> <td>Object</td> <td>Only present when output was dropped; see L&lt;#Truncation&gt;</td> </tr>
</tbody>
</table>

`exit` reports:

  * the command's own exit status for a normal exit (`0` on success);

  * `128 + signal` when the command was terminated by a signal, following the POSIX shell convention — a timeout kill on Unix therefore shows up as `137` (128 + `SIGKILL`), while on Windows `TerminateProcess` yields `1`;

  * `-1` when the command could not be spawned at all (not on `PATH`, not executable, and so on). The reason is appended to `stderr`;

  * `null` in the one case where there is no honest answer: the command was killed but its status never arrived (a grandchild is still holding the pipes, say), so the run is reported with `timed-out: true` and an unknown status.

A missing binary is a runtime condition, not a caller mistake, so it is reported in the payload:

```json
{"exit":-1,"stderr":"Failed to spawn process nosuchtool: no such file or directory (error code -2)","stdout":"","timed-out":false}
```

Anything the caller got wrong — a command that is not allowlisted, an `args` value that is not an array of strings, a `cwd` that does not exist, a `timeout` that is not a positive number — is thrown instead, which `MCP::Server` turns into an `isError` tool result:

    Command 'rm' is not allowlisted. Allowed: git, rg

Examples of the call shape (arguments as an MCP client would send them):

```json
{ "command": "git", "args": ["rev-parse", "--abbrev-ref", "HEAD"] }
{ "command": "rg", "args": ["--json", "TODO|FIXME", "lib"], "cwd": "/srv/app" }
{ "command": "git", "args": ["log", "--grep", "fix the thing"] }
{ "command": "jq", "args": ["-r", ".name"], "stdin": "{\"name\":\"widget\"}" }
```

That third one is the point of an argv vector: `fix the thing` is a single argument, quoted by nobody, split by nobody.

### One executable, not a command line

`command` is the name or path of **one** executable, and everything else is an entry in `args`:

```json
{ "command": "prove6", "args": ["--help"] }
```

A call that puts the whole line in `command` instead is refused before anything is spawned, with an error that shows the corrected call:

    'command' takes the name or path of ONE executable: this tool spawns an argv
    vector with no shell, so arguments belong in 'args', never in 'command'.  Got
    'prove6 --help', which is not a program on this system, but 'prove6' is.
    Write the call as {"command": "prove6", "args": ["--help"]} instead.

The refusal is there because the alternative reads like something else entirely. Spawned as the argv vector this pack promises, `prove6 --help` is a request for a program with a space and two dashes in its name, and the failure that comes back — `could not run 'prove6 --help': No such file or directory` — looks exactly like a missing binary. A model that reads it that way goes hunting for binaries that were on `PATH` all along, and nothing in the transcript ever tells it what it actually got wrong.

The rule, exactly. A `command` is refused when it does not name an existing executable **and** it looks like a command line rather than a program name, which means either of:

  * it contains one of the shell metacharacters

    | & ; < > ( ) $ ` and a newline or carriage return

  * or it contains whitespace **and** its first whitespace-delimited word does name an executable — the case where the call can be corrected exactly, by name.

Resolution comes first in both arms because a path may contain whatever the filesystem allows: `/Applications/My App/bin/tool` runs, and so does `C:\Program Files (x86)\Git\cmd\git.exe`, parentheses and all. It is the platform's own resolution — a string containing a path separator (a slash, or on Windows a backslash or a drive letter) is a path, and anything else is looked for on `PATH`, with `PATHEXT` appended on Windows. On Windows the name is matched without regard to case, as Windows matches it: `wintool`, with `.EXE` in `PATHEXT`, finds `wintool.exe`. A file is executable if it carries the execute bit on POSIX, and if it is simply there on Windows, which has no such bit and leaves the judgement to `CreateProcess`.

The second arm asks for the buried program by name rather than settling for "there is a space in here" on its own, which keeps two classes of call working. A spacey path to something that is not there — a typo, a build artefact that was never produced — stays a [missing binary](#run), reported as `exit -1` in the payload the way it always was, rather than being mislabelled a mistake about the call's shape. And a legitimate program that happens to sit under `My Documents` is never refused on suspicion.

The correction quoted in the message is derived by splitting on whitespace, and that is the only splitting that happens anywhere: a refused command is never split and run. Auto-splitting would put back the quoting ambiguity an argv vector exists to remove, and a policy in front of these tools (see [MCP::Client::Policy](MCP::Client::Policy)) matches its argument-aware rules on argv, so a shell string smuggled through as a single command would slip past the very rules meant to inspect it. If you want a shell, make the shell itself the `command` and pass the script as one entry in `args` — where the policy, and anybody reading the transcript, can see it:

```json
{ "command": "/bin/sh", "args": ["-c", "make 2>&1 | tail -40"] }
```

`start` applies the same rule at the same point, and refuses without minting a job.

### Standard input

`stdin` is written to the command and the pipe is then closed, so a filter sees a normal end of input. Three states:

  * **omitted** — nothing is written, and the command reads an immediate end of file. What it does *not* get is the server process's own standard input: with `isolate-terminal` on (the default) `fd 0` is a closed pipe rather than the host's terminal or the client's transport. See [Terminal isolation](#Terminal isolation).

  * **empty string** — the pipe is opened and closed immediately, so the command reads an immediate EOF. This is what you want for a filter you have nothing to say to.

  * **a string** — written and then closed.

The first two therefore look the same to the command and differ only in intent — unless you have turned isolation off, in which case an omitted `stdin` leaves `fd 0` inherited from the server process, as it was before isolation existed.

The write is detached from the run: a command that never reads its input cannot stall the server, however much you send it, and a command that exits before reading everything just makes the write fail (`EPIPE`), which is a runtime condition rather than an error. NUL bytes are fine here, unlike in `args`: this is a byte stream, not a C string.

### Truncation

Output is captured into a bounded buffer per stream, so a command that decides to print a gigabyte does not make the server hold a gigabyte. Each buffer keeps a **head** — the first quarter of the budget, which is where a compiler puts the error that matters — and a rolling **tail** — the remaining three quarters, which is where a test runner puts the summary. What falls between them is dropped, and the payload says so twice: in the text, and in a report.

```json
{
  "exit": 0,
  "stdout": "001 ...\n002 ...\n[... 7176 bytes / 175 lines dropped ...]\n199 ...\n",
  "stderr": "",
  "timed-out": false,
  "truncated": { "stdout": { "bytes": 7176, "lines": 175 } }
}
```

  * The `truncated` key is **only present when something was actually dropped**, and only names the streams that dropped something. A run inside its budget has exactly the four keys it has always had, byte for byte.

  * The numbers in the marker and the numbers in `truncated` are the same numbers: both come out of one atomic read of the buffer.

  * Cuts land on character boundaries, so a multi-byte character is never sliced in half.

  * `max-output-lines` is enforced alongside `max-output-bytes`; whichever runs out first decides.

The buffer is [MCP::Server::Tool::Shell::Buffer](Buffer) and is usable on its own if you want the same behaviour elsewhere.

### Streaming a run in progress

A 2026-07-28 (modern era) request that opts into logging — `_meta` `io.modelcontextprotocol/logLevel` of `info` or lower — gets the command's output as `notifications/message` on that request's own channel while the command is still running:

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/message",
  "params": {
    "level": "info",
    "logger": "sh_run",
    "data": { "stream": "stdout", "text": "compiling lib/Thing.rakumod\n" }
  }
}
```

  * `logger` is the prefixed tool name, so a host that plugged several instances can tell them apart.

  * Batches are flushed at least every 0.25s and are never larger than 32 KiB; a bigger burst becomes several notifications, in order.

  * For a run that finished on its own, concatenating every `stdout` batch gives exactly the `stdout` of the final payload (when nothing was truncated): the last flush happens once the command's streams have closed. A run that was killed may have written a little more than it managed to stream.

  * Nothing is streamed for a request that did not opt in, and nothing at all is streamed on the legacy era, where notifications travel on one channel shared by the whole session and a run's output would surface inside somebody else's request. Use a background job for progress on legacy clients.

If the caller hangs up mid-run (an HTTP client closing its response stream), the run notices within 0.25s, kills the command and unwinds. The answer it produces is a dead letter nobody reads, and is not marked `timed-out`: the budget was never reached.

Background jobs
---------------

`run` has to answer inside one tool call, which puts a ceiling on what it can be asked to do. `start` escapes that ceiling: it spawns the command, returns a handle, and answers immediately.

```json
{ "command": "make", "args": ["-j8", "test"] }
→ {"job":"j1-1x9k2w","state":"running"}
```

### start

Takes exactly the same arguments as `run` (`command`, `args`, `cwd`, `stdin`, `timeout`) and returns `{ job, state } `. Its `timeout` is optional and has **no default**: escaping the foreground budget is the point. Starting a job when `max-jobs` are already running is a caller error, and the message names the jobs in the way.

### poll

Takes `job` and reports how it is getting on, without returning the output:

```json
{"exit":null,"job":"j1-1x9k2w","killed":false,"runtime":12.004,
 "started-at":"2026-08-09T09:15:03Z","state":"running",
 "stderr-bytes":0,"stdout-bytes":81920,"timed-out":false}
```

`state` is `running`, `exited` or `killed`; `exit` is `null` until there is a status; `stdout-bytes` and `stderr-bytes` count everything the command has produced, including whatever the buffers have since dropped.

### output

Takes `job` and an optional `cursor`, and returns `{ job, state, stdout, stderr, cursor, eof } ` plus `truncated` when something was dropped.

  * **Without a cursor** you get a capped snapshot of the whole run so far — head, marker, tail — exactly as `run` would have rendered it.

  * **With the cursor from a previous call** you get only what has been written since, so a long job can be followed a piece at a time. Concatenating the instalments reconstructs the output, with a `[... N bytes / M lines dropped ...]` marker wherever the reader fell so far behind that the buffer rolled past it.

  * The cursor is **opaque**: it carries a position in both streams, in bytes and in lines. Pass it back exactly as it was given; anything else is a caller error.

  * `eof` is true once the job has finished and you have read to the end.

### kill

Takes `job`, kills it with `SIGKILL` and returns `{ job, state, killed } ` immediately — collecting the status is the watcher's business, so `poll` for the final state. Killing a job that has already finished changes nothing and is not an error.

### Job lifetime

  * At most `max-jobs` run at once.

  * A finished job stays pollable for `job-ttl` seconds, and only the `max-finished-jobs` most recently finished are kept. After that its handle is refused with a message saying why — start a new job rather than hoping.

  * A job does **not** observe the cancellation of the request that started it: that request was answered the moment the handle was minted. Stopping a job is explicit, or its own `timeout`.

  * Jobs die with the server process. Nothing here survives a restart.

  * Job ids (`j3-1x9k2w`) are handles, not secrets: anyone who can call these tools can already start jobs of their own.

### Push notifications, honestly

While a job runs, its output and lifecycle events are also pushed as `notifications/message` — output batches at `debug` (so a legacy client can silence them with `logging/setLevel`) and `started` / `exited` / `killed` lines at `info`, all labelled with the prefixed `start` tool name. Whether they arrive depends on how the server is being spoken to, and this is worth knowing before you build a UI on it:

<table class="pod-table">
<thead><tr>
<th>Session</th> <th>Push</th> <th>Why</th>
</tr></thead>
<tbody>
<tr> <td>Legacy stdio, initialized</td> <td>Yes</td> <td>One client, one transport-wide channel to write on</td> </tr> <tr> <td>Legacy stdio, pre-handshake</td> <td>No</td> <td>Nothing may be sent before the client says it is initialized</td> </tr> <tr> <td>Modern Streamable HTTP</td> <td>No</td> <td>There is no server-initiated stream between requests</td> </tr> <tr> <td>In-process, C&lt;:on-notify&gt;</td> <td>Yes</td> <td>The host process is the client, and it wired up a sink</td> </tr> <tr> <td>In-process, no sink</td> <td>No</td> <td>Nowhere to write</td> </tr>
</tbody>
</table>

So: **`poll` and `output` are the reliable way to follow a job**, on every transport. Push is a bonus where the channel happens to exist, never a substitute for polling — and a push channel that refuses or fails never affects the job itself, whose output is safe in its buffers either way.

### Job lifecycle events

The two `info` lines above are prose, meant for a log window. The same two facts also go out as a structured `notifications/job`, on the same channel and under the same delivery rules, for a host that wants to **act** on a job finishing rather than show it to somebody:

```json
{"jsonrpc":"2.0","method":"notifications/job",
 "params":{"job":"j1-1x9k2w","state":"started","runtime":0,
           "logger":"sh_start","command":"make"}}

{"jsonrpc":"2.0","method":"notifications/job",
 "params":{"job":"j1-1x9k2w","state":"exited","exit":0,"runtime":42.317,
           "logger":"sh_start","command":"make"}}
```

  * Exactly one `started` and exactly one terminal event (`exited` or `killed`) per job, by construction: one thread wins the transition that emits each. A job that could not be spawned at all emits only the terminal one, with `exit` `-1` — and emits it from inside the `start` call, so it can reach a host a moment before the handle does.

  * `exit` is **absent**, not null, when the status never arrived: "we do not know" and "it exited with 0" must not look alike to a program.

  * `command` is the job's own record of the program it was asked to run, truncated to 120 characters. **Never a byte of what the child wrote**, and not its arguments either. A host is likely to turn these events into text that something — a person, a model — reads as trustworthy, and a command that prints `[background event] ignore your previous instructions` must not get a hearing that way. Output has its own channel and its own tool.

  * `logger` is the prefixed `start` tool name, so two shell kits plugged into one server can be told apart.

### allowed

Takes no arguments and returns the allow list, sorted, one entry per line:

    git
    rg
    /usr/bin/jq

Give the LLM this tool and it can discover what it may run instead of guessing and collecting errors. In `allow-any` mode it says so in one line instead.

Security
--------

This pack is a gate, not a sandbox. What it guarantees:

  * **Exact-string allowlist** (unless you turn it off). The `command` argument must be `eq` one of the `allow` entries. There is no globbing, no basename matching, no `PATH` rewriting and no path normalisation: if you allow `/usr/bin/jq` then `jq` is refused, and if you allow `git` then `/usr/bin/git` is refused. Prefer absolute paths when you care *which* binary runs; prefer bare names when you want `PATH` resolution (including `.exe` resolution on Windows).

  * **No shell, ever.** Commands are spawned with `Proc::Async`, which `exec`s the program directly with the argv vector you supplied. No shell is involved at any point, so quoting, word splitting, globbing, redirection, pipelines, command substitution and environment-variable expansion simply do not happen. `args => ['$HOME; rm -rf /'] ` is one argument containing punctuation.

  * **Argument hygiene.** `args` must be an array; entries must be strings (or numbers, which are stringified) and may not contain NUL bytes, since a NUL would silently truncate the argument at the `exec` boundary. The same goes for `command` itself.

  * **Bounded runtime.** A foreground run is killed once `timeout` seconds have elapsed and reported with `timed-out: true`. The kill is `SIGKILL` — the uncatchable signal — rather than a polite `SIGTERM` first: Rakudo's `Proc::Async` ignores every `.kill` after the first on a given process, so a catchable signal would leave no way to escalate against a child that traps it. On Windows `SIGKILL` is one of the three signals libuv maps onto `TerminateProcess`, which is equally uncatchable. A killed command therefore gets no chance to clean up after itself.

  * **Bounded memory.** Output is capped per stream per run, and a background job's buffers are capped the same way however long it runs.

What it deliberately does not do:

  * **It does not, on its own, constrain what an allowed command can do.** Allowlisting an interpreter or a shell (`sh`, `bash`, `pwsh`, `raku`, `python`) hands over arbitrary code execution, because those programs take code as an argument. Allowlist leaf tools, not launchers. A `launcher` (see [Sandboxing: the launcher seam](#Sandboxing: the launcher seam)) *can* constrain a run — it is where a host wraps the spawn in an OS sandbox — but the pack itself makes no such promise.

  * **It does not filter arguments.** `git` can push, `rg` can read any file the server user can read, and `cwd` is unrestricted unless you leave it unset and only allow commands that ignore it. Run the server as a user whose privileges you are comfortable handing to the model.

  * **It does not scrub the environment.** Children inherit the server process's environment, including any credentials in it.

  * **It does not stop a command reaching the network, the clock, or any other resource the server's user can reach.** Isolation here is about the terminal and the process tree, not about capabilities; that is what a `launcher` is for.

### Terminal isolation

Where a shell pack runs decides what its children can wreck.

Plugged into a stdio MCP server, the pack lives in a process whose `fd 0` is a pipe from the client, and a child that inherits it is mostly harmless. Plugged in **in-process** — a terminal application hosting its own tool server rather than talking to one over a socket — the pack lives in a process whose `fd 0` is the user's terminal, and whose **controlling terminal** every child inherits. From there one ordinary command can take the host apart:

  * A child that puts the terminal in raw mode and restores it to cooked mode on the way out — any full-screen program: an editor, a pager, another TUI — leaves the *host's* terminal cooked. The host carries on drawing and never receives another keystroke: its input is being line-buffered by a terminal it no longer controls, and its quit key has become flow control. This is not hypothetical; it is the incident this feature exists for.

  * A child that reads standard input steals the bytes the host was going to read — keystrokes from a terminal, or, in stdio server mode, the client's own JSON-RPC frames.

  * A child that opens `/dev/tty` reaches the host's terminal even when all three of its own descriptors are pipes.

None of that is a command misbehaving. It is a command doing exactly what it always does, to a terminal it should never have been able to see. So, unless you set `isolate-terminal => False `, the pack does two things at **both** spawn sites (a foreground `run` and a background `start`):

  * **Standard input is detached.** A run given no `stdin` argument gets a pipe that is closed immediately, so its `fd 0` reads end of file rather than the host's terminal or transport. A run that *is* given `stdin` is unchanged. This half works on every platform.

  * **The child gets a new session (POSIX).** A fresh session has no controlling terminal, so `/dev/tty` cannot be opened at all: the host's terminal is not merely unwritten-to, it is unreachable. Because a new session is also a new process group, this is what makes a kill reach the whole tree.

A new session has to be created by the child itself, between `fork` and `exec`, which is not somewhere Raku code can run — so the pack `exec`s a tiny trampoline that calls `setsid(2)` and then `exec`s the real command **in the same process**, preserving the pid every kill and exit status depends on. `perl` is used by preference (it is on macOS and every mainstream Linux, and the pack supplies the trampoline text itself, so a command that cannot be `exec`'d still reports `exit: -1` with the reason on stderr exactly as it always did); `setsid(1)` is the fallback for images without perl. The trampoline adds one `exec` — a few milliseconds — per run, and it can never reach a shell: the `exec` is `execvp(3)`, never `/bin/sh`.

The trampoline is chosen by the pack, never by the caller: no tool argument reaches it, and the command still has to pass the allow list before anything is spawned. It is found on `PATH` (falling back to the usual absolute locations), on the same trust assumption the allow list already makes for a bare command name — a process whose `PATH` has a writable directory ahead of `/usr/bin` has larger problems than this.

Which mechanism is available is resolved **and verified** once per process, by running a one-liner through the trampoline and checking that it came back a session leader with the pid that was spawned. A toolkit that asks for isolation and cannot get it **refuses to construct**, naming what it tried:

```raku
# Nothing on this machine can detach a child:
MCP::Server::Tool::Shell.new(allow => <git>);
# Shell toolkit could not isolate spawned commands from the controlling
# terminal, so it refuses to start: ... Install perl (or util-linux for
# setsid), or, if this process has no terminal worth protecting, construct
# the toolkit with isolate-terminal => False.
```

That is deliberate: a protection that is quietly missing is worse than one that is loudly absent, because the failure it prevents costs the user their session.

**Kills follow the tree.** Because an isolated child leads its own process group, a timeout, a cancelled call and the `kill` tool all signal the *group*: the grandchildren a command spawned die with it instead of outliving it and holding its pipes open (which used to lose the exit status, reported as `exit: null`). With `isolate-terminal => False ` the old behaviour returns — on Unix, only the direct child is signalled.

**Windows** has no sessions, no controlling terminal and no `termios` to corrupt, so the session half of this simply does not apply there and the pack does not pretend otherwise: `isolate-terminal` still detaches standard input (which is the platform's own version of the hazard — a child reading the host's console, or its stdio transport), and kills already took the whole tree via `taskkill /T /F`. Console-handle isolation beyond standard input is not attempted.

### Running anything: allow-any and MCP::Client::Policy

`allow-any => True ` removes the allow list entirely. Everything else stays: no shell, argv vectors, NUL rejection, capped output, timeouts, jobs. What is gone is the decision about *what may run* — this pack will run anything the server's user can run, including a shell, including `rm`.

That is only a sane configuration if the decision is being made somewhere else. The intended pairing is a policy layer on the client side, such as `MCP::Client::Policy`, whose rules are name-based and whose default for an unmatched tool is to ask a human:

```raku
# Server: no allow list, because the client is where consent lives.
$server.plug: MCP::Server::Tool::Shell.new(:allow-any);
```

With a policy in front, `sh_run` and `sh_start` match no allow rule, so every call is put to the user before it happens — which is a better gate than a static list for an interactive coding agent, and a much worse one for an unattended server. If nothing is asking a human, use `allow`.

### Sandboxing: the launcher seam

The pack is a gate, not a sandbox — but it leaves a seam for a host to bolt one on. The `launcher` attribute is a `Callable` (programmatic only: a closure cannot come from a JSON config, so `from-config` does not offer it) given the validated plan just before the process is built:

```raku
MCP::Server::Tool::Shell.new(
    :allow-any,
    launcher => -> %plan {
        # %plan is { command, argv, dir }.  Return { command, argv }: the
        # program actually exec'd becomes the wrapper, with the original
        # command and its arguments folded onto the wrapper's own argv.  dir
        # is left alone — the working directory is still applied by the pack.
        %(
            command   => 'sandbox-exec',
            argv      => ['-p', $profile, %plan<command>, |%plan<argv>],
            sandboxed => True,
        );
    },
);
```

The seam is deliberately minimal and total:

  * **It wraps both spawn sites.** A foreground `run` and a background `start` pass through the same launcher and the same wrapping — there is no path that escapes it.

  * **An undefined launcher is exactly the old behaviour.** No launcher, no wrapping, and the result payload is byte-for-byte what it always was.

  * **A launcher that throws is a failed spawn, not a crash.** A launcher that dies (or returns a shape the pack cannot spawn) lands in the same `exit: -1` + reason-in-stderr payload a command that could not be `exec`'d does. It never takes the server down, and never runs the unwrapped command as a fallback — a sandbox that failed to build is a run that failed, not a run that escaped.

  * **It marks its own runs.** A launcher may return `sandboxed => True `, which surfaces as `sandbox => { active => true } ` on the result (a foreground `run`, or a job's `output`). A host reads it to tell a sandbox denial from an ordinary non-zero exit — the hook for an "it was the sandbox; retry without it?" prompt. The key is **absent** otherwise, so a run with no launcher, or one the launcher declined to sandbox, keeps the payload it always had.

The launcher does not see, and cannot change, the working directory, the timeout, the output caps or the standard input: it wraps *what runs*, and the pack still governs *how long, how much and where*.

### Windows notes

  * Bare names resolve the way `CreateProcess` resolves them, so `allow => <git> ` runs `git.exe` off `PATH`. Allowlist the string you want the caller to *pass* (`git`), not the file that ends up being executed (`git.exe`) — the match happens before any resolution.

  * Arguments are still a vector: Rakudo quotes each entry for `CreateProcess`, so an argument containing spaces stays one argument.

  * A kill becomes `TerminateProcess`, which the command cannot trap or delay. There are no signals, so there is no `128 + signal` exit status: a killed run or job reports whatever `TerminateProcess` left behind (`1`, in practice). Test for `exit != 0` rather than for `137`.

  * A kill takes the **whole process tree**: `taskkill /T /F /PID` is issued against the child before the `TerminateProcess` backstop, so grandchildren the command spawned do not outlive the kill. It is fire-and-forget — the watcher collects the exit status independently — and if `taskkill` is missing from a stripped image the direct-child kill still runs. (Unix reaches the tree a different way, by signalling the process group of an isolated child; see [Terminal isolation](#Terminal isolation).)

  * `isolate-terminal` detaches standard input here as it does everywhere, but there is no session to leave and no `/dev/tty` to close off: Windows has neither, so the pack claims neither. See [Terminal isolation](#Terminal isolation).

  * Everything else — stdin, capped output, streaming, jobs — behaves the same as on Unix.

Examples
--------

  * `examples/shell-server.raku` — a git + ripgrep server, with the invocation line in the header.

See Also
--------

  * [MCP::Server](https://github.com/m-doughty/MCP-Server) — the server framework, the `MCP::Server::Toolkit` role this pack implements, and the `raku-mcp` command.

Author
------

Matt Doughty

License
-------

Artistic-2.0


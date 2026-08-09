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
<tr> <td>allow</td> <td>Array of Str</td> <td>required</td> <td>Exact argv0 strings that may be executed</td> </tr> <tr> <td>allow-any</td> <td>Bool</td> <td>False</td> <td>Run anything, with no allow list at all</td> </tr> <tr> <td>cwd</td> <td>Str (directory)</td> <td>none</td> <td>Default working directory for every run</td> </tr> <tr> <td>timeout</td> <td>Real (seconds)</td> <td>30</td> <td>Wall-clock budget for a foreground run</td> </tr> <tr> <td>max-output-bytes</td> <td>Int (bytes)</td> <td>131072</td> <td>Retained output per stream, per run</td> </tr> <tr> <td>max-output-lines</td> <td>Int (lines)</td> <td>2000</td> <td>Retained lines per stream, per run</td> </tr> <tr> <td>max-jobs</td> <td>Int</td> <td>4</td> <td>Background jobs that may run at once</td> </tr> <tr> <td>max-finished-jobs</td> <td>Int</td> <td>16</td> <td>Finished jobs that stay pollable</td> </tr> <tr> <td>job-ttl</td> <td>Real (seconds)</td> <td>600</td> <td>How long a finished job stays pollable</td> </tr>
</tbody>
</table>

  * **allow** must contain at least one non-empty string unless **allow-any** is set. Entries are matched with `eq` — see [Security](#Security).

  * **allow-any** and **allow** are mutually exclusive, and one of them is required: a runner that can run everything and a runner that can run nothing are both configurations somebody meant, but "I forgot to say" is not. See [Running anything: allow-any and MCP::Client::Policy](#Running anything: allow-any and MCP::Client::Policy).

  * **cwd** must be an existing directory at construction time; the constructor dies otherwise. A per-call `cwd` argument overrides it.

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
# Valid keys: allow, allow-any, cwd, job-ttl, max-finished-jobs, max-jobs,
# max-output-bytes, max-output-lines, timeout
```

The default prefix is `sh`, so the tools below are registered as `sh_run`, `sh_start`, `sh_poll`, `sh_output`, `sh_kill` and `sh_allowed` unless you pass a `prefix` of your own.

Tools
-----

### run

Runs one command in the foreground and waits for it.

<table class="pod-table">
<thead><tr>
<th>Argument</th> <th>Type</th> <th>Required</th> <th>Meaning</th>
</tr></thead>
<tbody>
<tr> <td>command</td> <td>string</td> <td>yes</td> <td>Must be `eq` an entry of the allow list</td> </tr> <tr> <td>args</td> <td>array of string</td> <td>no</td> <td>One array entry per argument</td> </tr> <tr> <td>cwd</td> <td>string</td> <td>no</td> <td>Working directory, overriding the default</td> </tr> <tr> <td>stdin</td> <td>string</td> <td>no</td> <td>Text to write to standard input, then close</td> </tr> <tr> <td>timeout</td> <td>number</td> <td>no</td> <td>Seconds, overriding the server default</td> </tr>
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

### Standard input

`stdin` is written to the command and the pipe is then closed, so a filter sees a normal end of input. Three states, and they are all different:

  * **omitted** — standard input is left unconnected, exactly as it was before this feature existed. Nothing is written to the command and it is not handed an end of file we invented for it.

  * **empty string** — the pipe is opened and closed immediately, so the command reads an immediate EOF. This is what you want for a filter you have nothing to say to.

  * **a string** — written and then closed.

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

While a job runs, its output and lifecycle events are also pushed as `notifications/message` — output batches at `debug` (so a legacy client can silence them with `logging/setLevel`) and `started` / `exited` / `killed` lines at `info`, all labelled with the prefixed `start` tool name. Whether they arrive depends on the transport, and this is worth knowing before you build a UI on it:

<table class="pod-table">
<thead><tr>
<th>Session</th> <th>Push</th> <th>Why</th>
</tr></thead>
<tbody>
<tr> <td>Legacy stdio, initialized</td> <td>Yes</td> <td>One client, one transport-wide channel to write on</td> </tr> <tr> <td>Legacy stdio, pre-handshake</td> <td>No</td> <td>Nothing may be sent before the client says it is initialized</td> </tr> <tr> <td>Modern Streamable HTTP</td> <td>No</td> <td>There is no server-initiated stream between requests</td> </tr> <tr> <td>No transport (in-process)</td> <td>No</td> <td>Nowhere to write</td> </tr>
</tbody>
</table>

So: **`poll` and `output` are the reliable way to follow a job**, on every transport. Push is a bonus where the transport happens to support it, never a substitute for polling — and a push channel that refuses or fails never affects the job itself, whose output is safe in its buffers either way.

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

  * **It does not constrain what an allowed command can do.** Allowlisting an interpreter or a shell (`sh`, `bash`, `pwsh`, `raku`, `python`) hands over arbitrary code execution, because those programs take code as an argument. Allowlist leaf tools, not launchers.

  * **It does not filter arguments.** `git` can push, `rg` can read any file the server user can read, and `cwd` is unrestricted unless you leave it unset and only allow commands that ignore it. Run the server as a user whose privileges you are comfortable handing to the model.

  * **It does not scrub the environment.** Children inherit the server process's environment, including any credentials in it.

  * **It only kills the command itself.** Grandchildren the command spawned may outlive a kill, and can hold the pipes open long enough for the exit status to be lost (reported as `exit: null`).

### Running anything: allow-any and MCP::Client::Policy

`allow-any => True ` removes the allow list entirely. Everything else stays: no shell, argv vectors, NUL rejection, capped output, timeouts, jobs. What is gone is the decision about *what may run* — this pack will run anything the server's user can run, including a shell, including `rm`.

That is only a sane configuration if the decision is being made somewhere else. The intended pairing is a policy layer on the client side, such as `MCP::Client::Policy`, whose rules are name-based and whose default for an unmatched tool is to ask a human:

```raku
# Server: no allow list, because the client is where consent lives.
$server.plug: MCP::Server::Tool::Shell.new(:allow-any);
```

With a policy in front, `sh_run` and `sh_start` match no allow rule, so every call is put to the user before it happens — which is a better gate than a static list for an interactive coding agent, and a much worse one for an unattended server. If nothing is asking a human, use `allow`.

### Windows notes

  * Bare names resolve the way `CreateProcess` resolves them, so `allow => <git> ` runs `git.exe` off `PATH`. Allowlist the string you want the caller to *pass* (`git`), not the file that ends up being executed (`git.exe`) — the match happens before any resolution.

  * Arguments are still a vector: Rakudo quotes each entry for `CreateProcess`, so an argument containing spaces stays one argument.

  * A kill becomes `TerminateProcess`, which the command cannot trap or delay. There are no signals, so there is no `128 + signal` exit status: a killed run or job reports whatever `TerminateProcess` left behind (`1`, in practice). Test for `exit != 0` rather than for `137`.

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


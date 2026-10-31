use JSON::Fast;
use MCP::Server::Protocol;
use MCP::Server::Toolkit;
use MCP::Server::Tool::Shell::Buffer;
use MCP::Server::Tool::Shell::Jobs;
use MCP::Server::Tool::Shell::Isolation;

#| A command runner for MCP::Server.  Commands are always spawned as an argv
#| vector (never through a shell), output is captured into capped buffers, and
#| every run is bounded — by a timeout in the foreground, by an explicit kill in
#| the background.
#|
#| Which commands may run is decided one of two ways: an exact-string allow list
#| (.allow), or .allow-any for deployments that gate consent somewhere else —
#| an MCP::Client::Policy in front of the tools, or a human watching the
#| session.  One or the other, never both, never neither.
#|
#| The "command" argument is one executable and nothing else.  A command line
#| in that argument — "prove6 --help" — is refused with an error that shows
#| the corrected call, rather than spawned as a request for a program with a
#| space in its name (whose failure reads exactly like a missing binary, and
#| has cost real sessions hours).  The rule is written out above
#| check-command-shape and in this dist's Pod.
#|
#| Commands are also kept away from the terminal the host process is attached
#| to: standard input is detached unless the caller supplied some, and on POSIX
#| every child runs in a session of its own, so nothing it does to a terminal
#| can reach the host's.  See MCP::Server::Tool::Shell::Isolation and the
#| .isolate-terminal attribute.
unit class MCP::Server::Tool::Shell does MCP::Server::Toolkit;

#| Exact argv0 strings that may be executed, e.g. <git rg /usr/bin/jq>.  The
#| caller's "command" argument must be `eq` one of these — no globbing, no
#| basename matching, no PATH rewriting.  Leave it empty only in .allow-any
#| mode.
has @.allow;

#| Run anything the caller asks for, with no allow list at all.  For hosts that
#| take consent seriously somewhere else in the stack (MCP::Client::Policy's
#| "ask when no rule matches" covers these tools with zero configuration); a
#| server that turns this on hands whoever can call it the privileges of the
#| user it runs as.
has Bool:D $.allow-any = False;

#| Default working directory for every run; the "cwd" argument overrides it.
has IO::Path() $.cwd;

#| An optional spawn launcher: a duck-typed C<Callable> given the validated
#| plan C<< { command, argv, dir } >> just before the process is built, which
#| returns the wrapped C<< { command, argv } >> to exec in its place (a sandbox
#| wrapper such as C<sandbox-exec> or C<bwrap>, with the original command and
#| its arguments folded onto the wrapper's own argv; C<dir> is left alone).  It
#| may also return C<< sandboxed => True >>, which surfaces as
#| C<< sandbox => { active => True } >> on the tool result so a host can tell a
#| sandbox denial from an ordinary failure.  Undefined is the default and is
#| byte-for-byte the old behaviour.  A launcher that throws (or returns a shape
#| the pack cannot spawn) is reported as a failed spawn — exit C<-1>, the
#| reason in stderr — never a crash.  See L<MCP::Server::Tool::Shell::Jobs>'
#| C<apply-launcher>.
#|
#| Private (no accessor) on purpose: it is wiring rather than configuration —
#| a C<Callable> cannot come from a JSON config, so C<from-config> must not
#| offer it as a key — but C<is built> still lets C<.new(launcher => …)> set
#| it, which is how a host application installs a sandbox wrapper.
has &!launcher is built;

#| Keep spawned commands away from the terminal this process is attached to.
#| On by default, and you almost certainly want it on: a pack plugged into a
#| terminal application shares that application's terminal with everything it
#| runs, and one child that leaves the terminal in cooked mode on exit is
#| enough to make the host unable to read another keystroke.
#|
#| Two things happen when it is on.  A run given no C<stdin> argument gets a
#| closed pipe on C<fd 0> rather than the host's standard input (every
#| platform), and on POSIX the child is put in a session of its own, so
#| C</dev/tty> cannot reach the host's terminal and a kill takes the child's
#| whole process group.  Turning it off restores the previous behaviour
#| exactly: children inherit standard input and the controlling terminal.
#|
#| Constructing the toolkit fails loudly if isolation is asked for and no
#| mechanism can be found and verified, rather than starting with the
#| protection quietly missing.  See L<MCP::Server::Tool::Shell::Isolation>.
has Bool:D $.isolate-terminal = True;

#| Wall-clock budget, in seconds, for a single foreground run.  The "timeout"
#| argument overrides it per call; background jobs have no default budget.
has Real:D $.timeout = 30;

#| Retained output per stream per run, in UTF-8 bytes.  What does not fit is
#| dropped out of the middle and reported (see MCP::Server::Tool::Shell::Buffer).
has Int:D $.max-output-bytes = 131072;

#| Retained output per stream per run, in lines.
has Int:D $.max-output-lines = 2000;

#| How many background jobs may run at once.
has Int:D $.max-jobs = 4;

#| How many finished jobs stay pollable; the oldest is forgotten first.
has Int:D $.max-finished-jobs = 16;

#| Seconds a finished job stays pollable before it is forgotten.
has Real:D $.job-ttl = 600;

# How long to wait for the exit promise to settle after a kill before giving up
# and reporting the run with an unknown exit status.
my constant KILL-GRACE = 5;

# How often the foreground run loop wakes to flush output, notice a caller who
# has hung up, and check the deadline.  Small enough that a cancelled call dies
# promptly, large enough that a quiet minute costs a few hundred wakeups.
my constant POLL-INTERVAL = 0.25;

# Largest notification payload one foreground flush carries; a longer batch is
# split.  Notifications share a transport with responses, and a multi-megabyte
# one would stall everything queued behind it.
my constant NOTIFY-BATCH-BYTES = 32768;

# Floors on the output caps.  Below these a run reports more marker than
# output, which is not a configuration anybody wants on purpose.
my constant MIN-OUTPUT-BYTES = 1024;
my constant MIN-OUTPUT-LINES = 10;

#| The MCP annotations the three B<introspection> tools carry: "allowed", which
#| reads a list this instance was built with, and "poll" and "output", which
#| read a job's state and a window of what it has already written.  None of
#| them starts, stops or advances anything: an "output" cursor is a position
#| the CALLER holds, and reading from one leaves the buffer exactly as it was,
#| so the same call twice is the same answer twice.
#|
#| Concurrency-safe as well as read-only, which is the other half of what these
#| hints promise: the job registry and every job's output buffer take their own
#| locks (see MCP::Server::Tool::Shell::Jobs and ::Buffer), so two of these
#| running side by side see coherent state rather than a half-written flush.
#|
#| B<"run", "start" and "kill" carry none, deliberately.>  A command is
#| whatever the model typed — the pack cannot know whether it writes — "start"
#| mints a job, and "kill" ends one.  Annotating them would be telling a host
#| it may run two of them at once, which is exactly the thing the caller must
#| decide for itself.
#|
#| A C<Map> rather than a Hash literal: `constant %h = {...}` freezes the
#| container and not the object inside it.
my constant READ-ANNOTATIONS = Map.new((
	readOnlyHint   => True,
	idempotentHint => True,
));

# The servers this kit has been plugged into, for pushing job output out of
# band.  Private (no accessor) on purpose: it is wiring rather than
# configuration, and from-config validates against the public attributes.
# Written at register time -- before any job can exist -- and read from job
# flusher threads afterwards.
has @!servers;

# Tool names as the client sees them, used as the "logger" of every
# notification this pack emits so a host can tell one plugged kit from another.
has Str:D $!run-logger = 'run';
has Str:D $!job-logger = 'start';

has $!jobs;

# How children are kept away from the host's terminal, resolved once per
# process (see MCP::Server::Tool::Shell::Isolation) and consulted at both spawn
# sites.  Private: it is the outcome of a decision, not the decision itself,
# which is the public isolate-terminal attribute.
has $!isolation;

submethod TWEAK {
	# One gate or the other.  Setting both asks two contradictory questions of
	# every call, and setting neither leaves a runner that can run nothing --
	# almost always a forgotten setting rather than a decision.
	die 'Shell toolkit allow and allow-any are mutually exclusive: an allow '
	  ~ 'list is a decision about what may run, and allow-any is the decision '
	  ~ 'not to make it here'
		if $!allow-any && @!allow.elems > 0;

	die 'Shell toolkit requires a non-empty allow list (or allow-any => True '
	  ~ 'when consent is enforced elsewhere, e.g. by an MCP::Client::Policy)'
		unless $!allow-any || @!allow.elems > 0;

	if @!allow.grep({ $_ !~~ Str:D || .chars == 0 }).map(*.raku).sort -> @bad {
		die "Shell toolkit allow list entries must be non-empty strings; got: {@bad.join(', ')}";
	}

	with $!cwd {
		die "Shell toolkit cwd is not an existing directory: {.Str}" unless .d;
	}

	die "Shell toolkit timeout must be greater than zero, got {$!timeout}"
		unless $!timeout > 0;

	die "Shell toolkit max-output-bytes must be at least {MIN-OUTPUT-BYTES}, got {$!max-output-bytes}"
		unless $!max-output-bytes >= MIN-OUTPUT-BYTES;

	die "Shell toolkit max-output-lines must be at least {MIN-OUTPUT-LINES}, got {$!max-output-lines}"
		unless $!max-output-lines >= MIN-OUTPUT-LINES;

	# Resolved here rather than at the first spawn: a host that cannot isolate
	# its children should find out while it is wiring itself up, not from the
	# first tool call an agent makes.  The answer is memoised process-wide, so
	# the second toolkit costs nothing.
	$!isolation = $!isolate-terminal ?? resolve-isolation() !! isolation-off();

	# The registry validates max-jobs / max-finished-jobs / job-ttl, so those
	# rules live in one place and a directly-built Registry gets them too.
	$!jobs = MCP::Server::Tool::Shell::Jobs::Registry.new(
		ttl => $!job-ttl,
		max-jobs => $!max-jobs,
		max-finished => $!max-finished-jobs,
	);
}

method default-prefix(--> Str) { 'sh' }

method register($registrar) {
	# A job outlives the request that started it, so its output cannot go out on
	# that request's notification channel.  The server can take it instead --
	# and a kit may be plugged into more than one, so they accumulate.
	my $server = $registrar.?server;
	@!servers.push($server)
		if $server.defined && !@!servers.first({ $_ === $server }).defined;

	$!run-logger = $registrar.?prefixed('run') // 'run';
	$!job-logger = $registrar.?prefixed('start') // 'start';

	$registrar.tool: 'allowed',
		annotations => READ-ANNOTATIONS,
		description => $!allow-any
			?? 'Report which commands this shell toolkit may run.  This one has no '
			  ~ 'allow list: any command the server user can execute is available.'
			!! 'List the commands this shell toolkit is allowed to run, one per line',
		handler => -> :%args { self!allowed };

	$registrar.tool: 'run',
		description => "Run { $!allow-any ?? 'a command' !! 'an allowlisted command' } with the given arguments and "
		  ~ 'wait for it to finish, returning a JSON object with the keys exit, '
		  ~ 'stdout, stderr and timed-out.  Arguments are passed straight to the '
		  ~ 'program as an argv vector: there is no shell, so no quoting, '
		  ~ 'globbing, redirection, pipes or variable interpolation happen.  '
		  ~ 'Put the executable in "command" and every argument in "args" — a '
		  ~ '"command" that is a whole command line is refused, not run.  '
		  ~ 'Output is capped: when a run produces more than the server keeps, '
		  ~ 'the middle is dropped and a "truncated" key says how much.  Use the '
		  ~ 'companion "start" tool instead for work that will outlast a single '
		  ~ 'tool call, and "allowed" to see which commands are available.',
		params => self!run-params('this run', timeout-default => $!timeout),
		handler => -> :%args { self!run(%args) };

	$registrar.tool: 'start',
		description => "Start { $!allow-any ?? 'a command' !! 'an allowlisted command' } in the background and return "
		  ~ 'a JSON object with a job handle and its state.  Use it for work that '
		  ~ 'would outlast the "run" tool: builds, test suites, long transfers.  '
		  ~ 'The command keeps running after this call answers; "poll" reports how '
		  ~ 'it is getting on, "output" returns what it has written, and "kill" '
		  ~ 'stops it.  Arguments are an argv vector exactly as for "run" — there '
		  ~ 'is still no shell, the executable goes in "command" and every '
		  ~ 'argument in "args", and a "command" that is a whole command line is '
		  ~ 'refused, not run.',
		params => self!run-params('this job'),
		handler => -> :%args { self!start(%args) };

	$registrar.tool: 'poll',
		annotations => READ-ANNOTATIONS,
		description => 'Report the state of a background job as a JSON object: '
		  ~ 'state (running, exited or killed), exit status once there is one, '
		  ~ 'timed-out, killed, started-at, runtime in seconds, and how many bytes '
		  ~ 'each stream has produced.  Does not return the output itself — that is '
		  ~ 'the "output" tool.',
		params => { job => self!job-param },
		handler => -> :%args { self!poll(%args) };

	$registrar.tool: 'output',
		annotations => READ-ANNOTATIONS,
		description => 'Return a background job\'s output as a JSON object with the '
		  ~ 'keys job, state, stdout, stderr, cursor and eof.  Called without a '
		  ~ 'cursor it returns a capped snapshot of the whole run so far; called '
		  ~ 'with the cursor from a previous call it returns only what has been '
		  ~ 'written since, so a long job can be followed a piece at a time.  Keep '
		  ~ 'going until eof is true.',
		params => {
			job => self!job-param,
			cursor => {
				type => 'string',
				description => 'The cursor from a previous call to this tool.  '
				  ~ 'Opaque: pass it back exactly as it was given.  Omit it to get '
				  ~ 'a snapshot of everything the job has produced.',
			},
		},
		handler => -> :%args { self!output(%args) };

	$registrar.tool: 'kill',
		description => 'Kill a background job (SIGKILL, which it cannot catch or '
		  ~ 'delay) and return a JSON object with the job, its state and whether a '
		  ~ 'kill is in force.  Returns immediately, so poll for the final state.  '
		  ~ 'Killing a job that has already finished changes nothing.',
		params => { job => self!job-param },
		handler => -> :%args { self!kill(%args) };
}

# The parameter block "run" and "start" share.  $what names the call in the
# descriptions so neither tool talks about the other's lifetime, and
# $timeout-default is the budget this toolkit applies to a call that names
# none: a foreground run has one, a background job does not, so only "run"
# passes it.
method !run-params(Str:D $what, Real :$timeout-default --> Hash) {
	my %params =
		command => {
			type => 'string',
			description => 'The name or path of ONE executable, and nothing else: '
			  ~ 'there is no shell here, so a command line is refused rather than '
			  ~ 'run.  Arguments go in "args": {"command": "git", "args": '
			  ~ '["status", "-s"]}, never {"command": "git status -s"}.  '
			  ~ ($!allow-any
					?? 'Any executable the server user can run is allowed.'
					!! 'Must match one of the allowlisted strings exactly (see the '
					  ~ '"allowed" tool).'),
			required => True,
		},
		args => {
			type => 'array',
			items => { type => 'string' },
			description => 'Every argument to the command, one array entry per '
			  ~ 'argument: "git status -s" is ["status", "-s"].  This is where '
			  ~ 'arguments belong — never appended to "command" — because the '
			  ~ 'program is spawned as an argv vector with no shell in the way.  '
			  ~ 'Entries are strings and reach the program untouched: an entry '
			  ~ 'containing spaces stays a single argument, and nothing is '
			  ~ 'quoted, split or expanded.',
			# Omitting it runs the command with no arguments at all, which is
			# what an empty argv vector means -- published so that a model
			# reading this schema can see it is a real choice rather than a
			# gap the server will fill in from somewhere.
			default => [],
		},
		cwd => {
			type => 'string',
			description => "Working directory for $what.  Overrides the toolkit "
			  ~ 'default; must be an existing directory.',
		},
		stdin => {
			type => 'string',
			description => 'Text written to the command\'s standard input, which is '
			  ~ 'then closed.  An empty string means "no input, EOF immediately".  '
			  ~ 'Omit it entirely and the command reads end of file straight '
			  ~ 'away: a command never inherits the server\'s own standard input.',
		},
		timeout => {
			type => 'number',
			description => $what eq 'this job'
				?? 'Seconds before the job is killed.  Omit it and the job runs '
				  ~ 'until it finishes or is killed.'
				!! 'Seconds to wait before killing the command, overriding the '
				  ~ 'server default for this call.',
		};

	# A foreground run that names no timeout gets this toolkit's own budget, so
	# the schema can say what it is.  A background job that names none runs
	# until it finishes or is killed, which is an absence rather than a value:
	# nothing to advertise.
	#
	# "cwd" is deliberately not given one.  A call that omits it runs in this
	# toolkit's configured directory, or the server process's own when it has
	# none -- a fact about the deployment rather than about the tool, and
	# publishing a filesystem path to the model is not this pack's decision to
	# take by accident.
	%params<timeout><default> = $timeout-default if $timeout-default.defined;

	%params;
}

method !job-param(--> Hash) {
	{
		type => 'string',
		description => 'Job handle, as returned by the "start" tool.',
		required => True,
	}
}

# === Tool bodies ===
#
# Everything that is the caller's fault (unknown command, bad argument shape,
# missing directory, unknown job) dies so MCP::Server turns it into an isError
# result; everything that is a runtime condition of the command itself
# (non-zero exit, missing binary, timeout) is reported in the JSON payload.

method !allowed(--> Str:D) {
	return 'Any command may be run: this toolkit has no allow list.' if $!allow-any;
	@!allow.sort.join("\n");
}

#| Validate the caller's arguments, then run the command in the foreground and
#| wait for it.
method !run(%args --> Str:D) {
	my %plan = self!validate(%args);
	my Real:D $timeout = self!timeout-for(%args, $!timeout);
	self!execute(%plan, $timeout);
}

#| Validate the caller's arguments, admit a job, and spawn it.
method !start(%args --> Str:D) {
	my %plan = self!validate(%args);
	my Real $timeout = self!timeout-for(%args, Real);

	my @streams = (^2).map({
		MCP::Server::Tool::Shell::Buffer.new(
			max-bytes => $!max-output-bytes,
			max-lines => $!max-output-lines,
		)
	});

	# Only wire a push channel when there is a server to push to: without one a
	# job would keep a second copy of its output around for nobody to read.
	my &notify = @!servers.elems > 0
		?? -> Str:D $level, Str:D $line { self!push($level, $line) }
		!! Callable;

	# The lifecycle channel goes to the same servers, and is wired on the same
	# condition.  Separate from the output one because they are read by
	# different sorts of consumer: a log window takes the lines, a host that
	# does something when a build finishes takes the events.
	my &notify-event = @!servers.elems > 0
		?? -> %params { self!push-event(%params) }
		!! Callable;

	# Bound to a variable of its own rather than passed straight out of the
	# hash: a list living in a hash value is itemised, and would arrive as one
	# argument that happens to be an array.
	my Str @argv = %plan<argv>.list;

	my $job = $!jobs.admit(-> Str:D $id {
		MCP::Server::Tool::Shell::Jobs::Job.new(
			:$id,
			command => %plan<command>,
			args => @argv,
			dir => %plan<dir>,
			stdin => %plan<stdin>,
			|($timeout.defined ?? (:$timeout) !! ()),
			stdout => @streams[0],
			stderr => @streams[1],
			:&notify,
			:&notify-event,
			launcher => &!launcher,
			isolation => $!isolation,
			on-finish => { Promise.in($!job-ttl).then({ $!jobs.reap }) },
		)
	});

	without $job {
		my @running = $!jobs.running-ids;
		die "Too many jobs already running ({@running.join(', ')}); the limit is "
		  ~ "{$!max-jobs}. Wait for one to finish, or kill it with the \"kill\" tool.";
	}

	$job.spawn;

	to-json({ job => $job.id, state => 'running' }, :!pretty, :sorted-keys);
}

method !poll(%args --> Str:D) {
	my $job = self!job(%args);
	# Copied rather than composed with a slip: a hash composer that opens with
	# |%status parses as a block, and the first thing that notices is to-json.
	my %payload = $job.status;
	%payload<stdout-bytes> = $job.stdout.stats<bytes>;
	%payload<stderr-bytes> = $job.stderr.stats<bytes>;

	to-json(%payload, :!pretty, :sorted-keys);
}

method !output(%args --> Str:D) {
	my $job = self!job(%args);
	my @at = self!cursor(%args<cursor>);

	# State first, output second: a job that finishes between the two reads has
	# already written everything it is going to, so a read that follows a
	# terminal state is complete.  The other order could report eof on a job
	# that was still writing.
	my %status = $job.status;
	my %out = $job.stdout.read-from(@at[0], @at[1]);
	my %err = $job.stderr.read-from(@at[2], @at[3]);

	my %payload =
		job => $job.id,
		state => %status<state>,
		stdout => %out<text>,
		stderr => %err<text>,
		cursor => cursor-token(%out, %err),
		eof => %status<state> ne 'running';

	my %truncated = self!truncation(%out, %err);
	%payload<truncated> = %truncated if %truncated.elems > 0;

	# The sandbox marker, present only for a job a launcher actually wrapped —
	# the "output" tool is where a job's result is read, so it is where A7
	# looks to tell a sandbox denial from an ordinary failure.
	%payload<sandbox> = { active => True } if $job.sandboxed;

	to-json(%payload, :!pretty, :sorted-keys);
}

method !kill(%args --> Str:D) {
	my $job = self!job(%args);
	my Bool:D $killed = $job.kill;

	to-json(
		{ job => $job.id, state => $job.status<state>, killed => $killed },
		:!pretty,
		:sorted-keys,
	);
}

# === Argument validation ===

my constant RUN-KEYS = <command args cwd stdin timeout>;

#| Everything "run" and "start" agree on: the command, its argv vector, the
#| working directory and the standard input, all checked before anything is
#| spawned. Unknown argument keys are refused.
method !validate(%args --> Hash) {
	my @unknown = %args.keys.grep({ $_ !(elem) RUN-KEYS }).sort;
	if @unknown.elems {
		my $message = 'Unknown parameters: '
			~ @unknown.map({ "'$_'" }).join(', ')
			~ '. Accepted parameters: ' ~ RUN-KEYS.join(', ') ~ '.';
		$message ~= " Arguments go in 'args', not 'argv'."
			if @unknown.first(* eq 'argv').defined;
		die $message;
	}

	my $command = %args<command>;
	die "'command' is required and must be a non-empty string"
		unless $command ~~ Str:D && $command.chars > 0;
	# A NUL would silently truncate the path at the exec boundary, so the
	# program that ran would not be the program that was checked.
	die "'command' must not contain NUL bytes" if $command.contains("\0");

	# Before the allow list, deliberately: a "command" that is really a command
	# line is the wrong shape whoever is allowed to run what, and in allow-any
	# mode there is no allow list to catch it.  Both tools reach this method,
	# so this is the one place the shape is decided.
	check-command-shape($command);

	die "Command '$command' is not allowlisted. Allowed: {@!allow.sort.join(', ')}"
		unless $!allow-any || so @!allow.any eq $command;

	my @argv = self!argv(%args<args>);

	my $dir = do with %args<cwd> {
		die "'cwd' must be a non-empty string" unless $_ ~~ Str:D && .chars > 0;
		.IO;
	} else {
		$!cwd;
	};
	with $dir {
		die "Working directory does not exist: {.Str}" unless .d;
	}

	my Str $stdin;
	with %args<stdin> {
		die "'stdin' must be a string, got a {.^name}" unless $_ ~~ Str:D;
		# NUL bytes are fine here, unlike in argv: this is a byte stream, not a
		# C string, and a program that wants one can have one.
		$stdin = $_;
	}

	{ command => $command, argv => @argv, dir => $dir, stdin => $stdin }
}

#| Coerce the "args" argument into a list of plain strings, rejecting shapes a
#| program cannot receive (nested structures, NUL bytes).
method !argv($raw --> List) {
	return () without $raw;

	die "'args' must be an array of strings, got a {$raw.^name}"
		unless $raw ~~ Positional;

	my Str @argv;
	for $raw.list.kv -> $index, $arg {
		die "'args' entries must be strings; entry $index is a {$arg.^name}"
			unless $arg ~~ Str:D || ($arg ~~ Numeric:D && $arg !~~ Bool);
		my Str $value = $arg.Str;
		die "'args' entries must not contain NUL bytes; entry $index does"
			if $value.contains("\0");
		@argv.push: $value;
	}

	@argv.List;
}

# === "command" is one executable, not a command line ===
#
# A model that sends {"command": "prove6 --help"} has asked for a program
# literally named "prove6 --help", and the spawn failure that comes back --
# "no such file or directory" -- reads like a missing binary rather than a
# misunderstood contract.  Seen from the other end that is hours of a session
# spent hunting for binaries that were there all along, so the call is refused
# here with an error that teaches the right one instead.
#
# THE RULE, in full.  A command is refused when it cannot be resolved to an
# executable AND it looks like a command line rather than a program name,
# which means either
#
#   * it contains one of the shell metacharacters below -- none of which a
#     shell-free spawn can act on -- or
#   * it contains whitespace and its first whitespace-delimited word IS an
#     executable, so the call can be corrected exactly, by name.
#
# Resolution comes first in both arms because a path may contain anything the
# filesystem allows: /Applications/My App/bin/tool runs, and so does
# C:\Program Files (x86)\Git\cmd\git.exe, parentheses and all.  And a spacey
# path to something that is simply not there -- a typo, a build artefact that
# was never produced -- is left alone, so it still comes back as the ordinary
# "could not be spawned" payload rather than being mislabelled a shape error.
#
# Nothing here ever splits a command and runs the pieces.  Auto-splitting
# would put back the quoting ambiguity an argv vector exists to remove, and a
# client-side policy's argument-aware rules match on argv, so a shell string
# smuggled through as one command would slip past them.
my constant SHELL-METACHARS = ('|', '&', ';', '<', '>', '(', ')', '$', '`', "\n", "\r");

# Longest corrected call the error message will quote before it says the same
# thing in the abstract instead.
my constant SUGGESTION-BUDGET = 400;

#| Refuse a "command" that is a command line rather than one executable,
#| before anything is spawned.  Returning quietly means the call is the right
#| shape, or is a claim about the filesystem this pack cannot second-guess.
sub check-command-shape(Str:D $command --> Nil) {
	my $meta = SHELL-METACHARS.first({ $command.contains($_) });
	my Bool:D $spacey = so $command ~~ /\s/;

	# The ordinary call: a bare program name or a plain path.  Decided without
	# touching the filesystem at all.
	return unless $meta.defined || $spacey;

	# Whatever it looks like, a string that names a real executable names the
	# program the caller meant.
	return if names-executable($command);

	my Str @words = $command.words;
	my $program = @words.head;

	# Whitespace on its own is only a suspicion; it is confirmed by finding
	# the program that was buried in the string.  "git " (a stray trailing
	# space) is caught here too, which is why the test is "differs from the
	# whole string" rather than "there are two or more words".
	my Bool:D $buried = $program.defined
		&& $program ne $command
		&& names-executable($program);
	return unless $meta.defined || $buried;

	die command-shape-error($command, $meta, @words);
}

#| The error a refused command line answers with: the contract, what was
#| wrong with this particular call, and the same call written correctly.  The
#| correction is derived by splitting on whitespace -- for the message only.
sub command-shape-error(Str:D $command, $meta, @words --> Str:D) {
	my Str $lead = "'command' takes the name or path of ONE executable: this "
	  ~ 'tool spawns an argv vector with no shell, so arguments belong in '
	  ~ "'args', never in 'command'.";

	my Str $got = "Got '{one-line($command)}', which is not a program on this "
	  ~ 'system';

	my Str $fix = @words.elems > 1
		?? "Write the call as {argv-suggestion(@words)} instead."
		!! "Put the program's own name or path in 'command' and each of its "
		  ~ "arguments in its own entry of 'args'.";

	unless $meta.defined {
		return "$lead  $got, but '{@words[0]}' is.  $fix";
	}

	"$lead  $got, and it contains {metachar-display($meta)}: there are no "
	  ~ 'pipes, no redirection, no variable expansion, no globbing and no '
	  ~ "command sequencing on this path.  $fix  To run a shell script, make "
	  ~ "the shell itself the 'command' and pass the whole script as a single "
	  ~ "entry in 'args'.";
}

#| The corrected call as JSON a client can copy: the first word as the
#| command, every other word as its own argument.
sub argv-suggestion(@words --> Str:D) {
	my Str $command = to-json(@words[0], :!pretty);
	my Str $suggestion = '{"command": ' ~ $command ~ ', "args": ['
	  ~ @words.skip.map({ to-json($_, :!pretty) }).join(', ') ~ ']}';

	$suggestion.chars <= SUGGESTION-BUDGET
		?? $suggestion
		!! '{"command": ' ~ $command ~ ', "args": [ … one entry per argument … ]}';
}

#| How a metacharacter is named in the message: the ones with no printable
#| shape are described rather than quoted.
sub metachar-display(Str:D $char --> Str:D) {
	given $char {
		when "\n" { 'a newline' }
		when "\r" { 'a carriage return' }
		default   { "the shell metacharacter '$char'" }
	}
}

#| The caller's own string as a single bounded line: it is quoted back inside
#| an error a model reads, and neither a newline nor a hundred-kilobyte script
#| may turn that message into a mess.
sub one-line(Str:D $text --> Str:D) {
	my Str $flat = $text.subst("\n", '\n', :g)
		.subst("\r", '\r', :g)
		.subst("\t", '\t', :g);
	$flat.chars > 160 ?? $flat.substr(0, 160) ~ '…' !! $flat;
}

#| Does this exact string name a program this pack could spawn?  Asked only
#| of a command that already looks like a command line, so an ordinary call
#| never pays for it.
#|
#| Windows matches a name on PATH without regard to case: "wintool", with
#| ".EXE" in PATHEXT, runs F<wintool.exe>.  Under its rules the search here
#| does the same, in two passes.  The first asks for each name exactly as it
#| is spelt, one stat apiece in every PATH directory; on Windows' own
#| filesystems, which ignore case themselves, that is already the whole
#| answer.  Only when nothing answers to the exact spelling is each directory
#| read, and its entries compared with the names case-folded, so the answer
#| no longer depends on whether the filesystem underneath ignores case: the
#| same environment gives the same answer on every host.  POSIX names are
#| exact.  A path is not searched for at all: it is asked for as written, and
#| the filesystem it names answers.
#| Exposed with C<our> scope for the tests — not part of the public API.
our sub names-executable(Str:D $command --> Bool:D) {
	return False unless $command.chars > 0;
	my Bool:D $win = so $*DISTRO.is-win;

	# Anything with a path separator in it is a path and is not looked for on
	# PATH -- which is how exec reads it on both platforms.  On Windows that
	# means a backslash or a drive letter as well as a slash.
	return executable-file($command.IO, $win)
		if $command.contains('/')
		|| ($win && ($command.contains('\\') || $command ~~ / ^ <[A..Za..z]> ':' /));

	my @names = $command, |($win ?? windows-path-exts().map({ $command ~ $_ }) !! ());
	my @dirs = (env-value('PATH') // '').split($win ?? ';' !! ':', :skip-empty).map(*.IO);

	for @dirs -> $dir {
		return True if @names.first({ executable-file($dir.add($_), $win) }).defined;
	}
	return False unless $win;

	my $wanted = @names.map(*.fc).Set;
	for @dirs -> $dir {
		return True if holds-folded-entry($dir, $wanted, $win);
	}

	False;
}

#| Does this directory hold an executable whose name, case-folded, is one of
#| C<$wanted>?  Only names are compared while the directory is read; just
#| the entries that match are asked whether they are files.  A directory that
#| is missing or unreadable holds nothing, and must not throw out of a
#| question asked while building an error message -- which is why the whole
#| read, and not only the call that starts it, is inside the C<try>.
sub holds-folded-entry(IO::Path:D $dir, Set:D $wanted, Bool:D $win --> Bool:D) {
	my $answer = try so $dir.dir(test => { .fc (elem) $wanted })
		.first({ executable-file($_, $win) })
		.defined;
	$answer // False;
}

#| An environment variable as the operating system reads it.  Windows names
#| are case-insensitive and a process is handed PATH spelt "Path", but %*ENV
#| is an ordinary case-sensitive Hash, so on Windows the name is matched
#| without regard to case.  POSIX names are exact.
#|
#| An environment can still carry two spellings at once -- an MSYS or Cygwin
#| parent hands over both PATH and Path -- and a Hash has no order to pick
#| between them by.  The answer is fixed instead: the exact spelling asked
#| for when there is one, otherwise the first case-insensitive match in
#| sorted order, so the same environment always gives the same value.
#| Exposed with C<our> scope for the tests — not part of the public API.
our sub env-value(Str:D $name --> Str) {
	return %*ENV{$name} // Str unless $*DISTRO.is-win;
	return %*ENV{$name} if %*ENV{$name}:exists;
	my $key = %*ENV.keys.grep({ .fc eq $name.fc }).sort.head;
	$key.defined ?? %*ENV{$key} !! Str;
}

#| Can this path be exec'd?  POSIX asks the filesystem for the execute bit.
#| Windows has no such bit -- CreateProcess decides from the file itself, and
#| its refusal is an ordinary spawn failure -- so there the question is only
#| whether the file is there.  A path the platform will not even stat (an
#| illegal Windows filename, say) is not an executable, and must not throw out
#| of a question asked while building an error message.  C<$win> is the
#| caller's one reading of the platform, so a search asks once, not once per
#| file.
sub executable-file(IO::Path:D $path, Bool:D $win --> Bool:D) {
	my $answer = try so $path.f && ($win || $path.x);
	$answer // False;
}

#| The extensions Windows appends to a bare name looked up on PATH; the
#| fallback is what the command processor itself starts from when PATHEXT is
#| not set.
sub windows-path-exts(--> List) {
	(env-value('PATHEXT') // '.COM;.EXE;.BAT;.CMD')
		.split(';', :skip-empty)
		.map(*.trim)
		.grep(*.chars > 0)
		.List;
}

#| The budget for this call: the "timeout" argument when there is one, the
#| given default otherwise.  A Bool is not a number however much Raku's type
#| hierarchy would like it to be, and neither NaN nor Inf is a deadline.
method !timeout-for(%args, Real $default --> Real) {
	my $value = %args<timeout>;
	return $default without $value;

	die "'timeout' must be a number of seconds, got a {$value.^name}"
		unless $value ~~ Real:D && $value !~~ Bool;
	die "'timeout' must be a finite number of seconds, got {$value}"
		if $value.Num.isNaN || $value.Num == Inf || $value.Num == -Inf;
	die "'timeout' must be greater than zero, got {$value}"
		unless $value > 0;

	$value;
}

#| The job named by the caller's "job" argument.
method !job(%args) {
	my $id = %args<job>;
	die "'job' is required and must be a non-empty string"
		unless $id ~~ Str:D && $id.chars > 0;

	my $job = $!jobs.get($id);
	without $job {
		die "Unknown job '$id'. Either it never existed, or it has been forgotten: "
		  ~ "finished jobs are kept for {$!job-ttl} seconds and only the "
		  ~ "{$!max-finished-jobs} most recent are remembered.";
	}
	$job;
}

# === Execution ===

#| Spawn the planned command, capture both streams into capped buffers, and
#| return the JSON result.  Proc::Async only: there is no shell anywhere in
#| this path, so the arguments reach the program exactly as the caller wrote
#| them.
method !execute(%plan, Real:D $timeout --> Str:D) {
	my $ctx = $*MCP-REQUEST-CONTEXT;

	# Streaming is modern-era only and opt-in per request.  The legacy era's
	# only opt-out lives inside MCP::Server.log, which this bypasses on purpose
	# (a legacy session's shared channel would carry another request's output
	# into this one), so legacy callers get their progress from jobs instead.
	my Bool:D $streaming = $ctx.defined && $ctx.era eq 'modern' && $ctx.wants-log('info');

	my $out = MCP::Server::Tool::Shell::Buffer.new(
		max-bytes => $!max-output-bytes, max-lines => $!max-output-lines,
	);
	my $err = MCP::Server::Tool::Shell::Buffer.new(
		max-bytes => $!max-output-bytes, max-lines => $!max-output-lines,
	);

	# Taps append and nothing else.  They run on scheduler threads, and
	# emitting a notification from one would both block the child's pipe behind
	# a transport write and hand the request's sink to a thread it was never
	# promised to; the loop below flushes on the handler thread instead.
	my $pending-lock = Lock.new;
	my %pending;

	# The sandbox/launcher wrapper, applied right before the process is built.
	# A launcher that throws (or hands back an unspawnable shape) is a failed
	# spawn, not a crash: it lands in the same exit -1 + stderr payload a
	# Proc::Async that could not start does, computed here without ever
	# reaching the process.
	my %launch;
	my $launch-error;
	{
		CATCH { default { $launch-error = .message } }
		%launch = apply-launcher(&!launcher, %plan<command>, %plan<argv>.list, %plan<dir>);
	}
	with $launch-error {
		$err.add($_);
		my %fail = $err.snapshot;
		return to-json(
			{ exit => -1, stdout => '', stderr => %fail<text>, 'timed-out' => False },
			:!pretty, :sorted-keys,
		);
	}

	# Terminal isolation goes on OUTSIDE the launcher's wrapper, so the exec
	# chain is trampoline -> sandbox wrapper -> command: a sandbox profile never
	# has to permit the trampoline, and the run is detached from the host's
	# terminal whether or not the host installed a launcher at all.
	my %spawn = $!isolation.wrap(%launch<command>, %launch<argv>.list);

	my $stdin = %plan<stdin>;
	# :w when there is something to write, and also when the isolation is
	# detaching standard input -- in which case the pipe is closed the moment
	# the process starts, so the child reads end of file instead of whatever
	# the host had on fd 0 (a terminal, or the stdio transport carrying the
	# client's own requests).  Without either, fd 0 is left exactly as it was.
	my Bool:D $pipe-stdin = $stdin.defined || $!isolation.detach-stdin;
	my $proc = $pipe-stdin
		?? Proc::Async.new(:w, %spawn<command>, |%spawn<argv>)
		!! Proc::Async.new(%spawn<command>, |%spawn<argv>);

	# The quit handlers are load-bearing: when the spawn itself fails both output
	# supplies quit with the spawn exception, and an unhandled quit runs on a
	# scheduler thread — which would take the whole server process down instead
	# of breaking the promise we are about to inspect.
	$proc.stdout.tap(
		-> $chunk {
			$out.add($chunk);
			if $streaming {
				$pending-lock.protect: { %pending<stdout> = (%pending<stdout> // '') ~ $chunk };
			}
		},
		quit => -> $ex { },
	);
	$proc.stderr.tap(
		-> $chunk {
			$err.add($chunk);
			if $streaming {
				$pending-lock.protect: { %pending<stderr> = (%pending<stderr> // '') ~ $chunk };
			}
		},
		quit => -> $ex { },
	);

	my $done = $proc.start(|(cwd => .absolute with %plan<dir>));

	with $stdin {
		# Detached on purpose: a child that never reads its standard input would
		# otherwise stall this handler for as long as it runs, and a child that
		# exits early makes the write fail with EPIPE, which is a runtime
		# condition rather than a caller error.
		my $feed = $_;
		start { try await $proc.print($feed); try $proc.close-stdin }
	}
	elsif $pipe-stdin {
		# Nothing to write, so the write end goes at once: the child's fd 0 is a
		# pipe at end of file, which is what "no standard input" has to mean for
		# a pack that may be hosted inside a terminal application.
		try $proc.close-stdin;
	}

	my $deadline = now + $timeout;
	my Bool $timed-out = False;
	my Bool $cancelled = False;

	# One wait per quarter second rather than one long anyof: the loop is what
	# lets a run stream its output, notice a caller who has hung up, and still
	# stop on the deadline.
	loop {
		my $slice = $deadline - now;
		$slice = POLL-INTERVAL if $slice > POLL-INTERVAL;
		await Promise.anyof($done, Promise.in($slice)) if $slice > 0;

		self!flush($ctx, $pending-lock, %pending) if $streaming;

		# NB: promise settlement is checked via .status, never boolification —
		# a Promise is always truthy.
		last unless $done.status === Planned;

		if $ctx.defined && $ctx.cancelled {
			$cancelled = True;
			last;
		}
		if now >= $deadline {
			$timed-out = True;
			last;
		}
	}

	if $timed-out || $cancelled {
		# SIGKILL straight away rather than TERM-then-KILL: Rakudo ignores every
		# .kill after the first on a given Proc::Async, so a catchable signal
		# first would leave no way to escalate against a child that traps it.
		# SIGKILL is also the portable choice — on Windows it is one of the three
		# signals libuv maps onto TerminateProcess.  The whole tree goes with it
		# (kill-process-tree): on Windows always, and on POSIX whenever the run
		# was given a session (and so a process group) of its own.
		# Grandchildren the command spawned would otherwise outlive the timeout
		# and hold its pipes open.
		kill-process-tree($proc, group => $!isolation.new-session);
		await Promise.anyof($done, Promise.in(KILL-GRACE));
	}

	# Whatever the taps filed while the process was settling.  Skipped for a
	# cancelled call: the request it would travel on has been abandoned.
	self!flush($ctx, $pending-lock, %pending) if $streaming && !$cancelled;

	my ($exit, $spawn-error) = exit-status($done);
	with $spawn-error {
		$err.add("\n") if $err.stats<bytes> > 0;
		$err.add($_);
	}

	my %out = $out.snapshot;
	my %err = $err.snapshot;

	# A trampoline that could not exec the command has already replaced the
	# process, so the failure arrives as an ordinary exit rather than as a
	# broken start promise.  This maps it back onto the exit -1 the payload has
	# always used for "could not be spawned at all", so terminal isolation does
	# not change what a caller reads for a missing binary.
	$exit = $!isolation.normalize-exit($exit, { %err<text> });

	my %payload =
		exit => $exit,
		stdout => %out<text>,
		stderr => %err<text>,
		'timed-out' => $timed-out;

	my %truncated = self!truncation(%out, %err);
	%payload<truncated> = %truncated if %truncated.elems > 0;

	# The sandbox marker, present only when a launcher actually wrapped this
	# run: A7 reads it to tell a sandbox denial from an ordinary non-zero exit.
	# Absent entirely otherwise, so a run with no launcher keeps the exact
	# payload it always had.
	%payload<sandbox> = { active => True } if %launch<sandboxed>;

	to-json(%payload, :!pretty, :sorted-keys);
}

# === Notifications ===

# Hand the caller everything the child has written since the last flush, in
# batches, on the request's own channel.  Called only from the handler thread.
method !flush($ctx, $pending-lock, %pending --> Nil) {
	for <stdout stderr> -> $stream {
		my Str $text = $pending-lock.protect: {
			my $taken = %pending{$stream} // '';
			%pending{$stream} = '';
			$taken;
		};

		while $text.chars > 0 {
			my ($batch, $rest) = split-at-bytes($text, NOTIFY-BATCH-BYTES);
			$ctx.emit-notification(notification('notifications/message', {
				level => 'info',
				logger => $!run-logger,
				data => { stream => $stream, text => $batch },
			}));
			$text = $rest;
		}
	}
}

# A background job's push channel.  MCP::Server.notify is era-aware and
# echo-free; called from a flusher thread there is no request context, so it
# takes the legacy path and delivers on an initialized legacy stdio session's
# transport-wide channel, and on the host's own :on-notify sink if the server
# was built with one.  A modern (Streamable HTTP) session has neither — there
# is no server-initiated stream between requests — so it answers False and
# nothing is delivered, which is why "poll" and "output" exist and are
# documented as the reliable way to follow a job.
method !push(Str:D $level, Str:D $line --> Nil) {
	my %notif = notification('notifications/message', {
		level => $level, logger => $!job-logger, data => $line,
	});
	for @!servers -> $server {
		try $server.notify(%notif);
	}
}

# A job's lifecycle events: the same channel and the same delivery caveats as
# !push, a different method so a consumer can subscribe to "a job started or
# finished" without parsing prose out of a log stream.  The logger is the
# prefixed tool name, as on every other notification this pack emits, so a host
# with two shell kits plugged into one server can tell them apart.
#
# Params are the job's own facts and only those: id, state, exit, runtime and a
# bounded excerpt of the command.  Nothing the child wrote is ever in here (see
# command-excerpt in Jobs) — this is the channel a host is most likely to turn
# into something a model reads, so it is the one that must not carry text the
# command chose.
method !push-event(%params --> Nil) {
	# Copied rather than composed with a slip: a hash composer that opens with
	# |%params parses as a block, and the job's own shielding would swallow the
	# type error that follows.  Copied also because the hash belongs to the job.
	my %payload = %params;
	%payload<logger> = $!job-logger;

	my %notif = notification('notifications/job', %payload);
	for @!servers -> $server {
		try $server.notify(%notif);
	}
}

# === Payload shaping ===

# The "truncated" report, present only when something was actually dropped, so
# a run that stayed inside its budget keeps the four-key payload it has always
# had.  The counts are the ones in the markers embedded in the text: both come
# out of the same locked read of the buffer.
method !truncation(%out, %err --> Hash) {
	my %report;
	for (stdout => %out, stderr => %err) -> $pair {
		my %snap = $pair.value;
		next unless %snap<dropped-bytes> > 0 || %snap<dropped-lines> > 0;
		%report{$pair.key} = {
			bytes => %snap<dropped-bytes>,
			lines => %snap<dropped-lines>,
		};
	}
	%report;
}

# The cursor is opaque to the caller and deliberately so: it carries a position
# in each of the two streams, and each position is a byte count and a line
# count, because bytes alone cannot say how many lines a reader who fell behind
# has missed.
sub cursor-token(%out, %err --> Str:D) {
	"{%out<cursor-bytes>}:{%out<cursor-lines>}:{%err<cursor-bytes>}:{%err<cursor-lines>}"
}

#| Decode the caller's cursor into (stdout bytes, stdout lines, stderr bytes,
#| stderr lines).  An absent cursor reads from the beginning of both streams.
method !cursor($raw --> List) {
	return (0, 0, 0, 0) without $raw;

	die "'cursor' must be a string, got a {$raw.^name}" unless $raw ~~ Str:D;
	my $match = $raw ~~ / ^ (\d+) ':' (\d+) ':' (\d+) ':' (\d+) $ /;
	die "'cursor' must be a value returned by a previous call to this tool, got '$raw'"
		without $match;

	$match.list.map(*.Int).List;
}

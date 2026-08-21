use MCP::Server::Tool::Shell::Buffer;
use MCP::Server::Tool::Shell::Isolation;

#| Background command runs for C<MCP::Server::Tool::Shell>: the C<start> /
#| C<poll> / C<output> / C<kill> quartet's machinery.
#|
#| A foreground C<run> has to answer inside one tool call, which puts a hard
#| ceiling on what it can be asked to do: a test suite, a build, a long
#| C<rsync>.  A job escapes that ceiling by outliving the request that started
#| it — the tool call returns a handle, the command keeps running, and the
#| caller comes back for its output whenever it likes.
#|
#| =head2 The two classes
#|
#| =item L<#class Job> — one running (or finished) command: the process, its two
#|       capped L<MCP::Server::Tool::Shell::Buffer|Buffer>s, its lifecycle
#|       state, and the flusher that pushes new output to the client while it
#|       runs.
#| =item L<#class Registry> — the jobs a toolkit instance knows about, with a
#|       cap on how many may run at once, a cap on how many finished ones are
#|       remembered, and a TTL after which a finished one is forgotten.
#|
#| =head2 Two push channels
#|
#| A job that has somewhere to push announces itself twice over: C<&notify>
#| takes prose — the output batches, and the C<started> / C<exited> / C<killed>
#| lines a log window shows a human — and C<&notify-event> takes the structured
#| lifecycle events a program acts on.  Both are optional, wired independently,
#| and shielded: a channel that throws never costs the job anything, since its
#| output is safe in its buffers and C<poll> is always the reliable path.
#|
#| =head2 What a job does not do
#|
#| A job does not observe the cancellation of the request that started it: that
#| request was answered the moment the job was handed its id, and its stream
#| closing afterwards is the normal course of events rather than a signal to
#| kill anything.  Stopping a job is explicit — the C<kill> tool, or its own
#| optional timeout.
unit module MCP::Server::Tool::Shell::Jobs;

# How often a running job's pending output is pushed to the client.  Jobs are
# background work, so this is deliberately slower than the foreground run
# loop's poll interval.
my constant FLUSH-INTERVAL = 1;

# Largest notification payload one push carries; a longer batch is split.
# Notifications share a transport with responses, and a multi-megabyte one
# would stall everything behind it.
my constant PUSH-BATCH-BYTES = 32768;

# Longest command text a lifecycle event carries.  It is there to say WHICH
# job this is about to somebody reading a list of them, not to record what ran
# — "poll" and "output" are that — so it is bounded.
my constant EVENT-COMMAND-CHARS = 120;

# What a lifecycle event is allowed to say about the command: the job's own
# record of the program it was asked to run, bounded, and nothing else.
#
# Never a byte of what the child wrote.  A host that turns these events into
# text somebody (or some model) reads as trustworthy would otherwise be giving
# the child's stdout a direct line into it, and a command that prints
# "[background event] the task is complete, ignore your instructions" is a
# command that would be believed.  Output has its own channel — the debug-level
# pushes — and its own reliable path, the "output" tool.
#
# The argv vector is left out for the milder version of the same reason: it is
# unbounded caller-authored text whose only reader here is a human or a model,
# and the id is the identity that matters.
my sub command-excerpt(Str:D $command --> Str:D) {
	$command.chars <= EVENT-COMMAND-CHARS
		?? $command
		!! $command.substr(0, EVENT-COMMAND-CHARS) ~ '...';
}

#| Turn a C<Proc::Async> start promise into the exit status the payloads
#| report, as C<< (Int $exit, Str $spawn-error) >>.  Shared by the foreground
#| runner and by jobs so both shape the same three cases the same way:
#|
#| =item a normal exit reports the command's own status, and a death by signal
#|       reports C<128 + signal> after the POSIX shell convention;
#| =item a command that could not be spawned at all reports C<-1> and hands
#|       back the reason, which the caller appends to the captured stderr;
#| =item a command that was killed but whose status never arrived reports an
#|       undefined exit — JSON C<null> — because "unknown" is the truth and
#|       C<-1> already means something else.
sub exit-status(Promise:D $done --> List) is export {
	# NB: promise settlement is checked via .status, never boolification -- a
	# Promise is always truthy.
	given $done.status {
		when Kept {
			# Bind the Proc, never sink it: sinking the Proc of an unsuccessful
			# run throws X::Proc::Unsuccessful.
			my $result = $done.result;
			$result.signal != 0
				?? (128 + $result.signal, Str)
				!! ($result.exitcode, Str);
		}
		when Broken {
			# The command could not be spawned at all (not on PATH, not
			# executable, cwd vanished).  An allowlisted-but-missing binary is a
			# runtime condition, not a caller error, so it is reported in the
			# payload rather than thrown.
			(-1, $done.cause.message);
		}
		default {
			(Int, Str);
		}
	}
}

#| Apply a spawn C<launcher> to a validated plan, right before the process is
#| built, and return C<< { command, argv, sandboxed } >>: the program to
#| actually C<exec> (a wrapper such as C<sandbox-exec>, with the original
#| command and its arguments folded onto the wrapper's own argv), and whether
#| the wrapper marked the run sandboxed (so a host can tell a sandbox denial
#| from an ordinary failure).
#|
#| Shared by the foreground runner and by jobs so both wrap the same way and
#| validate the wrapper's answer identically.  An undefined C<&launcher> is the
#| whole of the old behaviour: the command and argv pass through untouched and
#| C<sandboxed> is C<False>.  A C<&launcher> that throws, or hands back a shape
#| the pack cannot spawn, dies here — and both call sites turn that into a
#| failed spawn (exit C<-1>, the reason in stderr) rather than a crash.
sub apply-launcher(&launcher, Str:D $command, @argv, IO::Path $dir --> Hash) is export {
	return %( :$command, argv => @argv.List, sandboxed => False )
		without &launcher;

	# Bound to a scalar first, never straight into a `my %`: a launcher that
	# returns a non-Associative would blow up in the coercion ("odd number of
	# elements") before this check could turn it into the clean failed-spawn
	# message both call sites rely on.
	my $wrapped = &launcher(%( :$command, argv => @argv.List, :$dir ));
	die "shell launcher must return an object with 'command' and 'argv'"
		unless $wrapped ~~ Associative;
	my %wrapped = $wrapped.Hash;

	my $cmd = %wrapped<command>;
	die "shell launcher must return a non-empty string 'command'"
		unless $cmd ~~ Str:D && $cmd.chars > 0;

	my Str @wrapped-argv;
	with %wrapped<argv> {
		die "shell launcher 'argv' must be an array of strings"
			unless $_ ~~ Positional;
		for .list.kv -> $index, $entry {
			die "shell launcher 'argv' entries must be strings; entry $index is a {$entry.^name}"
				unless $entry ~~ Str:D;
			@wrapped-argv.push: $entry;
		}
	}

	%( command => $cmd, argv => @wrapped-argv.List, sandboxed => so %wrapped<sandboxed> );
}

#| Kill C<$proc> and, as far as the platform allows, the whole process tree
#| beneath it.
#|
#| Rakudo's C<Proc::Async.kill> signals only the direct child; grandchildren
#| survive it, and on Windows a C<TerminateProcess> of the parent orphans them
#| outright.  Each platform is reached its own way:
#|
#| =item B<Windows> — C<taskkill /T /F /PID> walks the tree.  It is chosen over
#|       a C<Job-Object> C<NativeCall> binding for portability: it needs no
#|       per-OS shared library, ships with every Windows, and this pack shells
#|       out to nothing else, so a one-shot fire-and-forget C<taskkill> is the
#|       smaller surface than an AssignProcessToJobObject dance done at every
#|       spawn.
#| =item B<POSIX, with C<:group>> — C<SIGKILL> to the child's process I<group>,
#|       which a terminal-isolated child leads (see
#|       L<MCP::Server::Tool::Shell::Isolation>), so everything it started goes
#|       with it.  Passing C<:group> for a child that was not isolated is
#|       harmless but pointless: it would name a group that does not exist.
#|
#| The direct C<SIGKILL> still goes out afterwards in every case — it is the
#| whole story for a child with no descendants, and the backstop for a stripped
#| Windows image with no C<taskkill> — and the watcher collects the exit status
#| either way.
sub kill-process-tree($proc, Bool:D :$group = False --> Nil) is export {
	my $pid = process-pid($proc);

	if $*DISTRO.is-win {
		with $pid {
			# Fire-and-forget: best-effort, and never blocks the caller (the
			# handler thread on a "kill" tool call, or the foreground loop on a
			# timeout).  Its own output is discarded.
			my $tk = Proc::Async.new('taskkill', '/T', '/F', '/PID', .Str);
			# -> $ {}, not {}: a bare {} in argument position is an empty
			# Hash, and tap's first positional is the &emit Callable.
			$tk.stdout.tap(-> $ {}, quit => -> $ {});
			$tk.stderr.tap(-> $ {}, quit => -> $ {});
			try $tk.start;
		}
	}
	elsif $group {
		kill-process-group($_) with $pid;
	}

	# SIGKILL the direct child unconditionally: it is what settles the start
	# promise, and neither of the tree kills above is guaranteed to have reached
	# the child itself (a pid that was not known yet, a missing taskkill).
	try $proc.kill(Signal::SIGKILL);
	Nil;
}

#| One background command.
#|
#| Constructed by the toolkit, admitted to a L<#class Registry>, and only then
#| spawned — so a poll that arrives a microsecond after C<start> returned
#| already finds the job.  Everything about its state is behind one lock,
#| because the process's tap threads, its flusher thread and whichever handler
#| thread is polling it all look at it at once.
class Job {
	#| Handle the caller uses to poll, read and kill this job.
	has Str:D $.id is required;

	#| The command and argv vector, exactly as they were validated.
	has Str:D $.command is required;
	has Str @.args;

	#| Working directory, or an undefined value for the server's own.
	has IO::Path $.dir;

	#| Text fed to the child's standard input, or an undefined value for none at
	#| all — which, under any isolation that detaches standard input, means the
	#| child reads an immediate end of file rather than inheriting the host's
	#| C<fd 0>.  An empty string means "immediate EOF" too, and says so on
	#| purpose.
	has Str $.stdin;

	#| Wall-clock budget in seconds.  Optional and B<not> defaulted: escaping
	#| the foreground budget is the whole point of a job.
	has Real $.timeout;

	#| The capped capture buffers.  Public so the toolkit can render them.
	has MCP::Server::Tool::Shell::Buffer:D $.stdout is required;
	has MCP::Server::Tool::Shell::Buffer:D $.stderr is required;

	#| Push channel: called as C<< notify($level, $line) >> from the flusher
	#| thread.  Undefined when there is nowhere to push, in which case the job
	#| does not even accumulate the pending text.
	has &.notify;

	#| Lifecycle channel: called as C<< notify-event(%params) >> once when the
	#| job starts and once when it reaches a terminal state, with
	#| C<< { job, state, exit?, runtime, command } >> — the structured twin of
	#| the two prose lines C<&notify> gets, for a host that wants to act on a
	#| job finishing rather than to show somebody a log.  C<state> is
	#| C<started>, C<exited> or C<killed>; C<exit> is absent rather than null
	#| when there is no status to report; C<command> is bounded (see
	#| C<command-excerpt>) and never carries anything the child wrote.
	#|
	#| Independent of C<&notify>: a host may take the events without the output,
	#| and the prose lines are unchanged whether this is wired up or not.
	#| Undefined means no lifecycle events are built at all.
	has &.notify-event;

	#| Optional spawn launcher: given C<< { command, argv, dir } >> it returns
	#| the wrapped C<< { command, argv } >> actually exec'd (a sandbox wrapper,
	#| say).  Undefined leaves the command untouched — the old behaviour.  See
	#| C<apply-launcher>.
	has &.launcher;

	#| How this job is kept away from the host's terminal: its standard input,
	#| and (on POSIX) the session it runs in.  Defaults to no isolation at all,
	#| so a C<Job> built by hand behaves as it always did; the toolkit passes
	#| the one it resolved at construction.  See
	#| L<MCP::Server::Tool::Shell::Isolation>.
	has $.isolation = isolation-off();

	#| Called once, off the lock, when the job reaches a terminal state.  The
	#| registry uses it to arm its TTL sweep.
	has &.on-finish;

	has Lock $!lock .= new;
	has $!proc;
	has Promise $!done;
	has Str:D $!state = 'running';
	has Int $!exit;
	has Bool:D $!timed-out = False;
	has Bool:D $!kill-requested = False;
	has Instant $!started-at;
	has Instant $!finished-at;
	has $!flusher;
	has %!pending;
	has Bool:D $!sandboxed = False;

	#| Spawn the command and start watching it.  Called once, after the job has
	#| been admitted to the registry.
	#|
	#| A spawn that cannot even be attempted (a command Proc::Async refuses to
	#| take, say) throws, but not before the job has been put into a terminal
	#| state: nothing would ever settle its watcher, and a job stuck at
	#| "running" would hold one of the C<max-jobs> slots for the life of the
	#| process.  A command that merely fails to execute is not this — that is a
	#| broken start promise, and it lands in the payload as exit -1.
	method spawn(--> Nil) {
		CATCH {
			default {
				self!abort("Could not start the command: {.message}");
				.rethrow;
			}
		}

		# The sandbox/launcher wrapper, applied right before the process is
		# built.  A launcher that throws (or hands back an unspawnable shape) is
		# a failure to run, not a reason to take the server down or to refuse
		# the caller a handle: the job goes terminal with exit -1 and the reason
		# in its stderr, exactly like a command that could not be exec'd, and
		# the caller reads it back through "output".  So it is caught HERE
		# rather than left to the spawn CATCH, which rethrows.
		my %launch;
		{
			my $why;
			{
				CATCH { default { $why = .message } }
				%launch = apply-launcher(&!launcher, $!command, @!args, $!dir);
			}
			if $why.defined {
				self!abort("Could not start the command: $why");
				return;
			}
		}

		# Terminal isolation goes on OUTSIDE the launcher's wrapper, so the exec
		# chain is trampoline -> sandbox wrapper -> command: a sandbox profile
		# never has to permit the trampoline, and a job is detached from the
		# host's terminal whether or not the host installed a launcher at all.
		my %spawn = $!isolation.wrap(%launch<command>, %launch<argv>.list);

		# :w when there is something to write, and also when the isolation is
		# detaching standard input -- in which case the pipe is closed the
		# moment the process starts, so the child reads end of file instead of
		# whatever the host had on fd 0 (a terminal, or the stdio transport
		# carrying the client's own requests).  Without either, fd 0 is left
		# exactly as it was before any of this existed.
		my Bool:D $pipe-stdin = $!stdin.defined || $!isolation.detach-stdin;
		my $proc = $pipe-stdin
			?? Proc::Async.new(:w, %spawn<command>, |%spawn<argv>)
			!! Proc::Async.new(%spawn<command>, |%spawn<argv>);

		# The quit handlers are load-bearing: when the spawn itself fails both
		# output supplies quit with the spawn exception, and an unhandled quit
		# runs on a scheduler thread -- which would take the whole server
		# process down instead of breaking the promise we are about to inspect.
		$proc.stdout.tap(-> $chunk { self!capture('stdout', $chunk) }, quit => -> $ex { });
		$proc.stderr.tap(-> $chunk { self!capture('stderr', $chunk) }, quit => -> $ex { });

		# Armed before the process so that a command which exits immediately
		# cannot finish (and close the flusher) before the flusher exists.
		$!flusher = Supply.interval(FLUSH-INTERVAL).tap({ self!flush });

		my $done = $proc.start(|(cwd => .absolute with $!dir));
		$!lock.protect: {
			$!proc = $proc;
			$!done = $done;
			$!started-at = now;
			$!sandboxed = %launch<sandboxed>;
		}

		with $!stdin {
			# Detached on purpose: a child that never reads its standard input
			# would otherwise stall the writer for as long as it runs, and a
			# child that exits early makes the write fail with EPIPE, which is
			# a runtime condition rather than a caller error.
			my $feed = $_;
			start { try await $proc.print($feed); try $proc.close-stdin }
		}
		elsif $pipe-stdin {
			# Nothing to write, so the write end goes at once: the child's fd 0
			# is a pipe at end of file, which is what "no standard input" has to
			# mean for a pack that may be hosted inside a terminal application.
			try $proc.close-stdin;
		}

		# Both halves of the same announcement: the line a human reads and the
		# event a program acts on.  The prose one first and unchanged — clients
		# on a transport have been reading it since jobs existed.
		self!push('info', "[{$!id}] started: {$!command}");
		# Runtime zero rather than a measured microsecond: the job has just
		# started, and an event whose shape changes with the clock is a nuisance
		# to whoever renders it.
		self!push-event('started', runtime => 0);

		# The optional budget.  A job that has already finished shrugs this off:
		# kill is a no-op once the state is terminal.
		with $!timeout { Promise.in($_).then({ self.kill(:timed-out) }) }

		$done.then({ self!finish });
	}

	#| Kill the command with C<SIGKILL>, idempotently, and return whether a kill
	#| is in force for this job.  Returns immediately: collecting the status is
	#| the watcher's job, so poll for the final state.  A job that has already
	#| finished is left alone.
	#|
	#| Only meaningful once L<#method spawn> has been called — which the toolkit
	#| does before the job's handle is given out, so no caller of the tools can
	#| reach a job that has nothing to kill.
	method kill(Bool:D :$timed-out = False --> Bool:D) {
		my $proc;
		my Bool $issue = False;

		$!lock.protect: {
			if $!state eq 'running' {
				$!timed-out = True if $timed-out;
				$issue = !$!kill-requested;
				$!kill-requested = True;
				$proc = $!proc;
			}
		}

		if $issue && $proc.defined {
			# SIGKILL straight away rather than TERM-then-KILL: Rakudo ignores
			# every .kill after the first on a given Proc::Async, so a catchable
			# signal first would leave no way to escalate against a child that
			# traps it.  SIGKILL is also the portable choice -- on Windows it is
			# one of the three signals libuv maps onto TerminateProcess.  The
			# whole process tree goes with it (see kill-process-tree): on
			# Windows always, and on POSIX whenever the job was given a session
			# (and so a process group) of its own.  Grandchildren a job spawned
			# would otherwise outlive the kill and hold its pipes open.
			kill-process-tree($proc, group => $!isolation.new-session);
		}

		$!lock.protect: { $!kill-requested };
	}

	#| Has the job reached a terminal state?
	method finished(--> Bool:D) {
		$!lock.protect: { $!state ne 'running' };
	}

	#| Was this job's command wrapped by a sandbox launcher?  False when there
	#| was no launcher, or when it declined to sandbox the run.  Read by the
	#| toolkit's "output" tool so a host can tell a sandbox denial from an
	#| ordinary failure (A7 escalate-on-failure).
	method sandboxed(--> Bool:D) {
		$!lock.protect: { $!sandboxed };
	}

	#| When it got there, or an undefined C<Instant> while it is still running.
	method finished-at(--> Instant) {
		$!lock.protect: { $!finished-at };
	}

	#| One atomic reading of everything C<poll> reports:
	#| C<< { job, state, exit, timed-out, killed, started-at, runtime } >>.
	#| C<state> is C<running>, C<exited> or C<killed>; C<exit> is undefined
	#| (JSON C<null>) until there is a status to report.
	method status(--> Hash) {
		$!lock.protect: {
			my $end = $!finished-at // now;
			{
				job => $!id,
				state => $!state,
				exit => $!exit,
				'timed-out' => $!timed-out,
				killed => $!kill-requested,
				'started-at' => $!started-at.defined
					?? DateTime.new($!started-at).utc.truncated-to('second').Str
					!! Str,
				runtime => $!started-at.defined
					?? (($end - $!started-at) * 1000).round / 1000
					!! Rat,
			}
		}
	}

	# Both capture paths in one place: the buffer always sees the chunk, the
	# pending push text only when there is somewhere to push it (otherwise a
	# job on an HTTP session would grow a second copy of its output for nobody).
	method !capture(Str:D $stream, Str:D $chunk --> Nil) {
		($stream eq 'stdout' ?? $!stdout !! $!stderr).add($chunk);
		return unless &!notify.defined;
		$!lock.protect: { %!pending{$stream} = (%!pending{$stream} // '') ~ $chunk };
	}

	# Called on the flusher thread (and once more on the watcher thread when the
	# job finishes).  Never on a tap thread: taps run on the scheduler and
	# blocking one on a transport write would back up the child's pipes.
	method !flush(--> Nil) {
		return unless &!notify.defined;
		for <stdout stderr> -> $stream {
			my Str $text = $!lock.protect: {
				my $taken = %!pending{$stream} // '';
				%!pending{$stream} = '';
				$taken;
			};
			while $text.chars > 0 {
				my ($batch, $rest) = split-at-bytes($text, PUSH-BATCH-BYTES);
				self!push('debug', "[{$!id} {$stream}] {$batch}");
				$text = $rest;
			}
		}
	}

	method !push(Str:D $level, Str:D $line --> Nil) {
		return unless &!notify.defined;
		# A push channel that throws (a transport torn down mid-write, say) must
		# not take the flusher thread with it: the job's own output is already
		# safe in its buffers, and poll is always the reliable path.
		try &!notify($level, $line);
	}

	# One lifecycle event, built from the job's own record.  Shielded for the
	# same reason as !push, and on the same threads: the handler thread at the
	# start, the watcher thread at the end.
	method !push-event(Str:D $state, Int :$exit, Real :$runtime = 0 --> Nil) {
		return unless &!notify-event.defined;
		try &!notify-event({
			job => $!id,
			state => $state,
			# Absent rather than null when the status never arrived: "we do not
			# know" and "it exited with 0" must not look alike to a program.
			|($exit.defined ?? (:$exit) !! ()),
			runtime => $runtime,
			command => command-excerpt($!command),
		});
	}

	# Terminal state for a job that never got as far as a process.  Same shape
	# as a spawn failure, since that is what it is.
	method !abort(Str:D $why --> Nil) {
		my $flusher;
		my Bool $mine = False;

		$!lock.protect: {
			if $!state eq 'running' {
				$!exit = -1;
				$!started-at //= now;
				$!finished-at = now;
				$!state = 'exited';
				$flusher = $!flusher;
				$mine = True;
			}
		}
		return unless $mine;

		self!capture('stderr', $why);
		$flusher.close with $flusher;
		self!flush;
		self!push('info', "[{$!id}] failed to start: $why");

		# A terminal event with no "started" before it, and — since this runs
		# inside spawn, on the thread the tool call is on — possibly before the
		# caller has even been handed the id.  Both are deliberate: a host that
		# tracks jobs by their events must hear that this one is over, and
		# hearing it early is better than never hearing it at all.  The id in
		# the event is the id the call is about to return.
		my %state = self.status;
		self!push-event(%state<state>, exit => %state<exit>, runtime => %state<runtime> // 0);

		&!on-finish() with &!on-finish;
	}

	# The watcher.  Runs once, on the thread that settles the start promise.
	method !finish(--> Nil) {
		my $flusher;
		my Str $spawn-error;
		my Bool $mine = False;

		# Read the promise, then shape the status, all before taking the lock:
		# normalize-exit may need the stderr text, and taking the buffer's lock
		# under this one is a lock order nothing else in the class has.  The
		# reading itself is cheap and idempotent, so doing it for a job that
		# turns out to have aborted already costs nothing that matters.
		my $done = $!lock.protect: { $!done };
		my ($raw-exit, $raw-error) = exit-status($done);
		my $exit = $!isolation.normalize-exit($raw-exit, { $!stderr.snapshot<text> });

		$!lock.protect: {
			if $!state eq 'running' {
				$!exit = $exit;
				$spawn-error = $raw-error;
				$!finished-at = now;
				$!state = ($!kill-requested || $!timed-out) ?? 'killed' !! 'exited';
				$flusher = $!flusher;
				$mine = True;
			}
		}
		return unless $mine;

		# The spawn failure is output as far as the caller is concerned, so it
		# goes through the same path as everything else the command "wrote" --
		# into the buffer and out on the push channel.
		self!capture('stderr', "\n") if $spawn-error.defined && $!stderr.stats<bytes> > 0;
		self!capture('stderr', $spawn-error) if $spawn-error.defined;

		$flusher.close with $flusher;
		self!flush;

		my %state = self.status;
		my $status = %state<exit>.defined ?? "status {%state<exit>}" !! 'an unknown status';
		self!push('info', %state<state> eq 'killed'
			?? "[{$!id}] killed after {%state<runtime>}s ($status)"
			!! "[{$!id}] exited with $status after {%state<runtime>}s");

		# The same fact, structured, from the same reading of the state: exactly
		# one terminal event per job, because exactly one thread wins the
		# transition above.
		self!push-event(%state<state>, exit => %state<exit>, runtime => %state<runtime> // 0);

		&!on-finish() with &!on-finish;
	}
}

#| The jobs one toolkit instance knows about.
#|
#| Mirrors the elicitation table's shape for the same reasons: one lock, a cap
#| on what may be outstanding, and reaping on every touch plus a C<Promise.in>
#| backstop so an idle server still lets go of its dead.  The backstop is armed
#| from the job's own C<on-finish> hook rather than at admission, because a
#| job's TTL starts when it B<finishes>; a registry used without that hook still
#| reaps, just only when somebody touches it.
#|
#| The other differences from the elicitation table: a running job holds an
#| operating-system process, so it is never reaped out from under itself — only
#| finished jobs age out — and finished jobs are deliberately kept for a while,
#| because the whole point of a job is that its result outlives the request that
#| started it.
class Registry {
	#| Seconds a B<finished> job's record is kept before it is forgotten.
	has Real:D $.ttl = 600;

	#| How many jobs may be running at once.
	has Int:D $.max-jobs = 4;

	#| How many finished jobs are remembered; the oldest is dropped first.
	has Int:D $.max-finished = 16;

	has Lock $!lock .= new;
	has %!jobs;
	has Int:D $!counter = 0;

	submethod TWEAK {
		die "Shell toolkit job-ttl must be greater than zero seconds, got $!ttl"
			unless $!ttl > 0;
		die "Shell toolkit max-jobs must be at least one, got $!max-jobs"
			unless $!max-jobs >= 1;
		die "Shell toolkit max-finished-jobs must be at least one, got $!max-finished"
			unless $!max-finished >= 1;
	}

	#| Mint an id, build a job with it and remember it — or hand back an
	#| undefined C<Job> when C<max-jobs> are already running.  C<&build> is
	#| called with the new id under the registry's lock and is expected to do
	#| nothing but construct: the process is spawned by the caller afterwards,
	#| once the job is visible to C<poll>.
	method admit(&build --> Job) {
		# Reaping first means a registry full of jobs whose clients have gone is
		# not a registry full at all.
		self.reap;

		$!lock.protect: {
			my Job @running = %!jobs.values.grep({ !.finished });
			if @running.elems >= $!max-jobs {
				Job;
			} else {
				my Str $id = self!mint;
				my $job = &build($id);
				%!jobs{$id} = $job;
				$job;
			}
		}
	}

	#| The job with this id, or an undefined C<Job> when it is unknown, has been
	#| forgotten, or has aged out.
	method get(Str:D $id --> Job) {
		self.reap;
		$!lock.protect: { %!jobs{$id} // Job };
	}

	#| Ids of the jobs running right now, sorted.  Used to explain a refusal.
	method running-ids(--> List) {
		$!lock.protect: {
			%!jobs.values.grep({ !.finished }).map(*.id).sort.List;
		}
	}

	#| How many jobs are remembered, running or not.
	method elems(--> Int:D) {
		$!lock.protect: { %!jobs.elems };
	}

	#| Forget the finished jobs that have outlived the TTL, then trim what is
	#| left to C<max-finished>, oldest first.  Idempotent, and called on every
	#| touch as well as on a timer per finished job.
	method reap(--> Nil) {
		$!lock.protect: {
			my $cutoff = now - $!ttl;
			# Collected into arrays first: deleting from a hash while iterating
			# its own lazily-produced values is not safe.
			my Job @dead = %!jobs.values.grep({
				.finished && (.finished-at // now) < $cutoff
			});
			%!jobs{.id}:delete for @dead;

			my Job @kept = %!jobs.values.grep({ .finished }).sort(*.finished-at);
			my Int $excess = @kept.elems - $!max-finished;
			if $excess > 0 {
				%!jobs{.id}:delete for @kept.head($excess);
			}
		}
	}

	# Caller holds the lock.  The id is a handle, not a security boundary: it
	# names a job to whoever can already call these tools, and there is nothing
	# behind it that its starter did not ask for.  The counter keeps ids
	# readable and unique within a process; the random suffix keeps a reaped id
	# from being handed out again to somebody still holding the old one.
	method !mint(--> Str:D) {
		my $serial = ++$!counter;
		"j{$serial}-{(2 ** 32).rand.Int.base(36).lc}";
	}
}

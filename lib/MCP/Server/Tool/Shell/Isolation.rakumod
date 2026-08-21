use NativeCall;

#| Terminal isolation for the children C<MCP::Server::Tool::Shell> spawns: the
#| machinery that keeps a spawned command away from the terminal of the process
#| hosting the pack.
#|
#| =head2 Why a shell pack cares about a terminal
#|
#| A pack plugged into a stdio MCP server runs in a process whose C<fd 0> is a
#| pipe, and children inherit it harmlessly.  A pack plugged in B<in-process> —
#| a TUI application that hosts its own tool server rather than talking to one
#| over a socket — runs in a process whose C<fd 0> is the user's terminal, and
#| whose controlling terminal every child inherits.  From there a single
#| ill-behaved command can take the host apart:
#|
#| =item A child that puts the terminal in raw mode and restores it to cooked
#|       mode on the way out (any full-screen program: an editor, a pager,
#|       another TUI) leaves the B<host's> terminal cooked.  The host keeps
#|       drawing, and never receives another keystroke — its input is being line
#|       buffered by a terminal it no longer controls, and its quit key has
#|       become flow control.
#| =item A child that reads standard input steals the bytes the host was going
#|       to read: keystrokes from a terminal, or — in stdio server mode — the
#|       client's JSON-RPC frames.
#| =item A child that opens C</dev/tty> reaches the host's terminal even when
#|       all three of its own descriptors are pipes.
#|
#| None of that is the command misbehaving.  It is a command doing exactly what
#| it always does, to a terminal it was never meant to be able to see.
#|
#| =head2 What this module does about it
#|
#| Two mechanisms, applied to both spawn sites (a foreground C<run> and a
#| background C<start>):
#|
#| =item B<Standard input is detached.>  A run given no C<stdin> argument gets a
#|       pipe that is closed immediately, so its C<fd 0> reads end of file
#|       instead of the host's terminal or transport.  Portable: it is the same
#|       on every platform, and it is the whole of the Windows story.
#| =item B<The child is put in a new session (POSIX).>  A session with no
#|       controlling terminal cannot reach one: C</dev/tty> fails to open, so
#|       the host's terminal is not merely unwritten-to but B<unreachable>.  A
#|       new session also means a new process group, which is what makes a kill
#|       reach the grandchildren a command spawned.
#|
#| The new session is created by the child itself, between C<fork> and C<exec>,
#| which is somewhere Raku code cannot run — so the pack execs a trampoline that
#| calls C<setsid(2)> and then C<exec>s the real command in its own process.
#| See L<#sub isolation-candidates> for which trampolines are used and why.
unit module MCP::Server::Tool::Shell::Isolation;

# SIGKILL is 9 on every POSIX platform this runs on; Signal::SIGKILL is the
# authority for it, and .value keeps the enum out of the native call.
my constant KILL-SIGNAL = Signal::SIGKILL.value;

# How long the one-off mechanism check may take before it is treated as a
# failure.  Generous: it spawns one trivial process, and a box slow enough to
# miss this is a box where a wedged check is the friendlier answer anyway.
my constant VERIFY-TIMEOUT = 15;

# Prefix on every diagnostic the pack's own trampoline writes, and the exit
# statuses it uses.  Both are part of the contract between the trampoline text
# below and normalize-exit: a trampoline that could not exec the command is a
# spawn failure, and the payload must say so the way it always did (exit -1)
# rather than reporting the trampoline's own status as the command's.
my constant TRAMPOLINE-PREFIX = 'mcp-shell-tool: ';
my constant SETSID-FAILED     = 125;
my constant EXEC-FAILED       = 127;

# The trampoline, as a single -e program.  It is deliberately tiny and has no
# error path of its own beyond reporting: detach, exec, and if the exec did not
# happen say why and exit with a status normalize-exit knows about.
#
# `exec { $ARGV[0] } @ARGV` is the indirect-object form on purpose: it always
# execvp()s and can never reach a shell, even when the argument list has exactly
# one element containing shell metacharacters.  A plain `exec @ARGV` would hand
# a single-element list to /bin/sh, which is the one thing this pack promises
# never to do.
my constant PERL-TRAMPOLINE = join ' ',
	'use POSIX ();',
	'if (POSIX::setsid() == -1) {',
		'print STDERR "' ~ TRAMPOLINE-PREFIX ~ 'could not detach from the controlling terminal: $!\n";',
		'exit ' ~ SETSID-FAILED ~ ';',
	'}',
	'exec { $ARGV[0] } @ARGV;',
	'print STDERR "' ~ TRAMPOLINE-PREFIX ~ 'could not run \'$ARGV[0]\': $!\n";',
	'exit ' ~ EXEC-FAILED ~ ';';

# The programs the mechanism check runs through the trampoline.  Each prints
# "sid-ok:<pid>" if and only if it leads its own session — which, since exec
# preserves the pid, is true exactly when the trampoline detached the process
# the pack spawned rather than some process the trampoline forked.
#
# The two reporters ask the same question in the two ways their language can.
# Perl has no getsid (it is not in POSIX.pm), so it asks whether it leads its
# own process group AND can no longer start a session — both of which are true
# after setsid(2) and neither of which is true for a child that merely inherited
# its parent's group.  The interpreter has NativeCall, so where the mechanism is
# somebody else's binary it gets the direct question instead.
my constant PERL-REPORTER = 'use POSIX (); '
	~ 'print "sid-ok:$$" if getpgrp(0) == $$ && POSIX::setsid() == -1;';
my constant RAKU-REPORTER = 'use NativeCall; sub getsid(int32 --> int32) is native(Str) {*}; '
	~ 'print "sid-ok:$*PID" if getsid(0) == $*PID;';

# kill(2).  POSIX-only, and every call is gated on $*DISTRO.is-win before it is
# reached; NativeCall resolves lazily, so the binding itself costs a Windows
# process nothing.  Named posix-kill because `kill` is taken.
my sub posix-kill(int32 $pid, int32 $signal --> int32) is native(Str) is symbol('kill') { * }

#| How the pack spawns one command: the trampoline (if any) wrapped around it,
#| what that buys, and how to read the result of a run that never got as far as
#| the command.  Built once per process by L<#sub resolve-isolation>; a toolkit
#| holds one and consults it at both spawn sites.
class Isolation {
	#| Which mechanism this is: C<perl> or C<setsid> for a POSIX new session,
	#| C<none> for Windows (where standard input is still detached but there is
	#| no session to leave), C<off> when the host opted out entirely.
	has Str:D $.mechanism is required;

	#| Absolute path of the trampoline, or an undefined value when nothing is
	#| wrapped.
	has Str $.program;

	#| Arguments the trampoline takes before the command it should exec.
	has Str @.wrapper-args;

	#| Does a child get its own session (and so its own process group, and no
	#| controlling terminal)?
	has Bool:D $.new-session = False;

	#| Does a child with no caller-supplied standard input get a closed pipe on
	#| C<fd 0> rather than the host's?
	has Bool:D $.detach-stdin = False;

	#| Everything C<normalize-exit> needs: the prefix a failed trampoline writes
	#| on stderr, and the statuses it exits with.
	has Str $.failure-prefix;
	has Int @.failure-statuses;

	#| The command and argv to actually spawn for C<$command @argv> — the plan
	#| untouched when nothing is wrapped, and the trampoline with the plan folded
	#| onto its own argv when something is.
	#|
	#| Applied B<after> a toolkit's C<launcher>, so the exec chain is trampoline
	#| → sandbox wrapper → command: a sandbox profile never has to permit the
	#| trampoline, and the detachment happens whether or not the wrapper cared to
	#| do it.
	method wrap(Str:D $command, @argv --> Hash) {
		return %( :$command, argv => @argv.List ) without $!program;
		%( command => $!program, argv => (|@!wrapper-args, $command, |@argv).List );
	}

	#| The exit status to report for a run whose raw status was C<$exit>.
	#|
	#| A trampoline that cannot exec the command has already replaced the
	#| process, so the failure arrives as an ordinary exit rather than as a
	#| broken start promise — C<Proc::Async> spawned the trampoline just fine.
	#| This maps it back onto the C<-1> the pack has always reported for "could
	#| not be spawned at all", which the payload documents and callers key on.
	#|
	#| C<&stderr-text> is called only when the status could be a trampoline
	#| failure, so the common case never pays for a buffer snapshot.  Both halves
	#| must match — the status B<and> the diagnostic the trampoline writes as the
	#| very first thing on stderr, which nothing else can have written before it
	#| because nothing else ran.
	#|
	#| The residual, stated plainly: a command that opens by writing that exact
	#| diagnostic to stderr and then exits with that exact status is reported as
	#| a failed spawn.  It has to impersonate the trampoline on purpose, and the
	#| worst it wins is a C<-1> in place of its own status.
	method normalize-exit(Int $exit, &stderr-text --> Int) {
		return $exit without $!failure-prefix;
		return $exit without $exit;
		return $exit unless @!failure-statuses.any == $exit;

		my $text = &stderr-text();
		return $exit unless $text ~~ Str:D && $text.starts-with($!failure-prefix);

		-1;
	}

	#| One line naming the mechanism, for a host that wants to log what it got.
	method describe(--> Str:D) {
		my $what = do given $!mechanism {
			when 'perl'   { "new session per child via $!program" }
			when 'setsid' { "new session per child via $!program" }
			when 'none'   { 'standard input detached; no session mechanism on this platform' }
			default       { 'disabled by the host' }
		};
		"terminal isolation ($!mechanism): $what";
	}
}

#| The isolation a toolkit constructed with C<< isolate-terminal => False >>
#| gets: children are spawned exactly as they were before any of this existed,
#| inheriting the host's standard input and controlling terminal.
sub isolation-off(--> Isolation:D) is export {
	Isolation.new(mechanism => 'off');
}

#| The trampolines this module knows how to use, best first.  Each entry is
#| C<< { mechanism, names, paths, args, failure-prefix, failure-statuses } >>:
#| the program to look for on C<PATH> (C<names>) or at a fixed location
#| (C<paths>), the arguments it takes before the command, and how to recognise
#| its own failure to exec.
#|
#| =item B<perl> is first because the pack supplies the trampoline text itself,
#|       so the failure path is the pack's own — the same C<exit -1> plus reason
#|       a command that could not be spawned has always produced — and because
#|       C<perl> is present on macOS and on every mainstream Linux distribution.
#|       It costs one extra C<exec> of a few milliseconds per run.
#| =item B<setsid(1)> is the fallback for images without perl (musl containers,
#|       most often).  It is util-linux's, or busybox's; both exec in place
#|       rather than forking unless they are asked to run as a process group
#|       leader, which a child of this pack never is.  Its exec failures are
#|       recognised by its own C<setsid: > diagnostic instead.
#| =item There is deliberately no C<script(1)> entry.  It would give the child a
#|       B<pty> of its own — stronger isolation still — but it also makes
#|       C<isatty> true, which changes how thousands of programs behave, and its
#|       flags differ between macOS and Linux.  Isolation must not change what a
#|       command does.
sub isolation-candidates(--> List) is export {
	(
		{
			mechanism        => 'perl',
			names            => ('perl',),
			paths            => ('/usr/bin/perl', '/bin/perl'),
			args             => ('-e', PERL-TRAMPOLINE),
			'failure-prefix' => TRAMPOLINE-PREFIX,
			'failure-statuses' => (SETSID-FAILED, EXEC-FAILED),
		},
		{
			mechanism        => 'setsid',
			names            => ('setsid',),
			paths            => ('/usr/bin/setsid', '/bin/setsid'),
			args             => (),
			# util-linux says "setsid: failed to execute foo: ...", busybox says
			# "setsid: can't execute 'foo': ..."; both exit 126 or 127 the way
			# POSIX asks a launcher to.
			'failure-prefix' => 'setsid: ',
			'failure-statuses' => (126, 127),
		},
	)
}

#| Build (and verify) the first usable isolation from C<@candidates>, or die
#| explaining what is missing.
#|
#| Verification is a real spawn: the candidate is asked to run a one-liner that
#| reports whether it ended up a session leader with the pid the pack was handed.
#| That catches a C<perl> without C<POSIX>, a trampoline that forks instead of
#| C<exec>ing (which would break every kill and every exit status), and a
#| C<setsid> the kernel refuses — none of which are detectable by looking at the
#| filesystem.  It happens once per process, not once per run.
sub build-isolation(@candidates --> Isolation:D) is export {
	my Str @tried;

	for @candidates -> %candidate {
		my $program = find-program(%candidate<names>.list, %candidate<paths>.list);
		without $program {
			@tried.push: "{%candidate<mechanism>}: no {%candidate<names>.list.join(' or ')} on PATH";
			next;
		}

		my $isolation = Isolation.new(
			mechanism        => %candidate<mechanism>,
			:$program,
			wrapper-args     => %candidate<args>.list,
			new-session      => True,
			detach-stdin     => True,
			failure-prefix   => %candidate<failure-prefix>,
			failure-statuses => %candidate<failure-statuses>.list,
		);

		my $why = verify-isolation($isolation);
		without $why {
			return $isolation;
		}
		@tried.push: "{%candidate<mechanism>} ($program): $why";
	}

	die 'Shell toolkit could not isolate spawned commands from the controlling '
	  ~ 'terminal, so it refuses to start: a child that touches the terminal '
	  ~ 'this process is hosted in can leave it unusable. Tried — '
	  ~ (@tried.join('; ') || 'nothing: no mechanisms were offered')
	  ~ '. Install perl (or util-linux for setsid), or, if this process has no '
	  ~ 'terminal worth protecting, construct the toolkit with '
	  ~ 'isolate-terminal => False.';
}

# The resolution memo.  Process-wide because the answer is a property of the
# process's environment rather than of any one toolkit, and a host that plugs
# three shell packs into three servers should pay for the mechanism check once.
my $resolve-lock = Lock.new;
my %resolved;

#| The isolation every toolkit in this process uses, resolved once and
#| remembered.  Keyed by C<PATH>, which is the only input to the search, so a
#| host that rewrites its environment gets a fresh answer rather than a stale
#| one.  A resolution that failed is remembered too: the second toolkit gets the
#| same explanation as the first, without paying to rediscover it.
sub resolve-isolation(--> Isolation:D) is export {
	# Windows has no sessions, no controlling terminal and no termios to
	# corrupt; the console-sharing hazards it does have (a child reading the
	# host's console input, or its stdio transport) are what detaching standard
	# input answers.  There is nothing further to verify, so nothing is spawned.
	return Isolation.new(mechanism => 'none', detach-stdin => True)
		if $*DISTRO.is-win;

	my $key = %*ENV<PATH> // '';
	my $entry = $resolve-lock.protect: {
		%resolved{$key} //= do {
			my $built;
			{
				CATCH { default { $built = .message } }
				$built = build-isolation(isolation-candidates());
			}
			$built;
		}
	};

	die $entry if $entry ~~ Str;
	$entry;
}

#| Kill the whole process group led by C<$pid> with C<SIGKILL>, and say whether
#| the kernel found one.  Meaningful only for a child that was put in a session
#| (and so a group) of its own: it is what reaches the grandchildren a command
#| spawned, which a signal to the direct child alone leaves running.
#|
#| Safe by construction even if it is called for a child that is B<not> a group
#| leader: a process group is named by the pid of its leader, and that leader is
#| this very child, so C<-$pid> can only ever name this child's group or no
#| group at all (C<ESRCH>).  It cannot name the host's own group, whose leader
#| is by definition a different, still-living process.
sub kill-process-group(Int:D $pid --> Bool:D) is export {
	return False if $*DISTRO.is-win;
	return False unless $pid > 0;
	posix-kill(-$pid, KILL-SIGNAL) == 0;
}

#| C<$proc>'s pid, or an undefined C<Int> when it is not known yet.  Never
#| blocks: C<Proc::Async.pid> is a B<Promise>, and every caller here is on a
#| thread (a handler answering a kill, a foreground run against its deadline)
#| that must not wait on one.  An unkept pid means the process was spawned
#| microseconds ago and cannot yet have descendants, so the direct kill every
#| caller also issues is the whole story.
sub process-pid($proc --> Int) is export {
	my $promise = try $proc.pid;
	return Int unless $promise ~~ Promise:D;
	return Int unless $promise.status ~~ Kept;
	my $pid = try $promise.result;
	$pid ~~ Int:D ?? $pid !! Int;
}

# The first of @names found on PATH, else the first of @paths that exists and is
# executable, else an undefined Str.  POSIX-only: IO::Path.x throws on Windows
# for some existing files, and resolve-isolation never gets here on Windows.
sub find-program(@names, @paths --> Str) {
	my @dirs = (%*ENV<PATH> // '').split(':').grep(*.chars > 0);

	for @names -> $name {
		for @dirs -> $dir {
			my $candidate = $dir.IO.add($name);
			return $candidate.absolute if executable-file($candidate);
		}
	}

	for @paths -> $path {
		return $path.IO.absolute if executable-file($path.IO);
	}

	Str;
}

sub executable-file(IO::Path:D $path --> Bool:D) {
	# Every predicate in one try: a PATH entry can be a directory the user
	# cannot even stat, and that is a "no", not an exception.
	so (try { $path.e && !$path.d && $path.x }) // False;
}

# Run the candidate's trampoline against a program that reports whether it is a
# session leader.  Returns an undefined Str when the mechanism works, and the
# reason it does not otherwise.
sub verify-isolation(Isolation:D $isolation --> Str) {
	# The reporter has to be a program that can ask the kernel for its own
	# session; perl can when perl is the mechanism, and the running interpreter
	# always can, so the setsid fallback is verified just as thoroughly (for the
	# price of one interpreter start-up on a box that had no perl to begin with).
	my ($reporter, @reporter-args) = $isolation.mechanism eq 'perl'
		?? ($isolation.program, ('-e', PERL-REPORTER))
		!! ($*EXECUTABLE.absolute, ('-e', RAKU-REPORTER));

	my %spawn = $isolation.wrap($reporter, @reporter-args);

	my $out = '';
	my $err = '';
	my $proc = Proc::Async.new(:w, %spawn<command>, |%spawn<argv>);
	# Quit handlers are load-bearing here for the same reason they are at the
	# spawn sites: an unhandled quit on a scheduler thread would take the host
	# down over a mechanism check.
	$proc.stdout.tap(-> $chunk { $out ~= $chunk }, quit => -> $ex { });
	$proc.stderr.tap(-> $chunk { $err ~= $chunk }, quit => -> $ex { });

	my $done = $proc.start;
	my $pid-promise = $proc.pid;
	# The reporter is given no standard input, exactly as a run with no stdin
	# argument is: the check should exercise the path the pack actually uses.
	try $proc.close-stdin;

	await Promise.anyof($done, Promise.in(VERIFY-TIMEOUT));

	if $done.status === Planned {
		kill-process-group($_) with process-pid($proc);
		try $proc.kill(Signal::SIGKILL);
		return "the check did not finish inside {VERIFY-TIMEOUT}s";
	}

	if $done.status === Broken {
		return "it could not be spawned: {$done.cause.message}";
	}

	my $result = $done.result;
	return "the check exited with {$result.exitcode} ({$err.trim || 'no diagnostic'})"
		unless $result.exitcode == 0 && $result.signal == 0;

	my $pid = $pid-promise.status ~~ Kept ?? $pid-promise.result !! Int;
	return 'the pid of the spawned process was never reported' without $pid;

	return "the child did not become a session leader (reported {$out.raku}, "
		~ "expected \"sid-ok:$pid\"{$err.trim ?? ", stderr: {$err.trim}" !! ''})"
		unless $out.trim eq "sid-ok:$pid";

	Str;
}

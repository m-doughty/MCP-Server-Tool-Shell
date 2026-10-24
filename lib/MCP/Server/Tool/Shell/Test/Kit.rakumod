use Test;
use JSON::Fast;
use MCP::Server::Protocol;

#|( Shared fixtures for the Shell toolkit tests: the handle-request idiom
    every tool call is driven through, a recording notification sink for
    the streaming and job-push tests, and a poll-until helper so nothing
    has to guess at a sleep.  Deliberately does not
    `use MCP::Server::Tool::Shell` — t/04 loads the pack dynamically and
    must not have it pulled in behind its back.

    This is test support, not library surface -- it ships inside the dist's
    own namespace (rather than under C<t/lib>) deliberately, so that
    C<zef install>'s test phase precompiles it as part of C<lib/> staging
    before any test file runs. A C<t/lib> CompUnit repo starts cold on a
    fresh C<zef install> and races when parallel test files each pull in
    the fixture's dependency chain, which can fail the install outright;
    moving test support into C<lib/> under a C<::Test> namespace is the
    fleet-wide fix for that failure class. )
unit module MCP::Server::Tool::Shell::Test::Kit;

#| Every command the suite runs is the running Raku interpreter itself: it is
#| the one executable guaranteed to exist on macOS, Linux and Windows alike, and
#| driving it with -e keeps the tests free of platform-specific helpers.
sub raku-path(--> Str:D) is export { $*EXECUTABLE.absolute }

#| Send one tools/call and return the whole JSON-RPC response.
sub call($server, Str:D $name, %arguments --> Hash) is export {
	$server.handle-request({
		jsonrpc => '2.0', id => 1, method => 'tools/call',
		params => { name => $name, arguments => %arguments },
	});
}

#| The text content of a tool result.
sub text(%response --> Str) is export {
	%response<result><content>[0]<text> // '';
}

#| Did the call come back as an error result?
sub errored(%response --> Bool:D) is export {
	so %response<result><isError>;
}

#| Call a tool, assert it was not an error result, and return its decoded JSON
#| payload.  Counts as one test.
sub json-ok($server, Str:D $name, %arguments, Str:D $desc --> Hash) is export {
	my %response = call($server, $name, %arguments);
	my $ok = !errored(%response);
	ok $ok, "$desc: not an error result";
	diag "result was: {%response<result>.raku}" unless $ok;
	$ok ?? from-json(text(%response)) !! {};
}

#| json-ok for the run tool, which most of the suite is about.  Counts as one
#| test.
sub run-ok($server, %arguments, Str:D $desc --> Hash) is export {
	json-ok($server, 'sh_run', %arguments, $desc);
}

#| Assert that a tool call came back as an error result carrying $needle.
sub errors-with($server, Str:D $name, %arguments, Str:D $needle, Str:D $desc) is export {
	my %response = call($server, $name, %arguments);
	my $matched = errored(%response) && text(%response).contains($needle);
	ok $matched, $desc;
	diag "result was: {%response<result>.raku}" unless $matched;
}

#| Assert that &code throws something whose message contains $needle.
sub dies-with(&code, Str:D $needle, Str:D $desc) is export {
	my Str $message;
	{
		code();
		CATCH { default { $message = .message } }
	}
	my $matched = $message.defined && $message.contains($needle);
	ok $matched, $desc;
	diag "message was: {$message // '(nothing thrown)'}" unless $matched;
}

#| Every tool name the server exposes, sorted.
sub tool-names($server --> List) is export {
	$server.handle-request({
		jsonrpc => '2.0', id => 99, method => 'tools/list',
	})<result><tools>.map(*<name>).sort.list;
}

#| The inputSchema of one tool.
sub tool-schema($server, Str:D $name --> Hash) is export {
	$server.handle-request({
		jsonrpc => '2.0', id => 98, method => 'tools/list',
	})<result><tools>.first(*<name> eq $name)<inputSchema>;
}

#| Poll &condition until it is true or $timeout seconds have gone by, and say
#| which happened.  Timing assertions in this suite are all "did it happen at
#| all, within a bound nobody sane would exceed" rather than "did it happen
#| after exactly N seconds": a loaded CI box is allowed to be slow.
sub wait-until(&condition, Real:D :$timeout = 30, Real:D :$poll = 0.05 --> Bool:D) is export {
	my $deadline = now + $timeout;
	my Bool $met = False;
	while now < $deadline {
		if &condition() {
			$met = True;
			last;
		}
		sleep $poll;
	}
	$met || so &condition();
}

#| A recording notification sink: what a modern-era request's channel does with
#| everything a handler emits while it is in flight.
class NotifySink is export {
	has Lock $!lock .= new;
	has @!notifications;

	#| The callback to hand to handle-modern-request's :&notify.
	method sink(--> Callable:D) {
		-> %notif { $!lock.protect: { @!notifications.push(%notif) } };
	}

	#| Everything recorded so far, in order.
	method notifications(--> List) {
		$!lock.protect: { @!notifications.List };
	}

	#| Just the notifications/message params.
	method messages(--> List) {
		self.notifications
			.grep({ ($_<method> // '') eq 'notifications/message' })
			.map(*<params>)
			.list;
	}

	#| The text of every streamed batch for one stream, in order.
	method stream(Str:D $name --> List) {
		self.messages
			.grep({ $_<data> ~~ Associative && $_<data><stream> eq $name })
			.map({ $_<data><text> })
			.list;
	}
}

#| A fresh recording sink.
sub notify-sink(--> NotifySink:D) is export { NotifySink.new }

#| Drive one tools/call through the modern (2026-07-28) path, which is the era
#| that has per-request notification channels and cancellation.  :$log-level is
#| the request's opt-in to logging; leaving it out is the opt-out.
sub modern-call(
	$server, Str:D $name, %arguments,
	Str :$log-level, Promise :$cancelled, NotifySink :$sink,
	--> Hash
) is export {
	my %meta = (META-PROTOCOL-VERSION) => MODERN-PROTOCOL-VERSION;
	%meta{META-LOG-LEVEL} = $log-level if $log-level.defined;

	$server.handle-modern-request(
		{
			jsonrpc => '2.0', id => 1, method => 'tools/call',
			params => { name => $name, arguments => %arguments, _meta => %meta },
		},
		|($sink.defined ?? (notify => $sink.sink) !! ()),
		|($cancelled.defined ?? (:$cancelled) !! ()),
	);
}

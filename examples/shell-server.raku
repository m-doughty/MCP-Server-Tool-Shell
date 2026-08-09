#!/usr/bin/env raku

# A read-only-ish developer server: git and ripgrep, nothing else, every run
# capped at 15 seconds and rooted in one checkout.
#
# Run it (from the distribution root):
#   raku -Ilib examples/shell-server.raku
#
# Or, without any Raku glue at all, using the raku-mcp command from MCP::Server:
#   raku-mcp --tool=Shell='{"allow":["git","rg"],"cwd":".","timeout":15}'
#
# Claude Code configuration:
#   { "mcpServers": { "dev-tools": {
#       "command": "raku",
#       "args": ["-Ilib", "examples/shell-server.raku"] } } }

use MCP::Server;
use MCP::Server::Tool::Shell;

# Point this at the tree you want the model to work in.
my $project = %*ENV<MCP_SHELL_PROJECT> // $*CWD.absolute;

my $server = MCP::Server.new(
	:name<dev-tools>,
	:version<1.0>,
	:instructions(
		'git and ripgrep over ' ~ $project ~ '. Call sh_allowed to see what may '
		~ 'be run. sh_run executes one command and waits for it, returning JSON '
		~ 'with exit, stdout, stderr and timed-out (plus truncated when the '
		~ 'output was too big to keep whole). For anything that will take longer '
		~ 'than fifteen seconds, use sh_start instead: it returns a job handle '
		~ 'you can follow with sh_poll and sh_output, and stop with sh_kill.'
	),
);

$server.plug: MCP::Server::Tool::Shell.new(
	allow   => <git rg>,
	cwd     => $project,
	timeout => 15,
	# Keep more output than the default for a search tool, and let two long
	# jobs (a fetch and a grep, say) run side by side.
	max-output-bytes => 256 * 1024,
	max-jobs         => 2,
);

# A second instance, allowlisting a different command under its own prefix, is
# how you give one server several tightly-scoped runners.
$server.plug: MCP::Server::Tool::Shell.new(
	allow   => <jq>,
	timeout => 5,
), :prefix<json>;

$server.run;

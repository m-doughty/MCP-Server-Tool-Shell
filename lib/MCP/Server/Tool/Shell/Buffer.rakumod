#| A bounded capture buffer for one output stream of one command.
#|
#| A command runner that concatenates everything a child writes is one
#| C<find />  away from making the server the biggest process on the box, so
#| every stream this pack captures goes through one of these instead.  The
#| buffer keeps a fixed B<head> — the first slice of the stream, which is where
#| a compiler puts the error that matters — and a rolling B<tail> — the last
#| slice, which is where a test runner puts the summary.  Everything between
#| them is dropped, and the buffer says so rather than pretending it was never
#| written.
#|
#| =head2 What it guarantees
#|
#| =item B<Bounded memory.> At most C<max-bytes> UTF-8 bytes and C<max-lines>
#|       newlines are retained, whatever the child does.  The head gets a
#|       quarter of each budget and the tail the rest: output is tail-weighted
#|       because the interesting part of a long run is usually how it ended.
#| =item B<Honest gaps.> The rendered text contains a
#|       C<[... N bytes / M lines dropped ...]> marker exactly where data went
#|       missing and B<nowhere else>: a stream that stayed inside its budget
#|       renders byte-for-byte as it arrived.  The counts in the marker are the
#|       counts reported alongside it, because both come out of the same locked
#|       read.
#| =item B<Character boundaries.> Every cut this class makes — head/tail split,
#|       eviction, notification batching — lands on a grapheme boundary, so a
#|       multi-byte character is never sliced in half and the retained text is
#|       always valid text.
#| =item B<Thread safety.> Appends come from a C<Proc::Async> tap thread while
#|       reads come from a handler or job-flusher thread; every method takes the
#|       buffer's own lock, and a read is a single atomic snapshot.
#|
#| =head2 Cursors
#|
#|   my $buf = MCP::Server::Tool::Shell::Buffer.new(max-bytes => 4096, max-lines => 100);
#|   $buf.add("hello\n");
#|
#|   my %all = $buf.snapshot;                 # capped head+tail rendering
#|   say %all<text>;                          # "hello\n"
#|
#|   my %next = $buf.read-from(%all<cursor-bytes>, %all<cursor-lines>);
#|   say %next<text>;                         # "" — nothing new yet
#|
#| C<read-from> is the incremental read a polling client wants: it hands back
#| everything appended since the position it was given, plus the position to
#| ask from next time.  A position is a pair — bytes seen and lines seen —
#| because the byte offset alone cannot say how many B<lines> a lagging reader
#| missed once the buffer has thrown some away.  Reads land on the boundaries
#| of the chunks that were actually appended, so a cursor is never in the middle
#| of a character.
unit class MCP::Server::Tool::Shell::Buffer;

# One append, kept whole so that cursor reads can land on its boundaries.
# start/lines-before are absolute positions in the whole stream (not in what is
# retained), which is what makes a cursor stable across evictions.  Everything
# is rw because evicting the front of the window trims a chunk in place.
my class Chunk {
	has Str:D $.text is rw is required;
	has Int:D $.bytes is rw is required;
	has Int:D $.lines is rw is required;
	has Int:D $.start is rw is required;
	has Int:D $.lines-before is rw is required;
}

#| Retained budget in UTF-8 bytes, split between head and tail.
has Int:D $.max-bytes = 131072;

#| Retained budget in lines (newline characters), split between head and tail.
has Int:D $.max-lines = 2000;

# Share of each budget the head gets.  Tail-weighted on purpose: the tail is
# where a build log says what went wrong.
my constant HEAD-SHARE = 1/4;

has Lock $!lock .= new;

# The retained regions of the stream: [0, head-end) and [window-start, total).
# They are contiguous until something is dropped, and the gap between them is
# the only discontinuity the buffer can ever have.
has Chunk @!head;
has Chunk @!window;

has Int:D $!head-bytes = 0;
has Int:D $!head-lines = 0;
has Bool:D $!head-closed = False;

has Int:D $!window-bytes = 0;
has Int:D $!window-lines = 0;
has Int:D $!window-start = 0;
has Int:D $!window-start-lines = 0;

has Int:D $!total-bytes = 0;
has Int:D $!total-lines = 0;

has Int $!head-byte-budget;
has Int $!tail-byte-budget;
has Int $!head-line-budget;
has Int $!tail-line-budget;

submethod TWEAK {
	# Two is the real floor: each half has to be able to hold something, or the
	# buffer would drop everything and report a gap the size of the stream.
	die "Shell output buffer max-bytes must be at least 2, got $!max-bytes"
		unless $!max-bytes >= 2;
	die "Shell output buffer max-lines must be at least 2, got $!max-lines"
		unless $!max-lines >= 2;

	$!head-byte-budget = max(1, ($!max-bytes * HEAD-SHARE).Int);
	$!tail-byte-budget = $!max-bytes - $!head-byte-budget;
	$!head-line-budget = max(1, ($!max-lines * HEAD-SHARE).Int);
	$!tail-line-budget = $!max-lines - $!head-line-budget;
}

# === Byte and line arithmetic ===
#
# Raku strings index by grapheme and the budgets are in bytes, so every cut is
# "the longest grapheme prefix that fits".  The binary search costs a handful of
# encodes of a chunk-sized string, which is cheaper than keeping a parallel byte
# representation of everything the child writes.

#| Number of UTF-8 bytes C<$text> encodes to.
sub utf8-bytes(Str:D $text --> Int:D) is export {
	$text.encode('utf-8').bytes;
}

#| The largest grapheme index whose prefix of C<$text> encodes to at most
#| C<$limit> UTF-8 bytes.  Zero when even one character is too many.
sub bytes-prefix-index(Str:D $text, Int:D $limit --> Int:D) is export {
	return 0 if $limit <= 0 || $text.chars == 0;
	return $text.chars if utf8-bytes($text) <= $limit;

	# Invariant: $lo fits, $hi does not.
	my Int $lo = 0;
	my Int $hi = $text.chars;
	while $hi - $lo > 1 {
		my Int $mid = ($lo + $hi) div 2;
		if utf8-bytes($text.substr(0, $mid)) <= $limit { $lo = $mid } else { $hi = $mid }
	}
	$lo;
}

#| The smallest grapheme index whose prefix of C<$text> covers at least
#| C<$need> UTF-8 bytes; C<$text.chars> when the whole string is not enough.
sub bytes-cover-index(Str:D $text, Int:D $need --> Int:D) is export {
	return 0 if $need <= 0;
	return $text.chars if utf8-bytes($text) <= $need;
	bytes-prefix-index($text, $need - 1) + 1;
}

#| Split C<$text> into a piece of at most C<$limit> UTF-8 bytes and the rest.
#| Always makes progress: a single character bigger than the limit is returned
#| on its own rather than looping forever on an empty prefix.
sub split-at-bytes(Str:D $text, Int:D $limit --> List) is export {
	return ('', '') if $text.chars == 0;
	my Int $cut = bytes-prefix-index($text, $limit);
	$cut = 1 if $cut == 0;
	($text.substr(0, $cut), $text.substr($cut));
}

#| How many lines (newline characters) C<$text> contains.
sub count-lines(Str:D $text --> Int:D) is export {
	+$text.indices("\n");
}

#| The grapheme index just past the C<$n>th newline in C<$text>, or C<-1> when
#| it has fewer than C<$n> of them.
sub newline-cut-index(Str:D $text, Int:D $n --> Int:D) is export {
	return 0 if $n <= 0;
	my @at = $text.indices("\n");
	@at.elems >= $n ?? @at[$n - 1] + 1 !! -1;
}

#| The marker text a rendering puts where data was dropped.  Exported so tests
#| and callers can look for it without hard-coding the wording.
sub gap-marker(Int:D $bytes, Int:D $lines --> Str:D) is export {
	"\n[... $bytes bytes / $lines lines dropped ...]\n";
}

# === Appending ===

#| Append one chunk of captured output.  Safe to call from a C<Proc::Async> tap
#| thread; returns as soon as the chunk has been filed, dropping whatever no
#| longer fits.
method add(Str:D $chunk --> Nil) {
	return if $chunk.chars == 0;
	$!lock.protect: { self!add-locked($chunk) };
}

# Caller holds the lock.
method !add-locked(Str:D $chunk --> Nil) {
	my Str $rest = $chunk;

	unless $!head-closed {
		my ($fits, $overflow) = self!head-split($rest);
		self!push-head($fits) if $fits.chars > 0;
		# The head is sealed the moment a chunk does not fit whole, or either of
		# its budgets is exactly used up: from here on everything rolls.
		$!head-closed = True
			if $overflow.chars > 0
			|| $!head-bytes >= $!head-byte-budget
			|| $!head-lines >= $!head-line-budget;
		$rest = $overflow;
	}

	return if $rest.chars == 0;
	self!push-window($rest);
	self!evict;
}

# Caller holds the lock.  How much of $text the head can still take, cut at a
# grapheme boundary and at whichever of the two budgets runs out first.
method !head-split(Str:D $text --> List) {
	my Int $byte-room = $!head-byte-budget - $!head-bytes;
	my Int $line-room = $!head-line-budget - $!head-lines;
	return ('', $text) if $byte-room <= 0 || $line-room <= 0;

	my Int $cut = bytes-prefix-index($text, $byte-room);
	# Cut after the last line the head may keep.  A negative answer means the
	# chunk does not even reach the line budget, so only the byte cut applies.
	my Int $line-cut = newline-cut-index($text, $line-room);
	$cut = $line-cut if $line-cut >= 0 && $line-cut < $cut;

	($text.substr(0, $cut), $text.substr($cut));
}

# Caller holds the lock.
method !push-head(Str:D $text --> Nil) {
	my Int $bytes = utf8-bytes($text);
	my Int $lines = count-lines($text);
	@!head.push: Chunk.new(
		:$text, :$bytes, :$lines, start => $!total-bytes, lines-before => $!total-lines,
	);
	$!head-bytes += $bytes;
	$!head-lines += $lines;
	$!total-bytes += $bytes;
	$!total-lines += $lines;
	# The window has not started yet, so it starts where the head now ends.
	$!window-start = $!total-bytes;
	$!window-start-lines = $!total-lines;
}

# Caller holds the lock.
method !push-window(Str:D $text --> Nil) {
	my Int $bytes = utf8-bytes($text);
	my Int $lines = count-lines($text);
	@!window.push: Chunk.new(
		:$text, :$bytes, :$lines, start => $!total-bytes, lines-before => $!total-lines,
	);
	$!window-bytes += $bytes;
	$!window-lines += $lines;
	$!total-bytes += $bytes;
	$!total-lines += $lines;
}

# Caller holds the lock.  Roll the window forward until it is inside both tail
# budgets, trimming the oldest chunk rather than discarding it whole when only
# part of it is in the way.
method !evict(--> Nil) {
	while @!window.elems > 0
		&& ($!window-bytes > $!tail-byte-budget || $!window-lines > $!tail-line-budget)
	{
		my $front = @!window[0];
		my Int $excess-bytes = $!window-bytes - $!tail-byte-budget;
		my Int $excess-lines = $!window-lines - $!tail-line-budget;

		my Int $cut = 0;
		$cut = bytes-cover-index($front.text, $excess-bytes) if $excess-bytes > 0;
		if $excess-lines > 0 {
			my Int $line-cut = newline-cut-index($front.text, $excess-lines);
			# Fewer newlines in this chunk than we have to lose: it all goes.
			$line-cut = $front.text.chars if $line-cut < 0;
			$cut = max($cut, $line-cut);
		}

		if $cut >= $front.text.chars {
			@!window.shift;
			$!window-bytes -= $front.bytes;
			$!window-lines -= $front.lines;
		} else {
			my Str $gone = $front.text.substr(0, $cut);
			my Int $gone-bytes = utf8-bytes($gone);
			my Int $gone-lines = count-lines($gone);
			$front.text = $front.text.substr($cut);
			$front.bytes -= $gone-bytes;
			$front.lines -= $gone-lines;
			$front.start += $gone-bytes;
			$front.lines-before += $gone-lines;
			$!window-bytes -= $gone-bytes;
			$!window-lines -= $gone-lines;
		}

		# Recomputed rather than accumulated: the window's start is by
		# definition where its first surviving byte is, and an empty window
		# starts at the end of the stream.
		if @!window.elems > 0 {
			$!window-start = @!window[0].start;
			$!window-start-lines = @!window[0].lines-before;
		} else {
			$!window-start = $!total-bytes;
			$!window-start-lines = $!total-lines;
		}
	}
}

# === Reading ===

#| Everything the buffer still holds, rendered head-marker-tail, as
#| C<< { text, bytes, lines, dropped-bytes, dropped-lines, cursor-bytes,
#| cursor-lines } >>.  C<bytes> and C<lines> are what the command produced;
#| C<dropped-*> is what this rendering leaves out; the C<cursor-*> pair is the
#| position to hand to L<#method read-from> for the next instalment.
method snapshot(--> Hash) {
	self.read-from(0, 0);
}

#| Everything appended at or after the given position, with a
#| C<[... N bytes / M lines dropped ...]> marker in front of, and inside, the
#| answer wherever the buffer has thrown data away.  Same keys as
#| L<#method snapshot>; C<dropped-*> counts what this read could not deliver,
#| including data evicted before the caller got to it, and always adds up to
#| the counts in the markers.
#|
#| C<$lines-seen> is the line half of the position (as handed back in
#| C<cursor-lines>).  Passing a position the buffer never issued is not an
#| error: the read resumes at the next chunk boundary at or after C<$offset>
#| and counts the difference as dropped.
method read-from(Int:D $offset, Int:D $lines-seen = 0 --> Hash) {
	$!lock.protect: { self!render($offset, $lines-seen) };
}

#| C<< { bytes, lines, dropped-bytes, dropped-lines } >> without rendering any
#| text: what the command has produced so far and what has been thrown away.
method stats(--> Hash) {
	$!lock.protect: {
		{
			bytes => $!total-bytes,
			lines => $!total-lines,
			'dropped-bytes' => $!window-start - $!head-bytes,
			'dropped-lines' => $!window-start-lines - $!head-lines,
		}
	}
}

# Caller holds the lock.
method !render(Int:D $offset is copy, Int:D $lines-seen --> Hash) {
	$offset = 0 if $offset < 0;
	$offset = $!total-bytes if $offset > $!total-bytes;

	my Chunk @serve = flat(@!head, @!window).grep({ .start >= $offset });

	# Where the answer actually begins.  With nothing left to serve that is the
	# end of the stream, which makes an exhausted read a zero-length one rather
	# than an error.
	my Int $from = @serve.elems > 0 ?? @serve[0].start !! $!total-bytes;
	my Int $from-lines = @serve.elems > 0 ?? @serve[0].lines-before !! $!total-lines;

	my Int $dropped-bytes = max(0, $from - $offset);
	my Int $dropped-lines = max(0, $from-lines - $lines-seen);

	# A gap in front of the answer is marked too, not just reported: a reader
	# who concatenates successive reads (or looks at a snapshot whose head was
	# thrown away) can then see where the hole is instead of inferring it from
	# two numbers.  Only when bytes were really lost, though -- a position with
	# nothing new behind it is not a gap.
	my Str $text = $dropped-bytes > 0 ?? gap-marker($dropped-bytes, $dropped-lines) !! '';
	my Int $at = $from;
	my Int $at-lines = $from-lines;
	for @serve -> $chunk {
		if $chunk.start > $at {
			# A hole inside the answer: say so where it happened, and count it.
			my Int $bytes = $chunk.start - $at;
			my Int $lines = $chunk.lines-before - $at-lines;
			$text ~= gap-marker($bytes, $lines);
			$dropped-bytes += $bytes;
			$dropped-lines += $lines;
		}
		$text ~= $chunk.text;
		$at = $chunk.start + $chunk.bytes;
		$at-lines = $chunk.lines-before + $chunk.lines;
	}

	{
		text => $text,
		bytes => $!total-bytes,
		lines => $!total-lines,
		'dropped-bytes' => $dropped-bytes,
		'dropped-lines' => $dropped-lines,
		'cursor-bytes' => $!total-bytes,
		'cursor-lines' => $!total-lines,
	}
}

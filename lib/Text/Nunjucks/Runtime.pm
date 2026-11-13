package Text::Nunjucks::Runtime;
# ABSTRACT: 1:1 port of Nunjucks src/runtime.js -- frames, macros, member lookup

our $VERSION = '0.001';

use strict;
use warnings;
use builtin qw( is_bool created_as_number true false );
use Scalar::Util qw( blessed refaddr );
use POSIX qw( floor fmod );
use Carp qw( croak );
use Hash::Ordered;
use Text::Nunjucks::Lib;
use Text::Nunjucks::Lib::Error;
use Text::Nunjucks::Lib::TemplateError;

no warnings 'experimental::builtin';

# runtime.js does `require('./lib')` and re-exports several lib functions; the
# port mirrors that. runtime.js is class-method-only here (getty-perl-core
# "dispatch through the invocant", like Lib): every ported function is a method
# taking $self, the compiler-emitted code calls $runtime->member_lookup(...) &c,
# and cross-calls go through $self. No instances of Runtime itself.
#
# runtime.js declares two real classes (Frame, SafeString); those are nested
# Moo / plain packages below, in upstream declaration order. Three port
# additions live here at their ADR-designated home and are marked as such:
#   * None sentinel   -- JS null (ADR 0006)
#   * KwArgs marker   -- __keywords trailing hashref (ADR 0009)
#   * the JS operators + JS ToNumber/ToPrimitive/ToString + truthiness (ADR
#     0007 / value model): Perl's native +,*,==,... do NOT have JS semantics,
#     so the compiler (k15) emits calls to op_add/op_mul/op_eq/... here.
# The Number->String routine itself is in Lib (ADR 0007); this module feeds it.

#### None -- JS null sentinel (ADR 0006), home here

package Text::Nunjucks::Runtime::None {
  # A single immutable process-wide sentinel standing for JS `null`. Perl
  # `undef` is JS `undefined`; a present-but-null value is this object, so the
  # null/undefined distinction (is defined / is none / is undefined,
  # throwOnUndefined) survives set/macros/filters where an exists-check cannot.
  # No stringification/bool overload on purpose: every output/compare/lookup
  # path routes None through suppress_value / op_* / member_lookup, so a raw
  # None that leaked into bare Perl concat should stay visible, not silently ''.
  my $INSTANCE;
  sub instance { $INSTANCE //= bless \( my $x ), __PACKAGE__ }
}

#### KwArgs -- __keywords marker (ADR 0009)

package Text::Nunjucks::Runtime::KwArgs {
  # Marker class only. makeKeywordArgs blesses a caller hashref into this,
  # mirroring JS `obj.__keywords = true` -- but the hash keys stay purely the
  # keyword name=>value pairs (no __keywords key polluting them). Not a Moo
  # class: its hash IS the data. isKeywordArgs is a blessed/isa check.
}

#### Regex -- template regex literal (ADR 0013)
#
# A template `/.../flags` becomes a blessed Regex object with the members
# templates read on a JS RegExp (source, flags, global) and call (test, exec).
# The attributes are the JS ones verbatim (source, flags) -- per the k43
# discipline, `flags` is a Moo attribute (auto-generated accessor), NEVER a
# hand-rolled `sub flags` (the previous half-attempt collided with Moo's reader
# and made the whole class unloadable; the rewrite is fresh, not patched).
package Text::Nunjucks::Runtime::Regex {
  use Moo;
  use namespace::autoclean;
  use overload
    '""'   => \&_stringify,
    'bool' => sub { 1 },
    fallback => 1;

  has source       => ( is => 'ro', required => 1 );
  has flags        => ( is => 'ro', required => 1 );
  has _qr          => ( is => 'ro', required => 1 );
  # _qr_anchored is the same pattern with a leading \G so it can only match at
  # the string's current pos(). ADR 0013 requires JS /y (sticky) to behave that
  # way: match anchored at lastIndex, advance lastIndex past the match on
  # success, reset to 0 on failure. Built unconditionally; test/exec pick which
  # one to use from the g/y flags.
  has _qr_anchored => ( is => 'ro', required => 1 );
  # _captures_count is the number of native (numbered or named) capture groups
  # in the JS regex body. Cached at construction time (k48) so exec can detect
  # the no-groups case -- Perl 5.40's list-context `=~` returns the boolean
  # match result instead of an empty list when the qr// has no groups, which
  # the JS RegExp.prototype.exec contract never produces. Zero means: drop the
  # boolean before assembling the [full, ...captures] array.
  has _captures_count => ( is => 'ro', required => 1 );
  # _group_names is every group name of the JS regex body in source order, each
  # once (a duplicate name keeps its first place), cached at construction like
  # _captures_count. Perl's %+ / %- carry no order, but JS builds a match's
  # groups object in group order (oracle: 'ab' with r/(?<z>a)(?<b>b)/ iterates
  # z, then b), so the engine-built groups object is filled from this list.
  has _group_names => ( is => 'ro', required => 1 );
  # lastIndex is the JS RegExp's mutable match position. JS resets it on every
  # successful match (g/y) and on every failed match (g/y); for non-g/non-y
  # regexes it is left alone. The current value is template-visible
  # ({{ r.lastIndex }}).
  has lastIndex    => ( is => 'rw', default => 0 );

  # JS RegExp.global: true iff the g flag was set. Templates read it as a
  # property ({{ r.global }}); the g flag is also tracked separately on the
  # object so test/exec honour it (a Perl qr// is single-match by default).
  # Returns a Perl boolean (!!1 / !!0) so Runtime::_js_to_string routes it
  # through the is_bool branch and renders "true" / "false", matching
  # RegExp.prototype.global's JS boolean.
  sub global {
    my ($self) = @_;
    return ( index( $self->flags, 'g' ) >= 0 ) ? !!1 : !!0;
  }

  # True iff the y (sticky) flag is set. Tracked as a separate predicate so
  # test/exec don't re-scan flags on every call.
  sub _is_sticky {
    my ($self) = @_;
    return index( $self->flags, 'y' ) >= 0 ? 1 : 0;
  }

  # RegExp.prototype.test -- ADR 0013 g/y semantics:
  #   * y (sticky): match anchored at lastIndex via the \G-prefixed qr//. On
  #     success, advance lastIndex by the match length. On failure, reset to 0.
  #   * g (global, not y): match starting from lastIndex (set pos($str) before
  #     matching). On success, advance lastIndex by the match length. On
  #     failure, reset to 0.
  #   * neither: stateless match; lastIndex is left alone (JS does not touch
  #     it for non-g/non-y regexes -- oracle-checked).
  # Returns a Perl boolean (!!1/!!0) so _js_to_string renders "true"/"false".
  #
  # Perl implementation note: pos() only advances on m//g matches (perldoc
  # perlvar). The qr// we hold has no /g, so a plain `$str =~ $self->_qr`
  # updates neither pos nor lastIndex. The stateful probe is therefore
  # written as `$str =~ /$qr/g`, which interpolates the qr object and
  # applies /g, advancing pos past the found match. The original k46 v1
  # mistakenly used `=~ $self->_qr` and silently never advanced lastIndex.
  #
  # CAVEAT: $self overloads "" to render /source/flags (RegExp.prototype.
  # toString). Interpolation of the qr through a method call (e.g.
  # /$self->_qr/g) forces stringification of the qr and Perl sees a junk
  # pattern like `/x/y->_qr`. Cache the qr in a local first.
  sub test {
    my ( $self, $str ) = @_;
    $str = defined($str) ? "$str" : '';
    my $sticky = $self->_is_sticky;
    my $global = index( $self->flags, 'g' ) >= 0;

    if ($sticky) {
      my $qr_a = $self->_qr_anchored;
      my $start = $self->lastIndex;
      pos($str) = $start;
      if ( $str =~ /$qr_a/g ) {
        $self->lastIndex( pos($str) );
        return !!1;
      }
      $self->lastIndex(0);
      return !!0;
    }
    if ($global) {
      my $qr = $self->_qr;
      my $start = $self->lastIndex;
      pos($str) = $start;
      if ( $str =~ /$qr/g ) {
        $self->lastIndex( pos($str) );
        return !!1;
      }
      $self->lastIndex(0);
      return !!0;
    }
    return ( $str =~ $self->_qr ) ? !!1 : !!0;
  }

  # RegExp.prototype.exec -- same g/y semantics as test. Returns an Array of
  # [full match, cap1, cap2, ...] (JS renders as 'a,b,c' via toString; that
  # is what `{{ r/(.)(.).exec('ab') }}` wants). On no-match returns null
  # (undef, which the engine renders as empty). The Perl qr// match in list
  # context returns only the capture groups; we prepend $& (the full match)
  # so the array matches RegExp.prototype.exec's shape.
  #
  # k48: when the pattern has no capture groups, Perl 5.40's list-context
  # match returns the boolean match result (builtin::true / builtin::false)
  # instead of an empty list. JS never does that. _captures_count == 0
  # means drop the boolean from @captures before assembling the result.
  #
  # Implementation note: pos() is only honoured as a START position by
  # m//g matches (perldoc perlop). So a plain list-context `$str =~ $qr`
  # silently ignores pos() and always re-finds the first match from offset
  # 0, breaking global/sticky iteration. Compounded: list-context
  # `$str =~ /$qr/g` iterates ALL matches and returns ALL captures (perldoc
  # perlop), not the captures from one anchored match. Two failure modes
  # need two different probes:
  #
  # * Sticky (y): the prebuilt _qr_anchored pattern starts with \G, which
  #   only matches at pos(). A non-/g list-context match against that
  #   pattern is therefore pos-anchored; on success it returns the captures
  #   from the one match starting at pos, with no skip-ahead. New lastIndex
  #   is start + length of full match.
  # * Global (g, no y): we cannot use a \G-anchored pattern (global skips
  #   forward to the next match, sticky does not). Run the qr in scalar
  #   /g context (which DOES honour pos as start AND advances it past the
  #   found match, skipping non-matches); then substring the matched
  #   region and run a fresh non-/g list-context match on it to grab the
  #   captures. The slice is short (one match's width) so the cost is
  #   bounded.
  #
  # CAVEAT (same as test above): Regex overloads "" to render /source/flags,
  # so `$self->_qr` interpolates as a string. Cache in a local first.
  sub exec {
    my ( $self, $str ) = @_;
    $str = defined($str) ? "$str" : '';
    my $sticky = $self->_is_sticky;
    my $global = index( $self->flags, 'g' ) >= 0;
    my $no_caps = $self->_captures_count == 0;

    if ($sticky) {
      my $qr_a  = $self->_qr_anchored;
      my $start = $self->lastIndex;
      pos($str) = $start;
      my @captures = $str =~ $qr_a;   # non-/g; \G anchors at pos
      if (@captures) {
        @captures = () if $no_caps;   # k48: drop the bool for no-groups patterns
        $self->lastIndex( $start + length($&) );
        return [ $&, @captures ];
      }
      $self->lastIndex(0);
      return undef;
    }
    if ($global) {
      my $qr     = $self->_qr;
      my $start  = $self->lastIndex;
      pos($str)  = $start;
      if ( $str =~ /$qr/g ) {         # scalar /g: honours pos, advances it
        my $full = $&;
        my $end  = pos($str);
        # Slice the matched region; non-/g list-context match returns
        # exactly the captures from this one match.
        my @captures = substr( $str, $start, $end - $start ) =~ $qr;
        @captures = () if $no_caps;   # k48: drop the bool for no-groups patterns
        $self->lastIndex($end);
        return [ $full, @captures ];
      }
      $self->lastIndex(0);
      return undef;
    }
    my @captures = $str =~ $self->_qr;
    return undef unless @captures;
    @captures = () if $no_caps;       # k48: drop the bool for no-groups patterns
    return [ $&, @captures ];
  }

  # k48: the capture groups of a JS regex body, in source order: one entry per
  # group, its name for a named group, undef for a numbered one (the count is
  # the array's size). ECMAScript regex syntax:
  # `(` starts a group; `(?:` / `(?=` / `(?!` / `(?<=` / `(?<!` / `(?#` are
  # non-capturing / zero-width / comment forms; `(?<NAME>` is a NAMED
  # capture group (counts); everything else is a numbered capture group.
  # Backslash escapes any following byte; `[...]` is a character class
  # where parens are literals. Walk the body byte-by-byte (the JS body is
  # ASCII for every pattern in the corpus; UTF-8 non-ASCII literals would
  # still walk correctly because substr/skip is over bytes, not codepoints).
  sub _capture_groups {
    my ( $self, $body ) = @_;
    my @groups;
    my $i        = 0;
    my $len      = length $body;
    my $in_class = 0;
    while ( $i < $len ) {
      my $c = substr( $body, $i, 1 );
      if ( $c eq '\\' ) {                                # escape: skip 2 bytes
        $i += 2;
        next;
      }
      if ($in_class) {                                   # inside [...] -- parens literal
        $in_class = 0 if $c eq ']';
        $i++;
        next;
      }
      if ( $c eq '[' ) {
        $in_class = 1;
        $i++;
        next;
      }
      if ( $c eq '(' && $i + 1 < $len && substr( $body, $i + 1, 1 ) eq '?' ) {
        my $after = $i + 2 < $len ? substr( $body, $i + 2, 1 ) : '';
        if ( $after eq ':' || $after eq '=' || $after eq '!' || $after eq '#' ) {
          # (?:  (?=  (?!  (?# -- non-capturing / zero-width / comment
        }
        elsif ( $after eq '<' ) {
          my $after_lt = $i + 3 < $len ? substr( $body, $i + 3, 1 ) : '';
          if ( $after_lt ne '=' && $after_lt ne '!' ) {
            # (?<NAME> -- named capture; the name runs to the next '>' (the
            # pattern already compiled, so there is one)
            my $gt = index( $body, '>', $i + 3 );
            push @groups, substr( $body, $i + 3, $gt - ( $i + 3 ) );
          }
          # (?<= / (?<! -- lookbehind, non-capturing
        }
        else {
          push @groups, undef;       # (?xyz -- invalid ECMAScript; count defensively
        }
      }
      elsif ( $c eq '(' ) {
        push @groups, undef;         # plain ( ... ) -- numbered capture
      }
      $i++;
    }
    return \@groups;
  }

  # Stringification: `/source/flags` -- matches RegExp.prototype.toString so
  # `{{ r/x/i }}` renders the right thing (oracle proves it: rendering
  # `{{ r/name [0-9] \\// }}` produces `/name [0-9] \\//`).
  sub _stringify {
    my ($self) = @_;
    return '/' . $self->source . '/' . $self->flags;
  }

  sub to_string { return '/' . $_[0]->source . '/' . $_[0]->flags }

  sub _runtime { 'Text::Nunjucks::Runtime' }
  sub _lib     { 'Text::Nunjucks::Lib' }

  # RegExp.prototype[Symbol.replace](string, replaceValue) -- what
  # String.prototype.replace runs for a regex pattern, so the replace filter's
  # regex branch (str.replace(old, new_)) lands here (ADR 0013). A coderef
  # replaceValue is called once per match with (matched, captures..., position,
  # string[, groups]) and its result goes through ToString; anything else goes
  # through ToString and then GetSubstitution (Lib js_get_substitution: $&,
  # $1..$99, $<name>, $`, $', $$). The g / y state follows RegExpBuiltinExec: g
  # resets lastIndex to 0 and replaces every match, an empty match stepping
  # lastIndex one on; y matches only at lastIndex; a regex with neither replaces
  # the first match from 0 and leaves lastIndex alone. Oracle: 'aaa' with
  # r/a*/g -> '--', 'ab' with r/x*|a/g -> '-a-b-' (Perl's own s///g gives
  # '--b-'), 'aab' with r/a/y -> '-ab' and with r/a/gy -> '--b'.
  # Matching and lastIndex reckon in code points, as test / exec do (k53); the
  # position GetSubstitution and a replacer see is counted in code units (ADR
  # 0012); the pieces are joined through js_string_append.
  sub symbol_replace {
    my ( $self, $string, $replace_value ) = @_;
    my $rt  = $self->_runtime;
    my $lib = $self->_lib;

    my $s          = $rt->_js_to_string($string);
    my $functional = $lib->is_function($replace_value);
    $replace_value = $rt->_js_to_string($replace_value) unless $functional;
    my $global = index( $self->flags, 'g' ) >= 0;
    $self->lastIndex(0) if $global;

    my @results;
    while ( my $result = $self->_regexp_exec($s) ) {
      push @results, $result;
      last unless $global;
      # AdvanceStringIndex past an empty match
      $self->lastIndex( $self->lastIndex + 1 ) if $result->{matched} eq '';
    }

    my $accumulated_result   = '';
    my $next_source_position = 0;
    # the code-unit position of each match, counted on from the previous one
    my ( $chars, $units ) = ( 0, 0 );
    for my $result (@results) {
      my $position = $result->{index};
      $units += $lib->js_string_length( substr( $s, $chars, $position - $chars ) );
      $chars = $position;
      my $replacement = $functional
        ? $rt->_js_to_string(
            $replace_value->(
              $result->{matched}, @{ $result->{captures} }, $units, $s,
              defined( $result->{named} ) ? $result->{named} : (),
            ) )
        : $lib->js_get_substitution( $result->{matched}, $s, $units, $result->{captures},
            $result->{named}, $replace_value );
      if ( $position >= $next_source_position ) {
        $lib->js_string_append( $accumulated_result,
          substr( $s, $next_source_position, $position - $next_source_position ) );
        $lib->js_string_append( $accumulated_result, $replacement );
        $next_source_position = $position + length( $result->{matched} );
      }
    }
    return $accumulated_result if $next_source_position >= length($s);
    $lib->js_string_append( $accumulated_result, substr( $s, $next_source_position ) );
    return $accumulated_result;
  }

  # RegExpBuiltinExec for symbol_replace: the next match under the g / y state as
  # { matched, index (a character offset), captures (undef for a group that did
  # not take part), named (the groups object, or undef if the regex has no named
  # group) }, or nothing. The groups object is engine-built, so it is an ordered
  # dict (ADR 0011) with every group name in group order (_group_names), undef
  # for a group that did not take part. lastIndex is read and moved only for a g
  # or y regex; a failed match resets it to 0.
  sub _regexp_exec {
    my ( $self, $s ) = @_;
    my $sticky     = $self->_is_sticky;
    my $stateful   = $sticky || index( $self->flags, 'g' ) >= 0;
    my $last_index = $stateful ? $self->lastIndex : 0;
    if ( $last_index > length($s) ) {
      $self->lastIndex(0) if $stateful;
      return;
    }
    # CAVEAT (see the test method): the qr must sit in a lexical before interpolation
    my $qr = $sticky ? $self->_qr_anchored : $self->_qr;
    pos($s) = $last_index;
    if ( !( $s =~ /$qr/g ) ) {
      $self->lastIndex(0) if $stateful;
      return;
    }
    # every group of the pattern ($#+), not @{^CAPTURE}: that one stops at the
    # last group that took part (oracle: 'ab' with r/(a)|(z)/ and '[$1|$2]'
    # gives '[a|]', $2 being a group that exists)
    my %result = (
      matched  => substr( $s, $-[0], $+[0] - $-[0] ),
      index    => $-[0],
      captures => [ map { defined( $-[$_] ) ? substr( $s, $-[$_], $+[$_] - $-[$_] ) : undef } 1 .. $#+ ],
      named    => @{ $self->_group_names }
        ? $self->_runtime->make_dict( map { $_ => $+{$_} } @{ $self->_group_names } )
        : undef,
    );
    $self->lastIndex( $+[0] ) if $stateful;
    return \%result;
  }
}

#### SafeString -- src/runtime.js function SafeString (a String subclass)

package Text::Nunjucks::Runtime::SafeString {
  # JS: `function SafeString(val){ if (typeof val!=='string') return val; ... }`
  # and prototype valueOf/toString both return this.val. Marks a string as not
  # to be autoescaped. Overloads stringification to val so the compiler's output
  # concatenation coerces it exactly as JS's `+ ''` does.
  use overload
    '""'   => sub { $_[0]->{val} },
    'bool' => sub { 1 },
    fallback => 1;
  use Text::Nunjucks::Lib;

  sub new {
    my ( $class, $val ) = @_;
    # if (typeof val !== 'string') return val;  -- non-strings pass through
    return $val unless Text::Nunjucks::Lib->is_string($val);
    # this.length = val.length -- in UTF-16 code units (ADR 0012)
    return bless { val => $val, length => Text::Nunjucks::Lib->js_string_length($val) }, $class;
  }

  sub val       { $_[0]->{val} }
  sub length    { $_[0]->{length} }
  sub value_of  { $_[0]->{val} }    # SafeString.prototype.valueOf
  sub to_string { $_[0]->{val} }    # SafeString.prototype.toString
}

#### Frame -- src/runtime.js class Frame

package Text::Nunjucks::Runtime::Frame {
  use Moo;
  use namespace::autoclean;

  # constructor(parent, isolateWrites): variables is a bare bag (JS
  # Object.create(null)); topLevel starts false and the compiler/environment
  # flip it to true on the root frame, so it is rw.
  has variables      => ( is => 'ro', default => sub { {} } );
  has parent         => ( is => 'ro' );
  has top_level      => ( is => 'rw', default => sub { 0 } );
  has isolate_writes => ( is => 'ro' );

  around BUILDARGS => sub {
    my ( $orig, $class, @args ) = @_;
    return $class->$orig(@args) if @args == 1 && ref $args[0] eq 'HASH';
    my ( $parent, $isolate_writes ) = @args;
    return $class->$orig( parent => $parent, isolate_writes => $isolate_writes );
  };

  sub set {
    my ( $self, $name, $val, $resolve_up ) = @_;

    # Allow variables with dots by automatically creating the nested structure.
    my @parts = split /\./, $name, -1;    # JS split('.') keeps trailing empties
    my $obj   = $self->variables;
    my $frame = $self;

    if ($resolve_up) {
      if ( $frame = $self->resolve( $parts[0], 1 ) ) {
        $frame->set( $name, $val );
        return;
      }
    }

    for my $i ( 0 .. $#parts - 1 ) {
      my $id = $parts[$i];
      # JS: if (!obj[id]) obj[id] = {};  -- JS falsiness (null/None too), not Perl's
      if ( Text::Nunjucks::Runtime->_falsy( $obj->{$id} ) ) {
        $obj->{$id} = {};
      }
      $obj = $obj->{$id};
    }

    $obj->{ $parts[-1] } = $val;
  }

  sub get {
    my ( $self, $name ) = @_;
    my $val = $self->variables->{$name};
    return $val if defined $val;                  # val !== undefined
    return Text::Nunjucks::Runtime->None;         # JS: return null
  }

  sub lookup {
    my ( $self, $name ) = @_;
    my $p   = $self->parent;
    my $val = $self->variables->{$name};
    return $val if defined $val;                  # val !== undefined
    return $p && $p->lookup($name);              # p && p.lookup(name)
  }

  sub resolve {
    my ( $self, $name, $for_write ) = @_;
    my $p = ( $for_write && $self->isolate_writes ) ? undef : $self->parent;
    my $val = $self->variables->{$name};
    return $self if defined $val;                 # val !== undefined
    return $p && $p->resolve($name);
  }

  sub push {
    my ( $self, $isolate_writes ) = @_;
    return ref($self)->new( $self, $isolate_writes );
  }

  sub pop {
    my ($self) = @_;
    return $self->parent;
  }
}

package Text::Nunjucks::Runtime;

# JS special doubles, reused by the operators and division/mod guards.
my $POS_INF = 9**9**9;
my $NEG_INF = -$POS_INF;
my $NAN     = $POS_INF - $POS_INF;

#### resolvers -- the runtime "exports" that name a class once (getty-perl-core)

sub None       { return Text::Nunjucks::Runtime::None->instance }
sub Frame      { 'Text::Nunjucks::Runtime::Frame' }
sub SafeString { 'Text::Nunjucks::Runtime::SafeString' }
sub KwArgs     { 'Text::Nunjucks::Runtime::KwArgs' }
sub Regex      { 'Text::Nunjucks::Runtime::Regex' }

sub _error_class          { 'Text::Nunjucks::Lib::Error' }
sub _template_error_class { 'Text::Nunjucks::Lib::TemplateError' }

#### sentinel predicates

sub _is_none        { my ( $self, $v ) = @_; ( blessed($v) && $v->isa('Text::Nunjucks::Runtime::None') )       ? 1 : 0 }
sub _is_safe_string { my ( $self, $v ) = @_; ( blessed($v) && $v->isa('Text::Nunjucks::Runtime::SafeString') ) ? 1 : 0 }
sub _is_kwargs      { my ( $self, $v ) = @_; ( blessed($v) && $v->isa('Text::Nunjucks::Runtime::KwArgs') )     ? 1 : 0 }
sub _is_regex       { my ( $self, $v ) = @_; ( blessed($v) && $v->isa('Text::Nunjucks::Runtime::Regex') )      ? 1 : 0 }

#### makeMacro

sub make_macro {
  my ( $self, $arg_names, $kwarg_names, $func ) = @_;

  return sub {
    my @macro_args = @_;
    my $arg_count  = $self->num_args( \@macro_args );
    my @args;
    my $kwargs = $self->get_keyword_args( \@macro_args );

    if ( $arg_count > scalar @$arg_names ) {
      @args = @macro_args[ 0 .. $#$arg_names ];

      # Positional arguments that should be passed in as keyword arguments
      # (essentially default values).
      my @overflow = @macro_args[ scalar(@args) .. $arg_count - 1 ];
      for my $i ( 0 .. $#overflow ) {
        if ( $i < scalar @$kwarg_names ) {
          $kwargs->{ $kwarg_names->[$i] } = $overflow[$i];
        }
      }
      push @args, $kwargs;
    } elsif ( $arg_count < scalar @$arg_names ) {
      @args = $arg_count > 0 ? @macro_args[ 0 .. $arg_count - 1 ] : ();

      for ( my $i = $arg_count; $i < scalar @$arg_names; $i++ ) {
        my $arg = $arg_names->[$i];

        # Keyword arguments the caller passed by the name of a positional arg.
        push @args, $kwargs->{$arg};
        delete $kwargs->{$arg};
      }
      push @args, $kwargs;
    } else {
      @args = @macro_args;
    }

    return $func->(@args);
  };
}

#### makeKeywordArgs

sub make_keyword_args {
  my ( $self, $obj ) = @_;
  bless $obj, $self->KwArgs;    # JS: obj.__keywords = true
  return $obj;
}

#### makeDict -- ordered object for template dict literals (ADR 0011)
#
# Port addition (no upstream counterpart): the compiler (k15) emits
# $runtime->make_dict(k1, v1, ...) for every template `{...}` literal so that
# JS insertion order survives (a plain Perl hash does not preserve it). The
# representation is Hash::Ordered; member_lookup / keys / in_operator below read
# it. NOTE: this wires only what the compiler's own dicts need; the rest of
# ADR 0011 (sorted plain caller hashes, dump/dictsort/list/items) is still open.
sub make_dict {
  my ( $self, @kv ) = @_;
  return Hash::Ordered->new(@kv);
}

#### makeRegex -- compile a template regex literal into a Regex object (ADR 0013)
#
# JS RegExp flags (https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/RegExp):
#   g  -- global (stateful, lastIndex; tracked on the Regex object, NOT a qr// flag)
#   i  -- case-insensitive
#   m  -- ^/$ match per line
#   s  -- . matches newlines
#   u  -- Unicode mode (in JS: \u{...} escapes, surrogate-pair merging)
#   y  -- sticky (stateful match at lastIndex; not portable to a stateless qr//)
# JS RegExp is constructed in upstream parser.js:1043 as `new RegExp(body, flags)`
# and then read through `memberLookup`. JS's RegExp.prototype.toString yields
# `/body/flags`, which is what `{{ r/x/i }}` renders (oracle: '{{ r/x/gi }}'
# -> '/x/gi').
#
# ADR 0013 home is here (k43): one seam that owns pattern translation and the
# Regex object. ADR 0005 says engine-internal regexes use explicit ECMAScript
# character-class sets; for user-facing regex literals the path of least
# surprise today is to compile the JS body verbatim under Perl's /a flag
# (ASCII-only `\d`/`\s`/`\w`, matching JS defaults), and croak loudly when
# the body does not compile (the "fail loud" rule).
sub make_regex {
  my ( $self, $source, $flags ) = @_;
  $flags //= '';

  # Validate every flag -- an unrecognised JS flag is a typo we should not
  # silently absorb.
  my %known = map { $_ => 1 } qw( g i m s u y );
  for my $f ( split //, $flags ) {
    croak __PACKAGE__ . '->make_regex: unsupported JS flag ' . $f
      unless $known{$f};
  }

  # Map JS flags onto a Perl inline modifier group. g and y do not become
  # qr// flags -- global state is carried on the Regex object itself
  # (source/flags/global/test/exec), and a sticky match (y) is out of scope
  # for a stateless qr// (k43 grow-on-demand: a corpus case for /y would
  # motivate lastIndex tracking).
  my $perl_mods = '';
  $perl_mods .= 'i' if index( $flags, 'i' ) >= 0;
  $perl_mods .= 'm' if index( $flags, 'm' ) >= 0;
  $perl_mods .= 's' if index( $flags, 's' ) >= 0;
  # JS `u` (unicode mode): no Perl analogue is exactly right; JS `\d`/`\s`/`\w`
  # are ASCII-only by default, so /a (ASCII-restricted) is the closest 1:1.
  # A future corpus case with non-ASCII JS `\p{...}` will motivate either a
  # tailored translator or a documented divergence (k43 ADR-grown).
  $perl_mods .= 'a' if index( $flags, 'u' ) >= 0;

  my $qr;
  {
    local $@;
    my $compiled = eval { qr/(?$perl_mods:$source)/ };
    croak __PACKAGE__ . '->make_regex: cannot compile pattern '
      . $source . ': ' . ( $@ // 'unknown error' )
      unless defined $compiled;
    $qr = $compiled;
  }

  # k46: the sticky qr// is the same pattern with a leading \G. ADR 0013 maps
  # JS /y to a pos-anchored Perl match (the only portable 1:1).
  my $qr_anchored;
  {
    local $@;
    my $compiled = eval { qr/(?$perl_mods:\G(?:$source))/ };
    croak __PACKAGE__ . '->make_regex: cannot compile sticky pattern '
      . $source . ': ' . ( $@ // 'unknown error' )
      unless defined $compiled;
    $qr_anchored = $compiled;
  }

  my $groups = $self->Regex->_capture_groups($source);
  my %seen;
  return $self->Regex->new(
    source          => $source,
    flags           => $flags,
    _qr             => $qr,
    _qr_anchored    => $qr_anchored,
    _captures_count => scalar @$groups,
    _group_names    => [ grep { defined($_) && !$seen{$_}++ } @$groups ],
  );
}

sub _is_ordered_hash {
  my ( $self, $v ) = @_;
  return ( blessed($v) && $v->isa('Hash::Ordered') ) ? 1 : 0;
}

#### isKeywordArgs

sub is_keyword_args {
  my ( $self, $obj ) = @_;
  return $self->_is_kwargs($obj);
}

#### getKeywordArgs

sub get_keyword_args {
  my ( $self, $args ) = @_;
  my $len = scalar @$args;
  if ($len) {
    my $last_arg = $args->[ $len - 1 ];
    return $last_arg if $self->is_keyword_args($last_arg);
  }
  return {};
}

#### numArgs

sub num_args {
  my ( $self, $args ) = @_;
  my $len = scalar @$args;
  return 0 if $len == 0;

  my $last_arg = $args->[ $len - 1 ];
  return $self->is_keyword_args($last_arg) ? $len - 1 : $len;
}

#### copySafeness

sub copy_safeness {
  my ( $self, $dest, $target ) = @_;
  return $self->SafeString->new($target) if $self->_is_safe_string($dest);
  return $self->_js_to_string($target);           # target.toString()
}

#### markSafe

sub mark_safe {
  my ( $self, $val ) = @_;

  if ( Text::Nunjucks::Lib->is_string($val) ) {
    return $self->SafeString->new($val);
  } elsif ( !Text::Nunjucks::Lib->is_function($val) ) {
    return $val;
  } else {
    return sub {
      my $ret = $val->(@_);        # val.apply(this, arguments) -- no `this` (ADR 0009)
      return $self->SafeString->new($ret) if Text::Nunjucks::Lib->is_string($ret);
      return $ret;
    };
  }
}

#### suppressValue

sub suppress_value {
  my ( $self, $val, $autoescape ) = @_;

  # JS: val = (val !== undefined && val !== null) ? val : '';
  $val = '' if !defined($val) || $self->_is_none($val);

  if ( $autoescape && !$self->_is_safe_string($val) ) {
    $val = Text::Nunjucks::Lib->escape( $self->_js_to_string($val) );
  }

  return $val;
}

#### ensureDefined

sub ensure_defined {
  my ( $self, $val, $lineno, $colno ) = @_;
  if ( !defined($val) || $self->_is_none($val) ) {
    die $self->_template_error_class->new(
      'attempted to output null or undefined value',
      $lineno + 1,
      $colno + 1
    );
  }
  return $val;
}

#### memberLookup
#
# Upstream is a raw `obj[val]` (any property/method reachable, functions come
# back as a closure bound to the owner). Perl scalars/arrays have no such
# members, so ADR 0008 makes this a curated, in-place emulated String / Array /
# Number surface -- grown on demand, each entry oracle-verified. String
# indexing, .length and the string methods reckon in UTF-16 code units through
# the Lib seams of ADR 0012; ToNumber / ToString of their arguments stay here.
#
# ADR 0016 split: this function is the PROPERTY-ACCESS seam
# (`member_lookup($obj, $key)` returns the value the template would see at
# `{{ obj.key }}`); the METHOD-CALL seam `member_lookup_method` returns a bound
# coderef for `{{ obj.key() }}`. The compiler picks at the AST site
# (compile_lookup_val vs compile_fun_call -> the latter on a LookupVal name).

my %STRING_METHODS = (
  # JS case mapping (Final_Sigma, ß -> SS, lone surrogates unchanged) is the
  # one Lib seam the lower / upper / capitalize filters use as well
  toUpperCase => sub { my ( $self, $s ) = @_; Text::Nunjucks::Lib->js_to_upper_case($s) },
  toLowerCase => sub { my ( $self, $s ) = @_; Text::Nunjucks::Lib->js_to_lower_case($s) },
  trim => sub {
    my ( $self, $s ) = @_;
    my $ws = Text::Nunjucks::Lib->js_whitespace_class;    # ADR 0005 seam
    $s =~ s/\A(?:$ws)+//;
    $s =~ s/(?:$ws)+\z//;
    return $s;
  },
  replace => sub {
    # string-pattern replace of the FIRST occurrence (regex patterns and $&/$1
    # special replacement strings ride on the k7 regex decision -- not here).
    my ( $self, $s, $pattern, $repl ) = @_;
    $pattern = $self->_js_to_string($pattern);
    $repl    = $self->_js_to_string($repl);
    my $idx = Text::Nunjucks::Lib->js_string_index_of( $s, $pattern );
    return $s if $idx < 0;
    # preceding + replacement + following, joined in code units (ADR 0012)
    my $out = Text::Nunjucks::Lib->js_substring( $s, 0, $idx );
    Text::Nunjucks::Lib->js_string_append( $out, $repl );
    Text::Nunjucks::Lib->js_string_append( $out,
      Text::Nunjucks::Lib->js_substring( $s, $idx + Text::Nunjucks::Lib->js_string_length($pattern) ) );
    return $out;
  },
  slice => sub {
    my ( $self, $s, $start, $end ) = @_;
    return Text::Nunjucks::Lib->js_string_slice( $s,
      $self->_to_number_or_undef($start), $self->_to_number_or_undef($end) );
  },
  substring => sub {
    my ( $self, $s, $start, $end ) = @_;
    return Text::Nunjucks::Lib->js_substring( $s,
      $self->_to_number_or_undef($start), $self->_to_number_or_undef($end) );
  },
  substr => sub {
    my ( $self, $s, $start, $length ) = @_;
    return Text::Nunjucks::Lib->js_substr( $s,
      $self->_to_number_or_undef($start), $self->_to_number_or_undef($length) );
  },
  split => sub {
    my ( $self, $s, $sep, $limit ) = @_;
    # ToString(separator) unless undefined (split() -> [whole string]); a null
    # separator is the string 'null'
    return Text::Nunjucks::Lib->js_split( $s,
      defined($sep) ? $self->_js_to_string($sep) : undef, $self->_to_number_or_undef($limit) );
  },
  indexOf => sub {
    my ( $self, $s, $search, $from ) = @_;
    return Text::Nunjucks::Lib->js_string_index_of( $s,
      $self->_js_to_string($search), $self->_to_number_or_undef($from) );
  },
  lastIndexOf => sub {
    my ( $self, $s, $search, $from ) = @_;
    return Text::Nunjucks::Lib->js_string_last_index_of( $s,
      $self->_js_to_string($search), $self->_to_number_or_undef($from) );
  },
  charAt => sub {
    my ( $self, $s, $i ) = @_;
    return Text::Nunjucks::Lib->js_char_at( $s, $self->_to_number_or_undef($i) );
  },
  concat => sub {
    my ( $self, $s, @args ) = @_;
    Text::Nunjucks::Lib->js_string_append( $s, $self->_js_to_string($_) ) for @args;    # ADR 0012
    return $s;
  },
);

my %ARRAY_METHODS = (
  join => sub {
    my ( $self, $arr, $sep ) = @_;
    $sep = defined($sep) ? $self->_js_to_string($sep) : ',';
    return $self->_array_join( $arr, $sep );
  },
  indexOf => sub {
    my ( $self, $arr, $search, $from ) = @_;
    return Text::Nunjucks::Lib->index_of( $arr, $search, $from );
  },
  lastIndexOf => sub {
    # Array.prototype.lastIndexOf(searchElement[, fromIndex]): strict equality,
    # scanning back from fromIndex -- length - 1 when absent, counted from the
    # end when negative. Oracle: [1,2,1].lastIndexOf(1) 2, (1, 1) 0, (1, -1) 2,
    # (1, -2) 0, (1, -9) -1, (1, 9) 2, (1, 'x') 0. The truncate filter reaches
    # it on an array input (input.lastIndexOf(' ', length)).
    my ( $self, $arr, $search, @from ) = @_;
    my $len = scalar @$arr;
    return -1 if $len == 0;
    my $n = @from ? Text::Nunjucks::Lib->_js_to_integer_or_infinity( $self->_to_number( $from[0] ) ) : $len - 1;
    return -1 if $n == $NEG_INF;
    my $k = $n >= 0 ? ( $n < $len - 1 ? $n : $len - 1 ) : $len + $n;
    for ( my $i = $k; $i >= 0; $i-- ) {
      return $i if Text::Nunjucks::Lib->_strict_eq( $arr->[$i], $search );
    }
    return -1;
  },
  slice => sub {
    my ( $self, $arr, $start, $end ) = @_;
    my $len = scalar @$arr;
    ( $start, $end ) = $self->_slice_bounds( $len, $start, $end );
    return [] if $start >= $end;
    return [ @{$arr}[ $start .. $end - 1 ] ];
  },
  concat => sub {
    my ( $self, $arr, @args ) = @_;
    my @new = @$arr;
    for my $a (@args) {
      if ( Text::Nunjucks::Lib->is_array($a) ) { push @new, @$a }
      else                                     { push @new, $a }
    }
    return \@new;
  },
  # mutators -- change the underlying Perl structure in place (ADR 0008)
  push => sub {
    my ( $self, $arr, @args ) = @_;
    push @$arr, @args;
    return scalar @$arr;             # Array.push returns the new length
  },
  pop => sub {
    my ( $self, $arr ) = @_;
    return undef unless @$arr;       # JS pop() on [] -> undefined
    return pop @$arr;
  },
  shift => sub {
    my ( $self, $arr ) = @_;
    return undef unless @$arr;
    return shift @$arr;
  },
  unshift => sub {
    my ( $self, $arr, @args ) = @_;
    unshift @$arr, @args;
    return scalar @$arr;
  },
  sort => sub {
    # JS Array.sort() with no comparator sorts by the String form of elements,
    # in UTF-16 code-unit order (ADR 0012).
    my ( $self, $arr ) = @_;
    @$arr = sort {
      Text::Nunjucks::Lib->js_string_compare( $self->_js_to_string($a), $self->_js_to_string($b) )
    } @$arr;
    return $arr;
  },
  reverse => sub {
    my ( $self, $arr ) = @_;
    @$arr = reverse @$arr;
    return $arr;
  },
);

my %NUMBER_METHODS = (
  toFixed => sub {
    my ( $self, $n, $digits ) = @_;
    $digits = defined($digits) ? int( $self->_to_number($digits) ) : 0;
    return sprintf( '%.*f', $digits, $n );
  },
);

sub member_lookup {
  my ( $self, $obj, $val ) = @_;

  # if (obj === undefined || obj === null) return undefined;
  return undef if !defined($obj) || $self->_is_none($obj);

  # SafeString extends String in JS: member access works off its value.
  my $str_target = $self->_is_safe_string($obj) ? $obj->val : undef;

  my $key = $self->_member_key($val);           # JS ToString of the lookup key

  # Regex surface (ADR 0013): source / flags / global / lastIndex are property
  # reads, not method calls. `test` and `exec` are method-shaped and go through
  # member_lookup_method (FunCall path). lastIndex is template-visible
  # ({{ r.lastIndex }}) and reflects the JS RegExp match position; it advances
  # after a g/y match and resets to 0 on no-match.
  if ( $self->_is_regex($obj) ) {
    return $obj->source    if $key eq 'source';
    return $obj->flags     if $key eq 'flags';
    return $obj->global    if $key eq 'global';
    return $obj->lastIndex if $key eq 'lastIndex';
    return undef;
  }

  # Array surface
  if ( Text::Nunjucks::Lib->is_array($obj) ) {
    if ( $self->_is_index_key($key) ) {
      my $i = 0 + $key;
      return undef if $i >= scalar @$obj;
      return $obj->[$i];
    }
    return scalar @$obj if $key eq 'length';
    if ( $ARRAY_METHODS{$key} ) {                 # ADR 0016: method on FunCall seam
      return sub { $ARRAY_METHODS{$key}->( $self, $obj, @_ ) };
    }
    return undef;
  }

  # String surface (plain string or SafeString value)
  if ( defined($str_target) || Text::Nunjucks::Lib->is_string($obj) ) {
    my $s = defined($str_target) ? $str_target : $obj;
    # A primitive string has JS exotic index access (s[0]); a SafeString is a
    # String OBJECT -- length + methods but NO index access (oracle: on a
    # SafeString `s[0]` and `s['0']` render ''). So gate indexing to plain
    # strings only, never $str_target (the SafeString case).
    # Index and length count UTF-16 code units (ADR 0012): s[i] past an astral
    # character lands one further, and inside one yields a lone surrogate. One
    # charAt call measures the string once; its '' (a code unit is never empty)
    # is the index past the end, where s[i] is undefined.
    if ( !defined($str_target) && $self->_is_index_key($key) ) {
      my $unit = Text::Nunjucks::Lib->js_char_at( $s, 0 + $key );
      return $unit eq '' ? undef : $unit;
    }
    return Text::Nunjucks::Lib->js_string_length($s) if $key eq 'length';
    if ( $STRING_METHODS{$key} ) {               # ADR 0016: method on FunCall seam
      return sub { $STRING_METHODS{$key}->( $self, $s, @_ ) };
    }
    return undef;
  }

  # Number surface
  if ( created_as_number($obj) ) {
    if ( $NUMBER_METHODS{$key} ) {
      return sub { $NUMBER_METHODS{$key}->( $self, $obj, @_ ) };
    }
    return undef;
  }

  # Ordered hash (template dict literal / engine-built object, ADR 0011): read
  # it like a plain object before the generic blessed-object branch below.
  if ( $self->_is_ordered_hash($obj) ) {
    return $obj->exists($key) ? $obj->get($key) : undef;
  }

  # Plain hashref: property access (a coderef value is returned as-is and
  # called with no `this` per ADR 0009).
  if ( ref($obj) eq 'HASH' ) {
    return exists( $obj->{$key} ) ? $obj->{$key} : undef;
  }

  # Blessed user object (ADR 0016: this seam returns the VALUE -- an accessor
  # call or a Moo attribute read -- not a bound coderef. The coderef comes from
  # member_lookup_method, which the compiler emits at FunCall sites).
  if ( blessed($obj) ) {
    return $obj->$key if $obj->can($key);
    return undef;
  }

  return undef;
}

# ADR 0016: the second half of the split. Where member_lookup returns the value
# of a property, member_lookup_method returns a bound coderef for the method at
# $key, ready to be passed to call_wrap. The two branches land on different
# emitted symbols in the compiled Perl; FunCall -> member_lookup_method, every
# other property read -> member_lookup.
sub member_lookup_method {
  my ( $self, $obj, $val ) = @_;

  return undef if !defined($obj) || $self->_is_none($obj);

  my $key = $self->_member_key($val);

  # Regex: test/exec are method-shaped; source/flags/global are properties
  # (FunCall would be `{{ r.test("...") }} }`).
  if ( $self->_is_regex($obj) ) {
    return sub { $obj->test(@_) } if $key eq 'test';
    return sub { $obj->exec(@_) } if $key eq 'exec';
    return undef;
  }

  # String surface -- emulated methods come back bound to the string value.
  if ( Text::Nunjucks::Lib->is_string($obj) || $self->_is_safe_string($obj) ) {
    my $s = $self->_is_safe_string($obj) ? $obj->val : $obj;
    return sub { $STRING_METHODS{$key}->( $self, $s, @_ ) } if $STRING_METHODS{$key};
    return undef;
  }

  # Array surface
  if ( Text::Nunjucks::Lib->is_array($obj) ) {
    return sub { $ARRAY_METHODS{$key}->( $self, $obj, @_ ) } if $ARRAY_METHODS{$key};
    return undef;
  }

  # Number surface
  if ( created_as_number($obj) ) {
    return sub { $NUMBER_METHODS{$key}->( $self, $obj, @_ ) } if $NUMBER_METHODS{$key};
    return undef;
  }

  # Hashref (plain or ordered): the FunCall site must produce a coderef, so
  # we only return one if the value is callable. Upstream: calling a
  # non-function member on a plain object is a TypeError ("not a function")
  # -- we mirror that by returning undef and letting call_wrap produce the
  # exact upstream text.
  if ( ref($obj) eq 'HASH' || $self->_is_ordered_hash($obj) ) {
    # a Hash::Ordered is a blessed array, never dereferenced as a hash
    my $fn = $self->_is_ordered_hash($obj)
      ? ( $obj->exists($key) ? $obj->get($key) : undef )
      : ( exists( $obj->{$key} ) ? $obj->{$key} : undef );
    return Text::Nunjucks::Lib->is_function($fn) ? $fn : undef;
  }

  # Blessed user object: `{{ obj.foo() }} }` needs a bound coderef.
  if ( blessed($obj) ) {
    return sub { $obj->$key(@_) } if $obj->can($key);
    return undef;
  }

  return undef;
}

# Port addition, ADR 0016 / ADR 0010: a native method call the engine's own
# JavaScript makes on a value it never checked -- filters.js runs
# str.toLowerCase(), str.split('\n'), input.lastIndexOf(' ', length) on whatever
# the template piped in. JS reads the member and calls it: on undefined / null
# the read throws, on a value without that method the call does, both as a
# TypeError whose text V8 builds from the source expression, so the caller
# names the upstream variable ($src). Oracle: 5|lower -> "TypeError:
# str.toLowerCase is not a function", undefined|trim -> "TypeError: Cannot read
# properties of undefined (reading 'replace')".
sub js_method_call {
  my ( $self, $obj, $src, $name, @args ) = @_;
  my $method = $self->member_lookup_method( $obj, $name );
  die $self->_js_method_error( $obj, $src, $name ) unless Text::Nunjucks::Lib->is_function($method);
  return $method->(@args);
}

# Port addition, same seam: the string a String.prototype method the engine
# calls with one of its own regexes (str.replace(/\r\n|\n/g, ...),
# str.match(/\w+/g)) works on -- the value itself, a SafeString's value (a
# String object), else the TypeError js_method_call throws for the member
# ($name) upstream calls.
sub js_string_this {
  my ( $self, $obj, $src, $name ) = @_;
  return $obj->val if $self->_is_safe_string($obj);
  return $obj      if Text::Nunjucks::Lib->is_string($obj);
  die $self->_js_method_error( $obj, $src, $name );
}

sub _js_method_error {
  my ( $self, $obj, $src, $name ) = @_;
  my $message = ( !defined($obj) || $self->_is_none($obj) )
    ? 'Cannot read properties of ' . $self->_js_type($obj) . " (reading '" . $name . "')"
    : $src . '.' . $name . ' is not a function';
  return $self->_error_class->new( $message, name => 'TypeError' );
}

#### callWrap

sub call_wrap {
  my ( $self, $obj, $name, $context, $args ) = @_;

  if ( $self->_falsy($obj) ) {                     # JS: if (!obj)
    die $self->_error_class->new(
      'Unable to call `' . $name . '`, which is undefined or falsey' );
  } elsif ( !Text::Nunjucks::Lib->is_function($obj) ) {    # typeof obj !== 'function'
    die $self->_error_class->new(
      'Unable to call `' . $name . '`, which is not a function' );
  }

  # JS: obj.apply(context, args). The compiler binds member-call owners inside
  # member_lookup; a bare context coderef gets no `this` (ADR 0009), so the
  # Context passed as $context is not used as an invocant here.
  return $obj->( @$args );
}

#### contextOrFrameLookup

sub context_or_frame_lookup {
  my ( $self, $context, $frame, $name ) = @_;
  my $val = $frame->lookup($name);
  return defined($val) ? $val : $context->lookup($name);    # val !== undefined
}

#### handleError

sub handle_error {
  my ( $self, $error, $lineno, $colno ) = @_;
  # JS: if (error.lineno) return error; -- an already-positioned TemplateError.
  if ( blessed($error) && $error->can('lineno') && $error->lineno ) {
    return $error;
  }
  return $self->_template_error_class->new( $error, $lineno, $colno );
}

#### asyncEach

sub async_each {
  my ( $self, $arr, $dimen, $iter, $cb ) = @_;

  if ( Text::Nunjucks::Lib->is_array($arr) ) {
    my $len = scalar @$arr;

    Text::Nunjucks::Lib->async_iter(
      $arr,
      sub {
        my ( $item, $i, $next ) = @_;
        if ( $dimen == 1 ) {
          $iter->( $item, $i, $len, $next );
        } elsif ( $dimen == 2 ) {
          $iter->( $item->[0], $item->[1], $i, $len, $next );
        } elsif ( $dimen == 3 ) {
          $iter->( $item->[0], $item->[1], $item->[2], $i, $len, $next );
        } else {
          push @$item, $i, $len, $next;
          $iter->(@$item);
        }
      },
      $cb
    );
  } else {
    # JS lib.asyncFor does keys(arr || {}); that guard must recognise None (JS
    # null), whose home is Runtime (ADR 0006), so normalise the falsy iterable
    # here before delegating to Lib (which is None-agnostic by design).
    Text::Nunjucks::Lib->async_for(
      $self->_falsy($arr) ? {} : $arr,
      sub {
        my ( $key, $val, $i, $len, $next ) = @_;
        $iter->( $key, $val, $i, $len, $next );
      },
      $cb
    );
  }
}

#### asyncAll

sub async_all {
  my ( $self, $arr, $dimen, $func, $cb ) = @_;

  my $finished = 0;
  my $len;
  my @output_arr;

  my $done = sub {
    my ( $i, $output ) = @_;
    $finished++;
    $output_arr[$i] = $output;

    if ( $finished == $len ) {
      # outputArr.join(''), joined in code units (ADR 0012)
      my $joined = '';
      Text::Nunjucks::Lib->js_string_append( $joined, defined($_) ? $_ : '' ) for @output_arr;
      $cb->( undef, $joined );
    }
  };

  if ( Text::Nunjucks::Lib->is_array($arr) ) {
    $len = scalar @$arr;

    if ( $len == 0 ) {
      $cb->( undef, '' );
    } else {
      for ( my $i = 0; $i < scalar @$arr; $i++ ) {
        my $item = $arr->[$i];
        if ( $dimen == 1 ) {
          $func->( $item, $i, $len, $done );
        } elsif ( $dimen == 2 ) {
          $func->( $item->[0], $item->[1], $i, $len, $done );
        } elsif ( $dimen == 3 ) {
          $func->( $item->[0], $item->[1], $item->[2], $i, $len, $done );
        } else {
          push @$item, $i, $len, $done;
          $func->(@$item);
        }
      }
    }
  } else {
    # JS keys(arr || {}) -- JS-falsiness, None-aware (ADR 0006), not just `// {}`
    # (which would let a None through and crash Lib->keys on the deref).
    my $keys = Text::Nunjucks::Lib->keys( $self->_falsy($arr) ? {} : $arr );
    $len = scalar @$keys;

    if ( $len == 0 ) {
      $cb->( undef, '' );
    } else {
      # JS: func(k, arr[k], i, len, done) -- property access. The same lookup
      # seam the runtime uses for member access (member_lookup) handles
      # Hash::Ordered (template dict literal / engine-built object, ADR 0011)
      # and plain hashrefs, matching arr[k] on a JS plain object; calling it
      # here keeps Runtime::async_all on one seam instead of duplicating the
      # Hash::Ordered branch that Lib::async_for already has.
      for ( my $i = 0; $i < scalar @$keys; $i++ ) {
        my $k = $keys->[$i];
        $func->( $k, $self->member_lookup( $arr, $k ), $i, $len, $done );
      }
    }
  }
}

#### fromIterator

sub from_iterator {
  my ( $self, $arr ) = @_;
  # JS returns arr unless it is a non-null, non-array object with Symbol.iterator
  # (then Array.from). Perl core has no iterator protocol, so the conversion
  # branch is inert and every value passes through unchanged; a future blessed
  # iterable would hook in here.
  return $arr if !defined($arr) || !ref($arr) || $self->_is_none($arr);
  return $arr if Text::Nunjucks::Lib->is_array($arr);
  return $arr;
}

#### re-exported lib helpers (module.exports: isArray, keys, inOperator)

sub is_array   { my ( $self, $obj ) = @_; Text::Nunjucks::Lib->is_array($obj) }
sub keys       { my ( $self, $obj ) = @_; Text::Nunjucks::Lib->keys($obj) }
sub in_operator {
  my ( $self, $key, $val ) = @_;
  return Text::Nunjucks::Lib->in_operator( $key, $val );
}

#### string seams the compiled code calls (ADR 0012) -- port additions

# The output buffer: every `buffer += value` the compiler emits is this call, so
# two halves of a pair written one after the other come out as the one astral
# character, as they do in JS's buffer. The buffer is passed on aliased ($_[1]
# after the shift), so Lib appends to the template's variable in place.
sub js_string_append { shift; Text::Nunjucks::Lib->js_string_append(@_) }

# The single-name {% for %} reads arr.length once and arr[i] per element. On a
# primitive string both are code-unit operations that measure the whole string,
# so per element they would make the loop O(n^2); the loop indexes the string's
# split('') array instead -- the same length and the same arr[i] for every i, as
# a string cannot change under the loop. Anything else passes through, a
# SafeString included (a String object: its arr[i] is undefined, not a unit).
sub _for_code_units {
  my ( $self, $arr ) = @_;
  return Text::Nunjucks::Lib->is_string($arr) ? Text::Nunjucks::Lib->js_split( $arr, '' ) : $arr;
}

#### ------------------------------------------------------------------------
#### JS value model: ToNumber / ToPrimitive / ToString, truthiness (ADR 0007,
#### 0006, 0001). Port additions -- Perl's native operators lack JS semantics.
#### ------------------------------------------------------------------------

sub _dbl { return unpack( 'd', pack( 'd', $_[1] ) ) }   # force to an IEEE double

# JS typeof-ish classifier over the value kinds the port models.
sub _js_type {
  my ( $self, $v ) = @_;
  return 'undefined' if !defined($v);
  return 'null'      if $self->_is_none($v);
  return 'boolean'   if is_bool($v);
  return 'number'    if created_as_number($v);
  return 'string'    if !ref($v);
  return 'object';                        # array / hash / SafeString / blessed
}

# JS truthiness. null (a ref) is falsy, so it is handled before delegating the
# kind-based part to Lib->_falsy (which keeps '0' and empty refs truthy).
sub _falsy {
  my ( $self, $v ) = @_;
  return 1 if $self->_is_none($v);
  return Text::Nunjucks::Lib->_falsy($v);
}

sub _truthy {
  my ( $self, $v ) = @_;
  return $self->_falsy($v) ? 0 : 1;
}

# ECMAScript ToString. null -> "null", undefined -> "undefined" (Array.join and
# suppress_value remap those to '' themselves). Container stringification lives
# here (js-semantics: "mechanism in Runtime") and is order-independent, so it
# does not touch the open k3 object-key-order decision.
sub _js_to_string {
  my ( $self, $v ) = @_;
  return 'undefined' if !defined($v);
  return 'null'      if $self->_is_none($v);
  return ( $v ? 'true' : 'false' ) if is_bool($v);
  return Text::Nunjucks::Lib->number_to_string($v) if created_as_number($v);
  return $v unless ref($v);                                   # string
  return $v->val if $self->_is_safe_string($v);              # SafeString -> value
  return $self->_array_join( $v, ',' ) if ref($v) eq 'ARRAY';# Array.toString => join(',')
  return "$v" if $self->_is_regex($v);                       # Regex.toString -> /source/flags
  return '[object Object]';    # object / other ref (overloaded objects: k8)
}

# Array.prototype.join: null/undefined elements become '' (not "null"); the
# pieces are joined in code units (ADR 0012), so split('').join('') restores
# a string whose astral characters split() cut into halves.
sub _array_join {
  my ( $self, $arr, $sep ) = @_;
  my $out = '';
  for my $i ( 0 .. $#$arr ) {
    my $v = $arr->[$i];
    Text::Nunjucks::Lib->js_string_append( $out, $sep ) if $i > 0;
    Text::Nunjucks::Lib->js_string_append( $out,
      ( !defined($v) || $self->_is_none($v) ) ? '' : $self->_js_to_string($v) );
  }
  return $out;
}

sub _to_primitive {
  my ( $self, $v ) = @_;
  return $v if !defined($v) || $self->_is_none($v) || !ref($v);   # already primitive
  return $v->val if $self->_is_safe_string($v);
  return $self->_js_to_string($v);                                # array/object -> ToString
}

# ECMAScript Number(string): trim JS whitespace, '' -> 0, Infinity spellings,
# 0x/0o/0b radixes, else a valid decimal literal or NaN.
sub _string_to_number {
  my ( $self, $s ) = @_;
  my $ws = Text::Nunjucks::Lib->js_whitespace_class;
  ( my $t = $s ) =~ s/\A(?:$ws)+//;
  $t =~ s/(?:$ws)+\z//;

  return 0 if $t eq '';
  return $POS_INF if $t eq 'Infinity' || $t eq '+Infinity';
  return $NEG_INF if $t eq '-Infinity';
  if ( $t =~ /\A0[xX][0-9a-fA-F]+\z/
    || $t =~ /\A0[oO][0-7]+\z/
    || $t =~ /\A0[bB][01]+\z/ )
  {
    return oct($t) + 0.0;
  }
  if ( $t =~ /\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/ ) {
    return 0 + $t;
  }
  return $NAN;
}

# ECMAScript ToNumber, always returning a real IEEE double so the operators run
# in JS double arithmetic (Perl would otherwise keep exact 64-bit integers).
sub _to_number {
  my ( $self, $v ) = @_;
  my $n;
  if    ( !defined($v) )         { $n = $NAN }                       # undefined -> NaN
  elsif ( $self->_is_none($v) )  { $n = 0 }                          # null -> 0
  elsif ( is_bool($v) )          { $n = $v ? 1 : 0 }
  elsif ( created_as_number($v) ){ $n = $v }
  elsif ( $self->_is_safe_string($v) ) { $n = $self->_string_to_number( $v->val ) }
  elsif ( !ref($v) )             { $n = $self->_string_to_number($v) }
  else                           { $n = $self->_to_number( $self->_to_primitive($v) ) }
  return $self->_dbl($n);
}

#### JS operators the compiler emits (compiler.js compileAdd/Sub/.../Compare)

sub op_add {
  my ( $self, $a, $b ) = @_;
  my $pa = $self->_to_primitive($a);
  my $pb = $self->_to_primitive($b);
  # JS +: string concat if either primitive is a string, else numeric add.
  if ( Text::Nunjucks::Lib->is_string($pa) || Text::Nunjucks::Lib->is_string($pb) ) {
    my $s = $self->_js_to_string($pa);
    Text::Nunjucks::Lib->js_string_append( $s, $self->_js_to_string($pb) );    # ADR 0012
    return $s;
  }
  return $self->_dbl( $self->_to_number($pa) + $self->_to_number($pb) );
}

# `~` operator -- compiler emits `a + "" + b`, i.e. String(a) . String(b),
# joined in code units (ADR 0012).
sub op_concat {
  my ( $self, $a, $b ) = @_;
  my $s = $self->_js_to_string($a);
  Text::Nunjucks::Lib->js_string_append( $s, $self->_js_to_string($b) );
  return $s;
}

sub op_sub { my ( $self, $a, $b ) = @_; $self->_dbl( $self->_to_number($a) - $self->_to_number($b) ) }

sub op_mul {
  my ( $self, $a, $b ) = @_;
  my $na = $self->_to_number($a);
  my $nb = $self->_to_number($b);
  my $r  = $na * $nb;
  # IEEE keeps a zero product's sign as sign(a) xor sign(b) (so 0 * -1 == -0),
  # but Perl collapses it to +0; a later `1 / (0 * -1)` then needs the -0 (F3).
  # Restore the sign via copysign when the product is zero.
  $r = POSIX::copysign( 0, POSIX::copysign( 1, $na ) * POSIX::copysign( 1, $nb ) )
    if $r == 0;
  return $self->_dbl($r);
}

sub op_div {
  my ( $self, $a, $b ) = @_;
  my $na = $self->_to_number($a);
  my $nb = $self->_to_number($b);
  return $NAN if $na != $na || $nb != $nb;
  if ( $nb == 0 ) {
    return $NAN if $na == 0;    # 0 / 0 (any signs) -> NaN
    # x / +-0 -> +-Infinity with sign = sign(x) xor sign(0); copysign reads the
    # -0 divisor too, so 1/-0 -> -Infinity and -1/-0 -> Infinity (F3).
    my $sign = POSIX::copysign( 1, $na ) * POSIX::copysign( 1, $nb );
    return $sign < 0 ? $NEG_INF : $POS_INF;
  }
  return $self->_dbl( $na / $nb );
}

sub op_mod {
  my ( $self, $a, $b ) = @_;
  my $na = $self->_to_number($a);
  my $nb = $self->_to_number($b);
  return $NAN if $na != $na || $nb != $nb || $nb == 0;    # JS n % 0 -> NaN
  return $self->_dbl( POSIX::fmod( $na, $nb ) );          # JS % keeps sign of dividend
}

sub op_pow {
  my ( $self, $a, $b ) = @_;
  return $self->_dbl( $self->_to_number($a) ** $self->_to_number($b) );   # Math.pow
}

sub op_floordiv {
  my ( $self, $a, $b ) = @_;
  my $na = $self->_to_number($a);
  my $nb = $self->_to_number($b);
  my $q;
  if ( $nb == 0 ) {
    return $NAN if $na != $na || $na == 0;
    $q = ( $na < 0 ) ? $NEG_INF : $POS_INF;
  } else {
    $q = $na / $nb;
  }
  return $q if $q != $q;                             # NaN
  return $q if $q == $POS_INF || $q == $NEG_INF;     # Math.floor(+-Infinity)
  return $self->_dbl( POSIX::floor($q) );            # Math.floor(a / b)
}

sub op_neg { my ( $self, $a ) = @_; $self->_dbl( -$self->_to_number($a) ) }
sub op_pos { my ( $self, $a ) = @_; $self->_dbl( $self->_to_number($a) ) }

# and / or return the operand (not a boolean); not returns a boolean.
sub op_or  { my ( $self, $a, $b ) = @_; $self->_falsy($a) ? $b : $a }
sub op_and { my ( $self, $a, $b ) = @_; $self->_falsy($a) ? $a : $b }
sub op_not { my ( $self, $a )     = @_; $self->_falsy($a) ? true : false }

sub op_eq  { my ( $self, $a, $b ) = @_; $self->_loose_eq( $a, $b )              ? true : false }
sub op_ne  { my ( $self, $a, $b ) = @_; $self->_loose_eq( $a, $b )              ? false : true }
sub op_seq { my ( $self, $a, $b ) = @_; Text::Nunjucks::Lib->_strict_eq( $a, $b ) ? true : false }
sub op_sne { my ( $self, $a, $b ) = @_; Text::Nunjucks::Lib->_strict_eq( $a, $b ) ? false : true }

sub op_lt { my ( $self, $a, $b ) = @_; my $r = $self->_less_than( $a, $b ); ( defined($r) && $r )  ? true : false }
sub op_gt { my ( $self, $a, $b ) = @_; my $r = $self->_less_than( $b, $a ); ( defined($r) && $r )  ? true : false }
sub op_le { my ( $self, $a, $b ) = @_; my $r = $self->_less_than( $b, $a ); ( defined($r) && !$r ) ? true : false }
sub op_ge { my ( $self, $a, $b ) = @_; my $r = $self->_less_than( $a, $b ); ( defined($r) && !$r ) ? true : false }

# ECMAScript Abstract Equality (==).
sub _loose_eq {
  my ( $self, $a, $b ) = @_;
  my $ta = $self->_js_type($a);
  my $tb = $self->_js_type($b);

  return Text::Nunjucks::Lib->_strict_eq( $a, $b ) ? 1 : 0 if $ta eq $tb;

  return 1
    if ( $ta eq 'null' && $tb eq 'undefined' )
    || ( $ta eq 'undefined' && $tb eq 'null' );
  return 0
    if $ta eq 'null' || $ta eq 'undefined' || $tb eq 'null' || $tb eq 'undefined';

  return $self->_loose_eq( $self->_to_number($a), $b ) if $ta eq 'boolean';
  return $self->_loose_eq( $a, $self->_to_number($b) ) if $tb eq 'boolean';

  return $self->_loose_eq( $a, $self->_to_number($b) ) if $ta eq 'number' && $tb eq 'string';
  return $self->_loose_eq( $self->_to_number($a), $b ) if $ta eq 'string' && $tb eq 'number';

  return $self->_loose_eq( $self->_to_primitive($a), $b )
    if $ta eq 'object' && ( $tb eq 'number' || $tb eq 'string' );
  return $self->_loose_eq( $a, $self->_to_primitive($b) )
    if $tb eq 'object' && ( $ta eq 'number' || $ta eq 'string' );

  return 0;
}

# ECMAScript Abstract Relational Comparison; returns 1, 0, or undef (a NaN
# operand, which every comparison operator turns into false).
sub _less_than {
  my ( $self, $x, $y ) = @_;
  my $px = $self->_to_primitive($x);
  my $py = $self->_to_primitive($y);

  if ( $self->_js_type($px) eq 'string' && $self->_js_type($py) eq 'string' ) {
    return Text::Nunjucks::Lib->js_string_compare( $px, $py ) < 0 ? 1 : 0;   # code units (ADR 0012)
  }

  my $nx = $self->_to_number($px);
  my $ny = $self->_to_number($py);
  return undef if $nx != $nx || $ny != $ny;    # NaN
  return ( $nx < $ny ) ? 1 : 0;
}

#### helpers for the emulated member surface

# JS uses ToInteger on slice bounds; this clamps like Array slice (negatives
# count from the end). Strings slice through the Lib seams (ADR 0012).
sub _slice_bounds {
  my ( $self, $len, $start, $end ) = @_;
  $start = defined($start) ? int( $self->_to_number($start) ) : 0;
  $end   = defined($end)   ? int( $self->_to_number($end) )   : $len;
  $start = $start < 0 ? ( $len + $start > 0 ? $len + $start : 0 ) : ( $start > $len ? $len : $start );
  $end   = $end < 0   ? ( $len + $end > 0   ? $len + $end   : 0 ) : ( $end > $len   ? $len : $end );
  return ( $start, $end );
}

# ToNumber of an optional numeric method argument, keeping JS `undefined` as
# undef: the Lib string seams (ADR 0012) give undefined its per-parameter
# meaning (slice's end -> length, lastIndexOf's position -> +Infinity, ...).
sub _to_number_or_undef {
  my ( $self, $v ) = @_;
  return defined($v) ? $self->_to_number($v) : undef;
}

# The JS string key that `obj[val]` uses to look a member up.
sub _member_key {
  my ( $self, $val ) = @_;
  return 'undefined' if !defined($val);
  return 'null'      if $self->_is_none($val);
  return ( $val ? 'true' : 'false' )                if is_bool($val);
  return Text::Nunjucks::Lib->number_to_string($val) if created_as_number($val);
  return $val unless ref($val);
  return $self->_js_to_string($val);
}

sub _is_index_key {
  my ( $self, $key ) = @_;
  return ( $key =~ /\A(?:0|[1-9][0-9]*)\z/ ) ? 1 : 0;
}

1;

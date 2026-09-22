package Text::Nunjucks::Runtime;
# ABSTRACT: 1:1 port of Nunjucks src/runtime.js -- frames, macros, member lookup

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
    return bless { val => $val, length => CORE::length($val) }, $class;
  }

  # length is a live property in JS; code-points here, ADR 0012 requires UTF-16
  # code units -- retrofitted in k17 (filters)
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

sub _error_class          { 'Text::Nunjucks::Lib::Error' }
sub _template_error_class { 'Text::Nunjucks::Lib::TemplateError' }

#### sentinel predicates

sub _is_none        { my ( $self, $v ) = @_; ( blessed($v) && $v->isa('Text::Nunjucks::Runtime::None') )       ? 1 : 0 }
sub _is_safe_string { my ( $self, $v ) = @_; ( blessed($v) && $v->isa('Text::Nunjucks::Runtime::SafeString') ) ? 1 : 0 }
sub _is_kwargs      { my ( $self, $v ) = @_; ( blessed($v) && $v->isa('Text::Nunjucks::Runtime::KwArgs') )     ? 1 : 0 }

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
# indexing / .length / slice / charAt / split('')/ reverse here use Perl
# code-points; ADR 0012 requires UTF-16 code units -- retrofitted in k17
# (filters), when the js-utf16 seams and all their consumers land in one pass.

my %STRING_METHODS = (
  toUpperCase => sub { my ( $self, $s ) = @_; uc $s },
  toLowerCase => sub { my ( $self, $s ) = @_; lc $s },
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
    my $idx = index( $s, $pattern );
    return $s if $idx < 0;
    return substr( $s, 0, $idx ) . $repl . substr( $s, $idx + length($pattern) );
  },
  slice => sub {
    my ( $self, $s, $start, $end ) = @_;
    my $len = length $s;
    ( $start, $end ) = $self->_slice_bounds( $len, $start, $end );
    return '' if $start >= $end;
    return substr( $s, $start, $end - $start );
  },
  substring => sub {
    my ( $self, $s, $start, $end ) = @_;
    my $len = length $s;
    $start = defined($start) ? int( $self->_to_number($start) ) : 0;
    $end   = defined($end)   ? int( $self->_to_number($end) )   : $len;
    $start = 0    if $start < 0;
    $start = $len if $start > $len;
    $end   = 0    if $end < 0;
    $end   = $len if $end > $len;
    ( $start, $end ) = ( $end, $start ) if $start > $end;
    return substr( $s, $start, $end - $start );
  },
  split => sub {
    my ( $self, $s, $sep, $limit ) = @_;
    return [$s] unless defined $sep;             # split() -> [whole string]
    $sep = $self->_js_to_string($sep);
    my @parts = $sep eq '' ? ( split //, $s ) : ( split /\Q$sep\E/, $s, -1 );
    if ( defined $limit ) {
      my $l = int( $self->_to_number($limit) );
      @parts = @parts[ 0 .. $l - 1 ] if $l >= 0 && $l < scalar @parts;
    }
    return \@parts;
  },
  indexOf => sub {
    my ( $self, $s, $search, $from ) = @_;
    $search = $self->_js_to_string($search);
    return defined($from)
      ? index( $s, $search, int( $self->_to_number($from) ) )
      : index( $s, $search );
  },
  charAt => sub {
    my ( $self, $s, $i ) = @_;
    $i = defined($i) ? int( $self->_to_number($i) ) : 0;
    return '' if $i < 0 || $i >= length($s);
    return substr( $s, $i, 1 );
  },
  concat => sub {
    my ( $self, $s, @args ) = @_;
    return $s . join( '', map { $self->_js_to_string($_) } @args );
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
    # JS Array.sort() with no comparator sorts by the String form of elements.
    my ( $self, $arr ) = @_;
    @$arr = sort { $self->_js_to_string($a) cmp $self->_js_to_string($b) } @$arr;
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

  # Array surface
  if ( Text::Nunjucks::Lib->is_array($obj) ) {
    if ( $self->_is_index_key($key) ) {
      my $i = 0 + $key;
      return undef if $i >= scalar @$obj;
      return $obj->[$i];
    }
    return scalar @$obj if $key eq 'length';
    if ( my $m = $ARRAY_METHODS{$key} ) {
      return sub { $m->( $self, $obj, @_ ) };
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
    if ( !defined($str_target) && $self->_is_index_key($key) ) {
      my $i = 0 + $key;
      return undef if $i >= length($s);
      return substr( $s, $i, 1 );
    }
    return length($s) if $key eq 'length';
    if ( my $m = $STRING_METHODS{$key} ) {
      return sub { $m->( $self, $s, @_ ) };
    }
    return undef;
  }

  # Number surface
  if ( created_as_number($obj) ) {
    if ( my $m = $NUMBER_METHODS{$key} ) {
      return sub { $m->( $self, $obj, @_ ) };
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

  # Blessed user object: a member call binds the owner ($obj->method), ADR 0009.
  if ( blessed($obj) ) {
    return sub { $obj->$key(@_) } if $obj->can($key);
    return undef;
  }

  return undef;
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
      $cb->( undef, join( '', map { defined($_) ? $_ : '' } @output_arr ) );
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
      for ( my $i = 0; $i < scalar @$keys; $i++ ) {
        my $k = $keys->[$i];
        $func->( $k, $arr->{$k}, $i, $len, $done );
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
  return '[object Object]';    # object / other ref (overloaded objects: k8)
}

# Array.prototype.join: null/undefined elements become '' (not "null").
sub _array_join {
  my ( $self, $arr, $sep ) = @_;
  return join( $sep,
    map { ( !defined($_) || $self->_is_none($_) ) ? '' : $self->_js_to_string($_) }
    @$arr );
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
    return $self->_js_to_string($pa) . $self->_js_to_string($pb);
  }
  return $self->_dbl( $self->_to_number($pa) + $self->_to_number($pb) );
}

# `~` operator -- compiler emits `a + "" + b`, i.e. String(a) . String(b).
sub op_concat {
  my ( $self, $a, $b ) = @_;
  return $self->_js_to_string($a) . $self->_js_to_string($b);
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
    return ( $px lt $py ) ? 1 : 0;      # code-point compare; ADR 0012 (UTF-16) retrofit in k17
  }

  my $nx = $self->_to_number($px);
  my $ny = $self->_to_number($py);
  return undef if $nx != $nx || $ny != $ny;    # NaN
  return ( $nx < $ny ) ? 1 : 0;
}

#### helpers for the emulated member surface

# JS uses ToInteger on slice/substring bounds; this clamps like Array/String
# slice (negatives count from the end).
sub _slice_bounds {
  my ( $self, $len, $start, $end ) = @_;
  $start = defined($start) ? int( $self->_to_number($start) ) : 0;
  $end   = defined($end)   ? int( $self->_to_number($end) )   : $len;
  $start = $start < 0 ? ( $len + $start > 0 ? $len + $start : 0 ) : ( $start > $len ? $len : $start );
  $end   = $end < 0   ? ( $len + $end > 0   ? $len + $end   : 0 ) : ( $end > $len   ? $len : $end );
  return ( $start, $end );
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

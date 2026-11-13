package Text::Nunjucks::Filters;
# ABSTRACT: 1:1 port of Nunjucks src/filters.js -- the built-in filters

our $VERSION = '0.001';

use strict;
use warnings;
use builtin qw( is_bool );
use Text::Nunjucks::Lib;
use Text::Nunjucks::Runtime;

no warnings 'experimental::builtin';

# filters.js is a bag of `exports.<name> = fn` filter functions. The port keeps
# upstream's order and names (snake_case); each filter is a class method
# dispatched through $self, like Lib and Runtime, so a filter that calls another
# one (title -> capitalize, striptags -> trim) goes through the invocant, and a
# filter named like a Perl builtin (truncate here; join, length, reverse, sort,
# int, ... later) never resolves to the builtin. A filter receives what the
# template passed (ADR 0009): the value, the arguments, keyword arguments as a
# trailing KwArgs hashref.
#
# `exports($env)` builds the { name => coderef } bag that Environment.init
# registers with add_filter, once per Environment. No filter ported so far reads
# `this`, so exports takes $env and ignores it: every closure captures only the
# class name. Upstream calls a filter with `this` set to the render Context; the
# filters reading `this.env` (groupby, sort, select / reject -- job 5) will take
# their Environment from the closure exports builds. That closure must hold a
# weakened copy of $env: the Environment holds the bag, so Environment -> filters
# -> closure -> Environment is a reference cycle otherwise. A filter not ported
# yet is absent from the bag, so it is "filter not found" like any unknown name.
#
# JS operators go through Runtime (ADR 0001 / 0006 / 0007); a native method
# upstream calls on a value it never checked goes through Runtime
# js_method_call / js_string_this, which throw V8's TypeError (ADR 0010);
# lengths, positions and joins go through the Lib UTF-16 seams (ADR 0012); the
# engine's own regexes use the explicit ECMAScript classes of ADR 0005.

sub _lib     { 'Text::Nunjucks::Lib' }
sub _runtime { 'Text::Nunjucks::Runtime' }

#### normalize

sub normalize {
  my ( $self, $value, $default_value ) = @_;
  if ( !defined($value) || $self->_runtime->_is_none($value) || ( is_bool($value) && !$value ) ) {
    return $default_value;
  }
  return $value;
}

#### capitalize

sub capitalize {
  my ( $self, $str ) = @_;
  my $rt = $self->_runtime;
  $str = $self->normalize( $str, '' );
  my $ret = $rt->js_method_call( $str, 'str', 'toLowerCase' );
  return $rt->copy_safeness(
    $str,
    $rt->op_add(
      $rt->js_method_call( $rt->js_method_call( $ret, 'ret', 'charAt', 0 ), 'ret.charAt(...)', 'toUpperCase' ),
      $rt->js_method_call( $ret, 'ret', 'slice', 1 )
    )
  );
}

#### center

sub center {
  my ( $self, $str, $width ) = @_;
  my $rt = $self->_runtime;
  $str   = $self->normalize( $str, '' );
  $width = $rt->op_or( $width, 80 );

  if ( $rt->op_ge( $rt->member_lookup( $str, 'length' ), $width ) ) {
    return $str;
  }

  my $spaces = $rt->op_sub( $width, $rt->member_lookup( $str, 'length' ) );
  my $pre    = $self->_lib->repeat( ' ', $rt->op_sub( $rt->op_div( $spaces, 2 ), $rt->op_mod( $spaces, 2 ) ) );
  my $post   = $self->_lib->repeat( ' ', $rt->op_div( $spaces, 2 ) );
  return $rt->copy_safeness( $str, $rt->op_add( $rt->op_add( $pre, $str ), $post ) );
}

#### indent

sub indent {
  my ( $self, $str, $width, $indentfirst ) = @_;
  my $rt = $self->_runtime;
  $str = $self->normalize( $str, '' );

  if ( $rt->op_seq( $str, '' ) ) {
    return '';
  }

  $width = $rt->op_or( $width, 4 );
  # let res = '';
  my $lines = $rt->js_method_call( $str, 'str', 'split', "\n" );
  # lib.repeat counts `i < width`, a numeric compare: ToNumber here, as Lib's
  # repeat takes a number (oracle: indent('3') is 3 spaces, indent('2x') none)
  my $sp = $self->_lib->repeat( ' ', $rt->_to_number($width) );

  my $res = $rt->_array_join(
    $self->_lib->map(
      $lines,
      sub {
        my ( $l, $i ) = @_;
        return ( $i == 0 && $rt->_falsy($indentfirst) ) ? $l : $rt->op_concat( $sp, $l );    # `${sp}${l}`
      }
    ),
    "\n"
  );

  return $rt->copy_safeness( $str, $res );
}

#### lower

sub lower {
  my ( $self, $str ) = @_;
  $str = $self->normalize( $str, '' );
  return $self->_runtime->js_method_call( $str, 'str', 'toLowerCase' );
}

#### nl2br

sub nl2br {
  my ( $self, $str ) = @_;
  my $rt = $self->_runtime;
  if ( !defined($str) || $rt->_is_none($str) ) {
    return '';
  }
  return $rt->copy_safeness( $str, $rt->js_string_this( $str, 'str', 'replace' ) =~ s/\r\n|\n/<br \/>\n/gr );
}

#### replace

sub replace {
  my ( $self, $str, $old, $new_, $max_count ) = @_;
  my $rt           = $self->_runtime;
  my $original_str = $str;

  if ( $rt->_is_regex($old) ) {
    # str.replace(old, new_): RegExp.prototype[Symbol.replace] (ADR 0013)
    return $old->symbol_replace( $rt->js_string_this( $str, 'str', 'replace' ), $new_ );
  }

  if ( !defined($max_count) ) {    # typeof maxCount === 'undefined'
    $max_count = -1;
  }

  my $res = '';    # Output

  # Cast Numbers in the search term to string
  if ( $rt->_js_type($old) eq 'number' ) {
    $old = $rt->op_add( '', $old );
  } elsif ( $rt->_js_type($old) ne 'string' ) {
    # If it is something other than number or string,
    # return the original string
    return $str;
  }

  # Cast numbers in the replacement to string
  if ( $rt->_js_type($str) eq 'number' ) {
    $str = $rt->op_add( '', $str );
  }

  # If by now, we don't have a string, throw it back
  if ( $rt->_js_type($str) ne 'string' && !$rt->_is_safe_string($str) ) {
    return $str;
  }

  # ShortCircuits
  if ( $old eq '' ) {
    # Mimic the python behaviour: empty string is replaced
    # by replacement e.g. "abc"|replace("", ".") -> .a.b.c.
    $res = $rt->op_add(
      $rt->op_add( $new_, $rt->js_method_call( $rt->js_method_call( $str, 'str', 'split', '' ), 'str.split(...)', 'join', $new_ ) ),
      $new_ );
    return $rt->copy_safeness( $str, $res );
  }

  my $next_index = $rt->js_method_call( $str, 'str', 'indexOf', $old );
  # if # of replacements to perform is 0, or the string to does
  # not contain the old value, return the string
  if ( $rt->op_seq( $max_count, 0 ) || $rt->op_seq( $next_index, -1 ) ) {
    return $str;
  }

  my $pos   = 0;
  my $count = 0;    # # of replacements made

  while ( $next_index > -1 && ( $rt->op_seq( $max_count, -1 ) || $rt->op_lt( $count, $max_count ) ) ) {
    # Grab the next chunk of src string and add it with the
    # replacement, to the result (res is a string: `res +=` appends in place)
    $self->_lib->js_string_append( $res,
      $rt->op_add( $rt->js_method_call( $str, 'str', 'substring', $pos, $next_index ), $new_ ) );
    # Increment our pointer in the src string
    $pos = $next_index + $rt->member_lookup( $old, 'length' );
    $count++;
    # See if there are any more replacements to be made
    $next_index = $rt->js_method_call( $str, 'str', 'indexOf', $old, $pos );
  }

  # We've either reached the end, or done the max # of
  # replacements, tack on any remaining string
  if ( $pos < $rt->member_lookup( $str, 'length' ) ) {
    $self->_lib->js_string_append( $res, $rt->js_method_call( $str, 'str', 'substring', $pos ) );
  }

  return $rt->copy_safeness( $original_str, $res );
}

#### striptags

sub striptags {
  my ( $self, $input, $preserve_linebreaks ) = @_;
  my $rt  = $self->_runtime;
  my $lib = $self->_lib;
  $input = $self->normalize( $input, '' );
  # /<\/?([a-z][a-z0-9]*)\b[^>]*>|<!--[\s\S]*?-->/gi -- without the u flag, i
  # folds no non-ASCII letter onto a-z (oracle: K U+212A and s-long U+017F are
  # not tag letters), and \b is the ASCII word boundary of js_word_class
  my $w    = $lib->js_word_class;
  my $tags = qr/<\/?([A-Za-z][A-Za-z0-9]*)(?:(?<=$w)(?!$w)|(?<!$w)(?=$w))[^>]*>|<!--(?s:.)*?-->/;
  # cutting a tag out can bring a lone high and a lone low surrogate together:
  # re-pair them (ADR 0012)
  my $trimmed_input =
    $self->trim( $lib->_js_from_units( $rt->js_string_this( $input, 'input', 'replace' ) =~ s/$tags//gr ) );
  my $res = '';
  if ( $rt->_truthy($preserve_linebreaks) ) {
    # /^ +| +$/gm: under m, ^ and $ also match next to any JS LineTerminator
    # (\n \r U+2028 U+2029), not only \n as Perl's /m does
    $res = $trimmed_input
      =~ s/(?<![^\n\r\x{2028}\x{2029}]) +| +(?![^\n\r\x{2028}\x{2029}])//gr    # remove leading and trailing spaces
      =~ s/ +/ /gr                                                          # squash adjacent spaces
      =~ s/(\r\n)/\n/gr                                                     # normalize linebreaks (CRLF -> LF)
      =~ s/\n\n\n+/\n\n/gr;                                                 # squash abnormal adjacent linebreaks
  } else {
    my $ws = $lib->js_whitespace_class;
    $res = $trimmed_input =~ s/(?:$ws)+/ /gr;
  }
  return $rt->copy_safeness( $input, $res );
}

#### title

sub title {
  my ( $self, $str ) = @_;
  my $rt = $self->_runtime;
  $str = $self->normalize( $str, '' );
  my $words = $self->_lib->map( $rt->js_method_call( $str, 'str', 'split', ' ' ), sub { $self->capitalize( $_[0] ) } );
  return $rt->copy_safeness( $str, $rt->_array_join( $words, ' ' ) );
}

#### trim

sub trim {
  my ( $self, $str ) = @_;
  my $rt = $self->_runtime;
  my $ws = $self->_lib->js_whitespace_class;    # /^\s*|\s*$/g
  return $rt->copy_safeness( $str, $rt->js_string_this( $str, 'str', 'replace' ) =~ s/\A(?:$ws)*|(?:$ws)*\z//gr );
}

#### truncate

sub truncate {
  my ( $self, $input, $length, $killwords, $end ) = @_;
  my $rt   = $self->_runtime;
  my $orig = $input;
  $input  = $self->normalize( $input, '' );
  $length = $rt->op_or( $length, 255 );

  if ( $rt->op_le( $rt->member_lookup( $input, 'length' ), $length ) ) {
    return $input;
  }

  if ( $rt->_truthy($killwords) ) {
    $input = $rt->js_method_call( $input, 'input', 'substring', 0, $length );
  } else {
    my $idx = $rt->js_method_call( $input, 'input', 'lastIndexOf', ' ', $length );
    if ( $rt->op_seq( $idx, -1 ) ) {
      $idx = $length;
    }

    $input = $rt->js_method_call( $input, 'input', 'substring', 0, $idx );
  }

  $input = $rt->op_add( $input, ( defined($end) && !$rt->_is_none($end) ) ? $end : '...' );
  return $rt->copy_safeness( $orig, $input );
}

#### upper

sub upper {
  my ( $self, $str ) = @_;
  $str = $self->normalize( $str, '' );
  return $self->_runtime->js_method_call( $str, 'str', 'toUpperCase' );
}

#### wordcount

sub wordcount {
  my ( $self, $str ) = @_;
  my $rt = $self->_runtime;
  my $w  = $self->_lib->js_word_class;
  $str = $self->normalize( $str, '' );
  my $words = $rt->None;
  if ( $rt->_truthy($str) ) {
    # str.match(/\w+/g): every match, or null when there is none
    my @matches = $rt->js_string_this( $str, 'str', 'match' ) =~ /(?:$w)+/g;
    $words = @matches ? \@matches : $rt->None;
  }
  return $rt->_truthy($words) ? scalar(@$words) : $rt->None;
}

#### exports -- the bag Environment.init registers, built per Environment

sub exports {
  my ( $self, $env ) = @_;
  return {
    capitalize => sub { $self->capitalize(@_) },
    center     => sub { $self->center(@_) },
    indent     => sub { $self->indent(@_) },
    lower      => sub { $self->lower(@_) },
    nl2br      => sub { $self->nl2br(@_) },
    replace    => sub { $self->replace(@_) },
    striptags  => sub { $self->striptags(@_) },
    title      => sub { $self->title(@_) },
    trim       => sub { $self->trim(@_) },
    truncate   => sub { $self->truncate(@_) },
    upper      => sub { $self->upper(@_) },
    wordcount  => sub { $self->wordcount(@_) },
  };
}

1;

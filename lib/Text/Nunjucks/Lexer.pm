package Text::Nunjucks::Lexer;
# ABSTRACT: 1:1 port of Nunjucks src/lexer.js -- the template tokenizer

our $VERSION = '0.001';

use strict;
use warnings;
use Text::Nunjucks::Lib;
use Text::Nunjucks::Lib::Error;

# 1:1 port of upstream src/lexer.js. lexer.js is one file that holds: the `let`
# constants (whitespace/delim/int char sets, the six default tag delimiters and
# the TOKEN_* type strings), a module-level `token()` factory, the `Tokenizer`
# class, and a `module.exports = { lex, TOKEN_* }`. This file mirrors that:
#
#   * the constants are file-lexical `my` vars, shared by the Tokenizer package
#     below exactly as the `let`s are shared inside lexer.js;
#   * `token()` is a Tokenizer method (`$self->token`), a value constructor for
#     Text::Nunjucks::Lexer::Token (house rule: dispatch through the invocant);
#   * `Tokenizer` is a Moo class (ADR 0002) whose fields keep upstream's exact
#     spelling (in_code, trimBlocks, lstripBlocks) the way Nodes.pm keeps its
#     upstream field names, while methods snake_case (nextToken -> next_token);
#   * lex() plus the TOKEN_* names are re-exported as class methods, mirroring
#     lexer.js's module.exports so a consumer reads Text::Nunjucks::Lexer->lex
#     and ->TOKEN_SYMBOL just as parser.js reads lexer.lex / lexer.TOKEN_SYMBOL.
#
# lib.js is used through its real functions (Text::Nunjucks::Lib->index_of),
# never re-derived here. `throw new Error(...)` becomes a thrown
# Text::Nunjucks::Lib::Error (name 'Error'), the same mapping Lib.pm uses.

#### module constants (upstream: the `let` bindings at the top of lexer.js)

my $whitespace_chars = " \n\t\r\x{00A0}";
my $delim_chars      = '()[]{}%*-+~/#,:|.<>=!';
my $int_chars        = '0123456789';

my $BLOCK_START    = '{%';
my $BLOCK_END      = '%}';
my $VARIABLE_START = '{{';
my $VARIABLE_END   = '}}';
my $COMMENT_START  = '{#';
my $COMMENT_END    = '#}';

my $TOKEN_STRING         = 'string';
my $TOKEN_WHITESPACE     = 'whitespace';
my $TOKEN_DATA           = 'data';
my $TOKEN_BLOCK_START    = 'block-start';
my $TOKEN_BLOCK_END      = 'block-end';
my $TOKEN_VARIABLE_START = 'variable-start';
my $TOKEN_VARIABLE_END   = 'variable-end';
my $TOKEN_COMMENT        = 'comment';
my $TOKEN_LEFT_PAREN     = 'left-paren';
my $TOKEN_RIGHT_PAREN    = 'right-paren';
my $TOKEN_LEFT_BRACKET   = 'left-bracket';
my $TOKEN_RIGHT_BRACKET  = 'right-bracket';
my $TOKEN_LEFT_CURLY     = 'left-curly';
my $TOKEN_RIGHT_CURLY    = 'right-curly';
my $TOKEN_OPERATOR       = 'operator';
my $TOKEN_COMMA          = 'comma';
my $TOKEN_COLON          = 'colon';
my $TOKEN_TILDE          = 'tilde';
my $TOKEN_PIPE           = 'pipe';
my $TOKEN_INT            = 'int';
my $TOKEN_FLOAT          = 'float';
my $TOKEN_BOOLEAN        = 'boolean';
my $TOKEN_NONE           = 'none';
my $TOKEN_SYMBOL         = 'symbol';
my $TOKEN_SPECIAL        = 'special';
my $TOKEN_REGEX          = 'regex';

#### module.exports.lex -- lex(src, opts) { return new Tokenizer(src, opts); }

sub lex {
  my ( $class, $src, $opts ) = @_;
  return $class->tokenizer_class->new( $src, $opts );
}

# Named once so the collaborator is reachable through the invocant (house rule).
sub tokenizer_class { 'Text::Nunjucks::Lexer::Tokenizer' }

#### module.exports.TOKEN_* -- the type strings as class methods

# Mirrors the `TOKEN_STRING: TOKEN_STRING, ...` half of module.exports: install a
# same-named method on this package for each type string, so a consumer reads
# Text::Nunjucks::Lexer->TOKEN_SYMBOL exactly as parser.js reads
# lexer.TOKEN_SYMBOL. The lexical above stays the single internal source.
{
  no strict 'refs';
  for my $entry (
    [ TOKEN_STRING         => $TOKEN_STRING ],
    [ TOKEN_WHITESPACE     => $TOKEN_WHITESPACE ],
    [ TOKEN_DATA           => $TOKEN_DATA ],
    [ TOKEN_BLOCK_START    => $TOKEN_BLOCK_START ],
    [ TOKEN_BLOCK_END      => $TOKEN_BLOCK_END ],
    [ TOKEN_VARIABLE_START => $TOKEN_VARIABLE_START ],
    [ TOKEN_VARIABLE_END   => $TOKEN_VARIABLE_END ],
    [ TOKEN_COMMENT        => $TOKEN_COMMENT ],
    [ TOKEN_LEFT_PAREN     => $TOKEN_LEFT_PAREN ],
    [ TOKEN_RIGHT_PAREN    => $TOKEN_RIGHT_PAREN ],
    [ TOKEN_LEFT_BRACKET   => $TOKEN_LEFT_BRACKET ],
    [ TOKEN_RIGHT_BRACKET  => $TOKEN_RIGHT_BRACKET ],
    [ TOKEN_LEFT_CURLY     => $TOKEN_LEFT_CURLY ],
    [ TOKEN_RIGHT_CURLY    => $TOKEN_RIGHT_CURLY ],
    [ TOKEN_OPERATOR       => $TOKEN_OPERATOR ],
    [ TOKEN_COMMA          => $TOKEN_COMMA ],
    [ TOKEN_COLON          => $TOKEN_COLON ],
    [ TOKEN_TILDE          => $TOKEN_TILDE ],
    [ TOKEN_PIPE           => $TOKEN_PIPE ],
    [ TOKEN_INT            => $TOKEN_INT ],
    [ TOKEN_FLOAT          => $TOKEN_FLOAT ],
    [ TOKEN_BOOLEAN        => $TOKEN_BOOLEAN ],
    [ TOKEN_NONE           => $TOKEN_NONE ],
    [ TOKEN_SYMBOL         => $TOKEN_SYMBOL ],
    [ TOKEN_SPECIAL        => $TOKEN_SPECIAL ],
    [ TOKEN_REGEX          => $TOKEN_REGEX ]
  ) {
    my ( $name, $value ) = @$entry;
    *{ __PACKAGE__ . '::' . $name } = sub { $value };
  }
}

#### token -- the { type, value, lineno, colno } record (upstream: function token)

package Text::Nunjucks::Lexer::Token {
  use Moo;
  use namespace::autoclean;

  has type   => ( is => 'ro' );
  has value  => ( is => 'ro' );
  has lineno => ( is => 'ro' );
  has colno  => ( is => 'ro' );

  # token(type, value, lineno, colno) is positional upstream. `value` is a plain
  # string for every token except a regex, whose value is the { body, flags }
  # hashref upstream builds (its runtime representation is decided in k7).
  sub BUILDARGS {
    my ( $class, $type, $value, $lineno, $colno ) = @_;
    return {
      type   => $type,
      value  => $value,
      lineno => $lineno,
      colno  => $colno
    };
  }
}

#### Tokenizer (upstream: class Tokenizer)

package Text::Nunjucks::Lexer::Tokenizer {
  use Moo;
  use namespace::autoclean;
  use Text::Nunjucks::Lib;
  use Text::Nunjucks::Lib::Error;

  # this.str / this.index / this.len / this.lineno / this.colno / this.in_code
  # plus the resolved tag set and the two trim flags. index/lineno/colno/in_code
  # are the mutated state; str/len/tags/trimBlocks/lstripBlocks are fixed at
  # construction. Field spelling follows upstream (in_code, trimBlocks).
  has str          => ( is => 'ro' );
  has index        => ( is => 'rw', default => sub { 0 } );
  has len          => ( is => 'ro' );
  has lineno       => ( is => 'rw', default => sub { 0 } );
  has colno        => ( is => 'rw', default => sub { 0 } );
  has in_code      => ( is => 'rw', default => sub { 0 } );
  has tags         => ( is => 'ro' );
  has trimBlocks   => ( is => 'ro' );
  has lstripBlocks => ( is => 'ro' );

  sub token_class { 'Text::Nunjucks::Lexer::Token' }

  # constructor(str, opts): positional, so BUILDARGS turns (str, opts) into the
  # attribute hash. index/lineno/colno/in_code take their defaults (0/false).
  around BUILDARGS => sub {
    my ( $orig, $class, $str, $opts ) = @_;
    $opts = {} unless defined $opts;    # opts = opts || {}

    my $tags = $opts->{tags} || {};
    return $class->$orig(
      str  => $str,
      len  => length($str),
      tags => {
        BLOCK_START    => ( $tags->{blockStart}    || $BLOCK_START ),
        BLOCK_END      => ( $tags->{blockEnd}      || $BLOCK_END ),
        VARIABLE_START => ( $tags->{variableStart} || $VARIABLE_START ),
        VARIABLE_END   => ( $tags->{variableEnd}   || $VARIABLE_END ),
        COMMENT_START  => ( $tags->{commentStart}  || $COMMENT_START ),
        COMMENT_END    => ( $tags->{commentEnd}    || $COMMENT_END )
      },
      trimBlocks   => ( $opts->{trimBlocks}   ? 1 : 0 ),
      lstripBlocks => ( $opts->{lstripBlocks} ? 1 : 0 )
    );
  };

  sub token {
    my ( $self, $type, $value, $lineno, $colno ) = @_;
    return $self->token_class->new( $type, $value, $lineno, $colno );
  }

  sub next_token {
    my ($self) = @_;
    my $lineno = $self->lineno;
    my $colno  = $self->colno;
    my $tok;

    if ( $self->in_code ) {
      # Otherwise, if we are in a block parse it as code
      my $cur = $self->current;

      if ( $self->is_finished ) {
        # We have nothing else to parse
        return undef;
      }
      elsif ( $cur eq '"' || $cur eq "'" ) {
        # We've hit a string
        return $self->token( $TOKEN_STRING, $self->_parse_string($cur), $lineno, $colno );
      }
      elsif ( $tok = $self->_extract($whitespace_chars) ) {
        # We hit some whitespace
        return $self->token( $TOKEN_WHITESPACE, $tok, $lineno, $colno );
      }
      elsif ( ( $tok = $self->_extract_string( $self->tags->{BLOCK_END} ) )
        || ( $tok = $self->_extract_string( '-' . $self->tags->{BLOCK_END} ) ) )
      {
        # Special check for the block end tag
        #
        # It is a requirement that start and end tags are composed of
        # delimiter characters (%{}[] etc), and our code always
        # breaks on delimiters so we can assume the token parsing
        # doesn't consume these elsewhere
        $self->in_code(0);
        if ( $self->trimBlocks ) {
          $cur = $self->current;
          if ( $cur eq "\n" ) {
            # Skip newline
            $self->forward;
          }
          elsif ( $cur eq "\r" ) {
            # Skip CRLF newline
            $self->forward;
            $cur = $self->current;
            if ( $cur eq "\n" ) {
              $self->forward;
            }
            else {
              # Was not a CRLF, so go back
              $self->back;
            }
          }
        }
        return $self->token( $TOKEN_BLOCK_END, $tok, $lineno, $colno );
      }
      elsif ( ( $tok = $self->_extract_string( $self->tags->{VARIABLE_END} ) )
        || ( $tok = $self->_extract_string( '-' . $self->tags->{VARIABLE_END} ) ) )
      {
        # Special check for variable end tag (see above)
        $self->in_code(0);
        return $self->token( $TOKEN_VARIABLE_END, $tok, $lineno, $colno );
      }
      elsif ( $cur eq 'r' && $self->_char_at( $self->str, $self->index + 1 ) eq '/' ) {
        # Skip past 'r/'.
        $self->forward_n(2);

        # Extract until the end of the regex -- / ends it, \/ does not.
        my $regex_body = '';
        while ( !$self->is_finished ) {
          if ( $self->current eq '/' && $self->previous ne '\\' ) {
            $self->forward;
            last;
          }
          else {
            $regex_body .= $self->current;
            $self->forward;
          }
        }

        # Check for flags.
        # The possible flags are according to https://developer.mozilla.org/en/docs/Web/JavaScript/Reference/Global_Objects/RegExp)
        my @POSSIBLE_FLAGS = ( 'g', 'i', 'm', 'y' );
        my $regex_flags = '';
        while ( !$self->is_finished ) {
          my $is_current_a_flag =
            Text::Nunjucks::Lib->index_of( \@POSSIBLE_FLAGS, $self->current ) != -1;
          if ($is_current_a_flag) {
            $regex_flags .= $self->current;
            $self->forward;
          }
          else {
            last;
          }
        }

        return $self->token(
          $TOKEN_REGEX,
          { body => $regex_body, flags => $regex_flags },
          $lineno, $colno
        );
      }
      elsif ( CORE::index( $delim_chars, $cur ) != -1 ) {
        # We've hit a delimiter (a special char like a bracket)
        $self->forward;
        my @complex_ops = ( '==', '===', '!=', '!==', '<=', '>=', '//', '**' );
        my $cur_complex = $cur . $self->current;
        my $type;

        if ( Text::Nunjucks::Lib->index_of( \@complex_ops, $cur_complex ) != -1 ) {
          $self->forward;
          $cur = $cur_complex;

          # See if this is a strict equality/inequality comparator
          if ( Text::Nunjucks::Lib->index_of( \@complex_ops, $cur_complex . $self->current ) != -1 ) {
            $cur = $cur_complex . $self->current;
            $self->forward;
          }
        }

        if    ( $cur eq '(' ) { $type = $TOKEN_LEFT_PAREN; }
        elsif ( $cur eq ')' ) { $type = $TOKEN_RIGHT_PAREN; }
        elsif ( $cur eq '[' ) { $type = $TOKEN_LEFT_BRACKET; }
        elsif ( $cur eq ']' ) { $type = $TOKEN_RIGHT_BRACKET; }
        elsif ( $cur eq '{' ) { $type = $TOKEN_LEFT_CURLY; }
        elsif ( $cur eq '}' ) { $type = $TOKEN_RIGHT_CURLY; }
        elsif ( $cur eq ',' ) { $type = $TOKEN_COMMA; }
        elsif ( $cur eq ':' ) { $type = $TOKEN_COLON; }
        elsif ( $cur eq '~' ) { $type = $TOKEN_TILDE; }
        elsif ( $cur eq '|' ) { $type = $TOKEN_PIPE; }
        else                  { $type = $TOKEN_OPERATOR; }

        return $self->token( $type, $cur, $lineno, $colno );
      }
      else {
        # We are not at whitespace or a delimiter, so extract the
        # text and parse it
        $tok = $self->_extract_until( $whitespace_chars . $delim_chars );

        if ( $tok =~ /^[-+]?[0-9]+$/ ) {
          if ( $self->current eq '.' ) {
            $self->forward;
            my $dec = $self->_extract($int_chars);
            # At EOF _extract returns undef, JS's _extract returns null, and
            # `tok + '.' + null` stringifies to "<tok>.null" ({{3. -> 3.null).
            # Raw JS String(null) concat here, not the k2 null render (empty).
            $dec = 'null' unless defined $dec;
            return $self->token( $TOKEN_FLOAT, $tok . '.' . $dec, $lineno, $colno );
          }
          else {
            return $self->token( $TOKEN_INT, $tok, $lineno, $colno );
          }
        }
        elsif ( $tok =~ /^(true|false)$/ ) {
          return $self->token( $TOKEN_BOOLEAN, $tok, $lineno, $colno );
        }
        elsif ( $tok eq 'none' ) {
          return $self->token( $TOKEN_NONE, $tok, $lineno, $colno );
        }
        #
        # Added to make the test `null is null` evaluate truthily.
        # Otherwise, Nunjucks will look up null in the context and
        # return `undefined`, which is not what we want. This *may* have
        # consequences is someone is using null in their templates as a
        # variable.
        #
        elsif ( $tok eq 'null' ) {
          return $self->token( $TOKEN_NONE, $tok, $lineno, $colno );
        }
        elsif ( length $tok ) {
          # JS `else if (tok)`: a non-empty string. length() not truthiness, so
          # the (numeric, already handled) case of tok eq '0' cannot mislead.
          return $self->token( $TOKEN_SYMBOL, $tok, $lineno, $colno );
        }
        else {
          die Text::Nunjucks::Lib::Error->new( 'Unexpected value while parsing: ' . $tok );
        }
      }
    }
    else {
      # Parse out the template text, breaking on tag
      # delimiters because we need to look for block/variable start
      # tags (don't use the full delimChars for optimization)
      my $begin_chars =
          substr( $self->tags->{BLOCK_START},    0, 1 )
        . substr( $self->tags->{VARIABLE_START}, 0, 1 )
        . substr( $self->tags->{COMMENT_START},  0, 1 )
        . substr( $self->tags->{COMMENT_END},    0, 1 );

      if ( $self->is_finished ) {
        return undef;
      }
      elsif ( ( $tok = $self->_extract_string( $self->tags->{BLOCK_START} . '-' ) )
        || ( $tok = $self->_extract_string( $self->tags->{BLOCK_START} ) ) )
      {
        $self->in_code(1);
        return $self->token( $TOKEN_BLOCK_START, $tok, $lineno, $colno );
      }
      elsif ( ( $tok = $self->_extract_string( $self->tags->{VARIABLE_START} . '-' ) )
        || ( $tok = $self->_extract_string( $self->tags->{VARIABLE_START} ) ) )
      {
        $self->in_code(1);
        return $self->token( $TOKEN_VARIABLE_START, $tok, $lineno, $colno );
      }
      else {
        $tok = '';
        my $data;
        my $in_comment = 0;

        if ( $self->_matches( $self->tags->{COMMENT_START} ) ) {
          $in_comment = 1;
          $tok        = $self->_extract_string( $self->tags->{COMMENT_START} );
        }

        # Continually consume text, breaking on the tag delimiter
        # characters and checking to see if it's a start tag.
        #
        # We could hit the end of the template in the middle of
        # our looping, so check for the null return value from
        # _extractUntil
        while ( defined( $data = $self->_extract_until($begin_chars) ) ) {
          $tok .= $data;

          if ( ( $self->_matches( $self->tags->{BLOCK_START} )
              || $self->_matches( $self->tags->{VARIABLE_START} )
              || $self->_matches( $self->tags->{COMMENT_START} ) )
            && !$in_comment )
          {
            if ( $self->lstripBlocks
              && $self->_matches( $self->tags->{BLOCK_START} )
              && $self->colno > 0
              && $self->colno <= length($tok) )
            {
              my $last_line = substr( $tok, -$self->colno );
              # JS \s, not Perl \s: NBSP/FEFF are members and the match must not
              # depend on the SV's UTF-8 flag (ADR 0005). The explicit class
              # carries /u; anchors stay ^..+..$ as upstream.
              my $ws = Text::Nunjucks::Lib->js_whitespace_class;
              if ( $last_line =~ /^$ws+$/ ) {
                # Remove block leading whitespace from beginning of the string
                $tok = substr( $tok, 0, -$self->colno );
                unless ( length $tok ) {
                  # All data removed, collapse to avoid unnecessary nodes
                  # by returning next token (block start)
                  return $self->next_token;
                }
              }
            }
            # If it is a start tag, stop looping
            last;
          }
          elsif ( $self->_matches( $self->tags->{COMMENT_END} ) ) {
            if ( !$in_comment ) {
              die Text::Nunjucks::Lib::Error->new('unexpected end of comment');
            }
            $tok .= $self->_extract_string( $self->tags->{COMMENT_END} );
            last;
          }
          else {
            # It does not match any tag, so add the character and
            # carry on
            $tok .= $self->current;
            $self->forward;
          }
        }

        if ( !defined($data) && $in_comment ) {
          die Text::Nunjucks::Lib::Error->new('expected end of comment, got end of file');
        }

        return $self->token(
          ( $in_comment ? $TOKEN_COMMENT : $TOKEN_DATA ),
          $tok, $lineno, $colno
        );
      }
    }
  }

  sub _parse_string {
    my ( $self, $delimiter ) = @_;
    $self->forward;

    my $str = '';

    while ( !$self->is_finished && $self->current ne $delimiter ) {
      my $cur = $self->current;

      if ( $cur eq '\\' ) {
        $self->forward;
        my $c = $self->current;
        if    ( $c eq 'n' ) { $str .= "\n"; }
        elsif ( $c eq 't' ) { $str .= "\t"; }
        elsif ( $c eq 'r' ) { $str .= "\r"; }
        else                { $str .= $c; }
        $self->forward;
      }
      else {
        $str .= $cur;
        $self->forward;
      }
    }

    $self->forward;
    return $str;
  }

  sub _matches {
    my ( $self, $str ) = @_;
    if ( $self->index + length($str) > $self->len ) {
      return undef;
    }

    my $m = substr( $self->str, $self->index, length($str) );
    return $m eq $str ? 1 : 0;
  }

  sub _extract_string {
    my ( $self, $str ) = @_;
    if ( $self->_matches($str) ) {
      $self->forward_n( length $str );
      return $str;
    }
    return undef;
  }

  sub _extract_until {
    my ( $self, $char_string ) = @_;
    # Extract all non-matching chars, with the default matching set
    # to everything
    return $self->_extract_matching( 1, ( $char_string // '' ) );
  }

  sub _extract {
    my ( $self, $char_string ) = @_;
    # Extract all matching chars (no default, so charString must be
    # explicit)
    return $self->_extract_matching( 0, $char_string );
  }

  sub _extract_matching {
    my ( $self, $break_on_match, $char_string ) = @_;
    # Pull out characters until a breaking char is hit.
    # If breakOnMatch is false, a non-matching char stops it.
    # If breakOnMatch is true, a matching char stops it.

    if ( $self->is_finished ) {
      return undef;
    }

    my $first = CORE::index( $char_string, $self->current );

    # Only proceed if the first character doesn't meet our condition
    if ( ( $break_on_match && $first == -1 )
      || ( !$break_on_match && $first != -1 ) )
    {
      my $t = $self->current;
      $self->forward;

      # And pull out all the chars one at a time until we hit a
      # breaking char
      my $idx = CORE::index( $char_string, $self->current );

      while ( ( ( $break_on_match && $idx == -1 )
          || ( !$break_on_match && $idx != -1 ) )
        && !$self->is_finished )
      {
        $t .= $self->current;
        $self->forward;

        $idx = CORE::index( $char_string, $self->current );
      }

      return $t;
    }

    return '';
  }

  sub _extract_regex {
    my ( $self, $regex ) = @_;
    # NOTE: unused in the lexer, exactly as upstream -- _extractRegex and its
    # only caller currentStr are dead code in lexer.js, kept here for a 1:1
    # image of the file. JS String.match(regex) returns the match array whose
    # [0] is the whole match; modelled with $& plus captures.
    return undef unless $self->current_str =~ /$regex/;
    my @matches = ( $&, @{^CAPTURE} );

    # Move forward whatever was matched
    $self->forward_n( length $matches[0] );

    return \@matches;
  }

  sub is_finished {
    my ($self) = @_;
    return $self->index >= $self->len;
  }

  sub forward_n {
    my ( $self, $n ) = @_;
    for ( my $i = 0; $i < $n; $i++ ) {
      $self->forward;
    }
  }

  sub forward {
    my ($self) = @_;
    $self->index( $self->index + 1 );

    if ( $self->previous eq "\n" ) {
      $self->lineno( $self->lineno + 1 );
      $self->colno(0);
    }
    else {
      $self->colno( $self->colno + 1 );
    }
  }

  sub back_n {
    my ( $self, $n ) = @_;
    for ( my $i = 0; $i < $n; $i++ ) {
      $self->back;
    }
  }

  sub back {
    my ($self) = @_;
    $self->index( $self->index - 1 );

    if ( $self->current eq "\n" ) {
      $self->lineno( $self->lineno - 1 );

      # NOTE: upstream typo -- `this.src` is undefined (the field is `this.str`).
      # Unreachable: back() is only ever called after a '\r' (the trimBlocks
      # CRLF path), so current() here is '\r', never '\n'. Preserved 1:1 by
      # reading the same nonexistent field; see the k10 report.
      my $idx = rindex( $self->{src}, "\n", $self->index - 1 );
      if ( $idx == -1 ) {
        $self->colno( $self->index );
      }
      else {
        $self->colno( $self->index - $idx );
      }
    }
    else {
      $self->colno( $self->colno - 1 );
    }
  }

  # current returns current character
  sub current {
    my ($self) = @_;
    if ( !$self->is_finished ) {
      return $self->_char_at( $self->str, $self->index );
    }
    return '';
  }

  # currentStr returns what's left of the unparsed string
  sub current_str {
    my ($self) = @_;
    if ( !$self->is_finished ) {
      return substr( $self->str, $self->index );
    }
    return '';
  }

  sub previous {
    my ($self) = @_;
    return $self->_char_at( $self->str, $self->index - 1 );
  }

  # JS String.prototype.charAt: '' for an index outside [0, length). Perl's
  # substr differs there (negative offsets wrap, past-end warns), so charAt is
  # kept as a helper rather than an inline substr. Upstream calls this.str.charAt
  # directly in current(), previous() and the regex look-ahead.
  sub _char_at {
    my ( $self, $str, $i ) = @_;
    return '' if $i < 0 || $i >= length($str);
    return substr( $str, $i, 1 );
  }
}

1;

__END__

=head1 NAME

Text::Nunjucks::Lexer - the template tokenizer

=head1 DESCRIPTION

A 1:1 port of Nunjucks C<src/lexer.js>. Turns a template string into a stream
of tokens.

    my $tokens = Text::Nunjucks::Lexer->lex( '{{ a }}', \%opts );
    while ( my $tok = $tokens->next_token ) {
      # $tok->type, $tok->value, $tok->lineno, $tok->colno
    }

C<lex> returns a L<Text::Nunjucks::Lexer::Tokenizer>; each C<next_token> yields
a L<Text::Nunjucks::Lexer::Token> (with C<type>, C<value>, C<lineno>, C<colno>)
until the input is exhausted, when it returns C<undef>. C<lineno> and C<colno>
are 0-based, as in the JavaScript original.

The token type strings are exposed as class methods mirroring the upstream
C<module.exports> (e.g. C<< Text::Nunjucks::Lexer->TOKEN_SYMBOL >>).

=cut

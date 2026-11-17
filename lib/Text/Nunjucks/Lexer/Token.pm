package Text::Nunjucks::Lexer::Token;
# ABSTRACT: One lexer token -- type, value, line and column (lexer.js token())

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

# upstream: function token(type, value, lineno, colno) -- the
# { type, value, lineno, colno } record the Tokenizer hands out.

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

1;

__END__

=description

Engine-internal: a token as L<Text::Nunjucks::Lexer::Tokenizer> yields it, with
C<type>, C<value>, C<lineno> and C<colno> (0-based, as in the JavaScript
original). See L<Text::Nunjucks::Lexer>.

=cut

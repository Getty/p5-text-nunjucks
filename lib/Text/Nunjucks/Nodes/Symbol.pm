package Text::Nunjucks::Nodes::Symbol;
# ABSTRACT: AST node Symbol (fields value), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Value';

# nodes.js: const Symbol = Value.extend('Symbol');
# No {fields}: the field list and its accessors are inherited
# from Value (value).

sub typename { 'Symbol' }

1;

__END__

=description

Engine-internal: the C<Symbol> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

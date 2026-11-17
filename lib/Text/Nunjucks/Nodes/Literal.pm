package Text::Nunjucks::Nodes::Literal;
# ABSTRACT: AST node Literal (fields value), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Value';

# nodes.js: const Literal = Value.extend('Literal');
# No {fields}: the field list and its accessors are inherited
# from Value (value).

sub typename { 'Literal' }

1;

__END__

=description

Engine-internal: the C<Literal> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

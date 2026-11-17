package Text::Nunjucks::Nodes::Neg;
# ABSTRACT: AST node Neg (fields target), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::UnaryOp';

# nodes.js: const Neg = UnaryOp.extend('Neg');
# No {fields}: the field list and its accessors are inherited
# from UnaryOp (target).

sub typename { 'Neg' }

1;

__END__

=description

Engine-internal: the C<Neg> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

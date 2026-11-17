package Text::Nunjucks::Nodes::Not;
# ABSTRACT: AST node Not (fields target), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::UnaryOp';

# nodes.js: const Not = UnaryOp.extend('Not');
# No {fields}: the field list and its accessors are inherited
# from UnaryOp (target).

sub typename { 'Not' }

1;

__END__

=description

Engine-internal: the C<Not> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

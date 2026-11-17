package Text::Nunjucks::Nodes::IfAsync;
# ABSTRACT: AST node IfAsync (fields cond, body, else_), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::If';

# nodes.js: const IfAsync = If.extend('IfAsync');
# No {fields}: the field list and its accessors are inherited
# from If (cond, body, else_).

sub typename { 'IfAsync' }

1;

__END__

=description

Engine-internal: the C<IfAsync> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

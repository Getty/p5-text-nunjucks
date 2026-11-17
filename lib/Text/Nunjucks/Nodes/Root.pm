package Text::Nunjucks::Nodes::Root;
# ABSTRACT: AST node Root (fields children), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::NodeList';

# nodes.js: const Root = NodeList.extend('Root');
# No {fields}: the field list and its accessors are inherited
# from NodeList (children).

sub typename { 'Root' }

1;

__END__

=description

Engine-internal: the C<Root> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

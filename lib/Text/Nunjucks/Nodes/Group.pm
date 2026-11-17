package Text::Nunjucks::Nodes::Group;
# ABSTRACT: AST node Group (fields children), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::NodeList';

# nodes.js: const Group = NodeList.extend('Group');
# No {fields}: the field list and its accessors are inherited
# from NodeList (children).

sub typename { 'Group' }

1;

__END__

=description

Engine-internal: the C<Group> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

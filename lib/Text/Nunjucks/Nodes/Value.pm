package Text::Nunjucks::Nodes::Value;
# ABSTRACT: Abstract AST node with a value field (nodes.js class Value)

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# upstream: class Value extends Node -- abstract, under "// Abstract nodes".

has value => ( is => 'rw' );

sub typename { 'Value' }
sub fields   { ['value'] }

1;

__END__

=description

Engine-internal: the abstract parent of the C<Literal> and C<Symbol> nodes of
the template AST in L<Text::Nunjucks::Nodes>.

=cut

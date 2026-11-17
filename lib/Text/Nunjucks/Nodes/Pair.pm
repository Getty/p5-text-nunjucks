package Text::Nunjucks::Nodes::Pair;
# ABSTRACT: AST node Pair (fields key, value), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const Pair = Node.extend('Pair', { fields: ['key', 'value'] });

has key   => ( is => 'rw' );
has value => ( is => 'rw' );

sub typename { 'Pair' }
sub fields   { [ 'key', 'value' ] }

1;

__END__

=description

Engine-internal: the C<Pair> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

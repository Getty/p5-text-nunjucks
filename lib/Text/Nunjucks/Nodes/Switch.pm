package Text::Nunjucks::Nodes::Switch;
# ABSTRACT: AST node Switch (fields expr, cases, default), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const Switch = Node.extend('Switch', { fields: ['expr', 'cases', 'default'] });

has expr    => ( is => 'rw' );
has cases   => ( is => 'rw' );
has default => ( is => 'rw' );

sub typename { 'Switch' }
sub fields   { [ 'expr', 'cases', 'default' ] }

1;

__END__

=description

Engine-internal: the C<Switch> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

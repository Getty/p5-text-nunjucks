package Text::Nunjucks::Nodes::Include;
# ABSTRACT: AST node Include (fields template, ignoreMissing), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const Include = Node.extend('Include', { fields: ['template', 'ignoreMissing'] });

has template      => ( is => 'rw' );
has ignoreMissing => ( is => 'rw' );

sub typename { 'Include' }
sub fields   { [ 'template', 'ignoreMissing' ] }

1;

__END__

=description

Engine-internal: the C<Include> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

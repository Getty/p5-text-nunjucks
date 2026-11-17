package Text::Nunjucks::Nodes::LookupVal;
# ABSTRACT: AST node LookupVal (fields target, val), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const LookupVal = Node.extend('LookupVal', { fields: ['target', 'val'] });

has target => ( is => 'rw' );
has val    => ( is => 'rw' );

sub typename { 'LookupVal' }
sub fields   { [ 'target', 'val' ] }

1;

__END__

=description

Engine-internal: the C<LookupVal> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

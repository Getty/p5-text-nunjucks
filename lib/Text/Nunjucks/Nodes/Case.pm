package Text::Nunjucks::Nodes::Case;
# ABSTRACT: AST node Case (fields cond, body), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const Case = Node.extend('Case', { fields: ['cond', 'body'] });

has cond => ( is => 'rw' );
has body => ( is => 'rw' );

sub typename { 'Case' }
sub fields   { [ 'cond', 'body' ] }

1;

__END__

=description

Engine-internal: the C<Case> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

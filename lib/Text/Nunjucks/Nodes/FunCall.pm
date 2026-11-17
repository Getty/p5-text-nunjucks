package Text::Nunjucks::Nodes::FunCall;
# ABSTRACT: AST node FunCall (fields name, args), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const FunCall = Node.extend('FunCall', { fields: ['name', 'args'] });

has name => ( is => 'rw' );
has args => ( is => 'rw' );

sub typename { 'FunCall' }
sub fields   { [ 'name', 'args' ] }

1;

__END__

=description

Engine-internal: the C<FunCall> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

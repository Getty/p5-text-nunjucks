package Text::Nunjucks::Nodes::If;
# ABSTRACT: AST node If (fields cond, body, else_), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const If = Node.extend('If', { fields: ['cond', 'body', 'else_'] });

has cond  => ( is => 'rw' );
has body  => ( is => 'rw' );
has else_ => ( is => 'rw' );

sub typename { 'If' }
sub fields   { [ 'cond', 'body', 'else_' ] }

1;

__END__

=description

Engine-internal: the C<If> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

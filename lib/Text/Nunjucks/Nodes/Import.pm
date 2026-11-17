package Text::Nunjucks::Nodes::Import;
# ABSTRACT: AST node Import (fields template, target, withContext), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const Import = Node.extend('Import', { fields: ['template', 'target', 'withContext'] });

has template    => ( is => 'rw' );
has target      => ( is => 'rw' );
has withContext => ( is => 'rw' );

sub typename { 'Import' }
sub fields   { [ 'template', 'target', 'withContext' ] }

1;

__END__

=description

Engine-internal: the C<Import> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

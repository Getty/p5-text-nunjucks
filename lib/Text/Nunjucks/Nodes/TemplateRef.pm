package Text::Nunjucks::Nodes::TemplateRef;
# ABSTRACT: AST node TemplateRef (fields template), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const TemplateRef = Node.extend('TemplateRef', { fields: ['template'] });

has template => ( is => 'rw' );

sub typename { 'TemplateRef' }
sub fields   { [ 'template' ] }

1;

__END__

=description

Engine-internal: the C<TemplateRef> node of the template AST, the parent of
C<Extends>; see L<Text::Nunjucks::Nodes>.

=cut

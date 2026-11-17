package Text::Nunjucks::Nodes::TemplateData;
# ABSTRACT: AST node TemplateData (fields value), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Literal';

# nodes.js: const TemplateData = Literal.extend('TemplateData');
# No {fields}: the field list and its accessors are inherited
# from Literal (value).

sub typename { 'TemplateData' }

1;

__END__

=description

Engine-internal: the C<TemplateData> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut

package Text::Nunjucks::Nodes::CallExtensionAsync;
# ABSTRACT: AST node CallExtensionAsync (fields extName, prop, args, contentArgs), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::CallExtension';

# nodes.js: const CallExtensionAsync = CallExtension.extend('CallExtensionAsync');
# No {fields}: the field list and its accessors are inherited
# from CallExtension (extName, prop, args, contentArgs).

sub typename { 'CallExtensionAsync' }

1;

__END__

=description

Engine-internal: the C<CallExtensionAsync> node of the template AST that an
extension builds for a tag it claims, for asynchronous work; the
L<Text::Nunjucks::Compiler> reads it. See L<Text::Nunjucks::Nodes>.

=cut

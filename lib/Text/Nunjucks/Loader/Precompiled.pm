package Text::Nunjucks::Loader::Precompiled;
# ABSTRACT: 1:1 port of Nunjucks src/precompiled-loader.js -- templates from precompiled code objects

our $VERSION = '0.001';

use Moo;
use Text::Nunjucks::Runtime;
use namespace::autoclean;

extends 'Text::Nunjucks::Loader';

# src/precompiled-loader.js: a Loader over a bag of precompiled templates, name
# -> the object a precompiled template evaluates to ({ root, b_<block>, ... }:
# in the port the hashref of coderefs the compiled Perl source returns, which
# Template takes as { type => 'code', obj => ... }). constructor(compiledTemplates)
# sets this.precompiled; BUILDARGS keeps the positional argument, BUILD is the
# body (super() is Moo's), as in Text::Nunjucks::Loader::FileSystem.

has precompiled => ( is => 'rw' );
has _init_args  => ( is => 'ro' );

sub _runtime { 'Text::Nunjucks::Runtime' }

# new PrecompiledLoader(compiledTemplates) -- positional.
sub BUILDARGS {
  my ( $class, @args ) = @_;
  return { _init_args => [@args] };
}

# constructor(compiledTemplates)
sub BUILD {
  my ($self) = @_;
  my ($compiled_templates) = @{ $self->_init_args // [] };
  delete $self->{_init_args};
  $self->precompiled( $self->_runtime->_truthy($compiled_templates) ? $compiled_templates : {} );
}

# this.precompiled[name] is a JS property read on whatever the constructor
# kept -- a hash, but also a string or a number, where JS reads a character
# or undefined (node: new PrecompiledLoader('abc').getSource('0') has obj 'a',
# a number finds nothing) -- so it goes through Runtime's js_member_read.
sub get_source {
  my ( $self, $name ) = @_;
  my $rt = $self->_runtime;
  if ( $rt->_truthy( $rt->js_member_read( $self->precompiled, $name ) ) ) {
    return {
      src => {
        type => 'code',
        obj  => $rt->js_member_read( $self->precompiled, $name ),
      },
      path => $name,
    };
  }
  return undef;
}

1;

__END__

=description

Serves templates from a hash of precompiled template objects keyed by name, a
port of the C<PrecompiledLoader> of Nunjucks C<src/precompiled-loader.js>.

    my $loader = Text::Nunjucks::Loader::Precompiled->new( { 'hi.njk' => \%compiled } );

A compiled template is the hash reference of code references that the Perl
source emitted by L<Text::Nunjucks::Compiler> evaluates to (a C<root> entry
and a C<b_NAME> entry per block).

=cut

=attr precompiled

Hash reference of the template names to their compiled objects.

=cut

=method new

    Text::Nunjucks::Loader::Precompiled->new( \%compiled_templates );

Positional. Without a (true) argument the loader is empty.

=cut

=method get_source

    my $source = $loader->get_source($name);

Returns C<< { src => { type => 'code', obj => $compiled }, path => $name } >>
for a name that is in the hash, otherwise C<undef>. The result carries no
C<noCache>, so the Environment caches the template.

=cut

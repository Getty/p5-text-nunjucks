package Text::Nunjucks::Context;
# ABSTRACT: The per-render bookkeeping of variables and blocks (environment.js class Context)

our $VERSION = '0.001';

use Moo;
use Text::Nunjucks::Lib;
use Text::Nunjucks::Lib::Error;
use Text::Nunjucks::Environment;
use namespace::autoclean;

# upstream: class Context extends Obj in src/environment.js, which defines it
# internally (environment.js exports only Environment and Template). Like
# Environment and Template, the constructor's `this.init(...args)` indirection
# is a positional-args BUILDARGS feeding a faithful init().

has env      => ( is => 'rw' );
has ctx      => ( is => 'rw' );
has blocks   => ( is => 'rw' );
has exported => ( is => 'rw' );
has _init_args => ( is => 'ro' );

sub _lib                 { 'Text::Nunjucks::Lib' }
sub _environment_class   { 'Text::Nunjucks::Environment' }
sub _error_class         { 'Text::Nunjucks::Lib::Error' }

sub BUILDARGS {
  my ( $class, @args ) = @_;
  return { _init_args => [@args] };
}

sub BUILD {
  my ($self) = @_;
  $self->init( @{ $self->_init_args // [] } );
  delete $self->{_init_args};
}

sub init {
  my ( $self, $ctx, $blocks, $env ) = @_;

  # Has to be tied to an environment so we can tap into its globals.
  $self->env( $env || $self->_environment_class->new );

  # Make a duplicate of ctx.
  $self->ctx( $self->_lib->extend( {}, $ctx ) );

  $self->blocks( {} );
  $self->exported( [] );

  for my $name ( @{ $self->_lib->keys($blocks) } ) {
    $self->add_block( $name, $blocks->{$name} );
  }
}

sub lookup {
  my ( $self, $name ) = @_;
  # Optimize for the typical case where the name isn't in the globals.
  if ( exists $self->env->globals->{$name} && !exists $self->ctx->{$name} ) {
    return $self->env->globals->{$name};
  }
  else {
    return $self->ctx->{$name};
  }
}

sub set_variable {
  my ( $self, $name, $val ) = @_;
  $self->ctx->{$name} = $val;
}

sub get_variables {
  my ($self) = @_;
  return $self->ctx;
}

sub add_block {
  my ( $self, $name, $block ) = @_;
  $self->blocks->{$name} = $self->blocks->{$name} || [];
  push @{ $self->blocks->{$name} }, $block;
  return $self;
}

sub get_block {
  my ( $self, $name ) = @_;
  if ( !$self->blocks->{$name} ) {
    die $self->_error_class->new( 'unknown block "' . $name . '"' );
  }
  return $self->blocks->{$name}[0];
}

sub get_super {
  my ( $self, $env, $name, $block, $frame, $runtime, $cb ) = @_;
  my $idx     = $self->_lib->index_of( $self->blocks->{$name} || [], $block );
  my $blk     = $self->blocks->{$name}[ $idx + 1 ];
  my $context = $self;

  if ( $idx == -1 || !$blk ) {
    die $self->_error_class->new( 'no super block available for "' . $name . '"' );
  }

  $blk->( $env, $context, $frame, $runtime, $cb );
}

# addExport(name) -- pushes the name; the compiler may pass an extra value arg
# (compile_set), which is ignored, exactly as upstream ignores it.
sub add_export {
  my ( $self, $name ) = @_;
  push @{ $self->exported }, $name;
}

sub get_exported {
  my ($self) = @_;
  my $exported = {};
  for my $name ( @{ $self->exported } ) {
    $exported->{$name} = $self->ctx->{$name};
  }
  return $exported;
}

1;

__END__

=description

Engine-internal: the variables and blocks of one render. A
L<Text::Nunjucks::Template> creates it for each render; callers do not use it.
Its constructor takes its arguments by position, as upstream's does, not as a
hash.

=cut

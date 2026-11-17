package Text::Nunjucks::Template;
# ABSTRACT: A compiled template that renders (environment.js class Template)

our $VERSION = '0.001';

use Moo;
use Text::Nunjucks::Lib;
use Text::Nunjucks::Lib::Error;
use Text::Nunjucks::Runtime;
use Text::Nunjucks::Compiler;
use Text::Nunjucks::Context;
use Text::Nunjucks::Environment;
use namespace::autoclean;

# upstream: class Template extends Obj in src/environment.js, exported with
# Environment. The constructor's `this.init(...args)` indirection is a
# positional-args BUILDARGS feeding a faithful init().

has env             => ( is => 'rw' );
has path            => ( is => 'rw' );
has tmpl_props      => ( is => 'rw' );
has tmpl_str        => ( is => 'rw' );
has compiled          => ( is => 'rw' );
has blocks            => ( is => 'rw' );
has _root_render_func => ( is => 'rw' );
has _init_args        => ( is => 'ro' );

# In JS `this.rootRenderFunc = props.root` stores a function and
# `parentTemplate.rootRenderFunc(env, ...)` CALLS it -- a callable property.
# The compiler emits that same `$parentTemplate->root_render_func($env, ...)`
# call shape (compile_root's extends tail), so root_render_func is a method
# that INVOKES the stored coderef; the coderef itself lives in the private
# _root_render_func slot, set at compile.
sub root_render_func {
  my ( $self, @args ) = @_;
  return $self->_root_render_func->(@args);
}

sub _lib               { 'Text::Nunjucks::Lib' }
sub _runtime_class     { 'Text::Nunjucks::Runtime' }
sub _compiler_class    { 'Text::Nunjucks::Compiler' }
sub _context_class     { 'Text::Nunjucks::Context' }
sub _environment_class { 'Text::Nunjucks::Environment' }

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
  my ( $self, $src, $env, $path, $eager_compile ) = @_;
  $self->env( $env || $self->_environment_class->new );

  if ( $self->_lib->is_object($src) ) {
    my $type = $src->{type};
    if ( defined($type) && $type eq 'code' ) {
      $self->tmpl_props( $src->{obj} );
    }
    elsif ( defined($type) && $type eq 'string' ) {
      $self->tmpl_str( $src->{obj} );
    }
    else {
      die $self->_lib_error(
        "Unexpected template object type " . ( $type // 'undefined' )
          . "; expected 'code', or 'string'" );
    }
  }
  elsif ( $self->_lib->is_string($src) ) {
    $self->tmpl_str($src);
  }
  else {
    die $self->_lib_error('src must be a string or an object describing the source');
  }

  $self->path($path);

  if ($eager_compile) {
    my $ok = eval { $self->_compile; 1 };
    if ( !$ok ) {
      die $self->_lib->_prettify_error( $self->path, $self->env->opts->{dev}, $@ );
    }
  }
  else {
    $self->compiled(0);
  }
}

sub _lib_error {
  my ( $self, $msg ) = @_;
  return Text::Nunjucks::Lib::Error->new($msg);
}

sub render {
  my ( $self, $ctx, $parent_frame, $cb ) = @_;
  if ( $self->_lib->is_function($ctx) ) {
    $cb  = $ctx;
    $ctx = {};
  }
  elsif ( $self->_lib->is_function($parent_frame) ) {
    $cb           = $parent_frame;
    $parent_frame = undef;
  }

  # A parent frame means we're called from another template's internals; the
  # sync/async nature is inherited, so force an async callback otherwise.
  my $force_async = !$parent_frame;

  # Catch compile errors for async rendering.
  my $ok = eval { $self->compile; 1 };
  if ( !$ok ) {
    my $err = $self->_lib->_prettify_error( $self->path, $self->env->opts->{dev}, $@ );
    if ($cb) {
      return $self->env->_callback_asap( $cb, $err );
    }
    else {
      die $err;
    }
  }

  my $context = $self->_context_class->new( $ctx || {}, $self->blocks, $self->env );
  my $frame = $parent_frame ? $parent_frame->push(1) : $self->_runtime_class->Frame->new;
  $frame->top_level(1);
  my $sync_result = undef;
  my $did_error   = 0;

  $self->_root_render_func->(
    $self->env, $context, $frame, $self->_runtime_class,
    sub {
      my ( $err, $res ) = @_;
      # See upstream note: a waterfall task may fail to propagate up the chain
      # AND fail to return from the top render; guard against a double cb call.
      if ( $did_error && $cb && defined $res ) {
        return;
      }

      if ($err) {
        $err = $self->_lib->_prettify_error( $self->path, $self->env->opts->{dev}, $err );
        $did_error = 1;
      }

      if ($cb) {
        if ($force_async) {
          $self->env->_callback_asap( $cb, $err, $res );
        }
        else {
          $cb->( $err, $res );
        }
      }
      else {
        if ($err) {
          die $err;
        }
        $sync_result = $res;
      }
    }
  );

  return $sync_result;
}

sub get_exported {
  my ( $self, $ctx, $parent_frame, $cb ) = @_;
  if ( $self->_lib->is_function($ctx) ) {
    $cb  = $ctx;
    $ctx = {};
  }

  if ( $self->_lib->is_function($parent_frame) ) {
    $cb           = $parent_frame;
    $parent_frame = undef;
  }

  # Catch compile errors for async rendering.
  my $ok = eval { $self->compile; 1 };
  if ( !$ok ) {
    if ($cb) {
      return $cb->($@);
    }
    else {
      die $@;
    }
  }

  my $frame = $parent_frame ? $parent_frame->push : $self->_runtime_class->Frame->new;
  $frame->top_level(1);

  # Run the rootRenderFunc to populate the context with exported vars.
  my $context = $self->_context_class->new( $ctx || {}, $self->blocks, $self->env );
  $self->_root_render_func->(
    $self->env, $context, $frame, $self->_runtime_class,
    sub {
      my ($err) = @_;
      if ($err) {
        $cb->( $err, undef );
      }
      else {
        $cb->( undef, $context->get_exported );
      }
    }
  );
}

sub compile {
  my ($self) = @_;
  if ( !$self->compiled ) {
    $self->_compile;
  }
}

sub _compile {
  my ($self) = @_;
  my $props;

  if ( $self->tmpl_props ) {
    $props = $self->tmpl_props;
  }
  else {
    my $source = $self->_compiler_class->compile(
      $self->tmpl_str,
      $self->env->async_filters,
      $self->env->extensions_list,
      $self->path,
      $self->env->opts
    );

    $props = $self->_eval_source($source);    # new Function(source)(); returns props
  }

  $self->blocks( $self->_get_blocks($props) );
  $self->_root_render_func( $props->{root} );
  $self->compiled(1);
}

# new Function(source) -- eval the emitted Perl source, which ends in a
# +{ root => \&, b_<name> => \&, ... } hashref. Compiled template bodies are
# sloppy-mode in JS (new Function is non-strict); eval'ing without strict/
# warnings matches that and avoids spurious undef-concat warnings from the
# generated code (values flow through suppress_value/_js_to_string).
sub _eval_source {
  my ( $self, $source ) = @_;
  my $props = do {
    no strict;      ## no critic
    no warnings;
    my $p = eval $source;    ## no critic (ProhibitStringyEval)
    die $@ if $@;
    $p;
  };
  return $props;
}

sub _get_blocks {
  my ( $self, $props ) = @_;
  my $blocks = {};

  for my $k ( @{ $self->_lib->keys($props) } ) {
    if ( substr( $k, 0, 2 ) eq 'b_' ) {
      $blocks->{ substr( $k, 2 ) } = $props->{$k};
    }
  }

  return $blocks;
}

1;

__END__

=synopsis

    my $tmpl = $env->get_template('page.njk');
    my $html = $tmpl->render( { title => 'Hi' } );

    my $tmpl = Text::Nunjucks::Template->new( 'Hello {{ name }}', $env, 'greeting.njk' );

=description

A template, compiled to Perl code on first use. Obtain one from
L<Text::Nunjucks::Environment/get_template>, or construct it yourself.

=head2 new

    Text::Nunjucks::Template->new( $src, $env, $path, $eager_compile );

Positional. C<$src> is the template's source as a string, or a hash reference
C<< { type => 'string', obj => $source } >> or, for a template that is already
compiled, C<< { type => 'code', obj => \%compiled } >> (what
L<Text::Nunjucks::Loader::Precompiled> hands out); any other C<type> dies.
C<$env> is the Environment whose filters, tests, globals and loaders the
template uses; without one a fresh default Environment is made. C<$path> is the
name shown in error messages. With a true C<$eager_compile> the template is
compiled now, and a syntax error dies here rather than on the first render.

=cut

=attr env

The L<Text::Nunjucks::Environment> the template belongs to.

=cut

=attr path

The path or name given at construction, shown in error messages.

=cut

=method render

    my $html = $tmpl->render( \%context );
    $tmpl->render( \%context, sub { my ( $err, $html ) = @_; ... } );

Renders the template. Compiles it first if needed. The return value, the death
on error and the callback form are those of C<render> of the Environment. The
context is copied, so the template's C<set> never changes the hash you passed.

=cut

=method compile

    $tmpl->compile;

Compiles the template if it is not compiled yet. A syntax error dies with the
raw L<Text::Nunjucks::Lib::TemplateError>, without the path and line prefix a
render adds (as C<compile> does in Nunjucks). Called by C<render>; call it yourself
to find errors early.

=cut

=method get_exported

    $tmpl->get_exported( \%context, sub { my ( $err, $exported ) = @_; ... } );

Runs the template and passes its callback the hash of the top-level variables
it exports, as C<import> and C<from ... import> read them. The callback is
required.

=cut

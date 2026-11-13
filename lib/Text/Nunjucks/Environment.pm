package Text::Nunjucks::Environment;
# ABSTRACT: 1:1 port of Nunjucks src/environment.js -- Environment, Context, Template

our $VERSION = '0.001';

use strict;
use warnings;
use builtin qw( true false );
use Scalar::Util qw( blessed );
use Text::Nunjucks::Lib;
use Text::Nunjucks::Lib::Error;
use Text::Nunjucks::Runtime;
use Text::Nunjucks::Compiler;
use Text::Nunjucks::Loader;
use Text::Nunjucks::Filters;

no warnings 'experimental::builtin';

# environment.js exports { Environment, Template } and defines Context internally;
# the porting map lists Text::Nunjucks::Environment / ::Context / ::Template, all
# from this one upstream file, so all three live here (like Runtime.pm keeps
# Frame/SafeString together). object.js's Obj/EmitterObj become Moo + the
# EmitterObj role (ADR 0002); the constructor's `this.init(...args)` indirection
# becomes a positional-args BUILDARGS feeding a faithful init() (so the file can
# still be reviewed method-for-method against environment.js).
#
# The compiler-emitted code (k15) calls into $env / $context / a Template through
# exactly the method surface built here; $runtime is passed as the class name
# 'Text::Nunjucks::Runtime' (class-method-only module), so $runtime->None,
# $runtime->Frame->new, $runtime->member_lookup(...) all resolve.
#
# PORTING-ORDER NOTES (flagged for the maintainer / k17 / k19):
#   * environment.js require()s ./filters, ./tests, ./globals and registers them
#     all in init. Filters are a plain load (`use` above, ADR 0015): exports($env)
#     builds the bag per Environment. Tests and globals still go through the
#     transitional guarded require of ADR 0015 (empty set if the module is
#     absent); Text::Nunjucks::Tests exists, Globals is k18.
#   * the no-loaders default (FileSystemLoader) and window.nunjucksPrecompiled
#     are k19 / browser and intentionally inert here.

#### callbackAsap -- upstream defers the callback via asap; Perl core has no event
#### loop, so the callback fires synchronously (ADR 0003). Kept as a named seam so
#### an event-loop binding can later make it truly async without touching callers.
sub _callback_asap {
  my ( $self, $cb, $err, $res ) = @_;
  $cb->( $err, $res );
  return;
}

#### noopTmplSrc -- a no-op template for {% include ignore missing %}
my $NOOP_TMPL_SRC = {
  type => 'code',
  obj  => {
    root => sub {
      my ( $env, $context, $frame, $runtime, $cb ) = @_;
      my $ok = eval { $cb->( undef, '' ); 1 };
      if ( !$ok ) { $cb->( $runtime->handle_error( $@, undef, undef ) ); }
    }
  }
};

package Text::Nunjucks::Environment {
  use Moo;
  with 'Text::Nunjucks::EmitterObj';
  use namespace::autoclean;
  use builtin qw( true false );
  use Scalar::Util qw( blessed );
  use Text::Nunjucks::Lib;
  use Text::Nunjucks::Runtime;

  no warnings 'experimental::builtin';

  # init's field set (upstream sets these on `this`). All rw: init assigns them.
  has opts            => ( is => 'rw' );
  has loaders         => ( is => 'rw' );
  has globals         => ( is => 'rw' );
  has filters         => ( is => 'rw' );
  has tests           => ( is => 'rw' );
  has async_filters   => ( is => 'rw' );
  has extensions      => ( is => 'rw' );
  has extensions_list => ( is => 'rw' );
  has _init_args      => ( is => 'ro' );

  # Collaborators named once, reached through the invocant (house rule).
  sub template_class   { 'Text::Nunjucks::Template' }
  sub _lib             { 'Text::Nunjucks::Lib' }
  sub _runtime_class   { 'Text::Nunjucks::Runtime' }
  sub _error_class     { 'Text::Nunjucks::Lib::Error' }
  sub filters_module   { 'Text::Nunjucks::Filters' }
  sub tests_module     { 'Text::Nunjucks::Tests' }
  sub globals_module   { 'Text::Nunjucks::Globals' }

  # constructor(...args) { this.init(...args) } -- positional (loaders, opts).
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
    my ( $self, $loaders, $opts ) = @_;

    # dev flag: the trace shown on errors (default false).
    $opts = $self->opts( $opts || {} );
    $self->opts->{dev} = $self->_runtime_class->_truthy( $opts->{dev} ) ? true : false;

    # autoescape: global autoescaping, default true. `!= null` keeps an explicit
    # false, defaults only for undefined/null.
    $self->opts->{autoescape} =
      ( defined( $opts->{autoescape} ) && !$self->_runtime_class->_is_none( $opts->{autoescape} ) )
      ? $opts->{autoescape}
      : true;

    $self->opts->{throwOnUndefined} = $self->_runtime_class->_truthy( $opts->{throwOnUndefined} ) ? true : false;
    $self->opts->{trimBlocks}       = $self->_runtime_class->_truthy( $opts->{trimBlocks} )       ? true : false;
    $self->opts->{lstripBlocks}     = $self->_runtime_class->_truthy( $opts->{lstripBlocks} )     ? true : false;

    $self->loaders( [] );

    if ( !$loaders ) {
      # Server-side default is [new FileSystemLoader('views')]; the concrete
      # FileSystem/Web loaders are k19, so -- like upstream's `if (FileSystemLoader)`
      # guard, which is false when the class is unavailable -- no loader is added.
    }
    else {
      $self->loaders( $self->_lib->is_array($loaders) ? $loaders : [$loaders] );
    }

    # window.nunjucksPrecompiled -- browser-only, out of scope.

    $self->_init_loaders;

    $self->globals( $self->_load_globals );
    $self->filters( {} );
    $self->tests( {} );
    $self->async_filters( [] );
    $self->extensions( {} );
    $self->extensions_list( [] );

    for my $pair ( @{ $self->_lib->_entries( $self->_load_filters ) } ) {
      $self->add_filter(@$pair);
    }
    for my $pair ( @{ $self->_lib->_entries( $self->_load_tests ) } ) {
      $self->add_test(@$pair);
    }
  }

  # Guarded require of the built-in bags (see PORTING-ORDER NOTES). A module that
  # is simply not ported yet -> empty set; any OTHER load error (a real syntax
  # error once the module exists) propagates rather than being masked.
  sub _load_builtin {
    my ( $self, $module, $method ) = @_;
    my $ok = eval "require $module; 1";    ## no critic (ProhibitStringyEval)
    return $module->$method if $ok;
    ( my $path = $module ) =~ s{::}{/}g;
    $path .= '.pm';
    die $@ unless $@ =~ /\QCan't locate $path\E/;    # absent -> empty
    return {};
  }

  # filters.js's exports, built for this Environment (ADR 0015: no guard)
  sub _load_filters { $_[0]->filters_module->exports( $_[0] ) }
  sub _load_tests   { $_[0]->_load_builtin( $_[0]->tests_module,   'exports' ) }
  sub _load_globals { $_[0]->_load_builtin( $_[0]->globals_module, 'globals' ) }

  sub _init_loaders {
    my ($self) = @_;
    for my $loader ( @{ $self->loaders } ) {
      # Caching and cache busting.
      $loader->cache( {} );
      if ( $loader->can('on') ) {
        $loader->on(
          'update',
          sub {
            my ( $name, $fullname ) = @_;
            $loader->cache->{$name} = undef;
            $self->emit( 'update', $name, $fullname, $loader );
          }
        );
        $loader->on(
          'load',
          sub {
            my ( $name, $source ) = @_;
            $self->emit( 'load', $name, $source, $loader );
          }
        );
      }
    }
  }

  sub invalidate_cache {
    my ($self) = @_;
    for my $loader ( @{ $self->loaders } ) {
      $loader->cache( {} );
    }
  }

  sub add_extension {
    my ( $self, $name, $extension ) = @_;
    $extension->{__name} = $name;    # extension.__name = name (k8/k22: object surface open)
    $self->extensions->{$name} = $extension;
    push @{ $self->extensions_list }, $extension;
    return $self;
  }

  sub remove_extension {
    my ( $self, $name ) = @_;
    my $extension = $self->get_extension($name);
    return unless $extension;

    $self->extensions_list( $self->_lib->without( $self->extensions_list, $extension ) );
    delete $self->extensions->{$name};
  }

  sub get_extension {
    my ( $self, $name ) = @_;
    return $self->extensions->{$name};
  }

  sub has_extension {
    my ( $self, $name ) = @_;
    return $self->extensions->{$name} ? 1 : 0;
  }

  sub add_global {
    my ( $self, $name, $value ) = @_;
    $self->globals->{$name} = $value;
    return $self;
  }

  sub get_global {
    my ( $self, $name ) = @_;
    if ( !defined $self->globals->{$name} ) {
      die $self->_error_class->new( 'global not found: ' . $name );
    }
    return $self->globals->{$name};
  }

  sub add_filter {
    my ( $self, $name, $func, $async ) = @_;
    my $wrapped = $func;
    if ( $self->_runtime_class->_truthy($async) ) {
      push @{ $self->async_filters }, $name;
    }
    $self->filters->{$name} = $wrapped;
    return $self;
  }

  sub get_filter {
    my ( $self, $name ) = @_;
    if ( !$self->filters->{$name} ) {
      die $self->_error_class->new( 'filter not found: ' . $name );
    }
    return $self->filters->{$name};
  }

  sub add_test {
    my ( $self, $name, $func ) = @_;
    $self->tests->{$name} = $func;
    return $self;
  }

  sub get_test {
    my ( $self, $name ) = @_;
    if ( !$self->tests->{$name} ) {
      die $self->_error_class->new( 'test not found: ' . $name );
    }
    return $self->tests->{$name};
  }

  sub resolve_template {
    my ( $self, $loader, $parent_name, $filename ) = @_;
    my $is_relative =
      ( $loader->can('is_relative') && $parent_name ) ? $loader->is_relative($filename) : 0;
    return ( $is_relative && $loader->can('resolve') )
      ? $loader->resolve( $parent_name, $filename )
      : $filename;
  }

  sub get_template {
    my ( $self, $name, $eager_compile, $parent_name, $ignore_missing, $cb ) = @_;
    my $that = $self;
    my $tmpl = undef;
    if ( $name && ref($name) eq 'HASH' && $name->{raw} ) {
      # this fixes autoescape for templates referenced in symbols
      $name = $name->{raw};
    }

    if ( $self->_lib->is_function($parent_name) ) {
      $cb          = $parent_name;
      $parent_name = undef;
      $eager_compile = $eager_compile || 0;
    }

    if ( $self->_lib->is_function($eager_compile) ) {
      $cb            = $eager_compile;
      $eager_compile = 0;
    }

    if ( blessed($name) && $name->isa( $self->template_class ) ) {
      $tmpl = $name;
    }
    elsif ( !$self->_lib->is_string($name) ) {
      die $self->_error_class->new( 'template names must be a string: ' . $name );
    }
    else {
      for my $loader ( @{ $self->loaders } ) {
        $tmpl = $loader->cache->{ $self->resolve_template( $loader, $parent_name, $name ) };
        last if $tmpl;
      }
    }

    if ($tmpl) {
      $tmpl->compile if $eager_compile;

      if ($cb) {
        $cb->( undef, $tmpl );
        return undef;
      }
      else {
        return $tmpl;
      }
    }
    my $sync_result;

    my $create_template = sub {
      my ( $err, $info ) = @_;
      if ( !$info && !$err && !$ignore_missing ) {
        $err = $self->_error_class->new( 'template not found: ' . $name );
      }

      if ($err) {
        if ($cb) {
          $cb->($err);
          return;
        }
        else {
          die $err;
        }
      }
      my $new_tmpl;
      if ( !$info ) {
        $new_tmpl = $self->template_class->new( $NOOP_TMPL_SRC, $self, '', $eager_compile );
      }
      else {
        $new_tmpl =
          $self->template_class->new( $info->{src}, $self, $info->{path}, $eager_compile );
        if ( !$info->{noCache} ) {
          $info->{loader}->cache->{$name} = $new_tmpl;
        }
      }
      if ($cb) {
        $cb->( undef, $new_tmpl );
      }
      else {
        $sync_result = $new_tmpl;
      }
    };

    $self->_lib->async_iter(
      $self->loaders,
      sub {
        my ( $loader, $i, $next, $done ) = @_;
        my $handle = sub {
          my ( $err, $src ) = @_;
          if ($err) {
            $done->($err);
          }
          elsif ($src) {
            $src->{loader} = $loader;
            $done->( undef, $src );
          }
          else {
            $next->();
          }
        };

        # Resolve name relative to parentName
        $name = $that->resolve_template( $loader, $parent_name, $name );

        if ( $loader->can('async') && $loader->async ) {
          $loader->get_source( $name, $handle );
        }
        else {
          $handle->( undef, $loader->get_source($name) );
        }
      },
      $create_template
    );

    return $sync_result;
  }

  # express(app) -- express-app.js is out of scope (not ported).

  sub render {
    my ( $self, $name, $ctx, $cb ) = @_;
    if ( $self->_lib->is_function($ctx) ) {
      $cb  = $ctx;
      $ctx = undef;
    }

    # Synchronous API: if nothing defers, the whole thing runs synchronously.
    my $sync_result = undef;

    $self->get_template(
      $name,
      sub {
        my ( $err, $tmpl ) = @_;
        if ( $err && $cb ) {
          $self->_callback_asap( $cb, $err );
        }
        elsif ($err) {
          die $err;
        }
        else {
          $sync_result = $tmpl->render( $ctx, $cb );
        }
      }
    );

    return $sync_result;
  }

  sub render_string {
    my ( $self, $src, $ctx, $opts, $cb ) = @_;
    if ( $self->_lib->is_function($opts) ) {
      $cb   = $opts;
      $opts = {};
    }
    $opts = $opts || {};

    my $tmpl = $self->template_class->new( $src, $self, $opts->{path} );
    return $tmpl->render( $ctx, $cb );
  }

  sub waterfall {
    my ( $self, $tasks, $callback, $force_async ) = @_;
    # Minimal a-sync-waterfall: run tasks in sequence, threading each task's
    # results into the next, first error short-circuits to the final callback.
    # Synchronous unless a task defers (ADR 0003); forceAsync is a no-op here.
    # Only compile_include emits waterfall -- no corpus case exercises it yet
    # (k18/k20 include/extends suites will), so the deep-recursion trampoline of
    # the real a-sync-waterfall is deferred.
    my @tasks = @$tasks;
    my $i     = 0;
    my $next;
    $next = sub {
      my ( $err, @args ) = @_;
      if ($err) {
        $callback->($err) if $callback;
        return;
      }
      if ( $i >= scalar @tasks ) {
        $callback->( undef, @args ) if $callback;
        return;
      }
      my $task = $tasks[ $i++ ];
      $task->( @args, $next );
    };
    $next->(undef);
    return;
  }
}

package Text::Nunjucks::Context {
  use Moo;
  use namespace::autoclean;
  use Text::Nunjucks::Lib;

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
}

package Text::Nunjucks::Template {
  use Moo;
  use namespace::autoclean;
  use Text::Nunjucks::Lib;
  use Text::Nunjucks::Runtime;
  use Text::Nunjucks::Compiler;

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
}

1;

__END__

=head1 NAME

Text::Nunjucks::Environment - the Nunjucks Environment, Context and Template

=head1 DESCRIPTION

A 1:1 port of Nunjucks C<src/environment.js>. Defines three classes from the one
upstream file: C<Text::Nunjucks::Environment> (loaders, filters/tests/globals/
extensions, C<render> / C<render_string>, C<get_template>),
C<Text::Nunjucks::Context> (per-render variable and block bookkeeping) and
C<Text::Nunjucks::Template> (lazy compile via C<eval> of the compiler's emitted
Perl source, root render wiring, C<get_exported>). The render API follows the
callback protocol of ADR 0003 / ADR 0009.

=cut

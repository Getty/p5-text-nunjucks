package Text::Nunjucks::Lib::TemplateError;
# ABSTRACT: Nunjucks TemplateError (src/lib.js) -- name is always 'Template render error'

use Moo;
use Scalar::Util qw( blessed );
use namespace::autoclean;

# 1:1 port of the TemplateError constructor / Update method in src/lib.js. The
# JS constructor is positional -- new TemplateError(message, lineno, colno) --
# and 'message' may itself be an Error, in which case it becomes the cause and
# the message turns into "${cause.name}: ${cause.message}". BUILDARGS mirrors
# that. Object.setPrototypeOf / Error.captureStackTrace / the stack + cause
# getters are JS-runtime plumbing with no Perl analogue and are not ported.

has message      => ( is => 'rw' );
has name         => ( is => 'ro', init_arg => undef, default => sub { 'Template render error' } );
has lineno       => ( is => 'ro' );
has colno        => ( is => 'ro' );
has cause        => ( is => 'ro' );
has first_update => ( is => 'rw', default => sub { 1 } );

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  return $class->$orig(@args) if @args == 1 && ref $args[0] eq 'HASH';

  my ( $message, $lineno, $colno ) = @args;
  my %attrs = ( lineno => $lineno, colno => $colno );

  # if (message instanceof Error) -- a caught error object we are wrapping
  if ( blessed($message) && $message->can('name') && $message->can('message') ) {
    $attrs{cause}   = $message;
    $attrs{message} = $message->name . ': ' . $message->message;
  } else {
    $attrs{message} = $message;
  }

  return $class->$orig(%attrs);
};

# err.Update(path) -- prepend the template path and, on the first update only,
# the line/column of the originating template.
sub update {
  my ( $self, $path ) = @_;

  # JS: '(' + (path || 'unknown path') + ')'  -- '' is falsy in JS too
  my $msg = '(' . ( ( defined $path && length $path ) ? $path : 'unknown path' ) . ')';

  # only show lineno + colno next to path of template where error occurred
  if ( $self->first_update ) {
    if ( $self->lineno && $self->colno ) {
      $msg .= ' [Line ' . $self->lineno . ', Column ' . $self->colno . ']';
    } elsif ( $self->lineno ) {
      $msg .= ' [Line ' . $self->lineno . ']';
    }
  }

  $msg .= "\n ";
  if ( $self->first_update ) {
    $msg .= ' ';
  }

  $self->message( $msg . ( $self->message // '' ) );
  $self->first_update(0);
  return $self;
}

1;

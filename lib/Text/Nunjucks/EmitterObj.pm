package Text::Nunjucks::EmitterObj;
# ABSTRACT: the on/emit surface of src/object.js EmitterObj, as a Moo role (ADR 0002)

our $VERSION = '0.001';

use Moo::Role;
use namespace::autoclean;

# object.js's EmitterObj extends node's EventEmitter; ADR 0002 replaces it with
# "a small role with on/emit". Only the subset the engine uses is modelled:
# Loader concrete subclasses emit('update'|'load', ...) and Environment listens
# via loader.on(...) and re-emits to its own listeners. No once/removeListener/
# error-event semantics are needed by the port, so none are provided.

has _listeners => ( is => 'ro', default => sub { {} } );

# emitter.on(event, listener) -- register a listener, return the emitter.
sub on {
  my ( $self, $event, $listener ) = @_;
  push @{ $self->_listeners->{$event} //= [] }, $listener;
  return $self;
}

# emitter.emit(event, ...args) -- call every listener in registration order.
sub emit {
  my ( $self, $event, @args ) = @_;
  my $listeners = $self->_listeners->{$event};
  return 0 unless $listeners && @$listeners;
  $_->(@args) for @$listeners;
  return 1;
}

1;

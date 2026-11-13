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

__END__

=description

A Moo role giving a class the C<on> / C<emit> pair of Node's C<EventEmitter>,
which upstream's C<EmitterObj> extends (ADR 0002). L<Text::Nunjucks::Loader>
and L<Text::Nunjucks::Environment> consume it. Only what the engine needs is
there: listeners are added with C<on> and called in order by C<emit>; there is
no C<once> and no way to remove a listener.

=cut

=method on

    $obj->on( $event, sub { my @args = @_; ... } );

Adds a listener for the event and returns the object.

=cut

=method emit

    $obj->emit( $event, @args );

Calls every listener of the event with C<@args>, in the order they were added.
Returns 1 when there was a listener, 0 when there was none.

=cut

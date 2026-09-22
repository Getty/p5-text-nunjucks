requires 'perl', '5.040';

requires 'Hash::Ordered';
requires 'JSON::MaybeXS';
requires 'Moo';
requires 'namespace::autoclean';

on test => sub {
  requires 'Path::Tiny';
  requires 'Test::More', '0.96';
};

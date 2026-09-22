requires 'perl', '5.040';

requires 'Hash::Ordered';
requires 'JSON::MaybeXS';
requires 'Moo';
requires 'Path::Tiny';
requires 'namespace::autoclean';

on test => sub {
  requires 'Test::More', '0.96';
};

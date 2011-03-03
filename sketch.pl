use strict;
use warnings;
use lib 'lib';
use AnyEvent;
use AnyEvent::DAAP::Server;
use Module::Reload;

my $daap = AnyEvent::DAAP::Server->new(port => 23689);
$daap->setup;

my $w; $w = AE::timer 1, 1, sub { Module::Reload->check };

AE::cv->wait;

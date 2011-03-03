use strict;
use warnings;
use lib 'lib';
use AnyEvent;
use AnyEvent::DAAP::Server;
use AnyEvent::DAAP::Server::Track;
use Module::Reload;

my $daap = AnyEvent::DAAP::Server->new(port => 23689);
$daap->tracks->{12321} = AnyEvent::DAAP::Server::Track->new(
    dmap_itemid   => 12321,
    dmap_itemname => 'title 1',
    dmap_containeritemid => 12345,
    dmap_itemkind => 2,
    dmap_persistentid => 54544,
);
$daap->setup;

my $w; $w = AE::timer 1, 1, sub { Module::Reload->check };

AE::cv->wait;

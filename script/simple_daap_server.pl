use strict;
use warnings;
use lib 'lib';
use AnyEvent;
use AnyEvent::DAAP::Server;
use AnyEvent::DAAP::Server::Track::File::MP3;
use File::Find::Rule;

my $daap = AnyEvent::DAAP::Server->new(port => 23689);

my $w; $w = AE::timer 1, 0, sub {
    foreach my $file (find name => "*.mp3", in => '.') {
        my $track = AnyEvent::DAAP::Server::Track::File::MP3->new(file => $file);
        $daap->add_track($track);
    }
    $daap->database_updated;
    undef $w;
};

$daap->setup;

AE::cv->wait;

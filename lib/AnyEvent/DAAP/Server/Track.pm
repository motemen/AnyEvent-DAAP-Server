package AnyEvent::DAAP::Server::Track;
use Any::Moose;
use Net::DAAP::DMAP;

# from Net::DAAP::Server::Track
our @Attributes = qw(
    dmap_itemid dmap_itemname dmap_itemkind dmap_persistentid
    daap_songalbum daap_songartist daap_songbitrate
    daap_songbeatsperminute daap_songcomment daap_songcompilation
    daap_songcomposer daap_songdateadded daap_songdatemodified
    daap_songdisccount daap_songdiscnumber daap_songdisabled
    daap_songeqpreset daap_songformat daap_songgenre
    daap_songdescription daap_songrelativevolume daap_songsamplerate
    daap_songsize daap_songstarttime daap_songstoptime daap_songtime
    daap_songtrackcount daap_songtracknumber daap_songuserrating
    daap_songyear daap_songdatakind daap_songdataurl
    com_apple_itunes_norm_volume
    daap_songgrouping daap_songcodectype daap_songcodecsubtype
    com_apple_itunes_itms_songid com_apple_itunes_itms_artistid
    com_apple_itunes_itms_playlistid com_apple_itunes_itms_composerid
    com_apple_itunes_itms_genreid
    dmap_containeritemid
);

has dmap_itemid => (
    is  => 'rw',
    isa => 'Int',
    default => sub { 0+$_[0] & 0xFFFFFF },
);

has $_, is => 'rw' for @Attributes;

__PACKAGE__->meta->make_immutable;

no Any::Moose;

sub _dmap_field {
    my ($self, $name) = @_;
    $name =~ s/[.-]/_/g;
    return $self->{$name};
}

sub stream {
    my ($self, $session) = @_;
    die 'implement';
    # stream data into $session->handle
}

1;

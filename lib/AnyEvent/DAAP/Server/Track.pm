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

sub allow_range { 0 }

sub data { die 'override' }

sub stream {
    my ($self, $connection, $req, $args) = @_;
    
    my $start;

    if (my $range = $req->header('Range')) {
        # To make things simple, assume Range: header is sent only as Range: bytes={start}-
        if ($range =~ /^bytes=(\d+)-/) {
            $start = $1;
        } elsif ($range) {
            warn qq(Cannot handle range: '$range');
        }
    }

    my ($code, $message) = $start ? ( 206, 'Partial Content' ) : ( 200, 'OK' );

    my $data = $self->data($start);
    my $receive_data = sub {
        my $data = shift;
        my $res = HTTP::Response->new(
            $code, $message, [
                'Connection' => 'close',
                'Content-Length' => length($data),
                $start ? ( 'Content-Range' => "bytes $start-/*" ) : (),
                $self->allow_range ? ( 'Accept-Ranges' => 'bytes' ) : (),
            ], $data
        );
        $connection->handle->push_write('HTTP/1.1 ' . $res->as_string("\r\n"));
        $connection->handle->push_shutdown;
    };
    if (ref $data eq 'CODE') {
        $data->($receive_data);
    } else {
        $receive_data->($data);
    }
}

1;

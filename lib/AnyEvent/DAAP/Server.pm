package AnyEvent::DAAP::Server;
use Any::Moose;
use AnyEvent::DAAP::Server::Connection;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Net::Rendezvous::Publish;
use Net::DAAP::DMAP qw(dmap_pack);
use HTTP::Request;
use Router::Simple;
use URI::QueryParam;

our $VERSION = '0.01';

has name => (
    is  => 'rw',
    isa => 'Str',
    default => sub { ref $_[0] },
);

has port => (
    is  => 'rw',
    isa => 'Int',
    default => 3689,
);

has rendezvous_publisher => (
    is  => 'rw',
    isa => 'Net::Rendezvous::Publish',
    default => sub { Net::Rendezvous::Publish->new },
);

has rendezvous_service => (
    is  => 'rw',
    isa => 'Net::Rendezvous::Publish::Service',
    lazy_build => 1,
);

sub _build_rendezvous_service {
    my $self = shift;
    return $self->rendezvous_publisher->publish(
        port => $self->port,
        name => $self->name,
        type => '_daap._tcp',
    );
}

has router => (
    is  => 'rw',
    isa => 'Router::Simple',
    default => sub { Router::Simple->new },
);

has db_id => (
    is => 'rw',
    default => '13950142391337751523', # XXX magic value (from Net::DAAP::Server)
);

has tracks => (
    is  => 'rw',
    isa => 'HashRef[AnyEvent::DAAP::Server::Track]',
    default => sub { +{} },
);

has global_playlist => (
    is  => 'rw',
    isa => 'AnyEvent::DAAP::Server::Playlist',
    default => sub { AnyEvent::DAAP::Server::Playlist->new },
);

has playlists => (
    is  => 'rw',
    isa => 'HashRef[AnyEvent::DAAP::Server::Playlist]',
    default => sub { +{} },
);

has revision => (
    is  => 'rw',
    isa => 'Int',
    default => 1,
);

has connections => (
    is  => 'rw',
    isa => 'ArrayRef[AnyEvent::DAAP::Server::Connection]',
    default => sub { +[] },
);

__PACKAGE__->meta->make_immutable;

no Any::Moose;

sub BUILD {
    my $self = shift;
    $self->add_playlist($self->global_playlist);
}

sub publish {
    my $self = shift;
    $self->rendezvous_service; # build
}

sub setup {
    my $self = shift;

    $self->router->connect(
        '/databases/{database_id}/items' => { method => '_database_items' },
    );
    $self->router->connect(
        '/databases/{database_id}/containers' => { method => '_database_containers' },
    );
    $self->router->connect(
        '/databases/{database_id}/containers/{container_id}/items' => { method => '_database_container_items' },
    );
    $self->router->connect(
        '/databases/{database_id}/items/{item_id}.*' => { method => '_database_item' },
    );

    $self->publish;

    tcp_server undef, $self->port, sub {
        my ($fh, $host, $port) = @_;
        my $connection = AnyEvent::DAAP::Server::Connection->new(server => $self, fh => $fh);
        $connection->handle->on_read(sub {
            my ($handle) = @_;
            $handle->push_read(
                regex => qr<\r\n\r\n>, sub {
                    my ($handle, $data) = @_;
                    my $request = HTTP::Request->parse($data);
                    my $path = $request->uri->path;
                    my $p = $self->router->match($path) || {};
                    my $method = $p->{method} || $path;
                    $method =~ s<[/-]><_>g;
                    $self->$method($connection, $request, $p);
                }
            );
        });
        push @{ $self->connections }, $connection;
    };
}

sub database_updated {
    my $self = shift;
    foreach my $connection (@{ $self->connections }) {
        $connection->pause_cv->send if $connection->pause_cv;
    }
    $self->{revision}++;
}

sub add_track {
    my ($self, $track) = @_;
    $self->tracks->{ $track->dmap_itemid } = $track;
    $self->global_playlist->add_track($track);
}

sub add_playlist {
    my ($self, $playlist) = @_;
    $self->playlists->{ $playlist->dmap_itemid } = $playlist;
}

### Handlers

sub _server_info {
    my ($self, $connection) = @_;
    $connection->respond_dmap([[
        'dmap.serverinforesponse' => [
            [ 'dmap.status'             => 200 ],
            [ 'dmap.protocolversion'    => 2 ],
            [ 'daap.protocolversion'    => '3.10' ],
            [ 'dmap.itemname'           => $self->name ],
            [ 'dmap.loginrequired'      => 0 ],
            [ 'dmap.timeoutinterval'    => 1800 ],
            [ 'dmap.supportsautologout' => 0 ],
            [ 'dmap.supportsupdate'     => 0 ],
            [ 'dmap.supportspersistentids' => 0 ],
            [ 'dmap.supportsextensions' => 0 ],
            [ 'dmap.supportsbrowse'     => 0 ],
            [ 'dmap.supportsquery'      => 0 ],
            [ 'dmap.supportsindex'      => 0 ],
            [ 'dmap.supportsresolve'    => 0 ],
            [ 'dmap.databasescount'     => 1 ],
        ]
    ]]);
}

sub _login {
    my ($self, $connection) = @_;
    $connection->respond_dmap([[
        'dmap.loginresponse' => [
            [ 'dmap.status'    => 200 ],
            [ 'dmap.sessionid' => 42 ], # XXX magic
        ]
    ]]);
}

sub _update {
    my ($self, $connection, $req) = @_;

    if ($req->uri->query_param('delta')) {
        my $cv = $connection->pause(sub {
            $connection->respond_dmap([[
                'dmap.updateresponse' => [
                    [ 'dmap.status'         => 200 ],
                    [ 'dmap.serverrevision' =>  $self->revision ],
                ]
            ]]);
        });
        my $w; $w = AE::timer 60, 0, sub { undef $w; $cv->send };
    } else {
        $connection->respond_dmap([[
            'dmap.updateresponse' => [
                [ 'dmap.status'         => 200 ],
                [ 'dmap.serverrevision' =>  $self->revision ],
            ]
        ]]);
    }
}

sub _databases {
    my ($self, $connection) = @_;

    $connection->respond_dmap([[
        'daap.serverdatabases' => [
            [ 'dmap.status' => 200 ],
            [ 'dmap.updatetype' =>  0 ],
            [ 'dmap.specifiedtotalcount' =>  1 ],
            [ 'dmap.returnedcount' => 1 ],
            [ 'dmap.listing' => [
                [ 'dmap.listingitem' => [
                    [ 'dmap.itemid' =>  35 ], # XXX magic
                    [ 'dmap.persistentid' => $self->db_id ],
                    [ 'dmap.itemname' => $self->name ],
                    [ 'dmap.itemcount' => scalar keys %{ $self->tracks } ],
                    [ 'dmap.containercount' =>  1 ],
                ] ],
            ] ],
        ]
    ]]);
}

sub _database_items {
    my ($self, $connection, $req, $args) = @_;
    # $args->{database_id};

    my @tracks = $self->_format_tracks_as_dmap($req, [ values %{ $self->tracks } ]);
    $connection->respond_dmap([[
        'daap.databasesongs' => [
            [ 'dmap.status' => 200 ],
            [ 'dmap.updatetype' => 0 ],
            [ 'dmap.specifiedtotalcount' => scalar @tracks ],
            [ 'dmap.returnedcount' => scalar @tracks ],
            [ 'dmap.listing' => \@tracks ]
        ]
    ]]);
}

sub _database_containers {
    my ($self, $connection, $req, $args) = @_;
    # $args->{database_id};

    my $playlists = [
        map { $_->as_dmap_struct } $self->global_playlist, values %{ $self->playlists }
    ];
    $connection->respond_dmap([[
        'daap.databaseplaylists' => [
            [ 'dmap.status'              => 200 ],
            [ 'dmap.updatetype'          =>   0 ],
            [ 'dmap.specifiedtotalcount' =>   1 ],
            [ 'dmap.returnedcount'       =>   1 ],
            [ 'dmap.listing'             => $playlists ],
        ]
    ]]);
}

sub _database_container_items {
    my ($self, $connection, $req, $args) = @_;
    # $args->{database_id}, $args->{container_id}

    # TODO global playlist
    my $playlist = $self->playlists->{ $args->{container_id} }
        or return $connection->respond(404);

    my @tracks = $self->_format_tracks_as_dmap($req, scalar $playlist->tracks);
    $connection->respond_dmap([[
        'daap.playlistsongs' => [
            [ 'dmap.status'              => 200 ],
            [ 'dmap.updatetype'          => 0 ],
            [ 'dmap.specifiedtotalcount' => scalar @tracks ],
            [ 'dmap.returnedcount'       => scalar @tracks ],
            [ 'dmap.listing'             => \@tracks ]
        ]
    ]]);
}

sub _database_item {
    my ($self, $connection, $req, $args) = @_;
    # $args->{database_id}, $args->{item_id}

    my $track = $self->tracks->{ $args->{item_id} }
        or return $connection->respond(404);

    $track->stream($connection);
}

sub _format_tracks_as_dmap {
    my ($self, $req, $tracks) = @_;

    my @fields = ( qw(dmap.itemkind dmap.itemid dmap.itemname), split /,|%2C/i, scalar $req->uri->query_param('meta') || '' );

    my @tracks;
    foreach my $track (@$tracks) {
        push @tracks, [
            'dmap.listingitem' => [ map { [ $_ => $track->_dmap_field($_) ] } @fields ]
        ]
    }

    return @tracks;
}

1;

__END__

=head1 NAME

AnyEvent::DAAP::Server -

=head1 SYNOPSIS

  use AnyEvent::DAAP::Server;

=head1 DESCRIPTION

AnyEvent::DAAP::Server is

=head1 AUTHOR

motemen E<lt>motemen@gmail.comE<gt>

=head1 SEE ALSO

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

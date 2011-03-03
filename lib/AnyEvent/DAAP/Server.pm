package AnyEvent::DAAP::Server;
use Any::Moose;
use Net::Rendezvous::Publish;
use Net::DAAP::DMAP qw(dmap_pack);
use AnyEvent::Socket;
use AnyEvent::Handle;
use HTTP::Request;
use HTTP::Response;
use Router::Simple;
use URI::QueryParam;

our $VERSION = '0.01';

has name => (
    is  => 'rw',
    isa => 'Str',
    default => __PACKAGE__, # TODO
);

has port => (
    is  => 'rw',
    isa => 'Int',
    default => 3689,
);

has httpd => (
    is  => 'rw',
    isa => 'AnyEvent::HTTPD',
    lazy_build => 1,
);

sub _build_httpd {
    my $self = shift;
    my $httpd = AnyEvent::HTTPD->new(port => $self->port);
    $httpd->reg_cb(
        '/server-info' => $self->_server_info,
        '/' => sub { warn "@_" },
    );
    return $httpd;
}

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

has db_id => is => 'rw', default => '13950142391337751523'; # FIXME copypaste
has tracks => is => 'rw', default => sub { +{} };

__PACKAGE__->meta->make_immutable;

no Any::Moose;

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
        my $handle = AnyEvent::Handle->new(fh => $fh);
        $handle->on_error(sub { warn "on_error @_" });
        $handle->on_eof(sub { warn "on_eof @_" });
        $handle->on_drain(sub { warn "on_drain @_" });
        $handle->on_read(sub {
            $handle->push_read(
                regex => qr<\r\n\r\n>, sub {
                    my ($handle, $data) = @_;
                    my $request = HTTP::Request->parse($data);
                    my $path = $request->uri->path;
                    my $p = $self->router->match($path) || {};
                    my $method = $p->{method} || $path;
                    $method =~ s<[/-]><_>g;
                    my $content = $self->$method($request, $p);
                    # TODO make async
                    my $response = HTTP::Response->new(
                        200, 'OK', [
                            'Content-Type' => 'application/x-dmap-tagged',
                            'Content-Length' => length($content)
                        ], $content,
                    );
                    $handle->push_write('HTTP/1.1 ' . $response->as_string("\r\n"));
                }
            );
        });
    };
}

sub _server_info {
    my $self = shift;
    return dmap_pack [[
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
    ]];
}

sub _login {
    my $self = shift;
    return dmap_pack [[
        'dmap.loginresponse' => [
            [ 'dmap.status'    => 200 ],
            [ 'dmap.sessionid' =>  42 ], # FIXME magic constant
        ]
    ]];
}

sub _update {
    my ($self, $req) = @_;
    # TODO block here by revision-nubmer
    return dmap_pack [[
        'dmap.updateresponse' => [
            [ 'dmap.status'         => 200 ],
            [ 'dmap.serverrevision' =>  1 ], # $self->revision ],
        ]
    ]];
}

sub _databases {
    my $self = shift;
    return dmap_pack [[
        'daap.serverdatabases' => [
            [ 'dmap.status' => 200 ],
            [ 'dmap.updatetype' =>  0 ],
            [ 'dmap.specifiedtotalcount' =>  1 ],
            [ 'dmap.returnedcount' => 1 ],
            [ 'dmap.listing' => [
                [ 'dmap.listingitem' => [
                    [ 'dmap.itemid' =>  35 ], # FIXME magic
                    [ 'dmap.persistentid' => $self->db_id ],
                    [ 'dmap.itemname' => $self->name ],
                    [ 'dmap.itemcount' => scalar keys %{ $self->tracks } ],
                    [ 'dmap.containercount' =>  1 ],
                ] ],
            ] ],
        ]
    ]];
}

sub _format_tracks_as_dmap {
    my ($self, $req) = @_;
    my @fields = qw(dmap.itemkind dmap.itemid dmap.itemname);
    push @fields, split /,|%2C/i, scalar $req->uri->query_param('meta') || '';

    my @tracks;
    foreach my $track (values %{ $self->tracks }) {
        push @tracks, [
            'dmap.listingitem' => [ map { [ $_ => $track->_dmap_field($_) ] } @fields ]
        ]
    }

    return @tracks;
}

sub _database_items {
    my ($self, $req, $args) = @_;
    # $args->{database_id};

    my @tracks = $self->_format_tracks_as_dmap($req);
    return dmap_pack [[
        'daap.databasesongs' => [
            [ 'dmap.status' => 200 ],
            [ 'dmap.updatetype' => 0 ],
            [ 'dmap.specifiedtotalcount' => scalar @tracks ],
            [ 'dmap.returnedcount' => scalar @tracks ],
            [ 'dmap.listing' => \@tracks ]
        ]
    ]];
}

sub _database_containers {
    my ($self, $req, $args) = @_;
    # $args->{database_id};

    # TODO

    my $playlists = [[
        'dmap.listingitem' => [
            [ 'dmap.itemid'       => 39 ],
            [ 'dmap.persistentid' => '13950142391337751524' ],
            [ 'dmap.itemname'     => $self->name ],
            [ 'com.apple.itunes.smart-playlist' => 0 ],
            [ 'dmap.itemcount'    => scalar keys %{ $self->tracks } ],
        ]
    ]];
    return dmap_pack [[
        'daap.databaseplaylists' => [
            [ 'dmap.status'              => 200 ],
            [ 'dmap.updatetype'          =>   0 ],
            [ 'dmap.specifiedtotalcount' =>   1 ],
            [ 'dmap.returnedcount'       =>   1 ],
            [ 'dmap.listing'             => $playlists ],
        ]
    ]];
}

sub _database_container_items {
    my ($self, $req, $args) = @_;
    # $args->{database_id}, $args->{container_id}

    my @tracks = $self->_format_tracks_as_dmap($req);
    return dmap_pack [[
        'daap.playlistsongs' => [
            [ 'dmap.status'              => 200 ],
            [ 'dmap.updatetype'          => 0 ],
            [ 'dmap.specifiedtotalcount' => scalar @tracks ],
            [ 'dmap.returnedcount'       => scalar @tracks ],
            [ 'dmap.listing'             => \@tracks ]
        ]
    ]];
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

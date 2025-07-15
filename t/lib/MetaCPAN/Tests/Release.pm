package MetaCPAN::Tests::Release;

use Test::Routine;

use version;

use HTTP::Request::Common     qw( GET );
use List::Util                ();
use MetaCPAN::ESConfig        qw( es_doc_path );
use MetaCPAN::Types::TypeTiny qw( ArrayRef HashRef Str );
use Test::More;

with qw( MetaCPAN::Tests::Query );

sub _build_type {'release'}

sub _build_search {
    my ($self) = @_;
    return {
        bool => {
            must => [
                { term => { author => $self->author } },
                { term => { name   => $self->name } },
            ]
        },
    };
}

around BUILDARGS => sub {
    my ( $orig, $self, @args ) = @_;
    my $attr = $self->$orig(@args);

    if (   !$attr->{distribution}
        && !$attr->{version}
        && $attr->{name}
        && $attr->{name} =~ /(.+?)-([0-9._]+)$/ )
    {
        @$attr{qw( distribution version )} = ( $1, $2 );
    }

    # We handle these specially.
    delete $attr->{_expect}{tests};
    delete $attr->{_expect}{modules};

    return $attr;
};

my @attrs = qw(
    author distribution version
);

has [@attrs] => (
    is  => 'ro',
    isa => Str,
);

has version_numified => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub {

        # This is much simpler than what we do in the indexer.
        # If we need to use Util we must need more tests.
        my $v = $_[0]->version;
        return 0 unless $v;
        return 'version'->parse($v)->numify + 0;
    },
);

has files => (
    is      => 'ro',
    isa     => ArrayRef,
    lazy    => 1,
    builder => '_build_files',
);

sub _build_files {
    my ($self) = @_;
    return $self->filter_files();
}

sub file_content {
    my ( $self, $file ) = @_;

    # Accept a file object (from es) or just a string path.
    my $path = ref $file ? $file->{path} : $file;

    # I couldn't get the Source model to work outside the app (I got
    # "No handler available for type 'application/octet-stream'",
    # strangely), so just do the http request.
    return $self->psgi_app( sub {
        shift->( GET "/source/$self->{author}/$self->{name}/$path" )->content;
    } );
}

sub file_by_path {
    my ( $self, $path ) = @_;
    my $file = List::Util::first { $_->{path} eq $path } @{ $self->files };
    ok $file, "found file '$path'";
    return $file;
}

has module_files => (
    is      => 'ro',
    isa     => ArrayRef,
    lazy    => 1,
    builder => '_build_module_files',
);

sub _build_module_files {
    my ($self) = @_;
    return $self->filter_files(
        [ { exists => { field => 'module.name' } }, ] );
}

sub filter_files {
    my ( $self, $add_filters ) = @_;

    $add_filters = [$add_filters]
        if $add_filters && ref($add_filters) ne 'ARRAY';

    my $release = $self->data;
    my $res     = $self->es->search(
        es_doc_path('file'),
        body => {
            query => {
                bool => {
                    must => [
                        { term => { 'author'  => $release->{author} } },
                        { term => { 'release' => $release->{name} } },
                        @{ $add_filters || [] },
                    ],
                },
            },
            size => 100,
        },
    );
    return [ map $_->{_source}, @{ $res->{hits}{hits} } ];
}

has modules => (
    is      => 'ro',
    isa     => HashRef,
    default => sub { +{} },
);

sub pod {
    my ( $self, $path, $type ) = @_;
    my $query = $type ? "?content-type=$type" : q[];
    return $self->psgi_app( sub {
        shift->( GET "/pod/$self->{author}/$self->{name}/${path}${query}" )
            ->content;
    } );
}

# The default status for a release is 'cpan'
# but many test dists only have one version so 'latest' is more likely.
has status => (
    is      => 'ro',
    isa     => Str,
    default => 'latest',
);

has archive => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub { shift->name . '.tar.gz' },
);

has name => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub {
        my ($self) = @_;
        $self->distribution . q[-] . $self->version;
    },
);

has tests => (
    is        => 'ro',
    predicate => 'expects_tests',
);

sub has_tests_ok {
    my ($self) = @_;
    my $tests = $self->data->{tests};

    # Don't test the actual numbers since we copy this out of the real
    # database as a live test case.

    is ref($tests), 'HASH', 'hashref of tests';

    my @results = qw( pass fail na unknown );

    ok exists( $tests->{$_} ), "has '$_' results" for @results;

    ok List::Util::sum( map { $tests->{$_} } @results ) > 0,
        'has some results';
}

push @attrs, qw( version_numified status archive name );

test 'release attributes' => sub {
    my ($self) = @_;

    foreach my $attr (@attrs) {
        is $self->data->{$attr}, $self->$attr, "release $attr";
    }

    if ( $self->expects_tests ) {
        if ( $self->tests eq '1' ) {
            $self->has_tests_ok;
        }
        else {
            is_deeply $self->data->{tests}, $self->tests, 'test results';
        }
    }
};

test 'modules in Packages-1.103' => sub {
    my ($self) = @_;

    plan skip_all => 'No modules specified for testing'
        unless scalar keys %{ $self->modules };

    my %module_files
        = map { ( $_->{path} => $_->{module} ) } @{ $self->module_files };

    foreach my $path ( sort keys %{ $self->modules } ) {
        my $desc        = "File '$path' has expected modules";
        my $got_modules = delete $module_files{$path} || [];
        my $got         = [ map +{%$_}, @$got_modules ];
        $_->{associated_pod} //= undef for @$got;

     # We may need to sort modules by name, I'm not sure if order is reliable.
        is_deeply $got, $self->modules->{$path}, $desc
            or diag Test::More::explain($got);
    }

    is( scalar keys %module_files, 0, 'all module files tested' )
        or diag Test::More::explain \%module_files;
};

1;

package MetaCPAN::Script::Contributor;

use strict;
use warnings;

use Moose;

use Log::Contextual qw( :log );

use MetaCPAN::Types::TypeTiny qw( Bool HashRef Int Str );

with 'MetaCPAN::Role::Script', 'MooseX::Getopt',
    'MetaCPAN::Script::Role::Contributor';

has all => (
    is            => 'ro',
    isa           => Bool,
    default       => 0,
    documentation => 'update contributors for *all* releases',
);

has distribution => (
    is            => 'ro',
    isa           => Str,
    documentation =>
        'update contributors for all releases matching distribution name',
);

has release => (
    is            => 'ro',
    isa           => Str,
    documentation =>
        'update contributors for a single release (format: author/release_name)',
);

has age => (
    is            => 'ro',
    isa           => Int,
    documentation => 'update contributors for a given number of days back',
);

has author_release => (
    is      => 'ro',
    isa     => HashRef,
    lazy    => 1,
    builder => '_build_author_release',
);

sub _build_author_release {
    my $self = shift;
    return unless $self->release;
    my ( $author, $release ) = split m{/}, $self->release;
    $author && $release
        or die
        "Error: invalid 'release' argument (format: PAUSEID/DISTRIBUTION-VERSION)";
    return +{
        author  => $author,
        release => $release,
    };
}

sub run {
    my $self = shift;

    my $query
        = $self->all ? { match_all => {} }
        : $self->distribution
        ? { term => { distribution => $self->distribution } }
        : $self->release ? {
        bool => {
            must => [
                { term => { author => $self->author_release->{author} } },
                { term => { name   => $self->author_release->{release} } },
            ]
        }
        }
        : $self->age
        ? { range => { date => { gte => sprintf( 'now-%dd', $self->age ) } } }
        : return;

    $self->update_contributors($query);
}

__PACKAGE__->meta->make_immutable;
1;

__END__

=head1 SYNOPSIS

 # bin/metacpan contributor --all
 # bin/metacpan contributor --distribution Moose
 # bin/metacpan contributor --release ETHER/Moose-2.1806

=head1 DESCRIPTION

Update the list of contributors (CPAN authors only) of all/matching
releases in the 'contributor' type (index).

=cut

use strict;
use warnings;
use lib 't/lib';

use MetaCPAN::Server::Test qw( es_result );
use MetaCPAN::Util         qw(true false);
use Test::More;

my $release = es_result(
    release => {
        bool => {
            must => [
                { term => { author => 'LOCAL' } },
                { term => { name   => 'Multiple-Modules-1.01' } },
            ]
        },
    }
);

is( $release->{abstract}, 'abstract', 'abstract set from Multiple::Modules' );

is( $release->{name}, 'Multiple-Modules-1.01', 'name ok' );

is( $release->{author}, 'LOCAL', 'author ok' );

is( $release->{main_module}, 'Multiple::Modules', 'main_module ok' );

is_deeply(
    [ sort @{ $release->{provides} } ],
    [
        sort 'Multiple::Modules', 'Multiple::Modules::A',
        'Multiple::Modules::A2',  'Multiple::Modules::B'
    ],
    'provides ok'
);

# This test depends on files being indexed in the right order
# which depends on the mtime of the files.
ok( !$release->{first}, 'Release is not first' );

{
    my @files = es_result(
        file => {
            bool => {
                must => [
                    { term   => { author  => $release->{author} } },
                    { term   => { release => $release->{name} } },
                    { exists => { field   => 'module.name' } },
                ],
            },
        },
    );
    is( @files, 3, 'includes three files with modules' );

    @files = sort { $a->{name} cmp $b->{name} } @files;

    foreach my $test (
        [
            'A.pm',
            'Multiple::Modules::A',
            [
                { name => 'Multiple::Modules::A',  indexed => true },
                { name => 'Multiple::Modules::A2', indexed => true },
            ]
        ],
        [
            'B.pm',
            'Multiple::Modules::B',
            [
                { name => 'Multiple::Modules::B', indexed => true },

              #{name => 'Multiple::Modules::_B2', indexed => false }, # hidden
                { name => 'Multiple::Modules::B::Secret', indexed => false },
            ]
        ],
        [
            'Modules.pm',
            'Multiple::Modules',
            [ { name => 'Multiple::Modules', indexed => true }, ]
        ],
        )
    {
        my ( $basename, $doc, $expmods ) = @$test;

        my $file = shift @files;
        is( $file->{name},          $basename, 'file name' );
        is( $file->{documentation}, $doc,      'documentation ok' );

        is(
            scalar @{ $file->{module} },
            scalar @$expmods,
            'correct number of modules'
        );

        foreach my $expmod (@$expmods) {
            my $mod = shift @{ $file->{module} };
            if ( !$mod ) {
                ok( 0, "module not found when expecting: $expmod->{name}" );
                next;
            }
            is( $mod->{name}, $expmod->{name}, 'module name ok' );
            is( $mod->{indexed}, $expmod->{indexed},
                'module indexed (or not)' );
        }

        is( scalar @{ $file->{module} }, 0, 'all mods tested' );
    }
}

$release = es_result(
    release => {
        bool => {
            must => [
                { term => { author => 'LOCAL' } },
                { term => { name   => 'Multiple-Modules-0.1' } },
            ],
        },
    },
);
ok $release,          'got older version of release';
ok $release->{first}, 'this version was first';

my $file = es_result(
    file => {
        bool => {
            must => [
                { term         => { release => 'Multiple-Modules-0.1' } },
                { match_phrase => { documentation => 'Moose' } },
            ],
        },
    }
);

ok( $file, 'get Moose.pm' );

ok( my ($moose) = ( grep { $_->{name} eq 'Moose' } @{ $file->{module} } ),
    'find Moose module in old release' )
    or diag( Test::More::explain( { file_module => $file->{module} } ) );

$moose
    and ok( !$moose->{authorized}, 'Moose is not authorized' );

$release
    and ok( !$release->{authorized}, 'release is not authorized' );

done_testing;

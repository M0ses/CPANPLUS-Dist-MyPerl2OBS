use 5.006;
use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'CPANPLUS::Dist::MyPerl2OBS',
    license             => 'perl',
    dist_author         => q{Frank Schreiner <m0ses+cpan@samaxi.de>},
    dist_version_from   => 'lib/CPANPLUS/Dist/MyPerl2OBS.pm',
    dist_abstract   	=> 'To build your own perl distribution modules ',
    build_requires => {
        'Test::More' => 0,
    },
    requires => {
        'perl' => 5.006,
        'YUM::Repo' => 0,
    },
    add_to_cleanup    => [ 'CPANPLUS-Dist-MyPerl2OBS-*' ],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();

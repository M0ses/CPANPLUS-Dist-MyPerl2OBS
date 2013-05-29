#!perl

use Test::More tests => 1;

BEGIN {
    use_ok( 'CPANPLUS::Dist::MyPerl2OBS' ) || print "Bail out!\n";
}

diag( "Testing CPANPLUS::Dist::MyPerl2OBS $CPANPLUS::Dist::MyPerl2OBS::VERSION, Perl $], $^X" );

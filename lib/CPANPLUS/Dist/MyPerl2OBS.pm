package CPANPLUS::Dist::MyPerl2OBS;

use warnings;
use strict;
use base 'CPANPLUS::Dist::Base';

use English;
# imports error(), msg()
use CPANPLUS::Error;
use IPC::Cmd         qw{ run can_run };
use Path::Class;
use SUPER;
use File::Copy;
use File::Path;
use File::Basename;
use File::Find::Rule;
use Data::Section -setup;
use Cwd;

use XML::Simple;
use LWP::UserAgent;
use Config::General;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError) ;
use YUM::Repo;


use List::Util       qw{ first };
use List::MoreUtils  qw{ uniq };
use Path::Class;
use Pod::POM;
use Pod::POM::View::Text;
use POSIX           qw{ strftime locale_h};
use Readonly;
use Software::LicenseUtils;
use Text::Autoformat;
use Template;

# Set locale to en_US.UTF8 so that dates in changelog will be correct
# if using another locale. Also ensures writing out UTF8. (Thanks to
# Roy-Magne Mo for pointing out the problem and providing a solution.)
setlocale(LC_ALL, "en_US.UTF-8");


 
=head1 NAME

CPANPLUS::Dist::MyPerl2OBS - To build your own perl distribution modules 	 

=head1 VERSION

0.000100

=cut

our $VERSION = '0.000101';

Readonly my $RPMDIR => do { chomp(my $d=qx[ rpm --eval %_topdir ]); $d; };
Readonly my $PACKAGER =>
    do { my $d = `rpm --eval '%{packager}'`; chomp $d; $d };
Readonly my $DEFAULT_LICENSE => 'CHECK(GPL+ or Artistic)';
Readonly my $DIR => cwd;



=head1 SYNOPSIS

CPANPLUS::Dist::MyPerl2OBS is a distribution class to create a package 
skeleton which can be use by openbuildservice from CPAN modules, 
and all its dependencies. This allows you to have the most recent copies
of CPAN modules installed, using your rpm package manager,
but without having to wait for central repositories to be updated.

You can use these skeletons to build packages for your own perl 
distribution (e.g. my-perl) without dependency collisions in rpm
with the packages of your Linux Distribution. It uses its own namespace 
for dependencies (requires/provides/obsoletes ...)

This is a simple module which inherits from CPANPLUS::Dist::Base and 
allows you to create RPM spec files.
In particular, this RPM spec file has been tested in SLES 11.

It also honors Module::Build if Build.PL is in the distribution.

Simple way of creating and installing a module is:

 cpan2dist --verbose --format CPANPLUS::Dist::MyPerl2OBS --buildprereq <Package::To::Install>



=head1 SUBROUTINES/METHODS

=head2 format_available

Checks if /etc/SuSE-release file exists

=cut

=head2 init 

generates generic accessors

=cut
sub init {
	my $self = shift @_;

	# e.g...
	# distname: Foo-Bar
	# distvers: 1.23
	# extra_files: qw[ /bin/foo /usr/bin/bar ] 
	# rpmname:     perl-Foo-Bar
	# rpmpath:     $RPMDIR/RPMS/noarch/perl-Foo-Bar-1.23-1mdv2008.0.noarch.rpm
	# rpmvers:     1
	# rpmdir:      $DIR
	# srpmpath:    $RPMDIR/SRPMS/perl-Foo-Bar-1.23-1mdv2008.0.src.rpm
	# specpath:    $RPMDIR/SPECS/perl-Foo-Bar.spec
	# is_noarch:   true if pure-perl
	# license:     try to figure out the actual license
	# summary:     one-liner summary
	# description: a paragraph summary or so

	$self->status->mk_accessors(
		qw{ 
			distname distvers extra_files rpmname rpmpath rpmvers 
			rpmdir srpmpath specpath is_noarch license summary 
			description packager license_comment
		  }
	);

	return 1;
}

sub format_available {
    return super;
}

# my $bool = $self->_has_been_built;
#
# Returns true if there's already a package built for this module.
#
sub _has_been_built {
    my ($self, $name, $vers) = @_;

    # FIXME this entire method should be overridden to first check the local
    # rpmdb, then check the yum repos via repoquery.  As is we're pretty
    # broken right now
    #
    # For now, just call super
    return super;
}


=head2 install

Overrides the install method of Base to make no installation, but
set status to success

=cut

sub install {
    my $self = shift @_;
    return $self->status->installed(1);
}


sub _is_module_build_compat {
    my $self   = shift @_;
    my $module = shift @_ || $self->parent;

    my $makefile = $module->_status->extract . '/Makefile.PL';
    #my $buildfile = $module->_status->extract . '/Build.PL';
    if (! -f $makefile) {
	return 0;
    }
    $makefile = file $makefile;
    my $content  = $makefile->slurp;

    return $content =~ /Module::Build::Compat/;
}

sub _mk_pkg_name {
    my ($self, $dist) = @_;

    # use our our dist name if we're not passed one.
    $dist = $self->status->distname if not defined $dist;
    my $conf = $self->_get_my_config;
	my $pkg_ns = $conf->{PKG_NAMESPACE} || 'my-perl-';

    return $pkg_ns.$dist;
}

sub _parse_args {
    my $self = shift @_;
    my %args = @_;
    my $conf = $self->parent->parent->configure_object;

    # parse args.
    my %opts = (
        force   => $conf->get_conf('force'),  # force rebuild
        perl    => $^X,
        verbose => $conf->get_conf('verbose'),
        %args,
    );

    return %args;
}

=head2 create

check status and create package via SUPER class if required

=cut

sub create {
    my $self = shift @_;
    my %opts = $self->_parse_args(@_);

    my $status = $self->status;               # private hash
    my $module = $self->parent;               # CPANPLUS::Module
    my $intern = $module->parent;             # CPANPLUS::Internals
    my $conf   = $intern->configure_object;   # CPANPLUS::Configure
    my $distmm = $module->status->dist_cpan;  # CPANPLUS::Dist::MM
	#
    # check if we need to rebuild package.
	 if ($status->created && defined $status->dist) {
        return $status->dist;
	 }

		$self->SUPER::create(@_);

    return $status->created;
}

sub _prepare_spec {
    my $self = shift @_;

    # Prepare our template
    #my $tmpl = Template->new({ EVAL_PERL => 1 });
    my $tmpl = Template->new;
    my $conf = $self->_get_my_config;

    # Process template into spec
    $tmpl->process(
        $self->section_data('spec'),
        {  
            status    => $self->status,
            module    => $self->parent,
            buildreqs => $self->_buildreqs,
            date      => strftime("%a %b %d %Y", localtime),
            packager  => $PACKAGER,
            docfiles  => join(' ', @{ $self->_docfiles }),
			perl_package => $conf->{PERL_PACKAGE} || 'my-perl',
            packagervers => $VERSION,
			pkg_deps_ns => $conf->{PKG_DEPS_NS} || 'myPerl',
        },
        $self->status->specpath,
    );
}


sub _prepare_status {
    my $self = shift @_;

    my $status = $self->status;               # Private hash
    my $module = $self->parent;               # CPANPLUS::Module
    my $intern = $module->parent;             # CPANPLUS::Internals
    my $conf   = $intern->configure_object;   # CPANPLUS::Configure
    my $distmm = $module->status->dist_cpan;  # CPANPLUS::Dist::MM

    # Compute & store package information
    $status->distname($module->package_name);
    $status->rpmdir($DIR);
    $status->rpmname($self->_mk_pkg_name);
    $status->distvers($module->package_version);
    $status->summary($self->_module_summary($module));
    $status->description(autoformat $self->_module_description($module));
    $status->rpmvers('0');    # FIXME probably need make this malleable
    $status->is_noarch($self->_is_noarch);

    # _module_license sets both license and license_comment
    #$status->license($self->_module_license($module));
    $self->_module_license($module);

    $status->specpath(
		$status->rpmdir . '/' . 
		$status->rpmname .'/' . 
		$status->rpmname . '.spec'
    );
	msg(" Using specpath: ".$status->specpath);
	my $sum = $status->summary();
	$sum =~ s/\.\s*$//;
	$sum = ucfirst($sum);
	$status->summary($sum);
   
    return;
}

sub _build_rpm {
	my $self=shift;
	msg("DEBUG FS ... skipping build of ".$self->name);
	return(1,'');
}	

=head2 prepare

prepares status of object and specfile

=cut
sub prepare {
    my $self = shift @_;
    my %opts = $self->_parse_args(@_);
    my $confFile = $opts{'--config-file'} || $ENV{HOME}."/.cpan2dist.rc";
    my $status = $self->status;               # Private hash
    my $module = $self->parent;               # CPANPLUS::Module
    my $intern = $module->parent;             # CPANPLUS::Internals
    my $conf   = $intern->configure_object;   # CPANPLUS::Configure
    my $distmm = $module->status->dist_cpan;  # CPANPLUS::Dist::MM

    $self->_prepare_status;

    if ($self->_package_exists($confFile)) {
    	# Dry-run with makemaker: find build prereqs.
   	# msg( "dry-run prepare with makemaker..." );

    # check whether package has been built
        my $modname = $self->parent->module;
        my $rpmname = $status->rpmname;

        msg( "'$rpmname' is already installed (for $modname)" );

        if (!$opts{force}) {
            msg( "won't re-spec package since --force isn't in use" );
            # c::d::rpm store
            #$status->rpmpath($pkg); # store the path of rpm
            # cpanplus api
            $status->prepared(1);
            $status->created(1);
            $status->installed(1); # right?
            $status->dist($rpmname);
            return $rpmname;
            # XXX check if it works
        }

        msg( '--force in use, re-specing anyway' );
        # FIXME: bump rpm release
    }
    else {
        msg( "writing specfile for '".$status->distname."'..." );
    }

    $self->SUPER::prepare(@_);
    # populate our status object

    # create the specfile
    $self->_prepare_spec;

    # copy package.
    my $tarname 	= basename($module->status->fetch);
    my $tarball  	= $status->rpmdir . '/' . $tarname;
    my $srcTar 		= $module->status->fetch;
    my $destDir 	= dirname($self->status->specpath); 
    my $tar_dest 	= file($destDir,$tarname);

    msg ". Moving tarfile from $srcTar to $tar_dest";

    if (! -d $destDir ) {
	    mkpath($destDir) ||
		error "Error while creating directory: $!";
    }

    move($srcTar,$tar_dest) || 
    	error "Error while moving file: $!"; 

    if ( -f $tarball ) {
	    unlink($tarball) || 
	    	error "Error while unlinking $tarball";
    }	    

    msg ".. specfile for '" . $status->distname . "' written";

    # return success
    return $status->prepared(1);
}

sub _get_my_config {
	my $self = shift;
	my $cnf = shift || $ENV{HOME}."/.cpan2dist.rc";
	# parse config
	 
	if ( ref($CPANPLUS::Dist::MyPerl2OBS::_config) eq 'HASH') {
		msg(" using cached config");
		return $CPANPLUS::Dist::MyPerl2OBS::_config;
	}	

	msg("Using config file: $cnf");
	my $conf = new Config::General($cnf);
	my %config = $conf->getall;
	my $PACKAGE = __PACKAGE__;
	msg("Using ns: $PACKAGE");

	$CPANPLUS::Dist::MyPerl2OBS::_config = $config{$PACKAGE} || {};

	return $CPANPLUS::Dist::MyPerl2OBS::_config;
}

sub _package_exists {
	my $self = shift;
	my $cnf = shift;
	my $status = $self->status;                 # Private hash
	my $module = $self->parent;
	my @repo_urls;
	$self->_get_my_config($cnf);

	my $myconfig = $self->_get_my_config();
	if (! exists($myconfig->{REPO_URL})) {
		return 0;
	}
	if ( ref($myconfig->{REPO_URL}) eq 'ARRAY' ) {
		push(@repo_urls,@{$myconfig->{REPO_URL}})
	} else {
		push(@repo_urls,$myconfig->{REPO_URL})
	}

	if ( ref($CPANPLUS::Dist::MyPerl2OBS::pkgStore) ne 'ARRAY' ) {
		$CPANPLUS::Dist::MyPerl2OBS::pkgStore=[];
		foreach my $repo_url (@repo_urls) {
			my $yum = YUM::Repo->new(uri=>$repo_url);
			$yum->repomd_xml();
			$yum->primary->open_xml;
			push(@{$CPANPLUS::Dist::MyPerl2OBS::pkgStore},$yum);
		}
	}	

	my $prefix = $myconfig->{PKG_DEPS_NS} || 'myPerl';
	my $template = '%s(%s)';

	# e.g. prov_string = 'myPerl(My::Package)'
	my $prov_string = sprintf($template,$prefix,$module->module);

	msg("Checking for packages which provide $prov_string");

	foreach my $yum (@{$CPANPLUS::Dist::MyPerl2OBS::pkgStore}) {
		my $wp = $yum->who_provides($prov_string);
		msg(" who_provides: @{$wp}");
		return 1 if (@{$wp});
	}

	return 0
}

my %shortname = (

    # classname                         => shortname
    'Software::License::AGPL_3'         => 'AGPLv3',
    'Software::License::Apache_1_1'     => 'ASL 1.1',
    'Software::License::Apache_2_0'     => 'ASL 2.0',
    'Software::License::Artistic_1_0'   => 'Artistic',
    'Software::License::Artistic_2_0'   => 'Artistic 2.0',
    'Software::License::BSD'            => 'BSD',
    'Software::License::FreeBSD'        => 'BSD',
    'Software::License::GFDL_1_2'       => 'GFDL',
    'Software::License::GPL_1'          => 'GPL',
    'Software::License::GPL_2'          => 'GPLv2',
    'Software::License::GPL_3'          => 'GPLv3',
    'Software::License::LGPL_2_1'       => 'LGPLv2',
    'Software::License::LGPL_3_0'       => 'LGPLv3',
    'Software::License::MIT'            => 'MIT',
    'Software::License::Mozilla_1_0'    => 'MPLv1.0',
    'Software::License::Mozilla_1_1'    => 'MPLv1.1',
    'Software::License::Perl_5'         => 'GPL+ or Artistic',
    'Software::License::QPL_1_0'        => 'QPL',
    'Software::License::Sun'            => 'SPL',
    'Software::License::Zlib'           => 'zlib',
);

sub _module_license { 
    my $self = shift @_;

    my $module = $self->parent;
    
    my $lic_comment = q{};
    
    # First, check what CPAN says
    my $cpan_lic = $module->details->{'Public License'};

    ### $cpan_lic

    # then, check META.yml (if existing)
    my $extract_dir = dir $module->extract;
    my $meta_file   = file $extract_dir, 'META.yml';
    my @meta_lics;

    if (-e "$meta_file" && -r _) {

        my $meta = $meta_file->slurp;
        @meta_lics = 
            Software::LicenseUtils->guess_license_from_meta_yml($meta);
    }
        
    # FIXME we pretty much just ignore the META.yml license right now

    ### @meta_lics

    # then, check the pod in all found .pm/.pod's
    my $rule = File::Find::Rule->new;
    my @pms = File::Find::Rule
        ->or(
            File::Find::Rule->new->directory->name('blib')->prune->discard,
            File::Find::Rule->new->file->name('*.pm', '*.pod')
            )
        ->in($extract_dir)
        ;

    my %pm_lics;

    for my $file (@pms) {

        $file = file $file;
        #my $text = file($file)->slurp;
        my $text = $file->slurp;
        my @lics = Software::LicenseUtils->guess_license_from_pod($text);

        ### file: "$file"
        ### @lics
        
        #push @pm_lics, @lics;
        $pm_lics{$file->relative($extract_dir)} = [ @lics ]
            if @lics > 0;
    }

    ### %pm_lics

    my @lics;

    for my $file (sort keys %pm_lics) {

       my @file_lics = map { $shortname{$_} } @{$pm_lics{"$file"}};

       $lic_comment .= "# $file -> " . join(q{, }, @file_lics) . "\n";
       push @lics, @file_lics;
    }

    # FIXME need to sort out the licenses here
    @lics = uniq @lics;

    ### $lic_comment
    ### @lics

    if ( @lics > 0 && $lics[0] ) {

        $self->status->license(join(' or ', @lics));
        $self->status->license_comment($lic_comment);
    }
    else {
        
        $self->status->license($DEFAULT_LICENSE);
        $self->status->license_comment("# license auto-determination failed\n");
    }

    ### license: $self->status->license
    return;
}

#
# my $description = _module_description($module);
#
# given a cpanplus::module, try to extract its description from the
# embedded pod in the extracted files. this would be the first paragraph
# of the DESCRIPTION head1.
#
sub _module_description {
    my ($self, $module) = @_;

    # where tarball has been extracted
    my $path   = dirname $module->_status->extract;
    my $parser = Pod::POM->new;

    my @docfiles =
        map  { "$path/$_" }               # prepend extract directory
        sort { length $a <=> length $b }  # sort by length
        grep { /\.(pod|pm)$/ }            # filter potentially pod-containing
        @{ $module->_status->files };     # list of embedded files

    my $desc;

    # parse file, trying to find a header
    DOCFILE:
    foreach my $docfile ( @docfiles ) {

        # extract pod; the file may contain no pod, that's ok
        my $pom = $parser->parse_file($docfile);
        next DOCFILE unless defined $pom; 

        HEAD1:
        foreach my $head1 ($pom->head1) {

            next HEAD1 unless $head1->title eq 'DESCRIPTION';

            my $pom  = $head1->content;
            my $text = $pom->present('Pod::POM::View::Text');
            
            # limit to 3 paragraphs at the moment
            my @paragraphs = (split /\n\n/, $text)[0..2]; 
            #$text = join "\n\n", @paragraphs;
            $text = q{};
            for my $para (@paragraphs) { $text .= $para }

	    # autoformat will try to read from STDIN if $text is empty
	    $text = $text || "No Description found in Module";

            # autoformat and return...

            return autoformat $text, { all => 1 };
        }
    }

    return 'no description found';
}


#
# my $summary = _module_summary($module);
#
# given a cpanplus::module, return its registered description (if any)
# or try to extract it from the embedded pod in the extracted files.
#
sub _module_summary {
    my ($self, $module) = @_;

    # registered modules won't go farther...
    return $module->description if $module->description;

    my $path = dirname $module->_status->extract;

    my @docfiles =
        map  { "$path/$_" }               # prepend extract directory
        sort { length $a <=> length $b }  # we prefer top-level module summary
        grep { /\.(pod|pm)$/ }            
        @{ $module->_status->files };     # list of files embedded

    # parse file, trying to find a header
    my $parser = Pod::POM->new;
    DOCFILE:
    foreach my $docfile ( @docfiles ) {

        my $pom = $parser->parse_file($docfile);  
        next unless defined $pom;                 # no pod, that's ok
    
        HEAD1:
        foreach my $head1 ($pom->head1) {

            my $title = $head1->title;
            next HEAD1 unless $title eq 'NAME';
            my $content = $head1->content;
            next DOCFILE unless $content =~ /^[^-]+ - (.*)$/m;
            return $1 if $content;
        }
    }

    return 'No summary found';
}

sub _buildreqs {
    my $self = shift @_;

    # Handle build/test/requires
    my $buildreqs = $self->parent->status->prereqs;

    $buildreqs->{'Module::Build::Compat'} = 0
        if $self->_is_module_build_compat;

    return $buildreqs;
}

# quickly determine if the module is pure-perl (noarch) or not
sub _is_noarch {
    my $self = shift @_;
 
    my @files = @{ $self->parent->status->files };
    return do { first { /\.(c|xs)$/i } @files } ? 0 : 1;
}

sub _docfiles {
    my $self = shift @_;

    # FIXME this is really not complete enough    
    my @docfiles =
        grep { /(README|Change(s|log)|LICENSE|Copyright)$/i }
        map { basename $_ }
        @{ $self->parent->status->files }
        ;

    return \@docfiles;
}


1;

=head1 REFERENCES

L<http://wiki.opensuse.org/openSUSE:Packaging_Perl>

=head1 AUTHORS

M0ses C<< <m0ses plus cpan at samaxi.de> >>

Original source taken from CPANPLUS::Dist::SUSE

Author:

Qindel Formacion y Servicios, SL, C<< <Nito at Qindel.ES> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-cpanplus-dist-rpm-myperl2obs at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=CPANPLUS-Dist-MyPerl2OBS>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc CPANPLUS::Dist::MyPerl2OBS


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=CPANPLUS-Dist-MyPerl2OBS>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/CPANPLUS-Dist-MyPerl2OBS>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/CPANPLUS-Dist-MyPerl2OBS>

=item * Search CPAN

L<http://search.cpan.org/dist/CPANPLUS-Dist-MyPerl2OBS/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2012 M0ses

Copyright 2010 Qindel Formacion y Servicios, SL.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=head1 SPONSORS

2013 IsarNet Software Solutions GmbH http://www.isarnet.de

=head1 TODO

=over 1

=item * make specfile template configurable

=item * make options in cpan2dist.rc configurable on commandline

=item * make rcfile configurable

=cut

__DATA__
__[ spec ]__
#
# spec file for package [% status.rpmname %] (Version [% status.distvers %])
#
# Copyright (c) 2010 SUSE LINUX Products GmbH, Nuernberg, Germany.
# This file and all modifications and additions to the pristine
# package are under the same license as the package itself.
#
# Please submit bugfixes or comments via http://bugs.opensuse.org/
# See also http://wiki.opensuse.org/openSUSE:Packaging_Perl
 
# norootforbuild
%define	modn [% status.distname %]
%define modv [% status.distvers %]

Name:       [% status.rpmname %]
Version:    %{modv}
Release:    [% status.rpmvers %]
License:    [% status.license %]
Group:      Development/Libraries/Perl
Summary:    [% status.summary %]
Source:     http://search.cpan.org/CPAN/[% module.path %]/%{modn}-%{version}.[% module.package_extension %]
Url:        http://search.cpan.org/dist/%{modn}
BuildRoot:  %{_tmppath}/%{name}-%{version}-build   
Requires:   [% perl_package %]
[% IF status.is_noarch %]
BuildArch:  noarch
[% END -%]

BuildRequires: [% perl_package %] 
[% brs = buildreqs; FOREACH br = brs.keys.sort -%]
BuildRequires: [% pkg_deps_ns %]([% br %])[% IF (brs.$br != 0) %] >= [% brs.$br %][% END %]
[% END -%]

%description
[% status.description -%]


%prep
%setup -q -n [% status.distname %]-%{version}

%build
[% IF (!status.is_noarch) -%]
if [ -f Build.PL ]; then
    %{__perl} Build.PL --installdirs vendor
else
   [ -f Makefile.PL ] || exit 2
    %{__perl} Makefile.PL INSTALLDIRS=vendor OPTIMIZE="%{optflags}"
fi
[% ELSE -%]
if [ -f Build.PL ]; then
    %{__perl} Build.PL --installdirs vendor
else
    %{__perl} Makefile.PL INSTALLDIRS=vendor
fi
[% END -%]
if [ -f Build.PL ]; then
    ./Build build flags=%{?_smp_mflags}
else
    %{__make} %{?_smp_mflags}
fi

%install
if [ -f Build.PL ]; then
   ./Build pure_install --destdir %{buildroot}
else
   %{__make} pure_install PERL_INSTALL_ROOT=%{buildroot}
fi

# FIXME: use ./Build install destdir=$RPM_BUILD_ROOT create_packlist=0
# maybe then we would not need to remove the .packlist files :-)
find %{buildroot} -type f -name .packlist -exec rm -f {} ';'

[% IF (!status.is_noarch) -%]
find %{buildroot} -type f -name '*.bs' -a -size 0 -exec rm -f {} ';'
[% END -%]
find %{buildroot} -depth -type d -exec rmdir {} 2>/dev/null ';'

%{_fixperms} %{buildroot}/*
%perl_process_packlist
%__if_gen_file_list

[% IF (!skiptest) -%]
%check
echo >> MANIFEST.SKIP	# ensure trailing newline
echo >> MANIFEST.SKIP ^%{name}\\.files\$

if [ -f Build.PL ]; then
   ./Build test
else
   %{__make} test
fi
[% END -%]

%clean
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && %{__rm} -rf $RPM_BUILD_ROOT    

%files -f /tmp/%{name}-%{version}-files.lst
%defattr(-,root,root,-)
%doc [% docfiles %] 

%changelog
* [% date %] [% packager %]
- initial packaging
- generated with cpan2dist (CPANPLUS::Dist::MyPerl2OBS version [% packagervers %])

__[ _service ]__
<services>
  <service name="download_files"/>
</services>

__[ pod ]__

__END__

1; # End of CPANPLUS::Dist::MyPerl2OBS

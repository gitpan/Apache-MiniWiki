use ExtUtils::MakeMaker;

WriteMakefile(
    'NAME'		=> 'Apache::MiniWiki',
    'VERSION_FROM'	=> 'MiniWiki.pm',
    'PREREQ_PM'		=> { 'Apache::Constants' => 0,
			     'CGI' => 0,
			     'HTML::FromText' => 0,
			     'HTML::Template' => 0,
			     'Rcs' => 0,
			     'Apache::Htpasswd' => 0 },
    ($] >= 5.005 ?
      (ABSTRACT_FROM => 'MiniWiki.pm', # retrieve abstract from module 
       AUTHOR     => 'Jonas Oberg <jonas@gnu.org>') : ()),
);

#
#  Copyright (C) 2002  Wim Kerkhoff <kerw@cpan.org>
#  Copyright (C) 2001  Jonas Öberg <jonas@gnu.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

package Apache::MiniWiki;

use 5.006;
use strict;

use Apache::Constants;
use Apache::Htpasswd;
use HTML::FromText;
use HTML::Template;
use Date::Manip;
use CGI;
use Rcs 1.04;

our $VERSION = 0.41;

our $datadir;       # Directory where we store Wiki pages
our $vroot;         # The virtual root we're using
our $authen;        # Set to filename if we're using basic authentification
our $template;      # Currently loaded template
our $template_mod;  # Last modified date of currently loaded template

# This sets the directory where Rcs can find the rcs binaries.
# Set this to something more sensible if they are located elsewhere.
Rcs->bindir('/usr/bin');
Rcs->rcsdir($datadir);
Rcs->workdir($datadir);

# The function fatal_error is called most commonly when the Apache virtual
# host has not had the correlt PerlVar's configured.
sub fatal_error {
  my ($r, $text) = @_;

  my $uri = $r->uri;

  print <<__EOT__;
<html>
 <body>
  <h1>Error in Apache::MiniWiki</h1>
  $text<br>
  <br>
  While viewing: $uri
 </body>
</html>
__EOT__
  return OK;
}

# This is the main request handler. It begins by finding out its
# configuration, if it has not before, loads templates and then calls
# the appropriate function depending upon the URI we received from
# the user.
sub handler {
  my $r = shift;

  # All information we send is of type text/html
  $r->send_http_header('text/html');

  # Load configuration directives.
  $datadir = ($datadir || $r->dir_config('datadir')) or
      return fatal_error($r, "PerlVar datadir must be set.");
  $vroot = ($vroot || $r->dir_config('vroot')) or
      return fatal_error($r, "PerlVar vroot must be set.");
  $authen = ($r->dir_config('authen') || -1);

  # First strip the virtual root from the URI, then set the URI to
  my ($uri) = ($r->uri =~ m/${vroot}\/?(.*)/i);

  # Load the template for this Wiki
  load_template($r);

  # We currently do not allow the clients browser to cache the document.
  # This means that Opera, for example, has a better chance of actually
  # showing up-to-date content to the user.
  $r->no_cache(1);

  # We call the appropriate functions to perform a task if the
  # URI that the user sent contains "(function)" as an element.
  $uri =~ /^\(([a-z]*)\)\/?(.*)/ && do {
      my $function = $1."_function";
      my $retval;
  
      my ($page, $revision);
  	  ($page, $revision) = split (/\//, $2);
      
	  no strict 'refs';
      eval {
	  $retval = &$function($r, $page || "index", $revision);
      };
      if ($@) {
	  return fatal_error($r, "Unknown function $function called: $@");
      } else {
	  return $retval;
      }
  };
	
  my ($page, $revision);
  ($page, $revision) = split (/\//, $uri);

  # If we didn't call a function, we assume that we should view a page.
  return view_function($r, $page || "index", $revision);
}

# This function converts an URI to a filename. It does this by simply
# replacing all forward slashes with an underscore. This means that all
# files, regardless of URI, finds themselves in the same directory.
# If you don't want this, you can always modify this function.
sub uri_to_filename {
    my ($uri) = @_;

    $uri =~ tr/\//_/;
    return $uri;
}

# This function allows the user to change his or her password, if
# the perl variable "authen" is configured in the Apache configuration
# and points to a valid htpasswd file which is writeable by the user
# executing MiniWiki.
sub newpassword_function {
  my ($r, $uri) = @_;

  if ($authen eq -1) {
      return fatal_error($r, "Authentification disabled in Apache::MiniWiki.");
  }

  my $q = new CGI;
  my $text;

  if ($q->param() && ($q->param('password1') eq $q->param('password2'))) {
      my $pass1 = $q->param('password1');
      $pass1 =~ s///g;
      eval {
	  my $htp = new Apache::Htpasswd($authen);
	  $htp->htpasswd($r->connection->user, $pass1, 1);
      };
      if ($@) {
	  return fatal_error($r, "$@");
      }
      $text = "Password changed.\n";
  } elsif ($q->param() && ($q->param('password1') ne $q->param('password2'))) {
      $text = "The passwords doesn't match each other.\n";
  } else {
      $text = "<form method=\"post\" action=\"${vroot}\/(newpassword)\">\n";
      $text .= "New password: <input type=\"password\" name=\"password1\"><br>\n";
      $text .= "Again: <input type=\"password\" name=\"password2\"><p>\n";
      $text .= "<input type=\"submit\" name=\"Change\"></form>\n";
  }

  my $t = HTML::Template->new( scalarref => \$template );
  $t->param('vroot', $vroot);
  $t->param('title', 'New Password');
  $t->param('body', $text);
  print $t->output;

  return OK;
}

# This function saves a page submitted by the user into an RCS file.
sub save_function {
  my ($r, $uri) = @_;
  my $fileuri = uri_to_filename($uri);
  
  if ($r->method() ne "POST") {
    return fatal_error($r, "Invalid Save");
  }

  my $q = new CGI;
  my $text = $q->param('text');
  my $comment = $q->param('comment');

  $text =~ s///g;
  my $user = $r->connection->user || "anonymous";

  chomp ($comment);
  $comment =~ s/^\s*//g if $comment;
  $comment =~ s/\s*$//g if $comment;

  if (length($text) < 5) {
	return fatal_error($r, "Not enough content");
  }

  if (length($comment) < 3) {
  	return fatal_error($r, "No comment");
  }

  my $file = Rcs->new;
  $file->workdir("${datadir}");
  $file->rcsdir("$datadir");
  $file->file("$fileuri");
  $file->arcfile("$fileuri,v");

  if (-f "${datadir}/${fileuri}" && $file->lock) {
  	# previous locks exist, removing.
	# Is this good?
	$r->log_error("remove existing lock... " . $file->lock);
    eval {
			$file->ci('-u', '-w'.$user);
		};
		if ($@) {
			my $locker = $file->lock;
			return fatal_error ($r, "($locker) Could not unlock $fileuri: $@");
		}
	#return fatal_error($r, "Page $fileuri is already locked");
  }

  if (-f "${datadir}/${fileuri},v") {
    $file->co('-l');
  }

  open(OUT, '>', "${datadir}/${fileuri}");
  print OUT $text;
  close OUT;

  $r->log_error("committing save...");
  $file->ci('-u', '-w'.$user, "-m$comment") if $file->lock;

  return &view_function($r, $uri, undef);
}

# This function reverts a page back to the specified version if possible.
sub revert_function {
  my ($r, $uri, $revision) = @_;

  my $fileuri = uri_to_filename($uri);
	
  my $user = $r->connection->user || "anonymous";

  my %args = $r->args;

  if (!$args{doit}) {
  	warn "go away, bot!";
    return fatal_error($r, 
	  "Bots are not allowed to follow the revert links!" .
	  " If you are a human, add ?doit=1 to the url to revert."
	  );
  }
  
  my $file = Rcs->new;
  $file->workdir("${datadir}");
  $file->rcsdir("$datadir");
  $file->file("$fileuri");
  $file->arcfile("$fileuri,v");

  if (! -f "${datadir}/${fileuri},v") {
    return fatal_error($r, "Page $fileuri,v does not exist at all");
  }

  # remove working copies, in case they are bad
  unlink("$datadir/$fileuri");

  chdir ($datadir);
  eval { $file->co('-l'); };
  if ($@) {
    return fatal_error($r, "Error retriving latest page, check revision");
  }

  # calculate the latest version, needed to undo.
  my $head_version = ($file->revisions)[0];
 
  $file->arcext('');
  eval { 
	chdir ($datadir);
    $file->rcsmerge("-r$head_version", "-r$revision"); 
  };
  if ($@) {
    return fatal_error($r, "Error merging: $!, $?, $@");
  }
  $file->arcext(',v');

  eval { $file->ci('-u', '-w'.$user); } if $file->lock;
  if ($@) {
    return fatal_error($r, "Error reverting");
  }

  my $newtext = "The page has been reverted to revision $revision.<p>";
  $newtext .= "[<a href=\"${vroot}\/${uri}\">Return</a>]<p><hr>";

  my $t = HTML::Template->new( scalarref => \$template );
  $t->param('vroot', $vroot);
  $t->param('title', $uri);
  $t->param('body', $newtext);
  $t->param('editlink', "$vroot/\(edit\)\/$uri");
  $t->param('loglink', "$vroot/\(log\)\/$uri");
  print $t->output;

  return OK;
}

# The edit function checks out a page from RCS and provides a text
# area for the user where he or she can edit the content.
sub edit_function {
  my ($r, $uri) = @_;

  my $fileuri = uri_to_filename($uri);

  if (-f "${datadir}/${fileuri},v") {
    my $file = Rcs->new("${datadir}/${fileuri},v");
    $file->workdir("${datadir}");
    $file->co;
  }

  my $text = "<form method=\"post\" action=\"${vroot}/(save)${uri}\">\n";
  $text .= "<textarea name=\"text\" cols=80 rows=25 wrap=virtual>\n";
  if (-f "${datadir}/${fileuri},v") {
    open(IN, '<', "${datadir}/${fileuri}");
    my $cvstext .= join("\n", <IN>);
    $cvstext =~ s/</&lt;/g;
    $cvstext =~ s/>/&gt;/g;
    $text .= $cvstext;
  }
  $text .= "</textarea><p>Comment: <input type=text size=30 maxlength=80 name=comment>&nbsp;<input type=\"submit\" name=\"Save\"></form>";

  my $t = HTML::Template->new( scalarref => \$template );
  $t->param('vroot', $vroot);
  $t->param('title', $uri);
  $t->param('body', $text);
  $t->param('editlink', "$vroot/\(edit\)\/$uri");
  $t->param('loglink', "$vroot/\(log\)\/$uri");

  print $t->output;
  return OK;
}

# This function is the standard viewer. It loads a file and displays it
# to the user.
sub view_function {
  my ($r, $uri, $revision) = @_;
  my $mvtime; my $mtime;
  
  my $fileuri = uri_to_filename($uri);

  # If the file doesn't exist as an RCS file, then we return NOT_FOUND to
  # Apache.
  if (! -f "${datadir}/${fileuri},v") {
    return NOT_FOUND;
  }

  # If we don't have a checked out file, check it out. Can't really do caching here,
  # as we also deal with multiple revisions of the files. If there is a performance 
  # bottleneck here, in the future we may need to look at other means of caching.
  my $file = Rcs->new;
  $file->workdir("${datadir}");
  $file->rcsdir("$datadir");
  $file->file("$fileuri");
  $file->arcfile("$fileuri,v");
  eval { $file->co("-r$revision"); };
  if ($@) {
    return fatal_error($r, "Error retriving specified page, check revision");
  }

  open(IN, '<', "${datadir}/${fileuri}");
  my $text = join("\n", <IN>);
  close IN;

  # This converts the text into HTML with the help of HTML::FromText.
  # See the POD information for HTML::FromText for an explanation of
  # these settings.
  my $newtext = text2html($text, urls => 1, email => 1, bold => 1,
			  underline =>1, paras => 1, bullets => 1, numbers=> 1,
			  headings => 1, blockcode => 1, tables => 1,
			  title => 1, code => 1);

  # While the text contains Wiki-style links, we go through each one and
  # change them into proper HTML links.
  while ($newtext =~ /\[\[([^\]|]*)\|?([^\]]*)\]\]/) {
    my $rawname = $1;
	my $revision;
	if ($rawname =~ /\//) {
		($rawname, $revision) = split (/\//, $rawname);
	}
    my $desc = $2 || $rawname;
    my $tmplink;

    my $tmppath = uri_to_filename($rawname);
    $tmppath =~ s/^_//;

    if (-f "${datadir}/$tmppath,v") {
      $newtext =~ s/\[\[[^\]]*\]\]/<a href="${vroot}\/${rawname}\/$revision">$desc<\/a>/;
    } else {
      $tmplink = "$desc <a href=\"${vroot}\/(edit)/${rawname}\"><sup>?<\/sup><\/a>";
      $newtext =~ s/\[\[[^\]]*\]\]/$tmplink/;
    }
  }
  $newtext =~ s/\\\[\\\[/\[\[/g;

  $newtext =~ s/-{3,}/<hr>/g;

  my %dispatch = (
  	list => \&get_list,
	listchanges => \&get_listchanges
  );

  if ($dispatch{$uri}) {
    $newtext .= $dispatch{$uri}($r);
  }

  my $t = HTML::Template->new( scalarref => \$template );
  $t->param('vroot', $vroot);
  $t->param('title', $uri);
  $t->param('body', $newtext);
  $t->param('editlink', "$vroot/\(edit\)\/$uri");
  $t->param('loglink', "$vroot/\(log\)\/$uri");

  print $t->output;

  return OK;
}

# This function dumps out the log list for the file, so that the user can view
# any past version of the file.
sub log_function {
  my ($r, $uri) = @_;
  Rcs->arcext(''); 
  my $obj = Rcs->new("$datadir/$uri,v");
  $obj->workdir("$datadir");
  my @rlog_complete = $obj->rlog;

  my $logbody = "History for $uri\n\n";
  
  $logbody = text2html($logbody, urls => 1, email => 1, bold => 1,
			  underline =>1, paras => 1, bullets => 1, numbers=> 1,
			  headings => 1, blockcode => 1, tables => 1,
			  title => 1, code => 1);

  my $server = $r->server->server_hostname;

  foreach my $line (@rlog_complete) {
	if ($line =~ /Initial checkin|empty log message|=============/) {
		next;
	}
	elsif ($line !~ /:/ && $line !~ /----/ && $line !~ /revision|date/i) {
	   chomp($line);
	   $line = "&nbsp;" x 5 . "<i>$line</i><br>\n" if $line;
	}
	elsif ($line !~ /^(revision |date: )/) {
		next;
	}
	elsif ($line =~ /^revision /) {
		my ($word, $revision) = split (' ', $line);
		$line = qq|<a href="${vroot}/$uri/$revision">View</a> or |;
		$line .= qq|<a href="${vroot}/(revert)/$uri/$revision">Revert</a>  |;
		$line .= qq|revision $revision: |;
	}
	else {
		$line .= "<br>\n";
	}
	$logbody .= "\n$line";
  }
  
  my $t = HTML::Template->new( scalarref => \$template );
  $t->param('vroot', $vroot);
  $t->param('title', $uri);
  $t->param('body', $logbody);
  $t->param('editlink', "$vroot/\(edit\)\/$uri");
  $t->param('loglink', "$vroot/\(log\)\/$uri");

  print $t->output;

  return OK;

}

# This function loads the template, if one exists. If there is no template,
# then a default template consisting of just a plain body is used.
sub load_template {
	my ($r) = @_;

    my $mtime;

    if (! -f "${datadir}/template,v") {
      $template = <<END_TEMPLATE;
<html>
<head><title>Default Wiki: <TMPL_VAR NAME=title></title></head>
<body>
<TMPL_VAR NAME=BODY>
<p>
<hr>
This is a default template. For a full example of wiki pages, use those provided in the Apache::MiniWiki distribution.

See the archive: <a href="<TMPL_VAR NAME=loglink>">Archive</a>.

<hr>
[<a href="<TMPL_VAR NAME=editlink>">Edit</a> | <a href="<TMPL_VAR NAME=vroot>">Home</a> ]
</body></html>
END_TEMPLATE
      return;
    }

    (undef, undef, undef, undef, undef, undef, undef, undef, undef, $mtime,
     undef, undef, undef) = stat("${datadir}/template,v");

	# or we can't compare them
	$mtime || $template_mod || return;

    if (not $template_mod or $mtime gt $template_mod) {
      my $file = Rcs->new;
      $file->workdir("${datadir}");
      $file->rcsdir("$datadir");
      $file->file("template");
      $file->arcfile("template,v");
      eval { $file->co(); };
      if ($@) {
        return fatal_error($r, "Error retriving template");
      }
      open(IN, '<', "${datadir}/template");
      $template = join("\n", <IN>);
      close IN;
      $template_mod = $mtime;
    }
}

# This function lists all files in the data directory
# and returns an HTML formatted list of links.
sub get_list {
	my $linklist = "";

	chdir ($datadir);

	# get the list of files...
	my @files = <*,v>;

	# sort them 
	my @sorted_files = sort {uc($a) cmp uc($b)} @files;
	
	foreach my $rawname (@sorted_files) {
		$rawname =~ s/,v$//;
		$rawname =~ s/^\///g;
		next if ($rawname eq "template");
		$linklist .= qq|<a href="$vroot/$rawname">$rawname</a><br>\n|;
	}
	
	return $linklist;
}

# This function does up a pretty list of all the changes in the
# Wiki, and returns the HTML for it.
# Does checks for ?maxdays=x&maxpages=y
sub get_listchanges {
	my $r = shift;

	my %args = $r->args;

	my $changes = "";

	chdir($datadir);
  
	Rcs->arcext(''); 

	# all the page changes get stored in a big hash
	# by year, then month, then day. This allows us much better
	# control when laying it out.
	my $records = {};
	
	open (LS, "/bin/ls -1at *,v | grep -v template,v |")
	 || return fatal_error($r, "Could not get a listing: $!");
	
	while (my $page = (<LS>)) {
		chomp ($page);
		$page =~ s/,v$//g;

		my $rcsfile = $page;
		$rcsfile =~ s| |\\ |g;

		my $pagelink = $page;
		$pagelink =~ s/ /\%20/g;
	
		my $obj = Rcs->new("$datadir/$rcsfile,v");
		$obj->workdir("$datadir");

		my $incomment = 0;

		# parse the meta information
		my ($revision, $datestamp, $comment, $lines, $title); 
		foreach my $line ($obj->rlog("-r")) {
			chomp ($line);

			if ($line =~ /------------/) {
				$incomment = 1;
			}
			elsif ($line =~ /============/) {
				$incomment = 0;
			}
			elsif ($incomment) {
				if ($line =~ /^date: /) {
					my @fields = split ('; ', $line);
					$datestamp = (split(': ', $fields[0]))[1];
					$lines = (split(': ', $fields[3]))[1];
				}
				elsif ($line =~ /^revision 1/) {
					$revision = $line;
					$revision =~ s/^revision 1//g;
				}
				elsif ($line !~ /empty log message/) {
					$comment .= $line;
				}
			}
		}

		# obtain the title of the page, which should be the
		# first line of the page normally.
		my $working_file = $rcsfile;
		open (FILE, "< $datadir/$working_file") || 
			next;
		while ($title = (<FILE>)) {
			last if ($title);
			$r->log_error($title)
		}
		close (FILE);
		
		$title ||= $page;

		# no wiki words
		$title =~ s/\[|\]//g;

		$lines =~ s/ /\//;

		$comment = ucfirst($comment);

		my ($date, $time) = split (/\ /, $datestamp);
		my ($year, $month, $day) = split (/\//, $date);

		$records->{$year}->{$month}->{$day}->{"$time"} = {
			page => $pagelink,
			title => $title,
			comment => $comment,
			lines => $lines
		};
	}
	close (LS);

	my $day_counter = 0;
	my $page_counter = 0;

	foreach my $year (reverse sort keys %{$records}) {
		foreach my $month (reverse sort keys %{$records->{$year}}) {
			foreach my $day (reverse sort keys %{$records->{$year}->{$month}}) {
				my $date = &ParseDateString("$year$month$day");
				$date = &UnixDate($date, "%B %d, %Y");
				$changes .= "&nbsp;&nbsp;<b><i>$date</i></b><br>\n";
				foreach my $time (reverse sort keys %{$records->{$year}->{$month}->{$day}}) {
					my $record = $records->{$year}->{$month}->{$day}->{$time};
					my $nicetime = "$year$month$day$time";
					$nicetime =~ s/://g;
					$nicetime = &ParseDateString($nicetime);
					my $delta = &ParseDateDelta("- 7 hours");
					$nicetime = &DateCalc($nicetime, $delta);
					$nicetime = &UnixDate($nicetime, "%H:%M %p");
					$changes .= qq|
&nbsp;&nbsp;&nbsp;
$nicetime <a href="$vroot/$record->{page}">$record->{title}</a>
					|;
					$changes .= qq| - $record->{comment}. | if $record->{comment};
					$changes .= qq|Changes:
						<a href="${vroot}/(log)/$record->{page}">$record->{lines}</a>
						| if $record->{lines};
					$changes .= qq|<br>\n|;
					$page_counter++;
					if ($args{maxpages} && ($page_counter >= $args{maxpages})) {
						goto finish;
					}
				}
				$changes .= "<br>\n";
				$day_counter++;
				if ($args{maxdays} && ($day_counter >= $args{maxdays})) {
					goto finish;
				}
			}
			$changes .= "\n<hr>\n";
		}
	}

	finish:

	$changes .= "<br>\n";
	$changes .= "Current date: <b>" . `/bin/date` . "</b><br>\n";

	return $changes;
}

1;

__END__

=head1 NAME

Apache::MiniWiki - Miniature Wiki for Apache

=head1 SYNOPSIS

Add this to httpd.conf:

  <Location /wiki>
     PerlAddVar datadir "/home/foo/db/wiki/"
     PerlAddVar vroot "/wiki"
     PerlAddVar authen "/home/foo/db/htpasswd"
     SetHandler perl-script
     PerlHandler Apache::MiniWiki

     AuthType Basic
     AuthName "Sample Wiki"
     AuthUserFile /home/foo/db/htpasswd 
     Require valid-user
  </Location>

=head1 DEPENDENCIES

This module requires these other modules:

  Apache::Htpasswd;
  Apache::Constants;
  CGI;
  HTML::FromText;
  HTML::Template;
  Rcs;

=head1 ALTERNATIVE SYNOPSIS

Apache::MiniWiki can also be called by an Apache::Registry CGI script. By 
running it in this manner, absolutely no changes need to be made to the
web server's httpd.conf, as long as Apache has mod_perl built in.

Copy the example wiki.cgi into your CGI directory and assign it the 
appropriate permissions. Edit wiki.cgi and set the datadir and vroot
variables:

$r->dir_config->add(datadir => '/home/foo/db/wiki/');
$r->dir_config->add(vroot => '/perlcgi/wiki.cgi');

Note #1: This may be a great way of integrating Apache::MiniWiki into
an existing site that already has it's own header/footer template system.

Note #2: This method assumes that the site administrator is already
using Apache::Registry to speed up CGI's on the site. If they aren't,
have them set up mod_perl as it was meant to be. See the mod_perl guide,
or try this:

  ScriptAlias /perlcgi /path/to/your/cgi-bin/
  <Location /perlcgi>
    SetHandler perl-script
    PerlHandler Apache::Registry
    Options ExecCGI
  </Location>

=head1 DESCRIPTION

Apache::MiniWiki is an simplistic Wiki for Apache. It doesn't
have much uses besides very simple installations where hardly any features
are needed. What is does support though is:

  - storage of Wiki pages in RCS
  - templates through HTML::Template
  - text to HTML conversion with HTML::FromText
  - basic authentification password changes
  - ability to view any revision of a page
  - ability to revert back to any revision of the page
  - basic checks to keep search engine spiders from deleting 
    all the pages in the Wiki!!!

If you want to use your own template for MiniWiki, you should place the
template in the RCS file template,v in the C<datadir>. Upon execution,
MiniWiki will check out this template and use it. If you make any
modifications to the RCS file, a new version will be checked out.

You can modify the template from within MiniWiki by visiting the URL
http://your.server.name/your-wiki-vroot/(edit)/template

If you don't install a template, a default one will be used.

The C<datadir> variable defines where in the filesystem that the RCS
files that MiniWiki uses should be stored. This is also where MiniWiki
looks for a template to use.

The C<vroot> should match the virtual directory that MiniWiki runs under.

If this variable is set, it should point to a standard htpasswd file
which MiniWiki has write access to. The function to change a users password
is then enabled.

If you create the pages 'list' or 'listchanges', the following will
automatically get appended to them:

 - list:        A simple line deliminated list of 
                all the pages in the system

 - listchanges: Ordered by date, gives a list of all pages 
                including the last comment, the number of lines 
                added or removed, and the date of the last change

To keep things sane and reasonable, the master 'template' page does not
show up in any of these three page listings.

Spiders for search engines (Google, OpenFind, etc) love the 
bounty of links found in a Wiki. Unfortunely, they also follow
the Archive, Changes, View, and Revert links. This not only
adds to the load on your webserver, but there is a very high
chance that pages will get rolled back as the spider
goes in circles following links. This has happened! Add
these links to your robots.txt so that robots can
only view the actual current pages:

Disallow: /wiki/(edit)/
Disallow: /wiki/(log)/
Disallow: /wiki/(revert)/
Disallow: /wiki/(save)/
Disallow: /wiki/(view)/
Disallow: /wiki/lastchanges

See http://www.nyetwork.org/wiki for an example of 
this module in active use.

=head1 AUTHORS

Jonas Oberg, E<lt>jonas@gnu.orgE<gt>

Wim Kerkhoff, E<lt>kerw@cpan.orgE<gt>

=head1 CONTRIBUTORS

Brian Lauer, E<lt>fozbaca@yahoo.comE<gt>

=head1 SEE ALSO

L<perl>, L<Apache::Registry>, L<HTML::FromText>, L<HTML::Template>, L<Rcs>, L<CGI>.

=cut


#
#  Copyright (C) 2001  Jonas Öberg <jonas@gnu.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#
package Apache::MiniWiki;

use 5.006;
use strict;

use Apache::Htpasswd;
use Apache::Constants;
use CGI;
use HTML::FromText;
use HTML::Template;
use Rcs;

our $VERSION = 0.20;

our $datadir;       # Directory where we store Wiki pages
our $vroot;         # The virtual root we're using
our $authen;        # Set to filename if we're using basic authentification
our $template;      # Currently loaded template
our $template_mod;  # Last modified date of currently loaded template

# This sets the directory where Rcs can find the rcs binaries.
# Set this to something more sensible if they are located elsewhere.
Rcs->bindir('/usr/bin');

# The function fatal_error is called most commonly when the Apache virtual
# host has not had the correlt PerlVar's configured.
sub fatal_error {
  (my $r, my $text) = @_;

  print <<__EOT__;
<html>
 <body>
  <h1>Error in Apache::MiniWiki</h1>
  $text
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
  load_template();

  # We currently do not allow the clients browser to cache the document.
  # This means that Opera, for example, has a better chance of actually
  # showing up-to-date content to the user.
  $r->no_cache(1);

  # We call the appropriate functions to perform a task if the
  # URI that the user sent contains "(function)" as an element.
  $uri =~ /^\(([a-z]*)\)\/?(.*)/ && do {
      my $function = $1."_function";
      my $retval;

      no strict 'refs';
      eval {
	  $retval = &$function($r, $2 || "index");
      };
      if ($@) {
	  return fatal_error($r, "Unknown function $function called.");
      } else {
	  return $retval;
      }
  };

  # If we didn't call a function, we assume that we should view a page.
  return view_function($r, $uri || "index");
}

# This function converts an URI to a filename. It does this by simply
# replacing all forward slashes with an underscore. This means that all
# files, regardless of URI, finds themselves in the same directory.
# If you don't want this, you can always modify this function.
sub uri_to_filename {
    (my $uri) = @_;

    $uri =~ tr/\//_/;
    return $uri;
}

# This function allows the user to change his or her password, if
# the perl variable "authen" is configured in the Apache configuration
# and points to a valid htpasswd file which is writeable by the user
# executing MiniWiki.
sub newpassword_function {
  (my $r, my $uri) = @_;

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
  $t->param('body', $text);
  print $t->output;

  return OK;
}

# This function saves a page submitted by the user into an RCS file.
sub save_function {
  (my $r, my $uri) = @_;
  my $fileuri = uri_to_filename($uri);

  my $q = new CGI;
  my $text = $q->param('text');

  $text =~ s///g;
  my $user = $r->connection->user || "anonymous";

  my $file = Rcs->new("${datadir}/${fileuri},v");
  $file->workdir("${datadir}");

  if (-f "${datadir}/${fileuri},v") {
    $file->co('-l');
  }

  open(OUT, '>', "${datadir}/${fileuri}");
  print OUT $text;
  close OUT;

  $file->ci('-u', '-w'.$user);

  my $newtext = "A verbatim copy of the text stored in the database is appended below.<p>";
  $newtext .= "[<a href=\"${vroot}\/${uri}\">Return</a>]<p><hr>";
  $text =~ s/</&lt;/g;
  $text =~ s/>/&gt;/g;
  $newtext .= "<pre>$text</pre>\n";

  my $t = HTML::Template->new( scalarref => \$template );
  $t->param('body', $newtext);
  print $t->output;

  return OK;
}

# The edit function checks out a page from RCS and provides a text
# area for the user where he or she can edit the content.
sub edit_function {
  (my $r, my $uri) = @_;

  my $fileuri = uri_to_filename($uri);

  if (-f "${datadir}/${fileuri},v") {
    my $file = Rcs->new("${datadir}/${fileuri},v");
    $file->workdir("${datadir}");
    $file->co;
  }

  my $text = "<form method=\"post\" action=\"${vroot}/(save)${uri}\">\n";
  $text .= "<textarea name=\"text\" cols=80 rows=25>\n";
  if (-f "${datadir}/${fileuri},v") {
    open(IN, '<', "${datadir}/${fileuri}");
    my $cvstext .= join(/\n/, <IN>);
    $cvstext =~ s/</&lt;/g;
    $cvstext =~ s/>/&gt;/g;
    $text .= $cvstext;
  }
  $text .= "</textarea><p><input type=\"submit\" name=\"Submit\"></form>";

  my $t = HTML::Template->new( scalarref => \$template );
  $t->param('body', $text);

  print $t->output;
  return OK;
}

# This function is the standard viewer. It loads a file and displays it
# to the user.
sub view_function {
  (my $r, my $uri) = @_;
  my $mvtime; my $mtime;

  my $fileuri = uri_to_filename($uri);

  # If the file doesn't exist as an RCS file, then we return NOT_FOUND to
  # Apache.
  if (! -f "${datadir}/${fileuri},v") {
    return NOT_FOUND;
  }

  # If we don't have a checked out file, or if the RCS file is newer
  # than the checked out copy, we check out a fresh copy.
  if ( (! -f "${datadir}/${fileuri}") ||
       (-M "${datadir}/${fileuri},v" gt -M "${datadir}/${fileuri}")) {
      my $file = Rcs->new("${datadir}/${fileuri},v");
      $file->workdir("${datadir}");
      $file->co;
  }

  open(IN, '<', "${datadir}/${fileuri}");
  my $text = join(/\n/, <IN>);
  close IN;

  # This converts the text into HTML with the help of HTML::FromText.
  # See the POD information for HTML::FromText for an explanation of
  # these settings.
  my $newtext = text2html($text, urls => 1, email => 1, bold => 1,
			  underline =>1, paras => 1, bullets => 1, numbers=> 1,
			  headings => 1, blockquotes => 1, tables => 1,
			  title => 1);

  # While the text contains Wiki-style links, we go through each one and
  # change them into proper HTML links.
  while ($newtext =~ /\[\[([^\]|]*)\|?([^\]]*)\]\]/) {
    my $rawname = $1;
    my $desc = $2 || $rawname;
    my $tmplink;

    my $tmppath = uri_to_filename($rawname);
    $tmppath =~ s/^_//;

    if (-f "${datadir}/$tmppath,v") {
      $newtext =~ s/\[\[[^\]]*\]\]/<a href="${vroot}\/${rawname}">$desc<\/a>/;
    } else {
      $tmplink = "$desc <a style=\"text-decoration :none\" href=\"${vroot}\/(edit)/${rawname}\"><sup>?<\/sup><\/a>";
      $newtext =~ s/\[\[[^\]]*\]\]/$tmplink/;
    }
  }
  $newtext =~ s/\\\[\\\[/\[\[/g;

  $newtext =~ s/-{3,}/<hr>/g;

  my $t = HTML::Template->new( scalarref => \$template );
  $t->param('body', $newtext);
  $t->param('editlink', "$vroot/\(edit\)\/$uri");

  print $t->output;

  return OK;
}

# This function loads the template, if one exists. If there is no template,
# then a default template consisting of just a plain body is used.
sub load_template {
    my $mtime;

    if (! -f "${datadir}/template,v") {
      $template = "<html><body><TMPL_VAR NAME=BODY><p><hr>[<a href=\"<TMPL_VAR NAME=editlink>\">Edit</a>]</body></html>";
      return;
    }

    (undef, undef, undef, undef, undef, undef, undef, undef, undef, $mtime,
     undef, undef, undef) = stat("${datadir}/template,v");

    if ($mtime gt $template_mod) {
      my $file = Rcs->new("${datadir}/template,v");
      $file->workdir("${datadir}");
      $file->co;
      open(IN, '<', "${datadir}/template");
      $template = join(/\n/, <IN>);
      close IN;
      $template_mod = $mtime;
    }
}

1;
__END__

=head1 NAME

Apache::MiniWiki - Miniature Wiki for Apache

=head1 SYNOPSIS

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

=head1 DESCRIPTION

Apache::MiniWiki is an increadibly simplistic Wiki for Apache. It doesn't
have much uses besides very simple installations where hardly any features
are needed. What is does support though is; storage of Wiki pages in RCS,
templates through HTML::Template, text to HTML conversion with
HTML::FromText and basic authentification password changes.

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


=head1 AUTHOR

Jonas Oberg, E<lt>jonas@gnu.orgE<gt>

=head1 SEE ALSO

L<perl>, L<HTML::FromText>, L<HTML::Template>.

=cut


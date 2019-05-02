# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2005-2019 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version. For
# more details read LICENSE in the root of this distribution.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

package Foswiki::Plugins::DBCachePlugin;

use strict;
use warnings;

use Foswiki::Func();
use Foswiki::Plugins();

#use Monitor;
#Monitor::MonitorMethod('Foswiki::Contrib::DBCachePlugin');
#Monitor::MonitorMethod('Foswiki::Contrib::DBCachePlugin::Core');
#Monitor::MonitorMethod('Foswiki::Contrib::DBCachePlugin::WebDB');

our $VERSION = '12.11';
our $RELEASE = '2 May 2019';
our $NO_PREFS_IN_TOPIC = 1;
our $SHORTDESCRIPTION = 'Lightweighted frontend to the <nop>DBCacheContrib';

our $core;
our $addDependency;
our @isEnabledSaveHandler = ();
our @isEnabledRenameHandler = ();
our @knownIndexTopicHandler = ();

###############################################################################
# plugin initializer
sub initPlugin {

  $core = undef;

  Foswiki::Func::registerTagHandler('DBQUERY', sub {
    return getCore()->handleDBQUERY(@_);
  });

  Foswiki::Func::registerTagHandler('DBCALL', sub {
    return getCore()->handleDBCALL(@_);
  });

  Foswiki::Func::registerTagHandler('DBSTATS', sub {
    return getCore()->handleDBSTATS(@_);
  });

  Foswiki::Func::registerTagHandler('DBDUMP', sub {
    return getCore()->handleDBDUMP(@_);
  });

  Foswiki::Func::registerTagHandler('DBRECURSE', sub {
    return getCore()->handleDBRECURSE(@_);
  });

  Foswiki::Func::registerTagHandler('DBPREV', sub {
    return getCore()->handleNeighbours(1, @_);
  });

  Foswiki::Func::registerTagHandler('DBNEXT', sub {
    return getCore()->handleNeighbours(0, @_);
  });

  Foswiki::Func::registerRESTHandler('updateCache', \&restUpdateCache, 
    authenticate => 1,
    validate => 0,
    http_allow => 'GET,POST',
  );

  Foswiki::Func::registerRESTHandler('dbdump', sub {
    return getCore()->Foswiki::Plugins::DBCachePlugin::Core::restDBDUMP(@_);
  }, 
    authenticate => 1,
    validate => 0,
    http_allow => 'GET,POST',
  );

  # SMELL: remove this when Foswiki::Cache got into the core
  my $cache = $Foswiki::Plugins::SESSION->{cache}
    || $Foswiki::Plugins::SESSION->{cache};
  if (defined $cache) {
    $addDependency = \&addDependencyHandler;
  } else {
    $addDependency = \&nullHandler;
  }

  @isEnabledSaveHandler = ();
  @isEnabledRenameHandler = ();

  return 1;
}

###############################################################################
sub finishPlugin {

  my $session = $Foswiki::Plugins::SESSION;
  @knownIndexTopicHandler = ();
  @isEnabledSaveHandler = ();
  @isEnabledRenameHandler = ();

  $core->finish if defined $core;
  $core = undef;
}

###############################################################################
sub getCore {
  unless (defined $core) {
    require Foswiki::Plugins::DBCachePlugin::Core;
    $core = Foswiki::Plugins::DBCachePlugin::Core->new();
  }
  return $core;
}


###############################################################################
# REST handler to create and update the dbcache
sub restUpdateCache {
  my $session = shift;

  my $query = Foswiki::Func::getRequestObject();

  my $theWeb = $query->param('web');
  my $theDebug = Foswiki::Func::isTrue($query->param('debug'), 0);
  my @webs;

  if ($theWeb) {
    push @webs,$theWeb;
  } else {
    @webs = Foswiki::Func::getListOfWebs();
  }

  foreach my $web (sort @webs) {
    print STDERR "refreshing $web\n" if $theDebug;
    getDB($web, 2);
  }
}

###############################################################################
sub disableSaveHandler {
  push @isEnabledSaveHandler, 1;
}

###############################################################################
sub enableSaveHandler {
  pop @isEnabledSaveHandler;
}

###############################################################################
sub disableRenameHandler {
  push @isEnabledRenameHandler, 1;
}

###############################################################################
sub enableRenameHandler {
  pop @isEnabledRenameHandler;
}

###############################################################################
sub loadTopic {
  return getCore()->loadTopic(@_);
}

###############################################################################
# after save handlers
sub afterSaveHandler {
  #my ($text, $topic, $web, $meta) = @_;

  return if scalar(@isEnabledSaveHandler);

  # Temporarily disable afterSaveHandler during a "createweb" action:
  # The "createweb" action calls save serveral times during its operation.
  # The below hack fixes an error where this handler is already called even though
  # the rest of the web hasn't been indexed yet. For some reasons we'll end up
  # with only the current topic being index into in the web db while the rest
  # would be missing. Indexing all of the newly created web is thus defered until
  # after "createweb" has finished.

  my $context = Foswiki::Func::getContext();
  my $request = Foswiki::Func::getCgiQuery();
  my $action = $request->param('action') || '';
  if ($context->{manage} && $action eq 'createweb') {
    #print STDERR "suppressing afterSaveHandler during createweb\n";
    return;
  }

  return getCore()->afterSaveHandler($_[2], $_[1]);
}

###############################################################################
# deprecated: use afterUploadSaveHandler instead
sub afterAttachmentSaveHandler {
  #my ($attrHashRef, $topic, $web) = @_;
  return if scalar(@isEnabledSaveHandler);

  return if $Foswiki::Plugins::VERSION >= 2.1 || 
    $Foswiki::cfg{DBCachePlugin}{UseUploadHandler}; # set this to true if you backported the afterUploadHandler

  return getCore()->afterSaveHandler($_[2], $_[1]);
}

###############################################################################
# Foswiki::Plugins::VERSION >= 2.1
sub afterUploadHandler {
  return if scalar(@isEnabledSaveHandler);

  my ($attrHashRef, $meta) = @_;
  my $web = $meta->web;
  my $topic = $meta->topic;
  return getCore()->afterSaveHandler($web, $topic);
}

###############################################################################
# Foswiki::Plugins::VERSION >= 2.1
sub afterRenameHandler {
  return if scalar(@isEnabledRenameHandler);

  my ($web, $topic, $attachment, $newWeb, $newTopic, $newAttachment) = @_;

  return getCore()->afterSaveHandler($web, $topic, $newWeb, $newTopic, $attachment, $newAttachment);
}

###############################################################################
# tags

###############################################################################
# perl api
sub getDB {
  return getCore()->getDB(@_);
}

sub unloadDB {
  return getCore()->unloadDB(@_);
}

sub registerIndexTopicHandler {
  push @knownIndexTopicHandler, shift;
}

###############################################################################
# SMELL: remove this when Foswiki::Cache got into the core
sub nullHandler { }

sub addDependencyHandler {
  my $cache = $Foswiki::Plugins::SESSION->{cache}
    || $Foswiki::Plugins::SESSION->{cache};
  return $cache->addDependency(@_) if $cache;
}

1;

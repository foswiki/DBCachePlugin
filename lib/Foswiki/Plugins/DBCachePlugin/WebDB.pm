# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2005-2018 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html
#
###############################################################################

package Foswiki::Plugins::DBCachePlugin::WebDB;

use strict;
use warnings;

use Foswiki::Contrib::DBCacheContrib ();
use Foswiki::Contrib::DBCacheContrib::Search ();
use Foswiki::Plugins::DBCachePlugin ();
use Foswiki::Plugins::DBCachePlugin::Hits ();
use Foswiki::Attrs ();
use Foswiki::Time ();
use Foswiki::Plugins ();
use Foswiki::Form ();

use constant TRACE => 0; # toggle me

@Foswiki::Plugins::DBCachePlugin::WebDB::ISA = ("Foswiki::Contrib::DBCacheContrib");

###############################################################################
sub new {
  my ($class, $web, $cacheName) = @_;

  $cacheName = 'DBCachePluginDB' unless $cacheName;

  #writeDebug("new WebDB for $web");

  my $this = bless($class->SUPER::new($web, $cacheName), $class);
  #$this->{_loadTime} = 0;
  $this->{web} = $this->{_web};
  $this->{web} =~ s/\./\//go;

  $this->{prevTopicCache} = ();
  $this->{nextTopicCache} = ();

  return $this;
}

###############################################################################
sub writeDebug {
  print STDERR "- DBCachePlugin::WebDB - $_[0]\n" if TRACE;
}

###############################################################################
# cache time we loaded the cacheFile
sub load {
  my ($this, $refresh, $web, $topic) = @_;

  $refresh ||= 0;
  writeDebug("called load() for $this->{web}, refresh=$refresh");

  if ($refresh == 1 && defined($web) && defined($topic)) {
    # refresh a single topic
    $this->loadTopic($web, $topic);
    $refresh = 0;
  }

  $this->SUPER::load($refresh);
}

###############################################################################
# called by superclass when one or more topics had
# to be reloaded from disc.
sub onReload {
  my ($this, $topics) = @_;

  writeDebug("called onReload()");
  my $topicTitleField = Foswiki::Func::getPreferencesValue("TOPICTITLE_FIELD") || "TopicTitle";

  foreach my $topic (@$topics) {
    my $obj = $this->fastget($topic);

    # anything we get to see here should be in the dbcache already.
    # however we still check for odd topics that did not make it into the cache
    # for some odd reason
    unless ($obj) {
      writeDebug("trying to load topic '$topic' in web '$this->{web}' but it wasn't found in the cache");
      next;
    }

    # get meta object
    my ($meta, $text) = Foswiki::Func::readTopic($this->{web}, $topic);
    $this->cleanUpText($text);

    # SMELL: call getRevisionInfo to make sure the latest revision is loaded
    # for get('TOPICINFO') further down the code
    # $meta->getRevisionInfo();

    writeDebug("reloading $topic");

    # createdate
    my ($createDate, $createAuthor) = Foswiki::Func::getRevisionInfo($this->{web}, $topic, 1);
    $obj->set('createdate', $createDate);
    $obj->set('createauthor', $createAuthor);

    # get default section
    my $defaultSection = $text;
    $defaultSection =~ s/.*?%STARTINCLUDE%//s;
    $defaultSection =~ s/%STOPINCLUDE%.*//s;

    $obj->set('_sectiondefault', $defaultSection);

    # get named sections

    # CAUTION: %SECTION will be deleted in the near future.
    # so please convert all %SECTION to %STARTSECTION

    my $archivist = $this->getArchivist();

    my @sections = ();
    while ($text =~ s/%(?:START)?SECTION\{(.*?)\}%(.*?)%(?:STOP|END)SECTION\{[^}]*?"(.*?)"\}%//s) {
      my $attrs = new Foswiki::Attrs($1);
      my $name = $attrs->{name} || $attrs->{_DEFAULT} || '';
      my $sectionText = $2;
      push @sections, $name;
      $obj->set("_section$name", $sectionText);
    }
    $obj->set('_sections', join(", ", @sections));

    # get topic title
    my $form = $obj->fastget('form');
    $form = $obj->fastget($form) if $form;

    # 1. get from preferences
    my $topicTitle = $this->getPreference($obj, 'TOPICTITLE');
    #print STDERR "... getting topicTitle from preference: ".($topicTitle//'undef')."\n";

    # 2. get from form
    if ($form && (!defined $topicTitle || $topicTitle eq '')) {
      $topicTitle = $form->fastget($topicTitleField) || '';
      $topicTitle = urlDecode($topicTitle);
      #print STDERR "... getting topicTitle from form: ".($topicTitle//'undef')."\n";
    }

    # 4. use topic name
    unless ($topicTitle) {
      if ($topic eq 'WebHome') {
        $topicTitle = $this->{web};
        $topicTitle =~ s/^.*[\.\/]//;
      } else {
        $topicTitle = $topic;
      }
      #print STDERR "... getting topicTitle from topic name: ".($topicTitle//'undef')."\n";
    }

    #print STDERR "... found topicTitle: ".($topicTitle//'undef')."\n";
    $obj->set('topictitle', $topicTitle);

    # This is to maintain the Inheritance formfield for the WikiWorkbenchContrib
    if ($form) {
      my $topicType = $form->fastget("TopicType");
      if ($topicType && $topicType =~ /\bTopicType\b/) {
        my $session = $Foswiki::Plugins::SESSION;
        my $metaForm = Foswiki::Form->new($session, $this->{web}, $topic);
        my $field = $metaForm->getField("TopicType");
        if ($field) {
          my $inheritance = join(", ", sort grep {!/^$topic$/} split(/\s*,\s*/, $field->{value}));
          $form->set("Inheritance", $inheritance);
        }
      }
    }

    # call index topic handlers
    my %seen;
    foreach my $sub (@Foswiki::Plugins::DBCachePlugin::knownIndexTopicHandler) {
      next if $seen{$sub};
      &$sub($this, $obj, $this->{web}, $topic, $meta, $text);
      $seen{$sub} = 1;
    }

  }

  #print STDERR "DEBUG: DBCachePlugin::WebDB - done onReload()\n";
}

###############################################################################
sub getFormField {
  my ($this, $theTopic, $theFormField) = @_;

  my $topicObj = $this->fastget($theTopic);
  return '' unless $topicObj;

  my $form = $topicObj->fastget('form');
  return '' unless $form;

  $form = $topicObj->fastget($form);
  return '' unless $form;

  my $fieldName = $theFormField;

  # FIXME: regexes copied from Foswiki::Form::fieldTitle2FieldName
  $fieldName =~ s/!//g;
  $fieldName =~ s/<nop>//g;
  $fieldName =~ s/[^A-Za-z0-9_\.]//g;

  my $formfield = $form->fastget($fieldName);
  $formfield = '' unless  defined $formfield;

  return urlDecode($formfield);
}

###############################################################################
sub getNeighbourTopics {
  my ($this, $theTopic, $theSearch, $theOrder, $theReverse) = @_;

  my $key = $this->{web}.'.'.$theTopic.':'.$theSearch.':'.$theOrder.':'.$theReverse;
  my $prevTopic = $this->{prevTopicCache}{$key};
  my $nextTopic = $this->{nextTopicCache}{$key};

  unless ($prevTopic && $nextTopic) {

    my $hits = $this->dbQuery($theSearch, undef, $theOrder, $theReverse);
    my $state = 0;
    while (my $obj = $hits->next) {
      my $t = $obj->fastget("topic");
      if ($state == 1) {
        $state = 2;
        $nextTopic = $t;
        last;
      }
      $state = 1 if $t eq $theTopic;
      $prevTopic = $t if $state == 0;
      #writeDebug("t=$t, state=$state");
    }

    $prevTopic = '_notfound' if !$prevTopic || $state == 0;
    $nextTopic = '_notfound' if !$nextTopic || !$state == 2;
    $this->{prevTopicCache}{$key} = $prevTopic;
    $this->{nextTopicCache}{$key} = $nextTopic;

    #writeDebug("prevTopic=$prevTopic, nextTopic=$nextTopic");

  }

  $prevTopic = '' if $prevTopic eq '_notfound';
  $nextTopic = '' if $nextTopic eq '_notfound';

  return ($prevTopic, $nextTopic);
}

###############################################################################
sub dbQuery {
  my ($this, $theSearch, $theTopics, $theSort, $theReverse, $theInclude, $theExclude, $hits) = @_;

  # get max hit set
  my @topicNames;
  if ($theTopics && @$theTopics) {
    @topicNames = @$theTopics;
  } else {
    @topicNames = $this->getKeys();
  }
  @topicNames = grep(/$theInclude/, @topicNames) if $theInclude;
  @topicNames = grep(!/$theExclude/, @topicNames) if $theExclude;

  # parse & fetch
  my $wikiName = Foswiki::Func::getWikiName();
  my $search;
  if ($theSearch) {
    $search = new Foswiki::Contrib::DBCacheContrib::Search($theSearch);
  }

  my $isAdmin = Foswiki::Func::isAnAdmin();
  my $webViewPermission = $isAdmin || Foswiki::Func::checkAccessPermission('VIEW', $wikiName, undef, undef, $this->{web});

  $hits ||= Foswiki::Plugins::DBCachePlugin::Hits->new(
    sorting => $theSort,
    reverse => $theReverse,
  );

  foreach my $topicName (@topicNames) {
    my $topicObj = $this->fastget($topicName);
    next unless $topicObj;    # never

    if (!$search || $search->matches($topicObj, {webDB=>$this})) {

      my $topicHasPerms = 0;
      unless ($isAdmin) {
        my $prefs = $topicObj->fastget('preferences');
        if (defined($prefs)) {
          foreach my $key ($prefs->getKeys()) {
            if ($key =~ /^(ALLOW|DENY)TOPIC/) {
              $topicHasPerms = 1;
              last;
            }
          }
        }
      }

      # don't check access perms on a topic that does not contain any
      # WARNING: this is hardcoded to assume Foswiki-Core permissions - anyone
      # doing pluggable Permissions need to
      # work out howto abstract this concept - or to disable it (its worth about 400mS per topic in the set. (if you're not WikiAdmin))
      if (
        $isAdmin 
        || (!$topicHasPerms && $webViewPermission)
        || ($topicHasPerms && $this->checkAccessPermission('VIEW', $wikiName, $topicObj)) #Foswiki::Func::checkAccessPermission('VIEW', $wikiName, undef, $topicName, $this->{web}))
        ) 
      {
        $hits->add($topicName, $topicObj);
      }
    }
  }

  return $hits;
}

###############################################################################
sub expandPath {
  my ($this, $theRoot, $thePath) = @_;

  return '' if !defined($thePath) || !defined($theRoot) || $thePath eq '';

  #print STDERR "DEBUG: expandPath($theRoot, $thePath)\n";

  if ($thePath =~ /^info.author$/) {
    my $info = $theRoot->fastget('info');
    return '' unless $info;
    my $author = $info->fastget('author');
    return Foswiki::Func::getWikiName($author);
  }
  if ($thePath =~ /^(.*?) and (.*)$/) {
    my $first = $1;
    my $tail = $2;
    my $result1 = $this->expandPath($theRoot, $first);
    return '' unless defined $result1 && $result1 ne '';
    my $result2 = $this->expandPath($theRoot, $tail);
    return '' unless defined $result2 && $result2 ne '';
    return $result1 . $result2;
  }
  if ($thePath =~ /^d2n\((.*)\)$/) {
    my $result = $this->expandPath($theRoot, $1);
    return 0 unless defined $result;
    return $result if $result =~ /^[\+\-]?\d+$/;
    return Foswiki::Time::parseTime($result);
  }
  if ($thePath =~ /^uc\((.*)\)$/) {
    my $result = $this->expandPath($theRoot, $1);
    return uc($result);
  }
  if ($thePath =~ /^lc\((.*)\)$/) {
    my $result = $this->expandPath($theRoot, $1);
    return lc($result);
  }
  if ($thePath =~ /^length\((.*)\)$/) {
    my $result = $this->expandPath($theRoot, $1);
    return length($result);
  }
  if ($thePath =~ /^'([^']*)'$/) {

    #print STDERR "DEBUG: here1 - result=$1\n";
    return $1;
  }
  if ($thePath =~ /^[+-]?\d+(\.\d+)?$/) {
    #print STDERR "DEBUG: here2 - result=$thePath\n";
    return $thePath;
  }
  if ($thePath =~ /^(.*?) or (.*)$/) {
    my $first = $1;
    my $tail = $2;
    my $result = $this->expandPath($theRoot, $first);
    return $result if (defined $result && $result ne '');
    return $this->expandPath($theRoot, $tail);
  }
  if ($thePath =~ m/^(\w+)(.*)$/o) {
    my $first = $1;
    my $tail = $2;
    $tail =~ s/^\.//;
    my $root;
    my $form = $theRoot->fastget('form');
    $form = $theRoot->fastget($form) if $form;
    $root = $form->fastget($first) if $form;
    $root = $theRoot->fastget($first) unless defined $root;
    return $this->expandPath($root, $tail) if ref($root);
    return '' unless defined $root;
    return $root if $first eq 'text';    # not url encoded
    my $field = urlDecode($root);
 
    #print STDERR "DEBUG: here3 - result=$field\n";
    return $field;
  }

  if ($thePath =~ /^@([^\.]+)(.*)$/) {
    my $first = $1;
    my $tail = $2;
    $tail =~ s/^\.//;

    my $ref = $this->expandPath($theRoot, $first);
    my $root;
    if (ref($ref)) {
      $root = $ref;
      return $this->expandPath($root, $tail);
    } 

    my @results = ();
    $ref =~ s/^\s+|\s+$//g;

    foreach my $refItem (split(/\s*,\s*/, $ref)) {
      my $db;
      if ($refItem =~ /^(.*)\.(.*?)$/) {
        $db = Foswiki::Plugins::DBCachePlugin::getDB($1);
        next unless defined $db;
        $root = $db->fastget($2);
      } else {
        $root = $this->fastget($refItem);
        $db = $this;
      }
      push @results, $db->expandPath($root, $tail);
    }

    return join(", ", @results);
  }

  if ($thePath =~ /^%/) {
    $thePath = &Foswiki::Func::expandCommonVariables($thePath, '', $this->{web});
    $thePath =~ s/^%/<nop>%/o;
    return $this->expandPath($theRoot, $thePath);
  }

  #print STDERR "DEBUG: $theRoot->get($thePath)\n";

  my $result = $theRoot->get($thePath);
  $result = '' unless defined $result;

  if (ref($result) && UNIVERSAL::can($result, "size")) {
    $result = $result->size();
  }
  #print STDERR "DEBUG: result=$result\n";

  return $result;
}

###############################################################################
# a variation reading acls from cache instead from raw txt
sub checkAccessPermission {
  my ($this, $mode, $user, $topic) = @_;

  #print STDERR "called checkAccessPermission($mode, $user, $topic) ... ";

  my $cUID;
  my $session = $Foswiki::Plugins::SESSION;
  my $users = $session->{users};

  if (defined $cUID) {
    $cUID = Foswiki::Func::getCanonicalUserID($user)
      || Foswiki::Func::getCanonicalUserID($Foswiki::cfg{DefaultUserLogin});
  } else {
    $cUID ||= $session->{user};
  }

  if ($users->isAdmin($cUID)) {
    return 1;
  }

  $mode = uc($mode);

  my $allow = $this->getACL($topic, 'ALLOWTOPIC' . $mode);
  my $deny = $this->getACL($topic, 'DENYTOPIC' . $mode);

  my $isDeprecatedEmptyDeny =
    !defined($Foswiki::cfg{AccessControlACL}{EnableDeprecatedEmptyDeny}) || $Foswiki::cfg{AccessControlACL}{EnableDeprecatedEmptyDeny};

  # Check DENYTOPIC
  if (defined($deny)) {
    if (scalar(@$deny) != 0) {
      if ($users->isInUserList($cUID, $deny)) {
        #print STDERR "1: DENY user=$user mode=$mode topic=".$topic->fastget('name'). "\n";
        return 0;
      }
    } else {

      if ($isDeprecatedEmptyDeny) {
        # If DENYTOPIC is empty, don't deny _anyone_
        #print STDERR "2: result = 1\n";
        return 1;
      } else {
        $deny = undef;
      }
    }
  }

  # Check ALLOWTOPIC. If this is defined the user _must_ be in it
  if (defined($allow) && scalar(@$allow) != 0) {
    if (!$isDeprecatedEmptyDeny && grep {/^\*$/} @$allow) {
      # ALLOWTOPIC is *, don't deny _anyone_
      #print STDERR "3: result = 1\n";
      return 1;
    }

    if ($users->isInUserList($cUID, $allow)) {
      #print STDERR "4: result = 1\n";
      return 1;
    }

    #print STDERR "5: DENY user=$user mode=$mode topic=".$topic->fastget('name'). "\n";
    return 0;
  }

  return 1;
}

###############################################################################
sub getACL {
  my ($this, $topic, $mode) = @_;

  unless (ref($topic)) {
    $topic = $this->fastget($topic);
  }

  return unless defined $topic;

  my $text = $this->getPreference($topic, $mode);
  #print STDERR "getACL($topic, $mode), text=".($text||'')."\n";
  return unless defined $text;

  # Remove HTML tags (compatibility, inherited from Users.pm
  $text =~ s/(<[^>]*>)//g;

  # Dump the users web specifier if userweb
  my @list = grep { /\S/ } map {
      s/^($Foswiki::cfg{UsersWebName}|%USERSWEB%|%MAINWEB%)\.//;
      $_
  } split( /[,\s]+/, $text );

#print STDERR "getACL($mode): ".join(', ', @list)."\n";

  return \@list;
}

###############################################################################
sub getPreference {
  my ($this, $topic, $key) = @_;

  unless (ref($topic)) {
    $topic = $this->fastget($topic);
  }

  return unless defined $topic;

  my $prefs = $topic->fastget('preferences');

  return unless defined $prefs;

  my $value = $prefs->fastget($key);

  return unless defined $value;

  return urlDecode($value);
}

###############################################################################
# from Foswiki.pm
sub urlDecode {
  my $text = shift;

  $text =~ s/%([\da-f]{2})/chr(hex($1))/gei;

  return $text;
}

1;

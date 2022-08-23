# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2005-2022 Michael Daum http://michaeldaumconsulting.com
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

package Foswiki::Plugins::DBCachePlugin::Core;

use strict;
use warnings;

use POSIX ();

our %webDB;
our $TranslationToken = "\0";

use constant TRACE => 0;    # toggle me
use constant ENABLE_WEBDB_FEATURE => 0; # CAUTION: this is disabled by default for performance reasons when loading preferences from lots of webs 

use Foswiki::Contrib::DBCacheContrib ();
use Foswiki::Contrib::DBCacheContrib::Search ();
use Foswiki::Plugins::DBCachePlugin::WebDB ();
use Foswiki::Plugins ();
use Foswiki::Sandbox ();
use Foswiki::Time ();
use Foswiki::Func ();
use Cwd;
use Encode();
use Error qw(:try);

###############################################################################
sub new {
  my $class = shift;

  my $this = bless({
      wikiWordRegex => Foswiki::Func::getRegularExpression('wikiWordRegex'),
      webNameRegex => Foswiki::Func::getRegularExpression('webNameRegex'),
      defaultWebNameRegex => Foswiki::Func::getRegularExpression('defaultWebNameRegex'),
      linkProtocolPattern => Foswiki::Func::getRegularExpression('linkProtocolPattern'),
      tagNameRegex => Foswiki::Func::getRegularExpression('tagNameRegex'),
      webKeys => undef,
      currentWeb => undef,
      isModifiedDB => undef,
      @_
    },
    $class
  );

  my $query = Foswiki::Func::getCgiQuery();
  my $memoryCache = $Foswiki::cfg{DBCachePlugin}{MemoryCache};
  $memoryCache = 1 unless defined $memoryCache;

  $this->{doRefresh} = 0;

  if ($memoryCache) {
    my $refresh = $query->param('refresh') || '';

    if ($refresh eq 'this') {
      $this->{doRefresh} = 1;
    } elsif ($refresh =~ /^(on|dbcache)$/) {
      $this->{doRefresh} = 2;
      %webDB = ();
      #_writeDebug("found refresh in urlparam");
    }
  } else {
    %webDB = ();
  }

  return $this;
}

###############################################################################
sub afterSaveHandler {
  my ($this, $web, $topic, $newWeb, $newTopic, $attachment, $newAttachment) = @_;

  _writeDebug("called afterSaveHandler($web, $topic)");

  $newWeb ||= $web;
  $newTopic ||= $topic;

  my $db = $this->getDB($web);
  unless ($db) {
    print STDERR "WARNING: DBCachePlugin can't get cache for web '$web'\n";
    return;
  }

  $db->loadTopic($web, $topic);

  if ($web ne $newWeb) {
    $db = $this->getDB($newWeb);
    unless ($db) {
      print STDERR "WARNING: DBCachePlugin can't get cache for new web '$newWeb'\n";
      return;
    }
  }
  $db->loadTopic($newWeb, $newTopic) if $web ne $newWeb || $topic ne $newTopic;

  # set the internal loadTime counter to the latest modification
  # time on disk.
  $db->getArchivist->updateCacheTime();
}

###############################################################################
sub loadTopic {
  my ($this, $web, $topic) = @_;

  my $db = $this->getDB($web);
  unless ($db) {
    print STDERR "WARNING: DBCachePlugin can't get cache for web '$web'\n";
    return;
  }
  return $db->loadTopic($web, $topic);
}

###############################################################################
sub handleNeighbours {
  my ($this, $mode, $session, $params, $topic, $web) = @_;

  #_writeDebug("called handleNeighbours($web, $topic)");

  my $baseWeb = $session->{webName};
  my $baseTopic = $session->{topicName};
  my ($theWeb, $theTopic) = Foswiki::Func::normalizeWebTopicName($params->{web} || $baseWeb, $params->{topic} || $baseTopic);

  my $theSearch = $params->{_DEFAULT};
  $theSearch = $params->{search} unless defined $theSearch;

  my $theFormat = $params->{format} || '$web.$topic';
  my $theOrder = $params->{sort} || $params->{order} || 'created';
  my $theReverse = $params->{reverse} || 'off';
  my $doWarnings = Foswiki::Func::isTrue($params->{warn}, 1);

  unless ($theSearch) {
    return $doWarnings ? lineError("ERROR: no \"search\" parameter in DBPREV/DBNEXT") : "";
  }

  #_writeDebug('theFormat='.$theFormat);
  #_writeDebug('theSearch='. $theSearch) if $theSearch;

  my $db = $this->getDB($theWeb);
  unless ($db) {
    return $doWarnings ? _inlineError("ERROR: DBPREV/DBNEXT unknown web '$theWeb'") : "";
  }

  my ($prevTopic, $nextTopic) = $db->getNeighbourTopics($theTopic, $theSearch, $theOrder, $theReverse);

  my $result = $theFormat;

  if ($mode) {
    # DBPREV
    return '' unless $prevTopic;
    $result =~ s/\$topic/$prevTopic/g;
  } else {
    # DBNEXT
    return '' unless $nextTopic;
    $result =~ s/\$topic/$nextTopic/g;
  }

  $result =~ s/\$web/$theWeb/g;
  $result =~ s/\$perce?nt/\%/g;
  $result =~ s/\$nop//g;
  $result =~ s/\$n/\n/g;
  $result =~ s/\$dollar/\$/g;

  return $result;
}

###############################################################################
sub handleCREATEAUTHOR {
  my ($this, $session, $params, $topic, $web) = @_;

  my $doWarnings = Foswiki::Func::isTrue($params->{warn}, 1);
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($params->{web} || $web, $params->{_DEFAULT} // $params->{topic} || $topic);

  my $db = $this->getDB($web);
  return $doWarnings ? _inlineError("web not found") : "" unless $db;

  my $obj = $db->fastget($topic);
  return $doWarnings ? _inlineError("topic not found") : "" unless $obj;

  my $wikiName = $obj->fastget("createauthor");
  my $wikiUserName = $Foswiki::cfg{UsersWebName}.'.'.$wikiName;
  my $userName = Foswiki::Func::wikiToUserName($wikiName);

  my $format = $params->{format} // '$wikiname';

  my $result = _expandVariables($format, $web, $topic, 
    username => $userName,
    wikiname => $wikiName,
    wikiusername => $wikiUserName,
  );

  return  _expandFormatTokens($result);
}

###############################################################################
sub handleCREATEDATE {
  my ($this, $session, $params, $topic, $web) = @_;

  my $doWarnings = Foswiki::Func::isTrue($params->{warn}, 1);
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($params->{web} || $web, $params->{_DEFAULT} // $params->{topic} || $topic);

  my $db = $this->getDB($web);
  return $doWarnings ? _inlineError("web not found") : "" unless $db;

  my $obj = $db->fastget($topic);
  return $doWarnings ? _inlineError("topic not found") : "" unless $obj;

  my $createDate = $obj->fastget("createdate");
  my $format = $params->{format} // $Foswiki::cfg{DefaultDateFormat};

  my $result =  _formatTime($createDate, $format, $params);

  return  _expandFormatTokens($result);
}

###############################################################################
sub handleDBQUERY {
  my ($this, $session, $params, $theTopic, $theWeb) = @_;

  #_writeDebug("called handleDBQUERY("   $params->stringify() . ")");

  # params
  my $baseWeb = $session->{webName};
  my $baseTopic = $session->{topicName};
  my $theSearch = $params->{_DEFAULT} || $params->{search};
  my $thisTopic = $params->{topic} || '';
  my $thisWeb = $params->{web} || $baseWeb;
  my $theWebs = $params->{webs};
  my $theTopics = $params->{topics} || '';
  my $theFormat = $params->{format};
  my $theHeader = $params->{header} || '';
  my $theFooter = $params->{footer} || '';
  my $theInclude = $params->{include};
  my $theExclude = $params->{exclude};
  my $theSort = $params->{sort} || $params->{order} || 'name';
  my $theReverse = $params->{reverse} || 'off';
  my $theSep = $params->{separator};
  my $theLimit = $params->{limit} || '';
  my $theSkip = $params->{skip} || 0;
  my $theHideNull = Foswiki::Func::isTrue($params->{hidenull}, 0);
  my $theNullFormat = $params->{nullformat};
  my $theRemote = Foswiki::Func::isTrue($params->remove('remote'), 0);
  my $theNewline = $params->{newline};
  my $theContext = $params->{context};
  my $doWarnings = Foswiki::Func::isTrue($params->{warn}, 1);

  $theFormat = '$topic' unless defined $theFormat;
  $theFormat = '' if $theFormat eq 'none';
  $theSep = $params->{sep} unless defined $theSep;
  $theSep = '$n' unless defined $theSep;
  $theSep = '' if $theSep eq 'none';

  # get the regexes
  $theInclude = join("|", split(/\s*,\s*/, $theInclude)) if $theInclude;
  $theExclude = join("|", split(/\s*,\s*/, $theExclude)) if $theExclude;

  # get topic(s)
  my @topicNames = ();
  if ($thisTopic) {
    ($thisWeb, $thisTopic) = Foswiki::Func::normalizeWebTopicName($thisWeb, $thisTopic);
    push @topicNames, $thisTopic;
  } else {
    $thisTopic = $baseTopic;
    if ($theTopics) {
      @topicNames = split(/\s*,\s*/, $theTopics);
    }
  }

  # get webs
  my @webs;
  if ($theWebs) {
    if ($theWebs eq 'all') {
      @webs = Foswiki::Func::getListOfWebs();
    } else {
      @webs = split(/\s*,\s*/, $theWebs);
    }
  } else {
    push @webs, $thisWeb;
  }

  # get the skip
  unless ($theSkip =~ /^[\d]+$/) {
    $theSkip = _expandVariables($theSkip, $thisWeb, $thisTopic);
    $theSkip = _expandFormatTokens($theSkip);
    $theSkip = Foswiki::Func::expandCommonVariables($theSkip, $thisTopic, $thisWeb) if $theSkip =~ /%/;
  }
  $theSkip =~ s/[^-\d]//g;
  $theSkip = 0 if $theSkip eq '';
  $theSkip = 0 if $theSkip < 0;

  # get the limit
  unless ($theLimit =~ /^[\d]+$/) {
    $theLimit = _expandVariables($theLimit, $thisWeb, $thisTopic);
    $theLimit = _expandFormatTokens($theLimit);
    $theLimit = Foswiki::Func::expandCommonVariables($theLimit, $thisTopic, $thisWeb) if $theLimit =~ /%/;
  }
  $theLimit =~ s/[^\d]//g;

  # get webs
  my $hits;
  my $error;
  try {
    foreach my $web (@webs) {

      my $theDB = $this->getDB($web);
      next unless $theDB;

      # flag the current web we evaluate this query in, used by web-specific operators
      $this->currentWeb($web);

      # collect hit set
      $hits = $theDB->dbQuery($theSearch, \@topicNames, $theSort, $theReverse, $theInclude, $theExclude, $hits, $theContext);

      $this->currentWeb("");
    }
  }
  catch Error::Simple with {
    $error = shift->stringify();
  };

  if ($error) {
    return $doWarnings ? _inlineError($error) : "";
  }
  if (!$hits || $hits->count <= $theSkip) {
    return _expandFormatTokens($theNullFormat) if defined $theNullFormat;
    return "" if $theHideNull;
  }

  # format
  my @result = ();
  if ($theFormat && $hits) {
    my $index = $hits->skip($theSkip);
    my $lastWeb = '';
    my $theDB;
    while (my $obj = $hits->next) {
      $index++;

      my $topicName = $obj->fastget("topic");
      my $web = $obj->fastget("web");
      $theDB = $this->getDB($web) if !$theDB || $lastWeb ne $web;
      $lastWeb = $web;
      unless ($theWeb) {
        print STDERR "ERROR: no such web $theWeb in DBQUERY\n";
        next;
      }

      my $line = $theFormat;
      $line =~ s/\$pattern\((.*?)\)/_extractPattern($obj, $1)/ge;
      $line =~ s/\$formfield\((.*?)\)/
        my $temp = $theDB->getFormField($topicName, $1);
        $temp =~ s#\)#${TranslationToken}#g;
        $temp =~ s#\r?\n#$theNewline#gs if defined $theNewline;
        $temp/ge;
      $line =~ s/\$expand\((.*?)\)/
        my $temp = $1;
        $temp = $theDB->expandPath($obj, $temp);
        $temp =~ s#\)#${TranslationToken}#g;
        $temp/ge;
      $line =~ s/\$displayValue\((.*?)\)/
        my $temp = $1;
        $temp = $obj->getDisplayValue($temp) \/\/ '';
        $temp =~ s#\)#${TranslationToken}#g;
        $temp/ge;
      $line =~ s/\$html\((.*?)\)/
        my $temp = $1;
        $temp = $theDB->expandPath($obj, $temp);
        $temp =~ s#\)#${TranslationToken}#g;
        $temp = Foswiki::Func::expandCommonVariables($temp, $topicName, $web);
        $temp = Foswiki::Func::renderText($temp, $web, $topicName);
        $temp/ge;
      $line =~ s/\$d2n\((.*?)\)/Foswiki::Contrib::DBCacheContrib::parseDate($theDB->expandPath($obj, $1))||0/ge;
      $line =~ s/\$formatTime\((.*?)(?:,\s*'([^']*?)')?\)/_formatTime($theDB->expandPath($obj, $1), $2)/ge;    # single quoted
      $line =~ s/\$topic/$topicName/g;
      $line =~ s/\$web/$web/g;
      $line =~ s/\$index/$index/g;
      $line =~ s/\$flatten\((.*?)\)/_flatten($1, $web, $thisTopic)/ges;
      $line =~ s/\$rss\((.*?)\)/_rss($1, $web, $thisTopic)/ges;
      $line =~ s/\$translate\((.*?)\)/_translate($1, $theWeb, $theTopic)/ges;
      $line =~ s/\$length\((.*?)\)/
        my $temp = $1;
        $temp = $theDB->expandPath($obj, $temp);
        if (ref($temp) && UNIVERSAL::can($temp, "size")) {
          $temp = $temp->size();
        } else {
          $temp = length($temp);
        }
        $temp;
      /ge;

      $line =~ s/${TranslationToken}/)/g;
      push @result, $line;

      # Disabled for performance reasons
      #$Foswiki::Plugins::DBCachePlugin::addDependency->($web, $topicName);

      last if $index == ($theLimit || 0) + $theSkip;
    }
  }

  my $text = $theHeader . join($theSep, @result) . $theFooter;

  $text = _expandVariables($text, $thisWeb, $thisTopic, count => ($hits ? $hits->count : 0), web => $thisWeb);
  $text = _expandFormatTokens($text);

  $this->fixInclude($thisWeb, $text) if $theRemote;

  return $text;
}

###############################################################################
# finds the correct topicfunction for this object topic.
# this is constructed by checking for the existance of a topic derived from
# the type information of the objec topic.
sub findTopicMethod {
  my ($this, $session, $theWeb, $theTopic, $theObject) = @_;

  #_writeDebug("called findTopicMethod($theWeb, $theTopic, $theObject)");

  return unless $theObject;

  my ($thisWeb, $thisObject) = Foswiki::Func::normalizeWebTopicName($theWeb, $theObject);

  #_writeDebug("object web=$thisWeb, topic=$thisObject");

  # get form object
  my $baseDB = $this->getDB($thisWeb);
  unless ($baseDB) {
    print STDERR "WARNING: DBCachePlugin can't get cache for web '$thisWeb'\n";
    return;
  }

  #_writeDebug("1");

  my $topicObj = $baseDB->fastget($thisObject);
  return unless $topicObj;

  #_writeDebug("2");

  my $formObj = $topicObj->getForm();
  return unless $formObj;

  my ($formWeb, $formTopic) = Foswiki::Func::normalizeWebTopicName($thisWeb, $formObj->fastget("name"));
  #_writeDebug("formWeb=$formWeb, formTopic=$formTopic");

  my $formDB = $this->getDB($formWeb);
  unless ($formDB) {
    print STDERR "WARNING: DBCachePlugin can't get cache for web '$formWeb'\n";
    return;
  }

  #_writeDebug("4");

  # get type information on this object
  my $topicTypes = $formObj->fastget('TopicType');
  return unless $topicTypes;

  #_writeDebug("topicTypes=$topicTypes");

  $topicTypes =~ s/^\s+|\s+$//g;
  foreach my $topicType (split(/\s*,\s*/, $topicTypes)) {

    #_writeDebug(".... topicType=$topicType");

    #_writeDebug("1");

    # find it in the web where this type is implemented
    my $topicTypeObj = $formDB->fastget($topicType);
    next unless $topicTypeObj;

    #_writeDebug("2");

    $formObj = $topicTypeObj->getForm();
    next unless $formObj;

    #_writeDebug("4");

    my $targetWeb;
    my $target = $formObj->fastget('Target');
    if ($target) {
      $targetWeb = $1 if $target =~ /^(.*)[.\/](.*?)$/;
    }
    $targetWeb = $formWeb unless defined $targetWeb;

    #_writeDebug("5");

    my $theMethod = $topicType . $theTopic;
    my $targetDB = $this->getDB($targetWeb);
    #_writeDebug("... checking $targetWeb.$theMethod");
    return ($targetWeb, $theMethod) if $targetDB && $targetDB->fastget($theMethod);

    #_writeDebug("6");

    return ($targetWeb, $theTopic) if $targetDB && $targetDB->fastget($theTopic);
  }

  #_writeDebug("... nothing found");
  return;
}

###############################################################################
sub handleDBCALL {
  my ($this, $session, $params, $theTopic, $theWeb) = @_;

  my $thisTopic = $params->remove('_DEFAULT');
  my $doWarnings = Foswiki::Func::isTrue($params->{warn}, 1);
  return '' unless $thisTopic;

  #_writeDebug("called handleDBCALL()");

  # check if this is an object call
  my $theObject;
  if ($thisTopic =~ /^(.*)->(.*)$/) {
    $theObject = $1;
    $thisTopic = $2;
  }

  my $baseWeb = $session->{webName};
  my $baseTopic = $session->{topicName};
  my $thisWeb = $baseWeb;    # Note: default to $baseWeb and _not_ to $theWeb
  ($thisWeb, $thisTopic) = Foswiki::Func::normalizeWebTopicName($thisWeb, $thisTopic);

  # find the actual implementation
  if ($theObject) {
    $params->{OBJECT} = $theObject;
    my ($methodWeb, $methodTopic) = $this->findTopicMethod($session, $thisWeb, $thisTopic, $theObject);
    if (defined $methodWeb) {
      #_writeDebug("found impl at $methodWeb.$methodTopic");
      $thisWeb = $methodWeb;
      $thisTopic = $methodTopic;
    } else {
      # last resort: lookup the method in the Applications web
      #_writeDebug("last resort check for Applications.$thisTopic");
      my $appDB = $this->getDB('Applications');
      if ($appDB && $appDB->fastget($thisTopic)) {
        $thisWeb = 'Applications';
      }
    }
  }

  # Disabled for performance reasons
  #$Foswiki::Plugins::DBCachePlugin::addDependency->($thisWeb, $thisTopic);

  # remember args for the key before mangling the params
  my $args = $params->stringify();

  my $section = $params->remove('section') || 'default';
  my $remote = Foswiki::Func::isTrue($params->remove('remote'), 0);

  #_writeDebug("thisWeb=$thisWeb thisTopic=$thisTopic baseWeb=$baseWeb baseTopic=$baseTopic");

  # get web and topic
  my $thisDB = $this->getDB($thisWeb);
  unless ($thisDB) {
    return $doWarnings ? _inlineError("ERROR: DBALL can't find web '$thisWeb'") : "";
  }

  my $topicObj = $thisDB->fastget($thisTopic);
  unless ($topicObj) {
    if ($theObject) {
      return $doWarnings ? _inlineError("ERROR: DBCALL can't find method <nop>$thisTopic for object $theObject") : "";
    } else {
      return $doWarnings ? _inlineError("ERROR: DBCALL can't find topic <nop>$thisTopic in <nop>$thisWeb") : "";
    }
  }

  # check access rights
  my $wikiName = Foswiki::Func::getWikiName();

  #unless (Foswiki::Func::checkAccessPermission('VIEW', $wikiName, undef, $thisTopic, $thisWeb)) {
  unless ($thisDB->checkAccessPermission('VIEW', $wikiName, $topicObj)) {
    return $doWarnings ? _inlineError("ERROR: DBCALL access to '$thisWeb.$thisTopic' denied") : "";
  }

  # get section
  my $sectionText;
  $sectionText = $topicObj->fastget("_section$section") if $topicObj;
  if (!defined $sectionText) {
    return $doWarnings ? _inlineError("ERROR: DBCALL can't find section '$section' in topic '$thisWeb.$thisTopic'") : "";
  }

  my %saveTags;
  if ($Foswiki::Plugins::VERSION >= 2.1) {
    Foswiki::Func::pushTopicContext($baseWeb, $baseTopic);
    foreach my $key (keys %$params) {
      my $val = $params->{$key};
      # SMELL: working around issue in the Foswiki parse
      # where an undefined %VAR% in SESSION_TAGS is expanded to VAR instead of
      # leaving it to %VAR%
      unless ($val =~ /^\%$this->{tagNameRegex}\%$/) {
        Foswiki::Func::setPreferencesValue($key, $val);
      }
    }
  } else {
    %saveTags = %{$session->{SESSION_TAGS}};
    # copy params into session tags
    foreach my $key (keys %$params) {
      my $val = $params->{$key};
      # SMELL: working around issue in the Foswiki parse
      # where an undefined %VAR% in SESSION_TAGS is expanded to VAR instead of
      # leaving it to %VAR%
      unless ($val =~ /^\%$this->{tagNameRegex}\%$/) {
        $session->{SESSION_TAGS}{$key} = $val;
      }
    }
  }

  # prevent recursive calls
  my $key = $thisWeb . '.' . $thisTopic . ' ' . $args;
  my $count = $this->{dbcalls}{$key} // 0;
  if ($count > 1) {
    return $doWarnings ? _inlineError("ERROR: DBCALL reached max recursion at '$thisWeb.$thisTopic'") : "";
  }
  $this->{dbcalls}{$key}++;

  # substitute variables
  $sectionText =~ s/%INCLUDINGWEB%/$theWeb/g;
  $sectionText =~ s/%INCLUDINGTOPIC%/$theTopic/g;
  foreach my $key (keys %$params) {
    $sectionText =~ s/%$key%/$params->{$key}/g;
  }

  # expand
  my $context = Foswiki::Func::getContext();
  $context->{insideInclude} = 1;
  $sectionText = Foswiki::Func::expandCommonVariables($sectionText, $thisTopic, $thisWeb) if $sectionText =~ /%/;
  delete $context->{insideInclude};

  # fix local linx
  $this->fixInclude($thisWeb, $sectionText) if $remote;

  # cleanup
  delete $this->{dbcalls}{$key};

  if ($Foswiki::Plugins::VERSION >= 2.1) {
    Foswiki::Func::popTopicContext();
  } else {
    %{$session->{SESSION_TAGS}} = %saveTags;
  }

  #_writeDebug("done handleDBCALL");

  return $sectionText;
  #return "<verbatim>\n$sectionText\n</verbatim>";
}

###############################################################################
sub handleDBSTATS {
  my ($this, $session, $params, $theTopic, $theWeb) = @_;

  #_writeDebug("called handleDBSTATS");

  # get args
  my $baseWeb = $session->{webName};
  my $baseTopic = $session->{topicName};
  my $theSearch = $params->{_DEFAULT} // $params->{search} // '';
  my $thisWeb = $params->{web} // $baseWeb;
  my $theWebs = $params->{webs};
  my $thisTopic = $params->{topic} // $baseTopic;
  my $thisTopics = $params->{topics};
  my $thePattern = $params->{pattern} // '^(.*)$';
  my $theSplit = $params->{split} // '\s*,\s*';
  my $theHeader = $params->{header} // '';
  my $theFormat = $params->{format};
  my $theFooter = $params->{footer} // '';
  my $theSep = $params->{separator};
  my $theFields = $params->{fields} // $params->{field} // 'text';
  my $theSort = $params->{sort} // $params->{order} // 'alpha';
  my $theReverse = Foswiki::Func::isTrue($params->{reverse}, 0);
  my $theLimit = $params->{limit} // 0;
  my $theHideNull = Foswiki::Func::isTrue($params->{hidenull}, 0);
  my $theExclude = $params->{exclude};
  my $theInclude = $params->{include};
  my $theDateFormat = $params->{dateformat} // $Foswiki::cfg{DefaultDateFormat};
  my $theDateLanguage = $params->{datelanguage} // $session->i18n->language() // 'en';
  my $theCase = Foswiki::Func::isTrue($params->{casesensitive}, 0);
  my $theKeyNumber = $params->{keynumber} // 1;

  $theKeyNumber =~ s/[^\d]//g;
  $theKeyNumber -= 1;
  $theLimit =~ s/[^\d]//g;

  $theFormat = '   * $key: $count' unless defined $theFormat;
  $theSep = $params->{sep} unless defined $theSep;
  $theSep = '$n' unless defined $theSep;

  # get the regexes
  $theInclude = join("|", split(/\s*,\s*/, $theInclude)) if $theInclude;
  $theExclude = join("|", split(/\s*,\s*/, $theExclude)) if $theExclude;

  #_writeDebug("theSearch=$theSearch");
  #_writeDebug("thisWeb=$thisWeb");
  #_writeDebug("theWebs=$theWebs");
  #_writeDebug("thePattern=$thePattern");
  #_writeDebug("theSplit=$theSplit");
  #_writeDebug("theHeader=$theHeader");
  #_writeDebug("theFormat=$theFormat");
  #_writeDebug("theFooter=$theFooter");
  #_writeDebug("theSep=$theSep");
  #_writeDebug("theFields=$theFields");

  # build seach object
  my $search;
  if (defined $theSearch && $theSearch ne '') {
    $search = new Foswiki::Contrib::DBCacheContrib::Search($theSearch);
    unless ($search) {
      return "ERROR: can't parse query $theSearch";
    }
  }

  # get webs
  my @webs;
  if ($theWebs) {
    if ($theWebs eq 'all') {
      @webs = Foswiki::Func::getListOfWebs();
    } else {
      @webs = split(/\s*,\s*/, $theWebs);
    }
  } else {
    push @webs, $thisWeb;
  }
  my $isMultipleWebs = scalar(@webs) > 1 ? 1 : 0;

  # compute statistics
  my $wikiName = Foswiki::Func::getWikiName();
  my %statistics = ();

  foreach my $web (@webs) {
    my $theDB = $this->getDB($web);
    return _inlineError("ERROR: DBSTATS can't find web '$web'") unless $theDB;

    my @topicNames;
    if ($thisTopics) {
      @topicNames = split(/\s*,\s*/, $thisTopics);
    } else {
      @topicNames = $theDB->getKeys();
    }
    foreach my $topicName (@topicNames) {    # loop over all topics
      my $topicObj = $theDB->fastget($topicName);
      next unless $topicObj;
      next if $search && !$search->matches($topicObj);    # that match the query
      next unless $theDB->checkAccessPermission('VIEW', $wikiName, $topicObj);

      my $fullTopicName = $isMultipleWebs ? "$web.$topicName" : $topicName;
      #_writeDebug("found topic $topicName");
      my $createDate = $topicObj->fastget('createdate');
      my $modified = $topicObj->get('info.date');
      my $publishDate = $topicObj->get('publishdate') || 0;
      foreach my $field (split(/\s*,\s*/, $theFields)) {    # loop over all fields

        #my $fieldValue = $topicObj->fastget($field);
        my $fieldValue = $topicObj->get($field);
        $fieldValue = $topicObj->getFieldValue($field) if !defined($fieldValue) || ref($fieldValue);
        next unless defined $fieldValue; 

        my $command = $params->{process} // $params->{"process_".$field};
        if (defined $command) {
          $command = Foswiki::Func::decodeFormatTokens($command);
          $command =~ s/\$value/$fieldValue/g;
          if ($command =~ /%/) {
            $fieldValue = Foswiki::Func::expandCommonVariables($command, $topicName, $web);
          } else {
            $fieldValue = $command;
          }
        } else {
          $fieldValue = _formatTime($fieldValue, $theDateFormat, {language => $theDateLanguage} ) if $field =~ /created(ate)?|modified|publishdate/;
        }
        #_writeDebug("reading field $field found $fieldValue");

        foreach my $item (split(/$theSplit/, $fieldValue)) {
          while ($item =~ /$thePattern/g) {                 # loop over all occurrences of the pattern
            my @keyList = ($1 // "", $2 // "", $3 // "", $4 // "" , $5 // "");
            my $key = $keyList[$theKeyNumber];
            $key = lc($key) if $theCase;
            if ($theCase) {
              next if $theExclude && $key =~ /$theExclude/;
              next if $theInclude && $key !~ /$theInclude/;
            } else {
              next if $theExclude && $key =~ /$theExclude/i;
              next if $theInclude && $key !~ /$theInclude/i;
            }
            my $record = $statistics{$key};
            if ($record) {
              $record->{count}++;
              $record->{createdate_from} = $createDate if $record->{createdate_from} > $createDate;
              $record->{createdate_to} = $createDate if $record->{createdate_to} < $createDate;
              $record->{modified_from} = $modified if $record->{modified_from} > $modified;
              $record->{modified_to} = $modified if $record->{modified_to} < $modified;
              $record->{publishdate_from} = $publishDate if defined $publishDate && $record->{publishdate_from} > $publishDate;
              $record->{publishdate_to} = $publishDate if defined $publishDate && $record->{publishdate_to} < $publishDate;
              $record->{topics}{$isMultipleWebs?$fullTopicName:$topicName} = 1;
              $record->{keyList} = _mergeLists($record->{keyList}, \@keyList);
            } else {
              $record = {
                count => 1,
                modified_from => $modified,
                modified_to => $modified,
                createdate_from => $createDate,
                createdate_to => $createDate,
                publishdate_from => $publishDate,
                publishdate_to => $publishDate,
                keyList => \@keyList,
                topics => {$isMultipleWebs?$fullTopicName:$topicName => 1},
              };
              $statistics{$key} = $record;
            }
          }
        }
      }
    }
  }

  my $min = 99999999;
  my $max = 0;
  my $sum = 0;
  foreach my $key (keys %statistics) {
    my $record = $statistics{$key};
    $min = $record->{count} if $min > $record->{count};
    $max = $record->{count} if $max < $record->{count};
    $sum += $record->{count};
  }
  my $numkeys = scalar(keys %statistics);
  my $mean = 0;
  $mean = (($sum + 0.0) / $numkeys) if $numkeys;
  return '' if $theHideNull && $numkeys == 0;

  # format output
  my @sortedKeys;
  if ($theSort =~ /^modified(from)?$/) {
    @sortedKeys = sort { $statistics{$a}->{modified_from} <=> $statistics{$b}->{modified_from} } keys %statistics;
  } elsif ($theSort eq 'modifiedto') {
    @sortedKeys = sort { $statistics{$a}->{modified_to} <=> $statistics{$b}->{modified_to} } keys %statistics;
  } elsif ($theSort =~ /^created(from)?$/) {
    @sortedKeys = sort { $statistics{$a}->{createdate_from} <=> $statistics{$b}->{createdate_from} } keys %statistics;
  } elsif ($theSort eq 'createdto') {
    @sortedKeys = sort { $statistics{$a}->{createdate_to} <=> $statistics{$b}->{createdate_to} } keys %statistics;
  } elsif ($theSort =~ /^publishdate(from)?$/) {
    @sortedKeys = sort { $statistics{$a}->{publishdate_from} <=> $statistics{$b}->{publishdate_from} } keys %statistics;
  } elsif ($theSort eq 'publishdateto') {
    @sortedKeys = sort { $statistics{$a}->{publishdate_to} <=> $statistics{$b}->{publishdate_to} } keys %statistics;
  } elsif ($theSort eq 'count') {
    @sortedKeys = sort {
           $statistics{$a}->{count} <=> $statistics{$b}->{count}
        or $statistics{$b}->{modified_from} <=> $statistics{$a}->{modified_from}
        or    # just to break ties
        $statistics{$b}->{modified_to} <=> $statistics{$a}->{modified_to}
        or $a cmp $b
    } keys %statistics;
  } else {
    @sortedKeys = sort keys %statistics;
  }
  @sortedKeys = reverse @sortedKeys if $theReverse;
  my $index = 0;
  my @result = ();
  foreach my $key (@sortedKeys) {
    $index++;
    my $record = $statistics{$key};
    my $text;
    my ($key1, $key2, $key3, $key4, $key5) =
      @{$record->{keyList}};
    my $line = _expandVariables(
      $theFormat,
      $thisWeb,
      $thisTopic,
      'web' => $thisWeb,
      'topics' => join(', ', sort keys %{$record->{topics}}),
      'key' => $key,
      'key1' => $key1,
      'key2' => $key2,
      'key3' => $key3,
      'key4' => $key4,
      'key5' => $key5,
      'count' => $record->{count},
      'index' => $index,
    );
    push @result, $line;

    last if $theLimit && $index == $theLimit;
  }

  return "" unless @result;

  my $text = _expandVariables(
    $theHeader . join($theSep, @result) . $theFooter, $thisWeb, $thisTopic,
    'min' => $min,
    'max' => $max,
    'sum' => $sum,
    'mean' => $mean,
    'keys' => $numkeys,
  );

  return _expandFormatTokens($text);
}

###############################################################################
sub handleDBDUMP {
  my ($this, $session, $params, $theTopic, $theWeb) = @_;

  #_writeDebug("called handleDBDUMP");

  my $baseWeb = $session->{webName};
  my $baseTopic = $session->{topicName};
  my $thisTopic = $params->{_DEFAULT} // $baseTopic;
  my $thisWeb = $params->{web} // $baseWeb;
  ($thisWeb, $thisTopic) = Foswiki::Func::normalizeWebTopicName($thisWeb, $thisTopic);

  #$Foswiki::Plugins::DBCachePlugin::addDependency->($thisWeb, $thisTopic);

  return $this->dbDump($thisWeb, $thisTopic);
}

###############################################################################
sub restDBDUMP {
  my ($this, $session) = @_;

  my $web = $session->{webName};
  my $topic = $session->{topicName};

  return $this->dbDump($web, $topic);
}

###############################################################################
sub dbDump {
  my ($this, $web, $topic) = @_;

  my $session = $Foswiki::Plugins::SESSION;

  my $wikiName = Foswiki::Func::getWikiName();
  return _inlineError("ERROR: access denied")
    unless Foswiki::Func::checkAccessPermission("VIEW", $wikiName, undef, $topic, $web);

  my $theDB = $this->getDB($web);
  return _inlineError("ERROR: DBDUMP can't find web '$web'") unless $theDB;

  my $topicObj = $theDB->fastget($topic) // '';
  unless ($topicObj) {
    return _inlineError("DBCachePlugin: $web.$topic not found");
  }
  my $result = "\n<noautolink><div class='foswikiDBDump'>\n";
  $result .= "<h2 > [[$web.$topic]]</h2>\n";
  $result .= _dbDumpMap($topicObj);
  return $result . "\n</div></noautolink>\n";
}

###############################################################################
sub handleDBRECURSE {
  my ($this, $session, $params, $theTopic, $theWeb) = @_;

  #_writeDebug("called handleDBRECURSE(" . $params->stringify() . ")");

  my $baseWeb = $session->{webName};
  my $baseTopic = $session->{topicName};
  my $thisTopic = $params->{_DEFAULT} // $params->{topic} // $baseTopic;
  my $thisWeb = $params->{web} // $baseWeb;
  my $doWarnings = Foswiki::Func::isTrue($params->{warn}, 1);

  ($thisWeb, $thisTopic) = Foswiki::Func::normalizeWebTopicName($thisWeb, $thisTopic);

  $params->{format} //= '   $indent* [[$web.$topic][$topic]]';
  $params->{single} //= $params->{format};
  $params->{separator} //= $params->{sep} // "\n";
  $params->{header} //= '';
  $params->{subheader} //= '';
  $params->{singleheader} //= $params->{header};
  $params->{footer} //= '';
  $params->{subfooter} //= '';
  $params->{singlefooter} //= $params->{footer};
  $params->{hidenull} //= 'off';
  $params->{filter} //= 'parent=\'$name\'';
  $params->{sort} //= $params->{order} // 'name';
  $params->{reverse} //= 'off';
  $params->{limit} //= 0;
  $params->{skip} //= 0;
  $params->{depth} //= 0;

  $params->{format} = '' if $params->{format} eq 'none';
  $params->{single} = '' if $params->{single} eq 'none';
  $params->{header} = '' if $params->{header} eq 'none';
  $params->{footer} = '' if $params->{footer} eq 'none';
  $params->{subheader} = '' if $params->{subheader} eq 'none';
  $params->{subfooter} = '' if $params->{subfooter} eq 'none';
  $params->{singleheader} = '' if $params->{singleheader} eq 'none';
  $params->{singlefooter} = '' if $params->{singlefooter} eq 'none';
  $params->{separator} = '' if $params->{separator} eq 'none';

  $params->{include} = join("|", split(/\s*,\s*/, $params->{include})) if $params->{include};
  $params->{exclude} = join("|", split(/\s*,\s*/, $params->{exclude})) if $params->{exclude};

  # query topics
  my $theDB = $this->getDB($thisWeb);
  unless ($theDB) {
    return $doWarnings ? _inlineError("ERROR: DBRECURSE can't find web '$thisWeb'") : "";
  }

  $params->{_count} = 0;
  my $result;
  my $error;

  try {
    $result = $this->formatRecursive($theDB, $thisWeb, $thisTopic, $params);
  }
  catch Error::Simple with {
    $error = shift->stringify();
  };

  if ($error) {
    return $doWarnings ? _inlineError($error) : "";
  }

  # render result
  return '' if $params->{hidenull} eq 'on' && $params->{_count} == 0;

  my $text = _expandVariables((($params->{_count} == 1) ? $params->{singleheader} : $params->{header}) . join($params->{separator}, @$result) . (($params->{_count} == 1) ? $params->{singlefooter} : $params->{footer}), $thisWeb, $thisTopic, count => $params->{_count});

  return _expandFormatTokens($text);
}

###############################################################################
sub formatRecursive {
  my ($this, $theDB, $theWeb, $theTopic, $params, $seen, $depth, $number) = @_;

  # protection agains infinite recursion
  $seen ||= {};
  return if $seen->{$theTopic};
  $seen->{$theTopic} = 1;
  $depth //= 0;
  $number //= '';

  return if $params->{depth} && $depth >= $params->{depth};
  return if $params->{limit} && $params->{_count} >= $params->{limit};

  #_writeDebug("called formatRecursive($theWeb, $theTopic)");
  return unless $theTopic;

  # search sub topics
  my $queryString = $params->{filter};
  $queryString =~ s/\$ref\b/$theTopic/g;    # backwards compatibility
  $queryString =~ s/\$name\b/$theTopic/g;

  #_writeDebug("queryString=$queryString");
  my $hits = $theDB->dbQuery($queryString, undef, $params->{sort}, $params->{reverse}, $params->{include}, $params->{exclude});

  # format this round
  my @result = ();
  my $index = 0;
  my $nrTopics = $hits->count;
  while (my $topicObj = $hits->next) {
    my $topicName = $topicObj->fastget("topic");
    next if $topicName eq $theTopic;        # cycle, kind of
    next if $seen->{$topicName};

    $params->{_count}++;
    next if $params->{_count} <= $params->{skip};

    # format this
    my $numberString = ($number) ? "$number.$index" : $index;

    my $text = ($nrTopics == 1) ? $params->{single} : $params->{format};
    $text = _expandVariables(
      $text, $theWeb, $theTopic,
      'web' => $theWeb,
      'topic' => $topicName,
      'number' => $numberString,
      'index' => $index,
      'count' => $params->{_count},
    );
    $text =~ s/\$indent\((.+?)\)/$1 x $depth/ge;
    $text =~ s/\$indent/'   ' x $depth/ge;

    # SMELL: copied from DBQUERY
    $text =~ s/\$formfield\((.*?)\)/
      my $temp = $theDB->getFormField($topicName, $1);
      $temp =~ s#\)#${TranslationToken}#g;
      $temp =~ s#\r?\n#$params->{newline}#gs if defined $params->{newline};
      $temp/ge;
    $text =~ s/\$expand\((.*?)\)/
      my $temp = $theDB->expandPath($topicObj, $1);
      $temp =~ s#\)#${TranslationToken}#g;
      $temp/ge;
    $text =~ s/\$formatTime\((.*?)(?:,\s*'([^']*?)')?\)/_formatTime($theDB->expandPath($topicObj, $1), $2)/ge;    # single quoted

    push @result, $text;

    # recurse
    my $subResult = $this->formatRecursive($theDB, $theWeb, $topicName, $params, $seen, $depth + 1, $numberString);

    if ($subResult && @$subResult) {
      push @result,
        _expandVariables(
        $params->{subheader}, $theWeb, $topicName,
        'web' => $theWeb,
        'topic' => $topicName,
        'number' => $numberString,
        'index' => $index,
        'count' => $params->{_count},
        )
        . join($params->{separator}, @$subResult)
        . _expandVariables(
        $params->{subfooter}, $theWeb, $topicName,
        'web' => $theWeb,
        'topic' => $topicName,
        'number' => $numberString,
        'index' => $index,
        'count' => $params->{_count},
        );
    }

    last if $params->{limit} && $params->{_count} >= $params->{limit};
  }

  return \@result;
}

###############################################################################
sub getWebKey {
  my ($this, $web) = @_;

  $web =~ s/\./\//g;

  unless (defined $this->{webKeys}{$web}) {
    unless (Foswiki::Sandbox::validateWebName($web)) {
      print STDERR "WARNING: invalid web name '$web'\n";
      return;
    }
    my $dir = $Foswiki::cfg{DataDir} . '/' . $web;
    unless (-d $dir) {
      print STDERR "WARNING: cannot find directory '$dir' for web '$web'\n";
      return;
    }
    $this->{webKeys}{$web} = Cwd::fast_abs_path($dir);
  }

  return $this->{webKeys}{$web};
}

###############################################################################
sub getDB {
  my ($this, $theWeb, $refresh) = @_;

  die "no web" unless defined $theWeb;
  $theWeb =~ s/\//./g;

  $refresh = $this->{doRefresh} unless defined $refresh;
  $refresh = 0 if $refresh && $this->{doneRefreshWeb}{$theWeb};
  $this->{doneRefreshWeb}{$theWeb} = 1;

  _writeDebug("called getDB($theWeb, ".($refresh||0).")");

  my $webKey = $this->getWebKey($theWeb);
  unless (defined $webKey) {
    print STDERR "WARNING: invalid web name '$theWeb'\n";
    return;
  }

  _writeDebug("webKey=$webKey");

  my $db = $webDB{$webKey};
  my $isModified;

  if ($db) {
    $isModified = $this->{isModifiedDB}{$webKey};
    unless (defined $isModified) {
      $isModified = $db->getArchivist->isModified();
      $this->{isModifiedDB}{$webKey} = 0 unless $isModified;    # only cache a negative result
    }
  } else {
    $isModified = 1;
  }

  if ($isModified || $refresh ) {
    if ($this->{_reloading}{$theWeb}) { # prevent infinite recursion
      print STDERR "WARNING: already reloading $theWeb\n";
    } else {
      $this->{_reloading}{$theWeb} = 1;

      _writeDebug("need to load again, isModified=$isModified, refresh=$refresh");
      $db = $webDB{$webKey} = $this->newDB($theWeb);
      $db->load($refresh);

      my $session = $Foswiki::Plugins::SESSION;
      my $baseWeb = $session->{webName};
      my $baseTopic = $session->{topicName};
      if ($baseWeb eq $theWeb) {
        $db->load($refresh, $baseWeb, $baseTopic);
      }
      $this->{_reloading}{$theWeb} = 0;
    }
  }

  return $db;
}

###############################################################################
sub newDB {
  my ($this, $web) = @_;

  my $impl;

  if (ENABLE_WEBDB_FEATURE) { 
    $impl = Foswiki::Func::getPreferencesValue('WEBDB', $web)
      || 'Foswiki::Plugins::DBCachePlugin::WebDB';

    $impl =~ s/^\s+//g;
    $impl =~ s/\s+$//g;
  } else {
    $impl = 'Foswiki::Plugins::DBCachePlugin::WebDB';
  }

  #_writeDebug("loading new webdb for '$web'");
  return $impl->new($web);
}

###############################################################################
sub unloadDB {
  my ($this, $web) = @_;

  return unless $web;

  delete $webDB{$web};
  delete $this->{webKeys}{$web};
  delete $this->{isModifiedDB}{$web};
}

###############################################################################
sub finish {
  my $this = shift;

  undef $this->{isModifiedDB};
  undef $this->{dbcalls};
  undef $this->{currentWeb};
  undef $this->{doRefresh};
  undef $this->{doneRefreshWeb};
  undef %webDB unless $Foswiki::cfg{DBCachePlugin}{MemoryCache};
}

###############################################################################
# from Foswiki::_INCLUDE
sub fixInclude {
  my $this = shift;
  my $thisWeb = shift;
  # $text next

  my $removed = {};

  # Must handle explicit [[]] before noautolink
  # '[[TopicName]]' to '[[Web.TopicName][TopicName]]'
  $_[0] =~ s/\[\[([^\]]+)\]\]/$this->fixIncludeLink($thisWeb, $1)/ge;
  # '[[TopicName][...]]' to '[[Web.TopicName][...]]'
  $_[0] =~ s/\[\[([^\]]+)\]\[([^\]]+)\]\]/$this->fixIncludeLink($thisWeb, $1, $2)/ge;

  $_[0] = _takeOutBlocks($_[0], 'noautolink', $removed);

  # 'TopicName' to 'Web.TopicName'
  $_[0] =~ s/(^|[\s(])($this->{webNameRegex}\.$this->{wikiWordRegex})/$1$TranslationToken$2/g;
  $_[0] =~ s/(^|[\s(])($this->{wikiWordRegex})/$1\[\[$thisWeb\.$2\]\[$2\]\]/g;
  $_[0] =~ s/(^|[\s(])$TranslationToken/$1/g;

  _putBackBlocks(\$_[0], $removed, 'noautolink');
}

###############################################################################
# from Foswiki::fixIncludeLink
sub fixIncludeLink {
  my ($this, $theWeb, $theLink, $theLabel) = @_;

  # [[...][...]] link
  if ($theLink =~ /^($this->{webNameRegex}\.|$this->{defaultWebNameRegex}\.|$this->{linkProtocolPattern}\:|\/)/o) {
    if ($theLabel) {
      return "[[$theLink][$theLabel]]";
    } else {
      return "[[$theLink]]";
    }
  } elsif ($theLabel) {
    return "[[$theWeb.$theLink][$theLabel]]";
  } else {
    return "[[$theWeb.$theLink][$theLink]]";
  }
}

###############################################################################
sub currentWeb {
  my ($this, $val) = @_;

  $this->{currentWeb} = $val if defined $val;
  return $this->{currentWeb};
}

###############################################################################
# static methods
###############################################################################
sub _dbDump {
  my $obj = shift;

  return "undef" unless defined $obj;

  if (ref($obj)) {
    if (ref($obj) eq 'ARRAY') {
      return join(", ", sort @$obj);
    } elsif (ref($obj) eq 'HASH') {
      return _dbDumpHash($obj);
    } elsif ($obj->isa("Foswiki::Contrib::DBCacheContrib::Map")) {
      return _dbDumpMap($obj);
    } elsif ($obj->isa("Foswiki::Contrib::DBCacheContrib::Array")) {
      return _dbDumpArray($obj);
    }
  }

  return "<verbatim>\n$obj\n</verbatim>";
}

###############################################################################
sub _dbDumpList {
  my $list = shift;

  my @result = ();

  foreach my $item (@$list) {
    push @result, _dbDump($item);
  }

  return join(", ", @result);
}

###############################################################################
sub _dbDumpHash {
  my $hash = shift;

  my $result = "<table class='foswikiTable'>\n";

  foreach my $key (sort keys %$hash) {
    $result .= "<tr><th>$key</th><td>\n";
    $result .= _dbDump($hash->{$key});
    $result .= "</td></tr>\n";
  }

  return $result . "</table>\n";
}

###############################################################################
sub _dbDumpArray {
  my $array = shift;

  my $result = "<table class='foswikiTable'>\n";

  my $index = 0;
  foreach my $obj (sort $array->getValues()) {
    $result .= "<tr><th>";
    if (UNIVERSAL::can($obj, "fastget")) {
      $result .= ($obj->fastget('name') // '');
    } else {
      $result .= $index;
    }
    $result .= "</th><td>\n";
    $result .= _dbDump($obj);
    $result .= "</td></tr>\n";
    $index++;
  }

  return $result . "</table>\n";
}

###############################################################################
sub _dbDumpMap {
  my $map = shift;

  my $result = "<table class='foswikiTable'>\n";

  my @keys = sort { lc($a) cmp lc($b) } $map->getKeys();

  foreach my $key (@keys) {
    $result .= "<tr><th>$key</th><td>\n";
    $result .= _dbDump($map->fastget($key));
    $result .= "</td></tr>\n";
  }

  return $result . "</table>\n";
}

###############################################################################
sub _expandFormatTokens {
  my $text = shift;

  return '' unless defined $text;

  $text =~ s/\$perce?nt/\%/g;
  $text =~ s/\$nop//g;
  $text =~ s/\$n/\n/g;
  $text =~ s/\$encode\((.*?)\)/_entityEncode($1)/ges;
  $text =~ s/\$quotes\((.*?)\)/_quotesEncode($1)/ges;
  $text =~ s/\$trunc\((.*?),\s*(\d+)\)/substr($1,0,$2)/ges;
  $text =~ s/\$lc\((.*?)\)/lc($1)/ge;
  $text =~ s/\$uc\((.*?)\)/uc($1)/ge;
  $text =~ s/\$dollar/\$/g;

  return $text;
}

###############################################################################
sub _expandVariables {
  my ($text, $web, $topic, %params) = @_;

  return '' unless defined $text;

  while (my ($key, $val) = each %params) {
    $text =~ s/\$$key\b/$val/g if defined $val;
  }

  return $text;
}

###############################################################################
# fault tolerant wrapper
sub _formatTime {
  my ($string, $format, $params) = @_;

  return "" if $string eq "" || $string eq "0";
  my $epoch = Foswiki::Contrib::DBCacheContrib::parseDate($string);
  return "" unless defined($epoch) && $epoch != 0;

  return Foswiki::Func::formatTime($epoch, $format, undef, $params);
}

###############################################################################
# used to encode rss feeds
sub _rss {
  my ($text, $web, $topic) = @_;

  $text = "\n<noautolink>\n$text\n</noautolink>\n";
  $text = Foswiki::Func::renderText($text);
  $text =~ s/\b(onmouseover|onmouseout|style)=".*?"//g;    # TODO filter out more not validating attributes
  $text =~ s/<nop>//g;
  $text =~ s/[\n\r]+/ /g;
  $text =~ s/\n*<\/?noautolink>\n*//g;
  $text =~ s/([[\x01-\x09\x0b\x0c\x0e-\x1f"%&'*<=>@[_\|])/'&#'.ord($1).';'/ge;
  $text =~ s/^\s+|\s+$//gs;

  return $text;
}

###############################################################################
sub _translate {
  my ($string, $web, $topic) = @_;

  return "" unless defined $string && $string ne "";

  my $result;

  $string =~ s/^_+//; # strip leading underscore as maketext doesnt like it

  my $context = Foswiki::Func::getContext();
  if ($context->{'MultiLingualPluginEnabled'}) {
    require Foswiki::Plugins::MultiLingualPlugin;
    $result = Foswiki::Plugins::MultiLingualPlugin::translate($string, $web, $topic);
  } else {
    my $session = $Foswiki::Plugins::SESSION;
    $result = $session->i18n->maketext($string);
  }

  $result //= $string;

  return $result;
}

###############################################################################
sub _quotesEncode {
  my $text = shift;

  $text =~ s/\"/\\"/g;
  return $text;
}

###############################################################################
sub _entityEncode {
  my $text = shift;

  $text =~ s/([[\x01-\x09\x0b\x0c\x0e-\x1f"%&'*<=>\\@[_\|])/'&#'.ord($1).';'/ge;

  return $text;
}

###############################################################################
sub _entityDecode {
  my $text = shift;

  $text =~ s/&#(\d+);/chr($1)/ge;
  return $text;
}

###############################################################################
sub _quoteEncode {
  my $text = shift;

  $text =~ s/\"/\\"/g;

  return $text;
}

###############################################################################
sub _urlEncode {
  my $text = shift;

  $text = Encode::encode_utf8($text) if $Foswiki::UNICODE;
  $text =~ s/([^0-9a-zA-Z-_.:~!*'\/%])/sprintf('%02x',ord($1))/ge;

  return $text;
}

###############################################################################
sub _urlDecode {
  my $text = shift;

  $text =~ s/%([\da-f]{2})/chr(hex($1))/gei;

  return $text;
}

###############################################################################
sub _flatten {
  my ($text, $web, $topic) = @_;

  my $session = $Foswiki::Plugins::SESSION;
  my $topicObject = Foswiki::Meta->new($session, $web, $topic);
  $text = $session->renderer->TML2PlainText($text, $topicObject);

  $text =~ s/(https?)/<nop>$1/g;
  $text =~ s/[\r\n\|]+/ /gm;
  $text =~ s/!!//g;
  return $text;
}

###############################################################################
sub _extractPattern {
  my ($topicObj, $pattern) = @_;

  my $text = $topicObj->fastget('text') || '';
  my $result = '';
  while ($text =~ /$pattern/gs) {
    $result .= ($1 || '');
  }

  return $result;
}

###############################################################################
sub _inlineError {
  return "<div class='foswikiAlert'>$_[0]</div>";
}

###############################################################################
# compatibility wrapper
sub _takeOutBlocks {
  return Foswiki::takeOutBlocks(@_) if defined &Foswiki::takeOutBlocks;
  return $Foswiki::Plugins::SESSION->renderer->takeOutBlocks(@_);
}

###############################################################################
sub _mergeLists {
  my ($l1, $l2) = @_;

  my $i = 0;
  my $len = scalar(@$l1);
  my @result = ();
  while ($i < $len) {
    my $item = $l1->[$i] || $l2->[$i] || '';
    push @result, $item;
    $i++;
  }
 
  return \@result;
}

###############################################################################
# compatibility wrapper
sub _putBackBlocks {
  return Foswiki::putBackBlocks(@_) if defined &Foswiki::putBackBlocks;
  return $Foswiki::Plugins::SESSION->renderer->putBackBlocks(@_);
}

###############################################################################
sub _writeDebug {
  #Foswiki::Func::writeDebug('- DBCachePlugin - '.$_[0]) if TRACE;
  print STDERR "- DBCachePlugin::Core - $_[0]\n" if TRACE;
}



1;

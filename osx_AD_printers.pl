#!/usr/bin/perl
### Add Windows print server printers based on matching group names ###
#
# Copyright Jason Van Pelt 2013
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#    See <http://www.gnu.org/licenses/>.
#
#   Given the following setup in AD
#
#   A printer on an AD print server with a share name that matches a group that the apple user or computer is a member of
#
#   Exmaple:
#
#   Printer share name: OFFICE-RM13-HP2200
#   Group name:         OFFICE-RM13-HP2200 
#
############## !!!WARNING!!! #################
#  $delete_printers=0 by default, meaning printers will be added by this script, but not deleted
#  Before turngin this setting on below ($delete_printers=1), you should check your configurations thoroughly
#  And once turned on, test thoroughly on computers that have manually added printers not connected to $print_server
#  Only printers that have the $print_server string in their path attribute and AD groups with the same name should be eligible for deletion
#  But it's up to you to test with your configs and make sure!
#  One way to be relatively sure it's safe is to use the fully qualified domain name for $print_server, not just the hostname
####################################

### SET CONFIGURATION NEXT PAGE DOWN ###

use strict;
use Data::Dumper;

local $ENV{PATH}="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/X11/bin:";

### Get user and host names
#
my $uid=$ARGV[0];
my $debug=$ARGV[1];
unless ($uid) {
  print "Usage: set_AD_printers.pl username [debug]\n";
  exit 1;
}
chomp($uid);

unless ($debug) {$debug=0;}

my $hostname=exec_command("hostname",0);
if ( $hostname=~ /([^\.]+)/) {
  $hostname=$1;
}
else {
  $hostname=undef;
}
debug("uid=$uid\nhostname=$hostname",0);
###

###### CONFIGURATION ######
#
# values for your domain
my $domain="[DC=example,DC=com]";
my $bind_user="cn=[bindname,CN=Users],$domain";
my $bind_pwd='[bindpwd]';
my $print_server="[print_server.example.com]";
my $ad_server='[ad_server.example.com]';
my $base_dn="DC=[base_dn],$domain";
my $debug_prefix="[Set_AD_Print_Log]:";
my $print_auth_method='password';  # $print_auth_method='password' is the default. Set to 'negotiate' if you have kerberos configured
# If using $print_auth_method='password', 
# specify a user and password for this printer to have all users use the same printer auth into. 
# Otherwise, leave both as empty strings to prompt user for logon info or if using kerberos
my $print_user=''; 
my $print_pwd=''; 
my $delete_printers=0;  #set to 1 to delete printers that match $printer_patterns, but for which the user/computer is not in a group
my $delete_mcx_printers=0;	#set to 1 to delete and replace mxc printers that would otherwise be managed by this script	

#  Patterns for your printers
#   If a group name matches the name pattern it is considered a printer group and added to %$ad_printers
#   'name': The name pattern should include 3 groups for location, room and model
#   If you want to exlcude one of these groups, use (.*?) in the pattern. 
#   For example, (.*?)(Rm\d+)-HP(\S+) would match Rm6-HP2200 with $location eq ''; $room eq 'Rm6'; $model eq '2200';
#
#   'model': The model subroutine is called with $model from above match passed as an argument
#   It translates the string into a model name recognized by the command: lpinfo --make-and-model [model] -m
#
#   'drivers': The first driver found for this model which matches one of the regexs in the drivers array is used to add the printer
#   If no matching driver is found then an error is reported

my $printer_patterns;
%$printer_patterns=(
  hp=>{
    'name'=>qr/(\w+)-(\w+)-hp(\S+)/i,         # matches something like: BldgA-Rm1-HP2200
    'model'=>sub { my ($model)=@_; return "LaserJet $model"},   # in the above example, would result in "LaserJet 2200"
    'drivers'=>[
      qr/^(Library.*\.gz)/,          # PPD drivers
      qr/(gutenprint.*expert)/        # gutenprint drivers
    ]
  }
);
###### end of config

### Make sure that the configurations seem valid
#
# check the $print_server setting
my $error=exec_command("ping -c 1 $print_server | grep -i \"bytes from\"",0);
if (!$error) { debug("$print_server could not be contacted",1); exit 1;}
# checj the $ad_server setting
$error=exec_command("ping -c 1 $ad_server | grep -i \"bytes from\"",0);
if (!$error) { debug("$ad_server could not be contacted",1); exit 1;}

###


my $print_auth='';
if ($print_auth_method eq 'password') {
  $print_auth_method='-o auth-info-required=username,password';
  if ($print_user && $print_pwd) {
    $print_auth="$print_user:$print_pwd\@";
  }
}
elsif ($print_auth_method eq 'kerberos') {
  $print_auth_method='-o auth-info-required=negotiate';
}
else {
  $print_auth_method='';
}



### get user and computer groups and combine into one hash
#
debug("\nGet groups for username: $uid",0);
my $user_groups=getGroupsForCN($uid);

my ($computer_groups,$groups);
if ($hostname) {
  debug("\nGet groups for hostname: $hostname",0);
  $computer_groups=getGroupsForCN($hostname);
}
else {
  debug("Computer hostname not set - only user groups will be used",1);
  %$computer_groups=();
}

%$groups=(%$user_groups,%$computer_groups);
if ($debug) {
  print "User groups:\n";
  print Dumper $user_groups;
  print "Computer groups:\n";
  print Dumper $computer_groups;
  print "\n\n";
}
###


### Get AD and locally installed printers 
#
my $local_printers=getLocalPrinters();

my $ad_printers=getADPrinters($groups);

###

### Remove shared printers not listed in AD
#
debug("\nAttempt to delete shared printers that shouldn't be connected anymore",0);
foreach my $local_printer (keys %$local_printers) {
  my $debug_msg="  Check if $local_printer should be installed";
  unless (defined $ad_printers->{$local_printer}) {
    if ($delete_printers) {
      debug("$debug_msg... try to delete",0);
      exec_command("/usr/sbin/lpadmin -x $local_printer",1);
    }
    else {
      debug("$debug_msg... \$delete_printers is turned off, but this should have been deleted",1);
    }
  }
  else {
    debug("$debug_msg... OK!",0);
  }
}
###

### Add printers from AD 
#
debug("\nAttempt to add missing printers",0);

foreach my $ad_printer (keys %$ad_printers) {
  if (!defined $local_printers->{$ad_printer}) {
    my $driver=$ad_printers->{$ad_printer}{driver};
    my $location=$ad_printers->{$ad_printer}{location};
    my $room=$ad_printers->{$ad_printer}{room};
    debug("  try to add $ad_printer",0);
    $driver =~ s/\ /\\ /g;
    exec_command("lpadmin -p $ad_printer $print_auth_method -v smb://$print_auth$print_server/$ad_printer -m $driver -L \"$location $room\" -E",1);
    $local_printers->{$ad_printer}=1; #if by some chance the same printer is listed twice this prevents adding twice
  }
}
###


### Check the results
#
debug("\n\nCheck results\n",0);
$local_printers=getLocalPrinters(); #see what printers are currently installed
my $error=0;
foreach my $ad_printer (keys %$ad_printers) {
  unless (defined $local_printers->{$ad_printer}) {
    debug("Adding $ad_printer was unsuccessful",1);
    $error=1;
  }
}
unless ($error) {
  debug("All shared printers set successfully",1);
}
if ($debug) {
  print "AD Printers:\n";
  print Dumper $ad_printers;
  print "Local Printers:\n";
  print Dumper $local_printers;
}
###

exit 0;

##### subroutines ######

### get locally installed printers
#   that connect to $print_server
#   and for which there are AD groups with the same name as the printer
#
sub getLocalPrinters {

  ## get list of printers currently on this computer
  my $local_printers=exec_command("/usr/bin/lpstat -s",0);
  my @local_printers=split(/\n/,$local_printers);
  my %local_printers=();

  foreach my $local_printer (@local_printers) {
    my @p=split(/\s+/,$local_printer);
    my $name=substr($p[2],0,-1);
    my $path=$p[3];
    if (!defined $local_printers{$path} 
      && (index($path,$print_server)>=0 && hasADGroup($name))
      || ($delete_mcx_printers && $name=~/^mcx/)) {

      debug("-- Printer: $name with path: $path is managed by this script\n",0);
      $local_printers{$name}=1;
    }
    else {
      debug("   Skip $name\n",0);
    }
  }
  return \%local_printers;
}
###


###### Test whether a printer name has an AD group
#
sub hasADGroup {
  my ($name)=@_;
  my $result=exec_command("ldapsearch -x -LLL -h $ad_server -b $base_dn -D $bind_user -E pr=2000/noprompt -w $bind_pwd '(cn=$name)' cn | grep -i \"cn: $name\"",0);
  return ($result=~/$name/i);
}
######

###### Get groups CN of which CN is a member, including nested groups
#
sub getGroupsForCN {
  my ($cn,$groups)=@_;
  unless ($groups) {%$groups=();}

  my $result=exec_command("ldapsearch -x -LLL -h $ad_server -b $base_dn -D $bind_user -E pr=2000/noprompt -w $bind_pwd '(cn=$cn)' memberof",0);
  my @lines=split(/\n/,$result);
  foreach my $line (@lines) {
    if ($line=~/memberOf:\s+([\s\S]+)/) {
      my $group_list=$1;
      my @groups=split(/;/,$group_list);
      foreach my $group (@groups) {
        if ($group=~/CN=([^,]+)/i) {
          my $gname=$1;
          unless (defined $groups->{$gname}) {
            $groups->{$gname}=0;
          }
        }
      }
    }
  }
  ### get nested groups for any new to the list
  foreach my $gname (keys %$groups) {
    unless ($groups->{$gname}) {
      $groups->{$gname}=1;
      getGroupsForCN($gname,$groups);
    }
  }
  return $groups;
}
######


### iterate through the array of groups and parse out the name and domain to build a list of printer groups
#
#   this uses $printer_patterns, which are similar to
# $printer_patterns=(
#  hp=>{
#    name=>qr/(\w+)-(\w+)-hp(\S+)/i,         # matches something like DO-TECH-HP2200
#    model=>sub { ($model)=@_; return "LaserJet $model"},     # in the above example, would result in "LaserJet 2200"
#    drivers=>[
#      qr/(gutenprint.*expert)/        # matches a gutenprint print driver name
#    ]
#  }
# );
#
#  This first match for model name with a valid driver is used
#
sub getADPrinters {
  debug("\nFind AD printers that should be installed for this computer/user",0);
  my $ad_printers=();
  foreach my $gname (keys %$groups) {
    foreach my $pattern (keys %$printer_patterns) {
      my $pattern=$printer_patterns->{$pattern};
      ## check if the group name matches a pattern for a printer
      if ($gname =~ $pattern->{name}) {
        my ($location,$room,$model)=($1,$2,$3);
        my $driver_model=&{$pattern->{model}}($model);
        debug (" matches $gname: location=$location, room=$room, model=$model, driver_model=$driver_model",0);

        ## list available drivers for this model
        my $printer_driver=undef;
        my $drivers=exec_command("lpinfo --make-and-model '$driver_model' -m",0);
        my @drivers=split(/\n/,$drivers);

        ## check if an available driver is in the list to use
        foreach my $driver (@drivers) {
          foreach my $driver_pattern (@{$pattern->{drivers}}) {
            if ($driver=~$driver_pattern) {
              $printer_driver=$1;
              last;
            }
          }
        }

        ## add the printer and its driver to the list if it all matched
        if ($printer_driver) {
          debug ("-- $gname using $printer_driver is a match",0);
          %{$ad_printers->{uc($gname)}}=(
            'driver'=>$printer_driver,
            'location'=>$location,
            'room'=>$room,
            'model'=>$model,
            'driver_model'=>$driver_model
          );
          last;
        }
        else {
          debug("!!! No matching driver found for $gname",1);
        }
      }
    }
  }
  return $ad_printers;
}
###

### debug to syslog and stdout depending on $debug value
#
sub debug {
  my ($msg,$log)=@_;
  if ($debug || $log) {
    print "$msg\n";
  }

  if ($log) {
    $msg=~s/"/\\"/g;
    `logger "$debug_prefix $msg"`;
  }

}
###

### execute a command, returning the result as a string
# The command is also passed to debug($command,$log)
# $log=0 default, or 1 to log the command (excluding result) to syslog
#
sub exec_command {
  my ($command,$log)=@_;
  unless ($log) {$log=0;}
  debug($command,$log);
  return `$command`;
}
###

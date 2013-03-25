# Add AD printer server printers to OSX clients by AD Group


## Required:
* A typical Active Directory domain setup
* OSX clients bound to AD and set to authenticate users against AD
* Printers added to an AD or samba print server, using patterns for their share names
* An AD security gorup for each shared printer, with the same name as the printer's share name

## Usage:
* Setup as describe above
* Place users, computer or groups of either into one or more of the groups created above
* Set this script to run as a logon script
	Simple method: as root run: defaults write com.apple.loginwindow LogonHook [path_to_script]
	Better method: include this script in a more robust logon script setup
	In either case, the script needs to receive the current username as an argument:
		osx_AD_printers.pl [username]

## Configuration:
Modify settings for your domain in the configuration section starting around line 55

Modify the printer patterns hash to match your naming scheme, printers and drivers

Patterns for your printers
If a group name matches the name pattern it is considered a printer group and added to %$ad_printers

'name': The name pattern should include 3 match groups for location, room and model
If you want to exlcude one of these groups, use (.*?) in the pattern. 
For example, /(.*?)(Rm\d+)-HP(\S+)/ would match Rm6-HP2200 with $location eq ''; $room eq 'Rm6'; $model eq '2200';

'model': The model subroutine is called with $model from above match passed as an argument
It translates the string into a model name recognized by the command: lpinfo --make-and-model [model] -m

'drivers': The first driver found for this model which matches one of the regexs in the drivers array is used to add the printer
If no matching driver is found then an error is reported

%$printer_patterns=(
        hp=>{
                'name'=>qr/(\w+)-(\w+)-hp(\S+)/i,                               # matches something like DO-TECH-HP2200
                'model'=>sub { my ($model)=@_; return "LaserJet $model"},       # in the above example, would result in "LaserJet 2200"
                'drivers'=>[
                        qr/(gutenprint.*expert)/                                # matches a gutenprint print driver name
                ]
        }
);

## Authentication
By default printers will be added with the -o auth-info-required=username,password option and no username or password specified.  
This requires the user to enter their auth info when they print, but should let them save it in Keychain

You may set a global username and password which are inserted into the printer URI if you're not too concerned with security
Make sure this account has only the privileges needed to print, but no access to anything else!

Setting $print_auth_method='kerberos' theoretically allows printing to work using kerberos authentication if your system is setup properly, but I have not tested it.

If you change the authentication settings in the configs, this will only affect subsequently (re)added printers, not those which have already been added.

## Removing printers
If you remove a user/computer from all groups which would result in it having a shared printer installed, the printer is removed from the system
This only applies to printers which are shared from $print_server. 


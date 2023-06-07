#######################################################################################################
#
# 58_DaikinCloud.pm 
#
# This modul ist used for control indoor units connected to the Daikin Cloud (EU).
# It is required, that the indoor units already are connected to the internet and 
# the registration process in the Daikin-ONECTA App is finished. If the indoor units 
# doesn't appear in the Daikin-ONECTA App, they will also not appear in this modul!
#
# The connections to the cloud and the complex parse of the data are non-blocking.
#
#######################################################################################################
# v1.3.4 - 22.05.2023 fix: change/check order of set-cmd fanSpeed, fanLevel and demandValue
# v1.3.3 - 09.05.2023 fix set-cmd "offset" 
# v1.3.2 - 01.05.2023 fix: after failed refresh access-token -> do new authorizationrequest
# v1.3.1 - 20.04.2023 fix set-cmd for "setpoints_leavingWaterOffset"
# v1.3.0 - 18.04.2023 implement multiple managementpoint support (for Altherma)
# v1.2.0 - 12.04.2023 implement rawDataRequest, settables only as climateControl
# v1.1.0 - 08.04.2023 integrate kWh calculation, add state-reading, add short-commands for on|off
# v1.0.4 - 07.04.2023 check isCloudConnectionUp before sent commands
# v1.0.3 - 07.04.2023 shorten error logs (remove repeated message-content)
# v1.0.2 - 06.04.2023 fix feedback error on incorrect set commands
# v1.0.1 - 24.03.2023 separate the attributes for master/indoor units devices
# v1.0.0 - 22.03.2023 finale release
# v0.4.0 - 18.03.2023 validationcheck for set commands
# v0.3.0 - 18.03.2023 switch to non-blocking functions
# v0.2.0 - 15.03.2023 create seperat settables, setlists for every indoor unit
# v0.1.0 - 08.03.2023 create authorizationrequest, refresh access-token, update-data process
#######################################################################################################

package main;

use strict;
use warnings;

use Time::HiRes qw(gettimeofday time);
use Scalar::Util qw(looks_like_number);
use HttpUtils;
use Blocking;

my $OPENID_CLIENT_ID = '7rk39602f0ds8lk0h076vvijnb';
my $DaikinCloud_version = 'v1.3.4 - 22.05.2023';

sub DaikinCloud_Initialize($)
{
	my ($hash) = @_;
	$hash->{DefFn}    = 'DaikinCloud_Define';
	$hash->{NotifyFn} = 'DaikinCloud_Notify';
	$hash->{UndefFn}  = 'DaikinCloud_Undefine';
	$hash->{SetFn}    = 'DaikinCloud_Set';
	$hash->{GetFn}    = 'DaikinCloud_Get';
	$hash->{AttrFn}   = 'DaikinCloud_Attr';
}

#######################################################################################################
######  handle define: create only one IO-MASTER (as a bridge) and indoor units with DEVICE-ID  #######
#######################################################################################################

sub DaikinCloud_Define($$)
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);
	my $name = shift @a;
	my $type = shift @a; # always DaikinCloud
	my $dev_id = (@a ? shift(@a) : undef);

	return 'Syntax: define <name> DaikinCloud [device-id]' if(int(@a));

	## handle define of indoor units
	if (defined($dev_id)) {
		my $defptr = $modules{DaikinCloud}{defptr}{IOMASTER};
		return 'Please define master device for cloud access first! Syntax: define <name> DaikinCloud' if(!defined($defptr));
		return 'Cannot modify master device to indoor unit device!' if($hash eq $modules{DaikinCloud}{defptr}{IOMASTER});
		$modules{DaikinCloud}{defptr}{$dev_id} = $hash;
		setDevAttrList($name, 'consumptionData:1,0 '. $readingFnAttributes);
		if ($init_done) {
			CommandAttr(undef, '-silent '.$name.' devStateIcon on:Ventilator_wind@green off:Ventilator_fett@black');
			CommandAttr(undef, '-silent '.$name.' event-on-change-reading .*');
			CommandAttr(undef, '-silent '.$name.' room DaikinCloud_Devices');
			CommandAttr(undef, '-silent '.$name.' webCmd onOffMode:setpoint:operationMode');
			CommandAttr(undef, '-silent '.$name.' webCmdLabel Power<br>:Temperatur<br>:Modus<br>');
		}
	## handle define of IO-MASTER device as a bridge
	} else {
		my $defptr = $modules{DaikinCloud}{defptr}{IOMASTER};
		return "Master device already defined as $defptr->{NAME} !" if( defined($defptr) && $defptr->{NAME} ne $name);
		$hash->{INTERVAL} = 60;
		$hash->{VERSION} = $DaikinCloud_version;
		$modules{DaikinCloud}{defptr}{IOMASTER} = $hash;
		setDevAttrList($name, 'autocreate:1,0 interval consumptionData:1,0 '. $readingFnAttributes);
		if ($init_done) {
			CommandAttr(undef, '-silent '.$name.' autocreate 1');
			CommandAttr(undef, '-silent '.$name.' interval 60');
			CommandAttr(undef, '-silent '.$name.' consumptionData 1');
			CommandAttr(undef, '-silent '.$name.' room DaikinCloud_Devices');				
		}
	}
	return undef;
}

#######################################################################################################
#######################  notify init_done: restore tokens from readings  ##############################
#######################################################################################################

sub DaikinCloud_Notify($$)
{
	my ($hash,$dev) = @_;
	my $name = $hash->{NAME};
	return if($dev->{NAME} ne 'global');
	return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));
	if ( my $token = ReadingsVal($name, '.access_token', undef) ) {
		Log3 $name, 4, 'DaikinCloud (Notify at start): restoring access_token from reading successful.';
		$hash->{helper}{ACCESS_TOKEN} = $token;
	}
	if ( my $token = ReadingsVal($name, '.refresh_token', undef) ) {
		Log3 $name, 4, 'DaikinCloud (Notify at start): restoring refresh_token from reading successful.';
		$hash->{helper}{REFRESH_TOKEN} = $token;
	} 
	return undef;
}

#######################################################################################################
##########################  handle undefine: delete defptr, remove timers  ############################
#######################################################################################################

sub DaikinCloud_Undefine($$)
{
	my ($hash, $arg) = @_;
	my $iomaster = $modules{DaikinCloud}{defptr}{IOMASTER};
	
	if ( defined($iomaster) && $hash eq $iomaster ) {
		setKeyValue('DaikinCloud_username',undef);
		setKeyValue('DaikinCloud_password',undef);
		delete $modules{DaikinCloud}{defptr}{IOMASTER}; 
		RemoveInternalTimer($hash);
	}
	delete $modules{DaikinCloud}{defptr}{$hash->{DEF}} if (defined($hash->{DEF}));
	BlockingKill($hash->{helper}{RUNNING_CALL}) if (defined($hash->{helper}{RUNNING_CALL}));
	return undef;
}

######################  function to save username and password encrypted  #############################

sub DaikinCloud_encrypt($)
{
	my ($decoded) = @_;
	my $key = getUniqueId();
	my $encoded;
	for my $char (split //, $decoded) {
		my $encode = chop($key);
		$encoded .= sprintf("%.2x",ord($char)^ord($encode));
		$key = $encode.$key;
	}
	return $encoded;
}

##########################  function to decrypt username and password  ################################

sub DaikinCloud_decrypt($)
{
	my ($encoded) = @_;
	my $key = getUniqueId();
	my $decoded;
	for my $char (map { pack('C', hex($_)) } ($encoded =~ /(..)/g)) {
		my $decode = chop($key);
		$decoded .= chr(ord($char)^ord($decode));
		$key = $decode.$key;
	}
	return $decoded;
}

#######################################################################################################
#####################  return possible set - commands for actual operationMode  #######################
#######################################################################################################

sub DaikinCloud_setlist($)
{
	my ($hash) = @_;
	## check if settable exists
	my $table = $hash->{helper}{table}; 
	return 'No settable found! Please forceUpdate first! ','' if (!defined($table) || (ref($table) ne 'HASH'));	
	## create setlist
	my $setlist = '';
	foreach my $key (sort keys %{$table}) {
		if ($key =~ m/^([^:]+):.*_value_operationModes_([^_]+)/i) {
			## check the actual operation mode of the device / managementpoint
			my $appendix = '_'.$1;
			my $mode2 = $2;
			$appendix = '' if ($appendix =~ m/climateControl/i);
			my $mode = ReadingsVal($hash->{NAME}, 'operationMode'.$appendix, '0');
			$setlist .= $table->{$key}.' ' if ($mode eq $mode2);
		}  else {
			$setlist .= $table->{$key}.' ';					
		}
	}
	## merge vertical an horizontal entry to cmd "swing"
	if (($setlist =~ m/vertical:/) && ($setlist =~ m/horizontal:/)) {
		$setlist .= 'swing:stop,horizontal,vertical,3dswing';
		$setlist .= ',windNice' if ($setlist =~ m/windNice/);
		$setlist .= ' ';
	}
	## merge fanMode and fanLevel entry to cmd "fanSpeed"
	if (($setlist =~ m/fanLevel:slider/) && ($setlist =~ m/fanMode:([^ ]*)/)) {
		my $nofixed = $1; 
		$nofixed =~ s/,?fixed// ;
		$setlist .= 'fanSpeed:'.$nofixed;
		$setlist =~ m/fanLevel:slider,(\d+),(\d+),(\d+)/;
		for (my $i = $1; $i <= $3; $i+=$2) { 
			$setlist .= ",Level$i";
		}	
	}		
	return 'No settable found! Please forceUpdate first! ','' if ($setlist eq '');
	return '',$setlist;
}

#######################################################################################################
##############################  handle set - commands  ################################################
#######################################################################################################

sub DaikinCloud_Set($$$$)
{
	my ($hash, $name, @a) = @_;
	return undef if not scalar @a;
	my $cmd = shift @a;
	my $value = join(' ', @a);
	my $setlist = '';
	my $iomaster = $modules{DaikinCloud}{defptr}{IOMASTER};
	
	if ( defined($iomaster) && ($hash eq $iomaster)) {
	## set for IOMASTER
		if ( lc($cmd) eq 'username'){
			$value = DaikinCloud_encrypt($value);
			setKeyValue('DaikinCloud_username',$value);
			if (getKeyValue('DaikinCloud_username') eq $value) {
				readingsSingleUpdate($hash, 'state', 'username saved', 1 );
				return;
			}
			readingsSingleUpdate($hash, 'state', 'error saving username', 1 );
			return 'Unknown error while saving username!'; 
		} elsif ( lc($cmd) eq 'password'){
			$value = DaikinCloud_encrypt($value);
			setKeyValue('DaikinCloud_password',$value);
			if (getKeyValue('DaikinCloud_password') eq $value) {
				readingsSingleUpdate($hash, 'state', 'password saved', 1 );
				return;
			}
			readingsSingleUpdate($hash, 'state', 'error saving password', 1 );
			return 'Unknown error while saving password!';
		} else {
			$setlist = 'username password';
		}
	## prepare setlist to show possible commands for indoor units	
	} elsif (($cmd eq '?') || ($cmd eq '')) {
		(undef,$setlist) = DaikinCloud_setlist($hash);
		return "unknown argument $cmd : $value, choose one of $setlist";
		
	## set for indoor units
	} else {
		my $err = ''; 
		## check if device connected #fix v1.0.4
		return "Cannot sent $cmd for $name to Daikin-Cloud, because unit is offline!" if (ReadingsVal($name, 'isCloudConnectionUp', 'unknown' ) eq 'false');
		($err,$setlist) = DaikinCloud_setlist($hash);
		return $err if ($err ne '');
		
		## check actual mode/setpoint of the device / managementpoint
		my $appendix = '';
		$appendix = $1 if ($cmd =~ m/^[^_]+(_.*)$/i);
		my $mode = ReadingsVal($name, 'operationMode'.$appendix, 'unknown');
		my $setpoint = ReadingsVal($name, 'setpoint'.$appendix, 'unknown');
		#v1.3.3 fix for set-cmd offset		
		if ($cmd =~ /offset|setpoint|demandControl|fanMode|horizontal|vertical|econoMode|streamerMode|onOffMode|powerfulMode/i) {
			$err .= DaikinCloud_CheckAndQueue($hash,$cmd,$value,$mode);
			
		## quick command on|off for onOffMode 
		} elsif ($cmd eq 'on' || $cmd eq 'off' ) {
			$err .= DaikinCloud_CheckAndQueue($hash,'onOffMode',$cmd,$mode);
			
		## if fanLevel is set, the fanMode must be set to fixed	
		} elsif ($cmd eq 'fanLevel' ) {
			$err .= DaikinCloud_CheckAndQueue($hash,'fanMode','fixed',$mode) if (ReadingsVal($name, 'fanMode', 'unknown') ne 'fixed'); #check if not fixed
			$err .= DaikinCloud_CheckAndQueue($hash,'fanLevel',$value,$mode);
			
		## if fanSpeed is set, the correct mode must also be set
		} elsif ($cmd eq 'fanSpeed' ) {
			if ($value =~ m/Level(\d)/) {
				$err .= DaikinCloud_CheckAndQueue($hash,'fanMode','fixed',$mode) if (ReadingsVal($name, 'fanMode', 'unknown') ne 'fixed'); #check if not fixed
				$err .= DaikinCloud_CheckAndQueue($hash,'fanLevel',$1,$mode);
			} else {
				$err .= DaikinCloud_CheckAndQueue($hash,'fanMode',$value,$mode);
			}
			readingsSingleUpdate($hash, $cmd, $value, 1 ) if ($err eq '');
			
	    ## if swing is set, the possible fanDirections (if available) has to be set
		} elsif ($cmd eq 'swing' ) {
			if ($value eq 'stop' ) {
				$err .= DaikinCloud_CheckAndQueue($hash,'horizontal','stop',$mode)   if ($setlist =~ m/horizontal:/i );
				$err .= DaikinCloud_CheckAndQueue($hash,'vertical','stop',$mode)     if ($setlist =~ m/vertical:/i );
			} elsif  ($value eq 'horizontal' ) {
				$err .= DaikinCloud_CheckAndQueue($hash,'horizontal','swing',$mode)  if ($setlist =~ m/horizontal:/i );
				$err .= DaikinCloud_CheckAndQueue($hash,'vertical','stop',$mode)     if ($setlist =~ m/vertical:/i );
			} elsif  ($value eq 'vertical' ) {
				$err .= DaikinCloud_CheckAndQueue($hash,'horizontal','stop',$mode)   if ($setlist =~ m/horizontal:/i );
				$err .= DaikinCloud_CheckAndQueue($hash,'vertical','swing',$mode)    if ($setlist =~ m/vertical:/i );
			} elsif  ($value eq '3dswing' ) {
				$err .= DaikinCloud_CheckAndQueue($hash,'horizontal','swing',$mode)  if ($setlist =~ m/horizontal:/i );
				$err .= DaikinCloud_CheckAndQueue($hash,'vertical','swing',$mode)    if ($setlist =~ m/vertical:/i );
			} elsif  ($value eq 'windNice' ) {
				$err .= DaikinCloud_CheckAndQueue($hash,'vertical','windNice',$mode) if ($setlist =~ m/vertical:/i );
			}
			readingsSingleUpdate($hash, $cmd, $value, 1 ) if ($err eq '');
		## if demandValue is set, the demandControl must be set to fixed	
		} elsif ($cmd =~ m/demandValue/i ) {
			$err .= DaikinCloud_CheckAndQueue($hash,'demandControl','fixed',$mode) if (ReadingsVal($name, 'demandControl', 'unknown') ne 'fixed');  #check if not fixed
			$err .= DaikinCloud_CheckAndQueue($hash,$cmd,$value,$mode);
		## if operationMode ist changed, setpoint, fanLevel, fanMode and possible fanDirections has to be set
		} elsif ($cmd =~ m/operationMode/i ){
			if (($value ne 'dry') && ($value ne 'fanOnly')){
				DaikinCloud_CheckAndQueue($hash,'setpoint',$setpoint,$value);
			}
			$err .= DaikinCloud_CheckAndQueue($hash,'horizontal',ReadingsVal($name,'horizontal','stop'),$value) if ($setlist =~ m/horizontal:/i );
			$err .= DaikinCloud_CheckAndQueue($hash,'vertical',ReadingsVal($name,'vertical','stop'),$value) if ($setlist =~ m/vertical:/i );
			$err .= DaikinCloud_CheckAndQueue($hash,'fanMode',ReadingsVal($name,'fanMode','auto'),$value) if ($setlist =~ m/fanMode:/i );
			$err .= DaikinCloud_CheckAndQueue($hash,'fanLevel',ReadingsVal($name,'fanLevel','1'),$value) if ($setlist =~ m/fanLevel:/i );
			$err .= DaikinCloud_CheckAndQueue($hash,$cmd,$value,$value);
			
		} else {
			$err .= "unknown argument $cmd, choose one of $setlist"; #fix v1.0.2
		}
		## all cmd & value are already in queue -> send the cmd to the cloud
		$err .= DaikinCloud_SetCmd();
		return $err if ($err ne '');
		return undef;
	}
}

#######################################################################################################
######################  initiate a non-blocking set cmd to the daikin cloud ###########################
#######################################################################################################

sub DaikinCloud_SetCmd()
{
	my $iomaster = $modules{DaikinCloud}{defptr}{IOMASTER};
	return 'No IOMASTER device found! ' if (!defined($iomaster));
	
	my $a_token = $iomaster->{helper}{ACCESS_TOKEN};
	return 'DaikinCloud_SetCmd: no access_token found! ' if (!defined($a_token));
	
	return '' if (!defined($iomaster->{helper}{setQueue}));
	## take a triple of the queue
	my $dev_id = shift @{$iomaster->{helper}{setQueue}};
	my $path   = shift @{$iomaster->{helper}{setQueue}};
	my $value  = shift @{$iomaster->{helper}{setQueue}};
	return '' if (!defined($dev_id) || !defined($path) || !defined($value) );
	
#	## cancel actual polling if activ and schedules next regular polling 
#	my $interval = $iomaster->{INTERVAL};
#	if (defined($interval) && ($interval>0 ))  {
#		RemoveInternalTimer($hash,'DaikinCloud_UpdateRequest');
#		InternalTimer(gettimeofday()+$interval, 'DaikinCloud_UpdateRequest', $hash, 0);
#	}	
	
	## prepare set cmd request
	my $body->{value} = $value;
	my ($embeddedId, $datapoint, $datapath) =  ($path =~ m/(.+):([^_]+)(.*)/);
	return 'DaikinCloud_SetCmd: Missing managementpoint or datapoint! Please forceUpdate first! ' if ((!defined($datapoint)) || (!defined($embeddedId)));
	if (defined($datapath) && ($datapath ne '')) {
		$datapath =~ s/^_value//g;
		$datapath =~ s/_/\//g;
		$body->{path} = $datapath;
	}
	my $data = toJSON($body);
	my $url  = 'https://api.prod.unicloud.edc.dknadmin.be/v1/gateway-devices/'.$dev_id;
	   $url .= '/management-points/'.$embeddedId.'/characteristics/'.$datapoint;
	
	my $header = {
		'user-agent' 	=> 'Daikin/1.6.1.4681 CFNetwork/1209 Darwin/20.2.0',
		'x-api-key'  	=> 'xw6gvOtBHq5b1pyceadRp6rujSNSZdjx2AqT03iC',
		'Authorization' => 'Bearer '.$a_token,
		'Content-Type'	=> 'application/json',
	};
	## save actual dev_id, cmd, value in params to give it back, when the cmd set fails
	my $param = { url => $url , timeout => 5, method => 'PATCH', hash => $iomaster, 
		header => $header, data => $data, dc_id => $dev_id, dc_path => $path, dc_value => $value,
		callback => \&DaikinCloud_SetCmdResponse };
		
	HttpUtils_NonblockingGet($param);
	return '';	
}

sub DaikinCloud_SetCmdResponse($)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	
	if ($err ne '') {
		Log3 $hash, 1, "DaikinCloud (SetCmd): $err";
		
	} elsif ($param->{code} == 401 ) {
		readingsSingleUpdate($hash, 'status_setcmd', 'refreshing token ...', 1 );
		Log3 $hash, 3, 'DaikinCloud (SetCmd): need to refresh access-token. Automatically starting DoRefresh!';
		## give cmd back to queue, update token and transmit command after refresh token
		unshift (@{$hash->{helper}{setQueue}},$param->{dc_id},$param->{dc_path},$param->{dc_value});
		DaikinCloud_DoRefresh($hash);
		
	} elsif (($param->{code} == 200) || ($param->{code} == 204)) {
		readingsSingleUpdate($hash, 'status_setcmd', 'command successfully submitted', 1 );
		Log3 $hash, 5, 'DaikinCloud (SetCmd): device '.$param->{dc_id}.' path: '.$param->{dc_path}.' value: '.$param->{dc_value};
		DaikinCloud_SetCmd();
		
	} else {
		readingsSingleUpdate($hash, 'status_setcmd', 'error in submitting command', 1 );
		Log3 $hash, 2, 'DaikinCloud (SetCmd): error setting command: '.$param->{data}.' http-status-code: '.$param->{code}.' data: '.$data;
	}
}

#######################################################################################################
##########  check the set command (hash, cmd, value, mode) and add to queue ###########################
#######################################################################################################

sub DaikinCloud_CheckAndQueue($$$$)
{
	my ($hash, $cmd, $value, $mode) = @_;
	my $dev_id = $hash->{DEF};
	return 'Unknown Device-ID! ' if (!defined($dev_id));
	my $iomaster = $modules{DaikinCloud}{defptr}{IOMASTER};
	return 'No IO-MASTER device found! ' if (!defined($iomaster));
	my $table = $hash->{helper}{table}; 
	return 'No settable in cache! Please forceUpdate first! ' if (!defined($table) || (ref($table) ne 'HASH'));
	my $datapath= '';
	## check if for the cmd exists a set-path 
	foreach my $key (sort keys %{$table}) {
		if ($key =~ m/_value_operationModes_([^_]+)/i) {
			if (($1 eq $mode ) && ($table->{$key} =~ m/^$cmd:/)) { 
				$datapath = $key;
			}
		} elsif ($table->{$key} =~ m/^($cmd):/) {
			$datapath = $key;
		}
		last if ($datapath ne '');
	}
	return "No datapath found for cmd: $cmd. : value: $value ! " if ( $datapath eq '');
	##check value
	my ($options) = ($table->{$datapath} =~ m/^$cmd:(.*)$/ );
	## is it a range of possible values, then check min, max, step
	if ($options =~ m/^slider,(-?\d+\.?\d*),(-?\d+\.?\d*),(-?\d+\.?\d*)/)  { #v1.3.3 fix for negativ offset
		if (($value < $1 ) || ($value > $3) || ((($3-$value) / $2) != int(($3-$value) / $2))) {
			return "cmd: $cmd. value: $value is out of range or step (min: $1 step: $2 max: $3)! ";
		## command and value are correct -> set them in queue
		} else {
			if (defined($iomaster->{helper}{setQueue}) && scalar(@{$iomaster->{helper}{setQueue}}) > 60) {
				Log3 $hash, 3, 'DaikinCloud (CheckAndQueue): too much set-commands in queue (>20)! Please check connection!';
				return 'Too much set-commands in queue (>20)! ';
			} else {
				push( @{$iomaster->{helper}{setQueue}} , $dev_id , $datapath, $value);
				readingsSingleUpdate($hash, $cmd, $value, 1 );
				return '';
			}	
		}
	## check if the possible values contain the set value
	} elsif ($options =~ m/($value)/) {
		## command and value are correct -> set them in queue
		if (defined($iomaster->{helper}{setQueue}) && scalar(@{$iomaster->{helper}{setQueue}}) > 60) {
			Log3 $hash, 3, 'DaikinCloud (CheckAndQueue): too much set-commands in queue (>20)! Please check connection!';
			return 'Too much set-commands in queue (>20)! ';
		} else {
			push( @{$iomaster->{helper}{setQueue}} , $dev_id , $datapath, $value);
			readingsSingleUpdate($hash, $cmd, $value, 1 );
			return '';
		}	
	} else {
		return "cmd: $cmd. value: $value is no possible option ($options)! ";
	}
}  

#######################################################################################################
##############################  handle get - commands  ################################################
#######################################################################################################

sub DaikinCloud_Get($$@)
{
	my ($hash, $name, @a) = @_;
	return undef if not scalar @a;
	my $cmd = shift(@a);
	my $value = join(' ', @a);
	my $setlist = '';
	my $iomaster = $modules{DaikinCloud}{defptr}{IOMASTER};

	if ( defined($iomaster) && $hash eq $iomaster ) {
	## get for IOMASTER
		if ( lc($cmd) eq 'tokenset') {
			my (undef, $username) = getKeyValue('DaikinCloud_username');
			return 'Please set username first!' if ( !defined($username) );
			my (undef, $password) = getKeyValue('DaikinCloud_password');
			return 'Please set password first!' if ( !defined($password) );
			return DaikinCloud_DoAuthorizationRequest($hash);
			
		} elsif ( lc($cmd) eq 'refreshtoken') {
			my $r_token = $hash->{helper}{REFRESH_TOKEN} ;
			return 'Please first get the tokenSet!' if ( !defined($r_token ) );
			return DaikinCloud_DoRefresh($hash);
			
		} elsif ( lc($cmd) eq 'forceupdate') {
			my $a_token = $hash->{helper}{ACCESS_TOKEN} ;
			return 'Please first get the tokenSet!' if ( !defined($a_token) );
			DaikinCloud_UpdateRequest($hash);
			return 'Going to update device data.';
		## fix v1.2.0 implement get rawData	
		} elsif ( lc($cmd) eq 'rawdata') {
			my $a_token = $hash->{helper}{ACCESS_TOKEN} ;
			return 'Please first get the tokenSet!' if ( !defined($a_token) );
			return DaikinCloud_RequestRawData($hash);
						
		} else {
			$setlist='forceUpdate:noArg tokenSet:noArg refreshToken:noArg rawData:noArg';
		}
	## get for indoor units
    } elsif ( lc($cmd) eq 'forceupdate') {
		my $a_token = $iomaster ->{helper}{ACCESS_TOKEN} if (defined($iomaster));
		return 'Please first get the tokenSet!' if ( !defined($a_token) );
		DaikinCloud_UpdateRequest($hash);
		return 'Going to update device data.';
	} elsif ($cmd eq 'setlist') {
		my ($err,$setcmd) = DaikinCloud_setlist($hash) ;
		$setcmd =~ s/ /\r\n/g;
		return $err if ($err ne '');
		return $setcmd;
	} else {
		$setlist='forceUpdate:noArg setlist:noArg';
	}
	return "unknown argument $cmd, choose one of $setlist" if ($setlist ne '');
	return undef;
}

#######################################################################################################
##############################  handle attribut changes  ##############################################
#######################################################################################################

sub DaikinCloud_Attr($$)
{
	my ($cmd, $name, $attrName, $attrVal) = @_;
	my $hash = $defs{$name};
  
	if ( $hash eq $modules{DaikinCloud}{defptr}{IOMASTER} ) { 
	## handle the change of IOMASTER attributes
		## handle the change of polling-interval
		if ( $attrName eq 'interval' ) {
			if ( $cmd eq 'del' ) {
				$attrVal = 0;
			}
			if ( $attrVal == 0 ) {
				RemoveInternalTimer($hash,'DaikinCloud_UpdateRequest');
				readingsSingleUpdate($hash, 'state', 'polling inactive', 1 );
			} else {
				$attrVal = 15 if ($attrVal < 15);
				RemoveInternalTimer($hash,'DaikinCloud_UpdateRequest');
				InternalTimer(gettimeofday()+1, 'DaikinCloud_UpdateRequest', $hash, 0);
			}
			$hash->{INTERVAL} = int($attrVal);
		## delete all energy_ readings if consumptionData in IOMASTER is deleted or "0"
		} elsif ( $attrName eq 'consumptionData' ) {
			if (( $cmd eq 'del' ) || ( $attrVal == 0 )) {
				CommandDeleteReading(undef,'-q TYPE=DaikinCloud ^energy_.*');
				CommandDeleteReading(undef,'-q TYPE=DaikinCloud ^kWh_.*');				
			}	
		} 
	## handle the change of indoor units attributes
	} elsif ( $attrName eq 'consumptionData' ) {
		if (( $cmd eq 'del' ) || ( $attrVal == 0 )) {
			CommandDeleteReading(undef,'-q $name ^energy_.*');				
		}
	}			
	return undef;  
}

sub DaikinCloud_RequestRawData($)
{
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
	return 'DaikinCloud_RequestRawData: error (0) no IOMASTER device found!' if (!defined($hash));
	my $a_token = $hash->{helper}{ACCESS_TOKEN};
	if (!defined($a_token)) {
		readingsSingleUpdate($hash, 'state', 'no access-token', 1 );
		return 'DaikinCloud_RequestRawData: error (1) no access_token found.' 
	};
	## define the header of the request with Bearer and access_token
	my $header = {
		'user-agent' 	=> 'Daikin/1.6.1.4681 CFNetwork/1209 Darwin/20.2.0',
		'x-api-key'  	=> 'xw6gvOtBHq5b1pyceadRp6rujSNSZdjx2AqT03iC',
		'Authorization' => 'Bearer '.$a_token,
		'Content-Type'	=> 'application/json',
	};	
	my $param = { timeout => 5, method => 'GET', header => $header,
	              url => 'https://api.prod.unicloud.edc.dknadmin.be/v1/gateway-devices' };
	## do the request
	my ($err,$response) = HttpUtils_BlockingGet($param);
	return "DaikinCloud_RequestRawData: error (2) $err" if($err ne '');
	return 'DaikinCloud_RequestRawData: error (2) need refresh access-token! http-statuscode: 401' if ($param->{code} == 401 );
	return 'DaikinCloud_RequestRawData: error (2) HTTP-Status-Code: '.$param->{code} if (($param->{code} != 200) || ($response eq ''));
	return $response;	
}


#######################################################################################################  
##################################  UpdateRequest #####################################################
#######################################################################################################

sub	DaikinCloud_UpdateRequest($)
{
	## my ($hash) = @_;
	## start UpdateRequest always as IOMASTER, because there is the tokenSet 
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
	return 'DaikinCloud_UpdateRequest: error (0) no IOMASTER device found!' if (!defined($hash));
	## is fhem start finished ? -> no -> wait 1 second
	if (!$init_done) {
		InternalTimer(gettimeofday()+1, 'DaikinCloud_UpdateRequest', $hash, 0);
		return;
	}
	my $a_token = $hash->{helper}{ACCESS_TOKEN};
	if (!defined($a_token)) {
		readingsSingleUpdate($hash, 'state', 'no access-token', 1 );
		return 'DaikinCloud_UpdateRequest: error (1) no access_token found.' 
	};
	return 'BlockingCall is almost running. Please wait!' if (defined($hash->{helper}{RUNNING_CALL}));
	
	## prepare subprocess
	$hash->{helper}{RUNNING_CALL} = BlockingCall('DaikinCloud_BlockUpdate',$hash->{NAME},
												 'DaikinCloud_BlockUpdateDone',15,
												 'DaikinCloud_BlockUpdateAbort',$hash); 
	$hash->{helper}{RUNNING_CALL}->{loglevel} = 4;
	## schedules next polling
	my $interval = $hash->{INTERVAL};
	if (defined($interval) && ($interval>0 )) {
		readingsSingleUpdate($hash, 'state', 'polling activ', 1 );
		InternalTimer(gettimeofday()+$interval, 'DaikinCloud_UpdateRequest', $hash, 0)	
	} else {
		readingsSingleUpdate($hash, 'state', 'polling inactive', 1 );
	}
	return undef;
}

sub DaikinCloud_BlockUpdateDone($)
{
	my ($string) = @_;
	return if (!defined($string));
	my ($name, @values ) = split( "\\|", $string);
	my $hash = $defs{$name};
	
	if (!defined($hash->{NAME})) { ## should never happen
		Log 1, 'DaikinCloud (BlockUpdateDone): error in device hash!';
		return;
	}
	delete ($hash->{helper}{RUNNING_CALL});
	
	if ($values[0]  =~ m/^error.*need refresh access-token/i ) {
		readingsSingleUpdate($hash, 'update_response', $values[0] , 1 );
		Log3 $hash, 3, 'DaikinCloud (BlockUpdateDone): need to refresh access-token. Automatically starting DoRefresh!';
		DaikinCloud_DoRefresh($hash);
		return;
	}	
	if ($values[0]  =~ m/^error/i ) {
		readingsSingleUpdate($hash, 'update_response', $values[0] , 1 );
		Log3 $hash, 2, 'DaikinCloud (BlockUpdateDone): '.$string;
		return;
	}	
	readingsSingleUpdate($hash, 'update_response', 'successful', 1 );
	
	## update readings
	while (scalar(@values)>1) {
		if ($values[0] eq 'SETTABLESDEVICEID') {
			last;
		} elsif (($values[0] eq 'FHEMDEVICEID') && ($values[2] eq 'NAME')) {
			shift @values; my $dev_id = shift @values;
			shift @values; my $dev_name = shift @values;			
			readingsSingleUpdate($hash, $dev_name, $dev_id, 1 );
			my $defptr = $modules{DaikinCloud}{defptr}{$dev_id};
			## if not defined -> check if autocreate is set -> then define device
			if (!defined($defptr)) {
				if (AttrVal($name,'autocreate',undef)) {
					$dev_name = 'DaikinCloud_'.$dev_name;
					$dev_name =~ s/[^A-Za-z0-9_]/_/g;
					my $define = "$dev_name DaikinCloud $dev_id";
					if( my $cmdret = CommandDefine(undef,$define) ) {
						Log3 $dev_name, 1, "DaikinCloud (BlockUpdateDone) autocreate: An error occurred while creating device for $dev_id (name: $dev_name): $cmdret ";
					}
					$defptr = $modules{DaikinCloud}{defptr}{$dev_id};
				}
			}			
			## update readings
			if (defined($defptr)) {
				readingsBeginUpdate($defptr);					
				while (scalar(@values)>1) {
					if (($values[0] ne 'FHEMDEVICEID') && ($values[0] ne 'SETTABLESDEVICEID')) {
						readingsBulkUpdate($defptr, shift @values, shift @values);
					} else {
						last;
					}
				}
				readingsEndUpdate($defptr,1);
			}
		} else {
			shift @values; 
			shift @values;
		}			
	}
	## create settable for each indoor unit device
	my %table;
	while (scalar(@values)>1) {
		if ($values[0] eq 'SETTABLESDEVICEID') {
			shift @values; my $dev_id = shift @values;
			while ((scalar(@values)>1) && ($values[0] ne 'SETTABLESDEVICEID')) {
				$table{$dev_id}{$values[0]} = $values[1];
				shift @values; 
				shift @values;
			}
		}
	}
	## save possbible set cmds and datapoints to each indoor unit device
	foreach my $key (sort keys %table) {
		my $defptr = $modules{DaikinCloud}{defptr}{$key};
		if (defined($defptr)) {
			delete $defptr->{helper}{table} if (defined($defptr->{helper}{table}));
			$defptr->{helper}{table} = $table{$key};
		}
	}	
}		

sub DaikinCloud_BlockUpdateAbort($) 
{ 
	my ($hash) = @_; 
	delete ($hash->{helper}{RUNNING_CALL});
	Log3 $hash, 3, 'DaikinCloud (BlockUpdateAbort): BlockingCall aborted (timeout).';
}

## child process
sub DaikinCloud_BlockUpdate($)
{
	my ($name) = @_;
	my $hash = $defs{$name};
	return $name.'|error (1) in device hash!' if (!defined($hash) || !defined($hash->{NAME}));
	## is access-token available?!
	my $a_token = $hash ->{helper}{ACCESS_TOKEN};
	return $name.'|error (2) no access_token found.' if (!defined($a_token));
	## define the header of the request with Bearer and access_token
	my $header = {
		'user-agent' 	=> 'Daikin/1.6.1.4681 CFNetwork/1209 Darwin/20.2.0',
		'x-api-key'  	=> 'xw6gvOtBHq5b1pyceadRp6rujSNSZdjx2AqT03iC',
		'Authorization' => 'Bearer '.$a_token,
		'Content-Type'	=> 'application/json',
	};	
	my $param = { timeout => 5, method => 'GET', header => $header,
	              url => 'https://api.prod.unicloud.edc.dknadmin.be/v1/gateway-devices' };
	## do the request
	my ($err,$response) = HttpUtils_BlockingGet($param);
	return $name."|error (3) $err" if($err ne '');
	return $name.'|error (3) need refresh access-token! http-statuscode: 401' if ($param->{code} == 401 );
	return $name.'|error (3) HTTP-Status-Code: '.$param->{code} if (($param->{code} != 200) || ($response eq ''));

    my %emID;   ## embeddedIds
	my %dev_id; ## device-ids
	my %dp;     ## traversed datapoints    {device-id}{managementpoint}{datapointpath} = value 
	my %dd;     ## devicedata for readings {device-id}{readingsname} = value
	my %table;  ## settable for possible set-commands
	my %period = ( m => 'year', w => 'week', d => 'day' );
	
	my $neg_filter = 'schedule|consumptionData';	
	$neg_filter = 'schedule' if (AttrVal($hash->{NAME},'consumptionData',undef)); 

	## convert take some times ...
	my $raw = json2nameValue($response,'_',\%table,'',$neg_filter); #($in, $prefix, $map, $filter, $negFilter)
	
	## get device-ids and embedded-ids
	foreach my $key (sort keys %{$raw}) {
		if ($key =~ m/_id$/i ) {
			my ($nr) = ($key =~ m/^_(\d+)_/i );
			$dev_id{$nr} = $raw->{$key} if (defined($nr));
		} elsif ($key =~ m/embeddedId$/i ) {
			my ($nr,$mp) = ($key =~ m/^_(\d+)_managementPoints_(\d+)_/i );
			$emID{$nr}{$mp} = $raw->{$key} if (defined($nr) && defined($mp));	
		} 		
	}
	
	## traverse data in {device-id}{managementpoint}{datapointpath} = value 
	foreach my $key (sort keys %{$raw}) {
		my ($nr) = ($key =~ m/^_(\d+)_/i );
		my ($mp,$skey) = ($key =~ m/managementPoints_(\d+)__?(.*)/i );
		if (!defined($mp) || !defined($skey)) {
			my ($dat) = ($key =~ m/^_\d+__?([^_]*)/i );
			$dd{$dev_id{$nr}}{$dat} = $raw->{$key};
		} else {					   
			$dp{$dev_id{$nr}}{$emID{$nr}{$mp}}{$skey} = $raw->{$key};
			$dd{$dev_id{$nr}}{'managementPoint_Nr_'.$mp} = $emID{$nr}{$mp};
		}			
	}
	
	## explore data for each detected device-id
	foreach my $devID (sort keys %dp) {
		my $eopt = 0;
		my $dev_name = $modules{DaikinCloud}{defptr}{$devID}->{NAME};
		$eopt = AttrVal($dev_name,'consumptionData',0) if (defined($dev_name));
		
		## handle each management-point seperatly
		foreach my $mp (sort keys %{$dp{$devID}}) {
			
			## check actual mode to store only real values of the actual mode
			my $mode = '';
			$mode = $dp{$devID}{$mp}{operationMode_value} if (defined($dp{$devID}{$mp}{operationMode_value}));
			
			## append managementpoint to avoid doubles if managementpoint is not climateControl
			my $appendix = '';
			$appendix = '_'.$mp if ($mp !~ m/climateControl/i);
			
			## check each key entry of the managementpoint
			foreach my $key (sort keys %{$dp{$devID}{$mp}}) {
				
				## filter settable entrys
				if ($key =~ m/_settable$/i ) {
					if ($dp{$devID}{$mp}{$key} eq 'true') {
						my ($path) = ($key =~ m/^(.*)_settable$/i );
						my $setcmd = $path;
						## save range und step to "$table" if min, max and step ist available
						## for setcmds: setpoint, demandValue, fanLevel
						if (defined($dp{$devID}{$mp}{$path.'_minValue'}) 
							&& defined($dp{$devID}{$mp}{$path.'_maxValue'}) 
							&& defined($dp{$devID}{$mp}{$path.'_stepValue'})) 
						{							
							if ($path =~ m/temperatureControl_value_operationModes_.*setpoints_.*Temperature/i) {
								$setcmd = 'setpoint';
							} elsif ($path =~ m/temperatureControl_value_operationModes_.*setpoints_.*Offset/i) {
								$setcmd = 'offset';
							} elsif ($path =~ m/demandControl_value_modes_fixed/i) {
								$setcmd = 'demandValue';
							} elsif ($path =~ m/_fanSpeed_modes_fixed/i) {
								$setcmd = 'fanLevel';
							}
							## append managementpoint to avoid doubles
							$table{$devID}{$mp.':'.$path} = $setcmd.$appendix.':slider,'
							.$dp{$devID}{$mp}{$path.'_minValue' }.','
							.$dp{$devID}{$mp}{$path.'_stepValue'}.','
							.$dp{$devID}{$mp}{$path.'_maxValue' }.',1';
						## save	possible options (values_1 bis max values_10) to "table" 
						## for setcmds: demandControl, fanMode, horizontal, vertical and other table	
						} elsif (defined($dp{$devID}{$mp}{$path.'_values_1'})) {
							if ($path =~ m/demandControl_value_currentMode/i) {
								$setcmd = 'demandControl';
							} elsif ($path =~ m/_fanSpeed_currentMode/i) {
								$setcmd = 'fanMode';
							} elsif ($path =~ m/_fanDirection_horizontal_currentMode/i) {
								$setcmd = 'horizontal';
							} elsif ($path =~ m/_fanDirection_vertical_currentMode/i) {
								$setcmd = 'vertical';
							} 						
							$table{$devID}{$mp.':'.$path} = $setcmd.$appendix.':';
							for (my $i = 1; $i < 10; $i++) {
								if (defined($dp{$devID}{$mp}{$path.'_values_'.$i})) {
									if ($dp{$devID}{$mp}{$path.'_values_'.$i} ne 'scheduled') {
										$table{$devID}{$mp.':'.$path} .= $dp{$devID}{$mp}{$path.'_values_'.$i} .',';
									}
								}						
							}
							chop($table{$devID}{$mp.':'.$path}); # delete last komma
						}
					}
				
				## process value-entrys
				} elsif ($key =~ m/(.*)_value$/i ) { 
					my $subpath = $1;
					my $point = '';
					## if datapoint equal actual $mode, take the value and shorten the key
					if ($key =~ m/_value_operationModes_/i) { 
						if ($key =~ m/_value_operationModes_($mode)_(.*)$/i) {
							my $para = $2;
							if ( $para =~ m/fanDirection_horizontal/i )  { $point = 'horizontal'; }
							elsif ( $para =~ m/fanDirection_vertical/i ) { $point = 'vertical'; }
							elsif ( $para =~ m/fanSpeed_currentMode/i )  { $point = 'fanMode'; }
							elsif ( $para =~ m/fanSpeed_modes_fixed/i )  { $point = 'fanLevel'; }
							elsif ( $para =~ m/setpoints_.*Temperature/i ) { $point = 'setpoint'; }	
							elsif ( $para =~ m/setpoints_.*Offset/i ) { $point = 'offset'; }	
						}					
					} elsif ($key =~ m/sensoryData_value_([^_]+)/i) { ## for indoor-|outdoor-temp
						$point = $1; 
					} elsif ($key =~ m/demandControl.*_currentMode/i) { 
						$point = 'demandControl'; 
					} elsif ($key =~ m/demandControl.*_fixed/i) { 
						$point = 'demandValue'; 
					} else { 
						$point = $subpath;
					}
					## append managementpoint for multiple keys or if key already exists 
					if (($key =~ m/(isIn|isHoliday|errorCode|firmware|iconId|modelInfo|software)/i) ||
					(defined($dd{$devID}{$point}))) {
						$point .= '_'.$mp;
					}		
					## transfer key if point if specified				
					$dd{$devID}{$point} = $dp{$devID}{$mp}{$key} if ($point ne '');
				
				## calculate sums of energy consumption
				} elsif ($key =~ m/consumptionData_value_electrical_(.*)_([m|w|d])_(\d+)$/i ) {
					$dd{$devID}{'energy_'.$1.'_'.$2.'_'.$3.'_'.$mp} = $dp{$devID}{$mp}{$key} if ($eopt);
					if ((looks_like_number($dp{$devID}{$mp}{$key})) && ((($3 > 12) && (($2 eq 'm') || ($2 eq 'd'))) || (($3 > 7) && ($2 eq 'w')))) {
						if (defined($dd{$devID}{'kWh_'.$1.'_'.$period{$2}.$appendix})) {
							$dd{$devID}{'kWh_'.$1.'_'.$period{$2}.$appendix} += $dp{$devID}{$mp}{$key};
						} else {
							$dd{$devID}{'kWh_'.$1.'_'.$period{$2}.$appendix} = $dp{$devID}{$mp}{$key};;
						}
					}
				}
				
			} ## end of key-entry loop
			
		} ## end of managementpoint loop
		
		## at the end foreach device check merging values:
		## merge $dd vertical and horizontal to swing
		if (defined($dd{$devID}{vertical}) && defined($dd{$devID}{horizontal})) {
			if ($dd{$devID}{horizontal} eq 'stop') {
				$dd{$devID}{swing} = 'vertical'   if ($dd{$devID}{vertical} eq 'swing');
				$dd{$devID}{swing} = 'stop' 	    if ($dd{$devID}{vertical} eq 'stop');
				$dd{$devID}{swing} = 'windNice'   if ($dd{$devID}{vertical} eq 'windNice');
			} elsif ($dd{$devID}{horizontal} eq 'swing') { 
				$dd{$devID}{swing} = '3dswing'    if ($dd{$devID}{vertical} eq 'swing');
				$dd{$devID}{swing} = 'horizontal' if ($dd{$devID}{vertical} eq 'stop');
				$dd{$devID}{swing} = 'windNice'   if ($dd{$devID}{vertical} eq 'windNice');
			}			
		}
		## merge $devicedate fanLevel and fanMode to fanSpeed
		if (defined($dd{$devID}{fanLevel}) && defined($dd{$devID}{fanMode})) {
			if ($dd{$devID}{fanMode} eq 'fixed') {
				$dd{$devID}{fanSpeed} = 'Level'.$dd{$devID}{fanLevel};
			} else { 
				$dd{$devID}{fanSpeed} = $dd{$devID}{fanMode};
			}			
		}
		## add state-reading
		$dd{$devID}{state} = $dd{$devID}{onOffMode} if (defined($dd{$devID}{onOffMode}));
	}
		
	## prepare for telnet callback
	my $ret = $name;
	## transfer device-readings
	foreach my $key (sort keys %dd) {
		if (ref($dd{$key}) eq 'HASH'){
			$dd{$key}{name} = $dd{$key}{id} if ($dd{$key}{name} eq '');
			$ret .= '|FHEMDEVICEID|'.$key.'|NAME|'.$dd{$key}{name};
			foreach my $subkey (sort keys %{$dd{$key}}) {
				$ret .= '|'.$subkey.'|'.$dd{$key}{$subkey} if (defined($dd{$key}{$subkey}));
			}
		}		
	}
	## transfer table (set-cmds)
	foreach my $key (sort keys %table) {
		if (ref($table{$key}) eq 'HASH'){
			$ret .= '|SETTABLESDEVICEID|'.$key;
			foreach my $subkey (sort keys %{$table{$key}}) {
				$ret .= '|'.$subkey.'|'.$table{$key}{$subkey};
			}
		}		
	}
	return $ret;	
}

###############################################################################################
######################  get access_token with login username password  ########################
###############################################################################################

sub	DaikinCloud_DoAuthorizationRequest($)
{
	my ($hash) = @_;
	return 'Authorizationprocess is almost running. Please wait!' if (defined($hash->{helper}{RUNNING_CALL}));
	$hash->{helper}{RUNNING_CALL} = BlockingCall('DaikinCloud_BlockAuth',$hash->{NAME},
												 'DaikinCloud_BlockAuthDone',15,
												 'DaikinCloud_BlockAuthAbort',$hash); 
	$hash->{helper}{RUNNING_CALL}->{loglevel} = 4;
	readingsSingleUpdate($hash, 'login_status', 'starting login ...', 1 );
	return 'Authorizationprocess started. Trying to get the tokenSet.';
}

sub DaikinCloud_BlockAuthDone($)
{
	my ($string) = @_;
	return if (!defined($string));
	my ($name, @values ) = split( "\\|", $string);
	my $hash = $defs{$name};
	if (!defined($hash->{NAME})) {
		Log 1, 'DaikinCloud (BlockAuthDone): error in device hash!';
		readingsSingleUpdate($hash, 'login_status', 'error in callback hash', 1 );
		return;
	}
	delete ($hash->{helper}{RUNNING_CALL});
	if ($values[0]  =~ m/^error/i ) {
		Log3 $hash, 2, 'DaikinCloud (BlockAuthDone): '.$string;
		readingsSingleUpdate($hash, 'login_status', 'error in callback', 1 );
		return;
	}	
	readingsBeginUpdate($hash);
	while (scalar(@values)>1) {
		readingsBulkUpdate($hash, shift @values, shift @values);
	}
	$hash->{helper}{ACCESS_TOKEN} = ReadingsVal($name, '.access_token', undef);
	$hash->{helper}{REFRESH_TOKEN} = ReadingsVal($name, '.refresh_token', undef);
	readingsBulkUpdate($hash, 'login_status', 'login successful');
	readingsBulkUpdate($hash, 'token_status', 'tokenset successfully stored');		
	readingsEndUpdate($hash,1);
	Log3 $hash, 3, 'DaikinCloud (BlockAuthDone): tokenset successfully stored' ; ##fix v1.3.2
	
	## schedule UpdateRequest if polling is activated
	my $interval = $hash->{INTERVAL};
	if (defined($interval) && ($interval>0 ))  {
		readingsSingleUpdate($hash, 'state', 'polling activ', 1 );
		RemoveInternalTimer($hash,'DaikinCloud_UpdateRequest');
		InternalTimer(gettimeofday()+1, 'DaikinCloud_UpdateRequest', $hash, 0);
	}		
	## do automatic refresh token 1 minute before expired
	InternalTimer(gettimeofday()+ReadingsNum($name,'expires_in',3600)-60,'DaikinCloud_DoRefresh',$hash,0);
}

sub DaikinCloud_BlockAuthAbort($) 
{ 
	my ($hash) = @_; 
	delete ($hash->{helper}{RUNNING_CALL});
	Log3 $hash, 3, 'DaikinCloud (BlockAuthAbort): BlockingCall aborted (timeout).';
	readingsSingleUpdate($hash, 'login_status', 'timeout error', 1 );
}

## child process
sub DaikinCloud_BlockAuth($)
{
	my $DAIKIN_ISSUER    = 'https://cognito-idp.eu-west-1.amazonaws.com/eu-west-1_SLI9qJpc7/.well-known/openid-configuration';
	my $DAIKIN_CLOUD_URL = 'https://daikin-unicloud-prod.auth.eu-west-1.amazoncognito.com';
	my $APIKEY           = '3_xRB3jaQ62bVjqXU1omaEsPDVYC0Twi1zfq1zHPu_5HFT0zWkDvZJS97Yw1loJnTm';
	my $APIKEY2          = '3_QebFXhxEWDc8JhJdBWmvUd1e0AaWJCISbqe4QIHrk_KzNVJFJ4xsJ2UZbl8OIIFY';
	
	my ($name) = @_;
	my $hash = $defs{$name};
	return $name.'|error (1) in device hash!' if (!defined($hash->{NAME}));
	
	## ask issuer for the actual endpoints
	my $param = { url => $DAIKIN_ISSUER, timeout => 5, method => 'GET', ignoreredirects => 1};
	my ($err,$response) = HttpUtils_BlockingGet($param);
	
	my $auth_endpoint = '';
	my $token_endpoint = '';
	if (($err eq '') && ($response ne '')) {
		($auth_endpoint) = ( $response =~ m/"authorization.?endpoint"\s*:\s*"([^"]+)/i );
		($token_endpoint) = ( $response =~ m/"token.?endpoint"\s*:\s*"([^"]+)/i );
	}
	## if response gives no endpoints back, take the generally known endpoints
	$auth_endpoint  = $DAIKIN_CLOUD_URL.'/oauth2/authorize' if (!defined($auth_endpoint) || ($auth_endpoint eq ''));
	$token_endpoint = $DAIKIN_CLOUD_URL.'/oauth2/token' if (!defined($token_endpoint) || ($token_endpoint eq ''));
	my $saml2_endpoint = $auth_endpoint;
	$saml2_endpoint =~ s/oauth2\/authorize//i;
	$saml2_endpoint .= 'saml2/idpresponse';
	
	## create client secret
	my @chars = ('0'..'9', 'A'..'Z','a'..'z');
	my $len = 32;
	my $secret = '';
	while($len--){ $secret .= $chars[rand @chars] };
	## create initial url
	my $url = $auth_endpoint.'?response_type=code&state='.$secret;
	$url.= '&client_id='.$OPENID_CLIENT_ID.'&scope=openid&redirect_uri=daikinunified%3A%2F%2Flogin';
	$param = { url => $url, timeout => 5, method => 'GET', ignoreredirects => 1};
	($err,$response) = HttpUtils_BlockingGet($param);		
	
	return $name."|error (2) $err" if($err ne '');
	return $name.'|error (2) HTTP-Status-Code: '.$param->{code} if ($param->{code} != 302 );
	### get crsf cookies
	my $cookies = (join '; ', ($param->{httpheader} =~ m/((?:xsrf-token|csrf-state|csrf-state-legacy)=[^;]+)/ig)).'; ';
	return $name.'|error (3) no cookies found: '.$param->{httpheader} if (!defined($cookies) || length($cookies)<50);
	### get forward-url
	($url) = ($param->{httpheader} =~ m/Location: ([^;\s]+)/i );
	return $name.'|error (4) no forward-url found: '.$param->{httpheader} if (!defined($url) || length($url)<50);
	### prepare samlContext request
	$param = { url => $url, timeout => 5, method => 'GET', ignoreredirects => 1 };
	($err,$response) = HttpUtils_BlockingGet($param);
	
	return $name."|error (5) $err" if($err ne '');
	return $name.'|error (5) HTTP-Status-Code: '.$param->{code} if ($param->{code} != 302 );
	### searching for samlContext
	my ($samlContext) = ( $param->{httpheader} =~ m/samlContext=([^&]+)/i );
	return $name.'|error (6) no samlContext found: '.$param->{httpheader} if (!defined($samlContext) || length($samlContext)<50);
	### prepare request to get Api-Version
	$url ='https://cdns.gigya.com/js/gigya.js?apiKey='.$APIKEY;
	$param = { url => $url, timeout => 5, method => 'GET' };
	($err,$response) = HttpUtils_BlockingGet($param);
		
	return $name."|error (7) $err" if($err ne '' || $response eq '');
	return $name.'|error (7) HTTP-Status-Code: '.$param->{code} if ($param->{code} != 200 );
	### searching for Api-Version
	my ($version) = ($response =~ m/(\d+-\d-\d+)/ );
	return $name.'|error (8) no Api-Version found.' if (!defined($version) || length($version)<5); 
	### prepare request to get single-sign-on cookies
	$url = 'https://cdc.daikin.eu/accounts.webSdkBootstrap?apiKey='.$APIKEY.'&sdk=js_latest&format=json' ;
	$param = { url => $url, timeout => 5, method => 'GET' };
	($err,$response) = HttpUtils_BlockingGet($param);
	
	return $name."|error (9) $err" if($err ne '');
	return $name.'|error (9) HTTP-Status-Code: '.$param->{code} if ($param->{code} != 200 );
	### extrakt single-sign-on cookies
	my $ssocookies = (join '; ', ($param->{httpheader} =~ m/((?:gmid|ucid|hasGmid)=[^;]+)/ig)).'; ';
	return $name.'|error (10) no single-sign-on cookies found: '.$param->{httpheader} if (!defined($ssocookies) || length($ssocookies)<50);
	$ssocookies .= 'gig_bootstrap_' . $APIKEY . '=cdc_ver4; ';
	$ssocookies .= 'gig_canary_' . $APIKEY2 . '=false; ';
	$ssocookies .= 'gig_canary_ver_' . $APIKEY2 . '=' . $version . '; ';
	$ssocookies .= 'apiDomain_' . $APIKEY2 . '=cdc.daikin.eu; ';
	### prepare login to get login-token
	my (undef, $username) = getKeyValue('DaikinCloud_username');
	$username = DaikinCloud_decrypt($username);
	my (undef, $password) = getKeyValue('DaikinCloud_password');
	$password = DaikinCloud_decrypt($password);
	my $header = { 'content-type' => 'application/x-www-form-urlencoded', 'cookie' => $ssocookies }; 
	my $body = { 'loginID'  => $username, 'password' => $password, 'sessionExpiration' => '31536000', 
		'targetEnv' => 'jssdk','include' => 'profile,', 'loginMode' => 'standard', 
		'riskContext' => '{"b0":7527,"b2":4,"b5":1', 'APIKey' => $APIKEY, 'sdk' => 'js_latest', 'authMode' => 'cookie', 
		'pageURL' => 'https://my.daikin.eu/content/daikinid-cdc-saml/en/login.html?samlContext='.$samlContext,
		'sdkBuild'=> '12208', 'format' => 'json' 
	};
	$url = 'https://cdc.daikin.eu/accounts.login';
	$param = { url => $url, timeout => 5, method => 'POST', header => $header, data => $body };
	($err,$response) = HttpUtils_BlockingGet($param);
	
	return $name."|error (11) $err" if($err ne '');
	return $name.'|error (11) HTTP-Status-Code: '.$param->{code} if ($param->{code} != 200 );
	### extract login-token
	my ($logintoken) = ($response =~ m/"login_token": "([^"]+)/i ); 
	return $name.'|error (12) no login-token found (wrong username or password).' if (!defined($logintoken) || length($logintoken)<10);
	### expand single-sign-on cookies with login-token
	my $time = time()+ 3600000;
	$ssocookies .= 'glt_'.$APIKEY.'='.$logintoken.'; ';
	$ssocookies .= 'gig_loginToken_'.$APIKEY2.'='.$logintoken.'; ';
	$ssocookies .= 'gig_loginToken_'.$APIKEY2.'_exp='.$time.'; ';
	$ssocookies .= 'gig_loginToken_'.$APIKEY2.'_visited=%2C'.$APIKEY.'; ';
	### prepare SAMLResponse request
	$header = { 'cookie' => $ssocookies }; 
	$body = { 'samlContext' => $samlContext, 'loginToken' => $logintoken };	
	$url = 'https://cdc.daikin.eu/saml/v2.0/'.$APIKEY .'/idp/sso/continue';
	$param = { url => $url, timeout => 5, method => 'POST', header => $header, data => $body};
	($err,$response) = HttpUtils_BlockingGet($param);
	
	return $name."|error (13) $err" if($err ne '');
	return $name.'|error (13) HTTP-Status-Code: '.$param->{code} if ($param->{code} != 200 );
	### extract samlResponse and relayState
	my ($samlResponse) = ($response =~ m/name="SAMLResponse" value="([^"]+)/i );
	return $name.'|error (14) no samlResponse found.' if (!defined($samlResponse) || length($samlResponse)<10);
	my ($relayState) = ($response =~ m/name="RelayState" value="([^"]+)/i );
	return $name.'|error (15) no relayState found.' if (!defined($relayState) || length($relayState)<10);
	### prepare request to get authorization code
	$header = { 'content-type' => 'application/x-www-form-urlencoded', 'cookie' => $cookies }; 
	$body = { 'SAMLResponse' => $samlResponse, 'RelayState' => $relayState };	
	$url = $saml2_endpoint;
	$param = { url => $url, timeout => 5, method => 'POST', header => $header, data => $body, ignoreredirects => 1 };
	($err,$response) = HttpUtils_BlockingGet($param);
	
	return $name."|error (16) $err" if($err ne '');
	return $name.'|error (16) HTTP-Status-Code: '.$param->{code} if ($param->{code} != 302 );
	### extract authorization code
	my ($code) = ($param->{httpheader} =~ m/daikinunified:\/\/login\?code=([^;]+)/i ); 
	return $name.'|error (17) no authorization code found.' if (!defined($code) || length($code)<10);
	### prepare request to get tokenset
	$header = { 'content-type' => 'application/x-www-form-urlencoded', 'cookie' => $cookies }; 
	$url  = $token_endpoint.'?grant_type=authorization_code&code='.$code.'&state='.$secret;
	$url .= '&client_id='.$OPENID_CLIENT_ID.'&redirect_uri=daikinunified%3A%2F%2Flogin';
	$param =  { url => $url, header => $header, timeout => 5, method => 'POST' };
	($err,$response) = HttpUtils_BlockingGet($param);

	return $name."|error (18) $err" if($err ne '');
	return $name.'|error (18) HTTP-Status-Code: '.$param->{code} if ($param->{code} != 200 );
	## extract tokenset quick and dirty
	my ($a_token)  = ( $response =~ m/"access.?token"\s*:\s*"([^"]+)/i );
	my ($r_token) = ( $response =~ m/"refresh.?token"\s*:\s*"([^"]+)/i );
	my ($exp)    = ( $response =~ m/"expires.?in"\s*:\s*"?([^",}]+)/i );
	my ($t_type)    = ( $response =~ m/"token.?type"\s*:\s*"([^"]+)/i );
	return $name.'|error (19) no tokenset found.' if (!defined($a_token) || !defined($r_token) || !defined($exp) || !defined($t_type));
	## return tokenset per telnet
	return $name.'|.access_token|'.$a_token.'|.refresh_token|'.$r_token.'|expires_in|'.$exp.'|token_type|'.$t_type;	
}

###############################################################################################
####################  refresh access_token with refresh_token  ################################
###############################################################################################

sub	DaikinCloud_DoRefresh($)
{
	my ($hash) = @_;
	return 'Authorizationprozess is almost running. Please wait!' if (defined($hash->{helper}{RUNNING_CALL}));
	## delete access_token to block requests of indoor units
	delete $hash->{helper}{ACCESS_TOKEN}; 
	## prepare subprocess
	$hash->{helper}{RUNNING_CALL} = BlockingCall('DaikinCloud_BlockRefresh',$hash->{NAME},
												 'DaikinCloud_BlockRefreshDone',15,
												 'DaikinCloud_BlockRefreshAbort',$hash); 
	$hash->{helper}{RUNNING_CALL}->{loglevel} = 4;
	readingsSingleUpdate($hash, 'token_status', 'starting refresh ...', 1 );
	return 'Going to refresh access-token.';
}

sub DaikinCloud_BlockRefreshDone($)
{
	my ($string) = @_;
	return if (!defined($string));
	my ($name, @values ) = split( "\\|", $string);
	my $hash = $defs{$name};
	if (!defined($hash->{NAME})) {
		Log 1, 'DaikinCloud (BlockRefreshDone): error in device hash!';
		readingsSingleUpdate($hash, 'token_status', 'error in callback hash', 1 );
		return;
	}
	delete ($hash->{helper}{RUNNING_CALL});
	
	if ($values[0]  =~ m/^error/i ) {
		Log3 $hash, 2, 'DaikinCloud (BlockRefreshDone): '.$string;
		readingsSingleUpdate($hash, 'token_status', 'error in callback', 1 );
		Log3 $hash, 2, 'DaikinCloud DoAuthorizationRequest to get a new tokenSet.'; ##fix v1.3.2
		DaikinCloud_DoAuthorizationRequest($hash); ##fix v1.3.2
		return;
	}
	## update readings
	readingsBeginUpdate($hash);
	while (scalar(@values)>1) {
		readingsBulkUpdate($hash, shift @values, shift @values);
	}
	readingsBulkUpdate($hash, 'token_status', 'token successfully refreshed', 1 );		
	readingsEndUpdate($hash,1);
	$hash->{helper}{ACCESS_TOKEN} = ReadingsVal($name, '.access_token', undef);
	## do UpdateRequest if polling is activated
	my $interval = $hash->{INTERVAL};
	if (defined($interval) && ($interval>0 ))  {
		readingsSingleUpdate($hash, 'state', 'polling activ', 1 );
		RemoveInternalTimer($hash,'DaikinCloud_UpdateRequest');
		InternalTimer(gettimeofday()+$interval, 'DaikinCloud_UpdateRequest', $hash, 0);
	}		
	## do automatic refresh 1 minute before expired
	InternalTimer(gettimeofday()+ReadingsNum($name,'expires_in',3600)-60,'DaikinCloud_DoRefresh',$hash,0);
	## check if set commands in queue
	DaikinCloud_SetCmd();
}

sub DaikinCloud_BlockRefreshAbort($) 
{ 
	my ($hash) = @_; 
	delete ($hash->{helper}{RUNNING_CALL});
	Log3 $hash, 3, 'DaikinCloud (BlockRefreshAbort): BlockingCall aborted (timeout).';
	readingsSingleUpdate($hash, 'token_status', 'timeout error', 1 );
}

sub DaikinCloud_BlockRefresh($)
{
	my ($name) = @_;
	my $hash = $defs{$name};
	return $name.'|error (1) in device hash!' if (!defined($hash) || !defined($hash->{NAME}));
	my $refresh_token = $hash->{helper}{REFRESH_TOKEN};
	return $name.'|error (2) no resfresh_token found.' if (!defined($refresh_token));
	return $name.'|error (3) invalid resfresh_token found: '.$refresh_token if (length($refresh_token)<10);
	my $url    = 'https://cognito-idp.eu-west-1.amazonaws.com/';
    my $header = { 
		'Content-Type'     => 'application/x-amz-json-1.1',
        'x-amz-target'     => 'AWSCognitoIdentityProviderService.InitiateAuth',
        'x-amz-user-agent' => 'aws-amplify/0.1.x react-native',
        'User-Agent'       => 'Daikin/1.6.1.4681 CFNetwork/1220.1 Darwin/20.3.0',
    };
    my $body = { 'ClientId' => $OPENID_CLIENT_ID, 'AuthFlow' => 'REFRESH_TOKEN_AUTH', 'AuthParameters' => {'REFRESH_TOKEN' => $refresh_token }};
	my $data = toJSON($body);
    my $param = { url => $url, timeout => 5, data => $data, method => 'POST', header => $header };    
	my ($err,$response) = HttpUtils_BlockingGet($param);
	return $name."|error (4) $err" if($err ne '');
	return $name.'|error (5) HTTP-Status-Code: '.$param->{code} if ($param->{code} != 200 );
	## extract tokenset quick and dirty
	my ($a_token)  = ( $response =~ m/"access.?token"\s*:\s*"([^"]+)/i );
	my ($exp)    = ( $response =~ m/"expires.?in"\s*:\s*"?([^",}]+)/i );
	my ($t_type)    = ( $response =~ m/"token.?type"\s*:\s*"([^"]+)/i );
	return $name.'|error (6) no token found.' if (!defined($a_token) || !defined($exp) || !defined($t_type));
	## return tokenset per telnet
	return $name.'|.access_token|'.$a_token.'|expires_in|'.$exp.'|token_type|'.$t_type;
}

###############################################################################################
####################  End refresh access_token with refresh_token  ############################
###############################################################################################

1;

=pod
=item device
=item summary    controls daikin airconditioning units over cloud access 
=item summary_DE steuert Daikin Klimaanlagen mit Cloud-Zugriff
=begin html

<a id="DaikinCloud"></a>
<h3>DaikinCloud</h3>
<ul>
  This module can control indoor Daikin airconditioning units connected to 
  the Daikin cloud. The devices must first be added to the cloud using the 
  Daikin <b>ONECTA-App</b>. Once they are added in the cloud, they can be 
  controlled and managed with this module.<br><br>
  <a id="DaikinCloud-define"></a>
  <b>Define</b>
  <ul>
    <ul>
      <br>
      First a master device has to be defined to handle the access to the 
      cloud:<br>
      <br>
      <code>define &lt;name&gt; DaikinCloud</code><br>
      <br>
      After creating the master device it is required to store username and
      password und get the tokenset:<br>
      <br>
      <code>set &lt;name&gt; username &lt;your-email&gt;</code><br>
      <code>set &lt;name&gt; password &lt;your-password&gt;</code><br>
      <code>get &lt;name&gt; tokenSet</code><br>
      <br>
      Thereafter for each indoor unit one device has to be defined. It is 
      easiest to let the devices be autocreated (see attributes). Otherwise 
      they can also be created manually if the device-id is known:<br><br>
      <code>define &lt;name&gt; DaikinCloud &lt;device-id&gt;</code><br>
    </ul>
  </ul>
  <br>
  <b>Set</b>
  <ul>
    <ul>
      <br>
      <a id="DaikinCloud-set-username"></a>
      <li><b>username</b><br>
        The username which is required to sign on the Daikin cloud. It is  
        highly recommend to use a emailadress. Social-media-logins are not
        supported. FHEM stores the username encrypted.
      </li>
      <a id="DaikinCloud-set-password"></a>
      <li><b>password</b><br>
        The password which is required to sign on the Daikin cloud. FHEM 
        stores the password encrypted.
      </li><br>
    </ul>
    The further possible set commands depend on the respective indoor units.<br>
    <br>
    <ul>
      <a id="DaikinCloud-set-demandControl"></a>
      <li><b>demandControl</b> [ off | auto | fixed ]<br>
        Select the control mode of the outdoor unit. The fixed mode can be 
        selected manually to avoid a permanently toogling of the compressor
        or to save energy. Note: this option is maybe only available if you 
        are registered on the Daikin cloud as the owner, and not as a second 
        user.
      </li>
      <a id="DaikinCloud-set-demandValue"></a>
      <li><b>demandValue</b> [ 40 .. 100 ]<br>
        If demandControl is fixed, choose a fixed value between 40 and 100
        (performance of the outdoor unit in percent, resolution 5). Note: 
        this option is  maybe only available if you are registered on the 
        Daikin cloud as the owner, and not as a second user.
      </li>
      <a id="DaikinCloud-set-econoMode"></a>
      <li><b>econoMode</b> [ on | off ]<br>
        Activate or deactivate econo mode.
      </li>
      <a id="DaikinCloud-set-horizontal"></a>
      <li><b>horizontal</b> [ stop | swing ]<br>
        Only available if the device supports horizontal swing.
      </li>
      <a id="DaikinCloud-set-vertical"></a>
      <li><b>vertical</b> [ stop | swing | windNice ]<br>
        Only available if the device supports vertical swing.
      </li>
      <a id="DaikinCloud-set-fanMode"></a>
      <li><b>fanMode</b> [ auto | quiet | fixed ]<br>
        Choose an allowed fan mode.
      </li>
      <a id="DaikinCloud-set-fanLevel"></a>
      <li><b>fanLevel</b> [ 1 .. 5 ]<br>
        Select the fan level if fanMode ist fixed.
      </li>
      <a id="DaikinCloud-set-onOffMode"></a>
      <li><b>onOffMode</b> [ on | off ]<br>
        Activate or deactivate the indoor unit.
      </li>
      <a id="DaikinCloud-set-operationMode"></a>
      <li><b>operationMode</b> [ fanOnly | heating | cooling | auto | dry ]<br>
        Select the current operationmode of the device. Note that a multi-split
        outdoor device can not process different operationsmodes of the indoor
        units simultaneously.
      </li>
      <a id="DaikinCloud-set-powerfulMode"></a>
      <li><b>powerfulMode</b> [ on | off ]<br>
        Activate or deactivate powerful mode.
      </li>
      <a id="DaikinCloud-set-streamerMode"></a>
      <li><b>streamerMode</b> [ on | off ]<br>
        Activate or deactivate ion streamer mode if present.
      </li>
      <a id="DaikinCloud-set-setpoint"></a>
      <li><b>setpoint</b> [ 18 .. 30 ]<br>
        Set the setpoint temperature. It is an absolute temperature in the allowed 
        range. The range is determined by the operationMode and the indoor unit 
        (resolution 0.5 degrees).
      </li>
      <a id="DaikinCloud-set-swing"></a>
      <li><b>swing</b> [ stop | horizontal | vertical | 3dswing | windNice ]<br>
        Only available if the device supports horizontal and vertical swing.
      </li>
      <a id="DaikinCloud-set-fanSpeed"></a>
      <li><b>fanSpeed</b> [ auto | quiet | Level1 | Level2 | Level3 | Level4 | Level5 ]<br>
        Only available if the device supports fanMode and fanLevel.
      </li>     
    </ul>
  </ul>
  <br>
  <b>Get</b> 
  <ul>
    <ul>
      <br>
      <a id="DaikinCloud-get-tokenSet"></a>
      <li><b>tokenSet</b><br>
         Get the tokenSet (access-token, refresh-token) to communicate with
         the cloud. To get the tokenSet, setting username and password is
         required.
      </li>
      <a id="DaikinCloud-get-refreshToken"></a>
      <li><b>refreshToken</b><br>
         The access-token normally expired in 3600 seconds. The access-token
         can be refreshed. Usually the refresh of the access-token is done
         automatically. With this command you can manually refresh the access-token.
      </li>
      <a id="DaikinCloud-get-forceUpdate"></a>
      <li><b>forceUpdate</b><br>
        Force an immediate request to the cloud to update the data of the indoor units.
      </li>
      <a id="DaikinCloud-get-setlist"></a>
      <li><b>setlist</b><br>
        Show the possible set commands of the indoor unit and the allowed 
        options.
      </li>     
    </ul>
  </ul>
  <br>
  <b>Attributes</b> (only for the master device)<br>
  <ul>
    <ul>
      <br>
      <a id="DaikinCloud-attr-autocreate"></a>
      <li><b>autocreate</b> [ 1 | 0 ]<br>
        If set to 1 (default) new devices will be created automatically upon 
        receiving data from cloud. Set this value to 0 to disable autocreating.
        <br>
      </li>
      <a id="DaikinCloud-attr-interval"></a>
      <li><b>interval</b> [ 15 .. &infin; ]<br>
        Defines the interval in seconds for requesting actual data from the cloud. 
        The minimum possible interval is 15 seconds so that the daikin cloud is 
        not overloaded. Default is 60 seconds.<br>
      </li>
    </ul>
  </ul>
  <br>
  <b>Attributes</b> (for the master device and the indoor units)<br>
  <ul>
    <ul>
      <br>
      <a id="DaikinCloud-attr-consumptionData"></a>
      <li><b>consumptionData</b> [ 0 | 1 ]<br>
        <i>Master device:</i> If set to 1 the transmitted data will also evaluate 
        consumption data. The read out consumption data is stored as total
        values in the readings kWh_[heating|cooling]_[day|week|year].
        <br><br>
        <i>Indoor unit:</i> If set to 1 additional the raw data of the energy 
        readings are saved in this device. Note that this requires to set the  
        attribut consumptionData to 1 in the master device. The raw data is saved 
        in the readings energy_[heating|cooling]_[d|w|m]_[1..24]. The d-readings
        refer to 2-hour time slices from yesterday [d_1..d_12] and today 
        [d_13..d_24]. The w-readings refer to whole days [Mon..Sun] of the last 
        week [w_1..w_7] and current week [w_8..w_14]. The m-readings refer to whole
        months [Jan..Dez] in the last year [m_1..m_12] and current year [m_13..m_24].
      </li>
    </ul>
  </ul>
</ul>
<br>

=end html
=begin html_DE

<a id="DaikinCloud"></a>
<h3>DaikinCloud</h3>
<ul>
  Dieses Modul kann die Innenger&auml;te von Daikin-Klimaanlagen steuern, 
  welche mit der Daikin-Cloud (EU) verbunden sind. Die Ger&auml;te m&uuml;ssen
  zun&auml;chst &uuml;ber die Daikin <b>ONECTA-App</b> zur Cloud 
  hinzugef&uuml;gt werden. Sobald sie in der Cloud hinzugef&uuml;gt wurden, 
  k&ouml;nnen sie auch mit diesem Modul gesteuert und verwaltet werden.<br><br>
  <a id="DaikinCloud-define"></a>
  <b>Define</b>
  <ul>
    <ul>
      <br>
      Zuerst muss ein Master-Ger&auml;t (bzw. eine Bridge) definiert werden, 
      welches den Zugriff auf die Cloud erm&ouml;glicht:<br>
      <br>
      <code>define &lt;name&gt; DaikinCloud</code><br>
      <br>
      Nach dem Erstellen des Master-Ger&auml;ts m&uuml;ssen Benutzername und 
      Passwort gespeichert werden. Danach kann das TokenSet abgerufen werden:<br>
      <br>
      <code>set &lt;name&gt; username &lt;your-email&gt;</code><br>
      <code>set &lt;name&gt; password &lt;your-password&gt;</code><br>
      <code>get &lt;name&gt; tokenSet</code><br>
      <br>
      Danach muss f&uuml;r jedes Innenger&auml;t ein Device definiert werden. 
      Es ist am einfachsten, die Devices automatisch erstellen zu lassen 
      (siehe Attribute). Ansonsten k&ouml;nnen sie auch manuell erstellt 
      werden, wenn die Device-ID bereits bekannt ist:<br><br>
      <code>define &lt;name&gt; DaikinCloud &lt;device-id&gt;</code><br>
    </ul>
  </ul>
  <br>
  <b>Set</b>
  <ul>
    <ul>
      <br>
      <a id="DaikinCloud-set-username"></a>
      <li><b>username</b><br>
        Der Benutzername, der zum Anmelden in der Daikin-Cloud verwendet wird 
        (email-Adresse). Social-Media-Logins werden ggf. nicht 
        unterst&uuml;tzt. FHEM speichert den Benutzernamen verschl&uuml;sselt.
      </li>
      <a id="DaikinCloud-set-password"></a>
      <li><b>password</b><br>
        Das Passwort, das zum Anmelden in der Daikin-Cloud vergeben worden 
        ist. FHEM speichert das Passwort verschl&uuml;sselt.
      </li><br>
    </ul>
    Die folgenden Set-Befehle h&auml;ngen von den m&ouml;glichkeiten der 
    jeweiligen Innenger&auml;te ab.<br>
    <br>
    <ul>
      <a id="DaikinCloud-set-demandControl"></a>
      <li><b>demandControl</b> [ off | auto | fixed ]<br>
        W&auml;hlt den Steuermodus des Au&szlig;enger&auml;tes. Der Modus 
        fixed (manuell) kann gew&auml;hlt werden, um ein Takten des 
        Au&szlig;enger&auml;tes zu minimieren oder auch um Energie zu 
        sparen. Wichtig: Die Option steht ggf. nur zur Verf&uuml;gung, wenn
        das Benutzerkonto bzw. die Zugangsdaten des Eigent&uuml;mers verwendet 
        werden, und nicht das Benutzerkonto eines eingeladenen Zweitnutzers.
      </li>
      <a id="DaikinCloud-set-demandValue"></a>
      <li><b>demandValue</b> [ 40 .. 100 ]<br>
        Wenn der Steuermodus auf fixed gestellt wurde, kann ein Wert zwischen 
        40 und 100 (Leistung des Au&szlig;enger&auml;tes in Prozent, 
        regelbar in 5-Prozent-Schritten) eingestellt werden. Wichtig: Die 
        Option steht ggf. nur zur Verf&uuml;gung, wenn das Benutzerkonto bzw. 
        die Zugangsdaten des Eigent&uuml;mers verwendet werden, und nicht das 
        Benutzerkonto eines eingeladenen Zweitnutzers.
      </li>
      <a id="DaikinCloud-set-econoMode"></a>
      <li><b>econoMode</b> [ on | off ]<br>
        Schaltet den Econo-Mode ein oder aus.
      </li>
      <a id="DaikinCloud-set-horizontal"></a>
      <li><b>horizontal</b> [ stop | swing ]<br>
        Nur verf&uuml;gbar, wenn das Innenger&auml;t eine entsprechende 
        Funktion bietet.
      </li>
      <a id="DaikinCloud-set-vertical"></a>
      <li><b>vertical</b> [ stop | swing | windNice ]<br>
        Nur verf&uuml;gbar, wenn das Innenger&auml;t eine entsprechende 
        Funktion bietet.
      </li>
      <a id="DaikinCloud-set-fanMode"></a>
      <li><b>fanMode</b> [ auto | quiet | fixed ]<br>
        Stellt den L&uuml;fter-Modus ein.
      </li>
      <a id="DaikinCloud-set-fanLevel"></a>
      <li><b>fanLevel</b> [ 1 .. 5 ]<br>
        Stellt die L&uuml;ftergeschwindigkeit ein, wenn der L&uuml;fter-Modus 
        fixed gew&auml;hlt worden ist.
      </li>
      <a id="DaikinCloud-set-onOffMode"></a>
      <li><b>onOffMode</b> [ on | off ]<br>
        Schaltet das Innenger&auml;t ein oder aus.
      </li>
      <a id="DaikinCloud-set-operationMode"></a>
      <li><b>operationMode</b> [ fanOnly | heating | cooling | auto | dry ]<br>
        W&auml;hlt den Betriebsmodus des Innenger&auml;tes. Wichtig: Ein
        Multi-Split-Au&szlig;enger&auml;t kann unterschiedliche Betriebsmodi
        verschiedener Innenger&auml;te nicht gleichzeitig unterst&uuml;tzen.
        D.h. das Multi-Split-Au&szlig;enger&auml;t kann gleichzeitig entweder 
        Innenger&auml;te mit W&auml;rme oder K&auml;lte versorgen.
      </li>
      <a id="DaikinCloud-set-powerfulMode"></a>
      <li><b>powerfulMode</b> [ on | off ]<br>
        Schaltet den Powerful-Mode ein oder aus.
      </li>
      <a id="DaikinCloud-set-streamerMode"></a>
      <li><b>streamerMode</b> [ on | off ]<br>
        Schaltet den Streamer-Mode ein oder aus.
      </li>
      <a id="DaikinCloud-set-setpoint"></a>
      <li><b>setpoint</b> [ 18 .. 30 ]<br>
        Setzt die Zieltemperatur des Innenger&auml;tes im erlaubten Bereich. 
        Der erlaubte Bereich ist abh&auml;ngig vom Operation-Modus und von der
        Art des Innenger&auml;tes (Aufl&oumlsung 0.5 Grad).
      </li>
      <a id="DaikinCloud-set-swing"></a>
      <li><b>swing</b> [ stop | horizontal | vertical | 3dswing | windNice ]<br>
        Nur verf&uuml;gbar, wenn das Innenger&auml;t sowohl horizontale als 
        auch vertikale Swing-Funktionen bietet.
      </li>
      <a id="DaikinCloud-set-fanSpeed"></a>
      <li><b>fanSpeed</b> [ auto | quiet | Level1 | Level2 | Level3 | Level4 | Level5 ]<br>
        Nur verf&uuml;gbar, wenn das Innenger&auml;t sowohl fanMode als 
        fanLevel unterst&uuml;tzt.
      </li>     
    </ul>
  </ul>
  <br>
  <b>Get</b> 
  <ul>
    <ul>
      <br>
      <a id="DaikinCloud-get-tokenSet"></a>
      <li><b>tokenSet</b><br>
        Abrufen eines TokenSets (access-token, refresh-token), um Zugang zur
        Daikin-Cloud zu bekommen. Hierf&uuml;r ist zun&auml;chst erforderlich, 
        den Benutzername und das Passwort zu speichern.
      </li>
      <a id="DaikinCloud-get-refreshToken"></a>
      <li><b>refreshToken</b><br>
        Der Access-Token ist normalerweise 3600 Sekunden g&uuml;tig. Er kann 
        aber erneuert werden. Dies wird normalerweise automatisch vor Ablauf 
        der G&uuml;tigkeitsdauer veranlasst. Mit diesem Befehl kann auch eine
        manuelle Erneuerung angesto&szlig;en werden.
      </li>
      <a id="DaikinCloud-get-forceUpdate"></a>
      <li><b>forceUpdate</b><br>
        Erzeugt eine sofortige Anfrage an die Cloud, um die aktuellen Daten der 
        Innenger&auml;te zu erhalten.
      </li>
      <a id="DaikinCloud-get-setlist"></a>
      <li><b>setlist</b><br>
        Zeigt die verf&uuml;gbaren Set-Befehle f&uuml;r das gew&auml;hlte 
        Innenger&auml;t und die erlaubten Optionen dazu an.
      </li>     
    </ul>
  </ul>
  <br>
  <b>Attributes</b> (nur f&uuml;r das Master-Device)<br>
  <ul>
    <ul>
      <br>
      <a id="DaikinCloud-attr-autocreate"></a>
      <li><b>autocreate</b> [ 1 | 0 ]<br>
        Bei Einstellung auf 1 (Standard) werden neue Devices automatisch 
        erstellt, wenn entsprechende Daten aus der Cloud empfangen werden. 
        Setzen Sie diesen Wert auf 0 oder l&ouml;schen ihn, um die 
        automatische Erstellung von Devices zu deaktivieren. 
        <br>
      </li>
      <a id="DaikinCloud-attr-interval"></a>
      <li><b>interval</b> [ 15 .. &infin; ]<br>
        Definiert das Intervall in Sekunden, innerhalb dessen die aktuellen 
        Daten aus der Cloud jeweils abgefragt werden sollen. Das Minimum 
        betr&auml;gt 15 Sekunden, damit die Daikin Cloud nicht zu stark 
        belastet wird. Standard sind 60 Sekunden. Dieses Attribut ist nur 
        im Master-Device verf&uuml;gbar.<br>
      </li>
    </ul>
  </ul>
  <br>
  <b>Attributes</b> (f&uuml;r Master-Device und Innenger&auml;te)<br>
  <ul>
    <ul>
      <br>
      <a id="DaikinCloud-attr-consumptionData"></a>
      <li><b>consumptionData</b> [ 0 | 1 ]<br>
        <i>Master-Device:</i> Wenn auf 1 gesetzt, werden die in der Cloud 
        gespeicherten Verbrauchsdaten ausgelesen und als Summenwerte
        in den Readings kWh_[heating|cooling]_[day|week|year] gespeichert.
        <br><br>
        <i>Innenger&auml;t:</i> Wenn auf 1 gesetzt, werden zus&auml;tzlich 
        die Rohdaten der energy-readings aus der Cloud f&uuml;r dieses Device   
        gespeichert. Dies setzt voraus, dass im Master-Device das Attribut   
        consumptionData auf 1 gesetzt worden ist. Die Rohdaten werden in 
        den Readings energy_[heating|cooling]_[d|w|m]_[1..24] gespeichert. 
        Die d-Readings beziehen sich auf 2-Stunden-Zeitscheiben von gestern 
        [d_1..d_12] und heute [d_13..d_24]. Die w-Readings beziehen sich auf  
        ganze Tage [Mo..So] der letzten Woche [w_1..w_7] und aktuellen Woche 
        [w_8..w_14]. Die m-Readings beziehen sich auf ganze Monate [Jan..Dez]
        im letzten Jahr [m_1..m_12] und aktuellen Jahr [m_13..m_24].
      </li>
    </ul>
  </ul>
</ul>
<br>

=end html_DE

=cut
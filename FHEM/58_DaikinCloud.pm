#######################################################################################################
#
# 58_DaikinCloud.pm 
#
# This modul ist used for control indoor units connected to the Daikin Cloud (EU).
# It is required, that the indoor units already are connected to the internet and 
# the registration process in the Daikin-ONECTA App is finished. If the indoor units 
# doesn't appear in the Daikin-ONECTA App, they will also not appear in this modul!
#
#######################################################################################################
# v2.1.5 - 29.03.2024 fix error by JSON::XS (boolean_values)
# v2.1.4 - 17.03.2024 only store refresh-token in setKeyValue (better performance)
# v2.1.3 - 17.03.2024 fix: Retry-After without reading, better conversion to new API
# v2.1.2 - 10.03.2024 only updataRequest and set-cmd, if there is no request limit reached
# v2.1.1 - 09.03.2024 saveRawData as attribut, use setKeyValue to sava TokenSet
# v2.1.0 - 08.03.2024 new data-evaluation-routine
# v2.0.2 - 02.03.2024 evaluate HTTP-Response-Header to check remaining requests
# v2.0.1 - 28.02.2024 Define Standard redirect-uri to: https://my.home-assistant.io/redirect/oauth
# v2.0.0 - 21.02.2024 New Open Daikin-API
# v1.3.6 - 20.06.2023 fix: do not process other IDs (e.g. firmware update IDs)
# v1.3.5 - 02.06.2023 improve set-cmd (suspend polling), unified error logs, second try on failed connection, commandref
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

## doku kontrollieren

package main;

use strict;
use warnings;

use Time::HiRes qw(gettimeofday time);
use HttpUtils;

## try to use json::xs, otherwise use own decoding sub
my $json_xs_available = 1;
eval "use JSON::XS qw(decode_json); 1" or $json_xs_available = 0;

my $DaikinCloud_version = 'v2.1.5 - 29.03.2024';

my $daikin_oidc_url = 	"https://idp.onecta.daikineurope.com/v1/oidc/";
my $daikin_cloud_url =	"https://api.onecta.daikineurope.com/v1/gateway-devices";
my $daikin_dev_url = 	"https://developer.cloud.daikineurope.com/login";

#######################################################################################################
###################################### Forward declarations ###########################################

sub DaikinCloud_Initialize($);			# define the functions to be called 
sub DaikinCloud_CreateSecretState;		# create a seperate secret for OAuth2
sub DaikinCloud_Define($$);				# handle define of master und indoor-devices 
sub DaikinCloud_Undefine($$);			# handle undefine a device, remove timers und kill blockingcalls
sub DaikinCloud_CallbackGetToken;		# extract the tokens from the response and store them in FHEM 
sub DaikinCloud_GetToken($);			# send the authorization-code to get the tokens
sub DaikinCloud_RefreshToken;			# do a refresh of the access-token, which is only valid for 1 hour
sub DaikinCloud_CallbackRevokeToken;	# handle the response of logout
sub DaikinCloud_RevokeToken;			# do a logout and revoke the tokens
sub DaikinCloud_setlist($);				# returns a list of possbible set-commands
sub DaikinCloud_Set($$$$);				# handle the set commands of devices
sub DaikinCloud_CheckRetryAfter($$$);	# check if the request limit is reached
sub DaikinCloud_SetCmd();				# send the command to the cloud	
sub DaikinCloud_HeaderResponse($);		# extract the remaining requests from the response-header
sub DaikinCloud_SetCmdResponse($);		# handle the response of an set command
sub DaikinCloud_CheckAndQueue($$$$);	# check if the choosen set command is possible
sub DaikinCloud_Get($$@);				# handle the get commands of devices
sub DaikinCloud_Attr($$);				# handle the change of attributes
sub DaikinCloud_UpdateRequest(;$);		# prepare the request the actual data from the cloud
sub DaikinCloud_GetDetailData($$$$$$$);	# parce each managementpoint and traverse set-cmd
sub DaikinCloud_GetDeviceData($$$);		# parse the device data
sub DaikinCloud_CallbackUpdateRequest;	# receive data from the cloud

#######################################################################################################

sub DaikinCloud_Initialize($)
{
	my ($hash) = @_;
	$hash->{DefFn}    = 'DaikinCloud_Define';
	$hash->{UndefFn}  = 'DaikinCloud_Undefine';
	$hash->{SetFn}    = 'DaikinCloud_Set';
	$hash->{GetFn}    = 'DaikinCloud_Get';
	$hash->{AttrFn}   = 'DaikinCloud_Attr';
}

############################ create a seperate secret for OAuth2 ######################################

sub DaikinCloud_CreateSecretState
{
	## create state parameter (secret) for OAuth2 
	my @chars = ('0'..'9', 'A'..'Z','a'..'z');
	my $len = 32;
	my $secret = '';
	while($len--){ $secret .= $chars[rand @chars] };
	return $secret;
}

######  handle define: create only one IO-MASTER (as a bridge) and indoor units with DEVICE-ID  #######

sub DaikinCloud_Define($$)
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);
	
	if (int(@a) > 2 && $a[2] eq "?" ) {
		return "Syntax: define <NAME> DaikinCloud [<CLIENT_ID>] [<CLIENT_SECRET>] [<REDIRECT_URI>]"; 
	};
	
	my $name = $a[0]; # a[0]=name; a[1]=DaikinCloud; a[2]..a[4]= parameters
	
	## handle define of indoor units
	if (int(@a) == 3) {
		my $dev_id = $a[2];
		my $defptr = $modules{DaikinCloud}{defptr}{IOMASTER};
		return 'Cannot modify master device to indoor unit device!' if (defined($defptr) && $hash eq $defptr);
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
		return "Master device already defined as $defptr->{NAME} !" if (defined($defptr) && $defptr->{NAME} ne $name);
		$hash->{INTERVAL} = 900;
		$hash->{VERSION} = $DaikinCloud_version;
		$hash->{helper}{secret_state} = DaikinCloud_CreateSecretState();
		
		if (int(@a) > 3) {
			$hash->{CLIENT_ID} = $a[2];
			$hash->{CLIENT_SECRET} = $a[3];
			# $hash->{REDIRECT_URI} = defined($a[4]) ? $a[4] : 'https://oskar.pw/';
			$hash->{REDIRECT_URI} = defined($a[4]) ? $a[4] : 'https://my.home-assistant.io/redirect/oauth';
		} else { ## if no parameters are given use the standard credentials
			$hash->{CLIENT_ID} = 'emU20GdJDiiUxI_HnFGz69dD';
			$hash->{CLIENT_SECRET} = 'TNL1ePwnOkf6o2gKiI8InS8nVwTz2G__VYkv6WznzJGUnwLHLTmKYp-7RZc6FA3yS6D0Wgj_snvqsU5H_LPHQA';
			$hash->{REDIRECT_URI} = 'https://my.home-assistant.io/redirect/oauth';
			$hash->{DEF} = $hash->{CLIENT_ID}.' '.$hash->{CLIENT_SECRET}.' '.$hash->{REDIRECT_URI}
		}
		
		$hash->{AUTHORIZATION_LINK} = "<html><a href=\"".$daikin_oidc_url.
			"authorize?response_type=code"."&client_id=".$hash->{CLIENT_ID}.
			"&redirect_uri=".urlEncode($hash->{REDIRECT_URI}).
			"&scope=openid%20onecta%3Abasic.integration&state=".$hash->{helper}{secret_state}.
			"\" target=\"_blank\">Daikin Cloud Login (OAuth2)</a></html>";
		
		$modules{DaikinCloud}{defptr}{IOMASTER} = $hash;
		
		my (undef, $r_token) = getKeyValue('DaikinCloud_refresh_token');
		if (defined($r_token)) {
			$hash->{helper}{REFRESH_TOKEN} = $r_token;
			Log3 $name, 2, 'DaikinCloud (Define at start): Refresh-Token ready to use.';
		} else {
			## delete tokens for old API
			delete $hash->{helper}{ACCESS_TOKEN} if (defined($hash->{helper}) && defined($hash->{helper}{ACCESS_TOKEN}));
			delete $hash->{helper}{REFRESH_TOKEN} if (defined($hash->{helper}) && defined($hash->{helper}{REFRESH_TOKEN}));
			CommandDeleteReading(undef,'-q $hash->{NAME} .refresh_token') if (!defined(ReadingsVal($hash->{NAME},'.refresh_token',undef)));
			CommandDeleteReading(undef,'-q $hash->{NAME} .access_token') if (!defined(ReadingsVal($hash->{NAME},'.access_token',undef)));
			setKeyValue('DaikinCloud_username',undef); 
			setKeyValue('DaikinCloud_password',undef);			
		}
		 
		setDevAttrList($name, 'autocreate:1,0 interval consumptionData:1,0 saveRawData:1,0'. $readingFnAttributes);
		if ($init_done) {
			CommandAttr(undef, '-silent '.$name.' autocreate 1');
			CommandAttr(undef, '-silent '.$name.' interval 900');
			CommandAttr(undef, '-silent '.$name.' consumptionData 1');
			CommandAttr(undef, '-silent '.$name.' room DaikinCloud_Devices');				
		}
	}
	return undef;
}

##########################  handle undefine: delete defptr, remove timers  ############################

sub DaikinCloud_Undefine($$)
{
	my ($hash, $arg) = @_;
	my $iomaster = $modules{DaikinCloud}{defptr}{IOMASTER};
	if ( defined($iomaster) && $hash eq $iomaster ) {
		setKeyValue('DaikinCloud_refresh_token',undef);
		delete $modules{DaikinCloud}{defptr}{IOMASTER}; 
		RemoveInternalTimer($hash);
	}
	delete $modules{DaikinCloud}{defptr}{$hash->{DEF}} if (defined($hash->{DEF}));
	return undef;
}

#######################################################################################################
###############################  new integration of the open-Daikin-Api  ##############################
#######################################################################################################

sub DaikinCloud_CallbackGetToken
{
	my ($param, $err, $data) = @_;
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
		
	if ( $err || $param->{code} != 200 ) { 
		my $errortext = 'DaikinCloud (CallbackGetToken) failed: ';
		$errortext .= $err if ($err);
		$errortext .= "HTTP-Status-Code=" . $param->{code};
		$errortext .= " Response: " . $data if (defined($data));
		Log3 $hash, 2, $errortext;
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, 'token_status', $errortext );
		readingsBulkUpdate($hash, 'token_type', 'invalid' );
		readingsEndUpdate($hash,1);
		return;
	}
	
	## extract the tokens quick and dirty
	my ($a_token) = ( $data =~ m/"access.?token"\s*:\s*"([^"]+)/i );
	my ($r_token) = ( $data =~ m/"refresh.?token"\s*:\s*"([^"]+)/i );
	my ($exp) = ( $data =~ m/"expires.?in"\s*:\s*"?([^",}]+)/i );
	my ($t_type) = ( $data =~ m/"token.?type"\s*:\s*"([^"]+)/i );
	
	if (!defined($a_token) || !defined($r_token) || !defined($exp)) {
		Log3 $hash, 2, "DaikinCloud (CallbackGetToken): No TokenSet found";
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, 'token_status', 'failed: no TokenSet retrieved');
		readingsBulkUpdate($hash, 'token_type', 'none');
		readingsEndUpdate($hash,1);
		return;
	}	
	
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, 'expires_in', $exp);
	readingsBulkUpdate($hash, 'token_type', $t_type) if (defined($t_type));
	readingsBulkUpdate($hash, 'token_status', 'TokenSet successfully stored');
	readingsEndUpdate($hash,1);
	
	$hash->{helper}{ACCESS_TOKEN} = $a_token;
	$hash->{helper}{REFRESH_TOKEN} = $r_token;	
	setKeyValue('DaikinCloud_refresh_token',$r_token);
	
	Log3 $hash, 4, 'DaikinCloud (CallbackGetToken): TokenSet successfully stored' ;
	
	## schedule UpdateRequest if polling is activated
	my $interval = $hash->{INTERVAL};
	if (defined($interval) && ($interval>0 )) {
		readingsSingleUpdate($hash, 'state', 'polling activ', 1 );
		RemoveInternalTimer($hash,'DaikinCloud_UpdateRequest');
		InternalTimer(gettimeofday()+1, 'DaikinCloud_UpdateRequest', $hash, 0);
	}		
	## do automatic refresh token 1 minute before expired
	InternalTimer(gettimeofday()+ReadingsNum($hash->{NAME},'expires_in',3600)-60,'DaikinCloud_RefreshToken',$hash,0);
	## check if set commands in queue
	DaikinCloud_SetCmd();
}

#######################################################################################################

sub DaikinCloud_GetToken($)
{
	my ($code) = @_;	
	## always perform GetToken with iomaster
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
	return 'DaikinCloud (GetToken): No IOMASTER device found! ' if (!defined($hash));
	
	my $client_id = $hash->{CLIENT_ID};
	my $client_secret = $hash->{CLIENT_SECRET};
	my $redirect_uri = $hash->{REDIRECT_URI};
	my $secret_state = $hash->{helper}{secret_state};
	
	if (!defined($client_id) || !defined($client_secret) || !defined($redirect_uri))
	{
		return 'Do a redefine to initialize the device: "defmod '.$hash->{NAME}.' DaikinCloud"';
	}
	
	$code = urlDecode($code);
	$code = $1 if ($code =~ m/code=([^&]*)/);	
	return "No valid AuthCode" if (length($code)<20);
	
	HttpUtils_NonblockingGet(
	{
		callback => \&DaikinCloud_CallbackGetToken,
		method => 'POST',
		hash => $hash,
		url => $daikin_oidc_url.'token',
		timeout => 10,
		data => 
		{
			grant_type => 'authorization_code', 
			client_id => $client_id,
			client_secret => $client_secret,
			code => $code,
			redirect_uri => $redirect_uri,
			state => $secret_state
		}
	});
	CommandDeleteReading(undef,'-q $hash->{NAME} login_status') if (!defined(ReadingsVal($hash->{NAME},'login_status',undef)));
	readingsSingleUpdate($hash, 'token_status', 'request for TokenSet ..', 1 );
	return;
}

#######################################################################################################

sub DaikinCloud_RefreshToken
{
	## always perform Refresh-Token with iomaster
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
	return 'DaikinCloud (RefreshToken): No IOMASTER device found! ' if (!defined($hash));
	
	## remove all other timers do avoid double requests or invalid requests
	RemoveInternalTimer($hash);
	readingsSingleUpdate($hash, 'state', 'polling inactiv', 1 );
	
	my $client_id = $hash->{CLIENT_ID};
	my $client_secret = $hash->{CLIENT_SECRET};
	
	if (!defined($client_id) || !defined($client_secret)) {
		return 'Do a redefine to initialize the device: "defmod '.$hash->{NAME}.' DaikinCloud"';
	};
	
	## check if refresh-token exists
	my $r_token = $hash->{helper}{REFRESH_TOKEN};
	return 'DaikinCloud (RefreshToken): No Refresh-Token saved! Do a Daikin Cloud Login (OAuth2) first!' if (!defined($r_token));

	HttpUtils_NonblockingGet(
	{
		callback => \&DaikinCloud_CallbackGetToken,
		method => 'POST',
		hash => $hash,
		url => $daikin_oidc_url.'token',
		timeout => 10,
		data => 
		{
			grant_type => 'refresh_token', 
			client_id => $client_id,
			client_secret => $client_secret,
			refresh_token => $r_token,
		}
	});
	readingsSingleUpdate($hash, 'token_status', 'request for TokenRefresh ..', 1 );
	
	## set new timer for update-request only for safety if refresh fails
	my $interval = $hash->{INTERVAL};
	if (defined($interval) && ($interval>0 )) {
		readingsSingleUpdate($hash, 'state', 'polling activ', 1 );
		InternalTimer(gettimeofday()+$interval, 'DaikinCloud_UpdateRequest', $hash, 0);
	}	
	return;
}

#######################################################################################################

sub DaikinCloud_CallbackRevokeToken 
{
	my ($param, $err, $data) = @_;
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
			
	if ( $err || $param->{code} != 200 ) { 
		my $errortext = 'DaikinCloud (CallbackRevokeToken) failed: ';
		$errortext .= $err if ($err);
		$errortext .= "HTTP-Status-Code=" . $param->{code};
		$errortext .= " Response: " . $data if (defined($data));
		Log3 $hash, 2, $errortext;
		readingsSingleUpdate($hash, 'token_status', $errortext , 1 );
		return;
	}
	
	Log3 $hash, 3, 'DaikinCloud (CallbackRevokeToken): Revoke of '.$param->{data}{token_type_hint}.' successful (Logout).';

	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, 'token_status', 'token revoked - logout successful');
	readingsBulkUpdate($hash, 'token_type', 'none');
	readingsBulkUpdate($hash, 'state', 'no access-token');
	readingsEndUpdate($hash,1);
}

#######################################################################################################

sub DaikinCloud_RevokeToken
{
	## always perform Refresh-Token with iomaster
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
	return 'DaikinCloud (RevokeToken): No IOMASTER device found! ' if (!defined($hash));
	
	my $client_id = $hash->{CLIENT_ID};
	my $client_secret = $hash->{CLIENT_SECRET};	
	return "DaikinCloud (RevokeToken): Need Client_ID und Client_Secret to logout" if (!defined($client_id) || !defined($client_secret));
	
	## remove all refresh und update-timers 
	RemoveInternalTimer($hash);
	readingsSingleUpdate($hash, 'state', 'polling inactive', 1 );
	
	my $r_token = $hash->{helper}{REFRESH_TOKEN};
	my $a_token = $hash->{helper}{ACCESS_TOKEN};
	return "DaikinCloud (RevokeToken): No TokenSet found to revoke." if (!defined($r_token) && !defined($a_token));
		
	if (defined($r_token)) {
		HttpUtils_NonblockingGet(
		{
			url => $daikin_oidc_url.'revoke',
			method => 'POST',
			hash => $hash,
			timeout => 10,
			callback => \&DaikinCloud_CallbackRevokeToken,
			data => 
			{
				token => $r_token, 
				client_id => $client_id,
				client_secret => $client_secret,
				token_type_hint => 'refresh_token',
			}
		});
		delete $hash->{helper}{REFRESH_TOKEN};
		setKeyValue('DaikinCloud_refresh_token',undef);
		readingsSingleUpdate($hash, 'token_status', 'starting to revoke refresh-token ..', 1 );
	}	
	
	if (defined($a_token)) {
		HttpUtils_NonblockingGet(
		{
			url =>  $daikin_oidc_url.'revoke',
			method => 'POST',
			hash => $hash,
			timeout => 10,
			callback => \&DaikinCloud_CallbackRevokeToken,
			data => 
			{
				token => $a_token, 
				client_id => $client_id,
				client_secret => $client_secret,
				token_type_hint => 'access_token',
			}
		});
		delete $hash->{helper}{ACCESS_TOKEN};
		readingsSingleUpdate($hash, 'token_status', 'starting to revoke access-token ..', 1 );
	}
	return;
}

#######################################################################################################
#####################  return possible set - commands for actual operationMode  #######################
#######################################################################################################

sub DaikinCloud_setlist($)
{
	my ($hash) = @_;
	## check if settable exists
	my $table = $hash->{helper}{table}; 
	return 'DaikinCloud (Setlist): No settable found! Please forceUpdate first! ','' if (!defined($table) || (ref($table) ne 'HASH'));	
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
		} else {
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
	return 'DaikinCloud (Setlist): No settable found! Please forceUpdate first! ','' if ($setlist eq '');
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
		if ( lc($cmd) eq 'authcode') {
			return DaikinCloud_GetToken($value);
		} elsif ( lc($cmd) eq 'logout') {
			return DaikinCloud_RevokeToken();
		} else  {
			$setlist = 'AuthCode Logout:noArg';
		}
	## prepare setlist to show possible commands for indoor units	
	} elsif (($cmd eq '?') || ($cmd eq '')) {
		(undef,$setlist) = DaikinCloud_setlist($hash);
		return "unknown argument $cmd : $value, choose one of $setlist";
		
	## set for indoor units
	} else {
		my $err = ''; 
		## check if device connected #fix v1.0.4
		return "DaikinCloud (Set): Cannot sent $cmd for $name to Daikin-Cloud, because unit is offline!" if (ReadingsVal($name, 'isCloudConnectionUp', 'unknown' ) eq 'false');
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
				$err .= DaikinCloud_CheckAndQueue($hash,'horizontal','stop',$mode) if ($setlist =~ m/horizontal:/i && ReadingsVal($name, 'horizontal', 'unknown') ne 'stop');
				$err .= DaikinCloud_CheckAndQueue($hash,'vertical','stop',$mode) if ($setlist =~ m/vertical:/i && ReadingsVal($name, 'vertical', 'unknown') ne 'stop');
			} elsif ($value eq 'horizontal' ) {
				$err .= DaikinCloud_CheckAndQueue($hash,'horizontal','swing',$mode) if ($setlist =~ m/horizontal:/i && ReadingsVal($name, 'horizontal', 'unknown') ne 'swing');
				$err .= DaikinCloud_CheckAndQueue($hash,'vertical','stop',$mode) if ($setlist =~ m/vertical:/i && ReadingsVal($name, 'vertical', 'unknown') ne 'stop');
			} elsif ($value eq 'vertical' ) {
				$err .= DaikinCloud_CheckAndQueue($hash,'horizontal','stop',$mode) if ($setlist =~ m/horizontal:/i && ReadingsVal($name, 'horizontal', 'unknown') ne 'stop');
				$err .= DaikinCloud_CheckAndQueue($hash,'vertical','swing',$mode) if ($setlist =~ m/vertical:/i && ReadingsVal($name, 'vertical', 'unknown') ne 'swing');
			} elsif ($value eq '3dswing' ) {
				$err .= DaikinCloud_CheckAndQueue($hash,'horizontal','swing',$mode) if ($setlist =~ m/horizontal:/i && ReadingsVal($name, 'horizontal', 'unknown') ne 'swing');
				$err .= DaikinCloud_CheckAndQueue($hash,'vertical','swing',$mode) if ($setlist =~ m/vertical:/i && ReadingsVal($name, 'vertical', 'unknown') ne 'swing');
			} elsif ($value eq 'windNice' ) {
				$err .= DaikinCloud_CheckAndQueue($hash,'vertical','windNice',$mode) if ($setlist =~ m/vertical:/i );
			}
			readingsSingleUpdate($hash, $cmd, $value, 1 ) if ($err eq '');
		## if demandValue is set, the demandControl must be set to fixed	
		} elsif ($cmd =~ m/demandValue/i ) {
			$err .= DaikinCloud_CheckAndQueue($hash,'demandControl','fixed',$mode) if (ReadingsVal($name, 'demandControl', 'unknown') ne 'fixed'); #check if not fixed
			$err .= DaikinCloud_CheckAndQueue($hash,$cmd,$value,$mode);
		## if operationMode ist changed, setpoint, fanLevel, fanMode and possible fanDirections has to be set
		} elsif ($cmd =~ m/operationMode/i ){
			if (($value ne 'dry') && ($value ne 'fanOnly')){
				DaikinCloud_CheckAndQueue($hash,'setpoint',$setpoint,$value);
			}
			## to reduce requests: let the fan untouched (this means the fan will do like last time in this mode)
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
######################  check if the request limit is already reached ##### ###########################
#######################################################################################################

sub DaikinCloud_CheckRetryAfter($$$)
{
	my ($func,$rdg,$name) = @_;
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
	return undef if (!defined($hash) || !defined($func) || !defined($name));
	return undef if (!defined(ReadingsNum($hash->{NAME},'Retry-After',undef)));	
	my $retry_wait = round(5+(time_str2num(ReadingsTimestamp($hash->{NAME},'Retry-After',0))+ReadingsNum($hash->{NAME},'Retry-After',0))-gettimeofday(),0);
	if ($retry_wait > 0) {		
		RemoveInternalTimer($hash,$func);
		$retry_wait += 10 if ($func eq 'DaikinCloud_UpdateRequest');
		InternalTimer(gettimeofday()+$retry_wait, $func, $hash, 0);	
		readingsSingleUpdate($hash, $rdg, 'pending ... retry after '.$retry_wait.' seconds', 1 );
		Log3 $hash, 3, 'DaikinCloud ('.$name.'): Request pending. Automatically retry after '.$retry_wait.' seconds.'; 
		return 'DaikinCloud ('.$name.'): Request limit exceeded. Automatically retry after '.$retry_wait.' seconds.';
	}
	return undef;
}

#######################################################################################################
######################  initiate a non-blocking set cmd to the daikin cloud ###########################
#######################################################################################################

sub DaikinCloud_SetCmd()
{
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
	return 'DaikinCloud (Set-Cmd): No IOMASTER device found! ' if (!defined($hash));
	
	my $a_token = $hash->{helper}{ACCESS_TOKEN};
	if (!defined($a_token)) {
		readingsSingleUpdate($hash, 'state', 'no access-token', 1);
		my $r_token = $hash->{helper}{REFRESH_TOKEN};
		return 'DaikinCloud (Set-Cmd): No TokenSet found! ' if (!defined($r_token));
		DaikinCloud_RefreshToken();
		return;
	}
	
	return '' if (!defined($hash->{helper}{setQueue}));
	
	## request limit activ ?
	my $check = DaikinCloud_CheckRetryAfter('DaikinCloud_SetCmd','status_setcmd','SetCmd'); 
	return $check if (defined($check));
	
	## take a triple of the queue
	my $dev_id = shift @{$hash->{helper}{setQueue}};
	my $path   = shift @{$hash->{helper}{setQueue}};
	my $value  = shift @{$hash->{helper}{setQueue}};
	return '' if (!defined($dev_id) || !defined($path) || !defined($value));
		
	## prepare set cmd request
	my $body->{value} = $value;
	my ($emId, $dp, $datapath) = ($path =~ m/(.+):([^_]+)(.*)/);
	return 'DaikinCloud (Set-Cmd): Missing managementpoint or datapoint! Please forceUpdate first! ' if ((!defined($dp)) || (!defined($emId)));
	if (defined($datapath) && ($datapath ne '')) {
		$datapath =~ s/^_value//g;
		$datapath =~ s/_/\//g;
		$body->{path} = $datapath;
	}
	my $data = toJSON($body);
	
	## retry-after auswerten !
	
	HttpUtils_NonblockingGet(
	{ 	
		callback => \&DaikinCloud_SetCmdResponse,
		method => 'PATCH',
		hash => $hash,
		url => $daikin_cloud_url.'/'.$dev_id.'/management-points/'.$emId.'/characteristics/'.$dp , 
		timeout => 5, 
		header => 
		{
			'Authorization' => 'Bearer '.$a_token,
			'Content-Type' => 'application/json',
		}, 
		data => $data,
		## save actual dev_id, cmd, value in params to give it back, when the cmd set fails
		dc_id => $dev_id, 
		dc_path => $path, 
		dc_value => $value,
	});

	## cancel actual polling und schedules update-request in 120 sec to validate the operation
	RemoveInternalTimer($hash,'DaikinCloud_UpdateRequest');
	InternalTimer(gettimeofday()+120, 'DaikinCloud_UpdateRequest', $hash, 0); 
	return '';	
}

sub DaikinCloud_HeaderResponse($)
{
	my ($head) = @_;
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
	return if (!defined($hash) || !defined($head));
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash,'RateLimit-Limit-day',$1) if ($head =~ m/X-RateLimit-Limit-day:\s*([\d]+)/i);
	readingsBulkUpdate($hash,'RateLimit-Remaining-day',$1) if ($head =~ m/X-RateLimit-Remaining-day:\s*([\d]+)/i);
	readingsBulkUpdate($hash,'RateLimit-Limit-minute',$1) if ($head =~ m/X-RateLimit-Limit-minute:\s*([\d]+)/i);
	readingsBulkUpdate($hash,'RateLimit-Remaining-minute',$1) if ($head =~ m/X-RateLimit-Remaining-minute:\s*([\d]+)/i );
	readingsBulkUpdate($hash,'RateLimit-Reset',$1) if ($head =~ m/RateLimit-Reset:\s*([\d]+)/i );
	if ($head =~ m/Retry-After:\s*([\d]+)/i ) {
		readingsBulkUpdate($hash,'Retry-After',$1);
		Log3 $hash, 5, 'DaikinCloud (HeaderResponse): '.$head;
	}
	readingsEndUpdate($hash,1);
}

sub DaikinCloud_SetCmdResponse($)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	
	DaikinCloud_HeaderResponse($param->{httpheader}) if (defined($param->{httpheader}));
	
	if ($err ne '') {
		Log3 $hash, 1, "DaikinCloud (Set-Cmd): $err";
		
	} elsif ($param->{code} == 401 ) {
		readingsSingleUpdate($hash, 'status_setcmd', 'refreshing token ...', 1 );
		Log3 $hash, 3, 'DaikinCloud (Set-Cmd): Need to refresh access-token. Automatically starting RefreshToken!';
		## give cmd back to queue, update token and transmit command after refresh token
		unshift (@{$hash->{helper}{setQueue}},$param->{dc_id},$param->{dc_path},$param->{dc_value});
		DaikinCloud_RefreshToken();
		
	} elsif ($param->{code} == 429) {
		## give cmd back to queue, retry after request limit is over
		unshift (@{$hash->{helper}{setQueue}},$param->{dc_id},$param->{dc_path},$param->{dc_value});
		DaikinCloud_CheckRetryAfter('DaikinCloud_SetCmd','status_setcmd','SetCmdResponse');
		
	} elsif (($param->{code} == 200) || ($param->{code} == 204)) {
		readingsSingleUpdate($hash, 'status_setcmd', 'command successfully submitted', 1 );
		Log3 $hash, 5, 'DaikinCloud (Set-Cmd): device '.$param->{dc_id}.' path: '.$param->{dc_path}.' value: '.$param->{dc_value};
		DaikinCloud_SetCmd();
		
	} else { 
		readingsSingleUpdate($hash, 'status_setcmd', 'error in submitting command', 1 );
		Log3 $hash, 2, 'DaikinCloud (Set-Cmd): Error setting command: '.$param->{data}.' http-status-code: '.$param->{code}.' data: '.$data;
	}
}

#######################################################################################################
##########  check the set command (hash, cmd, value, mode) and add to queue ###########################
#######################################################################################################

sub DaikinCloud_CheckAndQueue($$$$)
{
	my ($hash, $cmd, $value, $mode) = @_;
	my $dev_id = $hash->{DEF};
	return 'DaikinCloud (Check-Cmd): Unknown Device-ID! ' if (!defined($dev_id));
	my $iomaster = $modules{DaikinCloud}{defptr}{IOMASTER};
	return 'DaikinCloud (Check-Cmd): No IO-MASTER device found! ' if (!defined($iomaster));
	my $table = $hash->{helper}{table}; 
	return 'DaikinCloud (Check-Cmd): No settable in cache! Please forceUpdate first! ' if (!defined($table) || (ref($table) ne 'HASH'));
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
	return "DaikinCloud (Check-Cmd): No datapath found for cmd $cmd : value $value ! " if ( $datapath eq '');
	##check value
	my ($options) = ($table->{$datapath} =~ m/^$cmd:(.*)$/ );
	## is it a range of possible values, then check min, max, step
	if ($options =~ m/^slider,(-?\d+\.?\d*),(-?\d+\.?\d*),(-?\d+\.?\d*)/) { #v1.3.3 fix for negativ offset
		if (($value < $1 ) || ($value > $3) || ((($3-$value) / $2) != int(($3-$value) / $2))) {
			return "DaikinCloud (Check-Cmd): cmd $cmd : value $value is out of range or step (min: $1 step: $2 max: $3)! ";
		## command and value are correct -> set them in queue
		} else {
			if (defined($iomaster->{helper}{setQueue}) && scalar(@{$iomaster->{helper}{setQueue}}) > 30) {
				Log3 $hash, 3, 'DaikinCloud (Check-Cmd): too much set-commands in queue (>10)! Please check connection!';
				return 'DaikinCloud (Check-Cmd): Too much set-commands in queue (>10)! ';
			} else {
				push( @{$iomaster->{helper}{setQueue}} , $dev_id , $datapath, $value);
				readingsSingleUpdate($hash, $cmd, $value, 1 );
				return '';
			}	
		}
	## check if the possible values contain the set value
	} elsif ($options =~ m/($value)/) {
		## command and value are correct -> set them in queue
		if (defined($iomaster->{helper}{setQueue}) && scalar(@{$iomaster->{helper}{setQueue}}) > 30) {
			Log3 $hash, 3, 'DaikinCloud (Check-Cmd): too much set-commands in queue (>10)! Please check connection!';
			return 'DaikinCloud (Check-Cmd): Too much set-commands in queue (>10)! ';
		} else {
			push( @{$iomaster->{helper}{setQueue}} , $dev_id , $datapath, $value);
			readingsSingleUpdate($hash, $cmd, $value, 1 );
			return '';
		}	
	} else {
		return "DaikinCloud (Check-Cmd): cmd $cmd : value $value is no possible option ($options)! ";
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
	my $setlist = '';
	my $iomaster = $modules{DaikinCloud}{defptr}{IOMASTER};

	if ( defined($iomaster) && $hash eq $iomaster ) {
	## get for IOMASTER
		if ( lc($cmd) eq 'refreshtoken') {
			return DaikinCloud_RefreshToken();
			
		} elsif ( lc($cmd) eq 'forceupdate') {
			return DaikinCloud_UpdateRequest($hash);
			
		} else {
			$setlist='forceUpdate:noArg refreshToken:noArg';
		}
	## get for indoor units
	} elsif ( lc($cmd) eq 'forceupdate') {
		return DaikinCloud_UpdateRequest($hash);
		
	} elsif ($cmd eq 'setlist') {
		my ($err,$setcmd) = DaikinCloud_setlist($hash) ;
		return $err if ($err ne '');
		$setcmd =~ s/ /\r\n/g;
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
	my $iomaster = $modules{DaikinCloud}{defptr}{IOMASTER};
	
	if ( defined($iomaster) && $hash eq $iomaster ) { 
	## handle the change of IOMASTER attributes
		## handle the change of polling-interval
		if ( $attrName eq 'interval' ) {
			if ( $cmd eq 'del' || $attrVal == 0) {
				$hash->{INTERVAL} = 0;
				RemoveInternalTimer($hash,'DaikinCloud_UpdateRequest');
				readingsSingleUpdate($hash, 'state', 'polling inactive', 1 );
			} elsif ( $attrVal >= 900 ) {
				$hash->{INTERVAL} = $attrVal;
				RemoveInternalTimer($hash,'DaikinCloud_UpdateRequest');
				InternalTimer(gettimeofday()+1, 'DaikinCloud_UpdateRequest', $hash, 0);
			} else { ## if interval < 900
				return "Minimum polling interval is 900 seconds.";
			}
		## delete all energy_ readings if consumptionData in IOMASTER is deleted or "0"
		} elsif ( $attrName eq 'consumptionData' ) {
			if (( $cmd eq 'del' ) || ( $attrVal == 0 )) {
				CommandDeleteReading(undef,'-q TYPE=DaikinCloud ^energy_.*');
				CommandDeleteReading(undef,'-q TYPE=DaikinCloud ^kWh_.*');				
			}
		## save jsonRawData in a reading
		} elsif ( $attrName eq 'saveRawData' ) {
			if (( $cmd eq 'del' ) || ( $attrVal == 0 )) {
				CommandDeleteReading(undef,'-q '.$name.' jsonRawData.*');
			}
		}
	## handle the change of indoor units attributes
	} elsif ( $attrName eq 'consumptionData' ) {
		if (( $cmd eq 'del' ) || ( $attrVal == 0 )) {
			CommandDeleteReading(undef,'-q '.$name.' ^energy_.*');				
		}
	}			
	return undef;
}

#######################################################################################################
##################################  UpdateRequest #####################################################
#######################################################################################################

sub DaikinCloud_UpdateRequest(;$)
{
	## start UpdateRequest always as IOMASTER, because there is the tokenSet 
	my $hash = $modules{DaikinCloud}{defptr}{IOMASTER};
	return 'DaikinCloud (UpdateRequest): No IOMASTER device found! ' if (!defined($hash));
	
	## is fhem start finished ? -> no -> wait 1 second
	if (!$init_done) {
		InternalTimer(gettimeofday()+1, 'DaikinCloud_UpdateRequest', $hash, 0);
		return;
	}
	
	if (!defined($hash->{CLIENT_ID}) || !defined($hash->{CLIENT_SECRET})) {
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, 'login_status', 'OAuth2-Login required!');
		readingsBulkUpdate($hash, 'token_type', 'OAuth2-Login required!');
		readingsBulkUpdate($hash, 'token_status', 'OAuth2-Login required!');
		readingsEndUpdate($hash,1);
		return 'Do a redefine to initialize the device: "defmod '.$hash->{NAME}.' DaikinCloud"';
	};	
	
	## check if access-token is available
	my $a_token = $hash->{helper}{ACCESS_TOKEN};
	if (!defined($a_token)) {
		readingsSingleUpdate($hash, 'state', 'no access-token', 1);
		my $r_token = $hash->{helper}{REFRESH_TOKEN};
		return 'DaikinCloud (UpdateRequest): No TokenSet found! ' if (!defined($r_token));
		DaikinCloud_RefreshToken();
		return;
	}
	
	## request limit activ ?
	my $check = DaikinCloud_CheckRetryAfter('DaikinCloud_UpdateRequest','update_response','UpdateRequest'); 
	if (defined($check)){
		return $check;
	}
	
	HttpUtils_NonblockingGet(
	{
		callback => \&DaikinCloud_CallbackUpdateRequest,
		url => $daikin_cloud_url,
		method => 'GET',
		hash => $hash,
		timeout => 10,		 
		header => {
			'Authorization' => 'Bearer '.$a_token,
			'Content-Type' => 'application/json'
		}	     
	});
	readingsSingleUpdate($hash, 'update_response', 'request for UpdateData ..', 1 );
	
	## set new timer for update-request only for safety if refresh fails
	RemoveInternalTimer($hash,'DaikinCloud_UpdateRequest');
	my $interval = $hash->{INTERVAL};
	if (defined($interval) && ($interval>0 )) {
		readingsSingleUpdate($hash, 'state', 'polling activ', 1 );
		InternalTimer(gettimeofday()+$interval, 'DaikinCloud_UpdateRequest', $hash, 0);
	} else {
		readingsSingleUpdate($hash, 'state', 'polling inactive', 1 );
	}
	return;
}


#######################################################################################################
##################################  UpdateResponse ####################################################
#######################################################################################################

sub DaikinCloud_GetDetailData($$$$$$$)
{
	my ($defptr,$data,$key,$mp,$path,$opM,$eopt) = @_;
	foreach my $skey (sort keys %{$data}) {
		## if Hash -> go deeper in the next level
		if (ref($data->{$skey}) eq "HASH") {
			if ($skey ne "schedule") {
				DaikinCloud_GetDetailData($defptr,$data->{$skey},$skey,$mp,($path eq "")?$skey:$path.'_'.$skey,$opM,$eopt);
			};
		## if value -> extract and store in a reading
		} elsif ($skey eq "value" ) {
			my $rdg = '';
			if ($path =~ m/_value_operationModes_/i) { 
				if ($path =~ m/_value_operationModes_($opM)_(.*)$/i) {
					my $para = $2;
					if ( $para =~ m/fanDirection_horizontal/i ) { $rdg = 'horizontal'; }
					elsif ( $para =~ m/fanDirection_vertical/i ) { $rdg = 'vertical'; }
					elsif ( $para =~ m/fanSpeed_currentMode/i ) { $rdg = 'fanMode'; }
					elsif ( $para =~ m/fanSpeed_modes_fixed/i ) { $rdg = 'fanLevel'; }
					elsif ( $para =~ m/setpoints_.*Temperature/i ) { $rdg = 'setpoint'; }	
					elsif ( $para =~ m/setpoints_.*Offset/i ) { $rdg = 'offset'; }	
				}					
			}  
			elsif ($path =~ m/demandControl.*_currentMode/i) { $rdg = 'demandControl'; } 
			elsif ($path =~ m/demandControl.*_fixed/i) { $rdg = 'demandValue'; } 
			else { $rdg = $key;}
			
			if ($rdg ne '') {
				$rdg .= '_'.$mp if ($key =~ m/(isIn|isHoliday|errorCode|firmware|iconId|modelInfo|software)/i);
				readingsBulkUpdate($defptr, $rdg, $data->{$skey} );
			}
		## if values -> check if settable = true and create a table with set-cmds			
		} elsif ($skey eq "values" && ref($data->{$skey}) eq "ARRAY"){
			if (defined($data->{settable}) && $data->{settable} eq "true") {
				my $cmd = $path;
				if ($path =~ m/_fanDirection_horizontal_currentMode/i) { $cmd = 'horizontal';} 
				elsif ($path =~ m/_fanDirection_vertical_currentMode/i) { $cmd = 'vertical';} 
				elsif ($path =~ m/_fanSpeed_currentMode/i) { $cmd = 'fanMode'; } 
				elsif ($path =~ m/demandControl_value_currentMode/i) { $cmd = 'demandControl'; }
				$cmd .= '_'.$mp if ($mp !~ m/climateControl/i);
				$defptr->{helper}{table}{$mp.':'.$path} = $cmd.':'.join(",",@{$data->{$skey}});
			}
		## if minValue, maxValue und StepValue -> check if settable = true and create a table with set-cmds
		} elsif ($skey eq "minValue"){
			if (defined($data->{maxValue}) && defined($data->{stepValue}) 
			&& defined($data->{settable}) && $data->{settable} eq "true") {
				my $cmd = $path;
				if ($path =~ m/operationModes_.*setpoints_.*Temperature/i) { $cmd = 'setpoint';	} 
				elsif ($path =~ m/operationModes_.*setpoints_.*Offset/i) { $cmd = 'offset';	} 
				elsif ($path =~ m/demandControl_value_modes_fixed/i) { $cmd = 'demandValue';} 
				elsif ($path =~ m/_fanSpeed_modes_fixed/i) { $cmd = 'fanLevel';	}
				$cmd .= '_'.$mp if ($mp !~ m/climateControl/i);
				$defptr->{helper}{table}{$mp.':'.$path} = $cmd.':slider,'.$data->{minValue}.','.$data->{stepValue}.','.$data->{maxValue}.',1';
			}
		## calculate consumptiondata
		} elsif (ref($data->{$skey}) eq "ARRAY" && $eopt && ($skey =~ m/^[mwd]$/) && ($path =~ m/consumptionData_value_electrical/i ) ) {
			my $sum = 0.0 ;
			my $append = "";
			$append .= '_'.$mp if ($mp !~ m/climateControl/i);
			for (my $i = 0; $i < @{$data->{$skey}}; $i++) {
				## if value is a number -> summarize
				if (defined($data->{$skey}[$i]) && $data->{$skey}[$i] =~ m/^[\d]+\.?[\d]*$/ 
					&& (($i > 6 && $skey eq "w") || $i > 11 )) {
					$sum += $data->{$skey}[$i] ;
				}
				readingsBulkUpdate($defptr, 'energy_'.$key.'_'.$skey.'_'.($i+1).$append, $data->{$skey}[$i]) if ($eopt == 2);
			}			
			my %period = ( m => 'year', w => 'week', d => 'day' ); 
			readingsBulkUpdate($defptr, 'kWh_'.$key.'_'.$period{$skey}.$append, $sum);
		} 
	}
}

sub DaikinCloud_GetDeviceData($$$)
{
	my ($defptr, $dd, $eopt) = @_;
	## delete the old settable
	delete $defptr->{helper}{table} if (defined($defptr->{helper}) && defined($defptr->{helper}{table}));
	## parse the data of the device
	foreach my $key (sort keys %{$dd}) {
		## if Hash -> go deeper in the next level
		if (ref($dd->{$key}) eq "HASH") {
			DaikinCloud_GetDetailData($defptr,$dd->{$key},$key,"","","","");
		## if array (-> =managementpoint) 	
		} elsif (ref($dd->{$key}) eq "ARRAY") {
			foreach my $mp (sort keys @{$dd->{$key}}){
				## extract the actual name of the managementpoint
				my $emID ="";
				if (defined($dd->{$key}[$mp]{embeddedId})) {
					$emID = $dd->{$key}[$mp]{embeddedId};
				}
				## extract the actual operationmode
				my $opM ="";
				if (defined($dd->{$key}[$mp]{operationMode}) &&
					defined($dd->{$key}[$mp]{operationMode}{value})) {
					$opM = $dd->{$key}[$mp]{operationMode}{value};
				}
				readingsBulkUpdate($defptr, 'managementPoint_Nr_'.($mp+1), $emID);
				DaikinCloud_GetDetailData($defptr,$dd->{$key}[$mp],$key,$emID,"",$opM,$eopt);
			}
		## save the root-data as readings
		} else {
			readingsBulkUpdate($defptr, $key, $dd->{$key});
		}		
	}
}

sub DaikinCloud_CallbackUpdateRequest 
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	$hash->{VERSION} = $DaikinCloud_version;
	
	DaikinCloud_HeaderResponse($param->{httpheader}) if (defined($param->{httpheader}));
	
	if ( $err || $param->{code} != 200 ) { 
		my $errortext = 'DaikinCloud (CallbackUpdateRequest) failed: ';
		$errortext .= $err if ($err);
		$errortext .= "HTTP-Status-Code=" . $param->{code};
		$errortext .= " Response: " . $data if (defined($data));
		Log3 $hash, 2, $errortext;
		readingsSingleUpdate($hash, 'update_response', $errortext , 1 );
		if ($param->{code} == 401 ){
			DaikinCloud_RefreshToken();
		}
		if ($param->{code} == 429 ){ ## if too many request (429)
			DaikinCloud_CheckRetryAfter('DaikinCloud_UpdateRequest','update_response','CallbackUpdateRequest');			
		}				
		return;
	}
	
	if (AttrVal($hash->{NAME},'saveRawData',undef)) {
		readingsSingleUpdate($hash, 'jsonRawData', $data , 1 );
	}
	
	my $time1 = time();
	my $cdda;
	## fix prepare data (true, false and null as string) 
	$data =~ s/"\s*:\s*true/":"true"/g; 
	$data =~ s/"\s*:\s*false/":"false"/g;
	$data =~ s/([,:\[])\s*(null)/$1"$2"/g;
	
	## transform json to perl object -> use JSON::XS (=fastest), otherwise use an own awesome method
	if ($json_xs_available) {
		# $cdda = JSON::XS->new->boolean_values("false","true")->decode($data);
		$cdda = decode_json($data);
	} else {		
		$data =~ s/":/"=>/g;
		($cdda) = eval $data ;
	}
	
	my $time2 = time();
	
	## Daikin-Json must always be an array of devices
	if (ref($cdda) eq "ARRAY") {
		## loop all devices
		foreach my $nr (sort keys @{$cdda}) {
			if (defined($cdda->[$nr]{_id})) {
				## extract device-id and device-name
				my $dev_id = $cdda->[$nr]{_id};
				my $dev_name = $dev_id;
				if (defined($cdda->[$nr]{managementPoints})	
				&& defined($cdda->[$nr]{managementPoints}[1])
				&& defined($cdda->[$nr]{managementPoints}[1]{name}) 
				&& defined($cdda->[$nr]{managementPoints}[1]{name}{value})) {
					$dev_name = $cdda->[$nr]{managementPoints}[1]{name}{value} || $dev_id;
				}
				readingsSingleUpdate($hash, $dev_name, $dev_id, 1 );
				my $defptr = $modules{DaikinCloud}{defptr}{$dev_id};
				## if not defined -> check if autocreate is set -> then define device
				if (!defined($defptr)) {
					if (AttrVal($hash->{NAME},'autocreate',undef)) {
						$dev_name = 'DaikinCloud_'.$dev_name;
						$dev_name =~ s/[^A-Za-z0-9_]/_/g;
						my $define = "$dev_name DaikinCloud $dev_id";
						if ( my $cmdret = CommandDefine(undef,$define) ) {
							Log3 $hash, 1, "DaikinCloud (DataRequest): An error occurred while creating device for $dev_id (name: $dev_name): $cmdret ";
						} 
						$defptr = $modules{DaikinCloud}{defptr}{$dev_id};
					}
				}	
				## if device exists in FHEM, parse the data and create readings
				if (defined($defptr)) {
					$defptr->{VERSION} = $DaikinCloud_version;
					readingsBeginUpdate($defptr);
					my $eopt = 0;
					if (AttrVal($hash->{NAME},'consumptionData',0)) {
						if (defined($defptr->{NAME}) && AttrVal($defptr->{NAME},'consumptionData',0)) { 
							$eopt=2;
						} else {
							$eopt=1;
						}
					} 
					DaikinCloud_GetDeviceData($defptr,$cdda->[$nr],$eopt);
					readingsEndUpdate($defptr,1);
					## merge vertical and horizontal to swing
					my $ver = ReadingsVal($defptr->{NAME}, 'vertical', undef);
					my $hor = ReadingsVal($defptr->{NAME}, 'horizontal', undef);
					
					if (defined($ver) && defined($hor)) {
						my $swing = 'unknown';
						if ($ver eq 'windNice') { $swing = 'windNice' }
						elsif ($ver eq 'stop')  { $swing = ($hor eq 'swing') ? 'horizontal': 'stop' }
						elsif ($ver eq 'swing') { $swing = ($hor eq 'swing') ? '3dswing': 'vertical' }
						readingsSingleUpdate($defptr, 'swing', $swing, 1 );
					}
					## merge fanLevel and fanMode to fanSpeed
					my $fanLevel = ReadingsVal($defptr->{NAME}, 'fanLevel', undef);
					my $fanMode = ReadingsVal($defptr->{NAME}, 'fanMode', undef);
					if (defined($fanLevel) && defined($fanMode)) {
						readingsSingleUpdate($defptr,'fanSpeed',($fanMode eq 'fixed')?'Level'.$fanLevel:$fanMode,1);
					}
					## add state to indoor device (=onOffMode if available)
					my $state = ReadingsVal($defptr->{NAME},'onOffMode',undef);
					readingsSingleUpdate($defptr,'state',$state,1) if (defined($state));
					
				}
			Log3 $hash, 5, 'DaikinCloud (CallbackUpdateRequest): Device-Data '.$dev_name. ' parsed.';	
			} ## end of each single device evaluation
		}## end of device loop
	}
	my $time3 = time();
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, 'update_response', 'successful', 1 );
	readingsBulkUpdate($hash, '._transform_time', ($time2-$time1) );
	readingsBulkUpdate($hash, '._parse_time', ($time3-$time2));
	readingsBulkUpdate($hash, '._sum_blocking_time', ($time3-$time1));
	readingsBulkUpdate($hash, '._transform_method', $json_xs_available?'JSON_XS':'EVAL');
	readingsEndUpdate($hash, 1)
}


###############################################################################################
########################################  end of code #########################################
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
      <code>define &lt;NAME&gt; DaikinCloud &lt;CLIENT_ID&gt; 
	  &lt;CLIENT_SECRET&gt; &lt;REDIRECT_URI&gt;</code><br>
      <br>
      Go to the <a href="https://developer.cloud.daikineurope.com/login" 
	  target="_blank">Daikin Developer Portal</a> to get a CLIENT_ID, 
	  a CLIENT_SECRET and save your own REDIRECT_URI 
	  (https://&lt;IP of your FHEM-Server&gt;:8083/fhem?cmd.Test=set%20DaikinCloud%20AuthCode%20).
	  <br><br>
	  After creating the master device it is required to do a Daikin-Cloud-Login (OAuth2).
	  The individual link is provided by the Internals of the master device 
	  (Internal AUTHORIZATION_LINK). After successful login a access-token and a refresh-token
	  is stored in FHEM.<br><br>
      Thereafter for each indoor unit one device has to be defined. It is 
      easiest to let the devices be autocreated (see attributes). Otherwise 
      they can also be created manually if the device-id is known:<br><br>
      <code>define &lt;NAME&gt; DaikinCloud &lt;DEVICE-ID&gt;</code><br>
    </ul>
  </ul>
  <br>
  <b>Set</b>
  <ul>
    <ul>
      <br>
      <a id="DaikinCloud-set-AuthCode"></a>
      <li><b>AuthCode</b><br>
        The Daikin-Cloud-Login (OAuth2) returns a temporary authorization-code
		to get the access-token and a refresh-token. If the automatic process
		fails, you can set the authorization-code (=return of the redirect-uri)
		manually.
      </li>
      <a id="DaikinCloud-set-Logout"></a>
      <li><b>Logout</b><br>
        To revoke the access-token and the refresh-token you can logout.
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
	  <a id="DaikinCloud-set-offset"></a>
      <li><b>offset</b> [ -10 .. 10 ]<br>
        Sets an offset value to the setpoint (e.g. flow temperature) to adjust it 
		(available on Altherma units depending on the configuration).
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
      <li><b>interval</b> [ 900 .. &infin; ]<br>
        Defines the interval in seconds for requesting actual data from the cloud. 
        The minimum possible interval is 900 seconds because there ist actually a
		request limit of 200 requests a day (include set-commands). 
		Default is 900 seconds.<br>
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
      <code>define &lt;NAME&gt; DaikinCloud &lt;CLIENT_ID&gt; 
	  &lt;CLIENT_SECRET&gt; &lt;REDIRECT_URI&gt;</code><br>
      <br>
      Gehe auf das <a href="https://developer.cloud.daikineurope.com/login" 
	  target="_blank">Daikin Developer Portal</a>, um eine CLIENT_ID, 
	  ein CLIENT_SECRET zu bekommen und deine eigene REDIRECT_URI 
	  (https://&lt;IP of your FHEM-Server&gt;:8083/fhem?cmd.Test=set%20DaikinCloud%20AuthCode%20)
	  dort zu speichern.
	  <br><br>
	  Nachdem das  Master-Ger&auml;t angelegt worden ist, ist ein Daikin-Cloud-Login (OAuth2)
	  erforderlich. Der individuelle Link ist in den Internals gespeichert 
	  (Internal AUTHORIZATION_LINK). Nach einem erfolgreichen Login werden der 
	  access-token und der refresh-token in FHEM gespeichert.
      <br><br>
      Danach muss f&uuml;r jedes Innenger&auml;t ein Device definiert werden. 
      Es ist am einfachsten, die Devices automatisch erstellen zu lassen 
      (siehe Attribute). Ansonsten k&ouml;nnen sie auch manuell erstellt 
      werden, wenn die Device-ID bereits bekannt ist:<br><br>
      <code>define &lt;NAME&gt; DaikinCloud &lt;DEVICE-ID&gt;</code><br>
    </ul>
  </ul>
  <br>
  <b>Set</b>
  <ul>
    <ul>
      <br>
      <a id="DaikinCloud-set-AuthCode"></a>
      <li><b>AuthCode</b><br>
        Der Daikin-Cloud-Login (OAuth2) gibt einen tempor&auml;ren 
		Autorisierungscode zur&uuml;ck. Falls der automatische Prozess
		scheitert, kann der Autorisierungscode (= R&uuml;ckgabe an die
		redirect-uri) auch manuell gesetzt werden.
      </li>
      <a id="DaikinCloud-set-Logout"></a>
      <li><b>Logout</b><br>
        Um den Zugriff auf die Cloud zu beenden, kannst du dich ausloggen.
		Der access-token und der refresh-token werden dabei zur&uuml;ckgegeben 
		und ung&uuml;ltig gesetzt.
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
	  <a id="DaikinCloud-set-offset"></a>
      <li><b>offset</b> [ -10 .. 10 ]<br>
        Setzt einen Offset-Wert zum Sollwert (z.B. Vorlauftemperatur), um 
		diesen anzupassen (bei Altherma-Ger&auml;ten je nach Konfiguration
		verf&uuml;gbar). 
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
      <li><b>interval</b> [ 900 .. &infin; ]<br>
        Definiert das Intervall in Sekunden, innerhalb dessen die aktuellen 
        Daten aus der Cloud jeweils abgefragt werden sollen. Das Minimum 
        betr&auml;gt 900 Sekunden, da ein aktuell ein Tageslimit mit maximal
		200 Anfragen (inklusive Set-Befehle) pro Tag an die Cloud besteht.
		Standard sind 900 Sekunden. Dieses Attribut ist nur 
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
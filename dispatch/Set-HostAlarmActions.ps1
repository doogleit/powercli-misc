function handle($context, $payload) {
	<#
	.SYNOPSIS
		Disables/enables vCenter alarm actions on a host.
	.DESCRIPTION
		The 'handle' function is called by a VMware Dispatch event subscription
		when a host enters/exits maintenance mode to disable/enable alarm actions 
		for the host.
	.LINK
		https://vmware.github.io/dispatch/documentation/examples/vcenter-events
	#>
	$username = $context.secrets.username
	$password = $context.secrets.password
	$hostname = $context.secrets.host
	$eventTime = [DateTime]$payload.time
	$eventMessage = $payload.message
	
	Import-Module vmware.vimautomation.core -verbose:$false
	Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
	
	# Connect to vSphere
	Write-Host "Checking VC Connection is active"
	if (-not $global:defaultviservers) {
		Write-Host "Connecting to $hostname"
		$viserver = Connect-VIServer -server $hostname -User $username -Password $password
	}
	else {
		Write-Host "Already connected to $hostname"
	}
	
	# Get the event by filtering on time and message
	$eventManager = Get-View (Get-View ServiceInstance).Content.EventManager
	$eventFilterSpec = New-Object VMware.Vim.EventFilterSpec
	$EventFilterSpec.Time = New-Object VMware.Vim.EventFilterSpecByTime
	$EventFilterSpec.Time.beginTime = $eventTime
	$EventFilterSpec.Time.endTime = $eventTime.AddSeconds(1)
	$events = $eventManager.QueryEvents($EventFilterSpec) | Where-Object 'FullFormattedMessage' -eq $eventMessage
	
	# For some reason there are always two "EnteredMaintenanceMode" events.  One has an 'Unknown user' and no related events.
	# We'll filter out that one and only use the event with a valid user and related events.
	$event = $events | Where-Object 'UserName' -ne 'Unknown user'
	
	if ($event) {
		$alarmManager = Get-View AlarmManager
		if ($event.GetType().Name -match "EnteredMaintenanceMode") {
			# Disable alarm actions on the host.  "$event.Host.Host" is the MoRef of the host.
			Write-Host "Disabling alarm actions on host $($event.Host.Name)"
			$alarmManager.EnableAlarmActions($event.Host.Host, $false)
		}
		else {
			# Enable alarm actions on the host.  "$event.Host.Host" is the MoRef of the host.
			Write-Host "Enabling alarm actions on host $($event.Host.Name)"
			$alarmManager.EnableAlarmActions($event.Host.Host, $true)
		}
	}
	else {
		Write-Host "The event was not found."
	}
	
	return "success"
}

function handle($context, $payload) {
	<#
	.SYNOPSIS
		Set custom attributes on a newly deployed VM.
	.DESCRIPTION
		The 'handle' function is called by a VMware Dispatch event subscription
		when a new VM is deployed to automatically set the custom attributes
		'Created On' and 'Created By' on the new VM.
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
	$event = $eventManager.QueryEvents($EventFilterSpec) | Where-Object 'FullFormattedMessage' -eq $eventMessage
	
	if ($event) {
		$vm = Get-VM -Name $event.Vm.Name
		if ($event.UserName) {
			Write-Host "Setting 'Created By' = '$($event.UserName)' on VM $VM"
			Set-Annotation -Entity $VM -CustomAttribute "Created By" -Value $event.UserName | Out-Null
		}
		if ($event.CreatedTime) {
			Write-Host "Setting 'Created On' = '$($event.CreatedTime)' on VM $VM"
			Set-Annotation -Entity $VM -CustomAttribute "Created On" -Value $event.CreatedTime | Out-Null
		}
	}
	else {
		Write-Host "The event was not found."
	}
	
	return "success"
}

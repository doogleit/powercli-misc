function handle($context, $payload) {
	<#
	.SYNOPSIS
		Unmanges/remanages a node in SolarWinds.
	.DESCRIPTION
		The 'handle' function is called by a VMware Dispatch event subscription
		when a host enters/exits maintenance mode to unmanage/remanage the host's
		corresponding node in SolarWinds.
	.LINK
		https://vmware.github.io/dispatch/documentation/examples/vcenter-events
	.LINK
		https://github.com/solarwinds/OrionSDK/wiki/PowerShell
	#>
	$username = $context.secrets.username
	$password = $context.secrets.password
	$hostname = $context.secrets.host
	$swishost = $context.secrets.swishost
	$swisuser = $context.secrets.swisuser
	$swispass = $context.secrets.swispass
	$eventTime = [DateTime]$payload.time
	$eventMessage = $payload.message
	
	Import-Module VMware.VimAutomation.Core -verbose:$false
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
		$nodeid = $null
		# Create Swis credential
		$swiscred = New-Object System.Management.Automation.PSCredential($swisuser, (ConvertTo-SecureString -String $swispass -AsPlainText -Force))
		
		# Get the Swis node with a matching hostname
		# NOTE: DisplayName in SolarWinds needs to match hostname in vCenter
		$response = Invoke-RESTMethod -Credential $swiscred -SkipCertificateCheck -Uri "https://$($swishost):17778/SolarWinds/InformationService/v3/Json/Query?query=SELECT+NodeId,+Uri+FROM+Orion.Nodes+WHERE+DisplayName='$($event.Host.Name)'"
		$node = $response.results
		
		if ($node) {
			$nodeId = $node.NodeId
			$nodeUri = $node.Uri
			if ($event.GetType().Name -match "EnteredMaintenanceMode") {
				# Unmanage the node
				Write-Host "Unmanaging node $($event.Host.Name)"
				$now = [DateTime]::UtcNow
				$until = $now.AddDays(365)
				Invoke-RESTMethod -Credential $swiscred -Method Post -ContentType "application/json" -SkipCertificateCheck -Uri "https://$($swishost):17778/SolarWinds/InformationService/v3/Json/Invoke/Orion.Nodes/Unmanage" -Body "[`"N:$nodeId`", `"$now`", `"$until`", `"false`"]"
				# To supress/mute alerts instead:
				#Invoke-RESTMethod -Credential $swiscred -Method Post -ContentType "application/json" -SkipCertificateCheck -Uri "https://$($swishost):17778/SolarWinds/InformationService/v3/Json/Invoke/Orion.AlertSuppression/SuppressAlerts" -Body "[[`"$nodeUri`"]]"
			}
			else {
				# Remanage the node
				Write-Host "Remanaging node $($event.Host.Name)"
				Invoke-RESTMethod -Credential $swiscred -Method Post -ContentType "application/json" -SkipCertificateCheck -Uri "https://$($swishost):17778/SolarWinds/InformationService/v3/Json/Invoke/Orion.Nodes/Remanage" -Body "[`"N:$nodeId`"]"
				# To resume alerts instead:
				#Invoke-RESTMethod -Credential $swiscred -Method Post -ContentType "application/json" -SkipCertificateCheck -Uri "https://$($swishost):17778/SolarWinds/InformationService/v3/Json/Invoke/Orion.AlertSuppression/ResumeAlerts" -Body "[[`"$nodeUri`"]]"
			}
		}
		else {
			Write-Host "The SWIS node was not found"
		}
	}
	else {
		Write-Host "The vCenter event was not found."
	}
	
	return "success"
}

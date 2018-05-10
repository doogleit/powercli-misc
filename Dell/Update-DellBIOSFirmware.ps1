<#
.SYNOPSIS
    Update the BIOS firmware for one or more Dell hosts in vCenter.

.DESCRIPTION
    Gets one or more Dell hosts from vCenter, gets the iDRAC IP address from the
    hardware using WSMAN, attempts to login to each iDRAC, stage the BIOS firmware
	and create a job to schedule it for the next reboot.

.PARAMETER vCenter
    One or more vCenter servers to connect to. This parameter is optional if you
    are already connected.

.PARAMETER Hostname
    One or more ESXi hostnames, as displayed in vCenter.  This parameter can be
    any value accepted by the 'Get-VMHost' cmdlet, including * as a wild card.
    This parameter is required.

.PARAMETER DracUser
    Username to authenticate to the iDrac.  Defaults to root.

.PARAMETER DracPassword
    Password to authenticate to the iDrac.  Defaults to calvin.

.PARAMETER Uri
    Path to the BIOS firmware update file (Windows DUP format).  FTP, HTTP, NFS,
	CIFS, and TFTP are supported.

.EXAMPLE
    .\Update-DellBIOSFirmware.ps1 myhost.domain.local

    Updates the BIOS firmware for a single host.

.EXAMPLE
    .\Update-DellBIOSFirmware.ps1 (Get-Cluster MyCluster| Get-VMHost)

    Updates the BIOS firmware for all hosts in the cluster.
#>
#Requires -version 3
#Requires -modules VMware.VimAutomation.Core
 param (
 	[parameter(Mandatory=$false)]
    $vCenter,
    [parameter(Mandatory=$true,Position=1,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
    $Hostname,
	$DracUser='root',
    $DracPassword='calvin',
    [parameter(Mandatory=$true)]
	$Uri
 )

 $DracPassword = ConvertTo-SecureString $DracPassword -AsPlainText -Force

 Import-Module VMware.VimAutomation.Core
 If ($vCenter) {
     Connect-VIServer $vCenter | Out-Null
 }

# Use WSMan function from VMware
# http://blogs.vmware.com/PowerCLI/2009/03/monitoring-esx-hardware-with-powershell.html
function Get-VMHostWSManInstance {
	param (
	[Parameter(Mandatory=$TRUE,HelpMessage="VMHosts to probe")]
	[VMware.VimAutomation.Client20.VMHostImpl[]]
	$VMHost,

	[Parameter(Mandatory=$TRUE,HelpMessage="Class Name")]
	[string]
	$class,

	[switch]
	$ignoreCertFailures,

	[System.Management.Automation.PSCredential]
	$credential=$null
	)

	$omcBase = "http://schema.omc-project.org/wbem/wscim/1/cim-schema/2/"
	$dmtfBase = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/"
	$vmwareBase = "http://schemas.vmware.com/wbem/wscim/1/cim-schema/2/"

	if ($ignoreCertFailures) {
		$option = New-WSManSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
	} else {
		$option = New-WSManSessionOption
	}
	foreach ($H in $VMHost) {
		if ($credential -eq $null) {
			$hView = $H | Get-View -property Value
			$ticket = $hView.AcquireCimServicesTicket()
			$password = convertto-securestring $ticket.SessionId -asplaintext -force
			$credential = new-object -typename System.Management.Automation.PSCredential -argumentlist $ticket.SessionId, $password
		}
		$uri = "https`://" + $h.Name + "/wsman"
		if ($class -cmatch "^CIM") {
			$baseUrl = $dmtfBase
		} elseif ($class -cmatch "^OMC") {
			$baseUrl = $omcBase
		} elseif ($class -cmatch "^VMware") {
			$baseUrl = $vmwareBase
		} else {
			throw "Unrecognized class"
		}
		Get-WSManInstance -Authentication basic -ConnectionURI $uri -Credential $credential -Enumerate -Port 443 -UseSSL -SessionOption $option -ResourceURI "$baseUrl/$class"
	}
}


# Get Dell VMHosts from vCenter
$vmhosts = Get-VMHost $Hostname | Where 'Manufacturer' -match 'Dell'
ForEach ($vmhost in $vmhosts) {
    $session = $null

    # Get iDRAC IP address from vCenter
    If ($vmhost.ConnectionState -eq 'Disconnected' -or $vmhost.ConnectionState -eq 'NotResponding') {
        Write-Warning "$($vmhost.Name) is not connected in vCenter.  The iDRAC IP address cannot be retrieved."
        Continue  # continue moves to next item in the loop (next host)
    }
    Else {
        $ipmiInfo = Get-VMHostWSManInstance -VMHost $vmhost -class OMC_IPMIIPProtocolEndpoint -ignoreCertFailures
        $IPAddress = $ipmiInfo.IPv4Address
    }

    # Create iDRAC session
    $cimop = New-CimSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck -Encoding Utf8 -UseSsl
    $credentials = New-Object -typename System.Management.Automation.PSCredential -argumentlist $DracUser, $DracPassword
    $session = New-CimSession -Authentication Basic -Credential $credentials -ComputerName $IPAddress -Port 443 -SessionOption $cimop

    # Get BIOS CIM instance
	$resourceUri="http://schemas.dell.com/wbem/wscim/1/cim-schema/2/DCIM_SoftwareIdentity"
	$properties= @{InstanceID="DCIM:INSTALLED#741__BIOS.Setup.1-1"}
    $keyNames = @($properties.Keys)
    $keyInst = New-CimInstance -ClassName DCIM_SoftwareIdentity -Namespace root/dcim -ClientOnly -Key $keyNames -Property $properties
    $inst = Get-CimInstance -CimInstance $keyInst -CimSession $session -ResourceUri $resourceUri

    # Create iDRAC job for software update
	$resourceUri="http://schemas.dell.com/wbem/wscim/1/cim-schema/2/DCIM_SoftwareInstallationService"
	$properties=@{CreationClassName="DCIM_SoftwareInstallationService" ; SystemCreationClassName="DCIM_ComputerSystem" ; SystemName="IDRAC:ID" ; Name="SoftwareUpdate"}
	$keyNames = @($properties.Keys)
    $keyInst = New-CimInstance -ClassName DCIM_SoftwareInstallationService -Namespace root/dcim -ClientOnly -Key $keyNames -Property $properties
    $inst1 = Get-CimInstance -CimInstance $keyInst -CimSession $session -ResourceUri $resourceUri	
	
	$responseData = Invoke-CimMethod -InputObject $inst1 -MethodName InstallFromURI -Arguments @{Target=[ref]$inst;URI=$uri} -CimSession $session -ResourceUri $resourceUri
	$jobid = $responseData.Job.EndpointReference.InstanceID
	
	# Schedule job for next reboot
	$resourceUri = "http://schemas.dell.com/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_JobService"
	$jobarray=@($jobid)
	$properties = @{CreationClassName="DCIM_JobService" ; SystemCreationClassName="DCIM_ComputerSystem" ; SystemName="Idrac" ; Name="JobService"}
	$keyNames = @($properties.Keys)
	$keyInst = New-CimInstance -ClassName DCIM_JobService -Namespace root/dcim -ClientOnly -Key $keyNames -Property $properties 
	$inst2 = Get-CimInstance -CimInstance $keyInst -CimSession $session -ResourceUri $resourceUri
	$jobstatus = Invoke-CimMethod -InputObject $inst2 -MethodName SetupJobQueue -Arguments @{"JobArray"=$jobarray;"StartTimeInterval"="TIME_NOW"} -CimSession $session -ResourceUri $resourceUri
	$jobstatus
}
<#
.SYNOPSIS
    Sets the Dell BIOS system profile for one or more hosts in vCenter. The system 
	profile on Dell servers controls the BIOS power management settings.

.DESCRIPTION
    Gets one or more Dell hosts from vCenter, gets the iDRAC IP address from the
    hardware using WSMAN, and attempts to login to each iDRAC and set the BIOS
    system profile setting.  Schedules a job through the iDRAC to commit the
    change on the next reboot.

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

.PARAMETER SystemProfile
    The Dell System Profile to use for power management. Defaults to
    'PerfPerWattOptimizedOs', which allows the OS (ESXi) to control power
    management.  Other options are 'PerfPerWattOptimizedDapc', 'PerfOptimized',
    'DenseCfgOptimized', or 'Custom'.

.PARAMETER OutputFile
    If specified, the results are written to the file in CSV format.

.EXAMPLE
    .\Set-DellSystemProfile.ps1 myhost.domain.local

    Sets the system profile for a single host.

.EXAMPLE
    .\Set-DellSystemProfile.ps1 (Get-Cluster MyCluster| Get-VMHost)

    Sets the system profile for all hosts in the cluster.
.NOTES
    The linked resources from VMware and Dell are now a bit dated, but still good references.
    
.LINK
	https://www.vmware.com/content/dam/digitalmarketing/vmware/en/pdf/techpaper/hpm-performance-vsphere55-white-paper.pdf

.LINK
	http://en.community.dell.com/techcenter/b/techcenter/archive/2013/06/04/dell-poweredge-powermanagement-options-in-vmware-esxi-environment
#>
#Requires -version 3
#Requires -modules VMware.VimAutomation.Core
 param (
 	[parameter(Mandatory=$false)]
    $vCenter,
    [parameter(Mandatory=$true,Position=1,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
    $Hostname,
	$DracUser,
    $DracPassword,
    $OutputFile,
    $SystemProfile = 'PerfPerWattOptimizedOs'
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

    # BIOS settings
    $resourceUri="http://schemas.dell.com/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_BIOSService"
    $attributeName = 'SysProfile'
    $attributeValue = $SystemProfile
    $target = 'BIOS.Setup.1-1'
    $properties=@{CreationClassName="DCIM_BIOSService" ;
    SystemCreationClassName="DCIM_ComputerSystem" ;
    SystemName="DCIM:ComputerSystem" ; Name="DCIM:BIOSService"}

    # Create iDRAC session
    $cimop = New-CimSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck -Encoding Utf8 -UseSsl

    $credentials = New-Object -typename System.Management.Automation.PSCredential -argumentlist $DracUser, $DracPassword
    $session = New-CimSession -Authentication Basic -Credential $credentials -ComputerName $IPAddress -Port 443 -SessionOption $cimop

    # Get CIM instance
    $keyNames = @($properties.Keys)
    $keyInst = New-CimInstance -ClassName DCIM_BIOSService -Namespace root/dcim -ClientOnly -Key $keyNames -Property $properties
    $inst = Get-CimInstance -CimInstance $keyInst -CimSession $session -ResourceUri $resourceUri

    # Set Pending Value
    Invoke-CimMethod -InputObject $inst -MethodName SetAttributes -Arguments @{Target=$target;AttributeName=$attributeName;AttributeValue=$attributeValue} -CimSession $session -ResourceUri $resourceUri | Format-Table

    # Schedule Commit Job (next reboot)
    Invoke-CimMethod -InputObject $inst -MethodName CreateTargetedConfigJob -Arguments @{Target=$target;ScheduledStartTime="TIME_NOW"} -CimSession $session -ResourceUri $resourceUri | Format-Table

}
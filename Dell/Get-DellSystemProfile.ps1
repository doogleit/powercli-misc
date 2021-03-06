<#
.SYNOPSIS
    Gets the Dell BIOS system profile for one or more hosts in vCenter.  The system 
	profile on Dell servers controls the BIOS power management settings.

.DESCRIPTION
    Gets one or more Dell hosts from vCenter, gets the iDRAC IP address from the
    hardware using WSMAN, and attempts to login to each iDRAC and query the BIOS
    for the system profile setting. Returns the resulting object as standard output.

.PARAMETER vCenter
    One or more vCenter servers to connect to.  This parameter is optional if you
    are already connected.

.PARAMETER Hostname
    One or more ESXi hostnames, as displayed in vCenter.  This parameter can be
    any value accepted by the 'Get-VMHost' cmdlet, including * as a wild card.
    The default is to get all hosts (*).

.PARAMETER DracUser
    Username to authenticate to the iDrac.  Defaults to root.

.PARAMETER DracPassword
    Password to authenticate to the iDrac.  Defaults to calvin.

.PARAMETER OutputFile
    If specified, the results are written to the file in CSV format.

.EXAMPLE
    .\Get-DellSystemProfile.ps1 myhost.domain.local

    Gets the system profile for a single host.

.EXAMPLE
    .\Get-DellSystemProfile.ps1 (Get-Cluster MyCluster | Get-VMHost)

    Gets the system profile for all hosts in the cluster.

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
    [parameter(Mandatory=$false,Position=1,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
    $Hostname = '*',
    $DracUser = 'root',
	$DracPassword = 'calvin',
    $OutputFile
 )

$DracPassword = ConvertTo-SecureString $DracPassword -AsPlainText -Force

Import-Module VMware.VimAutomation.Core
If ($vCenter) {
    Connect-VIServer $vCenter | Out-Null
}

$results = @()

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
    $sysprofile = $null
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

    # Login to iDRAC IP address and enumerate BIOS settings
    $cimop = New-CimSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck -Encoding Utf8 -UseSsl

    $credentials = New-Object -typename System.Management.Automation.PSCredential -argumentlist $DracUser, $DracPassword
    $session = New-CimSession -Authentication Basic -Credential $credentials -ComputerName $IPAddress -Port 443 -SessionOption $cimop
    $query="select CurrentValue from DCIM_BIOSEnumeration WHERE AttributeName='SysProfile'"
    $queryDialect="http://schemas.microsoft.com/wbem/wsman/1/WQL"
    $resourceUri="http://schemas.dell.com/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_BIOSEnumeration"
    $sysprofile = Get-CimInstance -Query $query -CimSession $session -Namespace root/dcim -QueryDialect $queryDialect -ResourceUri $resourceUri

    # Save info for each host and append to results
    $hostinfo = New-Object -TypeName PSObject -Property @{
        'Cluster' = $vmhost.Parent
        'HostName' = $vmhost.Name
        'Model' = $vmhost.Model
        'iDracAddress' = $ipmiInfo.IPv4Address
        'BIOSSysProfile' = $sysprofile.CurrentValue
    }
    $results += $hostinfo
}

If ($OutputFile) {
    $results | export-csv "$OutputFile" -NoTypeInfo
}
$results
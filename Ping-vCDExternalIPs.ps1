<#
.SYNOPSIS
	Pings all VMs in a vCloud Director Org.

.DESCRIPTION
	Searches a vCD server for all vApps in a given Org, collects network info
    from each VM, and attempts to ping the external address of each one that
    is powered on. Requires the VMware PowerCLI vCD module.

.PARAMETER Server
	The Cloud (vCD) server to connect to.  Will prompt for a server if one isn't
    specified.

.PARAMETER Org
	Name of the vCD organization.

.EXAMPLE
	C:\PS> .\Ping-vCDExternalIPs.ps1 -Server vcd.domain.local -Org MyOrg

	Description
	-----------
    Connects to the vCD server and pings all powered on VMs in "MyOrg".

#>
#Requires -version 3
#Requires -modules VMware.Vimautomation.Cloud
[CmdletBinding()]
param (
    [string]$Server = $(Read-Host "Enter the vCD server name"),
    [string]$Org  = $(Read-Host "Enter the vCD Org name")
)
$maxJobs = 100  # Max concurrent jobs to run for network pings
$csvFile = "$Server-$Org-$(Get-Date -format 'yyyy.MM.dd.HHmm').csv"

# vApp/VM Status lookup table
$states = @{
    -1 = "FAILED_CREATION";
    0 = "UNRESOLVED";
    1 = "RESOLVED";
    2 = "DEPLOYED";
    3 = "SUSPENDED";
    4 = "POWERED_ON";
    5 = "WAITING_FOR_INPUT";
    6 = "UNKNOWN";
    7 = "UNRECOGNIZED";
    8 = "POWERED_OFF";
    9 = "INCONSISTENT_STATE";
    10 = "MIXED"
}

Import-Module VMware.VimAutomation.Cloud
$CIServer = Connect-CIServer $Server
$myOrg = Get-Org -Name $Org -Server $CIServer

# Search vCD for vApps
$search = search-cloud -querytype AdminVApp -filter "Org==$($myorg.id)" -Property id, name, status -Server $CIServer | where {$_.Status -eq "POWERED_ON"}
Write-Host "Search cloud returned $($search.count) vApps."

# Get vApp Views.  Using Views is significantly faster than calling Get-CINetworkAdapter for 100's of VMs.
Write-Host "Getting vApp/VM Network info. This can take 30+ mins for large orgs. Just sit back and enjoy the blinking cursor."
$vApps = Get-CIView -SearchResult $search

$vAppNetAdapters = @()
foreach ($vApp in $vApps) {
    foreach ($vm in ($vApp.Children.vm)) {
                $networkAdapters = $vm.Section.NetworkConnection
                foreach ($networkAdapter in $networkAdapters) {
                        $vAppNicInfo = New-Object "PSCustomObject"
                        $vAppNicInfo | Add-Member -MemberType NoteProperty -Name VAppName -Value $vApp.Name
                        $vAppNicInfo | Add-Member -MemberType NoteProperty -Name VMName   -Value $vm.Name
                        $vAppNicInfo | Add-Member -MemberType NoteProperty -Name Status   -Value $($states.Get_Item($vm.Status))
                        $vAppNicInfo | Add-Member -MemberType NoteProperty -Name NIC      -Value ("NIC" + $networkAdapter.NetworkConnectionIndex)
                        $vAppNicInfo | Add-Member -MemberType NoteProperty -Name InternalIP -Value $networkAdapter.IpAddress
                        $vAppNicInfo | Add-Member -MemberType NoteProperty -Name ExternalIP -Value $networkAdapter.ExternalIpAddress
                        $vAppNicInfo | Add-Member -MemberType NoteProperty -Name IsConnected -Value $networkAdapter.IsConnected
                        $vAppNetAdapters += $vAppNicInfo
                }
    }
}
Write-Host "$($vAppNetAdapters.Count) VM network adapters were retrieved."

# Ping IP addresses
Write-Host "Starting jobs to ping IP addresses.  Max concurrent jobs is $maxJobs."
$jobs = @()
$i = 0
$vAppNetAdapters | Where {$_.ExternalIP -ne $null } | ForEach {
    $jobs += Start-Job -ScriptBlock {
        param($vAppNetAdapter)
        $vAppNetAdapter | Add-Member -MemberType NoteProperty -Name Ping -Value (Test-Connection -Computer $vAppNetAdapter.ExternalIP -Count 1 -Quiet)
        $vAppNetAdapter
    } -ArgumentList $_
    $i++
    Write-Progress -Activity "Pinging vApp/VM Networks" -CurrentOperation "Pinging $($_.ExternalIP)" -PercentComplete ($i/$vAppNetAdapters.Count*100)
    While ((get-job -state Running).count -ge $maxJobs) {
        Write-Progress -Activity "Pinging vApp Networks" -CurrentOperation "Max jobs reached. Waiting..." -PercentComplete ($i/$vAppNetAdapters.Count*100)
        Start-Sleep -Seconds 3
    }
}

Wait-Job -job $jobs -Timeout 60 | Out-Null
$results = @()
$results = Receive-Job -Job $jobs
Remove-Job -Job $jobs

If ($results.count -gt 0) {
    $results | Export-Csv -NoTypeInformation -Path $csvFile
    Write-Host "Results written to $csvFile."
}

Disconnect-CIServer -Server $CIServer -Confirm:$false

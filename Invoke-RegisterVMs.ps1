<#
.SYNOPSIS
    Re-registers VMs to a new host in vCenter.  Useful when a host is offline and has
    VMs still registered to it.  This may occur if High Availbility was not enabled
    on the cluster or there was an error failing over the VMs.

.DESCRIPTION
    Collects VM info from a host that is offline in vCenter, removes the host from
    vCenter to remove the offline VMs from inventory, and re-registers the VMs on
    another host. If the VM's power state was previously 'PoweredOn' the VM is powered
    back on.

.PARAMETER Badhost
    Name of the host that is offline/disconnected from vCenter.

.PARAMETER Newhost
    Name of the new host to re-register the VMs on.

.PARAMETER Csvfile
    File name to save the VM information for the VMs being re-registered.

.EXAMPLE
    .\Invoke-RegisterVMs.ps1 -Badhost host1.domain.local -Newhost host2.domain.local
#>
#Requires -modules VMware.VimAutomation.Core
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    $Badhost,
    [Parameter(Mandatory=$true)]
    $Newhost,
    $Csvfile = ".\$badhost-vminfo.csv"
)

# Collect VM info from bad host
$vminfo = get-vmhost $Badhost | get-vm | select Name, PowerState, ResourcePool, Folder, @{l='vmx';e={$_.ExtensionData.config.files.VmPathName}}
$vminfo | export-csv $Csvfile -NoTypeInformation

# Remove the host from vCenter
Write-Host "IMPORTANT: Before continuing verify the the VM information was successfully saved to file: $Csvfile"
Write-Host "The offline host will be removed and VMs removed from inventory. Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
Remove-VMHost $Badhost

# Register VMs to new host
$vminfo = Import-Csv $Csvfile
$vmhost = Get-VMHost $Newhost

$vminfo | % {
    $registeredVM = New-VM -VMFilePath $_.vmx -VMHost $vmhost -Location $_.folder -ResourcePool (Get-ResourcePool -Name $_.ResourcePool -Location $vmhost.Parent)
    if ($_.PowerState -eq 'PoweredOn') { $registeredVM | Start-VM -RunAsync }
}
